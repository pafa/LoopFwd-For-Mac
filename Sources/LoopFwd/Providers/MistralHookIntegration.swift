import AppKit
import Foundation
import CryptoKit
import Darwin

/// Explicit settings actions only. Provider parsing/transaction lives in the
/// bundled helper and runs in the selected Vibe installation's Python runtime.
@MainActor
final class MistralHookIntegration: ObservableObject {
    static let shared = MistralHookIntegration()
    @Published var busy = false
    @Published var installed = false
    @Published var message = L10n.string("Select a Vibe home folder to configure the observer")
    @Published var backup: URL?
    private let homeKey = "mistralObserver.home"
    private let nodeKey = "mistralObserver.node"

    var configURL: URL? {
        UserDefaults.standard.string(forKey: homeKey).map {
            URL(fileURLWithPath: $0).appendingPathComponent("hooks.toml")
        }
    }

    func refresh() {
        guard let configURL, let data = Self.readPrefix(configURL, limit: 1024 * 1024),
            let text = String(data: data, encoding: .utf8)
        else { installed = false; return }
        installed = text.contains("# BEGIN LOOPFWD MISTRAL OBSERVER v1 ")
    }

    func install() {
        guard !busy else { return }
        guard let cli = AgentKind.mistral.installedCLIPath else {
            message = L10n.string("Choose the official Vibe CLI in Agents first")
            return
        }
        let panel = NSOpenPanel()
        panel.title = L10n.string("Select the VIBE_HOME folder")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL =
            configURL?.deletingLastPathComponent() ?? URL(fileURLWithPath: NSHomeDirectory() + "/.vibe")
        guard panel.runModal() == .OK, let home = panel.url else { return }
        let node = findNode() ?? chooseNode()
        guard let node else { return }
        UserDefaults.standard.set(home.path, forKey: homeKey)
        UserDefaults.standard.set(node, forKey: nodeKey)
        perform("install", cli: cli, node: node, config: home.appendingPathComponent("hooks.toml"))
    }

    func remove() {
        guard !busy, let configURL else { return }
        busy = true
        Task {
            let result = await Task.detached { Result { try Self.removeConfiguration(at: configURL) } }.value
            switch result {
            case .success(let directory):
                backup = directory
                message = L10n.string("Observer removed. Backups and private script copies are retained.")
            case .failure:
                backup = configURL.deletingLastPathComponent().appendingPathComponent(".loopfwd-observer")
                message = L10n.string(
                    "Observer configuration failed. Review the current settings and available backups.")
            }
            busy = false
            refresh()
        }
    }

    private func perform(_ operation: String, cli: String, node: String?, config: URL) {
        guard let helper = Bundle.main.url(forResource: "LoopFwdInstallMistral", withExtension: "py"),
            let collector = Bundle.main.url(forResource: "LoopFwdObserveHook", withExtension: "mjs"),
            let header = Self.readPrefix(URL(fileURLWithPath: cli).resolvingSymlinksInPath(), limit: 4096),
            let first = String(data: header, encoding: .utf8)?.split(separator: "\n").first,
            first.hasPrefix("#!/"),
            FileManager.default.isExecutableFile(atPath: String(first.dropFirst(2)))
        else { message = L10n.string("A Python-based Vibe 2.25.0 installation is required"); return }
        let python = String(first.dropFirst(2))
        busy = true
        message = L10n.string("Checking and backing up observer configuration…")
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                if let node {
                    let check = BoundedProcess.run(node, ["--version"], timeout: 2, maximumBytes: 1024)
                    guard check.succeeded,
                        let major = Int(
                            check.output.trimmingCharacters(in: .whitespacesAndNewlines).dropFirst().split(
                                separator: "."
                            ).first ?? ""), major >= 24
                    else {
                        return BoundedProcess.Result(
                            output: "", status: nil, timedOut: false, exceededOutputLimit: false)
                    }
                }
                var args = [helper.path, operation, "--config", config.path]
                if let node { args += ["--node", node, "--collector", collector.path] }
                return BoundedProcess.run(python, args, timeout: 8, maximumBytes: 16 * 1024)
            }.value
            let object = (try? JSONSerialization.jsonObject(with: Data(result.output.utf8))) as? [String: Any]
            if let path = object?["backupPath"] as? String { backup = URL(fileURLWithPath: path) }
            if result.succeeded, object?["ok"] as? Bool == true {
                message = L10n.string(
                    operation == "install"
                        ? "Observer installed. Restart Vibe to load it."
                        : "Observer removed. Backups and private script copies are retained.")
            } else {
                let directory = config.deletingLastPathComponent().appendingPathComponent(".loopfwd-observer")
                if FileManager.default.fileExists(atPath: directory.path) { backup = directory }
                message = L10n.string(
                    result.timedOut
                        ? "Configuration outcome is uncertain. Review the current settings and backups."
                        : "Observer configuration failed. Review the current settings and available backups.")
                if let code = object?["code"] as? String { message += " (\(code))" }
            }
            busy = false
            refresh()
        }
    }

    /// Removal must remain available after Vibe and Python have been uninstalled.
    nonisolated static func removingBlock(from data: Data) throws -> Data {
        let begin = "# BEGIN LOOPFWD MISTRAL OBSERVER v1 "
        let end = "# END LOOPFWD MISTRAL OBSERVER v1\n"
        func invalid() -> NSError { NSError(domain: "LoopFwdHook", code: 1) }
        guard let text = String(data: data, encoding: .utf8) else { throw invalid() }
        if !text.contains(begin) && !text.contains(end.trimmingCharacters(in: .newlines)) { return data }
        guard text.components(separatedBy: begin).count == 2,
            text.components(separatedBy: end.trimmingCharacters(in: .newlines)).count == 2,
            let start = text.range(of: begin), start.lowerBound != text.startIndex,
            text[text.index(before: start.lowerBound)] == "\n",
            let newline = text[start.upperBound...].firstIndex(of: "\n"),
            let finish = text.range(of: end, range: newline..<text.endIndex)
        else { throw invalid() }
        let body = text[text.index(after: newline)..<finish.lowerBound]
        let digest = SHA256.hash(data: Data(body.utf8)).map { String(format: "%02x", $0) }.joined()
        guard text[start.upperBound..<newline] == digest else { throw invalid() }
        let before = text[..<text.index(before: start.lowerBound)]
        let after = text[finish.upperBound...]
        let separator =
            !before.isEmpty && !after.isEmpty && !before.hasSuffix("\n") && !after.hasPrefix("\n") ? "\n" : ""
        return Data((before + separator + after).utf8)
    }

    nonisolated static func removeConfiguration(at config: URL) throws -> URL? {
        let manager = FileManager.default
        let attrs = try manager.attributesOfItem(atPath: config.path)
        guard attrs[.type] as? FileAttributeType == .typeRegular,
            (attrs[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
            (attrs[.size] as? NSNumber)?.intValue ?? Int.max <= 1024 * 1024
        else { throw NSError(domain: "LoopFwdHook", code: 2) }
        let original = try Data(contentsOf: config)
        let updated = try removingBlock(from: original)
        guard updated != original else { return nil }
        let root = config.deletingLastPathComponent().appendingPathComponent(".loopfwd-observer")
        if manager.fileExists(atPath: root.path) {
            let attrs = try manager.attributesOfItem(atPath: root.path)
            guard attrs[.type] as? FileAttributeType == .typeDirectory,
                (attrs[.ownerAccountID] as? NSNumber)?.uint32Value == getuid()
            else { throw NSError(domain: "LoopFwdHook", code: 3) }
        } else {
            try manager.createDirectory(
                at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        let lock = open(root.appendingPathComponent("install.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard lock >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { close(lock) }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        guard try Data(contentsOf: config) == original else { throw NSError(domain: "LoopFwdHook", code: 4) }
        let backup = root.appendingPathComponent("backup-" + UUID().uuidString)
        try manager.createDirectory(
            at: backup, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try writePrivate(original, to: backup.appendingPathComponent("hooks.toml"))
        guard try Data(contentsOf: config) == original else { throw NSError(domain: "LoopFwdHook", code: 4) }
        try writePrivate(updated, to: config)
        guard try Data(contentsOf: config) == updated else { throw NSError(domain: "LoopFwdHook", code: 5) }
        return backup
    }

    /// Keep temporary configuration bytes private before the atomic replacement.
    nonisolated private static func writePrivate(_ data: Data, to destination: URL) throws {
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".loopfwd-" + UUID().uuidString)
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close(); unlink(temporary.path) }
        try handle.write(contentsOf: data)
        try handle.synchronize()
        guard rename(temporary.path, destination.path) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }

    private func findNode() -> String? {
        let directories = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let choices =
            [UserDefaults.standard.string(forKey: nodeKey)].compactMap { $0 }
            + (directories + ["/opt/homebrew/bin", "/usr/local/bin"]).map { $0 + "/node" }
        return choices.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private func chooseNode() -> String? {
        let panel = NSOpenPanel()
        panel.title = L10n.string("Select Node.js 24 or newer")
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url?.path : nil
    }

    private static func readPrefix(_ url: URL, limit: Int) -> Data? {
        guard let file = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? file.close() }
        return try? file.read(upToCount: limit)
    }
}
