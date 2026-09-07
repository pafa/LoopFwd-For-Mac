import Darwin
import Foundation

/// One explicit Claude configuration edit. All backups remain local and each
/// attempt gets a distinct recovery directory; no provider process is started.
enum ClaudeHookInstaller {
    enum Failure: LocalizedError {
        case invalidSettings
        case unsafeFile
        case locked
        case changed
        case operationFailed(backup: String, restored: Bool)

        var errorDescription: String? {
            switch self {
            case .invalidSettings: return L10n.string("Invalid Claude settings. Nothing was changed.")
            case .unsafeFile: return L10n.string("Claude settings must be a regular file, not a symbolic link.")
            case .locked: return L10n.string("Another hook operation may be running. Review the lock before retrying.")
            case .changed: return L10n.string("Settings changed during installation. Newer changes were preserved.")
            case .operationFailed(let backup, let restored):
                return L10n.format(
                    restored
                        ? "Hook operation failed; previous files restored. Backup: %@"
                        : "Hook operation failed; review files and backup before retrying: %@",
                    backup)
            }
        }
    }

    static func backupRoot(for settings: URL) -> URL {
        settings.deletingLastPathComponent().appendingPathComponent(".loopfwd-hook-backups", isDirectory: true)
    }

    static func update(
        install: Bool, settings: URL, scriptURL: URL, script: Data,
        beforeCommit: (() throws -> Void)? = nil
    ) throws {
        let fm = FileManager.default
        // Invalid input fails before creating installer artifacts.
        _ = try projected(try read(settings), install: install, path: scriptURL.path)
        try fm.createDirectory(
            at: settings.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let lock = settings.deletingLastPathComponent().appendingPathComponent(".loopfwd-hook.lock")
        let descriptor = open(lock.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw Failure.locked }
        defer { close(descriptor); unlink(lock.path) }
        let lockHandle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        try lockHandle.write(contentsOf: Data("pid=\(ProcessInfo.processInfo.processIdentifier)\n".utf8))

        // Re-read after acquiring the lock; another installer may have finished.
        let original = try read(settings)
        let updated = try projected(original, install: install, path: scriptURL.path)
        let scriptLock = scriptURL.deletingLastPathComponent().appendingPathComponent(".loopfwd-script.lock")
        var scriptDescriptor: Int32 = -1
        if install {
            try fm.createDirectory(
                at: scriptURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            scriptDescriptor = open(scriptLock.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
            guard scriptDescriptor >= 0 else { throw Failure.locked }
        }
        defer {
            if scriptDescriptor >= 0 { close(scriptDescriptor); unlink(scriptLock.path) }
        }
        if scriptDescriptor >= 0 {
            let handle = FileHandle(fileDescriptor: scriptDescriptor, closeOnDealloc: false)
            try handle.write(contentsOf: Data("pid=\(ProcessInfo.processInfo.processIdentifier)\n".utf8))
        }
        let originalScript = install ? try read(scriptURL) : nil
        let backupBase = backupRoot(for: settings)
        try fm.createDirectory(
            at: backupBase, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let backup = backupBase.appendingPathComponent(
            "\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: backup, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        if let original { try writePrivate(original, to: backup.appendingPathComponent("settings.json")) }
        if let originalScript { try writePrivate(originalScript, to: backup.appendingPathComponent("notify-hook.sh")) }

        var changedScript = false
        do {
            if install {
                try writePrivate(script, to: scriptURL, mode: 0o700)
                changedScript = true
            }
            try beforeCommit?()
            guard try read(settings) == original else { throw Failure.changed }
            // The atomic rename is the final fallible operation: a successful
            // settings replacement cannot later be reported as a rollback.
            if original != nil || install { try writePrivate(updated, to: settings) }
        } catch {
            var restored = true
            if changedScript {
                do {
                    guard try read(scriptURL) == script else { throw Failure.changed }
                    if let originalScript {
                        try writePrivate(originalScript, to: scriptURL, mode: 0o700)
                    } else {
                        try fm.removeItem(at: scriptURL)
                    }
                } catch { restored = false }
            }
            // We never restore settings over an external edit.
            if (try? read(settings)) != original { restored = false }
            throw Failure.operationFailed(backup: backup.path, restored: restored)
        }
        // Shared script/spool files are retained: another explicitly configured
        // Claude profile can still reference them. Remove only this config's hooks.
    }

    private static func projected(_ data: Data?, install: Bool, path: String) throws -> Data {
        let root: [String: Any]
        switch HookSettings.load(data: data) {
        case .missing: root = [:]
        case .parsed(let value): root = value
        case .unreadable: throw Failure.invalidSettings
        }
        let result =
            try install
            ? HookSettings.merged(into: root, hookPath: path)
            : HookSettings.removed(from: root, hookPath: path)
        guard let data = HookSettings.serialize(result) else { throw Failure.invalidSettings }
        return data
    }

    private static func read(_ url: URL) throws -> Data? {
        let attributes: [FileAttributeKey: Any]
        do { attributes = try FileManager.default.attributesOfItem(atPath: url.path) } catch let error as NSError
            where error.domain == NSCocoaErrorDomain
            && (error.code == NSFileNoSuchFileError || error.code == NSFileReadNoSuchFileError)
        {
            return nil
        }
        guard attributes[.type] as? FileAttributeType == .typeRegular else { throw Failure.unsafeFile }
        guard let size = attributes[.size] as? NSNumber, size.intValue <= 4 * 1024 * 1024 else {
            throw Failure.invalidSettings
        }
        return try Data(contentsOf: url)
    }

    /// Adapted from the existing TOML installer's private atomic write.
    private static func writePrivate(_ data: Data, to destination: URL, mode: mode_t = 0o600) throws {
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".loopfwd-" + UUID().uuidString)
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode)
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close(); unlink(temporary.path) }
        try handle.write(contentsOf: data)
        try handle.synchronize()
        guard rename(temporary.path, destination.path) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }
}
