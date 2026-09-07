import Foundation

/// Reads Grok CLI's session store (~/.grok) to enrich Grok agents the same way
/// ClaudeSessions/CodexSessions do: real lifecycle status from turn
/// events, prompts, live activity, title, model, and todos.
///
/// Without this, Grok fell back to the CPU heuristic — and Grok's turn shape
/// (server-side "Thought for 1.8s" at ~0% CPU, then a tool call spike) flapped
/// working ↔ idle on every thinking step, firing a completion notification and
/// sound each time.
///
/// Store layout:
///   ~/.grok/active_sessions.json                     [{session_id, pid, cwd, opened_at}]
///   ~/.grok/sessions/<percent-encoded cwd>/<session_id>/
///     events.jsonl        turn_started / turn_ended, phase_changed,
///                         tool_started / tool_completed, permission_* …
///     summary.json        generated_title, current_model_id
///     chat_history.jsonl  user / assistant / tool_result records
enum GrokSessions {

    enum Phase: Equatable { case working, completed, needsAttention, failed, stopped, unknown }

    struct Info: Equatable {
        var sessionID: String?
        var turnID: String?
        var directory: String?
        var cwd: String?
        var observation = ObservationHealth.processOnly("Grok event store", reason: "No confirmed Grok event boundary")
        var title: String?
        var lastPrompt: String?
        var lastMessage: String?
        var activity: String?
        var model: String?
        var todos: [Todo] = []
        var phase: Phase = .unknown
    }

    static let source = "Grok Build event schema 1.0"
    private static let lock = NSLock()

    // MARK: - pid → session directory

    struct ReadBatch {
        var infos: [Info]
        var outcome: ProviderReadResult.Outcome
        var reason: String?
    }

    /// The official writer keeps events.jsonl open. Match both its current
    /// owner and the live registry; a recycled PID or newest cwd is not enough.
    static func read(
        pid: Int32, grokHome: String?, openEvents: [String], processStartedAt: String?, now: Date = Date()
    ) -> ReadBatch {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        guard pid > 0, let processStartedAt, let processStart = formatter.date(from: processStartedAt) else {
            return .init(infos: [], outcome: .failed, reason: "Grok process identity could not be confirmed")
        }
        let root = canonical(grokHome ?? NSHomeDirectory() + "/.grok")
        let sessionsRoot = root + "/sessions/"
        guard let data = boundedData(root + "/active_sessions.json", limit: 512 * 1024),
            let entries = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]], entries.count <= 4096
        else { return .init(infos: [], outcome: .failed, reason: "Grok active-session registry unavailable") }
        let owned = Set(openEvents.map(canonical))
        var infos: [Info] = []
        var seen = Set<String>()
        var metadataFailure = false
        for entry in entries {
            guard let entryPID = entry["pid"] as? Int, entryPID == Int(pid),
                let id = entry["session_id"] as? String, safeID(id),
                let cwd = entry["cwd"] as? String, cwd.hasPrefix("/")
            else { continue }
            let directory = canonical(sessionsRoot + encodedProjectDir(cwd) + "/" + id)
            guard directory.hasPrefix(sessionsRoot), owned.contains(directory + "/events.jsonl") else { continue }
            guard let rawOpened = entry["opened_at"] as? String, let opened = LocalSessionJSON.date(rawOpened),
                opened >= processStart,
                opened <= now.addingTimeInterval(1)
            else { metadataFailure = true; continue }
            guard let summaryData = boundedData(directory + "/summary.json", limit: 512 * 1024),
                let summary = (try? JSONSerialization.jsonObject(with: summaryData)) as? [String: Any],
                let identity = summary["info"] as? [String: Any], identity["id"] as? String == id,
                let summaryCwd = identity["cwd"] as? String, canonical(summaryCwd) == canonical(cwd)
            else { metadataFailure = true; continue }
            guard seen.insert(id).inserted else { continue }
            var info = info(dir: directory, expectedSessionID: id, openedAt: opened, now: now)
            info.sessionID = id
            info.directory = directory
            info.cwd = cwd
            infos.append(info)
        }
        let unhealthy = infos.first { $0.observation.mode != .rich }
        if metadataFailure {
            return .init(
                infos: infos, outcome: infos.isEmpty ? .failed : .partial,
                reason: "An owned Grok session has invalid identity metadata")
        }
        let outcome: ProviderReadResult.Outcome =
            unhealthy == nil
            ? (infos.isEmpty ? .empty : .success)
            : infos.allSatisfy({ $0.observation.mode == .incompatible }) ? .incompatible : .partial
        return .init(infos: infos, outcome: outcome, reason: unhealthy?.observation.reason)
    }

    private static func safeID(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= 128
            && id.utf8.allSatisfy {
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
            }
    }

    private static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: LocalSessionJSON.standardPath(path)).resolvingSymlinksInPath().path
    }

    /// Grok names project dirs by percent-encoding the cwd ("/" → "%2F").
    private static func encodedProjectDir(_ cwd: String) -> String {
        let unreserved = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return cwd.addingPercentEncoding(withAllowedCharacters: unreserved) ?? cwd
    }

    // MARK: - Session info

    private static var infoCache: [String: (stamp: String, info: Info)] = [:]

    static func info(dir: String, expectedSessionID: String? = nil, openedAt: Date? = nil, now: Date = Date()) -> Info {
        let eventsPath = dir + "/events.jsonl"
        let chatPath = dir + "/chat_history.jsonl"
        let summaryPath = dir + "/summary.json"

        func mtime(_ path: String) -> Date? {
            (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? nil
        }
        let stamp =
            [eventsPath, chatPath, summaryPath]
            .map {
                (mtime($0)?.timeIntervalSince1970.description ?? "-") + ":"
                    + String(
                        (try? FileManager.default.attributesOfItem(atPath: $0)[.size] as? NSNumber)?.intValue ?? -1)
            }
            .joined(separator: "|") + "|" + (expectedSessionID ?? "")
            + "|" + (openedAt?.timeIntervalSince1970.description ?? "")

        lock.lock()
        if let cached = infoCache[dir], cached.stamp == stamp {
            lock.unlock()
            return aged(cached.info, now: now)
        }
        lock.unlock()

        var info = Info()
        parseSummary(path: summaryPath, into: &info)
        parseChat(path: chatPath, into: &info)
        parseEvents(path: eventsPath, expectedSessionID: expectedSessionID, openedAt: openedAt, into: &info)

        lock.lock()
        if infoCache.count >= 128 { infoCache.removeAll(keepingCapacity: true) }
        infoCache[dir] = (stamp, info)
        lock.unlock()
        return aged(info, now: now)
    }

    private static func aged(_ info: Info, now: Date) -> Info {
        var info = info
        if (info.phase == .working || info.phase == .needsAttention),
            now.timeIntervalSince(info.observation.updatedAt) > 30 * 60
        {
            info.observation.mode = .stale
            info.observation.reason = "Grok progress has not been updated for 30 minutes"
        }
        return info
    }

    // MARK: summary.json — title + model

    private static func parseSummary(path: String, into info: inout Info) {
        guard let data = boundedData(path, limit: 512 * 1024),
            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return }
        info.title = (obj["generated_title"] as? String) ?? (obj["session_summary"] as? String)
        info.model = obj["current_model_id"] as? String
    }

    // MARK: chat_history.jsonl — prompts, last reply, todos, in-flight tool

    /// The last assistant tool call whose result hasn't landed, for activity.
    private struct ChatTail {
        var unresolvedCall: (name: String, arguments: String)?
    }

    private static func parseChat(path: String, into info: inout Info) {
        var pending: [(id: String, name: String, arguments: String)] = []
        var resolved = Set<String>()

        for obj in tailEntries(path: path, bytes: 256 * 1024) {
            switch obj["type"] as? String {
            case "user":
                if let text = userText(obj), TaskPresentationResolver.substantive(text) != nil {
                    info.lastPrompt = text
                }
            case "assistant":
                if let text = obj["content"] as? String,
                    !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                {
                    info.lastMessage = text
                }
                for call in obj["tool_calls"] as? [[String: Any]] ?? [] {
                    guard let name = call["name"] as? String else { continue }
                    let id = call["id"] as? String ?? ""
                    let arguments = call["arguments"] as? String ?? ""
                    pending.append((id, name, arguments))
                    if name == "todo_write", let todos = todoList(arguments: arguments) {
                        info.todos = todos
                    }
                }
            case "tool_result":
                if let id = obj["tool_call_id"] as? String { resolved.insert(id) }
            default:
                break
            }
        }

        if let call = pending.last(where: { !resolved.contains($0.id) }) {
            info.activity = describeCall(name: call.name, arguments: call.arguments)
        }
    }

    /// Grok wraps what the human typed in <user_query> tags; other user-role
    /// records are injected context and start with a different tag.
    static func userText(_ obj: [String: Any]) -> String? {
        guard let content = obj["content"] as? [[String: Any]] else { return nil }
        let text =
            content
            .filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }
            .joined(separator: "\n")
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let start = trimmed.range(of: "<user_query>"),
            let end = trimmed.range(of: "</user_query>", options: .backwards),
            start.upperBound <= end.lowerBound
        {
            let inner = trimmed[start.upperBound..<end.lowerBound]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return inner.isEmpty ? nil : inner
        }
        guard !trimmed.isEmpty, !trimmed.hasPrefix("<") else { return nil }
        return trimmed
    }

    private static func todoList(arguments: String) -> [Todo]? {
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(arguments.utf8))) as? [String: Any],
            let todos = obj["todos"] as? [[String: Any]], !todos.isEmpty
        else { return nil }
        return todos.compactMap { entry in
            guard let content = entry["content"] as? String else { return nil }
            let raw = entry["status"] as? String ?? "pending"
            let status = ["completed", "in_progress"].contains(raw) ? raw : "pending"
            return Todo(content: content, status: status)
        }
    }

    private static func describeCall(name: String, arguments: String) -> String {
        let args = (try? JSONSerialization.jsonObject(with: Data(arguments.utf8))) as? [String: Any]
        func base(_ key: String) -> String? {
            guard let path = args?[key] as? String, !path.isEmpty else { return nil }
            return (path as NSString).lastPathComponent
        }
        switch name {
        case "run_terminal_command":
            if let cmd = (args?["command"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !cmd.isEmpty
            {
                let short = cmd.count > 48 ? String(cmd.prefix(47)) + "…" : cmd
                return "Running \(short)"
            }
            return "Running a command"
        case "write", "search_replace":
            if let file = base("file_path") { return "Editing \(file)" }
            return "Editing files"
        case "read_file":
            if let file = base("target_file") { return "Reading \(file)" }
            return "Reading a file"
        case "list_dir":
            return "Listing files"
        case "grep", "search_tool":
            return "Searching the code"
        case "web_search", "web_fetch":
            return "Searching the web"
        case "spawn_subagent":
            return "Running a subagent"
        case "get_command_or_subagent_output":
            return "Waiting on a background task"
        case "todo_write":
            return "Updating the plan"
        case "use_tool":
            if let tool = args?["tool_name"] as? String {
                return "Using \(tool.replacingOccurrences(of: "_", with: " "))"
            }
            return "Using a tool"
        default:
            return "Using \(name.replacingOccurrences(of: "_", with: " "))"
        }
    }

    // MARK: events.jsonl — the phase

    /// The state a stream of turn events reduces to. Shared by the local
    /// tail reader and RemoteMonitor's over-SSH tails.
    struct EventState: Equatable {
        var phase: Phase = .unknown
        var streaming: String?  // "Thinking…" / "Replying…" while working
        var toolRunning = false
        var sessionID: String?
        var turnID: String?
        var startedAt: Date = .distantPast
        var updatedAt: Date = .distantPast
        var incompatible = false
        var invalid = false
    }

    /// Fold event records (oldest first) into a phase.
    static func reduceEvents(_ events: [[String: Any]]) -> EventState {
        var state = EventState()
        var active = false
        let timestamp = ISO8601DateFormatter()
        timestamp.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let seconds = ISO8601DateFormatter()

        for obj in events {
            guard let type = obj["type"] as? String else { continue }
            if type == "turn_started" {
                state = EventState()
                active = false
                guard obj["schema_version"] as? String == "1.0" else {
                    state.incompatible = true
                    continue
                }
                guard obj["session_relationship"] as? String == "primary",
                    let id = obj["session_id"] as? String, safeID(id),
                    let turn = obj["turn_number"] as? UInt64
                else { state.invalid = true; continue }
                state.sessionID = id
                state.turnID = String(turn)
                active = true
            }
            guard active else { continue }
            guard let rawTime = obj["ts"] as? String,
                let time = timestamp.date(from: rawTime) ?? seconds.date(from: rawTime)
            else { state.invalid = true; active = false; continue }
            // Only actual turn progress advances freshness, not MCP background noise.
            switch type {
            case "turn_started":
                state.startedAt = time
                state.phase = .working
            case "turn_ended":
                switch obj["outcome"] as? String {
                case "completed": state.phase = .completed
                case "cancelled": state.phase = .stopped
                case "error": state.phase = .failed
                default: state.phase = .unknown; state.invalid = true
                }
                state.streaming = nil
                state.toolRunning = false
                active = false
            case "phase_changed":
                switch obj["phase"] as? String {
                case "waiting_for_model", "streaming_reasoning":
                    state.streaming = "Thinking…"
                    state.toolRunning = false
                case "streaming_text":
                    state.streaming = "Replying…"
                    state.toolRunning = false
                default:
                    break  // tool_execution / permission_prompt via their events
                }
            case "tool_started":
                state.toolRunning = true
            case "tool_completed":
                state.toolRunning = false
            case "permission_requested":
                state.phase = .needsAttention
            case "permission_resolved":
                state.phase = .working
            case "first_token", "loop_started":
                break
            default:
                // mcp_server_* / mcp_transport_* noise arrives outside turns
                // too — it must not count as evidence of a turn in progress.
                continue
            }
            // EventWriter timestamps before taking its append lock. File order
            // is authoritative even when concurrent producers have older ts.
            state.updatedAt = max(state.updatedAt, time)
        }
        return state
    }

    /// Reduce a raw tail of events.jsonl (as fetched over SSH). The first
    /// line may be a fragment — unparsable lines are skipped.
    static func eventState(fromTailText text: String) -> EventState {
        let events = text.split(separator: "\n").compactMap { line in
            (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
        }
        return reduceEvents(events)
    }

    private static func parseEvents(path: String, expectedSessionID: String?, openedAt: Date?, into info: inout Info) {
        // Read a bounded suffix and resynchronize only at a real turn boundary.
        // Old history can grow indefinitely without permanently disabling reads.
        guard let data = eventTail(path, limit: 4 * 1024 * 1024),
            data.isEmpty || data.last == 10, let text = String(data: data, encoding: .utf8)
        else {
            info.observation = .init(
                mode: .stale, updatedAt: .distantPast, source: source,
                reason: "Grok events are unreadable, incomplete, or exceed the read budget")
            return
        }
        let lines = text.split(separator: "\n")
        let entries = lines.compactMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] }
        guard entries.count == lines.count, entries.count <= 32768,
            entries.allSatisfy({ $0["type"] is String })
        else {
            info.observation = .init(
                mode: .stale, updatedAt: .distantPast, source: source, reason: "Grok event stream is damaged")
            return
        }
        let state = reduceEvents(entries)
        if let openedAt, (entries.isEmpty || (!state.invalid && !state.incompatible && state.startedAt < openedAt)),
            entries.isEmpty || state.sessionID == expectedSessionID
        {
            // Opening an old transcript does not resume its turn or approval.
            // The live registry confirms an open session, not active work.
            info.turnID = nil
            info.activity = nil
            info.todos = []
            // Keep the original event clock; opening is identity, not progress.
            info.observation = .rich(source, updatedAt: state.updatedAt, authority: .officialLocalStore)
            return
        }
        guard !state.incompatible else {
            info.observation = .init(
                mode: .incompatible, updatedAt: state.updatedAt, source: source, reason: "Unsupported Grok event schema"
            )
            return
        }
        guard !state.invalid, state.sessionID != nil,
            expectedSessionID == nil || state.sessionID == expectedSessionID
        else {
            info.observation = .init(
                mode: .stale, updatedAt: state.updatedAt, source: source, reason: "No valid Grok session/turn boundary")
            return
        }
        info.sessionID = state.sessionID
        info.turnID = state.turnID
        info.observation = .rich(source, updatedAt: state.updatedAt, authority: .officialLocalStore)
        info.phase = state.phase
        if state.phase == .working {
            // A named in-flight tool call (from the chat tail) wins; otherwise
            // report the streaming state.
            if info.activity == nil || !state.toolRunning {
                info.activity = state.streaming ?? info.activity ?? "Thinking…"
            }
        } else {
            info.activity = nil
        }
    }

    // MARK: - Detail chat

    /// Recent plain-text conversation for the detail view, oldest first.
    static func recentMessages(path: String, limit: Int = 12) -> [ChatMessage] {
        var messages: [ChatMessage] = []
        var index = 0

        func append(user: Bool, text: String) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            if !user, let last = messages.last, !last.isUser {
                messages[messages.count - 1] = ChatMessage(
                    id: last.id, isUser: false,
                    text: last.text + "\n\n" + trimmed)
            } else {
                messages.append(ChatMessage(id: index, isUser: user, text: trimmed))
                index += 1
            }
        }

        for obj in tailEntries(path: path, bytes: 384 * 1024) {
            switch obj["type"] as? String {
            case "user":
                if let text = userText(obj) { append(user: true, text: text) }
            case "assistant":
                if let text = obj["content"] as? String { append(user: false, text: text) }
            default:
                break
            }
        }
        return Array(messages.suffix(limit))
    }

    // MARK: - Helpers

    private static func eventTail(_ path: String, limit: Int) -> Data? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
            attributes[.type] as? FileAttributeType == .typeRegular,
            let file = FileHandle(forReadingAtPath: path)
        else { return nil }
        defer { try? file.close() }
        do {
            let size = try file.seekToEnd()
            if size == 0 { return Data() }
            let offset = size > UInt64(limit) ? size - UInt64(limit) : 0
            try file.seek(toOffset: offset)
            guard let data = try file.read(upToCount: limit) else { return nil }
            if offset == 0 { return data }
            guard let endOfFragment = data.firstIndex(of: 10) else { return nil }
            let suffix = Data(data.suffix(from: data.index(after: endOfFragment)))
            // A single over-budget record is not a genuinely empty event log.
            return suffix.isEmpty ? nil : suffix
        } catch { return nil }
    }

    private static func boundedData(_ path: String, limit: Int) -> Data? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
            attributes[.type] as? FileAttributeType == .typeRegular,
            let size = attributes[.size] as? NSNumber, size.intValue <= limit,
            let file = FileHandle(forReadingAtPath: path)
        else { return nil }
        defer { try? file.close() }
        guard let data = try? file.read(upToCount: limit + 1), data.count <= limit else { return nil }
        return data
    }

    /// Parse the last `bytes` of a jsonl file (partial first line dropped).
    private static func tailEntries(path: String, bytes: Int) -> [[String: Any]] {
        guard let handle = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? handle.close() }

        let size = (try? handle.seekToEnd()) ?? 0
        let offset = size > UInt64(bytes) ? size - UInt64(bytes) : 0
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.read(upToCount: bytes) else { return [] }

        // Lossy on purpose — the window can begin mid-character. See TailRead.
        let lines = TailRead.lines(data, dropsFirstLine: offset > 0)

        return lines.compactMap { line in
            (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
        }
    }
}
