import Foundation
import SwiftUI

/// Visual urgency while an approval / question sits unanswered.
/// Inspired by MioIsland unattended alerts (≈30s orange, ≈60s red) —
/// glance escalation only; never auto-approves or auto-denies.
enum AttentionUrgency: Equatable, Sendable {
    case normal
    case elevated
    case critical

    static let elevatedAfter: TimeInterval = 30
    static let criticalAfter: TimeInterval = 60

    static func level(waitingSince: Date, now: Date = Date()) -> AttentionUrgency {
        let waited = now.timeIntervalSince(waitingSince)
        if waited >= criticalAfter { return .critical }
        if waited >= elevatedAfter { return .elevated }
        return .normal
    }

    /// Prefer live ApprovalCenter timestamps; fall back to observation time.
    static func waitingSince(for agent: AgentSession) -> Date? {
        guard agent.status == .needsAttention else { return nil }
        if let approval = ApprovalCenter.shared.approval(for: agent) {
            return approval.at
        }
        if let question = ApprovalCenter.shared.question(for: agent) {
            return question.at
        }
        return agent.observation.updatedAt
    }

    static func level(for agent: AgentSession, now: Date = Date()) -> AttentionUrgency {
        guard let since = waitingSince(for: agent) else { return .normal }
        return level(waitingSince: since, now: now)
    }

    var color: Color {
        switch self {
        case .normal:
            return AgentStatus.needsAttention.color
        case .elevated:
            // MioIsland-style orange after ~30s.
            return Color(red: 1.00, green: 0.55, blue: 0.18)
        case .critical:
            // MioIsland-style red after ~60s.
            return Color(red: 1.00, green: 0.36, blue: 0.36)
        }
    }

    /// Compact wait label for Island glance (nil while still "fresh").
    func waitLabel(waitingSince: Date, now: Date = Date()) -> String? {
        let seconds = max(0, Int(now.timeIntervalSince(waitingSince)))
        switch self {
        case .normal:
            return nil
        case .elevated, .critical:
            if seconds < 60 { return L10n.format("waiting %ds", seconds) }
            return L10n.format("waiting %dm", max(1, seconds / 60))
        }
    }
}
