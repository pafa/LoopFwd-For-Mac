import Foundation

/// Maps trusted Mac `AgentSession` (+ ApprovalCenter overlays) → SessionProjection.
enum SessionProjector {
    static let approvalTTL: TimeInterval = 10 * 60
    static let questionTTL: TimeInterval = 30 * 60

    static func project(
        agents: [AgentSession],
        macDeviceId: String,
        macOnline: Bool
    ) -> [SessionProjection] {
        agents.map { project(agent: $0, macDeviceId: macDeviceId, macOnline: macOnline) }
    }

    static func project(
        agent: AgentSession,
        macDeviceId: String,
        macOnline: Bool
    ) -> SessionProjection {
        let caps = agent.effectiveCapabilities
        let stale = agent.observation.mode == .stale || agent.observation.mode == .incompatible
        var pendingQuestion: RemotePendingQuestion?
        var approval: RemoteApprovalRequest?
        var attention = agent.attentionKind.map(mapAttention)
        var status = mapStatus(agent.status)

        if let entry = ApprovalCenter.shared.question(for: agent), agent.status == .needsAttention {
            pendingQuestion = RemotePendingQuestion(
                prompt: entry.question.prompt,
                options: entry.question.options,
                multiSelect: entry.question.multiSelect,
                requestId: entry.requestID,
                expiresAt: entry.at.addingTimeInterval(questionTTL)
            )
            attention = .question
            status = .needsAttention
        } else if let control = agent.openCodeControl, let qid = control.questionRequestID,
            let question = agent.pendingQuestion, agent.status == .needsAttention
        {
            pendingQuestion = RemotePendingQuestion(
                prompt: question.prompt,
                options: question.options,
                multiSelect: question.multiSelect,
                requestId: qid,
                expiresAt: agent.observation.updatedAt.addingTimeInterval(questionTTL)
            )
            attention = .question
            status = .needsAttention
        }

        if let live = ApprovalCenter.shared.approval(for: agent), agent.status == .needsAttention {
            approval = RemoteApprovalRequest(
                title: live.toolName.map { "Allow \($0)" } ?? "Allow tool",
                toolName: live.toolName,
                message: live.message,
                actions: [.approve, .alwaysAllow, .deny],
                requestId: claudeApprovalRequestId(live),
                expiresAt: live.at.addingTimeInterval(approvalTTL)
            )
            attention = .approval
            status = .needsAttention
            pendingQuestion = nil
        } else if let permission = agent.openCodeControl?.permission, agent.status == .needsAttention {
            approval = RemoteApprovalRequest(
                title: "Allow \(permission.name)",
                toolName: permission.name,
                message: permission.patterns.isEmpty ? nil : permission.patterns.joined(separator: ", "),
                actions: [.approve, .alwaysAllow, .deny],
                requestId: permission.requestID,
                expiresAt: agent.observation.updatedAt.addingTimeInterval(approvalTTL)
            )
            attention = .approval
            status = .needsAttention
            pendingQuestion = nil
        }

        // Fail closed: never advertise controls without a live requestId / capability.
        let canApprove = caps.contains(.approve) && approval != nil && !stale && macOnline
        let canReply =
            caps.contains(.reply)
            && (pendingQuestion != nil || agent.codexManagedControl != nil)
            && !stale && macOnline
        let canStop = caps.contains(.stop) && agent.codexManagedControl != nil && !stale && macOnline

        return SessionProjection(
            sessionId: agent.id,
            macDeviceId: macDeviceId,
            kind: agent.kind.rawValue,
            surfaceId: agent.surfaceID.rawValue,
            title: agent.displayTitle,
            project: agent.projectDisplayTitle,
            status: status,
            attentionKind: attention,
            activity: agent.currentStepSummary ?? agent.activity,
            taskSummary: agent.currentTaskSummary,
            updatedAt: agent.observation.updatedAt,
            pendingQuestion: pendingQuestion,
            approval: approval,
            capabilities: RemoteSessionCapabilities(
                observe: true,
                reply: canReply,
                approve: canApprove,
                stop: canStop,
                openDetail: false
            ),
            macOnline: macOnline,
            observationStale: stale
        )
    }

    static func claudeApprovalRequestId(_ approval: ApprovalCenter.Approval) -> String {
        claudeApprovalRequestIdComponents(
            sessionID: approval.identity.sessionID,
            processID: approval.identity.processID,
            processStartedAt: approval.identity.processStartedAt
        )
    }

    static func claudeApprovalRequestIdComponents(
        sessionID: String, processID: Int32, processStartedAt: String
    ) -> String {
        "claude-appr:\(sessionID):\(processID):\(processStartedAt)"
    }

    private static func mapStatus(_ status: AgentStatus) -> RemoteSessionStatus {
        switch status {
        case .working: return .working
        case .stalled: return .stalled
        case .completed: return .completed
        case .needsAttention: return .needsAttention
        case .failed: return .failed
        case .stopped: return .stopped
        case .idle: return .idle
        }
    }

    private static func mapAttention(_ kind: AttentionKind) -> RemoteAttentionKind {
        switch kind {
        case .question: return .question
        case .approval: return .approval
        case .authentication: return .authentication
        case .confirmation: return .confirmation
        }
    }
}
