import Darwin
import Foundation

/// Reads Claude Code's live session registry and transcripts to enrich Claude
/// agents with titles, prompts, activity, and real status. Most sessions use
/// ~/.claude; CLAUDE_CONFIG_DIR sessions carry their own config root in Meta.
enum ClaudeSessions {

    struct Meta {
        let pid: Int32
        let sessionId: String
        let cwd: String
        let name: String?
        let status: String?  // "busy" | "idle"
        let statusUpdatedAt: Double?  // epoch ms
        let configDir: String
        var processStartUTC: String? = nil
    }

    struct TranscriptInfo: Equatable {
        var title: String?
        var lastPrompt: String?
        var lastMessage: String?  // the assistant's recent text, including an actionable question
        var activity: String?
        var model: String?
        var todos: [Todo] = []
        var subagents: [Subagent] = []
        var plan: String?  // markdown from the last ExitPlanMode call
        var question: PendingQuestion?  // pending AskUserQuestion, if any
    }

    static let defaultConfigDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude").path

    // MARK: - Session registry

    /// All live sessions keyed by pid. Files for dead pids may linger; the
    /// caller cross-checks against the process table.
    static func sessionsByPid() -> [Int32: Meta] {
        sessionsByPid(configDirs: [defaultConfigDir])
    }

    /// Read every config root used by the currently running Claude processes.
    /// The caller filters each result against that process's actual root, so a
    /// stale file in another root cannot attach to a recycled pid.
    static func sessionsByPid(configDirs: Set<String>) -> [Int32: Meta] {
        guard let starts = processStartsUTC() else { return [:] }
        return readRegistry(configDirs: configDirs, processStartsUTC: starts).sessions
    }

    struct RegistryRead {
        var sessions: [Int32: Meta]
        var outcome: ProviderReadResult.Outcome
        var reason: String?
    }

    /// Claude 2.1.263 writes procStart using LC_ALL=C and TZ=UTC. Do not compare
    /// that identity with a localized lstart string or a registration timestamp.
    /// Query only the relevant PIDs when the scanner already knows them.
    static func processStartsUTC(pids: [Int32]? = nil) -> [Int32: String]? {
        if pids?.isEmpty == true { return [:] }
        let selection = pids.map { ["-p", $0.map(String.init).joined(separator: ",")] } ?? ["-ax"]
        let query = BoundedProcess.run(
            "/usr/bin/env", ["LC_ALL=C", "TZ=UTC", "/bin/ps"] + selection + ["-o", "pid=,lstart="],
            timeout: 1, maximumBytes: 256 * 1024)
        return processStartsUTC(query: query, selectedPIDs: pids)
    }

    static func processStartsUTC(query: BoundedProcess.Result, selectedPIDs: [Int32]?) -> [Int32: String]? {
        guard query.succeeded else {
            // ps returns 1 when every selected process has just exited. That
            // is an empty observation, not a provider failure. EPERM and
            // helper failures must still remain unknown, never empty.
            if query.status == 1, !query.timedOut, !query.exceededOutputLimit,
                query.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                let selectedPIDs, !selectedPIDs.isEmpty,
                selectedPIDs.allSatisfy({ $0 > 0 && Darwin.kill($0, 0) != 0 && errno == ESRCH })
            {
                return [:]
            }
            return nil
        }
        var starts: [Int32: String] = [:]
        for line in query.output.split(separator: "\n") {
            let parts = line.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            if parts.count == 2, let pid = Int32(parts[0]), pid > 0 {
                starts[pid] = normalizedBirth(String(parts[1]))
            }
        }
        return starts
    }

    private static func normalizedBirth(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func readRegistry(
        configDirs: Set<String>, processStartsUTC: [Int32: String]? = nil,
        configDirsByPID: [Int32: String]? = nil
    ) -> RegistryRead {
        var result: [Int32: Meta] = [:]
        var incomplete = false
        var identityRejected = false
        for configDir in configDirs {
            let dir = configDir + "/sessions"
            guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir) else {
                incomplete = true; continue
            }

            for file in files where file.hasSuffix(".json") {
                // The official registry names files <pid>.json. Discard a
                // different root's copy before parsing or aggregating errors.
                if let configDirsByPID {
                    guard let pid = Int32(file.dropLast(5)), configDirsByPID[pid] == configDir else { continue }
                }
                guard let attributes = try? FileManager.default.attributesOfItem(atPath: dir + "/" + file),
                    attributes[.type] as? FileAttributeType == .typeRegular,
                    let handle = FileHandle(forReadingAtPath: dir + "/" + file)
                else { incomplete = true; continue }
                defer { try? handle.close() }
                // Read one extra byte so a valid JSON prefix cannot hide a
                // truncated/oversized registry entry. PID conversion must be
                // exact: NSNumber.int32Value silently wraps or truncates.
                let maximumBytes = 256 * 1024
                guard let data = try? handle.read(upToCount: maximumBytes + 1), data.count <= maximumBytes,
                    let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                    let pidNumber = obj["pid"] as? NSNumber,
                    CFGetTypeID(pidNumber) != CFBooleanGetTypeID(),
                    let pid = Int32(exactly: pidNumber.doubleValue), pid > 0,
                    let sessionId = obj["sessionId"] as? String,
                    !sessionId.isEmpty, sessionId.utf8.count <= 256,
                    sessionId != ".", sessionId != "..",
                    !sessionId.contains("/"), !sessionId.contains("\\"), !sessionId.contains("\0"),
                    let cwd = obj["cwd"] as? String
                else { incomplete = true; continue }
                if let configDirsByPID {
                    guard configDirsByPID[pid] == configDir, file == "\(pid).json" else { continue }
                }
                if let processStartsUTC {
                    // Files left by exited processes are not active sessions.
                    guard let actual = processStartsUTC[pid] else { continue }
                    guard let recorded = obj["procStart"] as? String, !actual.isEmpty,
                        normalizedBirth(recorded) == normalizedBirth(actual),
                        obj["pidDomain"] == nil || obj["pidDomain"] as? String == "darwin"
                    else {
                        incomplete = true
                        identityRejected = true
                        continue
                    }
                }
                result[pid] = Meta(
                    pid: pid,
                    sessionId: sessionId,
                    cwd: cwd,
                    name: obj["name"] as? String,
                    status: obj["status"] as? String,
                    statusUpdatedAt: (obj["statusUpdatedAt"] as? NSNumber)?.doubleValue
                        ?? ((try? FileManager.default.attributesOfItem(atPath: dir + "/" + file)[.modificationDate])
                        as? Date).map { $0.timeIntervalSince1970 * 1000 },
                    configDir: configDir,
                    processStartUTC: (obj["procStart"] as? String).map(normalizedBirth)
                )
            }
        }
        return .init(
            sessions: result,
            outcome: incomplete ? (result.isEmpty ? .failed : .partial) : (result.isEmpty ? .empty : .success),
            reason: identityRejected
                ? "Claude session registry process identity could not be verified"
                : incomplete ? "Claude session registry is unavailable or contains unreadable entries" : nil)
    }

    static func transcriptPath(for meta: Meta) -> String {
        meta.configDir + "/projects/\(projectDirName(for: meta.cwd))/\(meta.sessionId).jsonl"
    }

    /// Claude Code's own encoding of a project path into a directory name.
    ///
    /// It applies `/[^a-zA-Z0-9]/g → "-"` per UTF-16 code unit. Verified against
    /// the real CLI: a session in `/private/tmp/ai_probe_josé.test-dir` produced
    /// `-private-tmp-ai-probe-jos--test-dir` — the underscore, the `é` and the
    /// `.` each collapsing to a single dash.
    ///
    /// This used to test `isLetter || isNumber`, which is Unicode-wide: `é`,
    /// CJK and even `²` all pass and were kept verbatim. Any project path with a
    /// non-ASCII character therefore resolved to a directory that does not
    /// exist, and the card showed no title, prompt, activity, model or todos —
    /// permanently, with no error.
    ///
    /// Iterating UTF-16 code units rather than Characters matters: JavaScript's
    /// regex works per code unit, so a decomposed `é` (e + combining accent)
    /// yields `e-` there. Treating it as one Swift Character would produce `-`
    /// and diverge again.
    static func projectDirName(for cwd: String) -> String {
        var out = String.UnicodeScalarView()
        for unit in cwd.utf16 {
            let isASCIIAlphanumeric =
                (unit >= 48 && unit <= 57)  // 0-9
                || (unit >= 65 && unit <= 90)  // A-Z
                || (unit >= 97 && unit <= 122)  // a-z
            if isASCIIAlphanumeric, let scalar = Unicode.Scalar(unit) {
                out.append(scalar)
            } else {
                out.append("-")
            }
        }
        return String(out)
    }

    // MARK: - Task store (~/.claude/tasks/<sessionId>/<n>.json)

    /// The current task system. Each task is one JSON file:
    /// { id, subject, status: pending|in_progress|completed, ... }
    static func tasks(for meta: Meta) -> [Todo] {
        let dir = meta.configDir + "/tasks/" + meta.sessionId
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return [] }

        var items: [(order: Int, todo: Todo)] = []
        for file in files where file.hasSuffix(".json") && !file.hasPrefix(".") {
            guard let data = FileManager.default.contents(atPath: dir + "/" + file),
                let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                let subject = obj["subject"] as? String
            else { continue }
            let raw = obj["status"] as? String ?? "pending"
            if raw == "deleted" || raw == "cancelled" { continue }
            let status = ["completed", "in_progress"].contains(raw) ? raw : "pending"
            let order = Int((file as NSString).deletingPathExtension) ?? 0
            items.append((order, Todo(content: subject, status: status)))
        }
        return items.sorted { $0.order < $1.order }.map(\.todo)
    }

    // MARK: - Transcript tail parsing

    private static var infoCache: [String: (mtime: Date, info: TranscriptInfo)] = [:]
    private static let cacheLock = NSLock()

    static func tailInfo(path: String) -> TranscriptInfo {
        let mtime = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? nil

        cacheLock.lock()
        if let mtime, let cached = infoCache[path], cached.mtime == mtime {
            cacheLock.unlock()
            return cached.info
        }
        cacheLock.unlock()

        var info = TranscriptInfo()
        var pendingTools: [(id: String, description: String)] = []
        var resolvedToolIds = Set<String>()
        // Newest user text in the window; only consulted when the session's own
        // last-prompt record didn't make it into the window.
        var fallbackPrompt: String?
        var taskCalls: [(id: String, description: String, type: String?)] = []
        var questionCalls: [(id: String, question: PendingQuestion)] = []

        // A generous window so a pending tool_use (question/plan) survives even
        // in very active sessions where big tool results pile up after it.
        for obj in tailEntries(path: path, bytes: 512 * 1024) {
            switch obj["type"] as? String {
            case "ai-title":
                if let t = obj["aiTitle"] as? String, !t.isEmpty { info.title = t }
            case "last-prompt":
                if let p = obj["lastPrompt"] as? String, TaskPresentationResolver.substantive(p) != nil {
                    info.lastPrompt = p
                }
            case "assistant":
                if let message = obj["message"] as? [String: Any],
                    let model = message["model"] as? String, !model.isEmpty
                {
                    info.model = model
                }
                let assistantText = contentItems(obj)
                    .filter { $0["type"] as? String == "text" }
                    .compactMap { $0["text"] as? String }
                    .joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !assistantText.isEmpty { info.lastMessage = assistantText }
                for item in contentItems(obj) {
                    if item["type"] as? String == "tool_use",
                        let id = item["id"] as? String,
                        let name = item["name"] as? String
                    {
                        let input = item["input"] as? [String: Any] ?? [:]
                        pendingTools.append((id, describeTool(name: name, input: input)))
                        if name == "TodoWrite", let raw = input["todos"] as? [[String: Any]] {
                            info.todos = raw.compactMap { todo in
                                guard let content = todo["content"] as? String else { return nil }
                                return Todo(content: content, status: todo["status"] as? String ?? "pending")
                            }
                        }
                        if name == "Task" || name == "Agent" {
                            let description =
                                (input["description"] as? String)
                                ?? (input["prompt"] as? String).map { String($0.prefix(60)) }
                                ?? "Subagent"
                            taskCalls.append((id, description, input["subagent_type"] as? String))
                        }
                        if name == "ExitPlanMode", let plan = input["plan"] as? String, !plan.isEmpty {
                            info.plan = plan
                        }
                        if name == "AskUserQuestion",
                            let questions = input["questions"] as? [[String: Any]],
                            let first = questions.first
                        {
                            let prompt =
                                (first["question"] as? String)
                                ?? (first["header"] as? String) ?? "Choose an option"
                            let options = (first["options"] as? [[String: Any]] ?? [])
                                .compactMap { $0["label"] as? String }
                            if !options.isEmpty {
                                questionCalls.append(
                                    (
                                        id,
                                        PendingQuestion(
                                            prompt: prompt, options: options,
                                            multiSelect: first["multiSelect"] as? Bool ?? false)
                                    ))
                            }
                        }
                    }
                }
            case "user":
                for item in contentItems(obj) where item["type"] as? String == "tool_result" {
                    if let id = item["tool_use_id"] as? String { resolvedToolIds.insert(id) }
                }
                // Fallback prompt, used only if no last-prompt entry appears
                // anywhere in the window. Keeping the *newest* matters: the old
                // `info.lastPrompt == nil` guard made the first match win and
                // never be overwritten, so whenever a single turn produced more
                // than 512KB of tool results — routine on a large repo — the
                // card showed the oldest user message still in the window
                // instead of the most recent one.
                if obj["isMeta"] as? Bool != true,
                    let text = userText(obj), TaskPresentationResolver.substantive(text) != nil
                {
                    fallbackPrompt = text
                }
            default:
                break
            }
        }

        // A `last-prompt` entry is authoritative wherever it sits in the window;
        // the user-message fallback fills in only when none was present.
        if info.lastPrompt == nil { info.lastPrompt = fallbackPrompt }

        info.activity = pendingTools.last(where: { !resolvedToolIds.contains($0.id) })?.description
        // The most recent still-unanswered question. NOTE: Claude Code writes the
        // AskUserQuestion tool_use together with its result, so this is only
        // non-nil in the brief write gap — live questions come from the
        // PreToolUse hook (ApprovalCenter.questions), not the transcript.
        info.question = questionCalls.last(where: { !resolvedToolIds.contains($0.id) })?.question

        // Running subagents first, then the most recent finished ones.
        let running = taskCalls.filter { !resolvedToolIds.contains($0.id) }
        let finished = taskCalls.filter { resolvedToolIds.contains($0.id) }.suffix(2)
        info.subagents =
            (running.map { Subagent(description: $0.description, type: $0.type, done: false) }
                + finished.map { Subagent(description: $0.description, type: $0.type, done: true) })

        if let mtime {
            cacheLock.lock()
            infoCache[path] = (mtime, info)
            cacheLock.unlock()
        }
        return info
    }

    /// Recent plain-text conversation messages for the detail view, oldest first.
    static func recentMessages(path: String, limit: Int = 12) -> [ChatMessage] {
        var messages: [ChatMessage] = []
        var index = 0
        for obj in tailEntries(path: path, bytes: 384 * 1024) {
            switch obj["type"] as? String {
            case "user":
                guard obj["isMeta"] as? Bool != true, let text = userText(obj), !text.isEmpty else { continue }
                messages.append(ChatMessage(id: index, isUser: true, text: text))
                index += 1
            case "assistant":
                let texts = contentItems(obj)
                    .filter { $0["type"] as? String == "text" }
                    .compactMap { $0["text"] as? String }
                let joined = texts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !joined.isEmpty else { continue }
                // Consecutive assistant texts in one turn: merge into the last bubble.
                if let last = messages.last, !last.isUser {
                    messages[messages.count - 1] = ChatMessage(
                        id: last.id, isUser: false, text: last.text + "\n\n" + joined)
                } else {
                    messages.append(ChatMessage(id: index, isUser: false, text: joined))
                    index += 1
                }
            default:
                break
            }
        }
        return Array(messages.suffix(limit))
    }

    // MARK: - Helpers

    /// Parse the last `bytes` of a jsonl file into JSON objects (partial first line dropped).
    private static func tailEntries(path: String, bytes: Int) -> [[String: Any]] {
        guard let handle = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? handle.close() }

        let size = (try? handle.seekToEnd()) ?? 0
        let offset = size > UInt64(bytes) ? size - UInt64(bytes) : 0

        // The window's first line is only *partial* if the byte just before the
        // offset isn't a newline; when it aligns to a line boundary, dropping it
        // would lose a complete entry.
        var startsMidLine = false
        if offset > 0 {
            try? handle.seek(toOffset: offset - 1)
            startsMidLine = (try? handle.read(upToCount: 1))?.first != UInt8(ascii: "\n")
        }
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.read(upToCount: bytes) else { return [] }

        // Lossy on purpose — the window can begin mid-character. See TailRead.
        let lines = TailRead.lines(data, dropsFirstLine: startsMidLine)

        return lines.compactMap { line in
            (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
        }
    }

    private static func contentItems(_ entry: [String: Any]) -> [[String: Any]] {
        let message = entry["message"] as? [String: Any]
        return message?["content"] as? [[String: Any]] ?? []
    }

    private static func userText(_ entry: [String: Any]) -> String? {
        guard let message = entry["message"] as? [String: Any] else { return nil }
        if let text = message["content"] as? String { return text }
        let texts = contentItems(entry)
            .filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }
        return texts.isEmpty ? nil : texts.joined(separator: "\n")
    }

    private static func describeTool(name: String, input: [String: Any]) -> String {
        func fileBase() -> String {
            ((input["file_path"] as? String ?? input["path"] as? String ?? "") as NSString).lastPathComponent
        }
        switch name {
        case "Edit", "Write", "MultiEdit", "NotebookEdit":
            let base = fileBase()
            return base.isEmpty ? "Writing files" : "Writing \(base)"
        case "Read":
            let base = fileBase()
            return base.isEmpty ? "Reading files" : "Reading \(base)"
        case "Bash":
            return input["description"] as? String ?? "Running a command"
        case "Grep", "Glob":
            return "Searching the codebase"
        case "Task", "Agent":
            return "Running a subagent"
        case "WebFetch", "WebSearch":
            return "Searching the web"
        case "TodoWrite", "TaskCreate", "TaskUpdate":
            return "Updating tasks"
        default:
            if name.hasPrefix("mcp__"), let tool = name.components(separatedBy: "__").last {
                return "Using \(tool.replacingOccurrences(of: "_", with: " "))"
            }
            return "Using \(name)"
        }
    }
}
