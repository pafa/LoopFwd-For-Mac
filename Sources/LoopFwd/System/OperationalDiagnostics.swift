import Foundation

struct IslandNotice: Equatable {
    let sessionID: String?
    let title: String
    let message: String
    let createdAt: Date
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

    func showNotice(sessionID: String?, title: String, message: String, duration: TimeInterval = 7) {
        publish {
            self.noticeRevision += 1
            let revision = self.noticeRevision
            self.notice = IslandNotice(
                sessionID: sessionID,
                title: title,
                message: message,
                createdAt: Date()
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
