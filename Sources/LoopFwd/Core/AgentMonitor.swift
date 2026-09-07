import Darwin
import Foundation
import Combine

struct ProviderScanDiagnostic: Equatable {
    var lastAttemptAt: Date
    var lastSuccessfulAt: Date?
    var duration: TimeInterval
    var outcome: String
    var source: String
    var errorCategory: String?
    var cacheHits: Int
}

/// Polls the process table and Claude Code's session registry, publishing
/// the list of recognized coding agent sessions.
final class AgentMonitor: ObservableObject {
    static let shared = AgentMonitor()

    @Published private(set) var agents: [AgentSession] = []
    private(set) var lastSuccessfulScanAt: Date?
    private(set) var lastScanDuration: TimeInterval = 0
    private(set) var providerDiagnostics: [AgentKind: ProviderScanDiagnostic] = [:]
    private(set) var surfaceDiagnostics: [IntegrationSurfaceID: ProviderScanDiagnostic] = [:]
    private(set) var lastScanError: String?
    @Published private(set) var hasDataFailure = false

    /// The always-visible island observes task changes, not changing scan
    /// timestamps/durations. Only the open Diagnostics page subscribes here.
    final class DiagnosticsUpdates: ObservableObject {
        let objectWillChange = ObservableObjectPublisher()
    }
    let diagnosticsUpdates = DiagnosticsUpdates()

    private var timer: Timer?
    private var currentInterval: TimeInterval = 0
    private var hasScannedOnce = false
    private let lifecycle = AgentLifecycleReducer()
    private let scanRequests = ScanRequestCoalescer()

    func start() {
        scanNow()
        reschedule()
    }

    private func reschedule() {
        let domain = Bundle.main.bundleIdentifier.flatMap {
            UserDefaults.standard.persistentDomain(forName: $0)
        }
        let explicitInterval = (domain?[Pref.pollInterval] as? NSNumber)?.doubleValue
        let interval = PollSchedule.interval(
            hasActiveTasks: agents.contains { $0.status.isActive && $0.observation.mode == .rich },
            explicitInterval: explicitInterval)
        guard interval != currentInterval else { return }
        currentInterval = interval
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.scanNow()
            self?.reschedule()
        }
    }

    func scanNow() {
        guard scanRequests.request() else { return }

        Task { @MainActor [weak self] in
            let startedAt = Date()
            let result = await Task.detached(priority: .utility) {
                await AgentScanner.findAgents()
            }.value
            guard let self else { return }
            let completedAt = Date()
            self.applyScanDiagnostics(result, startedAt: startedAt, completedAt: completedAt)
            if !Pref.disabledKinds.contains(.codex),
                result.codexUsageConfiguration == UserDefaults.standard.string(forKey: Pref.codexDesktopDataDirectory)
            {
                UsageTracker.shared.updateCodexSource(result.codexUsageSource)
            } else {
                UsageTracker.shared.invalidateCodexSource()
            }
            self.reschedule()

            // Record that a scan completed *before* the unchanged-list
            // early-return, so launching with zero agents still counts as
            // the first scan — otherwise the first agent to appear later
            // would be mistaken for "already running" and never post
            // .agentStarted / its start sound.
            let firstScan = !self.hasScannedOnce
            self.hasScannedOnce = true
            let reduction = self.lifecycle.reduce(
                ApprovalCenter.shared.projectLiveRequests(result.sessions),
                suppressEvents: firstScan
            )
            guard self.agents != reduction.sessions || !reduction.events.isEmpty else {
                self.finishScan()
                return
            }
            self.agents = reduction.sessions
            let managedCodexIDs = Set(CodexAppServer.shared.agents.map(\.id))
            AgentLifecycleEventEmitter.emit(
                reduction.events.filter {
                    !managedCodexIDs.contains($0.session.id) || $0.kind == .stalled
                }
            )
            self.finishScan()
        }
    }

    func applyScanDiagnostics(_ result: AgentScanResult, startedAt: Date, completedAt: Date) {
        diagnosticsUpdates.objectWillChange.send()
        lastScanError = result.processScanSucceeded ? nil : "Process scan failed or exceeded its budget"
        if result.processScanSucceeded {
            lastSuccessfulScanAt = completedAt
            surfaceDiagnostics = surfaceDiagnostics.filter { result.readerResults[$0.key] != nil }
        }
        for (surface, read) in result.readerResults {
            surfaceDiagnostics[surface] = .init(
                lastAttemptAt: completedAt,
                lastSuccessfulAt: read.successful ? completedAt : surfaceDiagnostics[surface]?.lastSuccessfulAt,
                duration: result.surfaceDurations[surface] ?? 0,
                outcome: read.outcome.rawValue, source: read.source,
                errorCategory: read.successful ? nil : read.reason, cacheHits: 0)
        }
        lastScanDuration = max(0, completedAt.timeIntervalSince(startedAt))
        updateProviderDiagnostics(
            sessions: result.sessions, durations: result.providerDurations,
            cacheHits: result.providerCacheHits, reads: result.readerResults, completedAt: completedAt)
        let failed = lastScanError != nil || surfaceDiagnostics.values.contains { $0.errorCategory != nil }
        if hasDataFailure != failed { hasDataFailure = failed }
    }

    /// Coalesce any number of refresh requests into one current scan and one
    /// follow-up. This prevents timer, wake, display and manual refresh events
    /// from building an unbounded queue.
    private func finishScan() {
        reschedule()
        if scanRequests.finish() { scanNow() }
    }

    private func updateProviderDiagnostics(
        sessions: [AgentSession],
        durations: [AgentKind: TimeInterval],
        cacheHits: [AgentKind: Int],
        reads: [IntegrationSurfaceID: ProviderReadResult],
        completedAt: Date
    ) {
        for kind in SupportRegistry.shippedKinds {
            let sourceReads = reads.filter { $0.key.providerKind == kind }
                .sorted { $0.key.rawValue < $1.key.rawValue }.map(\.value)
            if let first = sourceReads.first {
                let merged = sourceReads.dropFirst().reduce(first) { $0.merging($1) }
                providerDiagnostics[kind] = .init(
                    lastAttemptAt: completedAt,
                    lastSuccessfulAt: merged.successful ? completedAt : providerDiagnostics[kind]?.lastSuccessfulAt,
                    duration: durations[kind] ?? 0, outcome: merged.outcome.rawValue,
                    source: Set(sourceReads.map(\.source)).sorted().joined(separator: ", "),
                    errorCategory: merged.successful ? nil : merged.reason ?? "Scan incomplete",
                    cacheHits: cacheHits[kind] ?? 0)
                continue
            }
            let providerSessions = sessions.filter { $0.kind == kind }
            let rich = providerSessions.filter { $0.observation.mode == .rich }
            let outcome: String
            if !rich.isEmpty {
                outcome = "rich"
            } else if let first = providerSessions.first {
                outcome = first.observation.mode.rawValue
            } else {
                outcome = "no active session"
            }
            let previousSuccess = providerDiagnostics[kind]?.lastSuccessfulAt
            let source = Set(providerSessions.map(\.observation.source)).sorted()
                .joined(separator: ", ")
            let errorCategory = providerSessions.first(where: {
                $0.observation.mode != .rich
            }).map { session in
                switch session.observation.mode {
                case .processOnly: return "reader unavailable"
                case .stale: return "stale"
                case .incompatible: return "incompatible"
                case .rich: return "none"
                }
            }
            providerDiagnostics[kind] = ProviderScanDiagnostic(
                lastAttemptAt: completedAt,
                lastSuccessfulAt: rich.isEmpty ? previousSuccess : completedAt,
                duration: durations[kind] ?? 0,
                outcome: outcome,
                source: source.isEmpty ? "No active source" : source,
                errorCategory: errorCategory,
                cacheHits: cacheHits[kind] ?? 0
            )
        }
    }
}

enum PollSchedule {
    static func interval(hasActiveTasks: Bool, explicitInterval: Double?) -> TimeInterval {
        if let explicitInterval, explicitInterval.isFinite, explicitInterval > 0 { return max(1, explicitInterval) }
        return hasActiveTasks ? 2 : 8
    }
}

/// Thread-safe two-slot scan gate: one request may run and every burst behind
/// it collapses into exactly one follow-up request.
final class ScanRequestCoalescer {
    private let lock = NSLock()
    private var running = false
    private var pending = false

    func request() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if running {
            pending = true
            return false
        }
        running = true
        return true
    }

    func finish() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let shouldRepeat = pending
        pending = false
        running = false
        return shouldRepeat
    }
}
