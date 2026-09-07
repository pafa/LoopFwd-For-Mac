import Foundation

/// Current CLI tab state comes from the official open-session tracker and PID
/// locks. Persisted events supply context and explicit results, never control.
enum CopilotSessions {
    static let source = "Copilot open-session tracker"
    struct Info {
        let sessionID: String
        var transcriptPath: String?
        var title: String?
        var cwd: String?
        var status: AgentStatus
        var lastPrompt: String?
        var lastMessage: String?
        var activity: String?
        var model: String?
        var turnID: String?
        var updatedAt: Date
        var observation: ObservationHealth
    }
    struct Batch {
        var sessions: [Info] = []
        var outcome: ProviderReadResult.Outcome = .empty
        var reason: String?
    }

    static func returnTarget(terminalApp: String?) -> ReturnTarget {
        switch terminalApp {
        case "Terminal": return .application(bundleIdentifier: "com.apple.Terminal", name: "Terminal")
        case "iTerm": return .application(bundleIdentifier: "com.googlecode.iterm2", name: "iTerm")
        default: return .unavailable(reason: "Copilot session tab cannot be selected precisely")
        }
    }

    static func read(processID: Int32, processStartedAt: String?, cwd: String?, home: String?, now: Date = Date())
        -> Batch
    {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        guard processID > 0, let processStartedAt, let start = formatter.date(from: processStartedAt) else {
            return Batch(outcome: .failed, reason: "Copilot process identity could not be confirmed")
        }
        let root = LocalSessionJSON.standardPath(LocalSessionJSON.compact(home) ?? NSHomeDirectory() + "/.copilot")
        guard let bytes = file(root + "/open-sessions-state.json", limit: 1024 * 1024),
            let records = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any], records.count <= 4096
        else { return Batch(outcome: .failed, reason: "Copilot open-session tracker is missing or unreadable") }
        var batch = Batch()
        for (id, value) in records.sorted(by: { $0.key < $1.key }) {
            guard UUID(uuidString: id) != nil else { continue }
            let directory = root + "/session-state/" + id
            let lockPath = directory + "/inuse.\(processID).lock"
            guard regular(directory, .typeDirectory),
                let lockData = file(lockPath, limit: 64),
                String(data: lockData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    == String(processID),
                let lockDate = LocalSessionJSON.fileDate(lockPath), lockDate >= start,
                lockDate <= now.addingTimeInterval(1)
            else { continue }
            guard let record = value as? [String: Any], schemaOne(record["schemaVersion"]),
                let working = boolean(record["working"]),
                let opened = date(record["openedAt"], now: now), opened >= start,
                let refreshed = date(record["refreshedAt"] ?? record["openedAt"], now: now), refreshed >= opened
            else {
                batch.outcome = .partial; batch.reason = "Copilot session state is incompatible or invalid"; continue
            }
            var info = Info(
                sessionID: id, cwd: cwd, status: working ? .working : .idle,
                updatedAt: refreshed, observation: .rich(source, updatedAt: refreshed))
            readWorkspace(directory + "/workspace.yaml", into: &info)
            let events = directory + "/events.jsonl"
            if FileManager.default.fileExists(atPath: events) {
                readEvents(events, openedAt: opened, working: working, now: now, into: &info)
            }
            if info.observation.mode != .rich {
                batch.outcome = .partial
                batch.reason = info.observation.reason
            }
            guard file(lockPath, limit: 64) == lockData else { continue }
            batch.sessions.append(info)
        }
        if batch.outcome != .partial { batch.outcome = batch.sessions.isEmpty ? .empty : .success }
        return batch
    }

    private static func readWorkspace(_ path: String, into info: inout Info) {
        guard let data = file(path, limit: 64 * 1024), let text = String(data: data, encoding: .utf8) else { return }
        // Deliberately not general YAML: only single-line top-level scalars.
        var values: [String: String] = [:]
        for line in text.split(separator: "\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon])
            guard ["id", "cwd", "summary"].contains(key), values[key] == nil else { continue }
            let raw = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if raw.hasPrefix("\"") {
                values[key] =
                    (try? JSONSerialization.jsonObject(with: Data(raw.utf8), options: .fragmentsAllowed)) as? String
            } else if raw.hasPrefix("'"), raw.hasSuffix("'") {
                values[key] = String(raw.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
            } else if !raw.isEmpty, !["|", ">", "&", "*", "!", "[", "{"].contains(String(raw.prefix(1))) {
                values[key] = raw
            }
        }
        guard values["id"] == info.sessionID else { return }
        if let cwd = values["cwd"], cwd.hasPrefix("/") { info.cwd = cwd }
        info.title = bounded(values["summary"])
    }

    private static func readEvents(_ path: String, openedAt: Date, working: Bool, now: Date, into info: inout Info) {
        guard regular(path, .typeRegular),
            let header = LocalSessionJSON.headObjects(path: path).first(where: {
                $0["type"] as? String == "session.start"
            }),
            let metadata = header["data"] as? [String: Any], metadata["sessionId"] as? String == info.sessionID,
            metadata["copilotVersion"] as? String == "1.0.83"
        else {
            info.observation = .init(
                mode: .incompatible, updatedAt: info.updatedAt, source: source,
                reason: "Copilot event format or version is incompatible")
            return
        }
        guard let records = eventTail(path) else {
            info.observation = .init(
                mode: .stale, updatedAt: info.updatedAt, source: source,
                reason: "Copilot event log is unreadable or incomplete")
            return
        }
        guard
            records.allSatisfy({
                $0["type"] is String && $0["data"] is [String: Any] && date($0["timestamp"], now: now) != nil
            })
        else {
            info.observation = .init(
                mode: .stale, updatedAt: info.updatedAt, source: source,
                reason: "Copilot event log is unreadable or incomplete")
            return
        }
        info.transcriptPath = path
        info.model = bounded(metadata["selectedModel"])
        let objectivePath = URL(fileURLWithPath: path).deletingLastPathComponent()
            .appendingPathComponent("autopilot-objective.json").path
        let objective = readObjective(objectivePath)
        var latestObjectiveChange: Objective?
        var completion: [String: Any]?
        var outcome: AgentStatus?
        var activeTools: [String: String] = [:]
        for record in records {
            guard record["agentId"] == nil, let type = record["type"] as? String,
                let data = record["data"] as? [String: Any], let time = date(record["timestamp"], now: now)
            else { continue }
            info.updatedAt = max(info.updatedAt, time)
            switch type {
            case "user.message":
                if let prompt = bounded(data["content"]), TaskPresentationResolver.substantive(prompt) != nil {
                    info.lastPrompt = prompt
                }
                info.turnID = bounded(record["id"])
                activeTools.removeAll(); outcome = nil; completion = nil
            case "session.context_cleared", "session.snapshot_rewind":
                info.lastPrompt = nil; info.lastMessage = nil; info.turnID = nil
                activeTools.removeAll(); outcome = nil; completion = nil
            case "session.title_changed": info.title = bounded(data["title"])
            case "session.model_change": info.model = bounded(data["newModel"]) ?? bounded(data["model"]) ?? info.model
            case "assistant.turn_start":
                outcome = nil; completion = nil; info.model = bounded(data["model"]) ?? info.model
            case "assistant.message": info.lastMessage = bounded(data["content"]) ?? info.lastMessage
            case "tool.execution_start":
                if let id = bounded(data["toolCallId"]), let name = bounded(data["toolName"]), activeTools.count < 128 {
                    activeTools[id] = name
                }
            case "tool.execution_complete":
                if let id = bounded(data["toolCallId"]) { activeTools.removeValue(forKey: id) }
            case "session.task_complete" where time >= openedAt && info.turnID != nil:
                // All fields are optional in 1.0.83. Legacy success omits
                // outcome; invalid calls explicitly report success:false.
                completion = acceptedCompletion(data) ? data : nil
                outcome = completion == nil ? nil : .completed
            case "session.autopilot_objective_changed":
                let previous = latestObjectiveChange ?? objective.identity
                let change = objectiveChange(data)
                latestObjectiveChange = change
                // Only a same-objective confirmation may retain an earlier
                // result. A new/deleted/resumed goal invalidates that result.
                if case .current(let id, "completed") = change,
                    data["operation"] as? String == "update", objectiveID(completion?["objectiveId"]) == id
                {
                } else {
                    let retainsFailure: Bool
                    if case .current(let oldID, _) = previous, case .current(let id, let status) = change,
                        id == oldID, data["operation"] as? String == "update",
                        ["paused", "cap_reached"].contains(status), outcome == .failed || outcome == .stopped
                    {
                        // Autopilot pauses after an error/cancel; that metadata
                        // update must not erase the explicit terminal result.
                        retainsFailure = true
                    } else {
                        retainsFailure = false
                    }
                    if !retainsFailure { outcome = nil }
                    completion = nil
                }
            case "abort" where time >= openedAt && info.turnID != nil: outcome = .stopped
            case "session.error" where time >= openedAt && info.turnID != nil: outcome = .failed
            default: break  // turn_end, idle, shutdown and historical requests do not grant success/attention.
            }
        }
        if outcome == .completed, let completion,
            !completionMatches(completion, objective: objective.identity, change: latestObjectiveChange)
                || objective != readObjective(objectivePath)
        {
            outcome = nil
        }
        info.status = working ? .working : outcome ?? .idle
        if working, let tool = activeTools.sorted(by: { $0.key < $1.key }).first?.value {
            info.activity = "Running \(tool)"
        }
        info.observation = .rich(source, updatedAt: info.updatedAt)
    }

    private enum Objective: Equatable {
        case none
        case current(Int64, String)
        case unknown
    }

    private struct ObjectiveSnapshot: Equatable {
        var identity: Objective
        var bytes: Data?
    }

    /// This is the pinned native disk envelope, not the SDK's public projection.
    /// Read only identity/status; never copy the objective text into diagnostics.
    private static func readObjective(_ path: String) -> ObjectiveSnapshot {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else {
            // A regular CLI task need not create an autopilot file. Only true
            // absence is optional; access errors and dangling links fail closed.
            var info = stat()
            return .init(identity: lstat(path, &info) != 0 && errno == ENOENT ? .none : .unknown)
        }
        guard attributes[.type] as? FileAttributeType == .typeRegular,
            let bytes = file(path, limit: 128 * 1024),
            let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
            schemaOne(object["version"])
        else { return .init(identity: .unknown) }
        if object["current"] is NSNull { return .init(identity: .none, bytes: bytes) }
        guard let current = object["current"] as? [String: Any] else { return .init(identity: .unknown, bytes: bytes) }
        return .init(identity: objectiveIdentity(current), bytes: bytes)
    }

    private static func objectiveIdentity(_ data: [String: Any]) -> Objective {
        guard let id = objectiveID(data["id"]), let status = data["status"] as? String,
            ["active", "paused", "cap_reached", "completed"].contains(status)
        else { return .unknown }
        return .current(id, status)
    }

    private static func objectiveChange(_ data: [String: Any]) -> Objective {
        switch data["operation"] as? String {
        case "delete": return .none
        case "create", "update": return objectiveIdentity(data)
        default: return .unknown
        }
    }

    private static func objectiveID(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
            number.doubleValue >= 1, number.doubleValue <= 9_007_199_254_740_991,
            number.doubleValue.rounded() == number.doubleValue
        else { return nil }
        return number.int64Value
    }

    private static func acceptedCompletion(_ data: [String: Any]) -> Bool {
        if data["success"] != nil, boolean(data["success"]) != true { return false }
        if data["outcome"] != nil, data["outcome"] as? String != "completed" { return false }
        if data["objectiveId"] != nil, objectiveID(data["objectiveId"]) == nil { return false }
        for key in ["summary", "reason"] where data[key] != nil {
            if !(data[key] is String) { return false }
        }
        return true
    }

    private static func completionMatches(_ data: [String: Any], objective: Objective, change: Objective?) -> Bool {
        // A bounded event suffix cannot prove absence of autopilot state. Always
        // check the current file as well as any objective transition in the tail.
        if let change, change != objective { return false }
        switch objective {
        case .none: return data["objectiveId"] == nil
        case .current(let id, let status):
            return status == "completed" && objectiveID(data["objectiveId"]) == id
        case .unknown: return false
        }
    }

    static func recentMessages(path: String, limit: Int = 12) -> [ChatMessage] {
        (eventTail(path) ?? []).compactMap { record -> (Bool, String)? in
            guard record["agentId"] == nil, let type = record["type"] as? String,
                ["user.message", "assistant.message"].contains(type), let data = record["data"] as? [String: Any],
                let text = bounded(data["content"])
            else { return nil }
            return (type == "user.message", text)
        }.suffix(max(1, min(limit, 100))).enumerated().map {
            ChatMessage(id: $0.offset, isUser: $0.element.0, text: $0.element.1)
        }
    }

    private static func eventTail(_ path: String) -> [[String: Any]]? {
        guard regular(path, .typeRegular), let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let limit: UInt64 = 1024 * 1024
        let offset = size > limit ? size - limit : 0
        do { try handle.seek(toOffset: offset) } catch { return nil }
        guard var bytes = try? handle.read(upToCount: Int(limit)), !bytes.isEmpty, bytes.last == 10 else { return nil }
        if offset > 0 {
            guard let newline = bytes.firstIndex(of: 10) else { return nil }
            bytes = bytes.suffix(from: bytes.index(after: newline))
        }
        var records: [[String: Any]] = []
        for line in bytes.split(separator: 10) {
            guard records.count < 8192,
                let record = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any]
            else { return nil }
            records.append(record)
        }
        return records
    }
    private static func regular(_ path: String, _ type: FileAttributeType) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: path)[.type] as? FileAttributeType) == type
    }
    private static func file(_ path: String, limit: Int) -> Data? {
        guard regular(path, .typeRegular), let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: limit + 1), data.count <= limit else { return nil }
        return data
    }
    private static func schemaOne(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return false }
        return number.doubleValue == 1
    }
    private static func boolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }
    private static func date(_ value: Any?, now: Date) -> Date? {
        guard let value = value as? String, let parsed = LocalSessionJSON.date(value),
            parsed.timeIntervalSince1970.isFinite, parsed.timeIntervalSince1970 > 0, parsed <= now.addingTimeInterval(1)
        else { return nil }
        return parsed
    }
    private static func bounded(_ value: Any?) -> String? {
        LocalSessionJSON.text(value).map { String($0.prefix(4096)) }
    }
}
