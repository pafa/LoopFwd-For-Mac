import AppKit
import SwiftUI
import UserNotifications

/// A compact first-run inventory. It reports what this Mac can prove now;
/// missing software remains discoverable later and never becomes a startup
/// permission prompt or automatic install.
struct SetupStatusPane: View {
    @ObservedObject private var monitor = AgentMonitor.shared
    @ObservedObject private var scanUpdates = AgentMonitor.shared.diagnosticsUpdates
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
                        detail: kind == .cursorAgent
                            ? "Reads visible Cursor Agents panes locally. Account login is sufficient. Hidden tasks, approvals and completion are not inferred."
                            : kind.supportTier == .previewTested
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
                    Button(L10n.string("Review access")) { SettingsWindowController.shared.show(pane: .notifications) }
                }
                SDiv()
                statusRow(
                    title: "Terminal.app",
                    value: "Return only · keyboard injection disabled",
                    ready: false
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
        let selected = kind == .codex ? UserDefaults.standard.string(forKey: Pref.codexDesktopDataDirectory) : nil
        let missingFolder = selected.map { !$0.isEmpty && !FileManager.default.fileExists(atPath: $0) } ?? false
        let readiness = ProviderReadiness.resolve(
            enabled: enabled, installed: softwareAvailable,
            observations: active.map { $0.observation.mode }, diagnostic: monitor.providerDiagnostics[kind],
            scanFailed: monitor.lastScanError != nil, missingConfiguration: missingFolder,
            usesObserver: [.claude, .gemini, .qwen, .kimi].contains(kind),
            claudeHookInstalled: kind == .claude ? ApprovalCenter.hookInstalled : nil,
            claudeHookNeedsUpdate: kind == .claude ? ApprovalCenter.hookNeedsUpdate : nil)
        let ready = readiness.ready

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
                Text(L10n.string(readiness.status))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(ready ? Color.secondary : Color.primary.opacity(0.75))
                Text(L10n.string(readiness.detail ?? detail))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 6) {
                statusBadge(readiness.status, ready: ready)
                Button(readiness.action.title) { SettingsWindowController.shared.show(pane: readiness.action) }
                    .font(.system(size: 10.5))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .accessibilityElement(children: .contain)
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

/// Pure presentation policy: installation is never treated as successful
/// observation, and an old successful read cannot cover a current failure.
struct ProviderReadiness {
    let status: String
    let detail: String?
    let action: SettingsPane
    var ready = false

    static func resolve(
        enabled: Bool, installed: Bool, observations: [ObservationMode],
        diagnostic: ProviderScanDiagnostic?, scanFailed: Bool = false,
        missingConfiguration: Bool = false, usesObserver: Bool = false,
        claudeHookInstalled: Bool? = nil, claudeHookNeedsUpdate: Bool? = nil
    ) -> Self {
        if !enabled {
            return .init(
                status: "Disabled in Agents", detail: "Enable this integration in Agents when you want to use it.",
                action: .agents)
        }
        if missingConfiguration {
            return .init(
                status: "Data folder unavailable",
                detail: "The selected data folder is missing. Choose its current location in Agents.", action: .agents)
        }
        if scanFailed || observations.contains(.stale) || observations.contains(.incompatible)
            || ["failed", "incompatible", "partial"].contains(diagnostic?.outcome ?? "")
        {
            return .init(
                status: "Data temporarily unavailable",
                detail: "Review Diagnostics for the failed source, then refresh after correcting it.",
                action: .diagnostics)
        }
        if claudeHookNeedsUpdate == true {
            return .init(
                status: "Claude hook update available",
                detail: "Update the Claude observer in Integrations so permission prompts stay aligned.",
                action: .integrations)
        }
        if observations.contains(.rich) {
            if claudeHookInstalled == false {
                return .init(
                    status: "Rich data · hook not installed",
                    detail: "Install the Claude observer in Integrations for live Approve / Deny on Island and phone.",
                    action: .integrations, ready: true)
            }
            return .init(
                status: claudeHookInstalled == true ? "Rich data · Claude hook ready" : "Rich data active",
                detail: nil, action: .diagnostics, ready: true)
        }
        if !observations.isEmpty {
            if usesObserver, claudeHookInstalled == false {
                return .init(
                    status: "Limited data · hook not installed",
                    detail: "Install the Claude observer in Integrations for live permission prompts.",
                    action: .integrations)
            }
            return .init(
                status: "Limited data",
                detail: usesObserver
                    ? "Only process data is available. Review the observer and its configuration in Integrations."
                    : "Only process data is available. Review the data source in Diagnostics.",
                action: usesObserver ? .integrations : .diagnostics)
        }
        if diagnostic?.outcome == "empty" {
            return .init(
                status: "No active tasks",
                detail: "The source was read successfully. Start a task in the provider to see it here.",
                action: .agents)
        }
        if !installed {
            return .init(
                status: "CLI or app not found",
                detail: "Install the official provider, or choose an existing CLI in Agents.", action: .agents)
        }
        if claudeHookInstalled == false {
            return .init(
                status: "Installed · Claude hook missing",
                detail: "Install the observer in Integrations before expecting live permission controls.",
                action: .integrations)
        }
        return .init(
            status: "Installed · not verified",
            detail:
                "Start a task in the provider, then refresh status. Installation alone does not verify observation.",
            action: .agents)
    }
}
