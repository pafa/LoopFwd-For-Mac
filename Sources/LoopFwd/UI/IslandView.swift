import AppKit
import SwiftUI

/// AppKit owns pointer entry/exit for the actual island bounds. SwiftUI hover
/// callbacks are unreliable in a borderless non-activating NSPanel, especially
/// across Spaces and display changes.
struct AppKitHoverTracker: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> TrackingView {
        TrackingView(onChange: onChange)
    }

    func updateNSView(_ view: TrackingView, context: Context) {
        view.onChange = onChange
    }

    final class TrackingView: NSView {
        var onChange: (Bool) -> Void
        private var area: NSTrackingArea?

        init(onChange: @escaping (Bool) -> Void) {
            self.onChange = onChange
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            // inVisibleRect follows animated bounds automatically. Replacing
            // the area every frame resets pointer tracking during expansion.
            guard area == nil else { return }
            IslandDebugTrace.record("tracking-install", "bounds=\(bounds)")
            let next = NSTrackingArea(
                rect: .zero,
                options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: self,
                userInfo: nil
            )
            addTrackingArea(next)
            area = next
        }

        override func mouseEntered(with event: NSEvent) { onChange(true) }
        override func mouseExited(with event: NSEvent) { onChange(false) }
    }
}

enum IslandCollapsePolicy {
    static func shouldCollapse(
        autoCollapse: Bool, autoRevealActive: Bool,
        switcherActive: Bool, mouseInside: Bool
    ) -> Bool {
        autoCollapse && !autoRevealActive && !switcherActive && !mouseInside
    }
}

struct IslandView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var monitor: AgentMonitor
    @ObservedObject private var codexServer = CodexAppServer.shared
    @ObservedObject private var switcher = SwitcherState.shared
    @ObservedObject private var outcomePresentation = OutcomePresentation.shared
    @ObservedObject private var notchPointer = NotchPointerState.shared
    @ObservedObject private var operationalDiagnostics = OperationalDiagnostics.shared
    let notch: NotchMetrics

    @State private var expanded = false
    @State private var selectedSessionID: String?
    @AppStorage(Pref.providerControlsEnabled) private var providerControlsEnabled = Pref.Default.providerControlsEnabled
    @State private var mouseInside = false
    @State private var hoverToken = 0
    @State private var autoRevealToken = 0
    @State private var autoRevealActive = false
    @State private var outsideClickMonitor: Any?
    @State private var composingCodexTask = false
    @State private var codexPrompt = ""
    @State private var codexStarting = false
    @State private var codexStartError: String?
    @State private var showAllSessions = false
    @State private var hasAvailableProvider = false

    @AppStorage(Pref.autoCollapse) private var autoCollapse = Pref.Default.autoCollapse
    @AppStorage(Pref.autoHideWhenEmpty) private var autoHideWhenEmpty = Pref.Default.autoHideWhenEmpty
    @AppStorage(Pref.expandOnHover) private var expandOnHover = Pref.Default.expandOnHover
    @AppStorage(Pref.hoverDuration) private var hoverDuration = Pref.Default.hoverDuration
    @AppStorage(Pref.autoRevealOnComplete) private var autoRevealOnComplete = Pref.Default.autoRevealOnComplete
    @AppStorage(Pref.autoRevealDwell) private var autoRevealDwell = Pref.Default.autoRevealDwell
    @AppStorage(Pref.dismissRevealOnOutsideClick) private var dismissOnOutsideClick = Pref.Default
        .dismissRevealOnOutsideClick
    @AppStorage(Pref.disableClickToJump) private var disableClickToJump = Pref.Default.disableClickToJump
    @AppStorage(Pref.maxVisibleSessions) private var maxVisible = Pref.Default.maxVisibleSessions
    @AppStorage(Pref.pillStyle) private var pillStyle = Pref.Default.pillStyle
    @AppStorage(Pref.maxPanelWidth) private var panelWidth = Pref.Default.maxPanelWidth
    @AppStorage(Pref.maxPanelHeight) private var panelMaxHeight = Pref.Default.maxPanelHeight
    @AppStorage(Pref.managedCodexCwd) private var managedCodexCwd = Pref.Default.managedCodexCwd

    private var allAgents: [AgentSession] {
        SessionList.merged(observed: monitor.agents, managed: codexServer.agents)
    }

    private var agents: [AgentSession] {
        outcomePresentation.visible(SessionPresentationPolicy.visible(allAgents))
    }

    private var displayedAgents: [AgentSession] {
        SessionAccessPolicy.displayed(
            agents,
            maximum: maxVisible,
            showAll: showAllSessions,
            switcherActive: switcher.active
        )
    }

    private var spring: Animation? {
        reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.78)
    }
    // Opening: quick off the mark with a trace of overshoot. Hover-triggered UI
    // has to feel like it was already on its way — 0.55 read as hesitant.
    private var expandSpring: Animation? {
        reduceMotion ? nil : .spring(response: 0.46, dampingFraction: 0.80)
    }
    // Closing: quicker and fully damped, no bounce on the way out.
    private var collapseSpring: Animation? {
        reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.95)
    }
    private var hidden: Bool { autoHideWhenEmpty && agents.isEmpty && !expanded }
    /// A notch belongs to the built-in display. On an external / older display
    /// the collapsed island becomes an invisible top-center hover target rather
    /// than drawing a permanent imitation notch.
    private var externalDormant: Bool { !notch.hasNotch && !expanded }
    private var selectedAgent: AgentSession? {
        selectedSessionID.flatMap { id in allAgents.first { $0.id == id } }
    }

    var body: some View {
        VStack(spacing: 0) {
            island
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear { reportPresentationState() }
        .onDisappear {
            NotificationCenter.default.post(
                name: .islandPresentationChanged,
                object: false
            )
        }
        .onChange(of: expanded) { _, _ in reportPresentationState() }
        .task(id: expanded) {
            guard expanded else { return }
            hasAvailableProvider = SupportRegistry.shippedKinds.contains {
                !Pref.disabledKinds.contains($0) && $0.softwareAvailable
            }
        }
    }

    /// Human attention outranks background activity everywhere the island has
    /// room for only one aggregate signal.
    private var attentionStatus: AgentStatus {
        if agents.contains(where: { $0.status == .needsAttention }) { return .needsAttention }
        if agents.contains(where: { $0.status == .failed }) { return .failed }
        if agents.contains(where: { $0.status == .stalled }) { return .stalled }
        if agents.contains(where: { $0.status == .completed }) { return .completed }
        if agents.contains(where: { $0.status == .working }) { return .working }
        return .idle
    }

    private var collapsedWidth: CGFloat {
        NotchPointerGeometry.collapsedWidth(notch: notch, pillStyle: pillStyle)
    }

    private var collapsedHeight: CGFloat {
        NotchPointerGeometry.collapsedHeight(notch: notch)
    }

    private var island: some View {
        ZStack(alignment: .top) {
            if expanded {
                expandedBody
                    .frame(width: panelWidth)
                    .transition(.islandContent)
            } else {
                CollapsedContent(agents: agents, notch: notch, detailed: pillStyle == "detailed")
                    .frame(width: collapsedWidth, height: collapsedHeight)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        hoverToken += 1
                        withAnimation(expandSpring) { expanded = true }
                    }
                    .transition(.islandContent)
            }
        }
        // Content is masked by the same silhouette that's stretching behind it,
        // so it can start arriving immediately and get *revealed* by the growth
        // instead of spilling outside a box that hasn't caught up. Clipping the
        // content only; fill and border are composed afterward so they stay
        // aligned with the animated silhouette.
        .clipShape(islandShape)
        .mask(wingVisibilityMask)
        // The surface stops at the silhouette. Outer shadows/glows create a
        // gray halo over full-screen content, even with NSPanel shadows off.
        .background(islandBackground)
        .geometryGroup()
        .opacity(hidden || externalDormant ? 0 : 1)
        .allowsHitTesting(!hidden)
        .accessibilityHidden(externalDormant)
        .background(AppKitHoverTracker(onChange: handleHover))
        // Animate task arrival/reordering and aggregate status, not every
        // transcript append, elapsed label or observation timestamp.
        .animation(spring, value: agents.map(\.id))
        .animation(spring, value: attentionStatus)
        .onReceive(NotificationCenter.default.publisher(for: .agentNotificationAccepted)) { note in
            guard let event = note.object as? AgentLifecycleEvent else { return }
            if event.kind == .completed { handleCompletion(note) }
            if event.kind == .needsAttention || event.kind == .failed { handleApprovalNeeded(note) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .islandExpand)) { _ in
            guard !expanded else { return }
            withAnimation(expandSpring) { expanded = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: .islandCollapse)) { _ in
            collapseNow()
        }
        .onReceive(NotificationCenter.default.publisher(for: .islandSelect)) { note in
            guard let id = note.object as? String,
                allAgents.contains(where: { $0.id == id })
            else { return }
            selectedSessionID = id
            if !expanded {
                withAnimation(expandSpring) { expanded = true }
            }
        }
    }

    /// The visual surface and AppKit pointer router share the same three-way
    /// split. Revealing a menu-bar wing never changes the island's dimensions;
    /// it only makes that side transparent while native clicks pass through.
    private var wingVisibilityMask: some View {
        GeometryReader { proxy in
            let centerWidth = min(notch.width, proxy.size.width)
            let wingWidth = max(0, (proxy.size.width - centerWidth) / 2)
            let shouldReveal = !expanded && notch.hasNotch
            let leftOpacity = shouldReveal && notchPointer.revealedWing == .left ? 0.0 : 1.0
            let rightOpacity = shouldReveal && notchPointer.revealedWing == .right ? 0.0 : 1.0

            HStack(spacing: 0) {
                Color.white.opacity(leftOpacity).frame(width: wingWidth)
                Color.white.frame(width: centerWidth)
                Color.white.opacity(rightOpacity).frame(width: wingWidth)
            }
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.12),
                value: notchPointer.revealedWing
            )
        }
    }

    // MARK: - Hover / reveal choreography

    private func handleHover(_ hovering: Bool) {
        IslandDebugTrace.record(
            "hover", "inside=\(hovering) previous=\(mouseInside) expanded=\(expanded)")
        mouseInside = hovering
        hoverToken += 1
        let token = hoverToken
        if hovering {
            // Entering the island during an auto-reveal keeps it open.
            if autoRevealActive { endAutoReveal() }
            guard expandOnHover, !expanded else { return }
            // Brief intent delay so a cursor passing by doesn't trigger it.
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0.02, hoverDuration)) {
                guard token == hoverToken, mouseInside, !expanded else { return }
                withAnimation(expandSpring) { expanded = true }
            }
        } else if IslandCollapsePolicy.shouldCollapse(
            autoCollapse: autoCollapse,
            autoRevealActive: autoRevealActive,
            switcherActive: switcher.active,
            mouseInside: mouseInside
        ) {
            // Grace period prevents flicker at the island's edge.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                guard token == hoverToken,
                    IslandCollapsePolicy.shouldCollapse(
                        autoCollapse: autoCollapse,
                        autoRevealActive: autoRevealActive,
                        switcherActive: switcher.active,
                        mouseInside: mouseInside
                    )
                else { return }
                collapseNow()
            }
        }
    }

    private func handleCompletion(_ note: Notification) {
        // External displays reveal only through deliberate pointer / shortcut
        // interaction; task events must not recreate a persistent fake notch.
        guard notch.hasNotch, autoRevealOnComplete, !expanded else { return }
        // Only the router's accepted event reaches this path. Do not probe
        // terminal UI again or make a second sound/reveal suppression decision.
        withAnimation(expandSpring) { expanded = true }
        autoRevealActive = true
        autoRevealToken += 1
        let token = autoRevealToken
        installOutsideClickMonitor()
        DispatchQueue.main.asyncAfter(deadline: .now() + max(1, autoRevealDwell)) {
            guard token == autoRevealToken, autoRevealActive else { return }
            if !mouseInside, !switcher.active { collapseNow() } else { endAutoReveal() }
        }
    }

    /// Approvals always pull the panel forward (independent of the
    /// task-complete toggle) — unless you're already in that terminal.
    private func handleApprovalNeeded(_ note: Notification) {
        guard notch.hasNotch, !expanded else { return }
        withAnimation(expandSpring) { expanded = true }
        autoRevealActive = true
        autoRevealToken += 1
        let token = autoRevealToken
        installOutsideClickMonitor()
        DispatchQueue.main.asyncAfter(deadline: .now() + max(10, autoRevealDwell)) {
            guard token == autoRevealToken, autoRevealActive else { return }
            if !mouseInside, !switcher.active { collapseNow() } else { endAutoReveal() }
        }
    }

    private func collapseNow() {
        withAnimation(collapseSpring) {
            expanded = false
            selectedSessionID = nil
            showAllSessions = false
        }
        endAutoReveal()
    }

    private func endAutoReveal() {
        autoRevealActive = false
        if let monitor = outsideClickMonitor {
            NSEvent.removeMonitor(monitor)
            outsideClickMonitor = nil
        }
    }

    /// Clicking anywhere else (another app, the desktop) closes an auto-reveal.
    private func installOutsideClickMonitor() {
        guard dismissOnOutsideClick, outsideClickMonitor == nil else { return }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { _ in
            if autoRevealActive { collapseNow() }
        }
    }

    // MARK: - Background

    /// The silhouette, shared by the background fill and the content mask so the
    /// two can never drift apart mid-morph.
    private var islandShape: NotchShape {
        NotchShape(topRadius: expanded ? 14 : 9, bottomRadius: expanded ? 30 : 12)
    }

    private var islandBackground: some View {
        let shape = islandShape
        return
            shape
            .fill(
                LinearGradient(
                    colors: [Color(white: 0.01), Color(white: expanded ? 0.055 : 0.03)],
                    startPoint: .top, endPoint: .bottom
                )
            )
            .overlay(
                // Hairline edge highlight — reads as machined depth.
                shape.stroke(
                    LinearGradient(
                        colors: [.white.opacity(0.02), .white.opacity(expanded ? 0.14 : 0.09)],
                        startPoint: .top, endPoint: .bottom
                    ),
                    lineWidth: 1
                )
                .padding(0.5)
            )
            .mask(wingVisibilityMask)
            .compositingGroup()
            .allowsHitTesting(false)
    }

    // MARK: - Expanded content

    @ViewBuilder
    private var expandedBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            if selectedAgent != nil, let notice = operationalDiagnostics.notice { noticeBanner(notice) }
            if let agent = selectedAgent {
                SessionDetail(
                    agent: agent,
                    onBack: { withAnimation(spring) { selectedSessionID = nil } },
                    onViewed: {
                        outcomePresentation.dismiss(agent)
                        AgentNotificationRouter.shared.markHandled(sessionID: agent.id)
                    }
                )
                .id(agent.id)
            } else {
                header
                if let notice = operationalDiagnostics.notice { noticeBanner(notice) }
                if providerControlsEnabled, composingCodexTask { codexComposer }
                sessionList
            }
        }
        .padding(.top, notch.hasNotch ? notch.height + 4 : 12)
        .padding(.horizontal, 22)  // clear the top-corner flares
        .padding(.bottom, 16)
    }

    private var header: some View {
        let working = agents.filter { $0.status == .working }.count
        let stalled = agents.filter { $0.status == .stalled }.count
        let attention = agents.filter { $0.status == .needsAttention }.count
        let failed = agents.filter { $0.status == .failed }.count
        let completed = agents.filter { $0.status == .completed }.count
        return HStack(spacing: 12) {
            LoopFwdMarkView(variant: .color, placement: .islandHeader)

            HStack(spacing: 5) {
                Circle().fill(AgentStatus.working.color).frame(width: 6, height: 6)
                Text(L10n.format("%d working", working))
                    .font(.system(size: 11.5, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(working > 0 ? 0.85 : 0.4))
            }
            HStack(spacing: 5) {
                Circle().fill(AgentStatus.needsAttention.color).frame(width: 6, height: 6)
                Text(L10n.format("%d need you", attention))
                    .font(.system(size: 11.5, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(attention > 0 ? 0.85 : 0.4))
            }
            if stalled > 0 {
                HStack(spacing: 5) {
                    Circle().fill(AgentStatus.stalled.color).frame(width: 6, height: 6)
                    Text(L10n.format("%d stalled", stalled))
                        .font(.system(size: 11.5, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.85))
                }
            }
            if failed > 0 {
                HStack(spacing: 5) {
                    Circle().fill(AgentStatus.failed.color).frame(width: 6, height: 6)
                    Text(L10n.format("%d failed", failed))
                        .font(.system(size: 11.5, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.85))
                }
            }
            if completed > 0 {
                HStack(spacing: 5) {
                    Circle().fill(AgentStatus.completed.color).frame(width: 6, height: 6)
                    Text(L10n.format("%d done", completed))
                        .font(.system(size: 11.5, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.85))
                }
            }

            Spacer()

            if switcher.active {
                Text(L10n.string("↑↓ select · ⏎ jump · esc close"))
                    .font(.system(size: 9.5, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.35))
            } else {
                UsageHeaderChip()
            }

            if providerControlsEnabled {
                Button {
                    codexStartError = nil
                    withAnimation(spring) { composingCodexTask.toggle() }
                } label: {
                    Image(systemName: composingCodexTask ? "xmark.circle.fill" : "plus.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(codexServer.isAvailable ? 0.65 : 0.25))
                }
                .buttonStyle(.plain)
                .disabled(!codexServer.isAvailable)
                .help(codexServer.isAvailable ? "Start a Codex task in LoopFwd" : "Codex CLI not found")
                .accessibilityLabel(L10n.string("New Codex task"))
                .accessibilityHint(
                    codexServer.isAvailable ? "Opens the task composer" : "Codex CLI is not available"
                )
            }

            Button(action: openSettings) {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.55))
            }
            .buttonStyle(.plain)
            .help(L10n.string("Open LoopFwd Settings"))
            .accessibilityLabel(L10n.string("Open LoopFwd Settings"))

            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.48))
            }
            .buttonStyle(.plain)
            .help(L10n.string("Quit LoopFwd"))
            .accessibilityLabel(L10n.string("Quit LoopFwd"))
        }
        .padding(.horizontal, 8)
        .padding(.top, 2)
        .padding(.bottom, 2)
    }

    private var codexComposer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                AgentIconView(kind: .codex, status: .idle, size: 19)
                Text(L10n.string("New Codex task"))
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                Spacer()
                Text(L10n.string("workspace sandbox"))
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.35))
            }

            HStack(spacing: 7) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.35))
                Text((managedCodexCwd as NSString).abbreviatingWithTildeInPath)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 6)
                Button(L10n.string("Choose…"), action: chooseCodexFolder)
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
                    .disabled(codexStarting)
            }

            HStack(spacing: 8) {
                TextField(L10n.string("What should Codex do?"), text: $codexPrompt)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.white)
                    .onSubmit(startCodexTask)
                Button(action: startCodexTask) {
                    if codexStarting {
                        ProgressView().controlSize(.small).tint(.white)
                    } else {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(
                                codexPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                    ? .white.opacity(0.25) : AgentKind.codex.color)
                    }
                }
                .buttonStyle(.plain)
                .disabled(codexStarting || codexPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel(L10n.string("Start Codex task"))
            }

            if codexStarting {
                Text(L10n.string("Starting the official Codex connection…"))
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.4))
            } else if let codexStartError {
                Text(codexStartError)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(Color(red: 1.0, green: 0.45, blue: 0.45))
                    .lineLimit(2)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(.white.opacity(0.045))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(AgentKind.codex.color.opacity(0.28), lineWidth: 1)
        )
        .padding(.horizontal, 6)
        .transition(.opacity.combined(with: .offset(y: -5)))
    }

    /// Slack the scroll view's clip bounds need so a hover-scaled card and its
    /// shadow aren't shaved off at the edges. Cancelled out by an equal inset on
    /// the content, so every visible margin stays exactly where it was.
    private let cardLiftBleed: CGFloat = 6

    private var sessionList: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 7) {
                    if agents.isEmpty {
                        emptyState
                    } else {
                        ForEach(Array(displayedAgents.enumerated()), id: \.element.id) { index, agent in
                            SessionCard(
                                agent: agent,
                                selected: switcher.active && switcher.selectedSessionID == agent.id,
                                onShowDetail: {
                                    outcomePresentation.dismiss(agent)
                                    AgentNotificationRouter.shared.markHandled(sessionID: agent.id)
                                    withAnimation(spring) { selectedSessionID = agent.id }
                                },
                                onActivate: { handleCardTap(agent) }
                            )
                            .contentShape(Rectangle())
                            .onTapGesture { handleCardTap(agent) }
                            .staggeredEntrance(index: index)
                            .id(agent.id)
                        }
                        if agents.count > maxVisible, !switcher.active {
                            Button {
                                withAnimation(expandSpring) { showAllSessions.toggle() }
                            } label: {
                                HStack(spacing: 4) {
                                    Text(
                                        showAllSessions
                                            ? L10n.string("Show fewer")
                                            : L10n.format("+ %d more", agents.count - maxVisible)
                                    )
                                    Image(systemName: showAllSessions ? "chevron.up" : "chevron.down")
                                        .font(.system(size: 8, weight: .bold))
                                }
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.55))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 4)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(
                                L10n.string(showAllSessions ? "Show fewer sessions" : "Show all sessions"))
                        }
                    }
                }
                .background(HeightReader())
                .padding(.horizontal, cardLiftBleed)
                .padding(.vertical, cardLiftBleed)
            }
            .onChange(of: switcher.selectedSessionID) { _, id in
                if let id { proxy.scrollTo(id, anchor: .center) }
            }
        }
        // The measured height lands a frame after the panel starts opening, so
        // this must ride a spring too — assigning it bare snaps the panel from
        // its guessed height to its real one mid-expand.
        .onPreferenceChange(ContentHeightKey.self) { height in
            IslandDebugTrace.record("list-height", "old=\(listContentHeight) new=\(height)")
            withAnimation(expandSpring) { listContentHeight = height }
        }
        .frame(
            height: min(
                max(listContentHeight + cardLiftBleed * 2, 40),
                panelMaxHeight + cardLiftBleed * 2)
        )
        .padding(.horizontal, -cardLiftBleed)
        .padding(.vertical, -cardLiftBleed)
    }

    @State private var listContentHeight: CGFloat = 200

    private func handleCardTap(_ agent: AgentSession) {
        // Click = go to the agent's terminal (unless disabled in settings).
        // Details live behind the chevron button on the card.
        if !disableClickToJump, ReturnResolver.resolve(agent).reason == nil {
            TerminalBridge.jump(to: agent) { result in
                if !result.opened {
                    OperationalDiagnostics.shared.showReturnFailure(result, session: agent)
                }
            }
        } else {
            outcomePresentation.dismiss(agent)
            withAnimation(spring) { selectedSessionID = agent.id }
        }
    }

    private var emptyState: some View {
        let state = IslandEmptyState.resolve(
            hasDataFailure: monitor.hasDataFailure,
            hasAvailableProvider: hasAvailableProvider || !monitor.agents.isEmpty)
        return VStack(spacing: 6) {
            Image(systemName: "moon.zzz.fill")
                .font(.system(size: 22))
                .foregroundStyle(.white.opacity(0.35))
            Text(L10n.string(state.title))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))
            Text(L10n.string(state.detail))
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.4))
            Button(L10n.string(state.action)) {
                SettingsWindowController.shared.show(pane: state == .unavailable ? .diagnostics : .setup)
            }
            .buttonStyle(.plain)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(AgentKind.codex.color.opacity(0.9))
            .accessibilityHint(L10n.string("Review provider availability and supported capabilities"))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
    }

    private func openSettings() {
        SettingsWindowController.shared.show()
    }

    private func noticeBanner(_ notice: IslandNotice) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(AgentStatus.needsAttention.color)
            VStack(alignment: .leading, spacing: 2) {
                Text(notice.title)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)
                Text(notice.message)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.white.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)
                if let recovery = notice.recovery {
                    Button(L10n.string(recovery.label)) {
                        operationalDiagnostics.dismissNotice()
                        switch recovery {
                        case .refreshTasks: monitor.scanNow()
                        case .setup: SettingsWindowController.shared.show(pane: .setup)
                        case .agents: SettingsWindowController.shared.show(pane: .agents)
                        }
                    }.buttonStyle(.plain)
                        .foregroundStyle(.blue)
                        .font(.system(size: 10, weight: .semibold))
                }
            }
            Spacer(minLength: 4)
            Button {
                operationalDiagnostics.dismissNotice()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white.opacity(0.45))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.string("Dismiss message"))
        }
        .padding(9)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(AgentStatus.needsAttention.color.opacity(0.10))
        )
        .padding(.horizontal, 6)
    }

    private func reportPresentationState() {
        IslandDebugTrace.record("presentation", "expanded=\(expanded) sessions=\(agents.count)")
        NotificationCenter.default.post(
            name: .islandPresentationChanged,
            object: expanded
        )
    }

    private func chooseCodexFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose Project"
        panel.directoryURL = URL(fileURLWithPath: (managedCodexCwd as NSString).expandingTildeInPath)
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { response in
            guard response == .OK, let path = panel.url?.path else { return }
            managedCodexCwd = path
            codexStartError = nil
        }
    }

    private func startCodexTask() {
        let prompt = codexPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !codexStarting else { return }
        codexStarting = true
        codexStartError = nil
        codexServer.startTask(prompt: prompt, cwd: managedCodexCwd) { result in
            codexStarting = false
            switch result {
            case .success:
                codexPrompt = ""
                withAnimation(spring) { composingCodexTask = false }
            case .failure(let error):
                codexStartError = error.localizedDescription
            }
        }
    }
}

/// Vibe-style quota estimate in the header: "5h 34% · ⟳1h20m · 7d 61%".
private struct UsageHeaderChip: View {
    @ObservedObject private var tracker = UsageTracker.shared
    @AppStorage(Pref.usageEnabled) private var enabled = Pref.Default.usageEnabled
    @AppStorage(Pref.usagePlan) private var plan = Pref.Default.usagePlan
    @AppStorage(Pref.communityUsageEnabled) private var communityUsageEnabled = Pref.Default.communityUsageEnabled

    private var hasClaude: Bool {
        communityUsageEnabled && !tracker.snapshot.hasIncompleteData && tracker.snapshot.weekTokens > 0
    }
    private var hasCodex: Bool { tracker.codex.hasData && tracker.codex.isRecent }

    var body: some View {
        if enabled, hasClaude || hasCodex {
            HStack(spacing: 8) {
                if hasClaude { claudeSegment }
                if hasClaude, hasCodex {
                    Rectangle().fill(.white.opacity(0.12)).frame(width: 1, height: 9)
                }
                if hasCodex { codexSegment }
            }
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .help(L10n.string("Last reported usage, not a live account balance. See Usage for source and time."))
        }
    }

    /// Claude — estimated from transcripts (brand-orange dot).
    private var claudeSegment: some View {
        let budgets = UsageTracker.budgets(plan: plan)
        let snapshot = tracker.snapshot
        return HStack(spacing: 5) {
            Circle().fill(AgentKind.claude.color).frame(width: 5, height: 5)
            if let blockPercent = snapshot.blockPercent(budget: budgets.block),
                let reset = snapshot.blockResetAt
            {
                label("5h"); percent(blockPercent)
                Text("⟳\(countdown(to: reset))").foregroundStyle(.white.opacity(0.35))
            }
            if let value = snapshot.weekPercent(budget: budgets.week) {
                label("7d"); percent(value)
            }
        }
        .help(L10n.string("Estimated Claude usage — Settings → Usage"))
    }

    /// Codex — exact, from its own rate-limit reports (brand-green dot).
    private var codexSegment: some View {
        HStack(spacing: 5) {
            Circle().fill(AgentKind.codex.color).frame(width: 5, height: 5)
            if let secondary = tracker.codex.secondary, let remaining = secondary.remainingPercent {
                label(secondary.label); remainingPercent(remaining, used: secondary.usedPercent)
            }
            if let primary = tracker.codex.primary, let remaining = primary.remainingPercent {
                label(primary.label); remainingPercent(remaining, used: primary.usedPercent)
            }
        }
        .help(L10n.string("Last reported usage, not a live account balance. See Usage for source and time."))
    }

    private func label(_ text: String) -> some View {
        Text(text).foregroundStyle(.white.opacity(0.35))
    }

    private func percent(_ value: Int) -> some View {
        Text("\(min(value, 999))%").foregroundStyle(color(for: value))
    }

    private func remainingPercent(_ value: Int, used: Double) -> some View {
        Text(L10n.format("%d%% remaining", value))
            .foregroundStyle(color(for: UsageTracker.displayPercent(used) ?? 0))
    }

    private func color(for percent: Int) -> Color {
        percent >= 90
            ? Color(red: 1.0, green: 0.45, blue: 0.45)
            : percent >= 70
                ? AgentStatus.needsAttention.color
                : .white.opacity(0.6)
    }

    private func countdown(to date: Date) -> String {
        let seconds = max(0, Int(date.timeIntervalSinceNow))
        let hours = seconds / 3600, minutes = (seconds % 3600) / 60
        return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
    }
}

/// Measures the session list so the panel hugs content up to the height cap.
private struct ContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct HeightReader: View {
    var body: some View {
        GeometryReader { geo in
            Color.clear.preference(key: ContentHeightKey.self, value: geo.size.height)
        }
    }
}
