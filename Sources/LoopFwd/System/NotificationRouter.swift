import AppKit
import Foundation
import UserNotifications

enum AgentNotificationPolicy {
    static func preferenceKey(for kind: AgentLifecycleEventKind) -> String? {
        switch kind {
        case .completed: return Pref.notifyOnComplete
        case .needsAttention: return Pref.notifyOnAttention
        case .failed: return Pref.notifyOnFailure
        case .stalled: return Pref.notifyOnStalled
        case .started: return Pref.notifyOnStart
        case .resumed, .stopped: return nil
        }
    }

    static func title(for event: AgentLifecycleEvent) -> String {
        let provider = event.session.kind.displayName
        switch event.kind {
        case .started: return L10n.format("%@ started", provider)
        case .resumed: return L10n.format("%@ resumed", provider)
        case .completed: return L10n.format("%@ finished", provider)
        case .needsAttention: return L10n.format("%@ needs you", provider)
        case .failed: return L10n.format("%@ failed", provider)
        case .stopped: return L10n.format("%@ stopped", provider)
        case .stalled: return L10n.format("%@ may be stalled", provider)
        }
    }

    static func body(for event: AgentLifecycleEvent) -> String {
        let session = event.session
        let task = String((session.currentTaskSummary ?? session.displayTitle).prefix(180))
        switch event.kind {
        case .needsAttention:
            return L10n.format("Needs attention: %@", task)
        case .failed:
            return L10n.format("Failed: %@", task)
        case .stalled:
            return L10n.format("No provider-backed progress: %@", task)
        case .completed:
            return L10n.format("Completed: %@", task)
        case .started:
            return L10n.format("Started: %@", task)
        case .resumed:
            return L10n.format("Resumed: %@", task)
        case .stopped:
            return L10n.format("Stopped: %@", task)
        }
    }
}

/// One notification decision point for every provider. Lifecycle state remains
/// recorded even when a banner is disabled or suppressed because the provider
/// app is already frontmost.
/// Retained notification state is not a second transcript store. Preserve the
/// original semantic key before discarding content that banners never use.
struct AgentNotificationRecord {
    let event: AgentLifecycleEvent
    let deduplicationKey: String
    var session: AgentSession { event.session }
    var kind: AgentLifecycleEventKind { event.kind }

    init(_ original: AgentLifecycleEvent) {
        deduplicationKey = original.deduplicationKey
        let source = original.session
        var summary = AgentSession(
            id: source.id, processID: source.processID, kind: source.kind,
            cpu: 0, elapsed: "", cwd: nil, status: source.status,
            terminalApp: source.terminalApp, tty: source.tty, bypassPermissions: false)
        summary.title = String(source.displayTitle.prefix(80))
        summary.taskAnchor = source.currentTaskSummary.map { String($0.prefix(180)) }
        summary.surfaceID = source.surfaceID
        // The passive visibility probe needs only terminal coordinates.
        // Clicks resolve the live session by ID, never this retained snapshot.
        if case .terminal = source.returnTarget { summary.returnTarget = source.returnTarget }
        event = .init(kind: original.kind, session: summary, occurredAt: original.occurredAt)
    }
}

protocol AgentNotificationTransport {
    func add(_ request: UNNotificationRequest, completion: @escaping (Error?) -> Void)
    func remove(_ identifiers: [String])
}

struct SystemNotificationTransport: AgentNotificationTransport {
    private let authorization: (@escaping (UNAuthorizationStatus) -> Void) -> Void
    private let submit: (UNNotificationRequest, @escaping (Error?) -> Void) -> Void

    init(
        authorization: @escaping (@escaping (UNAuthorizationStatus) -> Void) -> Void = { completion in
            UNUserNotificationCenter.current().getNotificationSettings {
                completion($0.authorizationStatus)
            }
        },
        submit: @escaping (UNNotificationRequest, @escaping (Error?) -> Void) -> Void = { request, completion in
            UNUserNotificationCenter.current().add(request, withCompletionHandler: completion)
        }
    ) {
        self.authorization = authorization
        self.submit = submit
    }

    func add(_ request: UNNotificationRequest, completion: @escaping (Error?) -> Void) {
        // Reading settings never opens a permission prompt. A successful add
        // only means system submission, not proof that a banner was visible.
        authorization { status in
            guard status == .authorized || status == .provisional else {
                DispatchQueue.main.async { completion(PermissionError(status: status)) }
                return
            }
            submit(request) { error in
                DispatchQueue.main.async { completion(error) }
            }
        }
    }

    private struct PermissionError: LocalizedError {
        let status: UNAuthorizationStatus
        var errorDescription: String? {
            switch status {
            case .notDetermined: return L10n.string("Notification permission has not been requested")
            case .denied: return L10n.string("Notifications are blocked in System Settings")
            default: return L10n.string("Notification permission could not be confirmed")
            }
        }
    }
    func remove(_ identifiers: [String]) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }
}

final class AgentNotificationRouter {
    static let shared = AgentNotificationRouter()

    private let center: NotificationCenter
    private let defaults: UserDefaults
    private let transport: AgentNotificationTransport
    private let checkVisibility: ([AgentSession], @escaping (Set<String>) -> Void) -> Void
    private let playSound: (AgentLifecycleEventKind) -> Void
    private var observer: NSObjectProtocol?
    private var delivered = Set<String>()
    private var pending: [AgentLifecycleEventKind: [AgentNotificationRecord]] = [:]
    private var scheduledFlushes: [AgentLifecycleEventKind: DispatchWorkItem] = [:]
    private var groups: [String: [AgentNotificationRecord]] = [:]
    private var inFlight = Set<String>()
    private var accepted = Set<String>()
    private var checking: [String: (token: UUID, event: AgentNotificationRecord)] = [:]
    private var visibilityInFlight = Set<AgentLifecycleEventKind>()

    init(
        center: NotificationCenter = .default, defaults: UserDefaults = .standard,
        transport: AgentNotificationTransport? = nil,
        isViewing: ((AgentSession) -> Bool)? = nil,
        checkVisibility: (([AgentSession], @escaping (Set<String>) -> Void) -> Void)? = nil,
        playSound: @escaping (AgentLifecycleEventKind) -> Void = { SoundEngine.shared.playLifecycle($0) }
    ) {
        self.center = center
        self.defaults = defaults
        self.transport = transport ?? SystemNotificationTransport()
        if let checkVisibility {
            self.checkVisibility = checkVisibility
        } else if let isViewing {
            self.checkVisibility = { sessions, completion in
                completion(Set(sessions.filter(isViewing).map(\.id)))
            }
        } else {
            self.checkVisibility = TerminalBridge.visibleExactSessionIDs
        }
        self.playSound = playSound
    }

    deinit {
        if let observer { center.removeObserver(observer) }
        scheduledFlushes.values.forEach { $0.cancel() }
    }

    func start() {
        guard observer == nil else { return }
        observer = center.addObserver(
            forName: .agentLifecycleEvent,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let event = note.object as? AgentLifecycleEvent else { return }
            self?.route(event)
        }
    }

    func route(_ original: AgentLifecycleEvent) {
        let event = AgentNotificationRecord(original)
        guard !delivered.contains(event.deduplicationKey) else { return }
        if pending.values.joined().contains(where: { $0.deduplicationKey == event.deduplicationKey }) { return }
        if checking[event.session.id]?.event.deduplicationKey == event.deduplicationKey { return }
        if groups.contains(where: {
            inFlight.contains($0.key)
                && $0.value.contains(where: {
                    $0.deduplicationKey == event.deduplicationKey
                })
        }) {
            return
        }
        // New state supersedes queued and delivered attention, even when the
        // new event itself is silent (for example, resumed or stopped).
        markHandled(sessionID: event.session.id)
        guard let preferenceKey = AgentNotificationPolicy.preferenceKey(for: event.kind) else {
            OperationalDiagnostics.shared.recordNotification("ignored \(event.kind.rawValue): no delivery policy")
            return
        }
        guard defaults.bool(forKey: preferenceKey) else {
            OperationalDiagnostics.shared.recordNotification("disabled \(event.kind.rawValue)")
            return
        }
        guard !delivered.contains(event.deduplicationKey) else {
            OperationalDiagnostics.shared.recordNotification("deduplicated \(event.kind.rawValue)")
            return
        }

        OperationalDiagnostics.shared.recordNotification("queued \(event.kind.rawValue)")
        pending[event.kind, default: []].append(event)
        if scheduledFlushes[event.kind] == nil {
            let kind = event.kind
            let work = DispatchWorkItem { [weak self] in self?.flush(kind) }
            scheduledFlushes[kind] = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
        }

        // The first version runs for days, not months. Keep a bounded in-memory
        // dedupe window without introducing a history database.
        if delivered.count > 512 { delivered.removeAll(keepingCapacity: true) }
        if accepted.count > 512 { accepted.removeAll(keepingCapacity: true) }
    }

    func flush(_ kind: AgentLifecycleEventKind) {
        scheduledFlushes[kind]?.cancel()
        scheduledFlushes[kind] = nil
        // Keep at most one probe in flight per event kind. New bursts remain
        // in the existing per-session queue and are checked after it finishes.
        guard !visibilityInFlight.contains(kind) else { return }
        guard let events = pending.removeValue(forKey: kind), !events.isEmpty else { return }
        guard isEnabled(kind) else { return }
        let token = UUID()
        visibilityInFlight.insert(kind)
        for event in events { checking[event.session.id] = (token, event) }
        let finish: (Set<String>) -> Void = { [weak self] visibleIDs in
            guard let self else { return }
            defer {
                self.visibilityInFlight.remove(kind)
                self.flush(kind)
            }
            let current = events.filter { self.checking[$0.session.id]?.token == token }
            for event in current { self.checking[event.session.id] = nil }
            guard self.isEnabled(kind) else {
                OperationalDiagnostics.shared.recordNotification("disabled before delivery \(kind.rawValue)")
                return
            }
            let eventsToDeliver = current.filter {
                !(self.defaults.bool(forKey: Pref.smartSuppression) && visibleIDs.contains($0.session.id))
            }
            if eventsToDeliver.count < current.count {
                OperationalDiagnostics.shared.recordNotification("suppressed \(kind.rawValue): exact task visible")
            }
            self.accept(eventsToDeliver, kind: kind)
        }
        if defaults.bool(forKey: Pref.smartSuppression) {
            checkVisibility(events.map(\.session), finish)
        } else {
            finish([])
        }
    }

    private func isEnabled(_ kind: AgentLifecycleEventKind) -> Bool {
        AgentNotificationPolicy.preferenceKey(for: kind).map { defaults.bool(forKey: $0) } ?? false
    }

    private func accept(_ eventsToDeliver: [AgentNotificationRecord], kind: AgentLifecycleEventKind) {
        guard !eventsToDeliver.isEmpty else { return }
        let newlyAccepted = eventsToDeliver.filter { accepted.insert($0.deduplicationKey).inserted }
        if !newlyAccepted.isEmpty { playSound(kind) }
        for event in newlyAccepted {
            center.post(name: .agentNotificationAccepted, object: event.event)
        }
        // Preserve outstanding members when a later burst of the same kind
        // arrives; replacing the banner must not lose the earlier tasks.
        let old = groups.filter { $0.value.first?.kind == kind }
        let merged = old.values.flatMap { $0 } + eventsToDeliver
        for identifier in old.keys { groups[identifier] = nil; transport.remove([identifier]) }
        var bySession: [String: AgentNotificationRecord] = [:]
        for event in merged { bySession[event.session.id] = event }
        deliver(bySession.values.sorted { $0.session.id < $1.session.id })
    }

    private func deliver(_ events: [AgentNotificationRecord]) {
        guard let first = events.first else { return }
        let kind = first.kind

        let content = UNMutableNotificationContent()
        if events.count == 1, let event = events.first {
            content.title = AgentNotificationPolicy.title(for: event.event)
            content.body =
                defaults.bool(forKey: Pref.hideNotificationDetails)
                ? L10n.string("Open LoopFwd to view the task") : AgentNotificationPolicy.body(for: event.event)
            content.userInfo = [
                "sessionID": event.session.id,
                "provider": event.session.kind.displayName,
            ]
        } else {
            content.title = Self.aggregateTitle(kind: kind, count: events.count)
            content.body =
                defaults.bool(forKey: Pref.hideNotificationDetails)
                ? L10n.string("Open LoopFwd to view tasks")
                : events.prefix(3).map { String($0.session.displayTitle.prefix(60)) }.joined(separator: " · ")
            content.userInfo = ["openIsland": true, "sessionIDs": events.map(\.session.id)]
        }
        let identifier =
            events.count == 1
            ? Self.notificationIdentifier(sessionID: events[0].session.id)
            : "loopfwd-group-\(kind.rawValue)"
        groups[identifier] = events
        // Serialize native adds for each identifier. A late add callback can
        // otherwise resurrect a notification after removeDelivered returned.
        guard inFlight.insert(identifier).inserted else { return }
        transport.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil)) {
            [weak self] error in
            guard let self else { return }
            self.inFlight.remove(identifier)
            let current = self.groups[identifier]
            guard current?.map(\.deduplicationKey) == events.map(\.deduplicationKey) else {
                self.transport.remove([identifier])
                if let current { self.deliver(current) }
                return
            }
            if let error {
                OperationalDiagnostics.shared.recordNotification(
                    L10n.format("Notification not submitted (%@): %@", kind.rawValue, error.localizedDescription)
                )
            } else {
                self.delivered.formUnion(events.map(\.deduplicationKey))
                OperationalDiagnostics.shared.recordNotification(
                    L10n.format("Submitted to macOS (%@); banner display is not confirmed", kind.rawValue)
                )
            }
        }
    }

    func markHandled(sessionID: String) {
        checking[sessionID] = nil
        for kind in Array(pending.keys) {
            pending[kind]?.removeAll { $0.session.id == sessionID }
        }
        var identifiers = [Self.notificationIdentifier(sessionID: sessionID)]
        var replacements: [[AgentNotificationRecord]] = []
        for (identifier, events) in Array(groups) where events.contains(where: { $0.session.id == sessionID }) {
            identifiers.append(identifier)
            groups[identifier] = nil
            let remaining = events.filter { $0.session.id != sessionID }
            if !remaining.isEmpty { replacements.append(remaining) }
        }
        transport.remove(identifiers)
        for remaining in replacements { deliver(remaining) }
    }

    static func notificationIdentifier(sessionID: String) -> String {
        var value: UInt64 = 14_695_981_039_346_656_037
        for byte in sessionID.utf8 {
            value ^= UInt64(byte)
            value &*= 1_099_511_628_211
        }
        return "loopfwd-session-\(String(value, radix: 16))"
    }

    private static func aggregateTitle(kind: AgentLifecycleEventKind, count: Int) -> String {
        switch kind {
        case .needsAttention: return L10n.format("%d tasks need you", count)
        case .failed: return L10n.format("%d tasks failed", count)
        case .completed: return L10n.format("%d tasks finished", count)
        case .stalled: return L10n.format("%d tasks may be stalled", count)
        case .started: return L10n.format("%d tasks started", count)
        case .resumed: return L10n.format("%d tasks resumed", count)
        case .stopped: return L10n.format("%d tasks stopped", count)
        }
    }
}

extension Notification.Name {
    static let agentNotificationAccepted = Notification.Name("loopfwd.agentNotificationAccepted")
}

/// Clicking a notification returns to the exact session when that target is
/// still valid. A stale target opens the corresponding island detail instead
/// of activating a guessed application window.
final class AgentNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        defer { completionHandler() }
        let userInfo = response.notification.request.content.userInfo
        guard let sessionID = userInfo["sessionID"] as? String else {
            if userInfo["openIsland"] as? Bool == true {
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .islandExpand, object: nil)
                }
            }
            return
        }
        DispatchQueue.main.async {
            let sessions = SessionList.merged(
                observed: AgentMonitor.shared.agents,
                managed: CodexAppServer.shared.agents
            )
            let unavailable = {
                let provider = userInfo["provider"] as? String ?? "Agent"
                let title = userInfo["displayTitle"] as? String ?? L10n.string("Task unavailable")
                OperationalDiagnostics.shared.showNotice(
                    sessionID: sessionID,
                    title: "\(provider) · \(title)",
                    message: L10n.string("This task ended or its exact return target is no longer available.")
                )
                NotificationCenter.default.post(name: .islandExpand, object: nil)
            }
            if let session = sessions.first(where: { $0.id == sessionID }) {
                TerminalBridge.jump(to: session) { result in
                    if !result.opened { unavailable() }
                }
            } else {
                unavailable()
            }
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
