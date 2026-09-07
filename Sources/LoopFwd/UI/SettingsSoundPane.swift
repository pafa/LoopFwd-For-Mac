import AppKit
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

// MARK: - Sound

struct SoundPane: View {
    @AppStorage(Pref.soundsEnabled) private var soundsEnabled = Pref.Default.soundsEnabled
    @AppStorage(Pref.soundVolume) private var volume = Pref.Default.soundVolume
    @AppStorage(Pref.quietHoursEnabled) private var quietEnabled = Pref.Default.quietHoursEnabled
    @AppStorage(Pref.quietHoursStart) private var quietStart = Pref.Default.quietHoursStart
    @AppStorage(Pref.quietHoursEnd) private var quietEnd = Pref.Default.quietHoursEnd
    @State private var customSounds: [String] = SoundEngine.customSoundNames()
    @State private var soundError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SSection {
                SRow(title: "Enable Sound Effects") {
                    Toggle(L10n.string(""), isOn: $soundsEnabled).toggleStyle(.switch).labelsHidden()
                }
                SDiv()
                SRow(title: "Volume") {
                    HStack(spacing: 10) {
                        Image(systemName: "speaker.fill")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                        Slider(value: $volume, in: 0...1) { editing in
                            if !editing { SoundEngine.shared.preview(currentPreviewSound) }
                        }
                        .frame(width: 150)
                        Image(systemName: "speaker.wave.3.fill")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                        Text("\(Int(volume * 100))%")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 38, alignment: .trailing)
                    }
                }
                .disabled(!soundsEnabled)
            }

            SSection(title: "Session") {
                SoundPickerRow(
                    title: "Session Start",
                    subtitle: "A new Claude / Codex / OpenCode session appears",
                    key: Pref.soundSessionStart, defaultSound: Pref.Default.soundSessionStart,
                    customSounds: customSounds)
                SDiv()
                SoundPickerRow(
                    title: "Task Complete",
                    subtitle: "AI finished its turn",
                    key: Pref.soundTaskComplete, defaultSound: Pref.Default.soundTaskComplete,
                    customSounds: customSounds)
                SDiv()
                SoundPickerRow(
                    title: "Task Failed",
                    subtitle: "A provider-confirmed turn failed",
                    key: Pref.soundTaskFailed, defaultSound: Pref.Default.soundTaskFailed,
                    customSounds: customSounds)
                SDiv()
                SoundPickerRow(
                    title: "Possibly Stalled",
                    subtitle: "No provider-backed progress for three minutes",
                    key: Pref.soundTaskStalled, defaultSound: Pref.Default.soundTaskStalled,
                    customSounds: customSounds)
                SDiv()
                SoundPickerRow(
                    title: "Task Acknowledge",
                    subtitle: "You submitted a prompt and the agent got to work",
                    key: Pref.soundAcknowledge, defaultSound: Pref.Default.soundAcknowledge,
                    customSounds: customSounds)
            }

            SSection(title: "Interactions") {
                SoundPickerRow(
                    title: "Needs Attention",
                    subtitle: "A live question, approval, sign-in or confirmation is waiting",
                    key: Pref.soundApprovalNeeded, defaultSound: Pref.Default.soundApprovalNeeded,
                    customSounds: customSounds)
            }

            SSection(title: "My Sounds", footer: "Imported sounds appear in every picker above.") {
                if customSounds.isEmpty {
                    SRow(title: "No imported sounds yet.") { EmptyView() }
                }
                ForEach(customSounds, id: \.self) { name in
                    SRow(title: name) {
                        HStack(spacing: 10) {
                            Button {
                                SoundEngine.shared.preview(SoundEngine.customPrefix + name)
                            } label: {
                                Image(systemName: "play.circle.fill").font(.system(size: 16))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(L10n.format("Preview sound %@", name))
                            Button {
                                switch SoundEngine.removeSound(named: name) {
                                case .success:
                                    customSounds = SoundEngine.customSoundNames()
                                case .failure(let error):
                                    soundError = error.localizedDescription
                                }
                            } label: {
                                Image(systemName: "trash").font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(L10n.format("Remove sound %@", name))
                        }
                    }
                    SDiv()
                }
                SRow(title: "") {
                    Button(action: importSound) {
                        Label(L10n.string("Add Sound…"), systemImage: "plus")
                    }
                }
            }

            SSection(
                title: "Quiet Hours",
                footer:
                    "Mutes all sounds during the selected time range (crosses midnight if end is earlier than start). Useful when agents run overnight."
            ) {
                SRow(title: "Silence during quiet hours") {
                    Toggle(L10n.string(""), isOn: $quietEnabled).toggleStyle(.switch).labelsHidden()
                }
                SDiv()
                SRow(title: "From") { HourPicker(minutes: $quietStart) }
                    .disabled(!quietEnabled)
                SDiv()
                SRow(title: "Until") { HourPicker(minutes: $quietEnd) }
                    .disabled(!quietEnabled)
            }
        }
        .alert(
            L10n.string("Sound Library"),
            isPresented: Binding(
                get: { soundError != nil },
                set: { if !$0 { soundError = nil } }
            )
        ) {
            Button(L10n.string("OK"), role: .cancel) { soundError = nil }
        } message: {
            Text(soundError ?? L10n.string("The sound library could not be changed."))
        }
    }

    private var currentPreviewSound: String {
        let configured =
            UserDefaults.standard.string(forKey: Pref.soundTaskComplete)
            ?? Pref.Default.soundTaskComplete
        return configured == SoundEngine.off ? Pref.Default.soundTaskComplete : configured
    }

    private func importSound() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if case .failure(let error) = SoundEngine.importSound(from: url) {
                soundError = "\(url.lastPathComponent): \(error.localizedDescription)"
                break
            }
        }
        customSounds = SoundEngine.customSoundNames()
    }
}

/// Sound selector + preview button for one event.
private struct SoundPickerRow: View {
    let title: String
    let subtitle: String?
    let key: String
    let customSounds: [String]
    @AppStorage private var selection: String

    init(title: String, subtitle: String? = nil, key: String, defaultSound: String, customSounds: [String]) {
        self.title = title
        self.subtitle = subtitle
        self.key = key
        self.customSounds = customSounds
        // Match Pref.registerDefaults so the picker's default and the value
        // SoundEngine reads never disagree.
        _selection = AppStorage(wrappedValue: defaultSound, key)
    }

    var body: some View {
        SRow(title: title, subtitle: subtitle) {
            HStack(spacing: 8) {
                Picker("", selection: $selection) {
                    Text(L10n.string("Off")).tag(SoundEngine.off)
                    ForEach(customSounds, id: \.self) { name in
                        Text("♪ \(name)").tag(SoundEngine.customPrefix + name)
                    }
                    ForEach(SoundEngine.systemSounds, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                .labelsHidden()
                .frame(width: 130)
                .onChange(of: selection) { _, new in
                    SoundEngine.shared.preview(new)
                }

                Button {
                    SoundEngine.shared.preview(selection)
                } label: {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 17))
                        .foregroundStyle(selection == SoundEngine.off ? .secondary : .primary)
                }
                .buttonStyle(.plain)
                .disabled(selection == SoundEngine.off)
                .accessibilityLabel(L10n.format("Preview sound for %@", L10n.string(title)))
            }
        }
    }
}

private struct HourPicker: View {
    @Binding var minutes: Int

    var body: some View {
        Picker("", selection: $minutes) {
            ForEach(0..<48, id: \.self) { slot in
                Text(label(slot * 30)).tag(slot * 30)
            }
        }
        .labelsHidden()
        .fixedSize()
    }

    private func label(_ mins: Int) -> String {
        String(format: "%02d:%02d", mins / 60, mins % 60)
    }
}
