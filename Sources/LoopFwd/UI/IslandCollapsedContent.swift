import AppKit
import SwiftUI

// MARK: - Collapsed pill

struct CollapsedContent: View {
    let agents: [AgentSession]
    let notch: NotchMetrics
    let detailed: Bool

    private var overall: AgentStatus {
        if agents.contains(where: { $0.status == .needsAttention }) { return .needsAttention }
        if agents.contains(where: { $0.status == .failed }) { return .failed }
        if agents.contains(where: { $0.status == .stalled }) { return .stalled }
        if agents.contains(where: { $0.status == .completed }) { return .completed }
        if agents.contains(where: { $0.status == .working }) { return .working }
        return .idle
    }

    /// One-liner for the detailed pill: human attention beats background work.
    private var headline: String {
        let attention = agents.filter { $0.status == .needsAttention }.count
        if attention > 0 { return L10n.format("%d need attention", attention) }
        let failed = agents.filter { $0.status == .failed }.count
        if failed > 0 { return L10n.format("%d failed", failed) }
        let stalled = agents.filter { $0.status == .stalled }.count
        if stalled > 0 { return L10n.format("%d may be stalled", stalled) }
        let completed = agents.filter { $0.status == .completed }.count
        if completed > 0 { return L10n.format("%d completed", completed) }
        if let working = agents.first(where: { $0.status == .working }) {
            return working.activity ?? working.displayTitle
        }
        if let first = agents.first { return first.displayTitle }
        return L10n.string("No active tasks")
    }

    var body: some View {
        HStack(spacing: 0) {
            // Left wing: mascot (+ count or live headline), tucked to the edge.
            HStack(spacing: 6) {
                LoopFwdMarkView(variant: .color, placement: .collapsedIsland)
                if detailed {
                    Text(headline)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                        .truncationMode(.tail)
                } else {
                    Text("\(agents.count)")
                        .font(.system(size: 11.5, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.92))
                        .contentTransition(.numericText())
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 20)

            // Leave the physical notch area empty.
            Color.clear
                .frame(width: notch.hasNotch ? notch.width : 8)

            // Right wing: session count (detailed) or one status dot per agent.
            HStack(spacing: 4.5) {
                if detailed {
                    Text("\(agents.count)")
                        .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.92))
                        .contentTransition(.numericText())
                    Text(L10n.string(agents.count == 1 ? "session" : "sessions"))
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.5))
                } else if agents.isEmpty {
                    Circle().fill(.white.opacity(0.25)).frame(width: 5.5, height: 5.5)
                } else {
                    ForEach(agents.prefix(4)) { agent in
                        StatusDot(color: agent.status.color, active: agent.status == .working)
                    }
                    if agents.count > 4 {
                        Text("+\(agents.count - 4)")
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.trailing, 20)
        }
    }
}
