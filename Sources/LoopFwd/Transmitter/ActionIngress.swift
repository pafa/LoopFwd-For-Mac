import Foundation

/// Hub → Mac action ingress. Revalidates live requestId, then executes through
/// existing ApprovalCenter / OpenCode / Codex paths. Fail closed.
enum ActionIngress {
    static func handle(
        _ envelope: RemoteActionEnvelope,
        macDeviceId: String,
        macOnline: Bool,
        project: (AgentSession) -> SessionProjection
    ) async -> ActionResult {
        var env = envelope
        env.normalize()

        guard env.macDeviceId == macDeviceId else {
            return ActionResult(
                clientActionId: env.clientActionId,
                status: .unauthorized,
                message: "macDeviceId mismatch",
                session: nil
            )
        }
        guard macOnline else {
            return ActionResult(
                clientActionId: env.clientActionId,
                status: .offline,
                message: "Mac transmitter offline",
                session: nil
            )
        }

        let agents = await MainActor.run { () -> [AgentSession] in
            SessionPresentationPolicy.visible(
                SessionList.merged(
                    observed: AgentMonitor.shared.agents,
                    managed: CodexAppServer.shared.agents
                )
            )
        }
        guard let agent = agents.first(where: { $0.id == env.sessionId }) else {
            return ActionResult(
                clientActionId: env.clientActionId,
                status: .rejected,
                message: "Unknown session",
                session: nil
            )
        }

        let projection = await MainActor.run { project(agent) }
        if projection.observationStale {
            return ActionResult(
                clientActionId: env.clientActionId,
                status: .rejected,
                message: "Observation stale",
                session: projection
            )
        }

        switch env.action {
        case .approve, .deny, .alwaysAllow:
            return await handleApproval(env, agent: agent, projection: projection, project: project)
        case .selectOptions:
            return await handleSelectOptions(env, agent: agent, projection: projection, project: project)
        case .replyText:
            return await handleReplyText(env, agent: agent, projection: projection, project: project)
        case .stop:
            return await handleStop(env, agent: agent, projection: projection, project: project)
        }
    }

    // MARK: - Approval

    private static func handleApproval(
        _ env: RemoteActionEnvelope,
        agent: AgentSession,
        projection: SessionProjection,
        project: (AgentSession) -> SessionProjection
    ) async -> ActionResult {
        guard projection.capabilities.approve, let approval = projection.approval else {
            return rejected(env, "No approve capability", projection)
        }
        if approval.expiresAt <= Date() || env.requestId != approval.requestId {
            return expired(env, projection)
        }
        if env.action == .alwaysAllow, !approval.actions.contains(.alwaysAllow) {
            return rejected(env, "alwaysAllow not offered", projection)
        }

        let macAction: ApprovalCenter.Action
        switch env.action {
        case .approve: macAction = .approve
        case .alwaysAllow: macAction = .alwaysAllow
        case .deny: macAction = .deny
        default: return rejected(env, "Invalid approval action", projection)
        }

        // Claude path
        if let live = await MainActor.run(body: { ApprovalCenter.shared.approval(for: agent) }),
            SessionProjector.claudeApprovalRequestId(live) == env.requestId
        {
            guard let pid = agent.processID else {
                return expired(env, projection)
            }
            let ok = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                DispatchQueue.main.async {
                    ApprovalCenter.shared.respond(pid: pid, action: macAction) { cont.resume(returning: $0) }
                }
            }
            return await finish(env, success: ok, sessionId: agent.id, project: project)
        }

        // OpenCode path — revalidates request on loopback before reply
        if let control = agent.openCodeControl, control.permission?.requestID == env.requestId {
            let reply: OpenCodeSessions.PermissionReply
            switch macAction {
            case .approve: reply = .once
            case .alwaysAllow: reply = .always
            case .deny: reply = .reject
            }
            let ok = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                OpenCodeSessions.replyPermission(control: control, reply: reply) { cont.resume(returning: $0) }
            }
            return await finish(env, success: ok, sessionId: agent.id, project: project)
        }

        return expired(env, projection)
    }

    // MARK: - Question / reply

    private static func handleSelectOptions(
        _ env: RemoteActionEnvelope,
        agent: AgentSession,
        projection: SessionProjection,
        project: (AgentSession) -> SessionProjection
    ) async -> ActionResult {
        guard projection.capabilities.reply, let question = projection.pendingQuestion else {
            return rejected(env, "No pending question", projection)
        }
        if question.expiresAt <= Date() || env.requestId != question.requestId {
            return expired(env, projection)
        }
        let indexes = env.optionIndexes ?? []
        if question.multiSelect {
            guard !indexes.isEmpty else { return rejected(env, "Empty optionIndexes", projection) }
        } else {
            guard indexes.count == 1 else { return rejected(env, "Expected exactly one option", projection) }
        }
        guard indexes.allSatisfy({ $0 >= 0 && $0 < question.options.count }) else {
            return rejected(env, "optionIndexes out of range", projection)
        }
        let answers = indexes.map { question.options[$0] }
        return await submitAnswers(env, agent: agent, requestId: question.requestId, answers: answers, project: project)
    }

    private static func handleReplyText(
        _ env: RemoteActionEnvelope,
        agent: AgentSession,
        projection: SessionProjection,
        project: (AgentSession) -> SessionProjection
    ) async -> ActionResult {
        guard projection.capabilities.reply else {
            return rejected(env, "No reply capability", projection)
        }
        let text = (env.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return rejected(env, "Empty reply text", projection) }

        if let question = projection.pendingQuestion {
            if question.expiresAt <= Date() || env.requestId != question.requestId {
                return expired(env, projection)
            }
            return await submitAnswers(
                env, agent: agent, requestId: question.requestId, answers: [text], project: project)

        }

        // Codex managed free-text (no pending question requestId required beyond session)
        if let control = agent.codexManagedControl {
            let ok = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                CodexAppServer.shared.send(text, to: control.threadID) { result in
                    cont.resume(returning: (try? result.get()) != nil)
                }
            }
            return await finish(env, success: ok, sessionId: agent.id, project: project)
        }

        return rejected(env, "No reply target", projection)
    }

    private static func submitAnswers(
        _ env: RemoteActionEnvelope,
        agent: AgentSession,
        requestId: String,
        answers: [String],
        project: (AgentSession) -> SessionProjection
    ) async -> ActionResult {
        // OpenCode
        if let control = agent.openCodeControl, control.questionRequestID == requestId {
            let ok = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                OpenCodeSessions.answerQuestion(control: control, answers: answers) { cont.resume(returning: $0) }
            }
            return await finish(env, success: ok, sessionId: agent.id, project: project)
        }

        // Claude — send option number or free text through terminal after identity match
        if let entry = await MainActor.run(body: { ApprovalCenter.shared.question(for: agent) }),
            entry.requestID == requestId
        {
            let payload: String
            if answers.count == 1, let idx = entry.question.options.firstIndex(of: answers[0]) {
                payload = String(idx + 1)
            } else {
                payload = answers.joined(separator: ", ")
            }
            let ok = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                DispatchQueue.main.async {
                    ApprovalCenter.shared.answerQuestion(text: payload, to: agent) { cont.resume(returning: $0) }
                }
            }
            return await finish(env, success: ok, sessionId: agent.id, project: project)
        }

        return await expired(env, sessionId: agent.id, project: project)
    }

    // MARK: - Stop

    private static func handleStop(
        _ env: RemoteActionEnvelope,
        agent: AgentSession,
        projection: SessionProjection,
        project: (AgentSession) -> SessionProjection
    ) async -> ActionResult {
        guard projection.capabilities.stop, let control = agent.codexManagedControl else {
            return rejected(env, "No stop capability", projection)
        }
        let ok = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            CodexAppServer.shared.interrupt(threadID: control.threadID) { result in
                cont.resume(returning: (try? result.get()) != nil)
            }
        }
        return await finish(env, success: ok, sessionId: agent.id, project: project)
    }

    // MARK: - Helpers

    private static func finish(
        _ env: RemoteActionEnvelope,
        success: Bool,
        sessionId: String,
        project: (AgentSession) -> SessionProjection
    ) async -> ActionResult {
        // Brief pause so monitor/hooks can clear the live request before projecting.
        try? await Task.sleep(nanoseconds: 350_000_000)
        await MainActor.run { AgentMonitor.shared.scanNow() }
        try? await Task.sleep(nanoseconds: 200_000_000)
        let session = await MainActor.run { () -> SessionProjection? in
            let agents = SessionPresentationPolicy.visible(
                SessionList.merged(
                    observed: AgentMonitor.shared.agents,
                    managed: CodexAppServer.shared.agents
                )
            )
            return agents.first(where: { $0.id == sessionId }).map(project)
        }
        if success {
            return ActionResult(
                clientActionId: env.clientActionId,
                status: .accepted,
                message: nil,
                session: session
            )
        }
        return ActionResult(
            clientActionId: env.clientActionId,
            status: .rejected,
            message: "Request expired or could not be reached",
            session: session
        )
    }

    private static func rejected(
        _ env: RemoteActionEnvelope, _ message: String, _ session: SessionProjection?
    ) -> ActionResult {
        ActionResult(clientActionId: env.clientActionId, status: .rejected, message: message, session: session)
    }

    private static func expired(
        _ env: RemoteActionEnvelope, _ session: SessionProjection?
    ) -> ActionResult {
        ActionResult(
            clientActionId: env.clientActionId, status: .expired, message: "Request expired", session: session)
    }

    private static func expired(
        _ env: RemoteActionEnvelope, sessionId: String, project: (AgentSession) -> SessionProjection
    ) async -> ActionResult {
        let session = await MainActor.run { () -> SessionProjection? in
            let agents = SessionPresentationPolicy.visible(
                SessionList.merged(
                    observed: AgentMonitor.shared.agents,
                    managed: CodexAppServer.shared.agents
                )
            )
            return agents.first(where: { $0.id == sessionId }).map(project)
        }
        return expired(env, session)
    }
}
