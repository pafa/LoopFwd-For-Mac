import Combine
import Foundation

/// Additive Session Hub transmitter. Disabled by default — Mac island UX unchanged.
@MainActor
final class TransmitterService: ObservableObject {
    static let shared = TransmitterService()

    @Published private(set) var isEnabled = false
    @Published private(set) var isConnected = false
    @Published private(set) var pairingCode: String = ""
    @Published private(set) var macDeviceId: String = ""
    @Published private(set) var lastError: String?
    @Published private(set) var lastPublishedCount = 0

    private let hub = HubClient()
    private var monitorCancellable: AnyCancellable?
    private var approvalCancellable: AnyCancellable?
    private var codexCancellable: AnyCancellable?
    private var publishTask: Task<Void, Never>?
    private var pendingPublish = false
    private var lastPublishAt: Date = .distantPast
    private var macToken: String = ""
    private var reconnectTask: Task<Void, Never>?

    private init() {
        hub.onActionForward = { [weak self] envelope in
            Task { @MainActor in
                await self?.handleForwardedAction(envelope)
            }
        }
        hub.onConnectionChange = { [weak self] online in
            Task { @MainActor in
                self?.isConnected = online
                if !online { self?.scheduleReconnect() }
            }
        }
        hub.onError = { [weak self] message in
            Task { @MainActor in
                self?.lastError = message
            }
        }
    }

    /// Called from AppDelegate after AgentMonitor / ApprovalCenter start.
    func startIfEnabled() {
        let defaults = UserDefaults.standard
        let enabled =
            defaults.object(forKey: Pref.transmitterEnabled) as? Bool
            ?? Pref.Default.transmitterEnabled
        guard enabled else {
            isEnabled = false
            return
        }
        Task { await enable() }
    }

    func enable() async {
        isEnabled = true
        UserDefaults.standard.set(true, forKey: Pref.transmitterEnabled)
        lastError = nil

        let base =
            UserDefaults.standard.string(forKey: Pref.transmitterHubURL)
            ?? Pref.Default.transmitterHubURL
        if let url = URL(string: base) {
            hub.updateBaseURL(url)
        }

        let displayName =
            UserDefaults.standard.string(forKey: Pref.transmitterDisplayName)
            ?? Host.current().localizedName
            ?? "Mac"
        var code =
            UserDefaults.standard.string(forKey: Pref.transmitterPairingCode)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if code.count < 4 {
            code = Self.makePairingCode()
            UserDefaults.standard.set(code, forKey: Pref.transmitterPairingCode)
        }
        pairingCode = code.uppercased()

        let existingId = UserDefaults.standard.string(forKey: Pref.transmitterMacDeviceId)
        do {
            let registration = try await hub.register(
                displayName: displayName,
                pairingCode: pairingCode,
                macDeviceId: existingId
            )
            macDeviceId = registration.macDeviceId
            macToken = registration.macToken
            pairingCode = registration.pairingCode
            UserDefaults.standard.set(macDeviceId, forKey: Pref.transmitterMacDeviceId)
            UserDefaults.standard.set(macToken, forKey: Pref.transmitterMacToken)
            UserDefaults.standard.set(pairingCode, forKey: Pref.transmitterPairingCode)
            hub.connect(macToken: macToken)
            bindPublishers()
            schedulePublish(immediate: true)
        } catch {
            lastError = error.localizedDescription
            isConnected = false
        }
    }

    func disable() {
        isEnabled = false
        UserDefaults.standard.set(false, forKey: Pref.transmitterEnabled)
        unbindPublishers()
        hub.disconnect(sendPresence: true)
        isConnected = false
    }

    // MARK: - Observation

    private func bindPublishers() {
        unbindPublishers()
        monitorCancellable = AgentMonitor.shared.$agents
            .receive(on: RunLoop.main)
            .sink { [weak self] agents in
                let needsAttention = agents.contains { $0.status == .needsAttention }
                self?.schedulePublish(immediate: needsAttention)
            }
        approvalCancellable = ApprovalCenter.shared.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.schedulePublish(immediate: true)
            }
        codexCancellable = CodexAppServer.shared.$agents
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.schedulePublish(immediate: false)
            }
        // Lifecycle / attention notifications also force a publish.
        NotificationCenter.default.addObserver(
            self, selector: #selector(attentionPing), name: .approvalNeeded, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(attentionPing), name: .agentLifecycleEvent, object: nil)
    }

    private func unbindPublishers() {
        monitorCancellable?.cancel()
        approvalCancellable?.cancel()
        codexCancellable?.cancel()
        monitorCancellable = nil
        approvalCancellable = nil
        codexCancellable = nil
        NotificationCenter.default.removeObserver(self)
        publishTask?.cancel()
        publishTask = nil
    }

    @objc private func attentionPing() {
        schedulePublish(immediate: true)
    }

    /// Coalesce to ≤2 Hz unless needsAttention (immediate).
    private func schedulePublish(immediate: Bool) {
        guard isEnabled else { return }
        pendingPublish = true
        if immediate {
            publishNow()
            return
        }
        let elapsed = Date().timeIntervalSince(lastPublishAt)
        let delay = max(0, 0.5 - elapsed)
        publishTask?.cancel()
        publishTask = Task { @MainActor in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            guard !Task.isCancelled else { return }
            self.publishNow()
        }
    }

    private func publishNow() {
        guard isEnabled else { return }
        pendingPublish = false
        lastPublishAt = Date()
        let sessions = currentProjections()
        let headline = AggregateHeadline.from(sessions: sessions, macDeviceId: macDeviceId)
        lastPublishedCount = sessions.count
        hub.sendSessionsPublish(sessions, headline: headline)
    }

    private func currentProjections() -> [SessionProjection] {
        let agents = SessionPresentationPolicy.visible(
            SessionList.merged(
                observed: AgentMonitor.shared.agents,
                managed: CodexAppServer.shared.agents
            )
        )
        return SessionProjector.project(
            agents: agents,
            macDeviceId: macDeviceId,
            macOnline: isConnected
        )
    }

    private func handleForwardedAction(_ envelope: RemoteActionEnvelope) async {
        let result = await ActionIngress.handle(
            envelope,
            macDeviceId: macDeviceId,
            macOnline: isConnected,
            project: { agent in
                SessionProjector.project(
                    agent: agent, macDeviceId: self.macDeviceId, macOnline: self.isConnected)
            }
        )
        hub.sendActionResult(result, requestId: envelope.requestId)
        // HTTPS fallback so Hub can complete pending waiters even if WS frame drops.
        if !macToken.isEmpty {
            try? await hub.postActionResult(result, token: macToken)
        }
        schedulePublish(immediate: true)
    }

    private func scheduleReconnect() {
        guard isEnabled, !macToken.isEmpty else { return }
        reconnectTask?.cancel()
        reconnectTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard self.isEnabled, !self.isConnected else { return }
            self.hub.connect(macToken: self.macToken)
            self.schedulePublish(immediate: true)
        }
    }

    static func makePairingCode() -> String {
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        var part = ""
        for _ in 0..<4 {
            let index = Int.random(in: 0..<alphabet.count)
            part.append(alphabet[index])
        }
        return "LOOP-" + part
    }
}
