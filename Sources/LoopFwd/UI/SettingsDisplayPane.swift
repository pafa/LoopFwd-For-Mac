import AppKit
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

// MARK: - Display

struct DisplayPane: View {
    @AppStorage(Pref.pillStyle) private var pillStyle = Pref.Default.pillStyle
    @AppStorage(Pref.displaySelection) private var displaySelection = Pref.Default.displaySelection
    @AppStorage(Pref.contentFontSize) private var contentFontSize = Pref.Default.contentFontSize
    @AppStorage(Pref.maxPanelWidth) private var maxPanelWidth = Pref.Default.maxPanelWidth
    @AppStorage(Pref.maxPanelHeight) private var maxPanelHeight = Pref.Default.maxPanelHeight
    @AppStorage(Pref.showLastPrompt) private var showLastPrompt = Pref.Default.showLastPrompt
    @AppStorage(Pref.showActivity) private var showActivity = Pref.Default.showActivity
    @AppStorage(Pref.showTerminalChip) private var showTerminalChip = Pref.Default.showTerminalChip
    @AppStorage(Pref.showTasks) private var showTasks = Pref.Default.showTasks
    @AppStorage(Pref.showModel) private var showModel = Pref.Default.showModel
    @AppStorage(Pref.showGitBranch) private var showGitBranch = Pref.Default.showGitBranch
    @AppStorage(Pref.showSubagents) private var showSubagents = Pref.Default.showSubagents
    @AppStorage(Pref.maxVisibleSessions) private var maxVisibleSessions = Pref.Default.maxVisibleSessions
    @AppStorage(Pref.notchWidthOffset) private var notchWidthOffset = Pref.Default.notchWidthOffset
    @AppStorage(Pref.notchHeightOffset) private var notchHeightOffset = Pref.Default.notchHeightOffset

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SSection(title: "Notch") {
                VStack(spacing: 12) {
                    HStack(spacing: 12) {
                        PillStyleCard(
                            name: "Clean", caption: "More space for the menu bar",
                            style: "clean", selection: $pillStyle
                        )
                        PillStyleCard(
                            name: "Detailed", caption: "Live activity & session count",
                            style: "detailed", selection: $pillStyle
                        )
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 12)

                    Divider().padding(.leading, 14)

                    SRow(
                        title: "Display",
                        subtitle:
                            "Automatic prefers the built-in notch. On a display without a notch, LoopFwd stays hidden until you move the pointer to the top center."
                    ) {
                        DisplayPicker(selection: $displaySelection)
                    }
                }
                .padding(.bottom, 2)
            }

            SSection(title: "Panel size") {
                SRow(title: "Content Font Size") {
                    Picker("", selection: $contentFontSize) {
                        Text(L10n.string("10pt")).tag(10)
                        Text(L10n.string("11pt (Default)")).tag(11)
                        Text(L10n.string("12pt")).tag(12)
                        Text(L10n.string("13pt")).tag(13)
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                SDiv()
                SRow(title: "Max Panel Width") {
                    SliderWithValue(value: $maxPanelWidth, range: 460...800, step: 10, unit: "pt")
                }
                SDiv()
                SRow(
                    title: "Max Panel Height",
                    subtitle: "The session list scrolls when it grows past this."
                ) {
                    SliderWithValue(value: $maxPanelHeight, range: 320...800, step: 20, unit: "pt")
                }
            }

            SSection(title: "Session card") {
                SRow(
                    title: "Show task summary",
                    subtitle: "Keeps the latest meaningful user goal; short confirmations are ignored."
                ) {
                    Toggle(L10n.string(""), isOn: $showLastPrompt).toggleStyle(.switch).labelsHidden()
                }
                SDiv()
                SRow(
                    title: "Show live activity",
                    subtitle: "e.g. \u{201C}Writing IslandView.swift\u{201D} while the agent works."
                ) {
                    Toggle(L10n.string(""), isOn: $showActivity).toggleStyle(.switch).labelsHidden()
                }
                SDiv()
                SRow(title: "Show AI model", subtitle: "Opus, Sonnet, Fable… read from the session transcript.") {
                    Toggle(L10n.string(""), isOn: $showModel).toggleStyle(.switch).labelsHidden()
                }
                SDiv()
                SRow(title: "Show git branch") {
                    Toggle(L10n.string(""), isOn: $showGitBranch).toggleStyle(.switch).labelsHidden()
                }
                SDiv()
                SRow(
                    title: "Show subagents",
                    subtitle: "Fan-out Task subagents while they run. Keeps the panel clean when off."
                ) {
                    Toggle(L10n.string(""), isOn: $showSubagents).toggleStyle(.switch).labelsHidden()
                }
                SDiv()
                SRow(title: "Show terminal app chip") {
                    Toggle(L10n.string(""), isOn: $showTerminalChip).toggleStyle(.switch).labelsHidden()
                }
                SDiv()
                SRow(title: "Show task checklists") {
                    Toggle(L10n.string(""), isOn: $showTasks).toggleStyle(.switch).labelsHidden()
                }
                SDiv()
                SRow(title: "Max visible sessions") {
                    Stepper("\(maxVisibleSessions)", value: $maxVisibleSessions, in: 3...12)
                        .fixedSize()
                }
            }

            SSection(
                title: "Tuning",
                footer:
                    "Fine-tune the pill dimensions if your machine doesn't fit perfectly. 0 uses the macOS API value."
            ) {
                SRow(title: "Notch width") {
                    SliderWithValue(value: $notchWidthOffset, range: -60...60, step: 2, unit: "pt", signed: true)
                }
                SDiv()
                SRow(title: "Notch height") {
                    SliderWithValue(value: $notchHeightOffset, range: -10...20, step: 1, unit: "pt", signed: true)
                }
            }
        }
        .onChange(of: displaySelection) { _, _ in reposition() }
        .onChange(of: notchWidthOffset) { _, _ in reposition() }
        .onChange(of: notchHeightOffset) { _, _ in reposition() }
    }

    private func reposition() {
        NotificationCenter.default.post(name: .repositionPanel, object: nil)
    }
}

/// Selectable mini-preview card for the collapsed pill style.
private struct PillStyleCard: View {
    let name: String
    let caption: String
    let style: String
    @Binding var selection: String

    private var selected: Bool { selection == style }

    var body: some View {
        Button {
            selection = style
        } label: {
            VStack(spacing: 8) {
                // Mini pill mock
                HStack(spacing: 5) {
                    Circle().fill(AgentStatus.working.color).frame(width: 5, height: 5)
                    if style == "detailed" {
                        Capsule().fill(.white.opacity(0.35)).frame(width: 42, height: 4)
                        Spacer(minLength: 4)
                        Text(L10n.string("2 ses"))
                            .font(.system(size: 7, weight: .bold, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.6))
                    } else {
                        Spacer(minLength: 4)
                        Text(L10n.string("2"))
                            .font(.system(size: 8, weight: .bold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
                .padding(.horizontal, 9)
                .frame(width: style == "detailed" ? 110 : 76, height: 20)
                .background(Capsule().fill(.black))
                .overlay(Capsule().strokeBorder(.white.opacity(0.15), lineWidth: 1))

                Text(name)
                    .font(.system(size: 13, weight: .semibold))
                Text(caption)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white.opacity(selected ? 0.08 : 0.03))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(
                        selected ? Color.accentColor : Color.white.opacity(0.1),
                        lineWidth: selected ? 1.5 : 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Picker over connected screens; stores "auto" or "id:<CGDirectDisplayID>".
private struct DisplayPicker: View {
    @Binding var selection: String
    @State private var screens: [(id: String, name: String)] = []

    var body: some View {
        Picker("", selection: $selection) {
            Text(L10n.string("Automatic")).tag("auto")
            ForEach(screens, id: \.id) { screen in
                Text(screen.name).tag(screen.id)
            }
            // Keep a stale selection visible instead of crashing the picker.
            if selection != "auto", !screens.contains(where: { $0.id == selection }) {
                Text(L10n.string("Disconnected display")).tag(selection)
            }
        }
        .labelsHidden()
        .fixedSize()
        .onAppear(perform: refresh)
        .onReceive(
            NotificationCenter.default.publisher(
                for: NSApplication.didChangeScreenParametersNotification)
        ) { _ in refresh() }
    }

    private func refresh() {
        screens = NSScreen.screens.compactMap { screen in
            guard let id = screen.displayID else { return nil }
            let notchMark = screen.safeAreaInsets.top > 0 ? " (notch)" : ""
            return ("id:\(id)", screen.localizedName + notchMark)
        }
    }
}

private struct SliderWithValue: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let unit: String
    var signed = false

    var body: some View {
        HStack(spacing: 10) {
            Slider(value: $value, in: range, step: step)
                .frame(width: 170)
            Text("\(signed && value > 0 ? "+" : "")\(Int(value))\(unit)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .trailing)
        }
    }
}
