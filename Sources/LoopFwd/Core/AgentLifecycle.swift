import Foundation

enum AgentLifecycleEventKind: String, Equatable {
    case started
    case resumed
    case completed
    case needsAttention
    case failed
    case stopped
    case stalled
}

struct AgentLifecycleEvent: Equatable {
    let kind: AgentLifecycleEventKind
    let session: AgentSession
    let occurredAt: Date

    /// Stable for one semantic transition. Notification delivery can safely
    /// retry without producing a second banner for the same turn event.
    var deduplicationKey: String {
        let turn = session.turnID ?? "source:\(Int(session.observation.updatedAt.timeIntervalSince1970 * 1000))"
        let content = [
            session.attentionKind?.rawValue ?? "",
            session.lastMessage ?? "",
            session.activity ?? "",
            session.openCodeControl?.questionRequestID ?? "",
            session.openCodeControl?.permission?.requestID ?? "",
        ].joined(separator: "\u{1f}")
        return
            "\(session.kind.rawValue):\(session.id):\(turn):\(kind.rawValue):\(Self.stableToken(content))"
    }

    private static func stableToken(_ text: String) -> String {
        var value: UInt64 = 14_695_981_039_346_656_037
        for byte in text.utf8 {
            value ^= UInt64(byte)
            value &*= 1_099_511_628_211
        }
        return String(value, radix: 16)
    }
}

struct AgentLifecycleReduction: Equatable {
    let sessions: [AgentSession]
    let events: [AgentLifecycleEvent]
}

/// Converts provider projections into one lifecycle contract. Readers remain
/// independent parsers; this reducer owns cross-provider transitions, progress
/// freshness, stalling, and the event boundary used by UI and notifications.
final class AgentLifecycleReducer {
    static let defaultStalledAfter: TimeInterval = 3 * 60

    private struct Snapshot {
        let session: AgentSession
        let fingerprint: String
        let sourceUpdatedAt: Date
        let lastProgressAt: Date
        let stateChangedAt: Date
        let taskStartedAt: Date?
        let attentionSignature: String?
        let missingSince: Date?
    }

    private var snapshots: [String: Snapshot] = [:]
    private let stalledAfterOverride: TimeInterval?

    init(stalledAfter: TimeInterval? = nil) {
        stalledAfterOverride = stalledAfter
    }

    func reduce(
        _ observed: [AgentSession],
        suppressEvents: Bool,
        now: Date = Date()
    ) -> AgentLifecycleReduction {
        var normalized: [AgentSession] = []
        var events: [AgentLifecycleEvent] = []
        var nextSnapshots: [String: Snapshot] = [:]

        let uniqueObservations = SessionList.uniqued(observed)
        for raw in uniqueObservations {
            var session = raw
            // Promote a temporary process identity only when it maps uniquely
            // to this provider session; one server can own multiple sessions.
            let provisionalID = session.processID.map { "process:\(session.kind.rawValue):\($0)" }
            let canPromote =
                provisionalID != session.id
                && uniqueObservations.filter {
                    $0.processID == session.processID && $0.kind == session.kind
                }.count == 1
            let migrated = canPromote ? provisionalID.flatMap { snapshots.removeValue(forKey: $0) } : nil
            let previous = snapshots[session.id] ?? migrated
            if let previous, previous.session.lastPrompt == session.lastPrompt,
                previous.session.todos == session.todos
            {
                session.taskAnchor = previous.session.taskAnchor
            } else {
                session.taskAnchor =
                    TaskPresentationResolver.resolve(
                        project: session.displayTitle,
                        previousTask: previous?.session.taskAnchor ?? previous?.session.currentTaskSummary,
                        lastPrompt: session.lastPrompt,
                        todos: session.todos,
                        activity: session.activity,
                        isActive: session.status.isActive
                    ).task
            }
            let fingerprint = Self.progressFingerprint(session)
            let sourceUpdatedAt = min(session.observation.updatedAt, now)
            let unhealthy = session.observation.mode == .stale || session.observation.mode == .incompatible
            let unavailableSince: Date? = unhealthy ? previous?.missingSince ?? now : nil
            let expired =
                unavailableSince.map {
                    now.timeIntervalSince($0) > session.integrationProfile.reconciliationGrace
                } ?? false
            let madeProgress =
                previous.map {
                    fingerprint != $0.fingerprint || sourceUpdatedAt > $0.sourceUpdatedAt
                } ?? true
            let lastProgressAt =
                madeProgress
                ? max(sourceUpdatedAt, previous?.lastProgressAt ?? sourceUpdatedAt)
                : previous?.lastProgressAt ?? sourceUpdatedAt

            var normalizedStatus = session.status
            let profile = session.integrationProfile
            if normalizedStatus == .completed,
                !profile.canAssertCompletion(authority: session.observation.authority)
            {
                normalizedStatus = .idle
                session.lifecycleReason = "No successful turn boundary could be confirmed"
            }
            if normalizedStatus == .needsAttention,
                !profile.canAssertAttention(authority: session.observation.authority)
            {
                normalizedStatus = previous?.session.status.isActive == true ? .working : .idle
                session.lifecycleReason = "No live user request could be confirmed"
            }
            if session.status == .idle,
                session.observation.mode == .stale || session.observation.mode == .incompatible,
                let previousStatus = previous?.session.status,
                previousStatus != .idle
            {
                // A broken/old reader does not prove that a turn became idle.
                // Keep the last known phase while health communicates the loss
                // of certainty and the provider's grace policy decides expiry.
                normalizedStatus = previousStatus
                session.lifecycleReason = session.observation.reason
            }
            let stalledAfter = stalledAfterOverride ?? Self.stalledThreshold(for: session)
            if session.status == .working,
                session.observation.mode == .rich,
                now.timeIntervalSince(lastProgressAt) >= stalledAfter
            {
                normalizedStatus = .stalled
                session.lifecycleReason = "No provider-backed progress for \(Int(stalledAfter / 60)) minutes"
            }

            let previousStatus = previous?.session.status
            let statusChanged = previousStatus != normalizedStatus
            let stateChangedAt = statusChanged ? now : previous?.stateChangedAt ?? now
            let taskStartedAt: Date?
            if normalizedStatus.isActive {
                if previousStatus?.isActive == true {
                    taskStartedAt = previous?.taskStartedAt
                } else if let providerStart = session.taskStartedAt {
                    taskStartedAt = providerStart
                } else if !suppressEvents,
                    session.observation.mode == .rich,
                    session.observation.authority != .processHeuristic
                {
                    taskStartedAt = now
                } else {
                    taskStartedAt = nil
                }
            } else {
                taskStartedAt = session.taskStartedAt ?? previous?.taskStartedAt
            }

            session.status = normalizedStatus
            session.lastProgressAt = lastProgressAt
            session.stateChangedAt = stateChangedAt
            session.taskStartedAt = taskStartedAt
            session.attentionKind = session.attentionKind ?? Self.attentionKind(session)
            session.capabilities = Self.normalizedCapabilities(session)

            let attentionSignature = Self.attentionSignature(session)
            if !suppressEvents && !unhealthy {
                events.append(
                    contentsOf: Self.events(
                        current: session,
                        previous: previous?.session,
                        previousAttentionSignature: previous?.attentionSignature,
                        attentionSignature: attentionSignature,
                        occurredAt: stateChangedAt
                    ))
            }

            if !expired { normalized.append(session) }
            nextSnapshots[session.id] = Snapshot(
                session: session,
                fingerprint: fingerprint,
                sourceUpdatedAt: sourceUpdatedAt,
                lastProgressAt: lastProgressAt,
                stateChangedAt: stateChangedAt,
                taskStartedAt: taskStartedAt,
                attentionSignature: attentionSignature,
                missingSince: unavailableSince
            )
        }

        // A provider can disappear for one polling cycle while replacing a
        // registry file or reconnecting its local API. Keep the last trusted
        // phase briefly and mark observation health stale instead of creating a
        // false stop/start pair and duplicate notification.
        let observedIDs = Set(uniqueObservations.map(\.id))
        for (id, previous) in snapshots where !observedIDs.contains(id) {
            // A single interactive CLI may resume a different thread without
            // exiting. A verified new binding retires only its old projection,
            // not the provider's task, and does not invent a stop/completion.
            if previous.session.surfaceID == .codexCLI,
                let pid = previous.session.processID,
                let start = previous.session.processStartedAt,
                uniqueObservations.contains(where: {
                    $0.surfaceID == .codexCLI && $0.processID == pid && $0.processStartedAt == start
                        && $0.id != id && !$0.id.hasPrefix("process:") && $0.observation.mode == .rich
                })
            {
                continue
            }
            let missingSince = previous.missingSince ?? now
            let grace = previous.session.integrationProfile.reconciliationGrace
            guard now.timeIntervalSince(missingSince) <= grace else { continue }

            var retained = previous.session
            retained.observation = .init(
                mode: .stale,
                updatedAt: previous.sourceUpdatedAt,
                source: previous.session.observation.source,
                reason: "Temporarily unavailable; reconciling the provider session",
                authority: previous.session.observation.authority
            )
            normalized.append(retained)
            nextSnapshots[id] = Snapshot(
                session: retained,
                fingerprint: previous.fingerprint,
                sourceUpdatedAt: previous.sourceUpdatedAt,
                lastProgressAt: previous.lastProgressAt,
                stateChangedAt: previous.stateChangedAt,
                taskStartedAt: previous.taskStartedAt,
                attentionSignature: previous.attentionSignature,
                missingSince: missingSince
            )
        }

        snapshots = nextSnapshots
        return AgentLifecycleReduction(
            sessions: SessionPresentationPolicy.sorted(normalized),
            events: events
        )
    }

    private static func events(
        current: AgentSession,
        previous: AgentSession?,
        previousAttentionSignature: String?,
        attentionSignature: String?,
        occurredAt: Date
    ) -> [AgentLifecycleEvent] {
        guard let previous else {
            guard current.status.isActive,
                current.observation.mode == .rich,
                current.observation.authority != .processHeuristic
            else { return [] }
            let kind: AgentLifecycleEventKind = current.status == .needsAttention ? .needsAttention : .started
            return [.init(kind: kind, session: current, occurredAt: occurredAt)]
        }

        var result: [AgentLifecycleEvent] = []
        let profile = current.integrationProfile
        let canAssertBoundary = profile.canAssertCompletion(
            authority: current.observation.authority)
        switch (previous.status, current.status) {
        case (_, .needsAttention)
        where profile.canAssertAttention(authority: current.observation.authority)
            && (previous.status != .needsAttention || previousAttentionSignature != attentionSignature):
            result.append(.init(kind: .needsAttention, session: current, occurredAt: occurredAt))
        case (_, .completed)
        where canAssertBoundary
            && [AgentStatus.working, .stalled, .needsAttention].contains(previous.status):
            result.append(.init(kind: .completed, session: current, occurredAt: occurredAt))
        case (_, .failed) where previous.status != .failed && canAssertBoundary:
            result.append(.init(kind: .failed, session: current, occurredAt: occurredAt))
        case (_, .stopped) where previous.status != .stopped && canAssertBoundary:
            result.append(.init(kind: .stopped, session: current, occurredAt: occurredAt))
        case (.working, .stalled):
            result.append(.init(kind: .stalled, session: current, occurredAt: occurredAt))
        case (_, .working)
        where current.observation.authority != .processHeuristic
            && [
                AgentStatus.completed, .needsAttention, .failed, .stopped, .stalled, .idle,
            ].contains(previous.status):
            result.append(.init(kind: .resumed, session: current, occurredAt: occurredAt))
        default:
            break
        }
        return result
    }

    private static func progressFingerprint(_ session: AgentSession) -> String {
        let todos = session.todos.map { "\($0.status):\($0.content)" }.joined(separator: "|")
        return [
            session.currentTaskSummary ?? "",
            session.activity ?? "",
            session.lastMessage ?? "",
            todos,
        ].joined(separator: "\u{1f}")
    }

    private static func attentionSignature(_ session: AgentSession) -> String? {
        if let permission = session.openCodeControl?.permission {
            return "permission:\(permission.requestID)"
        }
        if let request = session.openCodeControl?.questionRequestID {
            return "question:\(request)"
        }
        if let question = session.pendingQuestion {
            return "question:\(question.prompt):\(question.options.joined(separator: "|"))"
        }
        guard session.status == .needsAttention else { return nil }
        return "attention:\(session.lastMessage ?? session.activity ?? session.id)"
    }

    private static func attentionKind(_ session: AgentSession) -> AttentionKind? {
        if session.openCodeControl?.permission != nil { return .approval }
        if session.pendingQuestion != nil || session.openCodeControl?.questionRequestID != nil {
            return .question
        }
        guard session.status == .needsAttention else { return nil }
        let text = [session.activity, session.lastMessage]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")
        if text.contains("auth") || text.contains("login") || text.contains("sign in") {
            return .authentication
        }
        if text.contains("confirm") { return .confirmation }
        return .approval
    }

    private static func normalizedCapabilities(_ session: AgentSession) -> AgentCapabilities {
        session.effectiveCapabilities
    }

    private static func stalledThreshold(for session: AgentSession) -> TimeInterval {
        let normal = session.integrationProfile.stalledAfter
        let activity = session.activity?.lowercased() ?? ""
        let longRunningMarkers = [
            "build", "test", "install", "download", "compile", "archive", "render", "deploy",
            "构建", "测试", "安装", "下载", "编译", "打包", "渲染", "部署",
        ]
        return longRunningMarkers.contains(where: activity.contains) ? max(normal, 10 * 60) : normal
    }
}

enum SessionPresentationPolicy {
    /// Active island = current work and actionable outcomes. Idle process
    /// inventory remains available to Diagnostics instead of crowding the UI.
    static func visible(_ sessions: [AgentSession]) -> [AgentSession] {
        sorted(
            sessions.filter { session in
                switch session.status {
                case .working, .stalled, .needsAttention, .failed, .completed:
                    return true
                case .stopped:
                    return true
                case .idle:
                    return false
                }
            })
    }

    static func sorted(_ sessions: [AgentSession]) -> [AgentSession] {
        sessions.sorted {
            let lhsRank = rank($0.status)
            let rhsRank = rank($1.status)
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            let lhsDate = $0.stateChangedAt ?? $0.observation.updatedAt
            let rhsDate = $1.stateChangedAt ?? $1.observation.updatedAt
            if lhsDate != rhsDate { return lhsDate > rhsDate }
            return ($0.kind.rawValue, $0.id) < ($1.kind.rawValue, $1.id)
        }
    }

    private static func rank(_ status: AgentStatus) -> Int {
        switch status {
        case .needsAttention: return 0
        case .failed: return 1
        case .stalled: return 2
        case .working: return 3
        case .completed: return 4
        case .stopped: return 5
        case .idle: return 6
        }
    }
}

enum SessionAccessPolicy {
    /// The normal island stays compact, while an explicit expansion or the
    /// keyboard switcher exposes every active session in the same sorted list.
    static func displayed(
        _ sessions: [AgentSession],
        maximum: Int,
        showAll: Bool,
        switcherActive: Bool
    ) -> [AgentSession] {
        if showAll || switcherActive { return sessions }
        return Array(sessions.prefix(max(1, maximum)))
    }
}

enum AgentLifecycleEventEmitter {
    static func emit(
        _ events: [AgentLifecycleEvent],
        center: NotificationCenter = .default
    ) {
        for event in events {
            center.post(name: .agentLifecycleEvent, object: event)
            let legacyName: Notification.Name
            switch event.kind {
            case .started: legacyName = .agentStarted
            case .resumed: legacyName = .agentAcknowledged
            case .completed: legacyName = .agentCompleted
            case .needsAttention: legacyName = .approvalNeeded
            case .failed: legacyName = .agentFailed
            case .stopped: legacyName = .agentStopped
            case .stalled: legacyName = .agentStalled
            }
            center.post(name: legacyName, object: event.session.id)
        }
    }
}
