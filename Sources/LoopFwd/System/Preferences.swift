import Foundation

/// UserDefaults-backed preferences, shared between the Settings UI
/// (via @AppStorage) and the monitor/views (via these accessors).
enum Pref {
    static let interfaceLanguage = "interfaceLanguage"  // system | en | zh-Hans
    // MARK: General — expansion
    static let expandOnHover = "expandOnHover"  // hover opens the panel
    static let hoverDuration = "hoverDuration"  // seconds of hover intent before opening
    static let smartSuppression = "smartSuppression"  // no auto-expand when the agent's terminal is frontmost
    static let autoRevealOnComplete = "autoRevealOnComplete"  // expand island when an agent finishes

    // MARK: General — visibility
    static let hideInFullscreen = "hideInFullscreen"  // hide the island on fullscreen spaces
    static let autoHideWhenEmpty = "autoHideWhenEmpty"  // hide pill when no agents

    // MARK: General — dismissal
    static let autoCollapse = "autoCollapse"  // collapse when mouse leaves
    static let autoRevealDwell = "autoRevealDwell"  // seconds an auto-reveal stays open
    static let dismissRevealOnOutsideClick = "dismissRevealOnOutsideClick"
    static let hideIdleAfterMinutes = "hideIdleAfterMinutes"  // 0 = never

    // MARK: General — interaction
    static let disableClickToJump = "disableClickToJump"  // card click opens detail instead of the terminal
    static let pollInterval = "pollInterval"  // seconds

    // MARK: Display
    static let pillStyle = "pillStyle"  // "clean" | "detailed"
    static let displaySelection = "displaySelection"  // "auto" | "id:<CGDirectDisplayID>"
    static let contentFontSize = "contentFontSize"  // base pt for card text
    static let maxPanelWidth = "maxPanelWidth"  // expanded panel width, pt
    static let maxPanelHeight = "maxPanelHeight"  // session list scroll height cap, pt
    static let showLastPrompt = "showLastPrompt"
    static let showActivity = "showActivity"
    static let showTerminalChip = "showTerminalChip"
    static let showTasks = "showTasks"  // task checklist on session cards
    static let showModel = "showModel"  // AI model chip on cards
    static let showGitBranch = "showGitBranch"  // git branch chip on cards
    static let showSubagents = "showSubagents"  // fan-out Task subagents on cards
    static let maxVisibleSessions = "maxVisibleSessions"
    static let notchWidthOffset = "notchWidthOffset"  // pt added to the detected notch width
    static let notchHeightOffset = "notchHeightOffset"  // pt added to the detected notch height

    // MARK: Sound
    static let soundsEnabled = "soundsEnabled"  // master switch
    static let soundVolume = "soundVolume"  // 0…1
    static let soundSessionStart = "soundSessionStart"  // sound name or "Off"
    static let soundTaskComplete = "soundTaskComplete"
    static let soundTaskFailed = "soundTaskFailed"
    static let soundTaskStalled = "soundTaskStalled"
    static let soundAcknowledge = "soundAcknowledge"  // you replied, agent got to work
    static let soundApprovalNeeded = "soundApprovalNeeded"  // permission request pending
    static let quietHoursEnabled = "quietHoursEnabled"
    static let quietHoursStart = "quietHoursStart"  // minutes from midnight
    static let quietHoursEnd = "quietHoursEnd"

    // MARK: Usage
    static let usageEnabled = "usageEnabled"  // estimate quota from transcripts
    static let communityUsageEnabled = "communityUsageEnabled"
    static let usagePlan = "usagePlan"  // "pro" | "max5x" | "max20x"

    // MARK: Notifications
    static let notifyOnComplete = "notifyOnComplete"  // macOS notification when an agent finishes
    static let notifyOnAttention = "notifyOnAttention"  // question, approval, auth, or confirmation
    static let notifyOnFailure = "notifyOnFailure"  // provider-confirmed failed turn
    static let notifyOnStalled = "notifyOnStalled"  // optional no-progress warning
    static let notifyOnStart = "notifyOnStart"  // macOS notification when a session appears
    static let hideNotificationDetails = "hideNotificationDetails"

    // MARK: Shortcuts
    static let shortcutsEnabled = "shortcutsEnabled"
    static let shortcutModifier = "shortcutModifier"  // "control" | "option" | "command"
    static let reverseSwitcher = "reverseSwitcher"  // shift+modifier cycles backwards

    // MARK: Agents
    static let disabledAgents = "disabledAgents"  // CSV of AgentKind rawValues
    static let managedCodexCwd = "managedCodexCwd"  // last folder explicitly chosen for a LoopFwd task
    static let managedCodexThreads = "managedCodexThreads"  // LoopFwd-owned thread identities for restart recovery

    // MARK: Labs
    static let claudeControlsEnabled = "claudeControlsEnabled"
    static let providerControlsEnabled = "providerControlsEnabled"

    /// AppStorage fallbacks and registered defaults must share these values.
    /// A view-level literal that drifts from registration creates different
    /// first-run behavior depending on initialization order.
    enum Default {
        static let interfaceLanguage = "system"
        static let expandOnHover = true
        static let hoverDuration = 0.15
        static let smartSuppression = true
        static let autoRevealOnComplete = false
        static let hideInFullscreen = true
        static let autoHideWhenEmpty = false
        static let autoCollapse = true
        static let autoRevealDwell = 5.0
        static let dismissRevealOnOutsideClick = false
        static let hideIdleAfterMinutes = 0
        static let disableClickToJump = false
        static let pollInterval = 0.0  // adaptive; persisted positive intervals retain their meaning
        static let pillStyle = "clean"
        static let displaySelection = "auto"
        static let contentFontSize = 11
        static let maxPanelWidth = 530.0
        static let maxPanelHeight = 560.0
        static let showLastPrompt = true
        static let showActivity = true
        static let showTerminalChip = true
        static let showTasks = true
        static let showModel = true
        static let showGitBranch = true
        static let showSubagents = true
        static let maxVisibleSessions = 6
        static let notchWidthOffset = 0.0
        static let notchHeightOffset = 0.0
        static let soundsEnabled = true
        static let soundVolume = 0.5
        static let soundSessionStart = "Off"
        static let soundTaskComplete = "Glass"
        static let soundTaskFailed = "Basso"
        static let soundTaskStalled = "Off"
        static let soundAcknowledge = "Off"
        static let soundApprovalNeeded = "Ping"
        static let quietHoursEnabled = false
        static let quietHoursStart = 22 * 60
        static let quietHoursEnd = 8 * 60
        static let usageEnabled = true
        static let communityUsageEnabled = false
        static let usagePlan = "max5x"
        static let notifyOnComplete = true
        static let notifyOnAttention = true
        static let notifyOnFailure = true
        static let notifyOnStalled = false
        static let notifyOnStart = false
        static let shortcutsEnabled = true
        static let shortcutModifier = "control"
        static let reverseSwitcher = true
        static let disabledAgents = SupportRegistry.shippedKinds
            .filter { $0.supportTier == .experimental }.map(\.rawValue).sorted().joined(separator: ",")
        static let managedCodexCwd = NSHomeDirectory()
        static let claudeControlsEnabled = false
        static let providerControlsEnabled = false
        static let hideNotificationDetails = false
    }

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            interfaceLanguage: Default.interfaceLanguage,
            expandOnHover: Default.expandOnHover,
            hoverDuration: Default.hoverDuration,
            smartSuppression: Default.smartSuppression,
            autoRevealOnComplete: Default.autoRevealOnComplete,

            hideInFullscreen: Default.hideInFullscreen,
            autoHideWhenEmpty: Default.autoHideWhenEmpty,

            autoCollapse: Default.autoCollapse,
            autoRevealDwell: Default.autoRevealDwell,
            dismissRevealOnOutsideClick: Default.dismissRevealOnOutsideClick,
            hideIdleAfterMinutes: Default.hideIdleAfterMinutes,

            disableClickToJump: Default.disableClickToJump,
            pollInterval: Default.pollInterval,

            pillStyle: Default.pillStyle,
            displaySelection: Default.displaySelection,
            contentFontSize: Default.contentFontSize,
            maxPanelWidth: Default.maxPanelWidth,
            maxPanelHeight: Default.maxPanelHeight,
            showLastPrompt: Default.showLastPrompt,
            showActivity: Default.showActivity,
            showTerminalChip: Default.showTerminalChip,
            showTasks: Default.showTasks,
            showModel: Default.showModel,
            showGitBranch: Default.showGitBranch,
            showSubagents: Default.showSubagents,
            maxVisibleSessions: Default.maxVisibleSessions,
            notchWidthOffset: Default.notchWidthOffset,
            notchHeightOffset: Default.notchHeightOffset,

            soundsEnabled: Default.soundsEnabled,
            soundVolume: Default.soundVolume,
            soundSessionStart: Default.soundSessionStart,
            soundTaskComplete: Default.soundTaskComplete,
            soundTaskFailed: Default.soundTaskFailed,
            soundTaskStalled: Default.soundTaskStalled,
            soundAcknowledge: Default.soundAcknowledge,
            soundApprovalNeeded: Default.soundApprovalNeeded,
            quietHoursEnabled: Default.quietHoursEnabled,
            quietHoursStart: Default.quietHoursStart,
            quietHoursEnd: Default.quietHoursEnd,

            usageEnabled: Default.usageEnabled,
            communityUsageEnabled: Default.communityUsageEnabled,
            usagePlan: Default.usagePlan,

            notifyOnComplete: Default.notifyOnComplete,
            notifyOnAttention: Default.notifyOnAttention,
            notifyOnFailure: Default.notifyOnFailure,
            notifyOnStalled: Default.notifyOnStalled,
            notifyOnStart: Default.notifyOnStart,

            shortcutsEnabled: Default.shortcutsEnabled,
            shortcutModifier: Default.shortcutModifier,
            reverseSwitcher: Default.reverseSwitcher,

            disabledAgents: Default.disabledAgents,
            managedCodexCwd: Default.managedCodexCwd,
            claudeControlsEnabled: Default.claudeControlsEnabled,
            providerControlsEnabled: Default.providerControlsEnabled,
            hideNotificationDetails: Default.hideNotificationDetails,
        ])
    }

    static var disabledKinds: Set<AgentKind> {
        disabledKinds(in: .standard)
    }

    static func disabledKinds(in defaults: UserDefaults) -> Set<AgentKind> {
        let csv = defaults.string(forKey: disabledAgents) ?? Default.disabledAgents
        // Preserve saved preferences, but an old enabled toggle cannot opt a
        // deferred integration back into this release's scanning paths.
        return Set(csv.split(separator: ",").compactMap { AgentKind(rawValue: String($0)) })
            .union(SupportRegistry.deferredKinds)
    }
}

extension Notification.Name {
    /// Posted with an `AgentLifecycleEvent` as `object`.
    static let agentLifecycleEvent = Notification.Name("agentLifecycleEvent")
    /// Posted with the stable String session id as `object`.
    static let agentCompleted = Notification.Name("agentCompleted")
    /// Posted with the stable String session id as `object`.
    static let agentStarted = Notification.Name("agentStarted")
    /// Posted with the stable String session id as `object`.
    static let agentAcknowledged = Notification.Name("agentAcknowledged")
    /// Posted with the stable String session id when a turn fails.
    static let agentFailed = Notification.Name("agentFailed")
    /// Posted with the stable String session id when progress appears stalled.
    static let agentStalled = Notification.Name("agentStalled")
    /// Posted with the stable String session id after an explicit interruption.
    static let agentStopped = Notification.Name("agentStopped")
    /// The panel should re-detect its screen / notch metrics.
    static let repositionPanel = Notification.Name("repositionPanel")
    /// Ask the island to expand (object: "switcher" enables keyboard mode UI).
    static let islandExpand = Notification.Name("islandExpand")
    /// Ask the island to collapse.
    static let islandCollapse = Notification.Name("islandCollapse")
    /// Reports the rendered island's expanded state as a Bool object.
    static let islandPresentationChanged = Notification.Name("islandPresentationChanged")
    /// Expand the island directly into one session (object: String session id).
    static let islandSelect = Notification.Name("islandSelect")
}
