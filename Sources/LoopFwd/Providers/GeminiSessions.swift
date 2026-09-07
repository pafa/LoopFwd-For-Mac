import Foundation
import CryptoKit

/// Gemini 0.58 recordings are history, not live completion/approval evidence.
/// A chat must match an explicit session ID or a process-owned open file.
enum GeminiSessions {
    struct Info: Equatable {
        var sessionID: String?
        var turnID: String?
        var lastPrompt: String?
        var lastMessage: String?
        var model: String?
        var updatedAt: Date?
        var chatPath: String?
        var status: AgentStatus?
        var activity: String?
        var observation: ObservationHealth?
        var reason = "No verified Gemini session matched this process"
    }

    private struct Recording {
        var metadata: [String: Any]
        var messages: [[String: Any]]
    }

    private static let maximumBytes = 2 * 1024 * 1024
    private static let maximumMessages = 4096

    // GEMINI_CLI_HOME overrides the home parent, not the .gemini directory.
    private static func root(_ geminiHome: String?) -> String {
        let home = geminiHome ?? FileManager.default.homeDirectoryForCurrentUser.path
        return lexicalPath(home) + "/.gemini"
    }

    static func projectDir(cwd: String, geminiHome: String? = nil) -> String? {
        projectLocation(cwd: cwd, geminiHome: geminiHome)?.directory
    }

    private static func projectLocation(cwd: String, geminiHome: String?) -> (directory: String, project: String)? {
        let cwd = lexicalPath(cwd)
        let base = root(geminiHome)
        let registryPath = base + "/projects.json"
        if FileManager.default.fileExists(atPath: registryPath) {
            guard let data = boundedData(registryPath, limit: 256 * 1024),
                let registry = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let projects = registry["projects"] as? [String: String]
            else { return nil }
            let aliases = projects.keys.filter {
                LocalSessionJSON.standardPath($0) == LocalSessionJSON.standardPath(cwd)
            }
            let project = projects[cwd] != nil ? cwd : aliases.count == 1 ? aliases[0] : cwd
            if let slug = projects[project] {
                guard !slug.isEmpty, slug.utf8.count <= 255,
                    slug.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 })
                else { return nil }
                let dir = base + "/tmp/" + slug
                let marker = dir + "/.project_root"
                if FileManager.default.fileExists(atPath: marker) {
                    guard let data = boundedData(marker, limit: 16 * 1024),
                        let owner = String(data: data, encoding: .utf8),
                        lexicalPath(owner.trimmingCharacters(in: .whitespacesAndNewlines)) == project
                    else { return nil }
                }
                return FileManager.default.fileExists(atPath: dir) ? (dir, project) : nil
            }
        }
        let dir = base + "/tmp/" + projectHash(cwd)
        return FileManager.default.fileExists(atPath: dir) ? (dir, cwd) : nil
    }

    static func info(
        cwd: String, args: String = "", geminiHome: String? = nil, openChatPaths: [String] = [],
        processID: Int32? = nil, processStartedAt: String? = nil, observerRoot: String? = nil, now: Date = Date()
    ) -> Info {
        guard let location = projectLocation(cwd: cwd, geminiHome: geminiHome) else { return Info() }
        let directory = location.directory
        let events: [LocalHookEvents.Event]
        if let processID, let processStartedAt {
            events = LocalHookEvents.sourced(
                LocalHookEvents.read(
                    provider: "gemini", pid: processID,
                    startedAt: processStartedAt, root: observerRoot, now: now), now: now)
        } else {
            events = []
        }
        let binding = events.last
        if let binding, Set(events.filter { $0.sourceDate == binding.sourceDate }.map(\.sessionID)).count > 1 {
            return Info(reason: "Gemini Hook session identity is ambiguous")
        }
        let requested = binding?.sessionID ?? LocalSessionJSON.argumentValue(args, names: ["--resume", "-r"])
        // "latest" and numeric history indexes are not persistent identities.
        if let requested, UUID(uuidString: requested) == nil { return Info() }
        let chats = directory + "/chats"
        let paths: [String]
        if let binding {
            guard let transcript = binding.transcriptPath, transcript.hasPrefix("/"),
                let hookCwd = binding.cwd,
                LocalSessionJSON.standardPath(hookCwd) == LocalSessionJSON.standardPath(cwd),
                LocalSessionJSON.standardPath((transcript as NSString).deletingLastPathComponent)
                    == LocalSessionJSON.standardPath(chats),
                ["jsonl", "json"].contains((transcript as NSString).pathExtension)
            else { return Info(reason: "Gemini Hook recording location could not be verified") }
            paths = [transcript]
        } else if let requested {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: chats), names.count <= 4096
            else { return Info(reason: "Gemini session discovery exceeded its read budget") }
            paths = names.filter {
                $0.hasPrefix("session-") && $0.lowercased().contains(String(requested.prefix(8)).lowercased())
                    && ($0.hasSuffix(".jsonl") || $0.hasSuffix(".json"))
            }.map { chats + "/" + $0 }
        } else {
            paths = Array(
                Set(
                    openChatPaths.filter {
                        let url = URL(fileURLWithPath: $0)
                        return url.deletingLastPathComponent().path == chats
                            && url.lastPathComponent.hasPrefix("session-")
                            && ["jsonl", "json"].contains(url.pathExtension)
                    }))
        }
        guard !paths.isEmpty, paths.count <= 16 else { return Info() }
        var matches: [(String, Recording)] = []
        for path in paths {
            guard let value = recording(path),
                let id = value.metadata["sessionId"] as? String, UUID(uuidString: id) != nil,
                value.metadata["projectHash"] as? String == projectHash(location.project),
                value.metadata["kind"] as? String != "subagent",
                requested == nil || id.lowercased() == requested?.lowercased()
            else { continue }
            matches.append((path, value))
        }
        // A torn migrated file must not revive its superseded JSON history.
        for legacy in matches where legacy.0.hasSuffix(".json") {
            let migrated = legacy.0 + "l"
            if FileManager.default.fileExists(atPath: migrated), !matches.contains(where: { $0.0 == migrated }) {
                return Info(reason: "Gemini session data is unavailable or ambiguous")
            }
        }
        // Official JSON-to-JSONL migration retains the old .json file. Only
        // accept that exact same-ID pair; unrelated copies stay ambiguous.
        if matches.count == 2,
            let legacy = matches.first(where: { $0.0.hasSuffix(".json") }),
            let migrated = matches.first(where: { $0.0 == legacy.0 + "l" }),
            legacy.1.metadata["sessionId"] as? String == migrated.1.metadata["sessionId"] as? String
        {
            matches = [migrated]
        }
        // Conflicting copies must not be silently ranked by file timestamp.
        guard matches.count == 1, let (path, value) = matches.first else {
            return Info(reason: "Gemini session data is unavailable or ambiguous")
        }
        let users = value.messages.filter { $0["type"] as? String == "user" }
        let lastAssistant = value.messages.last { $0["type"] as? String == "gemini" }
        let task = users.reversed().compactMap { messageText($0) }.first {
            TaskPresentationResolver.substantive($0) != nil
        }
        let progress = LocalHookEvents.progress(
            events.filter {
                $0.sessionID == requested
                    && $0.transcriptPath.map(LocalSessionJSON.standardPath) == LocalSessionJSON.standardPath(path)
                    && $0.cwd.map(LocalSessionJSON.standardPath) == LocalSessionJSON.standardPath(cwd)
            }, provider: "gemini", now: now)
        return Info(
            sessionID: value.metadata["sessionId"] as? String,
            turnID: users.last?["id"] as? String,
            lastPrompt: task,
            lastMessage: lastAssistant.flatMap(messageText),
            model: (lastAssistant?["model"] as? String).map { String($0.prefix(120)) },
            updatedAt: validDate(value.metadata["lastUpdated"]),
            chatPath: path,
            status: progress?.status,
            activity: progress?.activity,
            observation: progress?.observation,
            reason: "Gemini history matched; live task state is not available"
        )
    }

    /// Replay replacements, rewinds and checkpoints. A tail cannot safely
    /// interpret these operations; oversized or torn records fail closed.
    private static func recording(_ path: String) -> Recording? {
        guard let data = boundedData(path, limit: maximumBytes) else { return nil }
        if !path.hasSuffix(".jsonl") {
            guard let root = try? JSONSerialization.jsonObject(with: data) else { return nil }
            if let array = root as? [[String: Any]], array.count <= maximumMessages {
                return Recording(metadata: [:], messages: array)
            }
            guard let obj = root as? [String: Any],
                let messages = (obj["messages"] ?? obj["history"]) as? [[String: Any]],
                messages.count <= maximumMessages
            else { return nil }
            return Recording(metadata: obj, messages: messages)
        }
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        var metadata: [String: Any] = [:]
        var order: [String] = []
        var messages: [String: [String: Any]] = [:]
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        guard lines.count <= 16_384 else { return nil }
        for line in lines {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
                return nil
            }
            if obj["$rewindTo"] != nil {
                guard let target = obj["$rewindTo"] as? String else { return nil }
                let position = order.firstIndex(of: target) ?? 0
                for id in order[position...] { messages.removeValue(forKey: id) }
                order.removeSubrange(position...)
            } else if obj["$set"] != nil {
                guard let update = obj["$set"] as? [String: Any] else { return nil }
                if update["messages"] != nil {
                    guard let items = update["messages"] as? [[String: Any]], items.count <= maximumMessages else {
                        return nil
                    }
                    order.removeAll(keepingCapacity: true)
                    messages.removeAll(keepingCapacity: true)
                    for item in items {
                        guard let id = item["id"] as? String, !id.isEmpty else { return nil }
                        if messages[id] == nil { order.append(id) }
                        messages[id] = item
                    }
                }
                for (key, value) in update where key != "messages" { metadata[key] = value }
            } else if let id = obj["id"] as? String, !id.isEmpty {
                if messages[id] == nil { order.append(id) }
                messages[id] = obj
            } else if let id = obj["sessionId"] as? String {
                guard metadata["sessionId"] == nil || metadata["sessionId"] as? String == id else { return nil }
                metadata.merge(obj) { _, new in new }
            } else {
                return nil
            }
            guard order.count <= maximumMessages else { return nil }
        }
        return Recording(metadata: metadata, messages: order.compactMap { messages[$0] })
    }

    static func recentMessages(path: String, limit: Int = 12) -> [ChatMessage] {
        guard limit > 0, let value = recording(path) else { return [] }
        return Array(
            value.messages.enumerated().compactMap { index, item -> ChatMessage? in
                let role = (item["role"] ?? item["type"]) as? String ?? ""
                guard ["user", "model", "assistant", "gemini"].contains(role), let text = messageText(item) else {
                    return nil
                }
                return ChatMessage(id: index, isUser: role == "user", text: text)
            }.suffix(min(limit, 100)))
    }

    static func defaultModel(geminiHome: String? = nil) -> String? {
        guard let data = boundedData(root(geminiHome) + "/settings.json", limit: 256 * 1024),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let name = (obj["model"] as? String) ?? ((obj["model"] as? [String: Any])?["name"] as? String)
        return name.flatMap(LocalSessionJSON.compact).map { String($0.prefix(120)) }
    }

    private static func messageText(_ item: [String: Any]) -> String? {
        LocalSessionJSON.text(item["displayContent"] ?? item["content"] ?? item["parts"] ?? item["text"])
            .map { String($0.prefix(4000)) }
    }

    private static func projectHash(_ path: String) -> String {
        SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    // Foundation's standardizingPath removes /private from /private/tmp.
    // Gemini hashes Node's lexical path.resolve result, so preserve that identity.
    private static func lexicalPath(_ path: String) -> String {
        var parts: [Substring] = []
        for part in (path as NSString).expandingTildeInPath.split(separator: "/") {
            if part == "." { continue }
            if part == ".." { if !parts.isEmpty { parts.removeLast() } } else { parts.append(part) }
        }
        return "/" + parts.joined(separator: "/")
    }

    private static func validDate(_ value: Any?) -> Date? {
        guard let date = LocalSessionJSON.date(value), date.timeIntervalSince1970.isFinite,
            date.timeIntervalSince1970 > 0, date <= Date().addingTimeInterval(1)
        else { return nil }
        return date
    }

    private static func boundedData(_ path: String, limit: Int) -> Data? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
            attributes[.type] as? FileAttributeType == .typeRegular,
            let handle = FileHandle(forReadingAtPath: path)
        else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: limit + 1), data.count <= limit else { return nil }
        return data
    }
}
