import CryptoKit
import Foundation
import SQLite3

/// Read-only projection of Cursor Agent's local CLI transcripts.
///
/// Cursor writes a human-readable JSONL stream below
/// `<data>/projects/<workspace>/agent-transcripts/<chat>/<chat>.jsonl` and
/// keeps the chat name/model in `<config>/chats/<workspace hash>/<chat>`.
/// LoopFwd observes those files only; it never resumes a chat or writes Cursor's
/// private SQLite store.
enum CursorSessions {
    struct Info {
        let sessionID: String
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
        let path: String
        let modified: Date
        let title: String?
        let model: String?
        let fileID: UInt64
        let size: UInt64
    }

    private struct Snapshot {
        let lastPrompt: String?
        let lastMessage: String?
        let model: String?
        let readable: Bool
    }

    private struct SnapshotCache {
        let modified: Date
        let fileID: UInt64
        let size: UInt64
        let snapshot: Snapshot
    }

    private static let lock = NSLock()
    private static var snapshotCache: [String: SnapshotCache] = [:]

    static func info(
        cwd: String?, args: String, cpu: Double,
        configDirectory: String?, xdgConfigHome: String?, dataDirectory: String? = nil,
        openChatPaths: [String] = [], processID: Int32? = nil, processStartedAt: String? = nil,
        observerRoot: String? = nil, now: Date = Date()
    ) -> Info? {
        guard let cwd else { return nil }
        let normalizedCwd = LocalSessionJSON.standardPath(cwd)
        let config = configRoot(
            cwd: normalizedCwd,
            configDirectory: configDirectory,
            xdgConfigHome: xdgConfigHome
        )
        // Cursor's data override is independent of its config/XDG override.
        let data = providerDirectory(dataDirectory, cwd: normalizedCwd) ?? NSHomeDirectory() + "/.cursor"
        let requestedID = LocalSessionJSON.argumentValue(args, names: ["--resume", "-r"])
        let transcripts = LocalSessionJSON.standardPath(
            data + "/projects/" + projectSlug(normalizedCwd) + "/agent-transcripts")
        let projects = LocalSessionJSON.standardPath(data + "/projects")
        let events: [LocalHookEvents.Event]
        if let processID, let processStartedAt {
            events = LocalHookEvents.read(
                provider: "cursor", pid: processID, startedAt: processStartedAt, root: observerRoot, now: now)
        } else {
            events = []
        }
        let owned = events.filter {
            UUID(uuidString: $0.sessionID) != nil && $0.cwd.map(LocalSessionJSON.standardPath) == normalizedCwd
        }
        let hookIDs = Set(owned.map { $0.sessionID.lowercased() })
        let held = Set(
            openChatPaths.map(LocalSessionJSON.standardPath).filter { path in
                let url = URL(fileURLWithPath: path), id = url.deletingLastPathComponent().lastPathComponent
                let workspace = url.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                return UUID(uuidString: id) != nil && url.lastPathComponent == id + ".jsonl"
                    && url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent
                        == "agent-transcripts"
                    && (workspace.path == projects || workspace.deletingLastPathComponent().path == projects)
            })
        let selectedPath: String?
        if held.count == 1 {
            guard let path = held.first,
                URL(fileURLWithPath: path).deletingLastPathComponent().deletingLastPathComponent().path == transcripts
            else { return nil }
            // An open file identifies the live process more directly than a
            // resume argument left over before the user switched conversations.
            selectedPath = path
        } else if !held.isEmpty {
            return nil
        } else if hookIDs.count == 1, let id = hookIDs.first {
            // The observer is tied to the real CLI PID and its birth identity.
            // It can locate a writer that closes its file between updates.
            let expected = LocalSessionJSON.standardPath(transcripts + "/" + id + "/" + id + ".jsonl")
            guard
                owned.allSatisfy({
                    $0.transcriptPath.map(LocalSessionJSON.standardPath).map { $0 == expected } ?? true
                })
            else { return nil }
            selectedPath = expected
        } else if !hookIDs.isEmpty {
            return nil
        } else if let requestedID, UUID(uuidString: requestedID) != nil {
            let id = requestedID.lowercased()
            selectedPath = transcripts + "/" + id + "/" + id + ".jsonl"
        } else {
            selectedPath = nil
        }
        guard let selectedPath, let selected = candidate(path: selectedPath, config: config, cwd: normalizedCwd) else {
            return nil
        }

        let snapshot = parse(selected)
        // These are historical messages, not the headless stream-json protocol.
        // Neither CPU, assistant output nor an unverified turn_ended marker is
        // authority for Working, attention or successful completion.
        var observation = ObservationHealth.processOnly(
            "Cursor local transcript", reason: "Historical transcript; live Cursor task state is unavailable")
        observation.updatedAt = selected.modified
        if !snapshot.readable, selected.size > 0 {
            observation.mode = .stale
            observation.reason = "Cursor transcript has no readable conversation records"
        }
        let matching = owned.filter {
            $0.sessionID.lowercased() == selected.id.lowercased()
                && ($0.transcriptPath.map(LocalSessionJSON.standardPath).map { $0 == selected.path } ?? true)
        }
        let progress = snapshot.readable ? hookProgress(matching, now: now) : nil
        return Info(
            sessionID: selected.id.lowercased(),
            transcriptPath: selected.path,
            title: selected.title,
            cwd: normalizedCwd,
            status: progress?.status ?? .idle,
            lastPrompt: snapshot.lastPrompt,
            lastMessage: snapshot.lastMessage,
            activity: progress?.activity,
            model: snapshot.model ?? selected.model,
            updatedAt: progress?.observation.updatedAt ?? selected.modified,
            observation: progress?.observation ?? observation
        )
    }

    /// Cursor emits thought/response callbacks asynchronously. A pending prompt
    /// is not active, and a stop/response barrier closes that generation even
    /// when its thought callback arrives later. Stop may schedule a follow-up;
    /// this observer therefore does not assert completion or attention.
    private static func hookProgress(_ events: [LocalHookEvents.Event], now: Date) -> LocalHookEvents.Progress? {
        guard let latest = events.last else { return nil }
        let source = "Cursor CLI Hook observer schema 1 (arrival time)"
        func result(_ reason: String, mode: ObservationMode = .stale) -> LocalHookEvents.Progress {
            .init(
                status: .idle, activity: nil,
                observation: .init(
                    mode: mode, updatedAt: latest.date, source: source,
                    reason: reason, authority: .versionedObserver))
        }
        guard events.allSatisfy({ $0.providerVersion == "2026.09.02-c22c1a3" }) else {
            return result("Cursor Hook version is not supported", mode: .incompatible)
        }
        if now.timeIntervalSince(latest.date) > 180 {
            return result("Cursor Hook data is stale; session identity is retained")
        }
        let closing = Set(
            events.filter { ["stop", "afterAgentResponse"].contains($0.eventName) }.compactMap(\.generationID))
        if events.contains(where: { $0.eventName == "sessionEnd" }) {
            return result("Cursor session ended; current execution is not confirmed")
        }
        let thoughts = events.filter {
            $0.eventName == "afterAgentThought" && $0.hasModelContent == true
                && ($0.generationID.map { !closing.contains($0) } ?? false)
                && now.timeIntervalSince($0.date) <= 180
        }
        guard Set(thoughts.compactMap(\.generationID)).count <= 1 else {
            return result("Cursor generation order is ambiguous")
        }
        guard let progress = thoughts.last else {
            return result("Cursor event received; running or final result is not confirmed")
        }
        // Thought completion confirms recent model progress, not a busy/idle
        // API. Keep that distinction visible; do not promote it to rich busy.
        return .init(
            status: .idle, activity: "Recent model progress",
            observation: .init(
                mode: .processOnly, updatedAt: progress.date, source: source,
                reason: "Recent model output; current execution is not confirmed", authority: .versionedObserver))
    }

    static func recentMessages(path: String, limit: Int = 12) -> [ChatMessage] {
        var messages: [(Bool, String)] = []
        for object in LocalSessionJSON.tailObjects(path: path) {
            guard let role = object["role"] as? String,
                let message = object["message"] as? LocalSessionJSON.Object
            else { continue }
            if role == "user" {
                append(cleanUserPrompt(visibleText(message["content"])), isUser: true, to: &messages)
            } else if role == "assistant" {
                append(visibleText(message["content"]), isUser: false, to: &messages)
            }
        }
        return messages.suffix(max(1, limit)).enumerated().map {
            ChatMessage(id: $0.offset, isUser: $0.element.0, text: $0.element.1)
        }
    }

    private static func configRoot(
        cwd: String, configDirectory: String?,
        xdgConfigHome: String?
    ) -> String {
        if let explicit = providerDirectory(configDirectory, cwd: cwd) {
            return explicit
        }
        if let xdg = providerDirectory(xdgConfigHome, cwd: cwd) {
            return xdg + "/cursor"
        }
        return NSHomeDirectory() + "/.cursor"
    }

    private static func candidate(path: String, config: String, cwd: String) -> Candidate? {
        let url = URL(fileURLWithPath: path)
        guard LocalSessionJSON.standardPath(url.resolvingSymlinksInPath().path) == LocalSessionJSON.standardPath(path),
            let attributes = try? FileManager.default.attributesOfItem(atPath: path),
            attributes[.type] as? FileAttributeType == .typeRegular,
            let modified = attributes[.modificationDate] as? Date
        else { return nil }
        let id = url.deletingLastPathComponent().lastPathComponent
        let metadata = cursorStoreMetadata(path: metadataPath(config: config, cwd: cwd, id: id)).flatMap { object in
            // A copied or stale store must not rename a different conversation.
            (object["agentId"] as? String)?.lowercased() == id.lowercased() ? object : nil
        }
        return Candidate(
            id: id, path: path, modified: modified,
            title: LocalSessionJSON.compact(metadata?["name"] as? String),
            model: LocalSessionJSON.compact(metadata?["lastUsedModel"] as? String),
            fileID: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0,
            size: (attributes[.size] as? NSNumber)?.uint64Value ?? 0)
    }

    private static func parse(_ candidate: Candidate) -> Snapshot {
        lock.lock()
        if let cached = snapshotCache[candidate.path], cached.modified == candidate.modified,
            cached.fileID == candidate.fileID, cached.size == candidate.size
        {
            lock.unlock()
            return cached.snapshot
        }
        lock.unlock()

        var lastPrompt: String?
        var lastMessage: String?
        var model: String?
        var readable = false

        for object in LocalSessionJSON.tailObjects(path: candidate.path) {
            guard let role = object["role"] as? String,
                let message = object["message"] as? LocalSessionJSON.Object
            else { continue }
            model = LocalSessionJSON.compact(message["model"] as? String) ?? model
            switch role {
            case "user":
                readable = true
                if let prompt = cleanUserPrompt(visibleText(message["content"])) {
                    lastPrompt = prompt
                }
            case "assistant":
                readable = true
                lastMessage = visibleText(message["content"]) ?? lastMessage
            default:
                continue
            }
        }

        let snapshot = Snapshot(
            lastPrompt: lastPrompt,
            lastMessage: lastMessage,
            model: model, readable: readable
        )
        lock.lock()
        if snapshotCache.count >= 128 { snapshotCache.removeAll() }
        snapshotCache[candidate.path] = SnapshotCache(
            modified: candidate.modified, fileID: candidate.fileID, size: candidate.size, snapshot: snapshot)
        lock.unlock()
        return snapshot
    }

    private static func visibleText(_ value: Any?) -> String? {
        if let text = value as? String { return LocalSessionJSON.compact(text) }
        guard let parts = value as? [Any] else { return nil }
        let pieces = parts.compactMap { value -> String? in
            guard let part = value as? LocalSessionJSON.Object,
                part["type"] as? String == "text"
            else { return nil }
            return LocalSessionJSON.compact(part["text"] as? String)
        }
        return LocalSessionJSON.compact(pieces.joined(separator: "\n"))
    }

    /// Cursor surrounds the human input with provider-generated XML context.
    /// When `<user_query>` is present it is the only authoritative prompt.
    private static func cleanUserPrompt(_ value: String?) -> String? {
        guard let value else { return nil }
        let pattern = #"<user_query>([\s\S]*?)</user_query>"#
        guard
            let expression = try? NSRegularExpression(
                pattern: pattern, options: [.caseInsensitive])
        else {
            return LocalSessionJSON.compact(value)
        }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        let matches = expression.matches(in: value, range: range)
        if !matches.isEmpty {
            let queries = matches.compactMap { match -> String? in
                guard match.numberOfRanges > 1,
                    let range = Range(match.range(at: 1), in: value)
                else { return nil }
                return LocalSessionJSON.compact(String(value[range]))
            }
            return LocalSessionJSON.compact(queries.joined(separator: "\n"))
        }
        return LocalSessionJSON.compact(value)
    }

    static func metadataPath(config: String, cwd: String, id: String) -> String {
        // This is Cursor's workspace addressing scheme, not a security hash.
        let workspace = Insecure.MD5.hash(data: Data(cwd.utf8)).map { String(format: "%02x", $0) }.joined()
        return config + "/chats/" + workspace + "/" + id + "/store.db"
    }

    private static func cursorStoreMetadata(path: String) -> LocalSessionJSON.Object? {
        let url = URL(fileURLWithPath: path)
        guard LocalSessionJSON.standardPath(url.resolvingSymlinksInPath().path) == LocalSessionJSON.standardPath(path),
            let attributes = try? FileManager.default.attributesOfItem(atPath: path),
            attributes[.type] as? FileAttributeType == .typeRegular
        else { return nil }
        var database: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(path, &database, flags, nil) == SQLITE_OK,
            let database
        else {
            if let database { sqlite3_close(database) }
            return nil
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 75)

        var statement: OpaquePointer?
        guard
            sqlite3_prepare_v2(
                database, "SELECT value FROM meta WHERE key='0' AND length(value)<=65536", -1, &statement, nil
            ) == SQLITE_OK, let statement
        else { return nil }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }

        let data: Data?
        if sqlite3_column_type(statement, 0) == SQLITE_BLOB,
            let bytes = sqlite3_column_blob(statement, 0)
        {
            data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
        } else if let text = sqlite3_column_text(statement, 0) {
            let raw = String(cString: text)
            data = raw.first == "{" ? Data(raw.utf8) : dataFromHex(raw)
        } else {
            data = nil
        }
        guard let data else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? LocalSessionJSON.Object
    }

    private static func dataFromHex(_ value: String) -> Data? {
        guard value.count.isMultiple(of: 2) else { return nil }
        var data = Data(capacity: value.count / 2)
        var index = value.startIndex
        while index < value.endIndex {
            let end = value.index(index, offsetBy: 2)
            guard let byte = UInt8(value[index..<end], radix: 16) else { return nil }
            data.append(byte)
            index = end
        }
        return data
    }

    static func projectSlug(_ cwd: String) -> String {
        var output = ""
        var previousWasDash = false
        for scalar in cwd.trimmingCharacters(in: CharacterSet(charactersIn: "/")).unicodeScalars {
            // The official CLI uses ASCII, including for Chinese workspace paths.
            let alphaNumeric =
                (48...57).contains(scalar.value) || (65...90).contains(scalar.value)
                || (97...122).contains(scalar.value)
            if alphaNumeric {
                output.unicodeScalars.append(scalar)
                previousWasDash = false
            } else if !previousWasDash {
                output.append("-")
                previousWasDash = true
            }
        }
        return output.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    static func providerDirectory(_ value: String?, cwd: String) -> String? {
        guard let path = value, !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        // Cursor only trims to test emptiness. Node does not expand a literal ~
        // in an environment variable, and spaces can be part of a directory name.
        if path.hasPrefix("/") {
            return LocalSessionJSON.standardPath(path)
        }
        return LocalSessionJSON.standardPath(cwd + "/" + path)
    }

    private static func append(
        _ text: String?, isUser: Bool,
        to messages: inout [(Bool, String)]
    ) {
        guard let text = LocalSessionJSON.compact(text) else { return }
        if messages.last?.0 == isUser {
            messages[messages.count - 1].1 += "\n" + text
        } else {
            messages.append((isUser, text))
        }
    }
}
