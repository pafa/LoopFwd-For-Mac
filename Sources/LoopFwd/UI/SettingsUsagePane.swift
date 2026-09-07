import AppKit
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

// MARK: - Usage

struct UsagePane: View {
    @AppStorage(Pref.usageEnabled) private var enabled = Pref.Default.usageEnabled
    @AppStorage(Pref.usagePlan) private var plan = Pref.Default.usagePlan
    @AppStorage(Pref.communityUsageEnabled) private var communityUsageEnabled = Pref.Default.communityUsageEnabled
    @ObservedObject private var tracker = UsageTracker.shared

    var body: some View {
        let budgets = UsageTracker.budgets(plan: plan)
        let snapshot = tracker.snapshot
        VStack(alignment: .leading, spacing: 22) {
            SSection(
                footer:
                    "Codex displays its last reported limits, not a live balance. Claude community estimates are optional in Labs."
            ) {
                SRow(title: "Show usage in the panel header") {
                    Toggle(L10n.string(""), isOn: $enabled).toggleStyle(.switch).labelsHidden()
                }
                if communityUsageEnabled {
                    SDiv()
                    SRow(title: "Claude plan") {
                        Picker("", selection: $plan) {
                            Text(L10n.string("Pro")).tag("pro")
                            Text(L10n.string("Max 5x")).tag("max5x")
                            Text(L10n.string("Max 20x")).tag("max20x")
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                }
            }

            if enabled {
                if communityUsageEnabled {
                    SSection(
                        title: "Claude · \(Self.planName(plan))",
                        footer:
                            "Estimated locally from transcript token counts (cache reads weighted at 10%). Anthropic doesn't publish exact budgets — treat the percentages as a guide."
                    ) {
                        if snapshot.hasIncompleteData {
                            SRow(
                                title: "Usage data incomplete",
                                subtitle:
                                    "History is still loading, unreadable, or contains oversized records. Estimates are hidden."
                            ) { EmptyView() }
                        } else {
                            if let reset = snapshot.blockResetAt,
                                let percent = snapshot.blockPercent(budget: budgets.block)
                            {
                                SRow(
                                    title: "Current 5-hour window",
                                    subtitle: L10n.format(
                                        "%@ weighted · resets %@", Self.tokens(snapshot.blockTokens),
                                        Self.relative(reset))
                                ) {
                                    UsageBar(percent: percent)
                                }
                            } else {
                                SRow(
                                    title: "Current 5-hour window",
                                    subtitle: "No active window — opens with your next Claude message."
                                ) { EmptyView() }
                            }
                            SDiv()
                            SRow(
                                title: "Rolling 7-day window",
                                subtitle: L10n.format("%@ weighted tokens", Self.tokens(snapshot.weekTokens))
                            ) {
                                if let percent = snapshot.weekPercent(budget: budgets.week) {
                                    UsageBar(percent: percent)
                                }
                            }
                        }
                    }
                }

                if tracker.codex.hasData {
                    SSection(
                        title: "Codex" + (tracker.codex.planType.map { " · \($0.capitalized)" } ?? ""),
                        footer: L10n.format(
                            "Source: local Codex rate-limit event. %@. Historical values may be out of date.",
                            tracker.codex.reportedAt.map { L10n.format("Last reported %@", Self.relative($0)) }
                                ?? L10n.string("Report time unavailable"))
                    ) {
                        if let primary = tracker.codex.primary { codexRow(primary) }
                        if let secondary = tracker.codex.secondary {
                            SDiv(); codexRow(secondary)
                        }
                    }
                } else {
                    SSection(title: "Codex") {
                        SRow(
                            title: "No current usage report",
                            subtitle:
                                "Expired windows are hidden. Usage follows the observed Codex data folder; select one in Agents if multiple accounts are running."
                        ) {
                            Button(L10n.string("Agents")) { SettingsWindowController.shared.show(pane: .agents) }
                        }
                    }
                }
            }
        }
        .onChange(of: enabled) { _, _ in tracker.refreshCodex() }
    }

    private static func planName(_ plan: String) -> String {
        switch plan {
        case "pro": return "Pro"
        case "max20x": return "Max 20x"
        default: return "Max 5x"
        }
    }

    private func codexRow(_ window: UsageTracker.CodexWindow) -> some View {
        SRow(
            title: Self.windowTitle(window),
            subtitle: window.resetsAt.map { L10n.format("Resets %@", Self.relative($0)) }
        ) {
            if let percent = UsageTracker.displayPercent(window.usedPercent) {
                UsageBar(percent: percent)
            }
        }
    }

    private static func windowTitle(_ window: UsageTracker.CodexWindow) -> String {
        let m = window.windowMinutes
        if m % 1440 == 0 { return L10n.format("Rolling %lld-day window", Int64(m / 1440)) }
        if m % 60 == 0 { return L10n.format("Current %lld-hour window", Int64(m / 60)) }
        return L10n.format("%lld-minute window", Int64(m))
    }

    private static func relative(_ date: Date) -> String {
        L10n.relativeTime(date)
    }

    private static func tokens(_ value: Double) -> String {
        value >= 1_000_000_000
            ? String(format: "%.1fB", value / 1_000_000_000)
            : value >= 1_000_000
                ? String(format: "%.1fM", value / 1_000_000)
                : String(format: "%.0fK", value / 1_000)
    }
}

private struct UsageBar: View {
    let percent: Int

    var body: some View {
        HStack(spacing: 8) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.1))
                    Capsule()
                        .fill(
                            percent >= 90
                                ? Color(red: 1.0, green: 0.45, blue: 0.45)
                                : percent >= 70
                                    ? AgentStatus.needsAttention.color
                                    : AgentStatus.working.color
                        )
                        .frame(width: geo.size.width * min(1, CGFloat(percent) / 100))
                }
            }
            .frame(width: 120, height: 6)
            Text(L10n.format("%d%% used", min(percent, 999)))
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
                .fixedSize()
        }
    }
}
