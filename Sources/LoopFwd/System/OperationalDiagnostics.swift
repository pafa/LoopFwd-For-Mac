import Foundation

struct IslandNotice: Equatable {
    let sessionID: String?
    let title: String
    let message: String
    let createdAt: Date
    var recovery: NoticeRecovery? = nil
}

enum NoticeRecovery: Equatable {
    case refreshTasks, setup, agents
    var label: String {
        switch self {
        case .refreshTasks: return "Refresh tasks"
        case .setup: return "Setup status"
        case .agents: return "Agents"
        }
    }
}

/// Bounded, in-memory operational evidence. It intentionally records decisions
/// and error classes, never prompts, full paths, credentials, or transcripts.
final class OperationalDiagnostics: ObservableObject {
    static let shared = OperationalDiagnostics()

    @Published private(set) var lastNotificationDecision: String?
    @Published private(set) var lastReturnFailure: String?
    @Published private(set) var lastControlFailure: String?
    @Published private(set) var notice: IslandNotice?

    private var noticeRevision = 0

    func recordNotification(_ value: String) {
        publish { self.lastNotificationDecision = DiagnosticsSanitizer.sanitize(value) }
    }

    func recordReturnFailure(_ value: String) {
        publish { self.lastReturnFailure = DiagnosticsSanitizer.sanitize(value) }
    }

    func recordControlFailure(_ value: String) {
        publish { self.lastControlFailure = DiagnosticsSanitizer.sanitize(value) }
    }

    func showReturnFailure(_ result: ReturnExecutionResult, session: AgentSession) {
        let recovery: NoticeRecovery
        switch result.failure {
        case .targetExpired: recovery = .refreshTasks
        case .applicationUnavailable: recovery = .agents
        default: recovery = .setup
        }
        showNotice(
            sessionID: session.id, title: session.displayTitle,
            message: L10n.string(result.reason ?? ReturnFailure.helperFailed.message),
            duration: 12, recovery: recovery)
    }

    func showNotice(
        sessionID: String?, title: String, message: String, duration: TimeInterval = 7,
        recovery: NoticeRecovery? = nil
    ) {
        publish {
            self.noticeRevision += 1
            let revision = self.noticeRevision
            self.notice = IslandNotice(
                sessionID: sessionID,
                title: title,
                message: message,
                createdAt: Date(), recovery: recovery
            )
            DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
                guard let self, revision == self.noticeRevision else { return }
                self.notice = nil
            }
        }
    }

    func dismissNotice() {
        publish {
            self.noticeRevision += 1
            self.notice = nil
        }
    }

    private func publish(_ action: @escaping () -> Void) {
        if Thread.isMainThread { action() } else { DispatchQueue.main.async(execute: action) }
    }
}
