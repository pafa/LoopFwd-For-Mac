import SwiftUI
import AppKit
import UniformTypeIdentifiers
import UserNotifications

// MARK: - Panes

enum SettingsPane: String, CaseIterable, Identifiable {
    case setup, general, integrations, notifications, display, sound, usage, agents, shortcuts, diagnostics, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .setup: return L10n.string("Setup status")
        case .general: return L10n.string("General")
        case .integrations: return L10n.string("Integrations")
        case .notifications: return L10n.string("Notifications")
        case .display: return L10n.string("Display")
        case .sound: return L10n.string("Sound")
        case .usage: return L10n.string("Usage")
        case .agents: return L10n.string("Agents")
        case .shortcuts: return L10n.string("Shortcuts")
        case .diagnostics: return L10n.string("Diagnostics")
        case .about: return L10n.string("About")
        }
    }

    var icon: String {
        switch self {
        case .setup: return "checklist"
        case .general: return "gearshape.fill"
        case .integrations: return "puzzlepiece.extension.fill"
        case .notifications: return "bell.badge.fill"
        case .display: return "textformat.size"
        case .sound: return "speaker.wave.2.fill"
        case .usage: return "gauge.with.needle.fill"
        case .agents: return "sparkles"
        case .shortcuts: return "keyboard.fill"
        case .diagnostics: return "stethoscope"
        case .about: return "info.circle.fill"
        }
    }

    var tileColor: Color {
        switch self {
        case .setup: return Color(red: 0.16, green: 0.72, blue: 0.50)
        case .general: return Color(white: 0.45)
        case .integrations: return Color(red: 0.30, green: 0.65, blue: 0.90)
        case .notifications: return Color(red: 0.94, green: 0.35, blue: 0.32)
        case .display: return Color(red: 0.45, green: 0.45, blue: 0.95)
        case .sound: return Color(red: 0.25, green: 0.75, blue: 0.40)
        case .usage: return Color(red: 0.90, green: 0.30, blue: 0.45)
        case .agents: return Color(red: 0.95, green: 0.60, blue: 0.20)
        case .shortcuts: return Color(red: 0.70, green: 0.40, blue: 0.90)
        case .diagnostics: return Color(red: 0.20, green: 0.70, blue: 0.72)
        case .about: return Color(red: 0.30, green: 0.60, blue: 0.95)
        }
    }

    /// Panes shown below the "Advanced" separator in the sidebar.
    static let main: [SettingsPane] = [
        .setup, .general, .integrations, .notifications, .display, .sound, .usage, .agents,
    ]
    static let advanced: [SettingsPane] = [.shortcuts, .diagnostics, .about]
}

struct SettingsView: View {
    @State private var pane: SettingsPane

    init(initialPane: SettingsPane = .general) {
        _pane = State(initialValue: initialPane)
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            detail
        }
        .frame(width: 780, height: 640)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(SettingsPane.main) { item in
                SidebarRow(pane: item, selected: pane == item) { pane = item }
            }
            Text(L10n.string("Advanced"))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.top, 14)
                .padding(.leading, 10)
                .padding(.bottom, 2)
            ForEach(SettingsPane.advanced) { item in
                SidebarRow(pane: item, selected: pane == item) { pane = item }
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
        .padding(.top, 40)  // clear the traffic lights (transparent titlebar)
        .frame(width: 200)
        .background(.black.opacity(0.15))
    }

    private var detail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(pane.tileColor.gradient)
                        .frame(width: 28, height: 28)
                        .overlay(
                            Image(systemName: pane.icon)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.white)
                        )
                    Text(pane.title)
                        .font(.system(size: 22, weight: .bold))
                }
                .padding(.bottom, 2)

                switch pane {
                case .setup: SetupStatusPane()
                case .general: GeneralPane()
                case .integrations: IntegrationsPane()
                case .notifications: NotificationsPane()
                case .display: DisplayPane()
                case .sound: SoundPane()
                case .usage: UsagePane()
                case .agents: AgentsPane()
                case .shortcuts: ShortcutsPane()
                case .diagnostics: DiagnosticsPane()
                case .about: AboutPane()
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
            .padding(.top, 30)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct SidebarRow: View {
    let pane: SettingsPane
    let selected: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(pane.tileColor.gradient)
                    .frame(width: 24, height: 24)
                    .overlay(
                        Image(systemName: pane.icon)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white)
                    )
                Text(pane.title)
                    .font(.system(size: 13, weight: selected ? .semibold : .regular))
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selected ? Color.white.opacity(0.12) : hovered ? Color.white.opacity(0.05) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

// MARK: - Building blocks

/// A grouped card of rows, like System Settings sections.
struct SSection<Content: View>: View {
    var title: String? = nil
    var footer: String? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let title {
                Text(L10n.string(title))
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.leading, 4)
            }
            VStack(spacing: 0) { content() }
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.white.opacity(0.055))
                )
            if let footer {
                Text(L10n.string(footer))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// One settings row: title (+ optional subtitle) with a trailing control.
struct SRow<Trailing: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.string(title))
                    .font(.system(size: 13))
                if let subtitle {
                    Text(L10n.string(subtitle))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            trailing()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

/// Divider between rows inside an SSection card.
struct SDiv: View {
    var body: some View {
        Divider().padding(.leading, 14)
    }
}

/// Small keycap badge, e.g. ⌃G or esc.
struct KeyCap: View {
    let label: String

    var body: some View {
        Text(label)
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.white.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.15), lineWidth: 1)
            )
    }
}
