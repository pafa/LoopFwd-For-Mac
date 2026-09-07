import CryptoKit
import Foundation

/// Explicit, recoverable installer for LoopFwd's read-only DeepSeek Harness Web
/// observer. No profile is changed at startup or during passive discovery.
final class DeepSeekHarnessIntegration: ObservableObject {
    static let shared = DeepSeekHarnessIntegration()

    @Published private(set) var installed = false
    @Published private(set) var busy = false
    @Published private(set) var message = L10n.string("Checking…")

    private let packageName = "@loopfwd/dsh-observer"
    private let queue = DispatchQueue(label: "app.loopfwd.dsh-integration", qos: .userInitiated)

    private init() { refresh() }

    var harnessAvailable: Bool { AgentKind.deepseek.installedCLIPath != nil }

    func refresh() {
        installed = Self.profileContainsObserver
        if installed {
            message = L10n.string("Installed · restart DeepSeek Harness Web after changes")
        } else if harnessAvailable {
            message = L10n.format("Not installed · supports dsh %@", DeepSeekHarnessSessions.supportedHarnessVersion)
        } else {
            message = L10n.string("dsh CLI not found")
        }
    }

    func install() {
        guard !busy, let executable = AgentKind.deepseek.installedCLIPath else {
            message = L10n.string("dsh CLI not found")
            return
        }
        guard
            let archive = Bundle.main.url(
                forResource: "LoopFwdDSHObserver", withExtension: "tgz"
            )
        else {
            message = L10n.string("Observer bundle is missing from this build")
            return
        }
        busy = true
        message = L10n.string("Installing…")
        queue.async {
            do {
                try Self.installObserver(
                    executable: executable,
                    archivePath: archive.path,
                    packageName: self.packageName,
                    command: Self.run
                )
                DispatchQueue.main.async {
                    self.busy = false
                    self.refresh()
                }
            } catch {
                DispatchQueue.main.async {
                    self.busy = false
                    self.installed = Self.profileContainsObserver
                    self.message = L10n.format("Install failed: %@", error.localizedDescription)
                }
            }
        }
    }

    func uninstall() {
        guard !busy, let executable = AgentKind.deepseek.installedCLIPath else {
            message = L10n.string("dsh CLI not found")
            return
        }
        busy = true
        message = L10n.string("Removing…")
        queue.async {
            do {
                try Self.backUpProfileMetadata()
                let result = Self.run(
                    executable,
                    [
                        "plugin", "--profile", "web", "remove", self.packageName,
                    ])
                guard result.ok else { throw IntegrationError.commandFailed(result.message) }
                var cleanupWarning: String?
                if FileManager.default.fileExists(atPath: DeepSeekHarnessSessions.snapshotPath) {
                    do {
                        try FileManager.default.removeItem(atPath: DeepSeekHarnessSessions.snapshotPath)
                    } catch {
                        cleanupWarning =
                            L10n.format(
                                "Observer removed, but its old snapshot could not be removed: %@",
                                error.localizedDescription)
                    }
                }
                DispatchQueue.main.async {
                    self.busy = false
                    self.refresh()
                    if let cleanupWarning { self.message = cleanupWarning }
                    AgentMonitor.shared.scanNow()
                }
            } catch {
                DispatchQueue.main.async {
                    self.busy = false
                    self.installed = Self.profileContainsObserver
                    self.message = L10n.format("Remove failed: %@", error.localizedDescription)
                }
            }
        }
    }

    static var dshRootOverride: String?
    private static var dshRoot: String {
        if let dshRootOverride { return dshRootOverride }
        let configured = ProcessInfo.processInfo.environment["DSH_HOME"]
            .flatMap { $0.isEmpty ? nil : $0 }
        return ((configured ?? NSHomeDirectory() + "/.dsh") as NSString)
            .standardizingPath
    }

    private static var profileDirectory: String { dshRoot + "/profiles/web" }

    private static var profileContainsObserver: Bool {
        let path = profileDirectory + "/package.json"
        guard let data = FileManager.default.contents(atPath: path),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        let dependencies = object["dependencies"] as? [String: Any]
        let devDependencies = object["devDependencies"] as? [String: Any]
        return dependencies?["@loopfwd/dsh-observer"] != nil
            || devDependencies?["@loopfwd/dsh-observer"] != nil
    }

    /// One synchronous installation transaction. Keeping this separate from
    /// UI and Bundle lookup makes the backup + official rollback path directly
    /// testable without invoking a real Harness profile.
    static func installObserver(
        executable: String,
        archivePath: String,
        packageName: String,
        command: (String, [String]) -> (ok: Bool, message: String)
    ) throws {
        let version = command(executable, ["--version"])
        guard version.ok,
            version.message.trimmingCharacters(in: .whitespacesAndNewlines)
                == DeepSeekHarnessSessions.supportedHarnessVersion
        else {
            throw IntegrationError.commandFailed(L10n.string("Unsupported Harness version; no profile was modified"))
        }
        let previousArchive = try installedArchive(packageName: packageName)
        let storedArchive = try persistentArchive(source: archivePath)
        let backup = try backUpProfileMetadata()
        let result = command(
            executable,
            ["plugin", "--profile", "web", "add", storedArchive]
        )
        guard result.ok else {
            let rollback = command(
                executable,
                previousArchive.map { ["plugin", "--profile", "web", "add", $0] }
                    ?? ["plugin", "--profile", "web", "remove", packageName]
            )
            throw IntegrationError.commandFailed(
                L10n.format(
                    "Install failed: %@. Rollback: %@. Backup: %@", result.message,
                    rollback.ok ? L10n.string("completed") : L10n.format("failed: %@", rollback.message),
                    backup ?? L10n.string("profile did not exist"))
            )
        }
    }

    /// Replacing an observer must not uninstall the previous working version
    /// on failure. Resolve its existing local archive before changing anything;
    /// if it cannot be restored, refuse the replacement with the profile intact.
    private static func installedArchive(packageName: String) throws -> String? {
        let manager = FileManager.default
        let path = profileDirectory + "/package.json"
        guard manager.fileExists(atPath: path) else { return nil }
        let attributes = try manager.attributesOfItem(atPath: path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
            (attributes[.size] as? NSNumber)?.intValue ?? Int.max <= 1024 * 1024,
            let object = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path)))
                as? [String: Any]
        else { throw CocoaError(.fileReadCorruptFile) }
        for key in ["dependencies", "devDependencies"] {
            guard let raw = object[key] else { continue }
            guard let dependencies = raw as? [String: Any] else { throw CocoaError(.fileReadCorruptFile) }
            guard let installed = dependencies[packageName] else { continue }
            if let reference = installed as? String, reference.hasPrefix("file:") {
                let local = String(reference.dropFirst(5))
                let archive = (local.hasPrefix("/") ? local : profileDirectory + "/" + local) as NSString
                let candidate = archive.standardizingPath
                if !local.isEmpty, let attributes = try? manager.attributesOfItem(atPath: candidate),
                    attributes[.type] as? FileAttributeType == .typeRegular,
                    manager.isReadableFile(atPath: candidate)
                {
                    return candidate
                }
            }
            throw IntegrationError.commandFailed(
                L10n.string("Previous Observer archive is unavailable; no profile was modified"))
        }
        return nil
    }

    /// pnpm retains a file: dependency on the archive. Keep it outside the App
    /// so moving/upgrading LoopFwd cannot break a later Harness restart. The
    /// content-addressed name also preserves the prior version for recovery.
    private static func persistentArchive(source: String) throws -> String {
        let manager = FileManager.default
        let attributes = try manager.attributesOfItem(atPath: source)
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: source))
        defer { try? handle.close() }
        let maximumBytes = 16 * 1024 * 1024
        let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        guard !data.isEmpty, data.count <= maximumBytes else { throw CocoaError(.fileReadCorruptFile) }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let ownedRoot = dshRoot + "/integrations/loopfwd"
        let directory = ownedRoot + "/bundles"
        for path in [ownedRoot, directory] {
            if let existing = try? manager.attributesOfItem(atPath: path) {
                guard existing[.type] as? FileAttributeType == .typeDirectory,
                    (existing[.ownerAccountID] as? NSNumber)?.uint32Value == getuid()
                else { throw CocoaError(.fileWriteNoPermission) }
            } else {
                try manager.createDirectory(
                    atPath: path, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            }
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
        }
        let target = directory + "/observer-\(digest).tgz"
        if let existing = try? manager.attributesOfItem(atPath: target) {
            guard existing[.type] as? FileAttributeType == .typeRegular,
                (existing[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
                (existing[.size] as? NSNumber)?.intValue == data.count,
                try Data(contentsOf: URL(fileURLWithPath: target)) == data
            else { throw CocoaError(.fileReadCorruptFile) }
        } else {
            try data.write(to: URL(fileURLWithPath: target), options: .atomic)
        }
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target)
        return target
    }

    @discardableResult
    private static func backUpProfileMetadata() throws -> String? {
        let manager = FileManager.default
        guard manager.fileExists(atPath: profileDirectory) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let backup = dshRoot + "/backups/loopfwd/" + formatter.string(from: Date()) + "-" + UUID().uuidString
        try manager.createDirectory(
            atPath: backup, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        for name in ["package.json", "pnpm-lock.yaml", "cordis.patch.yml", "pnpm-workspace.yaml"] {
            let source = profileDirectory + "/" + name
            guard manager.fileExists(atPath: source) else { continue }
            try manager.copyItem(atPath: source, toPath: backup + "/" + name)
        }
        return backup
    }

    private static func run(_ executable: String, _ arguments: [String]) -> (ok: Bool, message: String) {
        let result = BoundedProcess.run(executable, arguments, timeout: 45, maximumBytes: 256 * 1024)
        let text = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return (result.succeeded, result.timedOut ? L10n.string("Command timed out") : String(text.suffix(320)))
    }

    private enum IntegrationError: LocalizedError {
        case commandFailed(String)
        var errorDescription: String? {
            switch self {
            case .commandFailed(let message):
                return message.isEmpty ? L10n.string("dsh plugin command failed") : message
            }
        }
    }
}
