import AppKit
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

// MARK: - General

struct GeneralPane: View {
    @AppStorage(Pref.interfaceLanguage) private var interfaceLanguage = Pref.Default.interfaceLanguage
    @AppStorage(Pref.expandOnHover) private var expandOnHover = Pref.Default.expandOnHover
    @AppStorage(Pref.hoverDuration) private var hoverDuration = Pref.Default.hoverDuration
    @AppStorage(Pref.smartSuppression) private var smartSuppression = Pref.Default.smartSuppression
    @AppStorage(Pref.autoRevealOnComplete) private var autoRevealOnComplete = Pref.Default.autoRevealOnComplete
    @AppStorage(Pref.hideInFullscreen) private var hideInFullscreen = Pref.Default.hideInFullscreen
    @AppStorage(Pref.autoHideWhenEmpty) private var autoHideWhenEmpty = Pref.Default.autoHideWhenEmpty
    @AppStorage(Pref.autoCollapse) private var autoCollapse = Pref.Default.autoCollapse
    @AppStorage(Pref.autoRevealDwell) private var autoRevealDwell = Pref.Default.autoRevealDwell
    @AppStorage(Pref.dismissRevealOnOutsideClick) private var dismissOutsideClick = Pref.Default
        .dismissRevealOnOutsideClick
    @AppStorage(Pref.hideIdleAfterMinutes) private var hideIdleAfterMinutes = Pref.Default.hideIdleAfterMinutes
    @AppStorage(Pref.disableClickToJump) private var disableClickToJump = Pref.Default.disableClickToJump
    @AppStorage(Pref.pollInterval) private var pollInterval = Pref.Default.pollInterval
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var launchError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SSection(title: "System") {
                SRow(title: "Interface language", subtitle: "Language changes take effect after restarting LoopFwd.") {
                    Picker(L10n.string("Interface language"), selection: $interfaceLanguage) {
                        Text(L10n.string("Follow system")).tag("system")
                        Text("简体中文").tag("zh-Hans")
                        Text("English").tag("en")
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                SDiv()
                SRow(title: "Launch at Login") {
                    Toggle(L10n.string(""), isOn: $launchAtLogin)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .disabled(!LoginItem.isAvailable)
                        .onChange(of: launchAtLogin) { _, new in
                            if case .failure(let error) = LoginItem.set(enabled: new) {
                                launchAtLogin = LoginItem.isEnabled
                                launchError = error.localizedDescription
                            }
                        }
                }
            }

            SSection(title: "Expansion") {
                SRow(title: "Expand notch on hover") {
                    Toggle(L10n.string(""), isOn: $expandOnHover).toggleStyle(.switch).labelsHidden()
                }
                SDiv()
                SRow(
                    title: "Hover duration",
                    subtitle: "How long the cursor must rest on the island before it opens."
                ) {
                    HStack(spacing: 10) {
                        Slider(value: $hoverDuration, in: 0...0.6, step: 0.05)
                            .frame(width: 160)
                        Text(String(format: "%.2fs", hoverDuration))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 42, alignment: .trailing)
                    }
                }
                .disabled(!expandOnHover)
                SDiv()
                SRow(
                    title: "Smart suppression",
                    subtitle: "Suppress only when the exact task is known to be visible, not merely its application."
                ) {
                    Toggle(L10n.string(""), isOn: $smartSuppression).toggleStyle(.switch).labelsHidden()
                }
                SDiv()
                SRow(
                    title: "Auto-expand panel on task complete",
                    subtitle:
                        "Off by default. Completion still appears briefly and can notify without taking over the screen."
                ) {
                    Toggle(L10n.string(""), isOn: $autoRevealOnComplete).toggleStyle(.switch).labelsHidden()
                }
            }

            SSection(title: "Visibility") {
                SRow(
                    title: "Hide in fullscreen",
                    subtitle:
                        "Keeps the island out of other apps' fullscreen spaces. Menu-bar auto-hide does not affect this setting."
                ) {
                    Toggle(L10n.string(""), isOn: $hideInFullscreen).toggleStyle(.switch).labelsHidden()
                }
                SDiv()
                SRow(title: "Auto-hide when no active sessions") {
                    Toggle(L10n.string(""), isOn: $autoHideWhenEmpty).toggleStyle(.switch).labelsHidden()
                }
            }

            SSection(title: "Dismissal") {
                SRow(title: "Auto-collapse on mouse leave") {
                    Toggle(L10n.string(""), isOn: $autoCollapse).toggleStyle(.switch).labelsHidden()
                }
                SDiv()
                SRow(
                    title: "Auto reveal dwell",
                    subtitle: "How long the panel stays open after an event reveal."
                ) {
                    Picker("", selection: $autoRevealDwell) {
                        ForEach([2.0, 3.0, 5.0, 8.0, 10.0, 15.0], id: \.self) {
                            Text("\(Int($0))s").tag($0)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                SDiv()
                SRow(
                    title: "Dismiss auto reveal on outside click",
                    subtitle: "Clicking anywhere outside the panel closes an event reveal immediately."
                ) {
                    Toggle(L10n.string(""), isOn: $dismissOutsideClick).toggleStyle(.switch).labelsHidden()
                }
                SDiv()
                SRow(
                    title: "Idle session cleanup",
                    subtitle:
                        "Trim idle provider records from Diagnostics after this long. Idle never fills the island."
                ) {
                    Picker("", selection: $hideIdleAfterMinutes) {
                        Text(L10n.string("Never")).tag(0)
                        Text(L10n.string("30 minutes")).tag(30)
                        Text(L10n.string("1 hour")).tag(60)
                        Text(L10n.string("2 hours")).tag(120)
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }

            SSection(title: "Interaction") {
                SRow(
                    title: "Disable click-to-jump",
                    subtitle:
                        "When enabled, clicking a session opens its detail view instead of switching to its terminal."
                ) {
                    Toggle(L10n.string(""), isOn: $disableClickToJump).toggleStyle(.switch).labelsHidden()
                }
                SDiv()
                SRow(title: "Refresh interval") {
                    Picker("", selection: $pollInterval) {
                        Text(L10n.string("Automatic · 2s active / 8s idle")).tag(0.0)
                        Text(L10n.string("1 second")).tag(1.0)
                        Text(L10n.string("2 seconds")).tag(2.0)
                        Text(L10n.string("3 seconds")).tag(3.0)
                        Text(L10n.string("5 seconds")).tag(5.0)
                        Text(L10n.string("8 seconds")).tag(8.0)
                        if ![0, 1, 2, 3, 5, 8].contains(pollInterval) {
                            Text(L10n.format("%g seconds", pollInterval)).tag(pollInterval)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }
        }
        .alert(
            L10n.string("Launch at Login"),
            isPresented: Binding(
                get: { launchError != nil },
                set: { if !$0 { launchError = nil } }
            )
        ) {
            Button(L10n.string("OK"), role: .cancel) { launchError = nil }
        } message: {
            Text(launchError ?? L10n.string("The setting could not be changed."))
        }
    }
}
