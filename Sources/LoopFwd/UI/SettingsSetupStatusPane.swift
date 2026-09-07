import AppKit
import SwiftUI
import UserNotifications

/// A compact first-run inventory. It reports what this Mac can prove now;
/// missing software remains discoverable later and never becomes a startup
/// permission prompt or automatic install.
struct SetupStatusPane: View {
    @ObservedObject private var monitor = AgentMonitor.shared
    @State private var notificationsGranted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SSection(
                title: "Provider readiness",
                footer:
                    "LoopFwd changes no provider configuration on startup. Installers, hooks, notification access and login items run only after you choose them."
            ) {
                ForEach(Array(SupportRegistry.shippedKinds.enumerated()), id: \.element.rawValue) { index, kind in
                    if index > 0 { SDiv() }
                    providerRow(
                        kind: kind,
                        surfaces: SupportRegistry.testedSurfaces.filter { $0.providerKind == kind }
                            .map(\.rawValue).sorted().joined(separator: " · "),
                        softwareAvailable: kind.softwareAvailable,
                        detail: kind.supportTier == .previewTested
                            ? "Basic monitoring tested on the listed surface; return and controls vary by session."
                            : "Optional CLI integration. Enable in Agents; observer setup may be required. Real model tasks are not yet verified."
                    )
                }
            }

            SSection(
                title: "System access",
                footer:
                    "A missing permission disables only the capability that needs it. Passive observation remains read-only."
            ) {
                SRow(
                    title: "Notifications",
                    subtitle: "Open Notifications to review macOS authorization"
                ) {
                    statusBadge(notificationsGranted ? "Authorized" : "Not authorized", ready: notificationsGranted)
                }
                SDiv()
                statusRow(
                    title: "Terminal input (Labs)",
                    value: TerminalBridge.hasAccessibilityAccess
                        ? "Accessibility permission is available"
                        : "Not granted · required only for optional Terminal.app input",
                    ready: TerminalBridge.hasAccessibilityAccess
                )
            }

            HStack {
                Button(L10n.string("Refresh status")) {
                    monitor.scanNow()
                    Task { await refreshPermissions() }
                }
                Spacer()
                Text(L10n.string("Installed does not mean configured or tested on this Mac."))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
        }
        .task { await refreshPermissions() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await refreshPermissions() }
        }
    }

    private func refreshPermissions() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        notificationsGranted =
            settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
    }

    private func providerRow(
        kind: AgentKind,
        surfaces: String,
        softwareAvailable: Bool,
        detail: String
    ) -> some View {
        let active = monitor.agents.filter { $0.kind == kind }
        let enabled = !Pref.disabledKinds.contains(kind)
        let rich = enabled && active.contains { $0.observation.mode == .rich }
        let status =
            !enabled
            ? "Disabled in Agents"
            : rich
                ? "Rich data active"
                : active.isEmpty ? (softwareAvailable ? "Installed · not verified" : "Not installed") : "Limited data"
        let ready = rich

        return HStack(spacing: 11) {
            AgentIconView(kind: kind, status: ready ? .working : .idle, size: 24, showStatus: false)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(kind.displayName)
                        .font(.system(size: 13, weight: .semibold))
                    Text(surfaces.isEmpty ? kind.supportTier.label : surfaces)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Text(L10n.string(detail))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            statusBadge(status, ready: ready)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }

    private func statusRow(title: String, value: String, ready: Bool) -> some View {
        SRow(title: title, subtitle: value) {
            statusBadge(ready ? "Available" : "Optional", ready: ready)
        }
    }

    private func statusBadge(_ text: String, ready: Bool) -> some View {
        Text(L10n.string(text))
            .font(.system(size: 9.5, weight: .semibold, design: .rounded))
            .foregroundStyle(ready ? AgentStatus.working.color : .secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(
                Capsule().fill((ready ? AgentStatus.working.color : Color.secondary).opacity(0.12))
            )
    }

}
