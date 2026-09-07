import Foundation

/// Caches only pure command classification, never session identity or control
/// authority. Nil results matter: most rows in a process table are not agents.
struct ProcessClassificationCache {
    private struct Entry {
        let command: String
        let tty: String?
        let kind: AgentKind?
    }
    private var entries: [Int32: Entry] = [:]

    mutating func classify(pid: Int32, command: String, tty: String?, detect: () -> AgentKind?) -> AgentKind? {
        if let entry = entries[pid], entry.command == command, entry.tty == tty { return entry.kind }
        let kind = detect()
        // Do not keep unusually large argv strings alive between polls.
        if command.utf8.count <= 16 * 1024 {
            entries[pid] = Entry(command: command, tty: tty, kind: kind)
        } else {
            entries.removeValue(forKey: pid)
        }
        return kind
    }

    mutating func retain(livePIDs: Set<Int32>) {
        entries = entries.filter { livePIDs.contains($0.key) }
    }
}

/// Turning a `ps` args string into the hosting app's name.
///
/// `ps` prints the executable path and its arguments space-separated, and macOS
/// application paths routinely contain spaces — `/Applications/Visual Studio
/// Code.app/Contents/MacOS/Electron`. Splitting on the first space to recover
/// the executable therefore truncates it to `/Applications/Visual`, and every
/// lookup downstream fails.
///
/// That was the live behaviour: VS Code, Cursor and Windsurf sessions all
/// resolved to no terminal app at all, so click-to-jump and inline reply
/// silently did nothing for them, and the card showed no terminal chip. iTerm
/// and Terminal worked purely because their bundle paths have no spaces. The
/// giveaway was that the `"Visual Studio Code"` rename in the old
/// `appBundleName` could never run — the string never survived the split.
enum ProcessNaming {

    struct NodeAgentEntry {
        let kind: AgentKind
        let script: String
        let package: String
        let isLauncher: Bool
    }

    /// Inspect only Node's actual script operand. Generic cli.js basenames or
    /// package paths mentioned in a prompt must never classify a process.
    static func nodeAgentEntry(_ command: String) -> NodeAgentEntry? {
        let tokens = command.split(separator: " ", maxSplits: 32)
        guard let executable = tokens.first, (String(executable) as NSString).lastPathComponent == "node" else {
            return nil
        }
        var script: String?
        for token in tokens.dropFirst() {
            if ["--expose-gc", "--enable-source-maps", "--no-warnings"].contains(token) { continue }
            if token.hasPrefix("--max-old-space-size="), let size = Int(token.dropFirst(21)), size > 0 { continue }
            guard !token.hasPrefix("-") else { return nil }
            script = String(token)
            break
        }
        guard let raw = script else { return nil }
        let basename = (raw as NSString).lastPathComponent
        guard
            raw.hasSuffix("/@qwen-code/qwen-code/cli-entry.js") || raw.hasSuffix("/@qwen-code/qwen-code/cli.js")
                || raw.hasSuffix("/@google/gemini-cli/bundle/gemini.js") || ["qwen", "gemini"].contains(basename)
        else { return nil }
        let path = URL(fileURLWithPath: raw).resolvingSymlinksInPath().path
        if path.hasSuffix("/@qwen-code/qwen-code/cli-entry.js") || path.hasSuffix("/@qwen-code/qwen-code/cli.js") {
            return .init(
                kind: .qwen, script: path, package: (path as NSString).deletingLastPathComponent,
                isLauncher: path.hasSuffix("/cli-entry.js"))
        }
        if path.hasSuffix("/@google/gemini-cli/bundle/gemini.js") {
            return .init(
                kind: .gemini, script: path, package: (path as NSString).deletingLastPathComponent, isLauncher: false)
        }
        return nil
    }

    /// The official entrypoints relaunch the TUI. Same brand alone is not
    /// proof: require the same installed package and the provider's child flag.
    static func isNodeAgentRelaunch(
        parentPID: Int32, parentCommand: String, childCommand: String,
        parentEnvironment: [String: String], childEnvironment: [String: String]
    ) -> Bool {
        guard let parent = nodeAgentEntry(parentCommand), let child = nodeAgentEntry(childCommand),
            parent.kind == child.kind, parent.package == child.package
        else { return false }
        if parent.kind == .qwen, parent.isLauncher, !child.isLauncher {
            return childEnvironment["QWEN_CODE_LAUNCHER_PID"] == String(parentPID)
        }
        guard !parent.isLauncher, !child.isLauncher, parent.script == child.script else { return false }
        let key = parent.kind == .qwen ? "QWEN_CODE_NO_RELAUNCH" : "GEMINI_CLI_NO_RELAUNCH"
        return (parentEnvironment[key] ?? "").isEmpty && childEnvironment[key] == "true"
    }

    static func isCopilotNativeLaunch(childCommand: String, parentCommand: String?) -> Bool {
        guard executableBasename(childCommand) == "copilot", let parentCommand,
            executableBasename(parentCommand) == "node"
        else { return false }
        let tokens = parentCommand.split(separator: " ", maxSplits: 2)
        guard tokens.count > 1 else { return false }
        return (String(tokens[1]) as NSString).lastPathComponent == "copilot"
    }

    static func retainsAgentProcess(
        pid: Int32, kind: AgentKind, parentPID: Int32, parentKind: AgentKind?, launchers: Set<Int32>
    ) -> Bool {
        guard !launchers.contains(pid) else { return false }
        // A nested Node CLI can own an independent session. Only the proven
        // relaunch relationship above may remove Qwen/Gemini processes.
        if kind == .qwen || kind == .gemini { return true }
        return parentKind != kind || launchers.contains(parentPID)
    }

    /// Names macOS reports differently from how the UI should show them.
    static let displayNames: [String: String] = [
        "Visual Studio Code": "VS Code",
        "Code": "VS Code",
        "Code - Insiders": "VS Code",
        "iTerm2": "iTerm",
    ]

    /// GUI hosts LoopFwd can honestly treat as a terminal destination. Parent
    /// chains often end in an unrelated launcher app (for example ChatGPT or
    /// Finder); exposing those as a terminal chip makes click-to-jump lie.
    private static let terminalHosts: Set<String> = [
        "Terminal", "iTerm", "WezTerm", "kitty", "Ghostty", "Warp",
        "Alacritty", "VS Code", "Cursor", "Windsurf", "Zed",
    ]

    /// Defense in depth for any action path that receives a stored or
    /// externally-derived terminal name. Only hosts discovered by the fixed
    /// process-name table may be activated.
    static func isSupportedTerminalHost(_ name: String) -> Bool {
        terminalHosts.contains(name)
    }

    /// The hosting `.app` bundle name in a full `ps` args string, if any.
    ///
    /// Searches the whole string rather than a space-split first token, so
    /// bundle paths containing spaces resolve. Path components are separated by
    /// `/`, and a space inside a component is part of the name, so splitting on
    /// `/` keeps "Visual Studio Code.app" intact.
    static func appBundleName(fromCommand command: String) -> String? {
        for component in command.split(separator: "/") where component.hasSuffix(".app") {
            let raw = String(component.dropLast(4))
            return displayNames[raw] ?? raw
        }
        return nil
    }

    static func terminalHostName(fromCommand command: String) -> String? {
        guard let name = appBundleName(fromCommand: command), terminalHosts.contains(name) else {
            return nil
        }
        return name
    }

    /// The executable path alone — everything up to the first argument.
    ///
    /// Only meaningful for multiplexers (tmux/screen/zellij), whose binaries
    /// live at space-free paths; it exists so their basename match is not
    /// confused by trailing arguments.
    static func executableToken(_ command: String) -> String {
        String(command.split(separator: " ").first ?? "")
    }

    /// Last path component of the executable, lowercased — used to spot
    /// terminal multiplexers in the parent chain.
    static func executableBasename(_ command: String) -> String {
        (executableToken(command) as NSString).lastPathComponent.lowercased()
    }

    /// Is this a GUI application's background helper rather than a CLI agent?
    ///
    /// `detect` already rejects an executable path inside an `.app` bundle, but
    /// Electron apps rewrite `argv[0]` to a display string, so `ps` reports no
    /// path at all:
    ///
    ///     Cursor Helper: shared-process
    ///     Cursor Helper (Plugin): extension-host (user) …
    ///
    /// The first token is then plain `Cursor`, which matches the registered
    /// alias for the cursor-agent kind — so every helper Cursor spawns was
    /// listed as a running agent. Eight ghost sessions on an idle machine with
    /// only the editor open.
    ///
    /// Require the rewritten Helper name as well as a GUI parent and no TTY.
    /// GUI applications can also launch real CLI processes directly (including
    /// an OpenCode HTTP server); their parent alone is not evidence of a helper.
    static func isGUIHelper(tty: String?, childCommand: String, parentCommand: String?) -> Bool {
        guard tty == nil, let parentCommand, parentCommand.contains(".app/") else { return false }
        let tokens = childCommand.split(separator: " ", maxSplits: 2)
        guard tokens.count > 1, !tokens[0].contains("/") else { return false }
        return tokens[1] == "Helper" || tokens[1] == "Helper:"
    }
}
