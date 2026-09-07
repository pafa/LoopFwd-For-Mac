import AppKit
import Carbon.HIToolbox

/// Global hotkeys via Carbon's RegisterEventHotKey — works from an accessory
/// app with no Accessibility permission. ⌘/⌃/⌥ + G opens the session
/// switcher; +Shift cycles backwards.
final class HotKeyCenter: ObservableObject {
    static let shared = HotKeyCenter()

    @Published private(set) var registrationIssues: [String] = []

    private var hotKeys: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?

    private static let forwardId: UInt32 = 1
    private static let backwardId: UInt32 = 2
    private static let approveId: UInt32 = 3
    private static let alwaysAllowId: UInt32 = 4
    private static let denyId: UInt32 = 5

    /// (Re-)register hotkeys from current preferences. Approval keys
    /// (mod+Y/A/N) only exist while a permission request is pending, so they
    /// never shadow other apps' shortcuts in normal use.
    func update() {
        unregisterAll()
        registrationIssues.removeAll()
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: Pref.shortcutsEnabled) else { return }

        guard installHandlerIfNeeded() else { return }
        let modifiers = Self.carbonModifiers(defaults.string(forKey: Pref.shortcutModifier) ?? "control")
        register(keyCode: UInt32(kVK_ANSI_G), modifiers: modifiers, id: Self.forwardId, label: "Open Switcher")
        if defaults.bool(forKey: Pref.reverseSwitcher) {
            register(
                keyCode: UInt32(kVK_ANSI_G), modifiers: modifiers | UInt32(shiftKey),
                id: Self.backwardId, label: "Reverse Switcher")
        }
        if defaults.bool(forKey: Pref.claudeControlsEnabled), ApprovalCenter.shared.hasPending {
            register(keyCode: UInt32(kVK_ANSI_Y), modifiers: modifiers, id: Self.approveId, label: "Approve")
            register(keyCode: UInt32(kVK_ANSI_A), modifiers: modifiers, id: Self.alwaysAllowId, label: "Always Allow")
            register(keyCode: UInt32(kVK_ANSI_N), modifiers: modifiers, id: Self.denyId, label: "Deny")
        }
    }

    static func carbonModifiers(_ name: String) -> UInt32 {
        switch name {
        case "option": return UInt32(optionKey)
        case "command": return UInt32(cmdKey)
        default: return UInt32(controlKey)
        }
    }

    static func modifierSymbol(_ name: String) -> String {
        switch name {
        case "option": return "⌥"
        case "command": return "⌘"
        default: return "⌃"
        }
    }

    private func installHandlerIfNeeded() -> Bool {
        guard handler == nil else { return true }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let status = InstallEventHandler(
            GetEventDispatcherTarget(),
            { _, event, _ -> OSStatus in
                var hotKeyId = EventHotKeyID()
                let readStatus = GetEventParameter(
                    event, EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID), nil,
                    MemoryLayout<EventHotKeyID>.size, nil, &hotKeyId)
                guard readStatus == noErr else { return readStatus }
                guard hotKeyId.signature == OSType(0x4149_4C44) else { return OSStatus(eventNotHandledErr) }
                DispatchQueue.main.async {
                    switch hotKeyId.id {
                    case HotKeyCenter.approveId:
                        ApprovalCenter.shared.respondToNewest(action: .approve)
                    case HotKeyCenter.alwaysAllowId:
                        ApprovalCenter.shared.respondToNewest(action: .alwaysAllow)
                    case HotKeyCenter.denyId:
                        ApprovalCenter.shared.respondToNewest(action: .deny)
                    case HotKeyCenter.backwardId:
                        SwitcherState.shared.advance(by: -1)
                    default:
                        SwitcherState.shared.advance(by: 1)
                    }
                }
                return noErr
            }, 1, &eventType, nil, &handler)
        if let issue = Self.registrationIssue(
            operation: "Keyboard event handler", status: status, hasHandle: handler != nil)
        {
            handler = nil
            registrationIssues.append(issue)
            return false
        }
        return true
    }

    private func register(keyCode: UInt32, modifiers: UInt32, id: UInt32, label: String) {
        var ref: EventHotKeyRef?
        let hotKeyId = EventHotKeyID(signature: OSType(0x4149_4C44) /* "AILD" */, id: id)
        let status = RegisterEventHotKey(
            keyCode, modifiers, hotKeyId,
            GetEventDispatcherTarget(), 0, &ref)
        if status == noErr, let ref { hotKeys.append(ref) }
        if let issue = Self.registrationIssue(operation: label, status: status, hasHandle: ref != nil) {
            registrationIssues.append(issue)
        }
    }

    static func registrationIssue(operation: String, status: OSStatus, hasHandle: Bool) -> String? {
        if status != noErr {
            return L10n.format("%@ could not be registered (macOS error %d).", L10n.string(operation), status)
        }
        guard hasHandle else {
            return L10n.format("macOS did not return a registration handle for %@.", L10n.string(operation))
        }
        return nil
    }

    private func unregisterAll() {
        hotKeys.forEach { UnregisterEventHotKey($0) }
        hotKeys.removeAll()
    }
}

/// Keyboard-driven session switcher: hotkey opens the island in keyboard
/// mode, repeated presses / arrow keys cycle through sessions, ⏎ or mod+T
/// jumps to the selected session's terminal, esc dismisses.
final class SwitcherState: ObservableObject {
    static let shared = SwitcherState()

    @Published private(set) var active = false
    @Published private(set) var selectedSessionID: String?
    var index: Int { visibleAgents.firstIndex { $0.id == selectedSessionID } ?? 0 }

    weak var panel: NotchPanel?

    private var visibleAgents: [AgentSession] {
        let agents = SessionList.merged(
            observed: AgentMonitor.shared.agents,
            managed: CodexAppServer.shared.agents
        )
        return OutcomePresentation.shared.visible(SessionPresentationPolicy.visible(agents))
    }

    /// Hotkey entry point: open the switcher, or cycle when already open.
    func advance(by delta: Int) {
        // Never grab the keyboard while the island is hidden (fullscreen).
        if let panel, !panel.isOnActiveSpace || panel.alphaValue < 0.5 { return }
        let agents = visibleAgents
        guard !agents.isEmpty else {
            panel?.orderFrontRegardless()
            NotificationCenter.default.post(name: .islandExpand, object: nil)
            return
        }
        if active {
            selectedSessionID = agents[((index + delta) % agents.count + agents.count) % agents.count].id
        } else {
            active = true
            selectedSessionID = agents[delta >= 0 ? 0 : agents.count - 1].id
            panel?.makeKeyAndOrderFront(nil)
            NotificationCenter.default.post(name: .islandExpand, object: "switcher")
        }
    }

    func confirm() {
        let agents = visibleAgents
        guard let agent = agents.first(where: { $0.id == selectedSessionID }) else {
            end(collapse: true)
            return
        }
        TerminalBridge.jump(to: agent) { result in
            if result.opened {
                self.end(collapse: true)
            } else {
                OperationalDiagnostics.shared.showNotice(
                    sessionID: agent.id,
                    title: agent.displayTitle,
                    message: result.reason
                        ?? "The task target could not be reached."
                )
            }
        }
    }

    func end(collapse: Bool) {
        guard active else { return }
        active = false
        // Only restore a panel that was already visible in this Space. Space
        // changes also end keyboard mode; ordering forward there would undo
        // AppKit's fullscreen exclusion and could briefly reveal the panel.
        if let panel,
            NotchSpacePolicy.shouldRestoreAfterKeyboardDismissal(
                isVisible: panel.isVisible, isOnActiveSpace: panel.isOnActiveSpace, alpha: panel.alphaValue)
        {
            panel.orderOut(nil)
            panel.orderFrontRegardless()
        }
        if collapse {
            NotificationCenter.default.post(name: .islandCollapse, object: nil)
        }
    }

    /// Key events routed from the panel while it is key. Returns true when handled.
    func handleKey(_ event: NSEvent) -> Bool {
        guard active, UserDefaults.standard.bool(forKey: Pref.shortcutsEnabled) else { return false }
        switch Int(event.keyCode) {
        case kVK_DownArrow:
            advance(by: 1); return true
        case kVK_UpArrow:
            advance(by: -1); return true
        case kVK_Return, kVK_ANSI_KeypadEnter:
            confirm(); return true
        case kVK_Escape:
            end(collapse: true); return true
        case kVK_ANSI_T:
            confirm(); return true
        case kVK_ANSI_G
        where event.modifierFlags.contains(.control)
            || event.modifierFlags.contains(.option)
            || event.modifierFlags.contains(.command):
            // The Carbon hotkey normally swallows this; belt and suspenders.
            advance(by: event.modifierFlags.contains(.shift) ? -1 : 1); return true
        default:
            return false
        }
    }
}
