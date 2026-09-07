import AppKit
import Foundation

/// Explicit configuration of Kimi's lifecycle hooks. No login, model calls or
/// automatic changes; installation and uncertain results retain a recovery path.
@MainActor
final class KimiHookIntegration: ObservableObject {
    static let shared = KimiHookIntegration()
    @Published var busy = false
    @Published var installed = false
    @Published var message = L10n.string("Choose a configuration folder to set up observation")
    @Published var backup: URL?
    private let prefix = "kimiObserver"
    private var config: URL? {
        UserDefaults.standard.string(forKey: prefix + ".config").map { URL(fileURLWithPath: $0) }
    }
    var canRemove: Bool { config != nil }

    func install() {
        guard !busy else { return }
        guard let cli = AgentKind.kimi.installedCLIPath else {
            message = L10n.string("Choose the official CLI in Agents first"); return
        }
        let folder = NSOpenPanel()
        folder.title = L10n.string("Select the KIMI_CODE_HOME folder")
        folder.canChooseDirectories = true; folder.canChooseFiles = false
        folder.allowsMultipleSelection = false; folder.showsHiddenFiles = true
        folder.directoryURL =
            config?.deletingLastPathComponent() ?? URL(fileURLWithPath: NSHomeDirectory() + "/.kimi-code")
        guard folder.runModal() == .OK, let home = folder.url else { return }
        let target = home.appendingPathComponent("config.toml")
        if let config, config.standardizedFileURL != target.standardizedFileURL {
            message = L10n.string("Remove or recover the existing observer before choosing another folder."); return
        }
        guard let node = runtime(name: "node", title: "Select Node.js 24 or newer"),
            let python = runtime(name: "python3", title: "Select Python 3.11 or newer")
        else { return }
        perform("install", target: target, python: python, node: node, cli: cli)
    }

    func remove() {
        guard !busy, let config,
            let python = runtime(name: "python3", title: "Select Python 3.11 or newer")
        else { return }
        perform("remove", target: config, python: python, node: nil, cli: nil)
    }

    func refresh() {
        // Read-only startup check. Runtime validation happens only on an action.
        guard let config, let handle = try? FileHandle(forReadingFrom: config) else { installed = false; return }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 1024 * 1024 + 1), data.count <= 1024 * 1024,
            let text = String(data: data, encoding: .utf8)
        else { installed = false; return }
        installed = text.contains("# BEGIN LOOPFWD KIMI OBSERVER v1 ")
        backup = config.deletingLastPathComponent().appendingPathComponent(".loopfwd-observer")
    }

    private func runtime(name: String, title: String) -> String? {
        let candidates =
            [UserDefaults.standard.string(forKey: prefix + "." + name)].compactMap { $0 }
            + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { String($0) + "/" + name }
            + ["/opt/homebrew/bin/" + name, "/usr/local/bin/" + name]
        let panel = NSOpenPanel()
        panel.title = L10n.string(title); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        // Suggest the saved runtime, but always allow choosing a replacement.
        // An older executable first on PATH must not trap every retry/removal.
        if let value = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            panel.directoryURL = URL(fileURLWithPath: value).deletingLastPathComponent()
            panel.nameFieldStringValue = (value as NSString).lastPathComponent
        }
        return panel.runModal() == .OK ? panel.url?.path : nil
    }

    private func perform(_ operation: String, target: URL, python: String, node: String?, cli: String?) {
        guard let helper = Bundle.main.url(forResource: "LoopFwdInstallMistral", withExtension: "py"),
            let collector = Bundle.main.url(forResource: "LoopFwdObserveHook", withExtension: "mjs")
        else {
            message = L10n.string("Observer resources are unavailable"); return
        }
        busy = true
        let key = prefix
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                let pythonCheck = BoundedProcess.run(
                    python, ["-I", "-c", "import sys,tomllib; assert sys.version_info >= (3,11)"], timeout: 2,
                    maximumBytes: 1024)
                guard pythonCheck.succeeded else { return pythonCheck }
                if let node {
                    let check = BoundedProcess.run(
                        node, ["--version"], timeout: 2, maximumBytes: 1024,
                        removingEnvironmentKeys: ["NODE_OPTIONS", "NODE_PATH"])
                    guard check.succeeded,
                        let major = Int(
                            check.output.trimmingCharacters(in: .whitespacesAndNewlines).dropFirst().split(
                                separator: "."
                            ).first ?? ""), major >= 24
                    else {
                        return BoundedProcess.Result(
                            output: "{\"code\":\"node_24_required\"}", status: 1, timedOut: false,
                            exceededOutputLimit: false)
                    }
                }
                // One target only: retain it before any write, including timeout
                // or App termination. Removal does not need the Kimi installation.
                let defaults = UserDefaults.standard
                defaults.set(target.path, forKey: key + ".config")
                defaults.set(python, forKey: key + ".python3")
                if let node { defaults.set(node, forKey: key + ".node") }
                guard defaults.synchronize() else {
                    return BoundedProcess.Result(
                        output: "{\"code\":\"recovery_target_not_saved\"}", status: 1, timedOut: false,
                        exceededOutputLimit: false)
                }
                var args = ["-I", helper.path, operation, "--provider", "kimi", "--config", target.path]
                if let node { args += ["--node", node, "--collector", collector.path] }
                if let cli { args += ["--cli", cli] }
                return BoundedProcess.run(python, args, timeout: 8, maximumBytes: 16 * 1024)
            }.value
            let object = (try? JSONSerialization.jsonObject(with: Data(result.output.utf8))) as? [String: Any]
            if result.succeeded, object?["ok"] as? Bool == true {
                if operation == "remove" { UserDefaults.standard.removeObject(forKey: prefix + ".config") }
                installed = object?["installed"] as? Bool == true
                message = L10n.string(
                    installed
                        ? "Observer configured. Restart the CLI; workspace trust may still be required."
                        : "Observer is not configured")
            } else {
                message = L10n.string(
                    result.timedOut
                        ? "Configuration outcome is uncertain. Review the current settings and backups."
                        : "Observer configuration failed. Review the current settings and available backups.")
                if let code = object?["code"] as? String {
                    message += " (\(code))"
                } else if !result.succeeded {
                    message += " (Python 3.11+)"
                }
            }
            if let path = object?["backupPath"] as? String {
                backup = URL(fileURLWithPath: path)
            } else if FileManager.default.fileExists(
                atPath: target.deletingLastPathComponent().appendingPathComponent(".loopfwd-observer").path)
            {
                backup = target.deletingLastPathComponent().appendingPathComponent(".loopfwd-observer")
            }
            busy = false
        }
    }
}
