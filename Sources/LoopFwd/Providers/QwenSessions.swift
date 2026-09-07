import Foundation

/// Read-only projection of Qwen Code's per-project JSONL transcripts.
///
/// Qwen records append-only ChatRecord objects under
/// `<runtime root>/projects/<sanitized cwd>/chats/<session>.jsonl`. Every
/// record repeats its cwd, so discovery validates the file instead of trusting
/// the lossy directory key. Unknown records are ignored and no daemon is
/// started solely for monitoring.
enum QwenSessions {
    struct Info {
        let sessionID: String
        let transcriptPath: String?
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

    struct Binding: Equatable {
        let sessionID: String
        let cwd: String
        let registeredAt: Date
    }

    private struct Candidate {
        let id: String
        let path: String
        let cwd: String
        let modified: Date
    }

    private struct Snapshot {
        let title: String?
        let lastPrompt: String?
        let lastMessage: String?
        let activity: String?
        let model: String?
        let updatedAt: Date
    }

    private struct DiscoveryCache {
        let at: Date
        let candidates: [Candidate]
    }

    private struct SnapshotCache {
        let modified: Date
        let snapshot: Snapshot
    }

    private static let lock = NSLock()
    private static var discoveryCache: [String: DiscoveryCache] = [:]
    private static var snapshotCache: [String: SnapshotCache] = [:]

    static func info(
        cwd: String?, args: String, cpu: Double,
        runtimeRoot: String?, qwenHome: String?, processID: Int32,
        processStartedAt: String?, observerRoot: String? = nil, now: Date = Date()
    ) -> Info? {
        guard let cwd,
            let binding = binding(
                processID: processID, cwd: cwd, processStartedAt: processStartedAt, qwenHome: qwenHome, now: now)
        else { return nil }
        let normalizedCwd = LocalSessionJSON.standardPath(cwd)
        let root = dataRoot(cwd: normalizedCwd, runtimeRoot: runtimeRoot, qwenHome: qwenHome)
        let candidates = discover(root: root, cwd: normalizedCwd)
        // The process-owned registry is refreshed on /clear and /cd; argv is
        // only the initial resume request and must not override a later switch.
        let matches = candidates.filter { $0.id == binding.sessionID }
        guard matches.count == 1, let selected = matches.first else {
            // The real CLI registers before authentication or its first chat
            // record. Keep that proven identity without borrowing old text or
            // inventing a task phase from the setup screen.
            var health = ObservationHealth.processOnly(
                "Qwen session registry", reason: "Qwen session matched; no unique task recording is available")
            health.updatedAt = binding.registeredAt
            return Info(
                sessionID: binding.sessionID, transcriptPath: nil, title: nil, cwd: binding.cwd,
                status: cpu > 3 ? .working : .idle, lastPrompt: nil, lastMessage: nil, activity: nil, model: nil,
                updatedAt: binding.registeredAt, observation: health)
        }

        let snapshot = parse(selected)
        let status: AgentStatus = cpu > 3 ? .working : .idle
        var observation = ObservationHealth.processOnly(
            "Qwen session registry + transcript",
            reason: "Qwen session matched; CLI history does not confirm the live task state")
        observation.updatedAt = snapshot.updatedAt
        let allEvents = LocalHookEvents.sourced(
            LocalHookEvents.read(
                provider: "qwen", pid: processID, startedAt: processStartedAt ?? "",
                root: observerRoot, now: now), now: now)
        let pendingIdentity =
            allEvents.last.map { latest in
                latest.sessionID != binding.sessionID
                    || Set(allEvents.filter { $0.sourceDate == latest.sourceDate }.map(\.sessionID)).count > 1
            } ?? false
        let events = allEvents.filter {
            $0.sessionID == binding.sessionID
                && $0.cwd.map(LocalSessionJSON.standardPath) == normalizedCwd
                && $0.transcriptPath.map(LocalSessionJSON.standardPath) == LocalSessionJSON.standardPath(selected.path)
        }
        let progress = pendingIdentity ? nil : LocalHookEvents.progress(events, provider: "qwen", now: now)
        if pendingIdentity {
            observation = .init(
                mode: .stale, updatedAt: allEvents.last?.sourceDate ?? snapshot.updatedAt,
                source: "Qwen session registry + Hook observer",
                reason: "Qwen session switch is waiting for registry reconciliation",
                authority: .versionedObserver)
        }
        return Info(
            sessionID: binding.sessionID,
            transcriptPath: selected.path,
            title: snapshot.title,
            cwd: selected.cwd,
            status: pendingIdentity ? .idle : progress?.status ?? status,
            lastPrompt: snapshot.lastPrompt,
            lastMessage: snapshot.lastMessage,
            activity: pendingIdentity
                ? nil
                : progress?.activity
                    ?? (progress == nil && status == .working ? snapshot.activity ?? "Thinking…" : nil),
            model: snapshot.model,
            updatedAt: progress?.observation.updatedAt ?? observation.updatedAt,
            observation: progress?.observation ?? observation
        )
    }

    /// The official 0.23.0 macOS registry has no procStart token. Compare its
    /// registration time with the scanner's current OS process start time so
    /// a stale PID file cannot bind a reused process. Never consume ipcToken.
    static func binding(
        processID: Int32, cwd: String, processStartedAt: String?, qwenHome: String?, now: Date = Date()
    ) -> Binding? {
        guard processID > 0, let processStartedAt else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        guard let processStart = formatter.date(from: processStartedAt) else { return nil }
        let home = resolve(qwenHome ?? NSHomeDirectory() + "/.qwen", cwd: cwd)
        let path = home + "/sessions/\(processID).json"
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
            attributes[.type] as? FileAttributeType == .typeRegular,
            let handle = FileHandle(forReadingAtPath: path)
        else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 64 * 1024 + 1), data.count <= 64 * 1024,
            let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let schema = record["schemaVersion"] as? NSNumber,
            CFGetTypeID(schema) != CFBooleanGetTypeID(), schema.doubleValue == 1,
            let pid = record["pid"] as? NSNumber,
            CFGetTypeID(pid) != CFBooleanGetTypeID(), pid.doubleValue == Double(processID),
            record["qwenVersion"] as? String == "0.23.0",
            let id = record["sessionId"] as? String, UUID(uuidString: id) != nil,
            let recordCwd = record["cwd"] as? String,
            LocalSessionJSON.standardPath(recordCwd) == LocalSessionJSON.standardPath(cwd),
            let started = record["startedAt"] as? NSNumber,
            CFGetTypeID(started) != CFBooleanGetTypeID(), started.doubleValue.isFinite
        else { return nil }
        let registeredAt = Date(timeIntervalSince1970: started.doubleValue / 1000)
        guard registeredAt >= processStart, registeredAt <= now.addingTimeInterval(1) else { return nil }
        return Binding(sessionID: id, cwd: recordCwd, registeredAt: registeredAt)
    }

    static func recentMessages(path: String, limit: Int = 12) -> [ChatMessage] {
        var messages: [(Bool, String)] = []
        for record in LocalSessionJSON.tailObjects(path: path) {
            guard let type = record["type"] as? String else { continue }
            if type == "user", record["subtype"] == nil {
                append(visibleText(record["message"]), isUser: true, to: &messages)
            } else if type == "assistant" {
                append(visibleText(record["message"]), isUser: false, to: &messages)
            }
        }
        return messages.suffix(max(1, limit)).enumerated().map {
            ChatMessage(id: $0.offset, isUser: $0.element.0, text: $0.element.1)
        }
    }

    private static func dataRoot(
        cwd: String, runtimeRoot: String?,
        qwenHome: String?
    ) -> String {
        if let runtimeRoot = LocalSessionJSON.compact(runtimeRoot) {
            return resolve(runtimeRoot, cwd: cwd)
        }
        let homeRoot = resolve(
            LocalSessionJSON.compact(qwenHome) ?? NSHomeDirectory() + "/.qwen",
            cwd: cwd
        )
        let settings = LocalSessionJSON.object(path: homeRoot + "/settings.json")
        let advanced = settings?["advanced"] as? LocalSessionJSON.Object
        if let configured = LocalSessionJSON.compact(advanced?["runtimeOutputDir"] as? String) {
            return resolve(configured, cwd: cwd)
        }
        return homeRoot
    }

    private static func discover(root: String, cwd: String) -> [Candidate] {
        let cacheKey = root + "\u{0}" + cwd
        lock.lock()
        if let cached = discoveryCache[cacheKey], Date().timeIntervalSince(cached.at) < 3 {
            lock.unlock()
            return cached.candidates
        }
        lock.unlock()

        let projectsRoot = root + "/projects"
        let direct = projectsRoot + "/" + sanitized(cwd) + "/chats"
        var files = transcriptFiles(in: direct)

        // The directory key intentionally loses punctuation. Validate cwd from
        // the transcript and scan sibling project stores only when the direct
        // location is absent or collided.
        var matches = candidates(from: files, matching: cwd)
        if matches.isEmpty {
            let projectDirs = childDirectories(projectsRoot)
            files = projectDirs.flatMap { transcriptFiles(in: $0 + "/chats") }
            matches = candidates(from: files, matching: cwd)
        }
        matches.sort { $0.modified > $1.modified }

        lock.lock()
        discoveryCache[cacheKey] = DiscoveryCache(at: Date(), candidates: matches)
        lock.unlock()
        return matches
    }

    private static func candidates(from files: [String], matching cwd: String) -> [Candidate] {
        files.compactMap { path in
            let head = LocalSessionJSON.headObjects(path: path).first { record in
                record["cwd"] is String && record["sessionId"] is String
            }
            guard let record = head,
                let recordCwd = record["cwd"] as? String,
                LocalSessionJSON.standardPath(recordCwd) == cwd,
                let id = record["sessionId"] as? String,
                let modified = LocalSessionJSON.fileDate(path)
            else { return nil }
            return Candidate(id: id, path: path, cwd: recordCwd, modified: modified)
        }
    }

    private static func parse(_ candidate: Candidate) -> Snapshot {
        lock.lock()
        if let cached = snapshotCache[candidate.path], cached.modified == candidate.modified {
            lock.unlock()
            return cached.snapshot
        }
        lock.unlock()

        var title: String?
        var lastPrompt: String?
        var lastMessage: String?
        var model: String?
        var activeTools: [String: String] = [:]
        var eventDate: Date?

        for record in LocalSessionJSON.tailObjects(path: candidate.path) {
            guard let type = record["type"] as? String else { continue }
            eventDate = LocalSessionJSON.date(record["timestamp"]) ?? eventDate
            switch type {
            case "user" where record["subtype"] == nil:
                if let prompt = visibleText(record["message"]), TaskPresentationResolver.substantive(prompt) != nil {
                    lastPrompt = prompt
                }
                activeTools.removeAll()
            case "assistant":
                model = (record["model"] as? String) ?? model
                lastMessage = visibleText(record["message"]) ?? lastMessage
                let calls = functionCalls(record["message"])
                if calls.isEmpty {
                    activeTools.removeAll()
                } else {
                    for call in calls { activeTools[call.id] = call.name }
                }
            case "tool_result":
                for id in functionResponseIDs(record["message"]) {
                    activeTools.removeValue(forKey: id)
                }
            case "system" where record["subtype"] as? String == "custom_title":
                let payload = record["systemPayload"] as? LocalSessionJSON.Object
                title = LocalSessionJSON.compact(payload?["customTitle"] as? String) ?? title
            default:
                continue
            }
        }

        let updatedAt = eventDate ?? candidate.modified
        let activity =
            activeTools.values.first.map { "Running \($0)" }
        let snapshot = Snapshot(
            title: title,
            lastPrompt: lastPrompt,
            lastMessage: lastMessage,
            activity: activity,
            model: model,
            updatedAt: updatedAt
        )
        lock.lock()
        snapshotCache[candidate.path] = SnapshotCache(
            modified: candidate.modified, snapshot: snapshot)
        lock.unlock()
        return snapshot
    }

    private static func visibleText(_ value: Any?) -> String? {
        guard let message = value as? LocalSessionJSON.Object,
            let parts = message["parts"] as? [Any]
        else { return nil }
        let pieces = parts.compactMap { value -> String? in
            guard let part = value as? LocalSessionJSON.Object,
                part["thought"] as? Bool != true
            else { return nil }
            return LocalSessionJSON.compact(part["text"] as? String)
        }
        return LocalSessionJSON.compact(pieces.joined(separator: "\n"))
    }

    private static func functionCalls(_ value: Any?) -> [(id: String, name: String)] {
        guard let message = value as? LocalSessionJSON.Object,
            let parts = message["parts"] as? [Any]
        else { return [] }
        return parts.compactMap { value in
            guard let part = value as? LocalSessionJSON.Object,
                let call = part["functionCall"] as? LocalSessionJSON.Object,
                let name = call["name"] as? String
            else { return nil }
            let id = (call["id"] as? String) ?? name
            return (id, name)
        }
    }

    private static func functionResponseIDs(_ value: Any?) -> [String] {
        guard let message = value as? LocalSessionJSON.Object,
            let parts = message["parts"] as? [Any]
        else { return [] }
        return parts.compactMap { value in
            guard let part = value as? LocalSessionJSON.Object,
                let response = part["functionResponse"] as? LocalSessionJSON.Object
            else {
                return nil
            }
            return (response["id"] as? String) ?? (response["name"] as? String)
        }
    }

    private static func transcriptFiles(in chatsDirectory: String) -> [String] {
        let keys: [URLResourceKey] = [.isRegularFileKey]
        let urls =
            (try? FileManager.default.contentsOfDirectory(
                at: URL(fileURLWithPath: chatsDirectory),
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles]
            )) ?? []
        return urls.compactMap { url in
            guard url.pathExtension == "jsonl",
                (try? url.resourceValues(forKeys: Set(keys)).isRegularFile) == true
            else {
                return nil
            }
            return url.path
        }
    }

    private static func childDirectories(_ path: String) -> [String] {
        let keys: [URLResourceKey] = [.isDirectoryKey]
        let urls =
            (try? FileManager.default.contentsOfDirectory(
                at: URL(fileURLWithPath: path),
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles]
            )) ?? []
        return urls.compactMap { url in
            (try? url.resourceValues(forKeys: Set(keys)).isDirectory) == true ? url.path : nil
        }
    }

    private static func sanitized(_ cwd: String) -> String {
        String(
            cwd.unicodeScalars.map { scalar in
                let value = scalar.value
                let ascii =
                    (48...57).contains(value) || (65...90).contains(value)
                    || (97...122).contains(value)
                return ascii ? Character(String(scalar)) : "-"
            })
    }

    private static func resolve(_ path: String, cwd: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        if (expanded as NSString).isAbsolutePath {
            return LocalSessionJSON.standardPath(expanded)
        }
        return LocalSessionJSON.standardPath(cwd + "/" + expanded)
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
