import AppKit
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

// MARK: - Shortcuts

struct ShortcutsPane: View {
    @ObservedObject private var hotKeys = HotKeyCenter.shared
    @AppStorage(Pref.shortcutsEnabled) private var enabled = Pref.Default.shortcutsEnabled
    @AppStorage(Pref.shortcutModifier) private var modifier = Pref.Default.shortcutModifier
    @AppStorage(Pref.reverseSwitcher) private var reverse = Pref.Default.reverseSwitcher

    private var mod: String { HotKeyCenter.modifierSymbol(modifier) }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            if !hotKeys.registrationIssues.isEmpty {
                SSection(
                    title: "Shortcut registration failed",
                    footer:
                        "Check the error below. Another app may use this shortcut; you can choose a different modifier."
                ) {
                    SRow(title: "Registration details", subtitle: hotKeys.registrationIssues.joined(separator: "\n")) {
                        EmptyView()
                    }
                }
            }
            SSection(title: "Modifier Key") {
                SRow(title: "Modifier Key") {
                    Picker("", selection: $modifier) {
                        Text(L10n.string("⌃ Control")).tag("control")
                        Text(L10n.string("⌥ Option")).tag("option")
                        Text(L10n.string("⌘ Command")).tag("command")
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }

            SSection(title: "Global Shortcuts") {
                SRow(
                    title: "Enable Keyboard Shortcuts",
                    subtitle: "Turn off every LoopFwd shortcut without clearing your mappings."
                ) {
                    Toggle(L10n.string(""), isOn: $enabled).toggleStyle(.switch).labelsHidden()
                }
                SDiv()
                SRow(
                    title: "Open Switcher",
                    subtitle: "Tap to open, press again to cycle through sessions, ⏎ to jump (⌘Tab style)."
                ) {
                    KeyCap(label: "\(mod)G")
                }
                SDiv()
                SRow(
                    title: "Reverse Switcher",
                    subtitle: "Adds Shift for backwards cycling. Only registered while enabled."
                ) {
                    HStack(spacing: 10) {
                        KeyCap(label: "\(mod)⇧G")
                        Toggle(L10n.string(""), isOn: $reverse).toggleStyle(.switch).labelsHidden()
                    }
                }
                SDiv()
                SRow(
                    title: "Collapse Panel",
                    subtitle: "Active only while the switcher panel is open."
                ) {
                    KeyCap(label: "esc")
                }
            }

            SSection(title: "Panel Shortcuts", footer: "Navigation is active while the switcher is open.") {
                SRow(title: "Navigate Sessions") {
                    HStack(spacing: 4) {
                        KeyCap(label: "↑")
                        KeyCap(label: "↓")
                    }
                }
                SDiv()
                SRow(title: "Jump to Terminal") {
                    HStack(spacing: 4) {
                        KeyCap(label: "⏎")
                        Text(L10n.string("or")).font(.system(size: 11)).foregroundStyle(.secondary)
                        KeyCap(label: "T")
                    }
                }
            }

            SSection(
                title: "Approval Shortcuts",
                footer:
                    "Global, but only registered while a permission request is pending — they never shadow other apps' shortcuts in normal use. Needs the Claude Code hook (Integrations)."
            ) {
                SRow(title: "Approve") { KeyCap(label: "\(mod)Y") }
                SDiv()
                SRow(title: "Always Allow") { KeyCap(label: "\(mod)A") }
                SDiv()
                SRow(title: "Deny") { KeyCap(label: "\(mod)N") }
            }
        }
        .onChange(of: enabled) { _, _ in HotKeyCenter.shared.update() }
        .onChange(of: modifier) { _, _ in HotKeyCenter.shared.update() }
        .onChange(of: reverse) { _, _ in HotKeyCenter.shared.update() }
    }
}
