import AppKit
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

// MARK: - Agents

struct AgentsPane: View {
    @AppStorage(Pref.disabledAgents) private var disabledCSV = Pref.Default.disabledAgents
    @ObservedObject private var monitor = AgentMonitor.shared

    var body: some View {
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
                    if kind != .workbuddy {
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
        let level = kind.hasRichSessionReader ? "local session reader" : "process tracking"
        if isRunning(kind) { return "Running now · \(level)" }
        if let path = kind.installedCLIPath {
            return "Installed · \(level) · \((path as NSString).abbreviatingWithTildeInPath)"
        }
        return "CLI not found · \(level)"
    }
}
