import AppKit
import ApplicationServices
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

// MARK: - Agents

struct AgentsPane: View {
    @AppStorage(Pref.disabledAgents) private var disabledCSV = Pref.Default.disabledAgents
    @ObservedObject private var monitor = AgentMonitor.shared
    @AppStorage(Pref.codexDesktopDataDirectory) private var codexDataDirectory = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            trackedAgents
            SSection(
                title: "Cursor Desktop",
                footer:
                    "Reads visible Cursor Agents panes locally. Account login is sufficient. Hidden tasks, approvals and completion are not inferred."
            ) {
                SRow(
                    title: "Accessibility", subtitle: "Allow LoopFwd in macOS Accessibility, then enable Cursor above."
                ) {
                    Button(L10n.string("Review Cursor access")) {
                        // Explicit user action registers this exact build with macOS.
                        // Startup and background scans never request access.
                        let options =
                            [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                        _ = AXIsProcessTrustedWithOptions(options)
                        if let url = URL(
                            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
                        {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
            }
            SSection(
                title: "Codex Desktop data",
                footer:
                    "Automatic uses the running Codex app's environment. Choose its actual CODEX_HOME folder if detection is unavailable or ambiguous. This does not move or modify Codex data."
            ) {
                SRow(
                    title: "Data directory",
                    subtitle: codexDataDirectory.isEmpty ? "Automatic · observed app environment" : codexDataDirectory
                ) {
                    Button(L10n.string("Choose folder…")) {
                        let panel = NSOpenPanel()
                        panel.canChooseFiles = false
                        panel.canChooseDirectories = true
                        panel.allowsMultipleSelection = false
                        guard panel.runModal() == .OK, let url = panel.url else { return }
                        codexDataDirectory = url.path
                        UsageTracker.shared.invalidateCodexSource()
                        monitor.scanNow()
                    }
                    if !codexDataDirectory.isEmpty {
                        Button(L10n.string("Use automatic")) {
                            codexDataDirectory = ""
                            UsageTracker.shared.invalidateCodexSource()
                            monitor.scanNow()
                        }
                    }
                }
            }
        }
    }

    private var trackedAgents: some View {
        SSection(
            title: "Tracked agents",
            footer:
                "Preview tested means basic real-task monitoring was checked on a specific surface, not every feature or environment. Other integrations are optional experiments; enable only what you use."
        ) {
            ForEach(Array(SupportRegistry.shippedKinds.enumerated()), id: \.element.rawValue) { index, kind in
                if index > 0 { SDiv() }
                HStack(spacing: 10) {
                    // Real brand logo when bundled; tinted SF-symbol fallback otherwise.
                    AgentIconView(kind: kind, status: .working, size: 22, showStatus: false)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(kind.displayName)
                                .font(.system(size: 13))
                            Text(kind.supportTier.label.uppercased())
                                .font(.system(size: 8, weight: .bold, design: .rounded))
                                .foregroundStyle(
                                    kind.supportTier == .previewTested
                                        ? AgentStatus.working.color : .secondary)
                        }
                        Text(availability(for: kind))
                            .font(.system(size: 10.5))
                            .foregroundStyle(isRunning(kind) ? AgentStatus.working.color : .secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    if kind != .workbuddy && kind != .cursorAgent {
                        Button(L10n.string("Choose CLI…")) {
                            let panel = NSOpenPanel()
                            panel.canChooseDirectories = false
                            panel.allowsMultipleSelection = false
                            guard panel.runModal() == .OK, let url = panel.url,
                                FileManager.default.isExecutableFile(atPath: url.path)
                            else { return }
                            UserDefaults.standard.set(url.path, forKey: "cliExecutable.\(kind.rawValue)")
                            AgentMonitor.shared.scanNow()
                        }
                    }
                    Toggle(L10n.string(""), isOn: binding(for: kind)).toggleStyle(.switch).labelsHidden()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
            }
        }
    }

    private func binding(for kind: AgentKind) -> Binding<Bool> {
        Binding(
            get: { !disabledSet.contains(kind.rawValue) },
            set: { enabled in
                var set = disabledSet
                if enabled { set.remove(kind.rawValue) } else { set.insert(kind.rawValue) }
                disabledCSV = set.sorted().joined(separator: ",")
                if kind == .codex { UsageTracker.shared.invalidateCodexSource() }
                AgentMonitor.shared.scanNow()
            }
        )
    }

    private var disabledSet: Set<String> {
        Set(disabledCSV.split(separator: ",").map(String.init))
    }

    private func isRunning(_ kind: AgentKind) -> Bool {
        monitor.agents.contains { $0.kind == kind }
    }

    private func availability(for kind: AgentKind) -> String {
        if kind == .cursorAgent {
            return L10n.string(
                CursorDesktopSessions.authorized ? "Visible Agents panes · read only" : "Accessibility access required")
        }
        let level = kind.hasRichSessionReader ? "local session reader" : "process tracking"
        if isRunning(kind) { return L10n.format("Running now · %@", L10n.string(level)) }
        if let path = kind.installedCLIPath {
            return L10n.format(
                "Installed · %@ · %@", L10n.string(level), (path as NSString).abbreviatingWithTildeInPath)
        }
        return L10n.format("CLI not found · %@", L10n.string(level))
    }
}
