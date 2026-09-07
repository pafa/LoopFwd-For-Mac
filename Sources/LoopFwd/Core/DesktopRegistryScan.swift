import Foundation
import SQLite3

/// A bounded discovery cursor and a small projection cache, not a second
/// registry. Provider databases remain authoritative, including deletions.
/// The scanner serializes reads of each surface; distinct surfaces may run
/// concurrently. Cached projections never acquire a new progress timestamp.
enum DesktopRegistryScan {
    enum Kind {
        case codex, opencode
        var table: String { self == .codex ? "threads" : "session" }
        var filter: String {
            self == .codex
                ? "archived = 0 AND thread_source = 'user' AND source = 'vscode'"
                : "parent_id IS NULL AND time_archived IS NULL"
        }
        var updated: String { self == .codex ? "updated_at_ms" : "time_updated" }
        var prefix: String { self == .codex ? "codex:" : "opencode:" }
    }

    fileprivate struct State {
        var cursor = ""
        var discoveredAll = false
        var activeOffset = 0
        var seen: Set<String> = []
        var cycleSeen: Set<String> = []
        var pending: [String] = []
        var retained: [String: AgentSession] = [:]
        var checked: [String: Date] = [:]
    }

    struct Batch {
        let ids: [String]
        fileprivate let key: String
        fileprivate let kind: Kind
        fileprivate var state: State
        fileprivate let nextCursor: String
        fileprivate let reachedEnd: Bool
        fileprivate let pageIDs: [String]

        var predicate: String {
            guard !ids.isEmpty else { return "0" }
            // These are data values, never SQL identifiers. Quote even though
            // they came from the provider's database, which is untrusted input.
            return "id IN ("
                + ids.map { "'" + $0.replacingOccurrences(of: "'", with: "''") + "'" }
                .joined(separator: ",") + ")"
        }

        var ordering: String {
            "CASE id "
                + ids.enumerated().map {
                    "WHEN '" + $0.element.replacingOccurrences(of: "'", with: "''") + "' THEN \($0.offset)"
                }.joined(separator: " ") + " ELSE \(ids.count) END"
        }

        func finish(
            _ result: ProviderReadResult, scanFinished: Bool, visitedIDs: Set<String>, now: Date = Date()
        ) -> ProviderReadResult {
            var next = state
            // A timed-out batch still made progress. Retry its unvisited tail
            // first instead of repeatedly starving it behind expensive rows.
            let checkedIDs = scanFinished ? Set(ids) : visitedIDs
            for id in checkedIDs {
                next.retained.removeValue(forKey: kind.prefix + id)
                next.checked.removeValue(forKey: kind.prefix + id)
            }
            next.seen.formUnion(checkedIDs)
            var queued: Set<String> = []
            next.pending = (state.pending + ids + pageIDs).filter {
                !checkedIDs.contains($0) && queued.insert($0).inserted
            }
            if pageIDs.allSatisfy({ next.seen.contains($0) }) {
                next.cursor = reachedEnd ? "" : nextCursor
                next.discoveredAll = next.discoveredAll || reachedEnd
                next.cycleSeen.formUnion(pageIDs)
                if reachedEnd {
                    next.seen = next.cycleSeen.union(ids)
                    next.cycleSeen = []
                }
            }
            for session in result.sessions {
                // Idle/old outcomes need no fast lane; periodic discovery will
                // find them again if a fresh task starts in the same thread.
                if session.status.isActive || session.status == .failed || session.observation.mode != .rich {
                    next.retained[session.id] = session
                    next.checked[session.id] = now
                }
            }
            let currentIDs = Set(result.sessions.map(\.id))
            var sessions = result.sessions
            for (id, retained) in next.retained where !currentIDs.contains(id) {
                var cached = retained
                if now.timeIntervalSince(next.checked[id] ?? .distantPast) > 20 {
                    cached.observation.mode = .stale
                    cached.observation.reason = "Session refresh is waiting for the next scan batch"
                }
                sessions.append(cached)
            }
            store(next, key: key)
            let combined = ProviderReadResult.observations(sessions, source: result.source)
            if !scanFinished || !next.discoveredAll || !result.successful {
                return .init(
                    outcome: sessions.isEmpty && !result.successful ? result.outcome : .partial,
                    source: result.source, sessions: sessions,
                    reason: result.reason ?? "Session discovery is continuing in the next scan batch")
            }
            return combined
        }
    }

    private static let lock = NSLock()
    private static var states: [String: State] = [:]

    static func begin(
        database: OpaquePointer, path: String, kind: Kind, pageSize: Int = 32
    ) throws -> Batch {
        let inode = (try? FileManager.default.attributesOfItem(atPath: path)[.systemFileNumber]) as? NSNumber
        let key = path + ":" + (inode?.stringValue ?? "unknown")
        lock.lock()
        var state = states[key] ?? State()
        lock.unlock()
        let size = min(128, max(1, pageSize))
        let cursor = state.cursor.replacingOccurrences(of: "'", with: "''")
        let page = try ids(
            database,
            sql: "SELECT id FROM \(kind.table) WHERE \(kind.filter) AND id > '\(cursor)' ORDER BY id LIMIT \(size + 1)")
        let recent = try ids(
            database,
            sql:
                "SELECT id FROM \(kind.table) WHERE \(kind.filter) ORDER BY \(kind.updated) DESC, id LIMIT \(min(8, size))"
        )
        if (page + recent).contains(where: { !state.seen.contains($0) }) { state.discoveredAll = false }
        let retained = state.retained.keys.sorted()
        let start = retained.isEmpty ? 0 : state.activeOffset % retained.count
        let active = (Array(retained.dropFirst(start)) + Array(retained.prefix(start))).prefix(size * 2)
        state.activeOffset = retained.isEmpty ? 0 : (start + active.count) % retained.count
        var seen: Set<String> = []
        let selected =
            (state.pending + active.map { String($0.dropFirst(kind.prefix.count)) } + recent + Array(page.prefix(size)))
            .filter { seen.insert($0).inserted }
        return Batch(
            ids: Array(selected.prefix(size * 3 + 8)), key: key, kind: kind, state: state,
            nextCursor: page.prefix(size).last ?? "", reachedEnd: page.count <= size,
            pageIDs: Array(page.prefix(size)))
    }

    private static func ids(_ database: OpaquePointer, sql: String) throws -> [String] {
        var statement: OpaquePointer?
        let prepared = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        defer { if let statement { sqlite3_finalize(statement) } }
        guard prepared == SQLITE_OK, let statement else { throw ReadError.unreadable }
        var result: [String] = []
        var code = sqlite3_step(statement)
        while code == SQLITE_ROW {
            guard let value = sqlite3_column_text(statement, 0), sqlite3_column_bytes(statement, 0) <= 256 else {
                throw ReadError.invalidIdentity
            }
            let id = String(cString: value)
            guard !id.isEmpty else { throw ReadError.invalidIdentity }
            result.append(id)
            code = sqlite3_step(statement)
        }
        guard code == SQLITE_DONE else { throw ReadError.unreadable }
        return result
    }

    private static func store(_ state: State, key: String) {
        lock.lock()
        defer { lock.unlock() }
        if states[key] == nil, states.count >= 8 { states.removeAll() }
        states[key] = state
    }

    enum ReadError: Error { case unreadable, invalidIdentity }
}

/// SQLite must interrupt its own work; an async cancellation token alone
/// cannot interrupt a synchronous query or a costly JSON expression.
final class SQLiteReadDeadline {
    private var database: OpaquePointer?
    private let end: TimeInterval
    var expired: Bool { ProcessInfo.processInfo.systemUptime >= end }

    init(database: OpaquePointer, seconds: TimeInterval = 1) {
        self.database = database
        end = ProcessInfo.processInfo.systemUptime + max(0, seconds)
        sqlite3_progress_handler(
            database, 1000,
            { pointer in
                guard let pointer else { return 1 }
                return Unmanaged<SQLiteReadDeadline>.fromOpaque(pointer).takeUnretainedValue().expired ? 1 : 0
            }, Unmanaged.passUnretained(self).toOpaque())
    }

    func invalidate() {
        if let database { sqlite3_progress_handler(database, 0, nil, nil) }
        database = nil
    }

    deinit { invalidate() }
}
