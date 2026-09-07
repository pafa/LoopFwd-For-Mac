import Foundation

/// Version metadata actually observed, never the compatibility range of a
/// reader. Missing metadata remains unknown; no CLI is launched to fill it.
struct ProviderVersionEvidence: Equatable {
    let value: String
    let source: String

    static func metadata(_ value: String?, source: String) -> Self? {
        guard let value, value.utf8.count <= 80,
            value.range(of: #"^v?[0-9][0-9A-Za-z.+_-]*$"#, options: .regularExpression) != nil
        else { return nil }
        return .init(value: value, source: source)
    }
}

/// Empty is a successful observation, not a synonym for a failed read.
struct ProviderReadResult {
    enum Outcome: String { case success, empty, failed, incompatible, partial }
    let outcome: Outcome
    let source: String
    let sessions: [AgentSession]
    let reason: String?
    var successful: Bool { outcome == .success || outcome == .empty }

    static func read(_ sessions: [AgentSession], source: String) -> Self {
        .init(outcome: sessions.isEmpty ? .empty : .success, source: source, sessions: sessions, reason: nil)
    }

    static func failed(_ source: String, reason: String, incompatible: Bool = false) -> Self {
        .init(outcome: incompatible ? .incompatible : .failed, source: source, sessions: [], reason: reason)
    }

    static func observations(_ sessions: [AgentSession], source: String) -> Self {
        let unhealthy = sessions.filter { $0.observation.mode != .rich }
        guard !unhealthy.isEmpty else { return .read(sessions, source: source) }
        let outcome: Outcome =
            unhealthy.count < sessions.count
            ? .partial
            : unhealthy.allSatisfy { $0.observation.mode == .incompatible } ? .incompatible : .failed
        return .init(
            outcome: outcome, source: source, sessions: sessions,
            reason: unhealthy.first?.observation.reason ?? "Session data could not be confirmed")
    }

    /// One healthy process must not conceal another process's failed read.
    func merging(_ other: Self) -> Self {
        let combined = sessions + other.sessions
        if successful && other.successful { return .read(combined, source: source) }
        return .init(
            outcome: combined.isEmpty ? (successful ? other.outcome : outcome) : .partial,
            source: source, sessions: combined, reason: reason ?? other.reason)
    }
}
