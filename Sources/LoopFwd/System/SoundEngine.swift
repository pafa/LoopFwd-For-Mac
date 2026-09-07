import AppKit

/// Central sound playback: per-event sounds, master volume, quiet hours,
/// and user-imported sounds. Sound prefs store either a system sound name
/// ("Glass"), a custom sound reference ("custom:Airhorn"), or "Off".
final class SoundEngine {
    static let shared = SoundEngine()
    static let off = "Off"
    static let customPrefix = "custom:"

    private var current: NSSound?  // keep a reference while playing
    private let defaults = UserDefaults.standard

    func start() {
        // Lifecycle playback is owned by AgentNotificationRouter.
    }

    func playLifecycle(_ kind: AgentLifecycleEventKind) {
        switch kind {
        case .started: playEvent(Pref.soundSessionStart)
        case .completed: playEvent(Pref.soundTaskComplete)
        case .needsAttention: playEvent(Pref.soundApprovalNeeded)
        case .failed: playEvent(Pref.soundTaskFailed)
        case .stalled: playEvent(Pref.soundTaskStalled)
        case .resumed, .stopped: break
        }
    }

    /// Play the sound configured for a preference key, honoring master
    /// switch and quiet hours.
    func playEvent(_ prefKey: String) {
        guard defaults.bool(forKey: Pref.soundsEnabled), !inQuietHours else { return }
        play(defaults.string(forKey: prefKey) ?? Self.off)
    }

    /// Unconditional playback for settings previews.
    func preview(_ name: String) { play(name) }

    private func play(_ name: String) {
        guard name != Self.off else { return }
        let sound: NSSound?
        if name.hasPrefix(Self.customPrefix) {
            let base = String(name.dropFirst(Self.customPrefix.count))
            sound = Self.customSoundFiles()
                .first { ($0.lastPathComponent as NSString).deletingPathExtension == base }
                .flatMap { NSSound(contentsOf: $0, byReference: true) }
        } else {
            sound = NSSound(named: name)
        }
        guard let sound else { return }
        sound.volume = Float(defaults.double(forKey: Pref.soundVolume))
        // NSSound(named:) hands back a shared, cached instance, and .play() is a
        // no-op while it's already playing — so a second event within the sound's
        // duration would be silent. Rewind first so every event actually sounds.
        if sound.isPlaying { sound.stop() }
        current = sound
        sound.play()
    }

    var inQuietHours: Bool {
        guard defaults.bool(forKey: Pref.quietHoursEnabled) else { return false }
        let start = defaults.integer(forKey: Pref.quietHoursStart)
        let end = defaults.integer(forKey: Pref.quietHoursEnd)
        guard start != end else { return false }
        let comps = Calendar.current.dateComponents([.hour, .minute], from: Date())
        let now = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
        // Range crosses midnight when end < start (e.g. 22:00 → 08:00).
        return start < end ? (now >= start && now < end) : (now >= start || now < end)
    }

    // MARK: - Sound catalogs

    /// System sounds in /System/Library/Sounds ("Glass", "Ping", …).
    static var systemSounds: [String] {
        let dir = "/System/Library/Sounds"
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        return files.map { ($0 as NSString).deletingPathExtension }.sorted()
    }

    /// ~/Library/Application Support/LoopFwd/Sounds
    static var customSoundsDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("LoopFwd/Sounds", isDirectory: true)
    }

    static func customSoundFiles() -> [URL] {
        let urls =
            (try? FileManager.default.contentsOfDirectory(
                at: customSoundsDirectory, includingPropertiesForKeys: nil)) ?? []
        return
            urls
            .filter { ["aiff", "aif", "wav", "mp3", "m4a", "caf"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Display names of imported sounds (no extension).
    static func customSoundNames() -> [String] {
        customSoundFiles().map { ($0.lastPathComponent as NSString).deletingPathExtension }
    }

    /// Copy a user-picked audio file into the custom sounds folder.
    @discardableResult
    static func importSound(from url: URL) -> Result<Void, Error> {
        do {
            let manager = FileManager.default
            let dir = customSoundsDirectory
            try manager.createDirectory(at: dir, withIntermediateDirectories: true)
            let destination = dir.appendingPathComponent(url.lastPathComponent)
            let staging = dir.appendingPathComponent(".\(UUID().uuidString)-\(url.lastPathComponent)")
            let backup = dir.appendingPathComponent(".\(UUID().uuidString)-backup-\(url.lastPathComponent)")
            try manager.copyItem(at: url, to: staging)
            if manager.fileExists(atPath: destination.path) {
                try manager.moveItem(at: destination, to: backup)
            }
            do {
                try manager.moveItem(at: staging, to: destination)
            } catch {
                if !manager.fileExists(atPath: destination.path),
                    manager.fileExists(atPath: backup.path)
                {
                    try? manager.moveItem(at: backup, to: destination)
                }
                try? manager.removeItem(at: staging)
                throw error
            }
            if manager.fileExists(atPath: backup.path) {
                do {
                    try manager.removeItem(at: backup)
                } catch {
                    NSLog("SoundEngine: imported sound but could not remove backup: \(error.localizedDescription)")
                }
            }
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    @discardableResult
    static func removeSound(named name: String) -> Result<Void, Error> {
        do {
            for file in customSoundFiles()
            where (file.lastPathComponent as NSString).deletingPathExtension == name {
                try FileManager.default.removeItem(at: file)
            }
            return .success(())
        } catch {
            return .failure(error)
        }
    }
}
