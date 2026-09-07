import Foundation

/// Read-only projection of Kimi Code's session index, state and main-agent wire.
/// `$KIMI_CODE_HOME` is resolved from the target process by AgentMonitor; no
/// settings are changed and unknown wire events are ignored.
enum KimiSessions {
    struct Info {
        let sessionID: String
        let turnID: String?
        let transcriptPath: String
        let title: String?
        let cwd: String?
        let status: AgentStatus
        let lastPrompt: String?
        let lastMessage: String?
        let activity: String?
        let model: String?
        let updatedAt: Date
        let observation: ObservationHealth
    }

    private struct Candidate {
        let id: String
        let directory: String
        let cwd: String?
        let title: String?
        let lastPrompt: String?
        let createdAt: Date?
        let updatedAt: Date
    }

    static let source = "Kimi Code wire 1.5"
    private struct CachedInfo {
        let modified: Date
        let size: UInt64
        let metadataDate: Date
        let title: String?
        let info: Info
    }
    private static let cacheLock = NSLock()
    private static var cache: [String: CachedInfo] = [:]

    struct Batch {
        var sessions: [Info] = []
        var outcome: ProviderReadResult.Outcome = .empty
        var reason: String?
    }

    /// Lifecycle leases survive Kimi's short-lived wire file descriptors. They
    /// prove ownership only; all task state and progress still come from wire.
    static func read(
        processID: Int32, processStartedAt: String?, cwd: String?, args: String,
        dataRoot: String?, openWirePaths: [String] = [], observerRoot: String? = nil, now: Date = Date()
    ) -> Batch {
        let events =
            processStartedAt.map {
                LocalHookEvents.read(provider: "kimi", pid: processID, startedAt: $0, root: observerRoot, now: now)
            } ?? []
        guard !events.isEmpty else {
            guard let legacy = info(cwd: cwd, args: args, dataRoot: dataRoot, openWirePaths: openWirePaths) else {
                return Batch(outcome: .failed, reason: "No process-owned Kimi session could be verified")
            }
            return Batch(
                sessions: [legacy],
                outcome: legacy.observation.mode == .rich
                    ? .success
                    : legacy.observation.mode == .incompatible ? .incompatible : .failed,
                reason: legacy.observation.reason)
        }
        var result = Batch()
        var roots: [String: [Candidate]] = [:]
        for (_, group) in Dictionary(grouping: events, by: \.sessionID).sorted(by: { $0.key < $1.key }) {
            let ordered = group.sorted {
                if $0.observedAt != $1.observedAt { return $0.observedAt < $1.observedAt }
                return $0.eventName != "SessionEnd" && $1.eventName == "SessionEnd"
            }
            // A delayed heartbeat cannot undo close. Only a subsequent explicit
            // start (create/resume) can reopen this PID/session incarnation.
            var lease: LocalHookEvents.Event?
            var closed = false
            for event in ordered {
                switch event.eventName {
                case "SessionEnd": closed = true; lease = nil
                case "SessionStart": closed = false; lease = event
                case "SessionHeartbeat": if !closed { lease = event }
                default: break
                }
            }
            if closed { continue }
            guard let lease, lease.clientType == "kimi_code_cli",
                let root = lease.providerDataRoot, validAbsolutePath(root),
                let eventCwd = lease.cwd, validAbsolutePath(eventCwd),
                dataRoot.map({ resolvedProcessRoot($0, cwd: cwd) == canonicalPath(root) }) ?? true,
                Set(group.compactMap(\.providerDataRoot).map(LocalSessionJSON.standardPath)).count == 1
            else { result.reason = "Kimi lifecycle identity or data root is incompatible"; continue }
            if roots[root] == nil { roots[root] = discover(root: root) }
            let matches = (roots[root] ?? []).filter {
                $0.id == lease.sessionID
                    && $0.cwd.map(LocalSessionJSON.standardPath) == LocalSessionJSON.standardPath(eventCwd)
                    && boundedObject($0.directory + "/state.json")?["id"] as? String == lease.sessionID
            }
            guard matches.count == 1, let candidate = matches.first else {
                result.reason = "Kimi lifecycle session has no matching readable main wire"; continue
            }
            let info = parse(candidate)
            if info.observation.mode != .rich { result.reason = info.observation.reason }
            if now.timeIntervalSince(lease.date) > 150 {
                result.reason = "Kimi session lifecycle heartbeat is stale"
                // Keep source state, but never renew it with the observer clock.
                result.sessions.append(
                    Info(
                        sessionID: info.sessionID, turnID: info.turnID, transcriptPath: info.transcriptPath,
                        title: info.title, cwd: info.cwd, status: info.status, lastPrompt: info.lastPrompt,
                        lastMessage: info.lastMessage, activity: info.activity, model: info.model,
                        updatedAt: info.updatedAt,
                        observation: .init(
                            mode: .stale, updatedAt: info.observation.updatedAt, source: source,
                            reason: result.reason, authority: .officialLocalStore)))
            } else {
                result.sessions.append(info)
            }
        }
        if result.reason == nil {
            result.outcome = result.sessions.isEmpty ? .empty : .success
        } else if result.sessions.contains(where: { $0.observation.mode == .rich }) {
            result.outcome = .partial
        } else if !result.sessions.isEmpty && result.sessions.allSatisfy({ $0.observation.mode == .incompatible }) {
            result.outcome = .incompatible
        } else {
            result.outcome = .failed
        }
        return result
    }

    static func returnTarget(terminalApp: String?) -> ReturnTarget {
        switch terminalApp {
        case "Terminal": return .application(bundleIdentifier: "com.apple.Terminal", name: "Terminal")
        case "iTerm": return .application(bundleIdentifier: "com.googlecode.iterm2", name: "iTerm")
        default: return .unavailable(reason: "Kimi session cannot be selected precisely")
        }
    }

    private static func validAbsolutePath(_ path: String) -> Bool {
        path.hasPrefix("/") && !path.contains("\0") && path.utf8.count <= 4096
    }

    private static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }

    private static func resolvedProcessRoot(_ path: String, cwd: String?) -> String? {
        guard !path.contains("\0"), path.utf8.count <= 4096 else { return nil }
        let expanded = (path as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") { return canonicalPath(expanded) }
        guard let cwd, validAbsolutePath(cwd) else { return nil }
        return canonicalPath(cwd + "/" + expanded)
    }

    static func info(cwd: String?, args: String, dataRoot: String?, openWirePaths: [String] = []) -> Info? {
        let root = LocalSessionJSON.standardPath(
            LocalSessionJSON.compact(dataRoot) ?? NSHomeDirectory() + "/.kimi-code")
        let requestedID = LocalSessionJSON.argumentValue(args, names: ["--session", "-S"])
        let normalizedCwd = cwd.map(LocalSessionJSON.standardPath)
        let candidates = discover(root: root)
        let owned = Set(openWirePaths.map(LocalSessionJSON.standardPath))
        let matches = candidates.filter { candidate in
            guard let candidateCwd = candidate.cwd, let normalizedCwd,
                LocalSessionJSON.standardPath(candidateCwd) == normalizedCwd
            else { return false }
            // A cwd or the most recent index row is not session ownership.
            // An open main-agent wire takes precedence after a TUI switches sessions.
            if !owned.isEmpty {
                return owned.contains(LocalSessionJSON.standardPath(candidate.directory + "/agents/main/wire.jsonl"))
            }
            return requestedID == candidate.id
        }
        guard matches.count == 1, let selected = matches.first else { return nil }
        return parse(selected)
    }

    static func recentMessages(path: String, limit: Int = 12) -> [ChatMessage] {
        var messages: [(Bool, String)] = []
        var assistantBuffer = ""

        func flushAssistant() {
            guard let text = LocalSessionJSON.compact(assistantBuffer) else {
                assistantBuffer = ""
                return
            }
            append(text, isUser: false, to: &messages)
            assistantBuffer = ""
        }

        for object in LocalSessionJSON.tailObjects(path: path) {
            let type = object["type"] as? String
            if type == "turn.prompt" {
                flushAssistant()
                append(LocalSessionJSON.text(object["input"]), isUser: true, to: &messages)
            } else if type == "context.append_message",
                let message = object["message"] as? LocalSessionJSON.Object,
                let role = message["role"] as? String
            {
                if role == "user" {
                    flushAssistant()
                    append(LocalSessionJSON.text(message["content"]), isUser: true, to: &messages)
                } else if role == "assistant" {
                    flushAssistant()
                    append(LocalSessionJSON.text(message["content"]), isUser: false, to: &messages)
                }
            } else if type == "context.append_loop_event",
                let event = object["event"] as? LocalSessionJSON.Object,
                let eventType = event["type"] as? String
            {
                switch eventType {
                case "step.begin":
                    flushAssistant()
                case "content.part":
                    if let part = event["part"] as? LocalSessionJSON.Object,
                        part["type"] as? String == "text",
                        let text = part["text"] as? String
                    {
                        assistantBuffer += text
                    }
                case "step.end":
                    flushAssistant()
                default:
                    continue
                }
            }
        }
        flushAssistant()
        return messages.suffix(max(1, limit)).enumerated().map {
            ChatMessage(id: $0.offset, isUser: $0.element.0, text: $0.element.1)
        }
    }

    private static func discover(root: String) -> [Candidate] {
        let sessionsRoot = LocalSessionJSON.standardPath(root + "/sessions")
        let indexPath = root + "/session_index.jsonl"
        var byID: [String: Candidate] = [:]
        var deleted = Set<String>()

        for entry in LocalSessionJSON.tailObjects(path: indexPath, maxBytes: 2 * 1024 * 1024) {
            guard let id = entry["sessionId"] as? String else { continue }
            if entry["deleted"] as? Bool == true {
                deleted.insert(id)
                byID.removeValue(forKey: id)
                continue
            }
            guard let rawDirectory = entry["sessionDir"] as? String
            else { continue }
            deleted.remove(id)
            let directory = resolve(rawDirectory, relativeTo: root)
            guard valid(directory: directory, id: id, sessionsRoot: sessionsRoot),
                let candidate = candidate(
                    id: id, directory: directory,
                    indexCwd: entry["workDir"] as? String)
            else { continue }
            byID[id] = candidate
        }

        // A missing or stale index must not hide an otherwise valid session.
        // Scan exactly the documented two directory levels, not arbitrary files.
        let buckets = childDirectories(sessionsRoot)
        var remaining = 4096
        for bucket in buckets {
            for directory in childDirectories(bucket) {
                guard remaining > 0 else { return Array(byID.values) }
                remaining -= 1
                let id = (directory as NSString).lastPathComponent
                guard byID[id] == nil, !deleted.contains(id),
                    let value = candidate(id: id, directory: directory, indexCwd: nil)
                else { continue }
                byID[id] = value
            }
        }

        return Array(byID.values)
    }

    private static func candidate(id: String, directory: String, indexCwd: String?) -> Candidate? {
        let statePath = directory + "/state.json"
        guard let state = boundedObject(statePath),
            state["archived"] as? Bool != true,
            state["id"] == nil || state["id"] as? String == id
        else { return nil }
        let wirePath = directory + "/agents/main/wire.jsonl"
        guard FileManager.default.fileExists(atPath: wirePath) else { return nil }
        let wireDate = LocalSessionJSON.fileDate(wirePath) ?? .distantPast
        let updated = LocalSessionJSON.date(state["updatedAt"]) ?? wireDate
        return Candidate(
            id: id,
            directory: directory,
            cwd: (state["cwd"] as? String) ?? (state["workDir"] as? String) ?? indexCwd,
            title: LocalSessionJSON.compact(state["title"] as? String),
            lastPrompt: LocalSessionJSON.compact(state["lastPrompt"] as? String),
            createdAt: LocalSessionJSON.date(state["createdAt"]),
            updatedAt: max(updated, wireDate)
        )
    }

    private static func parse(_ candidate: Candidate) -> Info {
        let path = candidate.directory + "/agents/main/wire.jsonl"
        let modified = LocalSessionJSON.fileDate(path) ?? candidate.updatedAt
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.uint64Value ?? 0
        cacheLock.lock()
        let cached = cache[path]
        cacheLock.unlock()
        if let cached, cached.modified == modified, cached.size == size,
            cached.metadataDate == candidate.updatedAt, cached.title == candidate.title
        {
            return cached.info
        }
        var lastPrompt = candidate.lastPrompt
        var lastMessage: String?
        var assistantBuffer = ""
        var openStep = false
        var activeTools: [String: String] = [:]
        var model: String?
        var eventDate: Date?
        var turnID: String?
        var outcome: AgentStatus?
        let records = wireRecords(path)
        let version = records?.first?["protocol_version"] as? String
        let compatible = records?.first?["type"] as? String == "metadata" && version == "1.5"

        func flushAssistant() {
            if let text = LocalSessionJSON.compact(assistantBuffer) { lastMessage = text }
            assistantBuffer = ""
        }

        for object in compatible ? (records ?? []) : [] {
            if let agentID = object["agentId"] as? String, agentID != "main" { continue }
            let type = object["type"] as? String
            eventDate = LocalSessionJSON.date(object["time"]) ?? eventDate
            switch type {
            case "turn.prompt":
                flushAssistant()
                if let prompt = LocalSessionJSON.text(object["input"]),
                    TaskPresentationResolver.substantive(prompt) != nil
                {
                    lastPrompt = prompt
                }
                openStep = true
                turnID = nil
                outcome = nil
                activeTools.removeAll()
            case "context.append_message":
                guard let message = object["message"] as? LocalSessionJSON.Object,
                    let role = message["role"] as? String
                else { continue }
                if role == "user" {
                    if let prompt = LocalSessionJSON.text(message["content"]),
                        TaskPresentationResolver.substantive(prompt) != nil
                    {
                        lastPrompt = prompt
                    }
                } else if role == "assistant" {
                    lastMessage = LocalSessionJSON.text(message["content"]) ?? lastMessage
                }
            case "context.append_loop_event":
                guard let event = object["event"] as? LocalSessionJSON.Object,
                    let eventType = event["type"] as? String
                else { continue }
                switch eventType {
                case "step.begin":
                    flushAssistant()
                    openStep = true
                    turnID = identifier(event["turnId"]) ?? turnID
                    outcome = nil
                case "content.part":
                    if let part = event["part"] as? LocalSessionJSON.Object,
                        part["type"] as? String == "text",
                        let text = part["text"] as? String
                    {
                        assistantBuffer += text
                    }
                case "tool.call":
                    if let id = event["toolCallId"] as? String,
                        let name = event["name"] as? String
                    {
                        activeTools[id] = name
                    }
                case "tool.result":
                    if let id = event["toolCallId"] as? String { activeTools.removeValue(forKey: id) }
                case "step.end":
                    flushAssistant()
                    // A step boundary can be followed by another tool/step.
                    // Only turn.ended supplies a terminal result.
                    activeTools.removeAll()
                default:
                    continue
                }
            case "llm.request":
                model =
                    (object["model"] as? String)
                    ?? ((object["request"] as? LocalSessionJSON.Object)?["model"] as? String)
                    ?? model
            case "turn.ended":
                guard let endedID = identifier(object["turnId"]),
                    turnID == endedID || (openStep && turnID == nil)
                else { continue }
                turnID = endedID
                flushAssistant()
                openStep = false
                activeTools.removeAll()
                switch object["reason"] as? String {
                case "completed": outcome = object["error"] == nil ? .completed : .failed
                case "cancelled": outcome = .stopped
                case "failed", "blocked": outcome = .failed
                default: outcome = nil
                }
            case "context.clear", "context.undo":
                // Do not reuse task/result evidence across rewritten context.
                lastPrompt = nil
                lastMessage = nil
                assistantBuffer = ""
                openStep = false
                turnID = nil
                outcome = nil
                activeTools.removeAll()
            default:
                continue
            }
        }
        flushAssistant()

        let updatedAt = eventDate ?? max(candidate.updatedAt, modified)
        let status: AgentStatus
        if openStep || !activeTools.isEmpty {
            status = .working
        } else {
            status = outcome ?? .idle
        }
        let activity: String?
        if let tool = activeTools.values.first {
            activity = "Running \(tool)"
        } else if status == .working {
            activity = "Thinking…"
        } else {
            activity = nil
        }

        let info = Info(
            sessionID: candidate.id,
            turnID: turnID,
            transcriptPath: path,
            title: candidate.title,
            cwd: candidate.cwd,
            status: status,
            lastPrompt: lastPrompt,
            lastMessage: lastMessage,
            activity: activity,
            model: model,
            updatedAt: updatedAt,
            observation: compatible
                ? .rich(source, updatedAt: updatedAt)
                : .init(
                    mode: records == nil ? .stale : .incompatible,
                    updatedAt: modified, source: source,
                    reason: records == nil
                        ? "Kimi wire is unreadable, damaged or exceeds the read budget"
                        : "Unsupported Kimi wire version; expected 1.5")
        )
        if compatible {
            cacheLock.lock()
            if cache.count >= 128 { cache.removeAll(keepingCapacity: true) }
            cache[path] = CachedInfo(
                modified: modified, size: size, metadataDate: candidate.updatedAt, title: candidate.title, info: info)
            cacheLock.unlock()
        }
        return info
    }

    private static func identifier(_ value: Any?) -> String? {
        if let value = value as? String, let number = Int(value), number >= 0 { return String(number) }
        if let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
            value.doubleValue >= 0, value.doubleValue < Double(Int.max),
            value.doubleValue.rounded() == value.doubleValue
        {
            return String(value.intValue)
        }
        return nil
    }

    private static func boundedObject(_ path: String) -> [String: Any]? {
        guard let data = boundedData(path, limit: 256 * 1024) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func boundedData(_ path: String, limit: Int) -> Data? {
        guard let file = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? file.close() }
        guard let data = try? file.read(upToCount: limit + 1), data.count <= limit else { return nil }
        return data
    }

    private static func wireRecords(_ path: String) -> [[String: Any]]? {
        guard let data = boundedData(path, limit: 4 * 1024 * 1024),
            let text = String(data: data, encoding: .utf8), text.hasSuffix("\n")
        else { return nil }
        var records: [[String: Any]] = []
        for line in text.split(separator: "\n") {
            guard let record = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                records.count < 16_384
            else { return nil }
            records.append(record)
        }
        return records
    }

    private static func resolve(_ path: String, relativeTo root: String) -> String {
        if path.hasPrefix("/") || path.hasPrefix("~") {
            return LocalSessionJSON.standardPath(path)
        }
        return LocalSessionJSON.standardPath(root + "/" + path)
    }

    private static func valid(directory: String, id: String, sessionsRoot: String) -> Bool {
        directory.hasPrefix(sessionsRoot + "/")
            && (directory as NSString).lastPathComponent == id
    }

    private static func childDirectories(_ path: String) -> [String] {
        let keys: [URLResourceKey] = [.isDirectoryKey]
        let urls =
            (try? FileManager.default.contentsOfDirectory(
                at: URL(fileURLWithPath: path),
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles]
            )) ?? []
        guard urls.count <= 4096 else { return [] }
        return urls.compactMap { url in
            (try? url.resourceValues(forKeys: Set(keys)).isDirectory) == true ? url.path : nil
        }
    }

    private static func append(
        _ text: String?, isUser: Bool,
        to messages: inout [(Bool, String)]
    ) {
        guard let text else { return }
        if let last = messages.last, last.0 == isUser, last.1 == text { return }
        messages.append((isUser, text))
    }
}
