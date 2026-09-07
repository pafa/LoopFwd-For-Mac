import Foundation
import SQLite3

/// Read-only projection of top-level tasks owned by Codex Desktop.
///
/// Desktop tasks do not have a TTY, so the process-only scanner cannot attach
/// them to a terminal process. Codex's local thread registry provides the
/// exact rollout path; the rollout itself remains the status/context source.
/// This reader never starts app-server and never exposes provider controls.
enum CodexDesktopSessions {
    private static let recentWindow: TimeInterval = 30 * 60

    static func sessions() -> [AgentSession] {
        read().sessions
    }

    static func read(databasePath suppliedPath: String? = nil, pageSize: Int = 32) -> ProviderReadResult {
        let source = "Codex Desktop registry"
        let root = ProcessInfo.processInfo.environment["CODEX_HOME"] ?? NSHomeDirectory() + "/.codex"
        let databasePath = suppliedPath ?? root + "/state_5.sqlite"
        guard FileManager.default.fileExists(atPath: databasePath) else {
            return .failed(source, reason: "Session registry is not available")
        }

        var database: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(databasePath, &database, flags, nil) == SQLITE_OK,
            let database
        else {
            if let database { sqlite3_close(database) }
            return .failed(source, reason: "Session registry could not be opened")
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 100)
        let deadline = SQLiteReadDeadline(database: database)
        defer { deadline.invalidate() }
        guard
            sqlite3_exec(
                database,
                "SELECT id, rollout_path, cwd, name, title, model, created_at_ms FROM threads WHERE archived=0 AND thread_source='user' AND source='vscode' LIMIT 0",
                nil, nil, nil) == SQLITE_OK
        else { return .failed(source, reason: "Unsupported or unreadable registry schema", incompatible: true) }
        let batch: DesktopRegistryScan.Batch
        do {
            batch = try DesktopRegistryScan.begin(
                database: database, path: databasePath, kind: .codex, pageSize: pageSize)
        } catch { return .failed(source, reason: "Registry discovery could not finish") }

        let sql = """
            SELECT id, rollout_path, substr(cwd,1,8192), substr(name,1,512), substr(title,1,512), substr(model,1,256), created_at_ms
            FROM threads
            WHERE archived = 0
              AND thread_source = 'user'
              AND source = 'vscode'
              AND \(batch.predicate)
            ORDER BY \(batch.ids.isEmpty ? "id" : batch.ordering)
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
            let statement
        else { return .failed(source, reason: "Unsupported or unreadable registry schema", incompatible: true) }
        defer { sqlite3_finalize(statement) }

        var result: [AgentSession] = []
        var rowFailure: String?
        var visitedIDs: Set<String> = []
        while !deadline.expired && sqlite3_step(statement) == SQLITE_ROW {
            guard let threadID = text(statement, column: 0),
                !threadID.isEmpty, threadID.utf8.count <= 256
            else {
                rowFailure = "Registry contains an invalid session identity"
                continue
            }
            defer { visitedIDs.insert(threadID) }
            let rolloutPath = text(statement, column: 1)
            let metadata = rolloutPath.flatMap { CodexSessions.metadata(path: $0) }
            let metadataID = metadata?["id"] as? String
            let mismatch = metadataID != nil && metadataID != threadID
            guard let rolloutPath, let metadata, !mismatch,
                metadataID == threadID,
                let originator = metadata["originator"] as? String
            else {
                let reason =
                    mismatch
                    ? "Registry identity does not match its rollout"
                    : "Rollout metadata could not be read or verified"
                rowFailure = reason
                result.append(unreadableSession(statement, threadID: threadID, reason: reason))
                continue
            }
            // VS Code extension records may share the registry source. They
            // are intentionally excluded, not confused with Desktop tasks.
            guard originator == "Codex Desktop" else { continue }

            let attributes = try? FileManager.default.attributesOfItem(atPath: rolloutPath)
            let modified = attributes?[.modificationDate] as? Date
            let age = modified.map { Date().timeIntervalSince($0) } ?? .infinity
            let info = CodexSessions.tailInfo(path: rolloutPath)
            guard !info.readSucceeded || info.phase == .working || (age >= 0 && age < recentWindow) else { continue }
            let status: AgentStatus
            var observation: ObservationHealth
            switch info.phase {
            case .working:
                status = .working
                observation = .rich("Codex Desktop rollout", updatedAt: modified ?? Date())
            case .completed:
                status = .completed
                observation = .rich("Codex Desktop rollout", updatedAt: modified ?? Date())
            case .failed:
                status = .failed
                observation = .rich("Codex Desktop rollout", updatedAt: modified ?? Date())
            case .stopped:
                status = .stopped
                observation = .rich("Codex Desktop rollout", updatedAt: modified ?? Date())
            case .unknown:
                // Unknown data must fail visibly instead of claiming the task
                // completed or needs the user while it may still be running.
                status = .idle
                observation = .init(
                    mode: .stale,
                    updatedAt: modified ?? Date(),
                    source: "Codex Desktop rollout",
                    reason: "No current Codex task boundary could be confirmed"
                )
            }

            if !info.readSucceeded {
                observation = .init(
                    mode: .stale, updatedAt: info.lastSuccessfulReadAt ?? .distantPast,
                    source: "Codex Desktop rollout", reason: info.readIssue ?? "Rollout could not be read or parsed")
            }

            let cwd = text(statement, column: 2)
            let createdAtMilliseconds = sqlite3_column_int64(statement, 6)
            let createdAt =
                createdAtMilliseconds > 0
                ? Date(timeIntervalSince1970: Double(createdAtMilliseconds) / 1000)
                : modified ?? Date()

            result.append(
                AgentSession(
                    id: "codex:\(threadID)",
                    kind: .codex,
                    cpu: status == .working ? 1 : 0,
                    elapsed: elapsed(since: createdAt),
                    cwd: cwd,
                    status: status,
                    terminalApp: "Codex",
                    tty: nil,
                    bypassPermissions: false,
                    returnTarget: CodexDeepLink.returnTarget(threadID: threadID),
                    observation: observation,
                    todos: info.todos,
                    title: displayTitle(
                        name: text(statement, column: 3),
                        legacyTitle: text(statement, column: 4),
                        cwd: cwd
                    ),
                    lastPrompt: info.lastPrompt,
                    lastMessage: info.lastMessage,
                    activity: status == .working ? info.activity ?? "Thinking…" : nil,
                    transcriptPath: rolloutPath,
                    model: info.model ?? text(statement, column: 5),
                    turnID: info.turnID,
                    surfaceID: .codexDesktop
                ))
        }
        let code = sqlite3_errcode(database)
        guard !deadline.expired, code == SQLITE_OK || code == SQLITE_DONE else {
            return batch.finish(
                .init(outcome: .partial, source: source, sessions: result, reason: "Registry scan did not finish"),
                scanFinished: false, visitedIDs: visitedIDs)
        }
        if let rowFailure {
            return batch.finish(
                .init(
                    outcome: result.contains { $0.observation.mode == .rich } ? .partial : .failed,
                    source: source, sessions: result, reason: rowFailure), scanFinished: true, visitedIDs: visitedIDs)
        }
        return batch.finish(.observations(result, source: source), scanFinished: true, visitedIDs: visitedIDs)
    }

    /// Preserve the registry identity for reconciliation, but never infer a
    /// task state or expose a return target from an unverified association.
    private static func unreadableSession(
        _ row: OpaquePointer, threadID: String, reason: String
    ) -> AgentSession {
        let cwd = text(row, column: 2)
        return AgentSession(
            id: "codex:\(threadID)", kind: .codex, cpu: 0, elapsed: "", cwd: cwd,
            status: .idle, terminalApp: "Codex", tty: nil, bypassPermissions: false,
            returnTarget: .unavailable(reason: reason),
            observation: .init(
                mode: .stale, updatedAt: .distantPast, source: "Codex Desktop rollout", reason: reason),
            title: displayTitle(name: text(row, column: 3), legacyTitle: nil, cwd: cwd),
            surfaceID: .codexDesktop)
    }

    private static func text(_ statement: OpaquePointer, column: Int32) -> String? {
        guard let value = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: value)
    }

    /// Codex keeps both `name` (the concise, current conversation name) and
    /// `title` (historically the first user message). The old reader used
    /// `title`, producing cards made from long, stale prompts. Prefer `name`;
    /// older unnamed tasks fall back to their project folder, not prompt text.
    private static func displayTitle(name: String?, legacyTitle: String?, cwd: String?) -> String {
        if let name = compact(name), !name.isEmpty { return clipped(name) }
        if let cwd {
            let folder = (cwd as NSString).lastPathComponent
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if folder.count > 1 { return clipped(folder) }
        }
        if let legacy = compact(legacyTitle), legacy.count <= 56,
            !legacy.contains("http://"), !legacy.contains("https://")
        {
            return legacy
        }
        return "Codex task"
    }

    private static func compact(_ value: String?) -> String? {
        guard let value else { return nil }
        let compacted =
            value
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        return compacted.isEmpty ? nil : compacted
    }

    private static func clipped(_ value: String) -> String {
        value.count > 56 ? String(value.prefix(55)) + "…" : value
    }

    private static func elapsed(since date: Date) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince(date)))
        if seconds >= 3600 { return "\(seconds / 3600)h \((seconds % 3600) / 60)m" }
        if seconds >= 60 { return "\(seconds / 60)m" }
        return "<1m"
    }
}
