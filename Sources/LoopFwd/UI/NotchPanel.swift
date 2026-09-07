import AppKit
import SwiftUI

/// Opt-in local rendering diagnosis. Only caller-supplied geometry and UI
/// state are logged; never pass task text, paths or provider payloads here.
enum IslandDebugTrace {
    static let enabled = ProcessInfo.processInfo.arguments.contains("--trace-island")
    private static let buffer = IslandTraceBuffer()

    static func record(_ event: String, _ detail: @autoclosure () -> String) {
        guard enabled else { return }
        buffer.append("\(ProcessInfo.processInfo.systemUptime): \(event) \(detail())")
    }

    static func snapshot() -> [String] { buffer.snapshot() }
}

/// No observable publisher: recording layout must not trigger another layout.
/// The diagnostics pane reads a snapshot only when explicitly refreshed.
final class IslandTraceBuffer {
    private let lock = NSLock()
    private let capacity: Int
    private var entries: [String] = []

    init(capacity: Int = 128) { self.capacity = max(1, min(capacity, 128)) }

    func append(_ value: String) {
        lock.lock()
        defer { lock.unlock() }
        entries.append(String(value.prefix(256)))
        if entries.count > capacity { entries.removeFirst(entries.count - capacity) }
    }

    func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }
}

/// Physical notch (or fallback pill) dimensions for the target screen.
struct NotchMetrics: Equatable {
    let width: CGFloat
    let height: CGFloat
    let hasNotch: Bool

    static func detect(on screen: NSScreen) -> NotchMetrics {
        let defaults = UserDefaults.standard
        let dw = CGFloat(defaults.double(forKey: Pref.notchWidthOffset))
        let dh = CGFloat(defaults.double(forKey: Pref.notchHeightOffset))
        return calculate(
            frameWidth: screen.frame.width,
            safeTop: screen.safeAreaInsets.top,
            leftWidth: screen.auxiliaryTopLeftArea?.width,
            rightWidth: screen.auxiliaryTopRightArea?.width,
            widthOffset: dw,
            heightOffset: dh
        )
    }

    /// Pure geometry seam adapted from the archived AppKit pilot tests.
    static func calculate(
        frameWidth: CGFloat, safeTop: CGFloat,
        leftWidth: CGFloat?, rightWidth: CGFloat?,
        widthOffset: CGFloat = 0, heightOffset: CGFloat = 0
    ) -> NotchMetrics {
        if safeTop > 0, let leftWidth, let rightWidth {
            let width = frameWidth - leftWidth - rightWidth
            return NotchMetrics(
                width: max(80, width + widthOffset),
                height: max(20, safeTop + heightOffset),
                hasNotch: true
            )
        }
        // No notch (external display / older Mac): these dimensions are used
        // only after reveal. The collapsed SwiftUI surface is an invisible
        // top-center hover target, not a persistent floating pill.
        return NotchMetrics(
            width: max(80, 148 + widthOffset),
            height: max(20, 32 + heightOffset),
            hasNotch: false
        )
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}

enum NotchSpacePolicy {
    static func shouldRestoreAfterKeyboardDismissal(isVisible: Bool, isOnActiveSpace: Bool, alpha: CGFloat) -> Bool {
        isVisible && isOnActiveSpace && alpha >= 0.5
    }

    static func collectionBehavior(hideInFullscreen: Bool, currentSpaceOnly: Bool) -> NSWindow.CollectionBehavior {
        var behavior: NSWindow.CollectionBehavior =
            currentSpaceOnly ? [.moveToActiveSpace] : [.canJoinAllSpaces, .stationary]
        // AppKit's fullscreen eligibility keeps the panel out of other apps'
        // fullscreen Spaces from the start, rather than hiding it after arrival.
        // fullScreenNone only disables entering fullscreen; it is not an opt-out
        // from joining another app's fullscreen Space.
        behavior.insert(hideInFullscreen ? .fullScreenPrimary : .fullScreenAuxiliary)
        return behavior
    }
}

/// Borderless, non-activating panel pinned to the top-center of the chosen screen.
/// The window itself is large and transparent; the island draws inside it.
final class NotchPanel: NSPanel {
    static let panelSize = NSSize(width: 920, height: 860)
    private let monitor: AgentMonitor
    private var spacePreferenceObserver: NSObjectProtocol?
    private var currentNotch: NotchMetrics?
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var presentationObserver: NSObjectProtocol?
    private var pointerUpdateScheduled = false
    private var currentPointerZone: NotchPointerZone = .outside
    private var wingIntentGeneration = 0
    private var centerIntentGeneration = 0
    private var islandExpanded = false
    private var islandHidden: Bool { !isOnActiveSpace }

    init(monitor: AgentMonitor) {
        self.monitor = monitor
        super.init(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true  // key only for the keyboard switcher
        level = .screenSaver
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        isMovable = false
        // IslandView installs an AppKit NSTrackingArea over its exact visible
        // bounds. The panel must opt into moved events for reliable transitions.
        acceptsMouseMovedEvents = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        // Product mode follows the user across Spaces. The explicit launch
        // argument gives UI smoke tests a recoverable, current-Space-only app
        // without changing the shipped default or writing a user preference.
        updateSpacePolicy()

        repositionOnTargetScreen()
        startSpaceWatch()
        startPointerMonitoring()
    }

    deinit {
        if let spacePreferenceObserver { NotificationCenter.default.removeObserver(spacePreferenceObserver) }
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor) }
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
        if let presentationObserver {
            NotificationCenter.default.removeObserver(presentationObserver)
        }
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Intercept before SwiftUI so ScrollView etc. can't swallow the
    /// switcher's arrow keys / return / esc.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, SwitcherState.shared.handleKey(event) { return }
        super.sendEvent(event)
    }

    /// The screen chosen in settings; "auto" prefers the built-in (notched)
    /// display, falling back to the main screen.
    static func targetScreen() -> NSScreen? {
        let selection = UserDefaults.standard.string(forKey: Pref.displaySelection) ?? "auto"
        if selection.hasPrefix("id:"), let id = CGDirectDisplayID(selection.dropFirst(3)),
            let screen = NSScreen.screens.first(where: { $0.displayID == id })
        {
            return screen
        }
        return NSScreen.screens.first { $0.safeAreaInsets.top > 0 }
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }

    func repositionOnTargetScreen() {
        guard let screen = Self.targetScreen() else { return }

        let notch = NotchMetrics.detect(on: screen)
        IslandDebugTrace.record(
            "reposition", "screen=\(screen.frame) notch=\(notch.hasNotch) oldFrame=\(frame)")
        currentNotch = notch
        currentPointerZone = .outside
        wingIntentGeneration += 1
        centerIntentGeneration += 1
        NotchPointerState.shared.reveal(nil)
        if let host = contentView as? NSHostingView<IslandView> {
            host.rootView = IslandView(monitor: monitor, notch: notch)
        } else {
            contentView = NSHostingView(rootView: IslandView(monitor: monitor, notch: notch))
        }

        let frame = NSRect(
            x: screen.frame.midX - Self.panelSize.width / 2,
            y: screen.frame.maxY - Self.panelSize.height,
            width: Self.panelSize.width,
            height: Self.panelSize.height
        )
        setFrame(frame, display: true)
        updateSpacePolicy()
        schedulePointerUpdate(immediate: true)
    }

    // MARK: - Collapsed pointer routing

    /// The collapsed panel is click-through except for the center notch target.
    /// Since click-through windows do not receive SwiftUI hover, AppKit watches
    /// the pointer independently and drives both native hit routing and wing UI.
    private func startPointerMonitoring() {
        presentationObserver = NotificationCenter.default.addObserver(
            forName: .islandPresentationChanged,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let expanded = note.object as? Bool else { return }
            self?.islandExpanded = expanded
            self?.schedulePointerUpdate(immediate: true)
        }

        let events: NSEvent.EventTypeMask = [
            .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
        ]
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: events) {
            [weak self] _ in
            DispatchQueue.main.async { self?.schedulePointerUpdate() }
        }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: events) {
            [weak self] event in
            self?.schedulePointerUpdate()
            return event
        }
        schedulePointerUpdate(immediate: true)
    }

    /// Limit pointer geometry work to roughly 20 Hz. Immediate updates are used
    /// only for state/display transitions where stale hit routing is visible.
    private func schedulePointerUpdate(immediate: Bool = false) {
        if immediate {
            pointerUpdateScheduled = false
            updatePointerPolicy()
            return
        }
        guard !pointerUpdateScheduled else { return }
        pointerUpdateScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self else { return }
            self.pointerUpdateScheduled = false
            self.updatePointerPolicy()
        }
    }

    private func updatePointerPolicy() {
        guard let notch = currentNotch else {
            ignoresMouseEvents = true
            return
        }

        let style = UserDefaults.standard.string(forKey: Pref.pillStyle) ?? "clean"
        let zone = NotchPointerGeometry.zone(
            at: NSEvent.mouseLocation,
            panelFrame: frame,
            notch: notch,
            pillStyle: style
        )
        ignoresMouseEvents = !NotchPointerPolicy.capturesMouseEvents(
            zone: zone,
            expanded: islandExpanded,
            hidden: islandHidden
        )

        if islandHidden || islandExpanded {
            currentPointerZone = zone
            cancelPointerIntents()
            NotchPointerState.shared.reveal(nil)
            return
        }

        guard zone != currentPointerZone else { return }
        currentPointerZone = zone
        wingIntentGeneration += 1
        centerIntentGeneration += 1

        if let wing = NotchPointerPolicy.wing(for: zone) {
            if let revealedWing = NotchPointerState.shared.revealedWing,
                revealedWing != wing
            {
                NotchPointerState.shared.reveal(nil)
            }
            scheduleWingReveal(wing)
        } else if zone == .center {
            NotchPointerState.shared.reveal(nil)
            scheduleCenterExpansion()
        } else {
            scheduleWingRestore()
        }
    }

    private func cancelPointerIntents() {
        wingIntentGeneration += 1
        centerIntentGeneration += 1
    }

    private func scheduleWingReveal(_ wing: NotchWing) {
        let generation = wingIntentGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self,
                generation == self.wingIntentGeneration,
                NotchPointerPolicy.wing(for: self.currentPointerZone) == wing,
                !self.islandExpanded,
                !self.islandHidden
            else { return }
            NotchPointerState.shared.reveal(wing)
        }
    }

    private func scheduleWingRestore() {
        let generation = wingIntentGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) { [weak self] in
            guard let self,
                generation == self.wingIntentGeneration,
                self.currentPointerZone == .outside,
                !self.islandExpanded,
                !self.islandHidden
            else { return }
            NotchPointerState.shared.reveal(nil)
        }
    }

    private func scheduleCenterExpansion() {
        guard UserDefaults.standard.bool(forKey: Pref.expandOnHover) else { return }
        let generation = centerIntentGeneration
        let delay = max(
            0.02,
            UserDefaults.standard.double(forKey: Pref.hoverDuration)
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self,
                generation == self.centerIntentGeneration,
                self.currentPointerZone == .center,
                !self.islandExpanded,
                !self.islandHidden
            else { return }
            NotificationCenter.default.post(name: .islandExpand, object: nil)
        }
    }

    // MARK: - Native fullscreen Space eligibility

    private func startSpaceWatch() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(spaceChanged),
            name: NSWorkspace.activeSpaceDidChangeNotification, object: nil
        )
        spacePreferenceObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: UserDefaults.standard, queue: .main
        ) { [weak self] _ in self?.updateSpacePolicy() }
    }

    @objc private func spaceChanged() {
        IslandDebugTrace.record("space", "active=\(isOnActiveSpace) expanded=\(islandExpanded)")
        // Input must not pull a panel excluded from the current Space forward.
        // Do not toggle alpha on menu-bar changes: an auto-hidden menu bar is
        // not evidence of fullscreen and can change during a Space transition.
        if islandHidden { SwitcherState.shared.end(collapse: true) }
        schedulePointerUpdate(immediate: true)
    }

    private func updateSpacePolicy() {
        let behavior = NotchSpacePolicy.collectionBehavior(
            hideInFullscreen: UserDefaults.standard.bool(forKey: Pref.hideInFullscreen),
            currentSpaceOnly: ProcessInfo.processInfo.arguments.contains("--current-space-only"))
        if collectionBehavior != behavior {
            IslandDebugTrace.record("space-policy", "old=\(collectionBehavior.rawValue) new=\(behavior.rawValue)")
            collectionBehavior = behavior
        }
    }
}
