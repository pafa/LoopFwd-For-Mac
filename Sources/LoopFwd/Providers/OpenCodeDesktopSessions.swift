import Foundation
import SQLite3

/// Read-only observation of sessions owned by OpenCode Desktop.
///
/// OpenCode Desktop v1.18.26 protects its loopback sidecar with a random Basic
/// Auth password that is private to the Electron process. The provider's SQLite
/// store still records session/message/part/todo state. We use that store only
/// for display and app activation; reply and approval controls remain disabled.
enum OpenCodeDesktopSessions {
    private static var databasePath: String {
        (ProcessInfo.processInfo.environment["XDG_DATA_HOME"] ?? NSHomeDirectory() + "/.local/share")
            + "/opencode/opencode.db"
    }
    private static let attentionWindow: TimeInterval = 30 * 60
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    static func sessions(hideIdleAfterMinutes: Int) -> [AgentSession] {
        read(hideIdleAfterMinutes: hideIdleAfterMinutes).sessions
    }

    static func read(hideIdleAfterMinutes: Int, databasePath suppliedPath: String? = nil, pageSize: Int = 32)
        -> ProviderReadResult
    {
        let source = "OpenCode Desktop database"
        guard let database = openDatabase(path: suppliedPath) else {
            return .failed(source, reason: "OpenCode database is missing or unreadable")
        }
        defer { sqlite3_close(database) }
        let deadline = SQLiteReadDeadline(database: database)
        defer { deadline.invalidate() }
        for schema in [
            "SELECT id, directory, title, model, time_created, time_updated FROM session WHERE parent_id IS NULL AND time_archived IS NULL LIMIT 0",
            "SELECT id, session_id, data FROM message LIMIT 0",
            "SELECT message_id, session_id, data, time_updated, time_created FROM part LIMIT 0",
            "SELECT session_id, content, status, position FROM todo LIMIT 0",
        ] {
            guard sqlite3_exec(database, schema, nil, nil, nil) == SQLITE_OK else {
                return .failed(source, reason: "Unsupported message, part, or todo schema", incompatible: true)
            }
        }

        let batch: DesktopRegistryScan.Batch
        do {
            batch = try DesktopRegistryScan.begin(
                database: database, path: suppliedPath ?? databasePath, kind: .opencode, pageSize: pageSize)
        } catch { return .failed(source, reason: "Database discovery could not finish") }

        let sql = """
            SELECT id, substr(directory,1,8192), substr(title,1,512), substr(model,1,1024), time_created, time_updated
            FROM session
            WHERE parent_id IS NULL AND time_archived IS NULL
              AND \(batch.predicate)
            ORDER BY \(batch.ids.isEmpty ? "id" : batch.ordering)
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
            let statement
        else { return .failed(source, reason: "Unsupported session schema", incompatible: true) }
        defer { sqlite3_finalize(statement) }

        var result: [AgentSession] = []
        var invalidRows = false
        var visitedIDs: Set<String> = []
        let nowMilliseconds = Date().timeIntervalSince1970 * 1000
        while !deadline.expired && sqlite3_step(statement) == SQLITE_ROW {
            guard let sessionID = text(statement, column: 0),
                let directory = text(statement, column: 1),
                let title = text(statement, column: 2)
            else { invalidRows = true; continue }

            defer { visitedIDs.insert(sessionID) }
            let created = Double(sqlite3_column_int64(statement, 4))
            let updated = Double(sqlite3_column_int64(statement, 5))
            let age = max(0, (nowMilliseconds - updated) / 1000)
            let failures = ReadFailures()
            let user = latestMessage(database, sessionID: sessionID, role: "user", failures: failures)
            let assistant = latestMessage(database, sessionID: sessionID, role: "assistant", failures: failures)
            let tool = latestActiveTool(database, sessionID: sessionID, failures: failures)

            let userCreated = messageTime(user, key: "created") ?? 0
            let assistantCreated = messageTime(assistant, key: "created") ?? 0
            let assistantCompleted = messageTime(assistant, key: "completed") != nil
            let assistantError = errorMessage(assistant)

            let status = status(
                toolStatus: tool?.status,
                hasAssistantError: assistantError != nil,
                age: age,
                userCreated: userCreated,
                assistantCreated: assistantCreated,
                assistantCompleted: assistantCompleted,
                hasAssistant: assistant != nil,
                hasUser: user != nil
            )

            if !failures.failed, hideIdleAfterMinutes > 0, status == .idle,
                age > Double(hideIdleAfterMinutes) * 60
            {
                continue
            }

            let rawModel = text(statement, column: 3)
            let model = modelID(rawModel) ?? assistant?["modelID"] as? String
            let resultMessage = assistantError
            let taskTodos = todos(database, sessionID: sessionID, failures: failures)
            let prompt = latestText(database, sessionID: sessionID, role: "user", failures: failures)
            let message = latestText(database, sessionID: sessionID, role: "assistant", failures: failures)
            let observation: ObservationHealth =
                failures.failed
                ? .init(
                    mode: .stale, updatedAt: .distantPast, source: source,
                    reason: "Session message, tool or todo data could not be read")
                : .rich(source, updatedAt: Date(timeIntervalSince1970: updated / 1000))

            result.append(
                AgentSession(
                    id: "opencode:\(sessionID)",
                    kind: .opencode,
                    cpu: status == .working ? 1 : 0,
                    elapsed: elapsed(sinceMilliseconds: created),
                    cwd: directory,
                    status: status,
                    terminalApp: "OpenCode",
                    tty: nil,
                    bypassPermissions: false,
                    returnTarget: .application(bundleIdentifier: "ai.opencode.desktop", name: "OpenCode"),
                    observation: observation,
                    todos: taskTodos,
                    title: title,
                    lastPrompt: prompt,
                    lastMessage: resultMessage ?? message,
                    activity: status == .working
                        ? tool.map {
                            $0.status == "pending" ? "Preparing \($0.name)" : "Running \($0.name)"
                        } ?? "Thinking…"
                        : nil,
                    model: model,
                    openCodeDesktopSessionID: sessionID,
                    surfaceID: .openCodeDesktop
                ))
        }
        guard !deadline.expired, sqlite3_errcode(database) == SQLITE_DONE || sqlite3_errcode(database) == SQLITE_OK
        else {
            return batch.finish(
                .init(outcome: .partial, source: source, sessions: result, reason: "Database scan did not finish"),
                scanFinished: false, visitedIDs: visitedIDs)
        }
        if invalidRows {
            return batch.finish(
                .init(
                    outcome: .partial, source: source, sessions: result, reason: "Some session records were invalid"),
                scanFinished: true, visitedIDs: visitedIDs)
        }
        return batch.finish(.observations(result, source: source), scanFinished: true, visitedIDs: visitedIDs)
    }

    static func status(
        toolStatus: String?,
        hasAssistantError: Bool,
        age: TimeInterval,
        userCreated: Double,
        assistantCreated: Double,
        assistantCompleted: Bool,
        hasAssistant: Bool,
        hasUser: Bool
    ) -> AgentStatus {
        // The Desktop database cannot distinguish an internal queued tool from
        // a live user permission request. Without its authenticated sidecar,
        // pending means work in progress — never "Needs attention" or approval.
        if toolStatus == "pending" { return .working }
        if hasAssistantError { return .failed }
        if toolStatus == "running" { return .working }
        if userCreated > assistantCreated { return .working }
        if hasAssistant, !assistantCompleted { return .working }
        // A completed assistant message can be an intermediate tool turn.
        if hasAssistant { return .idle }
        if hasUser { return .working }
        return .idle
    }

    static func recentMessages(sessionID: String, limit: Int = 12) -> [ChatMessage] {
        guard let database = openDatabase() else { return [] }
        defer { sqlite3_close(database) }

        let sql = """
            SELECT m.data, p.data
            FROM part p
            JOIN message m ON m.id = p.message_id
            WHERE p.session_id = ?
              AND json_extract(p.data, '$.type') = 'text'
            ORDER BY p.time_created DESC
            LIMIT ?
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
            let statement
        else { return [] }
        defer { sqlite3_finalize(statement) }
        bind(sessionID, to: statement, index: 1)
        sqlite3_bind_int(statement, 2, Int32(max(1, limit)))

        var newestFirst: [(isUser: Bool, text: String)] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let messageData = text(statement, column: 0).flatMap(json),
                let role = messageData["role"] as? String,
                let partData = text(statement, column: 1).flatMap(json),
                let value = partData["text"] as? String
            else { continue }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, role == "user" || role == "assistant" else { continue }
            newestFirst.append((role == "user", trimmed))
        }
        return newestFirst.reversed().enumerated().map {
            ChatMessage(id: $0.offset, isUser: $0.element.isUser, text: $0.element.text)
        }
    }

    private struct ActiveTool {
        let name: String
        let status: String
    }

    /// Subquery errors must survive subsequent successful statements on the
    /// same SQLite connection. Empty query results are not errors.
    private final class ReadFailures {
        var failed = false
        func finish(_ statement: OpaquePointer) {
            if sqlite3_finalize(statement) != SQLITE_OK { failed = true }
        }
    }

    private static func openDatabase(path: String? = nil) -> OpaquePointer? {
        let databasePath = path ?? self.databasePath
        guard FileManager.default.fileExists(atPath: databasePath) else { return nil }
        var database: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(databasePath, &database, flags, nil) == SQLITE_OK,
            let database
        else {
            if let database { sqlite3_close(database) }
            return nil
        }
        sqlite3_busy_timeout(database, 100)
        return database
    }

    private static func latestMessage(
        _ database: OpaquePointer, sessionID: String,
        role: String, failures: ReadFailures
    ) -> [String: Any]? {
        let sql = """
            SELECT data FROM message
            WHERE session_id = ? AND json_extract(data, '$.role') = ?
            ORDER BY CAST(json_extract(data, '$.time.created') AS INTEGER) DESC
            LIMIT 1
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
            let statement
        else { failures.failed = true; return nil }
        defer { failures.finish(statement) }
        bind(sessionID, to: statement, index: 1)
        bind(role, to: statement, index: 2)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        let message = text(statement, column: 0).flatMap(json)
        if message == nil { failures.failed = true }
        return message
    }

    private static func latestText(
        _ database: OpaquePointer, sessionID: String,
        role: String, failures: ReadFailures
    ) -> String? {
        let sql = """
            SELECT p.data
            FROM part p
            JOIN message m ON m.id = p.message_id
            WHERE p.session_id = ?
              AND json_extract(m.data, '$.role') = ?
              AND json_extract(p.data, '$.type') = 'text'
            ORDER BY p.time_updated DESC
            LIMIT 20
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
            let statement
        else { failures.failed = true; return nil }
        defer { failures.finish(statement) }
        bind(sessionID, to: statement, index: 1)
        bind(role, to: statement, index: 2)
        while sqlite3_step(statement) == SQLITE_ROW {
            guard
                let object = text(statement, column: 0).flatMap(json),
                let value = object["text"] as? String
            else { failures.failed = true; continue }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, role != "user" || TaskPresentationResolver.substantive(trimmed) != nil {
                return String(trimmed.prefix(32 * 1024))
            }
        }
        return nil
    }

    private static func latestActiveTool(
        _ database: OpaquePointer,
        sessionID: String, failures: ReadFailures
    ) -> ActiveTool? {
        let sql = """
            SELECT data FROM part
            WHERE session_id = ?
              AND json_extract(data, '$.type') = 'tool'
              AND json_extract(data, '$.state.status') IN ('running', 'pending')
            ORDER BY time_updated DESC
            LIMIT 1
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
            let statement
        else { failures.failed = true; return nil }
        defer { failures.finish(statement) }
        bind(sessionID, to: statement, index: 1)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        guard
            let object = text(statement, column: 0).flatMap(json),
            let name = object["tool"] as? String,
            let state = object["state"] as? [String: Any],
            let status = state["status"] as? String
        else { failures.failed = true; return nil }
        return ActiveTool(name: name, status: status)
    }

    private static func todos(_ database: OpaquePointer, sessionID: String, failures: ReadFailures) -> [Todo] {
        let sql = "SELECT content, status FROM todo WHERE session_id = ? ORDER BY position LIMIT 64"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
            let statement
        else { failures.failed = true; return [] }
        defer { failures.finish(statement) }
        bind(sessionID, to: statement, index: 1)
        var result: [Todo] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let content = text(statement, column: 0),
                let status = text(statement, column: 1)
            else { failures.failed = true; continue }
            result.append(Todo(content: String(content.prefix(512)), status: status))
        }
        return result
    }

    private static func text(_ statement: OpaquePointer, column: Int32) -> String? {
        guard let value = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: value)
    }

    private static func bind(_ value: String, to statement: OpaquePointer, index: Int32) {
        sqlite3_bind_text(statement, index, value, -1, transient)
    }

    private static func json(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func messageTime(_ message: [String: Any]?, key: String) -> Double? {
        guard let time = message?["time"] as? [String: Any] else { return nil }
        return (time[key] as? NSNumber)?.doubleValue
    }

    private static func errorMessage(_ message: [String: Any]?) -> String? {
        guard let error = message?["error"] else { return nil }
        if let text = error as? String { return text }
        if let object = error as? [String: Any] {
            return object["message"] as? String ?? object["name"] as? String ?? "OpenCode error"
        }
        return "OpenCode error"
    }

    private static func modelID(_ raw: String?) -> String? {
        guard let raw, let object = json(raw) else { return raw }
        return object["id"] as? String
    }

    private static func elapsed(sinceMilliseconds value: Double) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince1970 - value / 1000))
        if seconds >= 3600 { return "\(seconds / 3600)h \((seconds % 3600) / 60)m" }
        if seconds >= 60 { return "\(seconds / 60)m" }
        return "<1m"
    }
}
