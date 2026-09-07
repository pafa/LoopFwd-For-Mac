import AppKit
import Foundation

/// Explicit setup for the supported provider Hook configuration formats.
/// No startup writes and no authority to answer provider requests.
@MainActor
final class JSONHookIntegration: ObservableObject {
    static let gemini = JSONHookIntegration(kind: .gemini, version: "0.58.0")
    static let qwen = JSONHookIntegration(kind: .qwen, version: "0.23.0")
    static let cursor = JSONHookIntegration(kind: .cursorAgent, version: "2026.09.02-c22c1a3")
    static let workbuddy = JSONHookIntegration(kind: .workbuddy, version: WorkBuddySessions.cliVersion)
    let kind: AgentKind
    let version: String
    @Published var busy = false
    @Published var installed = false
    @Published var message = L10n.string("Choose a configuration folder to set up observation")
    @Published var backup: URL?
    private var prefix: String { "jsonHookObserver.\(provider)" }
    private var provider: String {
        switch kind {
        case .gemini: return "gemini"
        case .cursorAgent: return "cursor"
        case .workbuddy: return "workbuddy"
        default: return "qwen"
        }
    }

    private init(kind: AgentKind, version: String) { self.kind = kind; self.version = version }

    private var config: URL? {
        UserDefaults.standard.string(forKey: prefix + ".config").map { URL(fileURLWithPath: $0) }
    }

    private var pendingConfig: URL? {
        UserDefaults.standard.string(forKey: prefix + ".pendingConfig").map { URL(fileURLWithPath: $0) }
    }

    var canRemove: Bool { installed || config != nil || pendingConfig != nil }

    private var actionNode: String? {
        UserDefaults.standard.string(forKey: prefix + (pendingConfig == nil ? ".node" : ".pendingNode"))
    }

    func install() {
        guard !busy else { return }
        let runtime =
            kind == .workbuddy
            ? NSWorkspace.shared.urlForApplication(withBundleIdentifier: WorkBuddySessions.bundleIdentifier)?.path
            : kind.installedCLIPath
        guard let cli = runtime else {
            message = L10n.string(
                kind == .workbuddy ? "Install WorkBuddy 5.5.3 first" : "Choose the official CLI in Agents first");
            return
        }
        let folder = NSOpenPanel()
        folder.title = L10n.string("Select the provider configuration folder")
        folder.canChooseFiles = false; folder.canChooseDirectories = true
        folder.allowsMultipleSelection = false; folder.showsHiddenFiles = true
        folder.directoryURL =
            (pendingConfig ?? config)?.deletingLastPathComponent()
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/." + provider)
        guard folder.runModal() == .OK, let directory = folder.url else { return }
        let target = directory.appendingPathComponent(kind == .cursorAgent ? "hooks.json" : "settings.json")
        if [config, pendingConfig].compactMap({ $0 }).contains(where: {
            $0.standardizedFileURL != target.standardizedFileURL
        }) {
            message = L10n.string("Remove or recover the existing observer before choosing another folder.")
            return
        }
        let choices =
            [UserDefaults.standard.string(forKey: prefix + ".node")].compactMap { $0 }
            + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { String($0) + "/node" }
            + ["/opt/homebrew/bin/node", "/usr/local/bin/node"]
        var node = choices.first { FileManager.default.isExecutableFile(atPath: $0) }
        if node == nil {
            let panel = NSOpenPanel()
            panel.title = L10n.string("Select Node.js 24 or newer")
            panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
            guard panel.runModal() == .OK else { return }
            node = panel.url?.path
        }
        guard let node else { return }
        perform("install", target: target, node: node, cli: cli)
    }

    func remove() {
        guard !busy, let target = pendingConfig ?? config, let node = actionNode else { return }
        perform("remove", target: target, node: node, cli: nil)
    }

    func refresh() {
        guard !busy, let target = pendingConfig ?? config, let node = actionNode else { return }
        perform("check", target: target, node: node, cli: nil)
    }

    private func perform(_ operation: String, target: URL, node: String, cli: String?) {
        guard
            let helper = Bundle.main.url(
                forResource: "configure-json-hooks", withExtension: "mjs", subdirectory: "LoopFwdJSONHooks"),
            let collector = Bundle.main.url(forResource: "LoopFwdObserveHook", withExtension: "mjs")
        else { message = L10n.string("Observer resources are unavailable"); return }
        busy = true
        let provider = self.provider, version = self.version, pendingPrefix = prefix
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                if let cli {
                    if provider == "workbuddy" {
                        guard WorkBuddySessions.installationCompatible(at: URL(fileURLWithPath: cli)) else {
                            return BoundedProcess.Result(
                                output: "{\"ok\":false,\"code\":\"unsupported_workbuddy_version\"}", status: 1,
                                timedOut: false, exceededOutputLimit: false)
                        }
                    } else {
                        let check = BoundedProcess.run(
                            cli, ["--version"], timeout: 5, maximumBytes: 4096,
                            removingEnvironmentKeys: [
                                "CLI_VERSION", "QWEN_CODE_HOST_UPDATE_RELAUNCH", "QWEN_CODE_RELAUNCH",
                                "QWEN_CODE_RELAUNCH_ARGS",
                                "NODE_OPTIONS", "NODE_PATH", "CURSOR_API_KEY",
                            ])
                        guard check.succeeded, check.output.trimmingCharacters(in: .whitespacesAndNewlines) == version
                        else {
                            return BoundedProcess.Result(
                                output: "{\"ok\":false,\"code\":\"unsupported_provider_version\"}", status: 1,
                                timedOut: check.timedOut, exceededOutputLimit: false)
                        }
                    }
                }
                if operation != "check" {
                    // Persist the recovery address before the helper can write.
                    // The previous successful target is left untouched even if
                    // the App/helper exits before delivering a result.
                    let defaults = UserDefaults.standard
                    defaults.set(target.path, forKey: pendingPrefix + ".pendingConfig")
                    defaults.set(node, forKey: pendingPrefix + ".pendingNode")
                    guard defaults.synchronize() else {
                        return BoundedProcess.Result(
                            output: "{\"ok\":false,\"code\":\"recovery_target_not_saved\"}", status: 1,
                            timedOut: false, exceededOutputLimit: false)
                    }
                }
                return BoundedProcess.run(
                    node,
                    [
                        helper.path, operation, "--provider", provider, "--config", target.path,
                        "--node", node, "--collector", collector.path,
                    ], timeout: 8, maximumBytes: 16384)
            }.value
            let object = (try? JSONSerialization.jsonObject(with: Data(result.output.utf8))) as? [String: Any]
            if let path = object?["backupPath"] as? String { backup = URL(fileURLWithPath: path) }
            if result.succeeded, object?["ok"] as? Bool == true {
                if operation == "install" {
                    UserDefaults.standard.set(target.path, forKey: prefix + ".config")
                    UserDefaults.standard.set(node, forKey: prefix + ".node")
                } else if operation == "remove", config?.standardizedFileURL == target.standardizedFileURL {
                    UserDefaults.standard.removeObject(forKey: prefix + ".config")
                    UserDefaults.standard.removeObject(forKey: prefix + ".node")
                }
                if operation != "check" {
                    UserDefaults.standard.removeObject(forKey: prefix + ".pendingConfig")
                    UserDefaults.standard.removeObject(forKey: prefix + ".pendingNode")
                }
                installed = object?["installed"] as? Bool == true
                message = L10n.string(
                    installed
                        ? (kind == .workbuddy
                            ? "Observer configured. Restart WorkBuddy to load the hooks."
                            : "Observer configured. Restart the CLI; workspace trust may still be required.")
                        : "Observer is not configured")
                if installed && (object?["complete"] as? Bool != true || object?["runtimeAvailable"] as? Bool != true) {
                    message = L10n.string("Observer setup is incomplete. Reinstall to repair it, or remove it.")
                }
                if object?["disabled"] as? Bool == true {
                    message = L10n.string(
                        "Hooks are disabled in the selected settings. No disable switches were changed.")
                }
                if object?["warning"] as? String == "unsupported_workbuddy_jsonc_bom" {
                    message +=
                        " · " + L10n.string("WorkBuddy cannot read this configuration's BOM. Review the settings file.")
                }
            } else {
                // Keep the last successful target. A separate recovery target
                // survives an uncertain write without redirecting the old setup.
                if operation != "check", result.timedOut || object?["backupPath"] as? String != nil {
                    UserDefaults.standard.set(target.path, forKey: prefix + ".pendingConfig")
                    UserDefaults.standard.set(node, forKey: prefix + ".pendingNode")
                }
                let directory = target.deletingLastPathComponent().appendingPathComponent(".loopfwd-json-hooks")
                if FileManager.default.fileExists(atPath: directory.path) { backup = directory }
                message = L10n.string(
                    result.timedOut
                        ? "Configuration outcome is uncertain. Review the current settings and backups."
                        : "Observer configuration failed. Review the current settings and available backups.")
                if let code = object?["code"] as? String { message += " (\(code))" }
            }
            busy = false
        }
    }
}
