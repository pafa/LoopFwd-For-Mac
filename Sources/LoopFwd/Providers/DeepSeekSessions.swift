import Foundation

/// Read-only projection produced by the bundled DeepSeek Harness Web observer.
/// LoopFwd never reads Harness credentials, browser cookies or full transcripts.
enum DeepSeekHarnessSessions {
    static let supportedHarnessVersion = "0.1.2-alpha.5"
    static let schemaVersion = 1
    static let staleAfter: TimeInterval = 15

    struct Projection {
        let sessions: [AgentSession]
        let health: ObservationHealth

        var readResult: ProviderReadResult {
            if health.mode == .rich { return .read(sessions, source: health.source) }
            return .init(
                outcome: health.mode == .incompatible ? .incompatible : .failed,
                source: health.source, sessions: sessions, reason: health.reason)
        }
    }

    private struct Snapshot: Decodable {
        let schemaVersion: Int
        let harnessVersion: String
        let generatedAt: FlexibleDate
        let sourceReadAt: FlexibleDate?
        let readError: String?
        let loopbackURL: String
        let sessions: [Session]
    }

    private struct Session: Decodable {
        let sessionId: String
        let cwd: String?
        let title: String?
        let running: Bool
        let updatedAt: FlexibleDate
        let lastPrompt: String?
        let lastMessage: String?
        let model: String?
    }

    private struct FlexibleDate: Decodable {
        let value: Date

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let number = try? container.decode(Double.self) {
                value = Date(timeIntervalSince1970: number > 10_000_000_000 ? number / 1000 : number)
                return
            }
            let string = try container.decode(String.self)
            // JavaScript Date.toISOString() includes milliseconds. Accept the
            // real observer's wire format as well as legacy whole-second dates.
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            guard let date = fractional.date(from: string) ?? ISO8601DateFormatter().date(from: string) else {
                throw DecodingError.dataCorruptedError(
                    in: container, debugDescription: "Expected ISO-8601 or Unix timestamp")
            }
            value = date
        }
    }

    static var snapshotPath: String {
        let environment = ProcessInfo.processInfo.environment
        let root =
            environment["DSH_HOME"].flatMap { $0.isEmpty ? nil : $0 }
            ?? NSHomeDirectory() + "/.dsh"
        return (root as NSString).standardizingPath + "/integrations/loopfwd/web.json"
    }

    static func read(
        path: String = snapshotPath, processID: Int32? = nil,
        now: Date = Date()
    ) -> Projection {
        let source = "DeepSeek Harness observer"
        guard let handle = FileHandle(forReadingAtPath: path) else {
            return Projection(
                sessions: [],
                health: .processOnly(
                    source, reason: "Observer snapshot not found; enable it in Settings"
                ))
        }
        defer { try? handle.close() }
        let maximumBytes = 4 * 1024 * 1024
        guard let data = try? handle.read(upToCount: maximumBytes + 1), data.count <= maximumBytes else {
            return Projection(
                sessions: [],
                health: .init(
                    mode: .incompatible, updatedAt: now, source: source,
                    reason: "Observer snapshot exceeds the read budget", authority: .versionedObserver))
        }

        let snapshot: Snapshot
        do {
            snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
        } catch {
            return Projection(
                sessions: [],
                health: .init(
                    mode: .incompatible, updatedAt: now, source: source,
                    reason: "Observer snapshot is unreadable",
                    authority: .versionedObserver
                ))
        }

        guard snapshot.schemaVersion == schemaVersion else {
            return Projection(
                sessions: [],
                health: .init(
                    mode: .incompatible, updatedAt: snapshot.generatedAt.value, source: source,
                    reason: "Snapshot schema \(snapshot.schemaVersion) is not supported",
                    authority: .versionedObserver
                ))
        }
        let validDate: (Date) -> Bool = {
            $0.timeIntervalSince1970.isFinite && $0.timeIntervalSince1970 >= 0
                && $0 <= now.addingTimeInterval(30)
        }
        guard validDate(snapshot.generatedAt.value), snapshot.sourceReadAt.map({ validDate($0.value) }) ?? true,
            snapshot.sessions.count <= 512,
            snapshot.sessions.allSatisfy({
                validDate($0.updatedAt.value) && !$0.sessionId.isEmpty && $0.sessionId.utf8.count <= 256
            }),
            Set(snapshot.sessions.map(\.sessionId)).count == snapshot.sessions.count
        else {
            return Projection(
                sessions: [],
                health: .init(
                    mode: .incompatible, updatedAt: now,
                    source: source, reason: "Invalid snapshot time, session identity, or session count",
                    authority: .versionedObserver))
        }
        guard snapshot.harnessVersion == supportedHarnessVersion else {
            return Projection(
                sessions: [],
                health: .init(
                    mode: .incompatible, updatedAt: snapshot.generatedAt.value, source: source,
                    reason: "Harness \(snapshot.harnessVersion) is not the supported \(supportedHarnessVersion)",
                    authority: .versionedObserver
                ))
        }
        guard let loopbackURL = safeLoopbackURL(snapshot.loopbackURL) else {
            return Projection(
                sessions: [],
                health: .init(
                    mode: .incompatible, updatedAt: snapshot.generatedAt.value, source: source,
                    reason: "Observer supplied a non-loopback URL",
                    authority: .versionedObserver
                ))
        }

        // File heartbeats are not successful reads, nor session progress.
        // Legacy snapshots have no read-health contract: use their data age.
        let sourceReadAt =
            snapshot.sourceReadAt?.value
            ?? snapshot.sessions.map(\.updatedAt.value).max() ?? .distantPast
        let generatedAge = max(0, now.timeIntervalSince(min(sourceReadAt, snapshot.generatedAt.value)))
        let mode: ObservationMode = generatedAge > staleAfter || snapshot.readError != nil ? .stale : .rich
        let reason = mode == .stale ? "Observer source data is unavailable or out of date" : nil
        let health = ObservationHealth(
            mode: mode,
            updatedAt: sourceReadAt,
            source: source,
            reason: reason,
            authority: .versionedObserver
        )
        if mode == .stale,
            !SessionVisibility.keepsStaleObservation(
                updatedAt: sourceReadAt,
                providerIsRunning: false,
                gracePeriod: IntegrationProfiles.profile(for: .deepSeekWeb, kind: .deepseek)
                    .reconciliationGrace,
                now: now
            )
        {
            return Projection(sessions: [], health: health)
        }

        let sessions = snapshot.sessions
            .filter { !$0.sessionId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { item -> AgentSession in
                let age = max(0, now.timeIntervalSince(item.updatedAt.value))
                let status: AgentStatus
                if item.running {
                    status = .working
                } else {
                    status = .idle
                }
                return AgentSession(
                    id: "dsh:\(item.sessionId)",
                    processID: processID,
                    kind: .deepseek,
                    cpu: item.running ? 1 : 0,
                    elapsed: age < 60 ? "<1m" : "\(Int(age / 60))m",
                    cwd: bounded(item.cwd, limit: 1024),
                    status: status,
                    terminalApp: nil,
                    tty: nil,
                    bypassPermissions: false,
                    returnTarget: .web(loopbackURL),
                    observation: .init(
                        mode: health.mode, updatedAt: item.updatedAt.value,
                        source: health.source, reason: health.reason, authority: health.authority),
                    title: bounded(item.title, limit: 96),
                    lastPrompt: bounded(item.lastPrompt, limit: 512),
                    lastMessage: bounded(item.lastMessage, limit: 512),
                    activity: item.running ? "Running in DeepSeek Harness" : nil,
                    model: bounded(item.model, limit: 96),
                    surfaceID: .deepSeekWeb
                )
            }
        return Projection(sessions: sessions, health: health)
    }

    static func safeLoopbackURL(_ value: String) -> URL? {
        guard let url = URL(string: value),
            let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
            let host = url.host?.lowercased(),
            ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host),
            url.user == nil, url.password == nil,
            url.port.map({ (1...65535).contains($0) }) ?? true
        else { return nil }
        return url
    }

    private static func bounded(_ value: String?, limit: Int) -> String? {
        guard let value else { return nil }
        let compact = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !compact.isEmpty else { return nil }
        return compact.count > limit ? String(compact.prefix(limit)) : compact
    }
}
