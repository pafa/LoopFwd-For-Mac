import AppKit
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

// MARK: - Integrations

struct IntegrationsPane: View {
    @State private var installed = ApprovalCenter.hookInstalled
    @State private var hookMessage: String?
    @State private var accessibilityGranted = TerminalBridge.hasAccessibilityAccess
    @AppStorage(Pref.claudeControlsEnabled) private var claudeControlsEnabled = Pref.Default.claudeControlsEnabled
    @ObservedObject private var kimiHooks = KimiHookIntegration.shared
    @ObservedObject private var geminiHooks = JSONHookIntegration.gemini
    @ObservedObject private var qwenHooks = JSONHookIntegration.qwen
    @AppStorage(Pref.providerControlsEnabled) private var providerControlsEnabled = Pref.Default.providerControlsEnabled
    @AppStorage(Pref.communityUsageEnabled) private var communityUsageEnabled = Pref.Default.communityUsageEnabled

    private func jsonObserver(_ integration: JSONHookIntegration, title: String) -> some View {
        SSection(
            title: title,
            footer:
                "Choose the provider settings folder explicitly. Existing hooks and comments are preserved, settings are backed up, and disabled hooks stay disabled. Observation only; no approvals or successful completion guarantees."
        ) {
            SRow(
                title: "Read-only stream observer",
                subtitle: integration.message + " · " + integration.version
            ) {
                HStack {
                    Button(L10n.string(integration.installed ? "Reinstall" : "Install")) { integration.install() }
                    if integration.canRemove { Button(L10n.string("Remove")) { integration.remove() } }
                }.disabled(integration.busy)
            }
            if let backup = integration.backup {
                SDiv()
                SRow(
                    title: "Configuration backup",
                    subtitle: "Review settings and backups before retrying an interrupted operation"
                ) {
                    Button(L10n.string("Show backup")) { NSWorkspace.shared.activateFileViewerSelecting([backup]) }
                }
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SSection(
                title: "Labs",
                footer: "Disabling controls does not stop existing managed tasks. Return and stop remain available."
            ) {
                SRow(
                    title: "New tasks and provider controls",
                    subtitle: "Experimental managed Codex creation and OpenCode replies/approvals"
                ) {
                    Toggle(L10n.string(""), isOn: $providerControlsEnabled).toggleStyle(.switch).labelsHidden()
                }
                SDiv()
                SRow(
                    title: "Claude community usage estimates",
                    subtitle: "Approximate transcript-based budgets, not official account limits"
                ) {
                    Toggle(L10n.string(""), isOn: $communityUsageEnabled).toggleStyle(.switch).labelsHidden()
                }
            }
            SSection(
                title: "Claude Code",
                footer: installed
                    ? "The observer reports explicit permission and question events. Terminal input remains a Labs feature and is off by default."
                    : "Installs a Notification hook into ~/.claude/settings.json after writing a backup. It observes explicit attention events and never answers them unless Labs control is separately enabled."
            ) {
                SRow(
                    title: "Attention observer",
                    subtitle: hookMessage
                        ?? (ApprovalCenter.hookNeedsUpdate
                            ? "Hook update required" : installed ? "Hook installed" : "Hook not installed")
                ) {
                    Button(
                        L10n.string(ApprovalCenter.hookNeedsUpdate ? "Update hook" : installed ? "Remove" : "Install")
                    ) {
                        let result =
                            installed && !ApprovalCenter.hookNeedsUpdate
                            ? ApprovalCenter.uninstallHook()
                            : ApprovalCenter.installHook()
                        switch result {
                        case .success:
                            hookMessage = nil
                        case .failure(let error):
                            hookMessage = error.localizedDescription
                        }
                        installed = ApprovalCenter.hookInstalled
                    }
                }
                SDiv()
                SRow(
                    title: "Labs: terminal input controls",
                    subtitle: "Experimental digit/text injection into one exact terminal session"
                ) {
                    Toggle(L10n.string(""), isOn: $claudeControlsEnabled)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .onChange(of: claudeControlsEnabled) { _, _ in
                            HotKeyCenter.shared.update()
                        }
                }
            }

            jsonObserver(geminiHooks, title: "Gemini CLI observer")
            jsonObserver(qwenHooks, title: "Qwen Code observer")

            SSection(
                title: "Kimi Code observer",
                footer:
                    "Requires Kimi Code 0.41.0, Node.js 24+ and Python 3.11+. Lifecycle hooks identify sessions; task state comes from the matching main wire. No approval or exact session return is promised. Configuration is backed up before changes."
            ) {
                SRow(title: "Read-only session observer", subtitle: kimiHooks.message) {
                    Button(L10n.string(kimiHooks.canRemove ? "Reinstall" : "Install")) { kimiHooks.install() }.disabled(
                        kimiHooks.busy)
                    if kimiHooks.canRemove {
                        Button(L10n.string("Remove")) { kimiHooks.remove() }.disabled(kimiHooks.busy)
                    }
                }
                if let backup = kimiHooks.backup {
                    SRow(title: "Configuration backup", subtitle: "Original settings are retained for manual recovery")
                    {
                        Button(L10n.string("Show backup")) { NSWorkspace.shared.activateFileViewerSelecting([backup]) }
                    }
                }
            }

            SSection(
                title: "Terminal control",
                footer:
                    "LoopFwd only sends text when it can address the exact session. Other terminal and editor hosts remain Jump-only until they expose a proven control API."
            ) {
                SRow(
                    title: "iTerm / tmux / WezTerm / kitty",
                    subtitle: "Exact session control when the host API is available"
                ) { EmptyView() }
                SDiv()
                SRow(
                    title: "Terminal.app",
                    subtitle: accessibilityGranted
                        ? "Ready — exact tab selection plus keyboard input"
                        : "Accessibility permission required for replies"
                ) {
                    Button(L10n.string(accessibilityGranted ? "Ready" : "Enable…")) {
                        accessibilityGranted = TerminalBridge.requestAccessibilityAccess()
                    }
                    .disabled(accessibilityGranted)
                }
                SDiv()
                SRow(
                    title: "Ghostty / Warp / editors",
                    subtitle: "Return to session only; replies are disabled"
                ) { EmptyView() }
            }
        }
        .onAppear { accessibilityGranted = TerminalBridge.hasAccessibilityAccess }
        .onAppear {
            kimiHooks.refresh(); geminiHooks.refresh(); qwenHooks.refresh()
        }
        .onReceive(
            NSWorkspace.shared.notificationCenter.publisher(
                for: NSWorkspace.didActivateApplicationNotification
            )
        ) { _ in
            accessibilityGranted = TerminalBridge.hasAccessibilityAccess
        }
    }
}
