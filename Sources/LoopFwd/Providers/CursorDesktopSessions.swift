import AppKit
import ApplicationServices
import CryptoKit
import Foundation

/// Observes rendered Cursor Agents panes, using macOS Accessibility only.
/// No account credentials, editor contents, hooks, or provider control.
enum CursorDesktopSessions {
    static let bundleIdentifier = "com.todesktop.230313mzl4w4u92"
    static let source = "Cursor visible Agents panes"
    static var authorized: Bool { AXIsProcessTrusted() }
    private static var progress = ProgressClock()

    struct ProgressClock {
        private var previous: [String: AgentSession] = [:]

        mutating func stamp(_ sessions: [AgentSession]) -> [AgentSession] {
            let stamped = sessions.map { session in
                var session = session
                if let old = previous[session.id], old.status == session.status,
                    old.activity == session.activity, old.lastPrompt == session.lastPrompt
                {
                    session.observation.updatedAt = old.observation.updatedAt
                }
                return session
            }
            previous = Dictionary(uniqueKeysWithValues: stamped.map { ($0.id, $0) })
            return stamped
        }
    }

    struct Node {
        var role: String
        var label = ""
        var selected = false
        var children: [Node] = []
        var all: [Node] { [self] + children.flatMap(\.all) }
    }

    static func read(processID: Int32, version: String?) -> ProviderReadResult {
        guard version == "3.20.17" else {
            return .failed(source, reason: "Cursor interface version has not been verified", incompatible: true)
        }
        guard authorized else {
            return .failed(source, reason: "Allow Accessibility for LoopFwd in Agents settings to observe Cursor")
        }
        let app = AXUIElementCreateApplication(processID)
        AXUIElementSetMessagingTimeout(app, 0.05)
        let deadline = ProcessInfo.processInfo.systemUptime + 0.8
        var remaining = 1600
        var complete = true
        func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
            guard ProcessInfo.processInfo.systemUptime < deadline else { complete = false; return nil }
            var result: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(element, name as CFString, &result)
            if error == .cannotComplete || error == .invalidUIElement { complete = false }
            return error == .success ? result : nil
        }
        func visit(_ element: AXUIElement, depth: Int) -> Node? {
            guard remaining > 0, depth < 45, ProcessInfo.processInfo.systemUptime < deadline else {
                complete = false
                return nil
            }
            remaining -= 1
            let role = attribute(element, kAXRoleAttribute) as? String ?? ""
            let title = attribute(element, kAXTitleAttribute) as? String ?? ""
            let description = title.isEmpty ? attribute(element, kAXDescriptionAttribute) as? String ?? "" : ""
            var node = Node(
                role: role,
                label: String((title.isEmpty ? description : title).prefix(1000)).trimmingCharacters(
                    in: .whitespacesAndNewlines))
            // Never read text fields, documents or menus. Their text is not status evidence.
            if role == kAXTextAreaRole || role == kAXTextFieldRole || role == kAXMenuBarRole
                || node.label == "Panel editor-panel-group"
            {
                return node
            }
            let value = attribute(element, kAXValueAttribute)
            node.selected = (value as? NSNumber)?.intValue == 1
            if node.label.isEmpty, let text = value as? String { node.label = String(text.prefix(1000)) }
            let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
            guard children.count <= 1600 else { complete = false; return node }
            node.children = children.compactMap { visit($0, depth: depth + 1) }
            return node
        }
        guard let tree = visit(app, depth: 0), complete else {
            return .failed(source, reason: "Cursor interface read was interrupted or exceeded its budget")
        }
        let result = project(tree, processID: processID)
        guard result.successful else { return result }
        return .read(progress.stamp(result.sessions), source: source)
    }

    static func project(_ root: Node, processID: Int32, now: Date = Date()) -> ProviderReadResult {
        let panels = root.all.filter { $0.label == "Panel project-conversations" }
        var sessions: [AgentSession] = []
        for panel in panels {
            let items = panel.all
            let tabs = items.filter { ($0.role == kAXRadioButtonRole || $0.role == "AXTab") && $0.selected }
            guard tabs.count == 1 else { continue }
            let tab = tabs[0]
            let title = tab.children.first { $0.role == kAXStaticTextRole }?.label ?? tab.label
            guard !title.isEmpty, title.count <= 180 else { continue }
            let conversations = items.filter { $0.role == kAXGroupRole && $0.label == title }
            guard conversations.count == 1 else { continue }
            let content = conversations[0].all
            // Only the live composer footer establishes phase. Old transcript
            // groups labelled Working/Worked cannot keep an idle task running.
            let footers = content.filter { node in
                node.children.contains { $0.role == kAXTextAreaRole }
            }
            guard footers.count == 1 else { continue }
            let buttons = footers[0].all.filter { $0.role == kAXButtonRole }.map(\.label)
            let runningCount = buttons.first {
                $0.range(of: #"^Agents, Working [1-9][0-9]*$"#, options: .regularExpression) != nil
            }
            let running = buttons.contains("Stop generation") || runningCount != nil
            let progress =
                running
                ? content.last {
                    $0.role == kAXButtonRole
                        && $0.label.range(of: #"^(?:[1-9][0-9]* )?Working(?: .+)?$"#, options: .regularExpression)
                            != nil
                }?.label : nil
            let goal = footers[0].all.first { $0.role == kAXGroupRole && $0.label.hasPrefix("Goal active:") }?.label
            let digest = SHA256.hash(data: Data(title.utf8)).map { String(format: "%02x", $0) }.joined()
            // UI identity is deliberately local, not a provider conversation ID.
            // No title-to-cache matching or invented exact task link.
            sessions.append(
                AgentSession(
                    id: "cursor:visible:\(processID):\(digest)", kind: .cursorAgent, cpu: 0, elapsed: "",
                    status: running ? .working : .idle, terminalApp: "Cursor", bypassPermissions: false,
                    returnTarget: .application(bundleIdentifier: bundleIdentifier, name: "Cursor"),
                    observation: .rich(source, updatedAt: now, authority: .versionedObserver),
                    title: title,
                    lastPrompt: goal.map {
                        String($0.dropFirst("Goal active:".count)).trimmingCharacters(in: .whitespaces)
                    },
                    activity: progress ?? runningCount, surfaceID: .cursorDesktop))
        }
        guard !sessions.isEmpty, Set(sessions.map(\.id)).count == sessions.count else {
            return .failed(source, reason: "Cursor task pane is unavailable or ambiguous; keep an Agents pane open")
        }
        return .read(sessions, source: source)
    }
}
