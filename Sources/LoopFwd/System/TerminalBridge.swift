import AppKit
import ApplicationServices
import Foundation

/// Sends text to an agent's terminal session and jumps to it, targeting the
/// exact tab/pane via the process's tty. iTerm and Terminal have precise
/// AppleScript APIs; tmux uses send-keys. Terminal.app can select the exact tab
/// by tty, then needs Accessibility to type into an interactive TUI.
enum TerminalBridge {

    static var hasAccessibilityAccess: Bool { AXIsProcessTrusted() }

    static func hasReturnHelper(for app: String) -> Bool {
        switch app {
        case "tmux": return tmuxPath != nil
        case "WezTerm": return weztermPath != nil
        case "kitty": return kittenPath != nil
        default: return true
        }
    }

    /// Terminal.app has no API for typing into an already-running interactive
    /// TUI. Ask only after an explicit user action (reply / approval / settings
    /// button), never during startup or passive discovery.
    @discardableResult
    static func requestAccessibilityAccess() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func needsAccessibilityAccess(for agent: AgentSession) -> Bool {
        agent.terminalApp == "Terminal" && !hasAccessibilityAccess
    }

    /// Whether this host has a control path that can address one exact session.
    /// App activation alone is not enough for sending user text: it can land in
    /// the wrong tab when several agents share a terminal.
    static func canSend(to agent: AgentSession) -> Bool {
        switch agent.terminalApp {
        case "tmux":
            return agent.tty != nil && tmuxPath != nil
        case "iTerm", "Terminal":
            return agent.tty != nil
        case "WezTerm":
            return agent.tty != nil && weztermPath != nil
        case "kitty":
            return kittenPath != nil
        default:
            return false
        }
    }

    @discardableResult
    static func send(text: String, to agent: AgentSession) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, controlProcessStillMatches(agent) else { return false }
        let dev = agent.tty.map { "/dev/\($0)" }

        switch agent.terminalApp {
        case "tmux":
            return tmuxSend(text: trimmed, tty: dev)
        case "iTerm":
            guard let dev else { return false }
            return osascript(
                """
                on run argv
                    set targetTTY to item 1 of argv
                    set userText to item 2 of argv
                    tell application "iTerm"
                        repeat with w in windows
                            repeat with t in tabs of w
                                repeat with s in sessions of t
                                    if tty of s is targetTTY then
                                        tell s to write text userText
                                        return
                                    end if
                                end repeat
                            end repeat
                        end repeat
                        error "LoopFwd session not found" number 1001
                    end tell
                end run
                """,
                arguments: [dev, trimmed])
        case "Terminal":
            // Terminal's `do script` API runs a shell command; it is not an
            // input API for an already-running interactive TUI. It can report
            // success while Codex receives nothing (or queue the command for
            // the shell after Codex exits). Select the exact tab first, then
            // deliver keyboard input only when Accessibility is already
            // granted. Otherwise fail closed and leave the user's text intact.
            guard hasAccessibilityAccess else {
                requestAccessibilityAccess()
                return false
            }
            guard dev != nil, jump(to: agent) else { return false }
            return synthesize(text: trimmed, pressReturn: true)
        case "WezTerm":
            guard let dev, let wez = weztermPath, let pane = weztermPaneId(dev: dev) else { return false }
            return succeeds(wez, ["cli", "send-text", "--pane-id", pane, "--no-paste", trimmed + "\n"])
        case "kitty":
            guard let kitten = kittenPath, let pid = agent.processID,
                let win = kittyWindowId(pid: pid)
            else { return false }
            return succeeds(kitten, ["@", "send-text", "--match", "id:\(win)", trimmed + "\n"])
        case .some, nil:
            // There is no proven exact-pane API for this host. Never type into
            // whichever window happens to be frontmost.
            return false
        }
    }

    @discardableResult
    static func jump(to agent: AgentSession) -> Bool {
        let success = performJump(to: agent)
        if !success {
            let reason = agent.returnTarget.unavailableReason ?? "The selected task target could not be reached"
            OperationalDiagnostics.shared.recordReturnFailure(
                "\(agent.kind.rawValue)/\(agent.surfaceID.rawValue): \(reason)"
            )
        }
        return success
    }

    /// User-initiated execution never waits for terminal helpers on the UI thread.
    static func jump(to agent: AgentSession, completion: @escaping (ReturnExecutionResult) -> Void) {
        let resolution = ReturnResolver.resolve(agent)
        guard resolution.reason == nil else {
            completion(.init(opened: false, exact: false, reason: resolution.reason))
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let success = jump(to: agent)
            DispatchQueue.main.async {
                let exact: Bool
                if case .exact = resolution.capability { exact = true } else { exact = false }
                if success && exact {
                    AgentNotificationRouter.shared.markHandled(sessionID: agent.id)
                    OutcomePresentation.shared.dismiss(agent)
                }
                completion(
                    .init(
                        opened: success, exact: success && exact,
                        reason: success ? nil : "The target expired, permission was denied, or the return timed out"))
            }
        }
    }

    private static func performJump(to agent: AgentSession) -> Bool {
        guard ReturnResolver.resolve(agent).reason == nil else { return false }
        if case .web(let url) = agent.returnTarget {
            guard DeepSeekHarnessSessions.safeLoopbackURL(url.absoluteString) != nil,
                let pid = agent.processID,
                let port = url.port,
                let expectedStart = agent.processStartedAt,
                run("/bin/ps", ["-p", String(pid), "-o", "lstart="]).trimmingCharacters(in: .whitespacesAndNewlines)
                    == expectedStart,
                AgentScanner.detect(args: run("/bin/ps", ["-p", String(pid), "-o", "args="])) == .deepseek,
                OpenCodeSessions.listeningPorts(pid: pid).contains(port)
            else { return false }
            return NSWorkspace.shared.open(url)
        }
        if case .application(let bundleIdentifier, _) = agent.returnTarget {
            guard
                let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
            else { return false }
            return NSWorkspace.shared.open(app)
        }
        if case .applicationLink(let bundleIdentifier, _, let url) = agent.returnTarget {
            guard
                let applicationURL = NSWorkspace.shared.urlForApplication(toOpen: url),
                Bundle(url: applicationURL)?.bundleIdentifier == bundleIdentifier
            else { return false }
            return NSWorkspace.shared.open(url)
        }
        if case .unavailable = agent.returnTarget { return false }
        let dev = agent.tty.map { "/dev/\($0)" }

        switch agent.terminalApp {
        case "Codex":
            guard
                let app = NSRunningApplication.runningApplications(
                    withBundleIdentifier: "com.openai.codex"
                ).first
            else { return false }
            return app.activate(options: [.activateAllWindows])
        case "OpenCode":
            guard
                let app = NSRunningApplication.runningApplications(
                    withBundleIdentifier: "ai.opencode.desktop"
                ).first
            else { return false }
            return app.activate(options: [.activateAllWindows])
        case "tmux":
            guard let dev else { return false }
            return tmuxSelectPane(tty: dev)
        case "iTerm":
            guard let dev else { return false }
            return osascript(
                """
                on run argv
                    set targetTTY to item 1 of argv
                    tell application "iTerm"
                        activate
                        repeat with w in windows
                            repeat with t in tabs of w
                                repeat with s in sessions of t
                                    if tty of s is targetTTY then
                                        select w
                                        select t
                                        select s
                                        return
                                    end if
                                end repeat
                            end repeat
                        end repeat
                        error "LoopFwd session not found" number 1001
                    end tell
                end run
                """,
                arguments: [dev])
        case "Terminal":
            guard let dev else { return false }
            return osascript(
                """
                on run argv
                    set targetTTY to item 1 of argv
                    tell application "Terminal"
                        activate
                        repeat with w in windows
                            repeat with t in tabs of w
                                if tty of t is targetTTY then
                                    set selected tab of w to t
                                    set index of w to 1
                                    return
                                end if
                            end repeat
                        end repeat
                        error "LoopFwd session not found" number 1001
                    end tell
                end run
                """,
                arguments: [dev])
        case "WezTerm":
            guard let dev, let wez = weztermPath, let pane = weztermPaneId(dev: dev) else { return false }
            let selected = succeeds(wez, ["cli", "activate-pane", "--pane-id", pane])
            let activated = osascript("tell application \"WezTerm\" to activate")
            return selected && activated
        case "kitty":
            guard let kitten = kittenPath, let pid = agent.processID,
                let win = kittyWindowId(pid: pid)
            else { return false }
            let selected = succeeds(kitten, ["@", "focus-window", "--match", "id:\(win)"])
            let activated = osascript("tell application \"kitty\" to activate")
            return selected && activated
        case .some(let app):
            guard ProcessNaming.isSupportedTerminalHost(app) else { return false }
            return osascript("tell application \"\(app)\" to activate")
        case nil:
            return false
        }
    }

    /// Send a single raw key (no Enter) to the agent's session — used to
    /// answer Claude Code permission prompts ("1"/"2"/"3").
    @discardableResult
    static func sendKey(_ key: String, to agent: AgentSession) -> Bool {
        guard controlProcessStillMatches(agent) else { return false }
        let dev = agent.tty.map { "/dev/\($0)" }

        switch agent.terminalApp {
        case "tmux":
            guard let tmux = tmuxPath, let pane = tmuxPane(tty: dev) else { return false }
            return succeeds(tmux, ["send-keys", "-t", pane, "-l", key])
        case "iTerm":
            guard let dev else { return false }
            return osascript(
                """
                on run argv
                    set targetTTY to item 1 of argv
                    set userText to item 2 of argv
                    tell application "iTerm"
                        repeat with w in windows
                            repeat with t in tabs of w
                                repeat with s in sessions of t
                                    if tty of s is targetTTY then
                                        tell s to write text userText newline NO
                                        return
                                    end if
                                end repeat
                            end repeat
                        end repeat
                        error "LoopFwd session not found" number 1001
                    end tell
                end run
                """,
                arguments: [dev, key])
        case "WezTerm":
            guard let dev, let wez = weztermPath, let pane = weztermPaneId(dev: dev) else { return false }
            return succeeds(wez, ["cli", "send-text", "--pane-id", pane, "--no-paste", key])
        case "kitty":
            guard let kitten = kittenPath, let pid = agent.processID,
                let win = kittyWindowId(pid: pid)
            else { return false }
            return succeeds(kitten, ["@", "send-text", "--match", "id:\(win)", key])
        case "Terminal":
            guard hasAccessibilityAccess else {
                requestAccessibilityAccess()
                return false
            }
            guard jump(to: agent) else { return false }
            return synthesize(text: key, pressReturn: false)
        case .some, nil:
            // A raw approval key must never land in whichever editor or
            // terminal window happens to be frontmost.
            return false
        }
    }

    /// A matching TTY alone survives an exited agent and can point at a shell
    /// or a replacement process. Revalidate birth, provider and TTY before any
    /// input or permission prompt. Observation never authorizes input itself.
    private static func controlProcessStillMatches(_ agent: AgentSession) -> Bool {
        guard let pid = agent.processID, pid > 0 else { return false }
        let query = BoundedProcess.run("/bin/ps", ["-p", String(pid), "-o", "lstart=,tty=,args="], timeout: 1)
        return controlProcessMatches(agent, query: query)
    }

    static func controlProcessMatches(_ agent: AgentSession, query: BoundedProcess.Result) -> Bool {
        guard query.succeeded, let birth = agent.processStartedAt, !birth.isEmpty,
            let tty = agent.tty, tty != "??"
        else { return false }
        let parts = query.output.split(maxSplits: 6, whereSeparator: \.isWhitespace)
        guard parts.count == 7 else { return false }
        return parts.prefix(5).joined(separator: " ")
            == birth.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            && String(parts[5]) == tty
            && AgentScanner.detect(args: String(parts[6]).trimmingCharacters(in: .whitespacesAndNewlines), tty: tty)
                == agent.kind
    }

    /// Is the given terminal/editor app currently frontmost? Names are fuzzy —
    /// our detector says "iTerm"/"VS Code" while macOS reports "iTerm2"/"Code".
    static func isFrontmost(appNamed name: String?) -> Bool {
        matches(appNamed: name, frontmost: NSWorkspace.shared.frontmostApplication?.localizedName)
    }

    /// Notification suppression is deliberately stricter than app activation.
    /// Today only Terminal and iTerm expose enough information to prove that
    /// the exact TTY is selected. A frontmost provider app or another terminal
    /// tab must not swallow a completion/attention notification.
    static func visibleExactSessionIDs(_ sessions: [AgentSession], completion: @escaping (Set<String>) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let visible = visibleExactSessionIDs(sessions)
            DispatchQueue.main.async { completion(visible) }
        }
    }

    /// One passive query per batch, not two blocking queries per task. A
    /// denied permission is an unknown result, never an authorization prompt.
    private static func visibleExactSessionIDs(_ sessions: [AgentSession]) -> Set<String> {
        guard let frontmost = NSWorkspace.shared.frontmostApplication,
            let bundleID = frontmost.bundleIdentifier
        else { return [] }
        let app: String
        switch bundleID {
        case "com.apple.Terminal": app = "Terminal"
        case "com.googlecode.iterm2": app = "iTerm"
        default: return []
        }
        let candidates = sessions.filter { $0.terminalApp == app }
        guard !candidates.isEmpty else { return [] }
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
        guard
            AEDeterminePermissionToAutomateTarget(
                target.aeDesc, typeWildCard, typeWildCard, false) == noErr
        else { return [] }
        let selectedTTY = app == "Terminal" ? selectedTerminalTTY() : selectedITermTTY()
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == frontmost.processIdentifier else {
            return []
        }
        return Set(
            candidates.filter {
                ExactTargetVisibilityPolicy.shouldSuppress(
                    appMatches: true, capability: ReturnResolver.resolve($0).capability,
                    selectedTTY: selectedTTY, targetTTY: $0.tty)
            }.map(\.id))
    }

    /// The name-matching half, separated from NSWorkspace so it can be tested.
    ///
    /// A false positive here is not cosmetic: smart suppression uses this to
    /// decide you are already watching the agent's terminal, and silently drops
    /// the completion notification and auto-expand. The old rule matched any
    /// substring in either direction and special-cased "vs code" to any name
    /// containing "code" — so with an agent in VS Code and Xcode frontmost, it
    /// answered true and swallowed the notification.
    static func matches(appNamed name: String?, frontmost: String?) -> Bool {
        guard let name, !name.isEmpty, let frontmost, !frontmost.isEmpty else { return false }
        let f = frontmost.lowercased()
        let t = name.lowercased()

        if f == t { return true }

        // Known aliases where macOS's name differs from our detector's. Kept
        // explicit — substring matching is what caused the false positives.
        let aliases: [String: Set<String>] = [
            "vs code": ["code", "visual studio code", "code - insiders"],
            "iterm": ["iterm2"],
            "cursor": ["cursor"],
        ]
        if let known = aliases[t], known.contains(f) { return true }
        if let known = aliases[f], known.contains(t) { return true }

        // Fall back to a prefix relationship rather than "contains anywhere",
        // so "Code" no longer matches "Xcode". Guarded by a length floor so
        // very short names can't match half the Dock.
        guard min(f.count, t.count) >= 4 else { return false }
        return f.hasPrefix(t) || t.hasPrefix(f)
    }

    private static func selectedTerminalTTY() -> String? {
        osascriptOutput(
            """
            tell application "Terminal"
                if not (exists front window) then return ""
                return tty of selected tab of front window
            end tell
            """)
    }

    private static func selectedITermTTY() -> String? {
        osascriptOutput(
            """
            tell application "iTerm"
                if not (exists current window) then return ""
                return tty of current session of current window
            end tell
            """)
    }

    // MARK: - tmux

    private static var tmuxPath: String? {
        ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func tmuxPane(tty: String?) -> String? {
        guard let tmux = tmuxPath, let tty else { return nil }
        let panes = run(tmux, ["list-panes", "-a", "-F", "#{pane_tty} #{pane_id}"])
        for line in panes.split(separator: "\n") {
            let parts = line.split(separator: " ")
            if parts.count == 2, parts[0] == Substring(tty) { return String(parts[1]) }
        }
        return nil
    }

    private static func tmuxSend(text: String, tty: String?) -> Bool {
        guard let tmux = tmuxPath, let pane = tmuxPane(tty: tty) else { return false }
        guard succeeds(tmux, ["send-keys", "-t", pane, "-l", text]) else { return false }
        return succeeds(tmux, ["send-keys", "-t", pane, "Enter"])
    }

    private static func tmuxSelectPane(tty: String) -> Bool {
        guard let tmux = tmuxPath, let pane = tmuxPane(tty: tty) else { return false }
        guard succeeds(tmux, ["switch-client", "-t", pane]) else { return false }
        guard succeeds(tmux, ["select-window", "-t", pane]) else { return false }
        return succeeds(tmux, ["select-pane", "-t", pane])
    }

    // MARK: - WezTerm (wezterm cli — precise, matched by tty)

    private static var weztermPath: String? {
        [
            "/opt/homebrew/bin/wezterm", "/usr/local/bin/wezterm",
            "/Applications/WezTerm.app/Contents/MacOS/wezterm",
        ]
        .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// pane_id of the WezTerm pane whose tty matches, e.g. "/dev/ttys003".
    private static func weztermPaneId(dev: String) -> String? {
        guard let wez = weztermPath else { return nil }
        let out = run(wez, ["cli", "list", "--format", "json"])
        guard let data = out.data(using: .utf8),
            let panes = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return nil }
        for pane in panes where pane["tty_name"] as? String == dev {
            if let id = pane["pane_id"] as? Int { return String(id) }
        }
        return nil
    }

    // MARK: - kitty (kitten @ — needs allow_remote_control; falls back to activate)

    private static var kittenPath: String? {
        [
            "/opt/homebrew/bin/kitten", "/usr/local/bin/kitten",
            "/Applications/kitty.app/Contents/MacOS/kitten",
        ]
        .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// kitty window id whose foreground process is the agent (matched by pid).
    private static func kittyWindowId(pid: Int32) -> String? {
        guard let kitten = kittenPath else { return nil }
        let out = run(kitten, ["@", "ls"])  // empty if remote control is off
        guard let data = out.data(using: .utf8),
            let osWindows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return nil }
        for osWindow in osWindows {
            for tab in (osWindow["tabs"] as? [[String: Any]] ?? []) {
                for window in (tab["windows"] as? [[String: Any]] ?? []) {
                    let fg = window["foreground_processes"] as? [[String: Any]] ?? []
                    let matches = fg.contains { ($0["pid"] as? Int).map(Int32.init) == pid }
                    if matches, let id = window["id"] as? Int { return String(id) }
                }
            }
        }
        return nil
    }

    // MARK: - Plumbing

    @discardableResult
    private static func osascript(_ source: String, arguments: [String] = []) -> Bool {
        BoundedProcess.run(
            "/usr/bin/osascript",
            appleScriptProcessArguments(source: source, arguments: arguments), timeout: 3
        ).succeeded
    }

    private static func osascriptOutput(_ source: String) -> String? {
        let result = BoundedProcess.run("/usr/bin/osascript", ["-e", source], timeout: 0.2, maximumBytes: 4096)
        guard result.succeeded else { return nil }
        let value = result.output
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    /// Dynamic TTY and user text values are process arguments, never source
    /// interpolation. AppleScript receives them only through `on run argv`.
    static func appleScriptProcessArguments(source: String, arguments: [String]) -> [String] {
        ["-e", source] + arguments
    }

    private static func run(_ path: String, _ arguments: [String]) -> String {
        let result = BoundedProcess.run(path, arguments)
        return result.succeeded ? result.output : ""
    }

    private static func succeeds(_ path: String, _ arguments: [String]) -> Bool {
        BoundedProcess.run(path, arguments).succeeded
    }

    /// Post Unicode keyboard input to the selected Terminal tab. We deliberately
    /// do not trigger the system permission prompt here: a send action without
    /// existing Accessibility authority returns false and the UI explains that
    /// nothing was sent.
    private static func synthesize(text: String, pressReturn: Bool) -> Bool {
        guard hasAccessibilityAccess,
            let source = CGEventSource(stateID: .hidSystemState)
        else { return false }

        let units = Array(text.utf16)
        for start in stride(from: 0, to: units.count, by: 20) {
            var chunk = Array(units[start..<min(start + 20, units.count)])
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            else { return false }
            down.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }

        if pressReturn {
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: true),
                let up = CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: false)
            else { return false }
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
        return true
    }
}

enum ExactTargetVisibilityPolicy {
    static func shouldSuppress(
        appMatches: Bool,
        capability: ReturnCapability,
        selectedTTY: String?,
        targetTTY: String?
    ) -> Bool {
        guard appMatches, case .exact = capability,
            let selectedTTY, let targetTTY
        else { return false }
        return normalizedTTY(selectedTTY) == normalizedTTY(targetTTY)
    }

    private static func normalizedTTY(_ value: String) -> String {
        value.hasPrefix("/dev/") ? String(value.dropFirst("/dev/".count)) : value
    }
}
