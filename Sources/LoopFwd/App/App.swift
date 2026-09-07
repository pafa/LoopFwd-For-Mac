import SwiftUI
import UserNotifications

@main
enum LoopFwdEntryPoint {
    static func main() {
        if CommandLine.arguments.contains("--verify-packaged-resources") {
            let valid = LoopFwdResources.verifyPackagedResources()
            print(valid ? "Packaged resources verified" : "Packaged resources missing or invalid")
            exit(valid ? 0 : 1)
        }
        LoopFwdApp.main()
    }
}

struct LoopFwdApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @ObservedObject private var monitor = AgentMonitor.shared
    @ObservedObject private var codexServer = CodexAppServer.shared
    @ObservedObject private var outcomePresentation = OutcomePresentation.shared

    private var agents: [AgentSession] {
        outcomePresentation.visible(
            SessionPresentationPolicy.visible(
                SessionList.merged(observed: monitor.agents, managed: codexServer.agents)
            )
        )
    }

    var body: some Scene {
        MenuBarExtra {
            menuContent
        } label: {
            let urgent = agents.filter {
                $0.status == .needsAttention || $0.status == .failed
            }.count
            let active = agents.filter { $0.status.isActive }.count
            let count = urgent > 0 ? urgent : active
            HStack(spacing: 2) {
                LoopFwdMarkView(variant: .template, placement: .menuBar)
                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                }
            }
            .frame(height: 16)
            .fixedSize(horizontal: true, vertical: true)
            .accessibilityLabel(
                urgent > 0
                    ? L10n.format("LoopFwd, %d tasks need attention", urgent)
                    : active > 0 ? L10n.format("LoopFwd, %d active tasks", active) : "LoopFwd"
            )
        }
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button(L10n.string("About LoopFwd")) { SettingsWindowController.shared.show(pane: .about) }
            }
            CommandGroup(after: .appInfo) {
                Button(L10n.string("Open Island")) {
                    NotificationCenter.default.post(name: .islandExpand, object: nil)
                }
                Button(L10n.string("LoopFwd Settings…")) { SettingsWindowController.shared.show() }
            }
        }
    }

    @ViewBuilder
    private var menuContent: some View {
        if agents.isEmpty {
            Text(L10n.string("No active tasks"))
        } else {
            ForEach(agents) { agent in
                Button(
                    "\(statusMark(agent.status))  \(agent.displayTitle) — \(agent.displayStatusLabel) · \(ReturnResolver.resolve(agent).capability.actionLabel)"
                ) {
                    TerminalBridge.jump(to: agent) { result in
                        if !result.opened {
                            OperationalDiagnostics.shared.showReturnFailure(result, session: agent)
                            NotificationCenter.default.post(name: .islandExpand, object: nil)
                        }
                    }
                }
                .disabled(ReturnResolver.resolve(agent).reason != nil)
            }
        }
        Divider()
        Button(L10n.string("Refresh Now")) { AgentMonitor.shared.scanNow() }
        Button(L10n.string("Settings…")) { SettingsWindowController.shared.show() }
            .keyboardShortcut(",")
        Divider()
        Button(L10n.string("Quit LoopFwd")) { NSApp.terminate(nil) }
    }

    private func statusMark(_ status: AgentStatus) -> String {
        switch status {
        case .working: return "🟢"
        case .stalled: return "🟠"
        case .completed: return "🔵"
        case .needsAttention: return "🟡"
        case .failed: return "🔴"
        case .stopped: return "⚪️"
        case .idle: return "⚪️"
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: NotchPanel?
    private let notificationDelegate = AgentNotificationDelegate()

    func applicationDidFinishLaunching(_ notification: Notification) {
        if activateExistingInstance() { return }

        Pref.registerDefaults()
        NSApp.setActivationPolicy(.accessory)
        // Prototype policy: startup never changes login items or asks for permissions.

        AgentMonitor.shared.start()
        UNUserNotificationCenter.current().delegate = notificationDelegate
        AgentNotificationRouter.shared.start()
        SoundEngine.shared.start()
        ApprovalCenter.shared.start()
        UsageTracker.shared.start()
        HotKeyCenter.shared.update()
        panel = NotchPanel(monitor: AgentMonitor.shared)
        SwitcherState.shared.panel = panel
        panel?.orderFrontRegardless()

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.panel?.repositionOnTargetScreen()
            AgentMonitor.shared.scanNow()
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.panel?.repositionOnTargetScreen()
            AgentMonitor.shared.scanNow()
        }

        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("app.loopfwd.activate-existing"),
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.panel?.orderFrontRegardless()
            NotificationCenter.default.post(name: .islandExpand, object: nil)
        }

        // Settings posts this when display selection / notch tuning changes.
        NotificationCenter.default.addObserver(
            forName: .repositionPanel, object: nil, queue: .main
        ) { [weak self] _ in
            self?.panel?.repositionOnTargetScreen()
        }

    }

    func applicationWillTerminate(_ notification: Notification) {
        CodexAppServer.shared.stop()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        panel?.orderFrontRegardless()
        NotificationCenter.default.post(name: .islandExpand, object: nil)
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard CodexAppServer.shared.agents.contains(where: { $0.status.isActive }) else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = L10n.string("Managed tasks are still running")
        alert.informativeText = L10n.string(
            "Quitting LoopFwd disconnects its managed Codex tasks. External agent tasks are not stopped."
        )
        alert.addButton(withTitle: L10n.string("Return to tasks"))
        alert.addButton(withTitle: L10n.string("Quit LoopFwd"))
        if alert.runModal() == .alertSecondButtonReturn { return .terminateNow }
        NotificationCenter.default.post(name: .islandExpand, object: nil)
        return .terminateCancel
    }

    /// A second launch wakes the existing island and exits. Never terminate the
    /// first process: it may own live managed Codex tasks.
    private func activateExistingInstance() -> Bool {
        guard let bundleId = Bundle.main.bundleIdentifier else { return false }
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        guard let existing = others.first else { return false }
        _ = existing.activate(options: [.activateAllWindows])
        DistributedNotificationCenter.default().post(
            name: Notification.Name("app.loopfwd.activate-existing"), object: nil
        )
        DispatchQueue.main.async { NSApp.terminate(nil) }
        return true
    }

}
