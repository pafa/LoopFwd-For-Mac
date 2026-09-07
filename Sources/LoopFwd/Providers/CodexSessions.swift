import Foundation

/// Reads Codex CLI rollout files (~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl)
/// to enrich Codex agents the same way ClaudeSessions does for Claude Code:
/// prompts, live activity, plan checklists, model, and real lifecycle
/// status from task events.
///
/// Bind CLI processes only to verified open rollouts. A working-directory
/// match alone cannot identify which conversation that process is executing.
enum CodexSessions {

    enum Phase: Equatable { case working, completed, failed, stopped, unknown }

    struct Info: Equatable {
        var turnID: String?
        var lastPrompt: String?
        var lastMessage: String?
        var activity: String?
        var model: String?
        var todos: [Todo] = []
        var phase: Phase = .unknown
        var readSucceeded = false
        var readIssue: String?
        var lastSuccessfulReadAt: Date?
        var recoveringTaskContext = false
    }

    private static let home = FileManager.default.homeDirectoryForCurrentUser.path
    static func sessionsDirectory(codexHome: String?) -> String {
        let configured = codexHome ?? ProcessInfo.processInfo.environment["CODEX_HOME"]
        let root = configured.flatMap { $0.hasPrefix("/") ? $0 : nil } ?? home + "/.codex"
        return URL(fileURLWithPath: root).appendingPathComponent("sessions").resolvingSymlinksInPath()
            .standardizedFileURL.path
    }

    // MARK: - pid → rollout discovery

    private static var pidRoots: [Int32: String] = [:]
    struct RolloutDiscovery {
        let path: String?
        let mode: ObservationMode
        let reason: String?
    }
    private struct CachedDiscovery {
        let result: RolloutDiscovery
        let checkedAt: Date
    }
    private static var discoveries: [Int32: CachedDiscovery] = [:]
    private static let lock = NSLock()

    /// Forget exited/recycled process bindings before the next read.
    static func prune(livePids: Set<Int32>) {
        lock.lock()
        pidRoots = pidRoots.filter { livePids.contains($0.key) }
        discoveries = discoveries.filter { livePids.contains($0.key) }
        lock.unlock()
    }

    static func discoverRollout(
        pid: Int32, cwd _: String?, codexHome: String? = nil,
        openFilesOutput: String? = nil, now: Date = Date()
    ) -> RolloutDiscovery {
        let directory = sessionsDirectory(codexHome: codexHome)
        lock.lock()
        let previous = pidRoots[pid] == directory ? discoveries[pid] : nil
        if openFilesOutput == nil, let previous,
            now.timeIntervalSince(previous.checkedAt) >= 0,
            now.timeIntervalSince(previous.checkedAt) < 2
        {
            lock.unlock()
            return previous.result
        }
        lock.unlock()

        let output = openFilesOutput ?? run("/usr/sbin/lsof", ["-a", "-p", "\(pid)", "-Fn"])
        let open = openRollouts(from: output)
        let result: RolloutDiscovery
        if open.count == 1 {
            result = .init(path: open[0], mode: .rich, reason: nil)
        } else if let previous, previous.result.mode != .processOnly, let path = previous.result.path {
            result = .init(
                path: path, mode: .stale,
                reason: "The process's current rollout could not be verified")
        } else if open.isEmpty {
            // Do not enumerate history to guess a binding that consumers
            // cannot trust. The process projection already carries its cwd.
            result = .init(
                path: nil, mode: .processOnly,
                reason: "No open rollout could be verified for this process")
        } else {
            result = .init(path: nil, mode: .processOnly, reason: "Multiple open rollouts make the session ambiguous")
        }
        lock.lock()
        pidRoots[pid] = directory
        discoveries[pid] = .init(result: result, checkedAt: now)
        lock.unlock()
        return result
    }

    /// A renamed/custom CODEX_HOME is valid. Verify provider metadata instead
    /// of assuming every open rollout lives under the default directory name.
    static func openRollouts(from output: String) -> [String] {
        var candidates: Set<String> = []
        for line in output.split(separator: "\n")
        where line.hasPrefix("n/") && line.hasSuffix(".jsonl") {
            let path = URL(fileURLWithPath: String(line.dropFirst())).resolvingSymlinksInPath().standardizedFileURL.path
            let name = (path as NSString).lastPathComponent
            guard name.hasPrefix("rollout-"), threadID(path: path) != nil else { continue }
            candidates.insert(path)
        }
        return candidates.sorted()
    }

    // MARK: - Rollout tail parsing

    /// Immutable provider identity, shared by CLI, Desktop and managed tasks.
    static func threadID(path: String) -> String? {
        guard let id = metadata(path: path)?["id"] as? String, !id.isEmpty else { return nil }
        return id
    }

    static func metadata(path: String) -> [String: Any]? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
            let fileID = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value,
            let size = (attributes[.size] as? NSNumber)?.uint64Value
        else { return nil }
        let modified = attributes[.modificationDate] as? Date
        lock.lock()
        if var cached = metadataCache[path], cached.fileID == fileID,
            size > cached.size || (size == cached.size && modified == cached.modified)
        {
            cached.size = size
            cached.modified = modified
            metadataCache[path] = cached
            lock.unlock()
            return cached.payload
        }
        lock.unlock()
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        // Read only through the first complete record, rather than reading and
        // splitting 256 KiB of tool output for every historical row each poll.
        var data = Data()
        while data.count < 256 * 1024 {
            guard let chunk = try? handle.read(upToCount: 4096), !chunk.isEmpty else { break }
            data.append(chunk)
            if data.contains(10) { break }
        }
        let line = data.prefix(upTo: data.firstIndex(of: 10) ?? data.endIndex)
        guard !line.isEmpty,
            let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
            object["type"] as? String == "session_meta",
            let payload = object["payload"] as? [String: Any]
        else { return nil }
        let identity = payload.filter { ["id", "cwd", "originator"].contains($0.key) }
        lock.lock()
        metadataCache[path] = .init(fileID: fileID, size: size, modified: modified, payload: identity)
        if metadataCache.count > 512,
            let oldest = metadataCache.min(by: {
                ($0.value.modified ?? .distantPast) < ($1.value.modified ?? .distantPast)
            })?.key
        {
            metadataCache.removeValue(forKey: oldest)
        }
        lock.unlock()
        return identity
    }

    private struct MetadataEntry {
        let fileID: UInt64
        var size: UInt64
        var modified: Date?
        let payload: [String: Any]
    }
    private static var metadataCache: [String: MetadataEntry] = [:]

    private static var infoCache: [String: (mtime: Date, info: Info)] = [:]
    private static let taskHistory = CodexTaskHistory()

    static func tailInfo(path: String) -> Info {
        let mtime = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? nil

        lock.lock()
        if let mtime, let cached = infoCache[path], cached.mtime == mtime {
            lock.unlock()
            guard cached.info.recoveringTaskContext else { return cached.info }
            var info = cached.info
            recoverTaskContext(path: path, tailPrompt: nil, info: &info)
            lock.lock()
            infoCache[path] = (mtime, info)
            lock.unlock()
            return info
        }
        lock.unlock()

        // Rollouts are append-only. Preserve stable context from the previous
        // parse when a new append pushes the last prompt or plan beyond the
        // bounded live-status tail; activity and phase are recomputed below.
        var info = Info()
        lock.lock()
        let previous = infoCache[path]?.info
        lock.unlock()
        if let previous {
            info.turnID = previous.turnID
            info.lastMessage = previous.lastMessage
            info.model = previous.model
            // A task boundary is state, not just tail-local evidence. Large
            // tool outputs can push task_started beyond the bounded read before
            // task_complete arrives, so retain the last confirmed phase.
            info.phase = previous.phase
            info.lastSuccessfulReadAt = previous.lastSuccessfulReadAt
        }
        var pendingCalls: [(id: String, description: String)] = []
        var resolvedCallIds = Set<String>()
        var sawTaskBoundary = false
        var sawLiveTurnEvidence = false

        let tail = readTail(path: path, bytes: 256 * 1024)
        let entries = tail.entries
        info.readSucceeded = entries.contains {
            guard let (type, _) = record($0) else { return false }
            return [
                "session_meta", "turn_context", "response_item", "event_msg", "message",
                "function_call", "function_call_output", "local_shell_call", "local_shell_call_output",
                "custom_tool_call", "reasoning",
            ].contains(type)
        }
        if info.readSucceeded {
            info.lastSuccessfulReadAt = mtime
        } else {
            info.readIssue =
                tail.exceedsWindow
                ? "Latest record exceeds the observation window; waiting for readable progress"
                : "Rollout could not be read or parsed"
        }
        for obj in entries {
            guard let (type, payload) = record(obj) else { continue }
            switch type {
            case "turn_context":
                if let model = payload["model"] as? String, !model.isEmpty { info.model = model }
            case "response_item":
                if isLiveTurnItem(payload) { sawLiveTurnEvidence = true }
                handleItem(payload, info: &info, pending: &pendingCalls, resolved: &resolvedCallIds)
            case "event_msg":
                if taskBoundaryPhase(payload) != nil { sawTaskBoundary = true }
                handleEvent(payload, info: &info)
            // Older flat format: response items at the top level.
            // "local_shell_call_output" was missing here, so shell results were
            // dropped before handleItem ever saw them.
            case "message", "function_call", "function_call_output",
                "local_shell_call", "local_shell_call_output", "reasoning":
                var item = payload
                item["type"] = type
                if isLiveTurnItem(item) { sawLiveTurnEvidence = true }
                handleItem(item, info: &info, pending: &pendingCalls, resolved: &resolvedCallIds)
            default:
                break
            }
        }

        // If the current tail contains model/tool output but no boundary, it
        // necessarily belongs to a turn whose task_started line was displaced
        // by a large record. Do not turn that active task into a completed
        // turn merely because the bounded reader lost its opening marker.
        if !sawTaskBoundary, sawLiveTurnEvidence {
            info.phase = .working
        }

        // Unresolved tool call = still working, even without task events.
        let unresolved = pendingCalls.last { !resolvedCallIds.contains($0.id) }
        if info.phase == .unknown, unresolved != nil { info.phase = .working }
        if info.phase == .working {
            info.activity = unresolved?.description ?? "Thinking…"
        }

        // On first launch there is no in-memory context to preserve. A large
        // command result can push update_plan beyond the 256 KB live tail in a
        // single turn, so make one wider, still-bounded pass only when needed.
        if info.todos.isEmpty, info.readSucceeded {
            if let previous, previous.turnID == info.turnID {
                info.todos = previous.todos
            } else if previous == nil, let plan = latestPlan(path: path, bytes: 8 * 1024 * 1024) {
                info.todos = plan
            }
        }
        if info.readSucceeded {
            recoverTaskContext(path: path, tailPrompt: info.lastPrompt, info: &info)
        } else {
            info.lastPrompt = previous?.lastPrompt
            info.todos = previous?.todos ?? []
        }

        if let mtime, info.readSucceeded {
            lock.lock()
            infoCache[path] = (mtime, info)
            if infoCache.count > 128,
                let oldest = infoCache.min(by: { $0.value.mtime < $1.value.mtime })?.key
            {
                infoCache.removeValue(forKey: oldest)
            }
            lock.unlock()
        }
        return info
    }

    private static func recoverTaskContext(path: String, tailPrompt: String?, info: inout Info) {
        let context = taskHistory.recover(path: path, tailPrompt: tailPrompt) { line in
            // Most history is tool output; avoid parsing it as a user message.
            guard
                line.range(of: Data("\"user\"".utf8)) != nil
                    || line.range(of: Data("\"user_message\"".utf8)) != nil,
                let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                let (type, payload) = record(object)
            else { return nil }
            let text: String?
            if type == "event_msg", payload["type"] as? String == "user_message" {
                text = payload["message"] as? String
            } else if (type == "message" || (type == "response_item" && payload["type"] as? String == "message")),
                payload["role"] as? String == "user"
            {
                text = messageText(payload)
            } else {
                text = nil
            }
            guard let raw = text, let text = userText(raw), TaskPresentationResolver.substantive(text) != nil else {
                return nil
            }
            return text
        }
        info.lastPrompt = context.prompt ?? info.lastPrompt
        info.recoveringTaskContext = context.isRecovering
    }

    private static func handleItem(
        _ item: [String: Any], info: inout Info,
        pending: inout [(id: String, description: String)],
        resolved: inout Set<String>
    ) {
        switch item["type"] as? String {
        case "message":
            guard let role = item["role"] as? String else { return }
            if role == "user", let raw = messageText(item), let text = userText(raw) {
                if TaskPresentationResolver.substantive(text) != nil { info.lastPrompt = text }
            } else if role == "assistant", let text = messageText(item) {
                info.lastMessage = text
            }
        case "function_call":
            let id = item["call_id"] as? String ?? item["id"] as? String ?? ""
            let name = item["name"] as? String ?? ""
            let arguments = item["arguments"] as? String ?? ""
            pending.append((id, describeCall(name: name, arguments: arguments)))
            if let todos = planFromItem(item) {
                info.todos = todos
            }
        case "local_shell_call":
            let id = item["call_id"] as? String ?? item["id"] as? String ?? ""
            let action = item["action"] as? [String: Any]
            let command = (action?["command"] as? [String]) ?? []
            pending.append((id, describeShell(command)))
        case "custom_tool_call":
            // Codex Desktop's current rollout format uses custom_tool_call for
            // MCP and orchestration tools. Treat it like function_call so an
            // active Desktop turn remains working after task_started scrolls
            // beyond the bounded tail.
            let id = item["call_id"] as? String ?? item["id"] as? String ?? ""
            let name = item["name"] as? String ?? "tool"
            let input = item["input"] as? String ?? ""
            pending.append((id, describeCall(name: name, arguments: input)))
            if let todos = planFromItem(item) {
                info.todos = todos
            }
        default:
            // Any *_call_output resolves the call it names.
            //
            // Only "function_call_output" was handled, so shell results —
            // written as "local_shell_call_output" — fell through here and
            // every completed shell call stayed pending forever. Once the
            // task_complete event scrolled out of the 256KB window (a long turn
            // with large tool output), phase was .unknown, the unresolved call
            // forced it to .working, and the card showed "Running <an old
            // command>" while Codex sat idle at the prompt.
            //
            // Matching on the suffix rather than listing types also covers
            // custom tool outputs without needing another edit here.
            if let type = item["type"] as? String, type.hasSuffix("_call_output") {
                // The call side falls back to "id" when "call_id" is absent, so
                // the output side has to as well or the two never match.
                if let id = item["call_id"] as? String ?? item["id"] as? String {
                    resolved.insert(id)
                }
            }
        }
    }

    private static func handleEvent(_ event: [String: Any], info: inout Info) {
        if let turnID = event["turn_id"] as? String { info.turnID = turnID }
        if let phase = taskBoundaryPhase(event) { info.phase = phase }
        if event["type"] as? String == "task_started" { info.todos = [] }
        if event["type"] as? String == "user_message" {
            if let raw = event["message"] as? String, let text = userText(raw) {
                if TaskPresentationResolver.substantive(text) != nil { info.lastPrompt = text }
            }
        }
    }

    private static func taskBoundaryPhase(_ event: [String: Any]) -> Phase? {
        switch event["type"] as? String {
        case "task_started":
            return .working
        case "task_complete":
            return .completed
        case "error":
            return .failed
        case "turn_aborted", "shutdown_complete":
            return .stopped
        default:
            return nil
        }
    }

    /// Response items are emitted only inside a live turn. If they are visible
    /// without task_started/task_complete in the same bounded tail, the opening
    /// boundary was displaced by output; this is positive Working evidence.
    private static func isLiveTurnItem(_ item: [String: Any]) -> Bool {
        guard let type = item["type"] as? String else { return false }
        if type == "message" { return item["role"] as? String == "assistant" }
        return type == "reasoning" || type.contains("call")
    }

    /// Recent plain-text conversation for the detail view, oldest first.
    static func recentMessages(path: String, limit: Int = 12, bytes: Int = 384 * 1024) -> [ChatMessage] {
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

        for obj in tailEntries(path: path, bytes: bytes) {
            guard let (type, payload) = record(obj) else { continue }
            var item: [String: Any]?
            if type == "response_item" { item = payload }
            if type == "message" {
                item = payload
                item?["type"] = "message"
            }
            guard let item, item["type"] as? String == "message",
                let role = item["role"] as? String,
                let text = messageText(item)
            else { continue }
            if role == "user" {
                guard let text = userText(text) else { continue }
                append(user: true, text: text)
            } else if role == "assistant" {
                append(user: false, text: text)
            }
        }
        return Array(messages.suffix(limit))
    }

    // MARK: - Helpers

    /// Both record shapes: {"type","payload":{…}} (current) and flat (older).
    private static func record(_ obj: [String: Any]) -> (String, [String: Any])? {
        guard let type = obj["type"] as? String else { return nil }
        if let payload = obj["payload"] as? [String: Any] { return (type, payload) }
        return (type, obj)
    }

    private static func messageText(_ item: [String: Any]) -> String? {
        guard let content = item["content"] as? [[String: Any]] else { return nil }
        let texts = content.compactMap { part -> String? in
            let type = part["type"] as? String
            guard type == "input_text" || type == "output_text" || type == "text" else { return nil }
            return part["text"] as? String
        }
        return texts.isEmpty ? nil : texts.joined(separator: "\n")
    }

    /// Ambient browser context may precede a real request in the same record.
    /// Strip only that known envelope and require the request marker outside
    /// its closing tag. Other injected XML, Hook replies and repository
    /// instructions remain non-user context, even if they contain the marker.
    private static func userText(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let tag = "<in-app-browser-context"
        if text.hasPrefix(tag) {
            let remainder = text.dropFirst(tag.count)
            guard let boundary = remainder.first, boundary == ">" || boundary.isWhitespace,
                let openingEnd = remainder.firstIndex(of: ">"),
                let closing = text.range(of: "</in-app-browser-context>", range: openingEnd..<text.endIndex)
            else { return nil }
            let context = text[text.index(after: openingEnd)..<closing.lowerBound]
            let suffix = text[closing.upperBound...]
            guard !context.contains(tag), !suffix.contains(tag), !suffix.contains("</in-app-browser-context>") else {
                return nil
            }
            text = suffix.trimmingCharacters(in: .whitespacesAndNewlines)
            let marker = "## My request:"
            guard let lineEnd = text.firstIndex(where: \.isNewline),
                text[..<lineEnd].trimmingCharacters(in: .whitespaces) == marker
            else { return nil }
            text = text[lineEnd...].trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !text.isEmpty, !text.hasPrefix("<"), !text.hasPrefix("# AGENTS.md") else { return nil }
        return text
    }

    private static func describeCall(name: String, arguments: String) -> String {
        // Provider tool titles are explicit activity descriptions. Do not
        // evaluate orchestration code or fabricate its intended outcome.
        let object =
            arguments.utf8.count <= 128 * 1024
            ? (try? JSONSerialization.jsonObject(with: Data(arguments.utf8))) as? [String: Any] : nil
        if let title = object?["title"] as? String,
            let summary = TaskPresentationResolver.concise(title)
        {
            return summary
        }
        switch name {
        case "shell", "exec_command", "container.exec":
            if let command = object?["command"] as? [String] { return describeShell(command) }
            if let command = object?["command"] as? String { return describeShell([command]) }
            if let command = object?["cmd"] as? String { return describeShell([command]) }
            return "Running a command"
        case "exec", "js": return "Running a tool script"
        case "apply_patch":
            // Patch text carries "*** Update File: path/to/file".
            if let range = arguments.range(
                of: #"\*\*\* (Update|Add|Delete) File: [^\\"\n]+"#,
                options: .regularExpression)
            {
                let line = String(arguments[range])
                let file = (line.components(separatedBy: ": ").last ?? "")
                let base = (file as NSString).lastPathComponent
                if !base.isEmpty { return "Editing \(base)" }
            }
            return "Editing files"
        case "update_plan":
            return "Updating the plan"
        case "web_search", "web_search_call":
            return "Searching the web"
        case "view_image":
            return "Viewing an image"
        default:
            return "Using \(name.replacingOccurrences(of: "_", with: " "))"
        }
    }

    private static func describeShell(_ command: [String]) -> String {
        // Commands usually arrive as ["bash", "-lc", "the real command"].
        var cmd = command.last ?? ""
        if command.count == 1 { cmd = command[0] }
        cmd = cmd.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cmd.isEmpty else { return "Running a command" }
        let short = cmd.count > 48 ? String(cmd.prefix(47)) + "…" : cmd
        return "Running \(short)"
    }

    private static func planTodos(arguments: String) -> [Todo]? {
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(arguments.utf8))) as? [String: Any],
            let plan = obj["plan"] as? [[String: Any]], !plan.isEmpty
        else { return nil }
        return plan.compactMap { step in
            guard let content = step["step"] as? String else { return nil }
            let raw = step["status"] as? String ?? "pending"
            let status = ["completed", "in_progress"].contains(raw) ? raw : "pending"
            return Todo(content: content, status: status)
        }
    }

    /// Codex Desktop currently records tool orchestration as an outer
    /// `custom_tool_call(name: "exec")` whose JavaScript invokes
    /// `tools.update_plan(...)`. Extract only the literal step/status pairs we
    /// generate; arbitrary JavaScript is never evaluated.
    private static func embeddedPlanTodos(source: String) -> [Todo]? {
        guard source.contains("tools.update_plan(") else { return nil }
        let pattern =
            #"\{\s*step\s*:\s*\"((?:\\.|[^\"\\])*)\"\s*,\s*status\s*:\s*\"(pending|in_progress|completed)\"\s*\}"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(source.startIndex..., in: source)
        let matches = expression.matches(in: source, range: range)
        let todos = matches.compactMap { match -> Todo? in
            guard let stepRange = Range(match.range(at: 1), in: source),
                let statusRange = Range(match.range(at: 2), in: source)
            else { return nil }
            let escaped = String(source[stepRange])
            let quoted = "\"" + escaped + "\""
            let content =
                ((try? JSONSerialization.jsonObject(
                    with: Data(quoted.utf8))) as? String) ?? escaped
            return Todo(content: content, status: String(source[statusRange]))
        }
        return todos.isEmpty ? nil : todos
    }

    private static func planFromItem(_ item: [String: Any]) -> [Todo]? {
        switch item["type"] as? String {
        case "function_call":
            guard item["name"] as? String == "update_plan" else { return nil }
            return planTodos(arguments: item["arguments"] as? String ?? "")
        case "custom_tool_call":
            let name = item["name"] as? String ?? ""
            let input = item["input"] as? String ?? ""
            if name == "update_plan" { return planTodos(arguments: input) }
            if name == "exec" { return embeddedPlanTodos(source: input) }
            return nil
        default:
            return nil
        }
    }

    private static func latestPlan(path: String, bytes: Int) -> [Todo]? {
        var latest: [Todo]?
        for obj in tailEntries(path: path, bytes: bytes) {
            guard let (type, payload) = record(obj) else { continue }
            if type == "event_msg", payload["type"] as? String == "task_started" { latest = nil }
            var item: [String: Any]?
            if type == "response_item" { item = payload }
            if type == "function_call" || type == "custom_tool_call" {
                item = payload
                item?["type"] = type
            }
            if let item, let plan = planFromItem(item) { latest = plan }
        }
        return latest
    }

    /// Parse the last `bytes` of a jsonl file (partial first line dropped).
    private static func tailEntries(path: String, bytes: Int) -> [[String: Any]] {
        readTail(path: path, bytes: bytes).entries
    }

    private static func readTail(path: String, bytes: Int) -> (entries: [[String: Any]], exceedsWindow: Bool) {
        guard let handle = FileHandle(forReadingAtPath: path) else { return ([], false) }
        defer { try? handle.close() }

        guard let size = try? handle.seekToEnd() else { return ([], false) }
        let offset = size > UInt64(bytes) ? size - UInt64(bytes) : 0
        do { try handle.seek(toOffset: offset) } catch { return ([], false) }
        guard let data = try? handle.read(upToCount: bytes) else { return ([], false) }

        // JSONL boundaries are ASCII bytes. Splitting a whole Unicode String
        // into graphemes and encoding it back into JSON was the hot path.
        var lines = data.split(separator: 10)
        let exceedsWindow = offset > 0 && !lines.isEmpty && lines.count == 1
        if offset > 0, !lines.isEmpty { lines.removeFirst() }
        let entries = lines.compactMap { line in
            (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any]
        }
        return (entries, exceedsWindow)
    }

    private static func run(_ path: String, _ arguments: [String]) -> String {
        let result = BoundedProcess.run(path, arguments)
        return result.succeeded ? result.output : ""
    }
}
