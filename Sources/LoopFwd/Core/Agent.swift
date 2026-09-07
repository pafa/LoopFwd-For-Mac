import SwiftUI

enum AgentKind: String, CaseIterable {
    case claude
    case codex
    case gemini
    case opencode
    case cursorAgent = "cursor-agent"
    case copilot
    case qwen
    case kimi
    case deepseek
    case grok
    case mistral
    case workbuddy

    /// Everything the UI needs to render an agent, in one place so adding an
    /// agent is a single table row rather than edits across five switches.
    struct Meta {
        let displayName: String
        let rgb: (Double, Double, Double)
        let symbol: String  // SF Symbol fallback when no brand icon
        let iconFile: String?  // Resources/agents/<name>.png, nil = symbol
        let aliases: [String]  // extra executable basenames that map here
    }

    var meta: Meta {
        Self.table[self]
            ?? Meta(
                displayName: rawValue.capitalized, rgb: (0.5, 0.5, 0.55), symbol: "terminal.fill", iconFile: nil,
                aliases: [])
    }

    var displayName: String { meta.displayName }
    var color: Color { Color(red: meta.rgb.0, green: meta.rgb.1, blue: meta.rgb.2) }
    var symbol: String { meta.symbol }
    /// Bundled brand icon (Resources/agents/<name>.png), nil = SF symbol fallback.
    var iconFile: String? { meta.iconFile }
    var supportTier: ProviderSupportTier {
        SupportRegistry.tier(self)
    }

    /// Providers with codebase-backed local transcript / registry readers. The
    /// remaining agents participate through process state and terminal jump,
    /// without claiming richer transcript authority.
    var hasRichSessionReader: Bool {
        self == .claude || self == .codex || self == .gemini
            || self == .opencode || self == .cursorAgent || self == .copilot
            || self == .qwen || self == .kimi || self == .deepseek
            || self == .grok || self == .mistral
            || self == .workbuddy
    }

    /// Installed CLI, searched without invoking a login shell or changing PATH.
    /// Direct paths cover each provider's official installer; PATH and common
    /// package-manager directories cover Homebrew/npm and custom shell setups.
    var installedCLIPath: String? {
        if self == .workbuddy { return nil }  // Desktop's private engine is not a selectable CLI.
        let home = NSHomeDirectory()
        if let selected = UserDefaults.standard.string(forKey: "cliExecutable.\(rawValue)"),
            FileManager.default.isExecutableFile(atPath: selected)
        {
            return selected
        }
        let direct: [String]
        switch self {
        case .claude:
            direct = ["\(home)/.local/bin/claude"]
        case .codex:
            direct = ["com.openai.codex", "com.openai.chat"].compactMap {
                NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0)?
                    .appendingPathComponent("Contents/Resources/codex").path
            }
        case .opencode:
            direct = ["\(home)/.opencode/bin/opencode", "\(home)/bin/opencode"]
        case .deepseek:
            direct = ["\(home)/.local/bin/dsh", "\(home)/bin/dsh"]
        default:
            direct = []
        }

        let pathDirectories = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
        let commonDirectories = [
            "\(home)/.local/bin", "\(home)/bin", "\(home)/.opencode/bin",
            "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin",
        ]
        let candidates =
            direct
            + (pathDirectories + commonDirectories).flatMap { directory in
                cliExecutableNames.map { "\(directory)/\($0)" }
            }

        var seen = Set<String>()
        return candidates.first { path in
            seen.insert(path).inserted && FileManager.default.isExecutableFile(atPath: path)
        }
    }

    /// Installation is only a setup hint, never verified observation/control.
    var softwareAvailable: Bool {
        if installedCLIPath != nil { return true }
        let bundleID: String?
        switch self {
        case .codex: bundleID = "com.openai.codex"
        case .opencode: bundleID = "ai.opencode.desktop"
        case .workbuddy: bundleID = WorkBuddySessions.bundleIdentifier
        default: bundleID = nil  // Claude Desktop is not Claude Code CLI.
        }
        return bundleID.flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) } != nil
    }

    private static let table: [AgentKind: Meta] = [
        .claude: Meta(
            displayName: "Claude", rgb: (0.85, 0.47, 0.34), symbol: "sparkle", iconFile: "claude-color", aliases: []),
        .codex: Meta(
            displayName: "Codex", rgb: (0.06, 0.64, 0.50), symbol: "curlybraces", iconFile: "openai", aliases: []),
        .gemini: Meta(
            displayName: "Gemini", rgb: (0.31, 0.53, 0.97), symbol: "diamond.fill", iconFile: "gemini-color",
            aliases: []),
        .opencode: Meta(
            displayName: "OpenCode", rgb: (0.35, 0.78, 0.98), symbol: "terminal.fill", iconFile: "opencode",
            aliases: []),
        .cursorAgent: Meta(
            displayName: "Cursor", rgb: (0.62, 0.62, 0.68), symbol: "cursorarrow", iconFile: "cursor",
            aliases: ["cursor"]),
        .copilot: Meta(
            displayName: "Copilot", rgb: (0.45, 0.49, 0.55), symbol: "eyeglasses", iconFile: "githubcopilot",
            aliases: []),
        .qwen: Meta(
            displayName: "Qwen", rgb: (0.38, 0.36, 0.93), symbol: "diamond.fill", iconFile: "qwen",
            aliases: ["qwen-code"]),
        // Kimi Code rewrites argv[0] to kimi-co while running.
        .kimi: Meta(
            displayName: "Kimi", rgb: (0.12, 0.12, 0.15), symbol: "moon.stars.fill", iconFile: "kimi",
            aliases: ["kimi-code", "kimi-co"]),
        .deepseek: Meta(
            displayName: "DeepSeek Harness", rgb: (0.30, 0.42, 1.00), symbol: "magnifyingglass", iconFile: "deepseek",
            aliases: ["dsh", "deepseek-harness"]),
        .grok: Meta(
            displayName: "Grok", rgb: (0.12, 0.12, 0.14), symbol: "circle.slash", iconFile: "grok",
            aliases: ["grok-cli"]),
        .mistral: Meta(
            displayName: "Mistral", rgb: (0.98, 0.32, 0.06), symbol: "wind", iconFile: "mistral",
            aliases: ["vibe", "mistral-vibe"]),
        .workbuddy: Meta(
            displayName: "WorkBuddy", rgb: (0.28, 0.46, 0.94), symbol: "briefcase.fill", iconFile: nil,
            aliases: []),
    ]

    private var cliExecutableNames: [String] {
        switch self {
        case .cursorAgent: return ["cursor-agent"]
        case .qwen: return ["qwen", "qwen-code"]
        case .kimi: return ["kimi", "kimi-code"]
        case .deepseek: return ["dsh", "deepseek-harness"]
        case .grok: return ["grok", "grok-cli"]
        case .mistral: return ["mistral", "vibe", "mistral-vibe"]
        default: return [rawValue]
        }
    }

    /// Match a process executable basename to an agent kind — by rawValue first,
    /// then by any registered alias (so "cursor" maps to the cursor-agent kind).
    init?(matching basename: String) {
        guard let kind = Self.executableKinds[basename.lowercased()] else { return nil }
        self = kind
    }

    private static let executableKinds: [String: AgentKind] = Dictionary(
        AgentKind.allCases.filter { $0 != .workbuddy }
            .flatMap { kind in ([kind.rawValue] + kind.meta.aliases).map { ($0, kind) } },
        uniquingKeysWith: { first, _ in first })
}

enum ProviderSupportTier: String, Equatable {
    case previewTested
    case experimental

    var label: String { L10n.string(self == .previewTested ? "Preview tested" : "Experimental") }
}

enum AgentStatus: Equatable {
    case working  // actively generating / running tools
    case stalled  // confirmed work with no provider-backed progress for a while
    case completed  // the latest turn finished successfully
    case needsAttention  // a real question or approval requires the user
    case failed  // the latest turn failed
    case stopped  // the latest turn was interrupted or shut down
    case idle  // no confirmed active or recent task

    var color: Color {
        switch self {
        case .working: return Color(red: 0.30, green: 0.85, blue: 0.40)
        case .stalled: return Color(red: 0.96, green: 0.58, blue: 0.20)
        case .completed: return Color(red: 0.35, green: 0.62, blue: 1.00)
        case .needsAttention: return Color(red: 1.00, green: 0.72, blue: 0.25)
        case .failed: return Color(red: 1.00, green: 0.36, blue: 0.36)
        case .stopped: return Color(white: 0.48)
        case .idle: return Color(white: 0.55)
        }
    }

    var label: String {
        switch self {
        case .working: return "Working"
        case .stalled: return "Possibly stalled"
        case .completed: return "Completed"
        case .needsAttention: return "Needs attention"
        case .failed: return "Failed"
        case .stopped: return "Stopped"
        case .idle: return "Idle"
        }
    }

    var displayLabel: String { L10n.string(label) }

    var isActive: Bool {
        self == .working || self == .stalled
    }
}

/// What kind of live request is blocking a turn. This is deliberately
/// independent from task phase: a process may be alive while its turn waits
/// for one precise user action.
enum AttentionKind: String, Equatable {
    case question
    case approval
    case authentication
    case confirmation
}

/// The authority behind a state claim. UI wording and lifecycle events use
/// this to avoid turning a CPU fluctuation into a provider-confirmed result.
enum ObservationAuthority: String, Equatable {
    case officialLive
    case officialLocalStore
    case versionedObserver
    case processHeuristic

    var canAssertTaskBoundary: Bool {
        self == .officialLive || self == .officialLocalStore || self == .versionedObserver
    }

    var shortLabel: String {
        switch self {
        case .officialLive: return "Live"
        case .officialLocalStore: return "Local"
        case .versionedObserver: return "Observer"
        case .processHeuristic: return "Process"
        }
    }
}

/// Capabilities are declared per concrete session, not inferred from a logo.
/// A provider may support an operation in general while an observed session
/// lacks the authenticated control path required to expose it safely.
struct AgentCapabilities: OptionSet, Equatable {
    let rawValue: Int

    static let observeProcess = Self(rawValue: 1 << 0)
    static let observeSession = Self(rawValue: 1 << 1)
    static let observeTask = Self(rawValue: 1 << 2)
    static let observeStep = Self(rawValue: 1 << 3)
    static let observeCompletion = Self(rawValue: 1 << 4)
    static let observeAttention = Self(rawValue: 1 << 5)
    static let exactReturn = Self(rawValue: 1 << 6)
    static let reply = Self(rawValue: 1 << 7)
    static let approve = Self(rawValue: 1 << 8)
    static let stop = Self(rawValue: 1 << 9)
    static let providerReturn = Self(rawValue: 1 << 10)

    var diagnosticLabels: [String] {
        [
            (Self.observeProcess, "process"),
            (Self.observeSession, "session"),
            (Self.observeTask, "task"),
            (Self.observeStep, "step"),
            (Self.observeCompletion, "completion"),
            (Self.observeAttention, "attention"),
            (Self.exactReturn, "exact-return"),
            (Self.providerReturn, "provider-return"),
            (Self.reply, "reply"),
            (Self.approve, "approve"),
            (Self.stop, "stop"),
        ].compactMap { capability, label in
            contains(capability) ? label : nil
        }
    }
}

struct Todo: Equatable {
    let content: String
    let status: String  // "pending" | "in_progress" | "completed"
}

struct Subagent: Equatable {
    let description: String
    let type: String?  // e.g. "Explore", "general-purpose"
    let done: Bool
}

/// A pending AskUserQuestion the agent is waiting on — rendered as tappable
/// choice buttons in the island.
struct PendingQuestion: Equatable {
    let prompt: String  // the question text
    let options: [String]  // option labels, in order
    let multiSelect: Bool
}

/// A live OpenCode permission request. The request ID is retained so the
/// island can revalidate and reply through the same local server that exposed
/// it instead of guessing at terminal keystrokes.
struct OpenCodePermission: Equatable {
    let requestID: String
    let name: String
    let patterns: [String]
}

/// Loopback-only control coordinates for one OpenCode session. These values
/// come from a process-owned listener that passed `/global/health` and cwd
/// matching in OpenCodeSessions.
struct OpenCodeControl: Equatable {
    let processID: Int32
    let port: Int
    let directory: String
    let sessionID: String
    let questionRequestID: String?
    let permission: OpenCodePermission?
}

/// A Codex thread owned by LoopFwd's official app-server connection. External
/// terminal sessions never receive this marker, so the UI cannot accidentally
/// route provider commands into a transcript that LoopFwd only observed.
struct CodexManagedControl: Equatable {
    let threadID: String
}

enum ObservationMode: String, Codable, Equatable {
    case rich
    case processOnly
    case stale
    case incompatible
}

struct ObservationHealth: Equatable {
    var mode: ObservationMode
    var updatedAt: Date
    var source: String
    var reason: String?
    var authority: ObservationAuthority = .officialLocalStore

    static func processOnly(_ source: String, reason: String? = nil) -> Self {
        .init(
            mode: .processOnly,
            updatedAt: Date(),
            source: source,
            reason: reason,
            authority: .processHeuristic
        )
    }

    static func rich(
        _ source: String,
        updatedAt: Date = Date(),
        authority: ObservationAuthority = .officialLocalStore
    ) -> Self {
        .init(
            mode: .rich,
            updatedAt: updatedAt,
            source: source,
            reason: nil,
            authority: authority
        )
    }
}

enum ReturnTarget: Equatable {
    case terminal(app: String, tty: String?, processID: Int32?)
    case application(bundleIdentifier: String, name: String)
    case applicationLink(bundleIdentifier: String, name: String, url: URL)
    case web(URL)
    case unavailable(reason: String)

    var unavailableReason: String? {
        if case .unavailable(let reason) = self { return reason }
        return nil
    }

    var label: String? {
        switch self {
        case .terminal(let app, _, _): return app
        case .application(_, let name): return name
        case .applicationLink(_, let name, _): return name
        case .web: return "Web"
        case .unavailable: return nil
        }
    }

    var isExact: Bool {
        switch self {
        case .terminal(let app, let tty, let processID):
            switch app {
            case "Terminal", "iTerm", "tmux", "WezTerm": return tty != nil
            case "kitty": return processID != nil
            default: return false
            }
        case .application: return false
        case .applicationLink: return true
        case .web: return false
        case .unavailable: return false
        }
    }

    var capability: ReturnCapability {
        switch self {
        case .unavailable(let reason):
            return .unavailable(reason: reason)
        default:
            return isExact
                ? .exact(label: label ?? "task")
                : .providerOnly(label: label ?? "provider")
        }
    }
}

enum ReturnCapability: Equatable {
    case exact(label: String)
    case providerOnly(label: String)
    case unavailable(reason: String)

    var actionLabel: String {
        switch self {
        case .exact: return L10n.string("Jump to task")
        case .providerOnly(let label): return L10n.format("Open %@", label)
        case .unavailable: return L10n.string("Unavailable")
        }
    }

    var unavailableReason: String? {
        if case .unavailable(let reason) = self { return reason }
        return nil
    }
}

struct AgentSession: Identifiable, Equatable {
    /// Provider-scoped stable identity. A process restart must not reassign a
    /// provider session, and two provider sessions must never collide on PID.
    var id: String
    var processID: Int32? = nil
    var observedVersion: ProviderVersionEvidence? = nil
    let kind: AgentKind
    var cpu: Double
    var elapsed: String
    var cwd: String?
    var status: AgentStatus
    var terminalApp: String?
    var tty: String?
    var bypassPermissions: Bool
    var returnTarget: ReturnTarget = .unavailable(reason: "No exact return target")
    var observation: ObservationHealth = .processOnly("Process table")
    var todos: [Todo] = []

    // Rich fields (Claude Code sessions, via ~/.claude)
    var title: String?
    var lastPrompt: String?
    var lastMessage: String?  // the agent's most recent visible message
    var activity: String?  // e.g. "Writing middleware.ts"
    var transcriptPath: String?
    var model: String?  // raw model id from the transcript, e.g. "claude-opus-4-8"
    var gitBranch: String?  // current branch of the session's cwd
    var subagents: [Subagent] = []
    var plan: String?  // markdown from the last ExitPlanMode call
    var pendingQuestion: PendingQuestion?  // an AskUserQuestion awaiting an answer
    var openCodeControl: OpenCodeControl?
    /// Read-only OpenCode Desktop identity. Unlike openCodeControl this never
    /// authorizes reply or approval operations.
    var openCodeDesktopSessionID: String?
    var codexManagedControl: CodexManagedControl?
    /// Provider turn identity when available. Session identity survives turns;
    /// this value scopes completion/attention deduplication to one turn.
    var turnID: String? = nil
    /// Task time is provider-backed when available. The reducer otherwise
    /// leaves it nil rather than presenting process uptime as task duration.
    var taskStartedAt: Date? = nil
    var stateChangedAt: Date? = nil
    var lastProgressAt: Date? = nil
    var attentionKind: AttentionKind? = nil
    var lifecycleReason: String? = nil
    var capabilities: AgentCapabilities = []
    var surfaceID: IntegrationSurfaceID = .process
    /// Stable semantic task retained by the lifecycle reducer when a provider's
    /// latest prompt is only an acknowledgement such as “继续” or “go ahead”.
    var taskAnchor: String? = nil
    /// Observation identity for revalidating a process-owned return endpoint.
    var processStartedAt: String? = nil

    var integrationProfile: IntegrationProfile {
        IntegrationProfiles.profile(for: surfaceID, kind: kind)
    }

    var statusLabel: String {
        switch observation.mode {
        case .rich: return status.label
        case .processOnly: return status.isActive ? "Activity detected" : "Process detected"
        case .stale: return "Data stale"
        case .incompatible: return "Incompatible data"
        }
    }

    var displayStatusLabel: String { L10n.string(statusLabel) }
    /// "claude-opus-4-8" → "Opus 4.8", "claude-sonnet-5" → "Sonnet 5",
    /// "gpt-5-codex" → "GPT 5 Codex", "o4-mini" → "O4 Mini".
    var modelDisplay: String? {
        guard var id = model?.lowercased() else { return nil }
        // The agent chip already says Claude/Gemini — don't repeat it.
        for prefix in ["claude-", "gemini-"] where id.hasPrefix(prefix) {
            id.removeFirst(prefix.count)
        }
        // Strip a date suffix like -20251001.
        let parts = id.split(separator: "-").filter { !($0.count == 8 && Int($0) != nil) }
        guard parts.contains(where: { Int($0) == nil }) else { return model }
        var words: [String] = []
        for part in parts {
            if Int(part) != nil, let last = words.last, Int(last) != nil {
                words[words.count - 1] = last + "." + part  // version run: 4-8 → 4.8
            } else if Int(part) != nil {
                words.append(String(part))
            } else if part == "gpt" {
                words.append("GPT")
            } else {
                words.append(part.prefix(1).uppercased() + part.dropFirst())
            }
        }
        return words.joined(separator: " ")
    }

    /// The active plan/goal is a better task label than a conversation opener.
    /// Otherwise use the provider's latest real user message. Agent output and
    /// tool activity belong to `currentStepSummary`, never the task title.
    var currentTaskSummary: String? {
        taskAnchor
            ?? TaskPresentationResolver.resolve(
                project: displayTitle,
                previousTask: nil,
                lastPrompt: lastPrompt,
                todos: todos,
                activity: activity,
                isActive: status.isActive
            ).task
    }

    /// A concise live step kept separate from the task/goal. This prevents a
    /// tool activity such as "Editing files" from replacing the user's task.
    var currentStepSummary: String? {
        TaskPresentationResolver.currentStep(todos: todos, activity: activity, isActive: status.isActive)
    }

    var freshnessLabel: String {
        let seconds = max(0, Int(Date().timeIntervalSince(observation.updatedAt)))
        if seconds < 15 { return L10n.string("updated now") }
        if seconds < 60 { return L10n.format("updated %ds ago", seconds) }
        if seconds < 3_600 { return L10n.format("updated %dm ago", seconds / 60) }
        return L10n.format("updated %dh ago", seconds / 3_600)
    }

    var taskElapsedLabel: String? {
        guard let taskStartedAt else { return nil }
        let seconds = max(0, Int(Date().timeIntervalSince(taskStartedAt)))
        if seconds < 60 { return "<1m" }
        if seconds < 3_600 { return "\(seconds / 60)m" }
        return "\(seconds / 3_600)h \((seconds % 3_600) / 60)m"
    }

    var cardTimingLabel: String {
        taskElapsedLabel.map { "\($0) · \(freshnessLabel)" } ?? freshnessLabel
    }

    var effectiveCapabilities: AgentCapabilities {
        effectiveCapabilities(
            providerControlsEnabled: UserDefaults.standard.bool(forKey: Pref.providerControlsEnabled),
            claudeControlsEnabled: UserDefaults.standard.bool(forKey: Pref.claudeControlsEnabled))
    }

    func effectiveCapabilities(providerControlsEnabled: Bool, claudeControlsEnabled: Bool) -> AgentCapabilities {
        let profile = integrationProfile
        var result = capabilities.intersection(profile.capabilities)
        if processID != nil { result.insert(.observeProcess) }
        if observation.mode == .rich { result.insert(.observeSession) }
        if currentTaskSummary != nil { result.insert(.observeTask) }
        if currentStepSummary != nil { result.insert(.observeStep) }
        if profile.canAssertCompletion(authority: observation.authority) {
            result.insert(.observeCompletion)
        }
        if status == .needsAttention,
            profile.canAssertAttention(authority: observation.authority)
        {
            result.insert(.observeAttention)
        }
        let controlsEnabled = providerControlsEnabled
        if controlsEnabled, status == .needsAttention, openCodeControl?.questionRequestID != nil {
            result.formUnion([.observeAttention, .reply])
        }
        if controlsEnabled, status == .needsAttention, openCodeControl?.permission != nil {
            result.formUnion([.observeAttention, .approve])
        }
        if kind == .claude,
            status == .needsAttention,
            pendingQuestion != nil,
            claudeControlsEnabled
        {
            result.formUnion([.observeAttention, .reply])
        }
        if returnTarget.label != nil { result.insert(.providerReturn) }
        if returnTarget.isExact { result.insert(.exactReturn) }
        if codexManagedControl != nil {
            result.insert(.stop)
            if controlsEnabled { result.insert(.reply) }
        }
        if !controlsEnabled, kind != .claude { result.subtract([.reply, .approve]) }
        if kind == .claude, !claudeControlsEnabled || !TerminalBridge.canSend(to: self) {
            result.subtract([.reply, .approve])
        }
        if codexManagedControl == nil, status != .needsAttention { result.subtract([.reply, .approve]) }
        return result
    }

    var displayTitle: String {
        if let title, title.count > 1 { return title }
        return cwdDisplay
    }

    var projectDisplayTitle: String {
        guard let cwd, !cwd.isEmpty else { return displayTitle }
        return cwdDisplay
    }

    var cwdDisplay: String {
        guard let cwd, !cwd.isEmpty else { return kind.displayName + " session" }
        let base = (cwd as NSString).lastPathComponent
        return base.count > 1 ? base : kind.displayName + " session"
    }

}

/// Produces the single session list consumed by every UI surface.
///
/// A LoopFwd-managed Codex thread can also appear in Codex Desktop's read-only
/// registry. Both projections use the same stable ID; the managed projection
/// wins because it carries the live control capability.
enum SessionList {
    static func uniqued(_ sessions: [AgentSession]) -> [AgentSession] {
        var result: [AgentSession] = []
        var indices: [String: Int] = [:]
        for session in sessions {
            if let index = indices[session.id] {
                result[index] = session
            } else {
                indices[session.id] = result.count
                result.append(session)
            }
        }
        return result
    }

    static func merged(observed: [AgentSession], managed: [AgentSession]) -> [AgentSession] {
        var result = uniqued(observed)
        var indices = Dictionary(
            uniqueKeysWithValues: result.enumerated().map { ($0.element.id, $0.offset) }
        )

        for session in uniqued(managed) {
            if let index = indices[session.id] {
                let observedSession = result[index]
                var controlledSession = session
                // The managed projection owns control; the monitor's central
                // reducer owns cross-provider timing and stall classification.
                if observedSession.status == .stalled, controlledSession.status == .working {
                    controlledSession.status = .stalled
                    controlledSession.lifecycleReason = observedSession.lifecycleReason
                }
                controlledSession.stateChangedAt = observedSession.stateChangedAt
                controlledSession.lastProgressAt = observedSession.lastProgressAt
                controlledSession.taskStartedAt =
                    controlledSession.taskStartedAt ?? observedSession.taskStartedAt
                result[index] = controlledSession
            } else {
                indices[session.id] = result.count
                result.append(session)
            }
        }
        return result
    }
}

/// Presents successful completions as short-lived feedback, not active work.
/// Only a real `.agentCompleted` transition enters this window, so old
/// completed sessions found during startup never repopulate the live island.
final class OutcomePresentation: ObservableObject {
    static let shared = OutcomePresentation()
    static let completionDuration: TimeInterval = 5
    static let stoppedDuration: TimeInterval = 8

    typealias Scheduler = (_ delay: TimeInterval, _ action: @escaping () -> Void) -> Void

    private let notificationCenter: NotificationCenter
    private let now: () -> Date
    private let schedule: Scheduler
    private var completionObserver: NSObjectProtocol?
    private var stoppedObserver: NSObjectProtocol?
    private var failureObserver: NSObjectProtocol?
    @Published private var visibleUntil: [String: Date] = [:]
    @Published private var dismissedFailures = Set<String>()

    init(
        notificationCenter: NotificationCenter = .default,
        now: @escaping () -> Date = Date.init,
        schedule: @escaping Scheduler = { delay, action in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: action)
        }
    ) {
        self.notificationCenter = notificationCenter
        self.now = now
        self.schedule = schedule
        completionObserver = notificationCenter.addObserver(
            forName: .agentCompleted,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let sessionID = note.object as? String else { return }
            self?.present(sessionID: sessionID, duration: Self.completionDuration)
        }
        stoppedObserver = notificationCenter.addObserver(
            forName: .agentStopped,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let sessionID = note.object as? String else { return }
            self?.present(sessionID: sessionID, duration: Self.stoppedDuration)
        }
        failureObserver = notificationCenter.addObserver(
            forName: .agentFailed,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let sessionID = note.object as? String else { return }
            self?.dismissedFailures.remove(sessionID)
        }
    }

    deinit {
        if let completionObserver {
            notificationCenter.removeObserver(completionObserver)
        }
        if let stoppedObserver {
            notificationCenter.removeObserver(stoppedObserver)
        }
        if let failureObserver {
            notificationCenter.removeObserver(failureObserver)
        }
    }

    func visible(_ sessions: [AgentSession]) -> [AgentSession] {
        let current = now()
        return sessions.filter { session in
            if session.status == .failed { return !dismissedFailures.contains(session.id) }
            guard session.status == .completed || session.status == .stopped else { return true }
            return visibleUntil[session.id].map { $0 > current } ?? false
        }
    }

    func dismiss(_ session: AgentSession) {
        if session.status == .failed {
            dismissedFailures.insert(session.id)
            return
        }
        guard session.status == .completed || session.status == .stopped else { return }
        var next = visibleUntil
        next.removeValue(forKey: session.id)
        visibleUntil = next
    }

    private func present(sessionID: String, duration: TimeInterval) {
        let deadline = now().addingTimeInterval(duration)
        var next = visibleUntil
        next[sessionID] = deadline
        visibleUntil = next
        schedule(duration) { [weak self] in
            guard let self, self.visibleUntil[sessionID] == deadline else { return }
            var next = self.visibleUntil
            next.removeValue(forKey: sessionID)
            self.visibleUntil = next
        }
    }
}

/// Stale observations are useful during a brief reconnect, but they are not
/// active work and must not remain in the island forever after a provider exits.
enum SessionVisibility {
    static let staleGracePeriod: TimeInterval = 20

    static func keepsStaleObservation(
        updatedAt: Date,
        providerIsRunning: Bool,
        gracePeriod: TimeInterval = staleGracePeriod,
        now: Date = Date()
    ) -> Bool {
        providerIsRunning || now.timeIntervalSince(updatedAt) <= gracePeriod
    }
}

struct ChatMessage: Identifiable, Equatable {
    let id: Int
    let isUser: Bool
    let text: String
}
