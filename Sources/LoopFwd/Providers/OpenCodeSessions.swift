import Foundation

/// Optional rich reader for an OpenCode TUI that was started with an explicit
/// `--port` / `--hostname`. A normal `opencode` TUI uses an in-process transport
/// and therefore keeps the process/TTY fallback in AgentMonitor.
///
/// API shapes verified against OpenCode v1.18.9, commit 4da7bb44. OpenCode's
/// own run transport polls `/session/status` because event streams can miss
/// status events, so the prototype uses the same reliable HTTP path.
enum OpenCodeSessions {
    struct QuestionProjection {
        let requestID: String
        let question: PendingQuestion?

        var isSupported: Bool { question != nil }
    }

    struct Info: @unchecked Sendable {
        let directory: String
        let title: String
        let status: AgentStatus
        let updatedAt: Double  // epoch ms
        let model: String?
        let lastPrompt: String?
        let lastMessage: String?
        let activity: String?
        let todos: [Todo]
        let pendingQuestion: PendingQuestion?
        let control: OpenCodeControl
        let turnID: String?
    }

    enum PermissionReply: String {
        case once, always, reject
    }

    private static let client: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 0.35
        configuration.timeoutIntervalForResource = 0.5
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration, delegate: LoopbackRedirectGuard(), delegateQueue: nil)
    }()

    struct ReadBatch: @unchecked Sendable {
        var infos: [Info]
        var outcome: ProviderReadResult.Outcome
        var reason: String?
    }

    // Only the serialized scanner uses this bounded, in-memory summary cache.
    private static var summaries: [String: Conversation] = [:]
    private static var summaryRevisions: [String: Double] = [:]
    private static var todoSummaries: [String: [Todo]] = [:]
    private static var summaryCursor: [Int32: Int] = [:]
    private struct CachedHeader {
        let item: [String: Any]
        let readAt: Date
    }
    private static var headers: [String: CachedHeader] = [:]
    private static var discoveryCursor: [String: Int] = [:]

    static func prune(livePids: Set<Int32>) {
        func isLive(_ key: String) -> Bool {
            key.split(separator: ":").first.flatMap { Int32($0) }.map(livePids.contains) == true
        }
        headers = headers.filter { isLive($0.key) }
        summaries = summaries.filter { isLive($0.key) }
        summaryRevisions = summaryRevisions.filter { isLive($0.key) }
        todoSummaries = todoSummaries.filter { isLive($0.key) }
        summaryCursor = summaryCursor.filter { livePids.contains($0.key) }
        discoveryCursor = discoveryCursor.filter { isLive($0.key) }
    }

    static func read(pid: Int32, expectedDirectory: String?) async -> ReadBatch {
        for port in listeningPorts(pid: pid) {
            let batch = await read(port: port, processID: pid, expectedDirectory: expectedDirectory)
            if batch.outcome != .failed { return batch }
        }
        return ReadBatch(infos: [], outcome: .failed, reason: "No compatible local OpenCode service responded")
    }

    /// The injected transport exercises the same discovery/projection entry
    /// as production without starting an Agent or authorizing control.
    typealias ReadTransport = (String, Int, [URLQueryItem]) async -> Any?

    static func read(
        port: Int, processID: Int32, expectedDirectory: String?,
        transport: ReadTransport? = nil, metadataBudget: Int = 16
    ) async -> ReadBatch {
        let deadline = Date().addingTimeInterval(3)
        let get: ReadTransport =
            transport ?? { path, port, query in
                await json(path: path, port: port, query: query)
            }
        let failed = ReadBatch(infos: [], outcome: .failed, reason: "OpenCode discovery or status read failed")
        guard let health = await get("/global/health", port, []) as? [String: Any],
            health["healthy"] as? Bool == true
        else { return failed }
        guard supportsVersion(health["version"] as? String) else {
            return ReadBatch(
                infos: [], outcome: .incompatible,
                reason: "OpenCode loopback API requires a stable 1.18.x version")
        }
        guard
            let path = await get("/path", port, []) as? [String: Any],
            let directory = path["directory"] as? String
        else { return failed }

        if let expectedDirectory,
            standard(expectedDirectory) != standard(directory)
        {
            return failed
        }

        let query = [URLQueryItem(name: "directory", value: directory)]
        // Discovery is independent of the summary budget. Status contains all
        // active identities; fetch missing metadata directly so history limits
        // cannot hide a still-running task.
        guard let statuses = await get("/session/status", port, query) as? [String: Any],
            var rawSessions = await get("/session", port, query) as? [Any]
        else { return failed }
        let questions = await get("/question", port, query) as? [[String: Any]]
        let permissions = await get("/permission", port, query) as? [[String: Any]]
        var incomplete = questions == nil || permissions == nil
        let knownIDs = Set(rawSessions.compactMap { ($0 as? [String: Any])?["id"] as? String })
        let requestedIDs = Set(statuses.keys).union(
            ((questions ?? []) + (permissions ?? [])).compactMap { $0["sessionID"] as? String })
        let cachePrefix = "\(processID):\(port):"
        let requestedKeys = Set(requestedIDs.map { cachePrefix + $0 })
        headers = headers.filter { !$0.key.hasPrefix(cachePrefix) || requestedKeys.contains($0.key) }
        // Retain only bounded header fields, never a full server response.
        func cacheHeader(_ item: [String: Any], id: String) {
            guard id.utf8.count <= 256 else { return }
            var header: [String: Any] = ["id": id]
            for (key, limit) in [("directory", 8192), ("title", 512), ("parentID", 256)] {
                if let value = item[key] as? String { header[key] = String(value.prefix(limit)) }
            }
            if let time = item["time"] as? [String: Any] {
                header["time"] = time.filter {
                    ["created", "updated", "archived"].contains($0.key) && number($0.value) != nil
                }
            }
            if let model = (item["model"] as? [String: Any])?["id"] as? String {
                header["model"] = ["id": String(model.prefix(256))]
            }
            headers[cachePrefix + id] = .init(item: header, readAt: Date())
        }
        for case let item as [String: Any] in rawSessions {
            if let id = item["id"] as? String, requestedIDs.contains(id) { cacheHeader(item, id: id) }
        }
        let missing = requestedIDs.subtracting(knownIDs).sorted()
        let due = missing.filter {
            headers[cachePrefix + $0].map { Date().timeIntervalSince($0.readAt) >= 30 } ?? true
        }
        let cursor = discoveryCursor[cachePrefix, default: 0] % max(1, due.count)
        var attempted = 0
        for index in 0..<min(max(0, metadataBudget), due.count) {
            guard !Task.isCancelled, Date() < deadline else { break }
            let id = due[(cursor + index) % due.count]
            attempted += 1
            guard let segment = pathSegment(id),
                let item = await get("/session/\(segment)", port, query) as? [String: Any],
                item["id"] as? String == id
            else { incomplete = true; continue }
            cacheHeader(item, id: id)
        }
        discoveryCursor[cachePrefix] = (cursor + attempted) % max(1, due.count)
        for id in missing {
            if let cached = headers[cachePrefix + id] {
                rawSessions.append(cached.item)
                if Date().timeIntervalSince(cached.readAt) >= 30 { incomplete = true }
            } else {
                incomplete = true
            }
        }
        let sessions = rawSessions.compactMap { $0 as? [String: Any] }.filter {
            ($0["directory"] as? String).map(standard) == standard(directory)
                && $0["parentID"] == nil
                && (($0["time"] as? [String: Any])?["archived"] == nil)
        }
        // A finished turn disappears from /session/status. Inspect recently
        // updated headers too, so its explicit result is not lost between
        // polls. This is a bounded observation window, not a persistent Done
        // list; the shared lifecycle still owns the five-second presentation.
        let active = sessions.filter { item in
            guard let id = item["id"] as? String else { return false }
            let updated = number((item["time"] as? [String: Any])?["updated"])
            let age = updated.map { Date().timeIntervalSince1970 - $0 / 1000 }
            return requestedIDs.contains(id) || age.map { (-1...60).contains($0) } == true
        }.sorted { ($0["id"] as? String ?? "") < ($1["id"] as? String ?? "") }
        let start = summaryCursor[processID, default: 0] % max(1, active.count)
        // All active cards are projected each scan. Only their expensive text
        // is rotated, rather than silently truncating the activity list.
        let summaryIDs = Set(
            (0..<min(4, active.count)).compactMap {
                active[(start + $0) % active.count]["id"] as? String
            })
        summaryCursor[processID] = (start + summaryIDs.count) % max(1, active.count)
        let liveKeys = Set(active.compactMap { ($0["id"] as? String).map { cachePrefix + $0 } })
        summaries = summaries.filter { !$0.key.hasPrefix(cachePrefix) || liveKeys.contains($0.key) }
        summaryRevisions = summaryRevisions.filter { !$0.key.hasPrefix(cachePrefix) || liveKeys.contains($0.key) }
        todoSummaries = todoSummaries.filter { !$0.key.hasPrefix(cachePrefix) || liveKeys.contains($0.key) }
        var infos: [Info] = []
        for selected in active {
            guard
                let sessionID = selected["id"] as? String,
                let title = selected["title"] as? String,
                let time = selected["time"] as? [String: Any],
                let updatedAt = number(time["updated"])
            else { incomplete = true; continue }

            guard let encodedID = pathSegment(sessionID) else { incomplete = true; continue }
            let cacheKey = cachePrefix + sessionID
            var conversation = summaries[cacheKey] ?? Conversation()
            var todos = todoSummaries[cacheKey] ?? []
            if summaryIDs.contains(sessionID), !Task.isCancelled, Date() < deadline {
                if let messages = await get(
                    "/session/\(encodedID)/message", port,
                    query + [URLQueryItem(name: "limit", value: "20")]) as? [Any]
                {
                    var updated = conversationInfo(messages)
                    updated.lastPrompt = updated.lastPrompt ?? conversation.lastPrompt
                    conversation = updated
                    summaries[cacheKey] = updated
                    summaryRevisions[cacheKey] = updatedAt
                } else {
                    incomplete = true
                }
                if let todoObjects = await get("/session/\(encodedID)/todo", port, query) as? [Any] {
                    todos = todoObjects.prefix(64).compactMap { value -> Todo? in
                        guard let item = value as? [String: Any],
                            let content = item["content"] as? String
                        else { return nil }
                        return Todo(
                            content: String(content.prefix(512)), status: item["status"] as? String ?? "pending")
                    }
                    todoSummaries[cacheKey] = todos
                }
            }

            let question = questions?.reversed().compactMap { questionProjection(request: $0, sessionID: sessionID) }
                .first
            let permission = permissions?.reversed().compactMap { permissionProjection($0, sessionID: sessionID) }.first
            let remoteStatus = (statuses[sessionID] as? [String: Any])?["type"] as? String
            let retryMessage = (statuses[sessionID] as? [String: Any])?["message"] as? String
            let age = Date().timeIntervalSince1970 - updatedAt / 1000
            let summaryCurrent = summaryRevisions[cacheKey] == updatedAt
            // A cached result from a previous header revision must never end
            // the current task. Defer unrefreshed idle candidates rather than
            // projecting an invented Idle/Completed from stale message data.
            if !summaryCurrent, question == nil, permission == nil,
                remoteStatus != "busy", remoteStatus != "retry"
            {
                incomplete = true
                continue
            }

            let status = status(
                remoteStatus: remoteStatus,
                hasAttention: question != nil || permission != nil,
                hasContent: conversation.hasContent,
                age: age,
                outcome: summaryCurrent ? conversation.outcome : nil
            )

            let model =
                (selected["model"] as? [String: Any])?["id"] as? String
                ?? conversation.model
            let blocker =
                permission.map { "Permission needed: \($0.name)" }
                ?? (question?.isSupported == false ? "OpenCode needs multiple answers in its app" : nil)

            infos.append(
                Info(
                    directory: directory,
                    title: title,
                    status: status,
                    updatedAt: status == conversation.outcome ? conversation.outcomeAt ?? updatedAt : updatedAt,
                    model: model,
                    lastPrompt: conversation.lastPrompt,
                    lastMessage: blocker ?? conversation.lastMessage,
                    activity: retryMessage ?? (remoteStatus == "busy" ? conversation.activity ?? "Thinking…" : nil),
                    todos: todos,
                    pendingQuestion: question?.question,
                    control: OpenCodeControl(
                        processID: processID,
                        port: port,
                        directory: directory,
                        sessionID: sessionID,
                        questionRequestID: question?.isSupported == true ? question?.requestID : nil,
                        permission: permission
                    ),
                    turnID: conversation.turnID
                ))
        }
        if summaries.count > 512 {
            summaries = summaries.filter { liveKeys.contains($0.key) }
            summaryRevisions = summaryRevisions.filter { liveKeys.contains($0.key) }
            todoSummaries = todoSummaries.filter { liveKeys.contains($0.key) }
        }
        if headers.count > 512 { headers = headers.filter { liveKeys.contains($0.key) } }
        if discoveryCursor.count > 128 { discoveryCursor = [cachePrefix: discoveryCursor[cachePrefix] ?? 0] }
        if summaryCursor.count > 128 { summaryCursor = [processID: summaryCursor[processID] ?? 0] }
        return ReadBatch(
            infos: infos, outcome: incomplete ? .partial : (infos.isEmpty ? .empty : .success),
            reason: incomplete ? "OpenCode scan incomplete; some session or attention metadata is unavailable" : nil)
    }

    private static func pathSegment(_ value: String) -> String? {
        guard !value.isEmpty, value.utf8.count <= 256 else { return nil }
        return value.addingPercentEncoding(
            withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "_-")))
    }

    private static func permissionProjection(_ request: [String: Any], sessionID: String) -> OpenCodePermission? {
        guard request["sessionID"] as? String == sessionID,
            let id = request["id"] as? String, let name = request["permission"] as? String
        else { return nil }
        return .init(requestID: id, name: name, patterns: request["patterns"] as? [String] ?? [])
    }

    /// Revalidate the request immediately before replying. A stale control must
    /// fail closed even when a recycled card still holds its old request ID.
    static func answerQuestion(
        control: OpenCodeControl, answers: [String],
        completion: @escaping (Bool) -> Void
    ) {
        guard UserDefaults.standard.bool(forKey: Pref.providerControlsEnabled) else {
            completion(false)
            return
        }
        guard let requestID = control.questionRequestID, !answers.isEmpty else {
            completion(false)
            return
        }
        Task {
            let query = [URLQueryItem(name: "directory", value: control.directory)]
            let valid = await validate(control: control)
            let live =
                valid
                ? await requestExists(
                    path: "/question", port: control.port, query: query,
                    requestID: requestID, sessionID: control.sessionID)
                : false
            let encoded = requestID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? requestID
            let success: Bool
            if live, UserDefaults.standard.bool(forKey: Pref.providerControlsEnabled) {
                success = await postBoolean(
                    path: "/question/\(encoded)/reply", port: control.port, query: query,
                    body: ["answers": [answers]])
            } else {
                success = false
            }
            await MainActor.run { completion(success) }
        }
    }

    static func replyPermission(
        control: OpenCodeControl, reply: PermissionReply,
        completion: @escaping (Bool) -> Void
    ) {
        guard UserDefaults.standard.bool(forKey: Pref.providerControlsEnabled) else {
            completion(false)
            return
        }
        guard let permission = control.permission else {
            completion(false)
            return
        }
        Task {
            let query = [URLQueryItem(name: "directory", value: control.directory)]
            let valid = await validate(control: control)
            let live =
                valid
                ? await requestExists(
                    path: "/permission", port: control.port, query: query,
                    requestID: permission.requestID, sessionID: control.sessionID)
                : false
            let encoded =
                permission.requestID
                .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? permission.requestID
            let success: Bool
            if live, UserDefaults.standard.bool(forKey: Pref.providerControlsEnabled) {
                success = await postBoolean(
                    path: "/permission/\(encoded)/reply", port: control.port, query: query,
                    body: ["reply": reply.rawValue])
            } else {
                success = false
            }
            await MainActor.run { completion(success) }
        }
    }

    struct Conversation {
        var lastPrompt: String?
        var lastMessage: String?
        var activity: String?
        var model: String?
        var hasContent = false
        var turnID: String?
        var outcome: AgentStatus?
        var outcomeAt: Double?
    }

    static func conversationInfo(_ raw: [Any]) -> Conversation {
        var result = Conversation()
        for value in raw {
            guard let item = value as? [String: Any],
                let info = item["info"] as? [String: Any],
                let role = info["role"] as? String
            else { continue }
            let parts = (item["parts"] as? [Any] ?? []).compactMap { $0 as? [String: Any] }
            if role == "user" {
                result.turnID = info["id"] as? String
                result.outcome = nil
                result.outcomeAt = nil
                result.activity = nil
            }
            if role == "assistant", let turnID = result.turnID,
                info["parentID"] as? String == turnID,
                info["summary"] as? Bool != true
            {
                // Each subsequent assistant step replaces the previous one.
                // Tool-call completion and compaction are not turn success.
                result.outcome = nil
                result.outcomeAt = nil
                result.activity = nil
                if let completed = number((info["time"] as? [String: Any])?["completed"]),
                    completed.isFinite, completed > 0,
                    completed <= Date().timeIntervalSince1970 * 1000 + 1000
                {
                    if let error = info["error"] as? [String: Any], let name = error["name"] as? String {
                        result.outcome = name == "MessageAbortedError" ? .stopped : .failed
                    } else if info["error"] == nil, info["finish"] as? String == "stop" {
                        result.outcome = .completed
                    }
                    if result.outcome != nil { result.outcomeAt = completed }
                }
            }
            let text = parts.filter { $0["type"] as? String == "text" }
                .compactMap { $0["text"] as? String }
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                result.hasContent = true
                if role == "user", TaskPresentationResolver.substantive(text) != nil {
                    result.lastPrompt = String(text.prefix(16 * 1024))
                }
                if role == "assistant" { result.lastMessage = String(text.prefix(32 * 1024)) }
            }
            if role == "assistant" {
                result.model = info["modelID"] as? String ?? result.model
                if let runningTool = parts.last(where: {
                    $0["type"] as? String == "tool"
                        && (($0["state"] as? [String: Any])?["status"] as? String) == "running"
                }) {
                    result.activity = runningTool["tool"] as? String
                }
            }
        }
        return result
    }

    static func status(
        remoteStatus: String?, hasAttention: Bool,
        hasContent: Bool, age: TimeInterval, outcome: AgentStatus? = nil
    ) -> AgentStatus {
        if hasAttention { return .needsAttention }
        if remoteStatus == "busy" || remoteStatus == "retry" { return .working }
        if remoteStatus == nil || remoteStatus == "idle", let outcome { return outcome }
        // Idle plus historical content does not prove successful completion.
        return .idle
    }

    static func questionProjection(
        request: [String: Any], sessionID: String
    ) -> QuestionProjection? {
        guard request["sessionID"] as? String == sessionID,
            let requestID = request["id"] as? String,
            let questions = request["questions"] as? [Any],
            !questions.isEmpty
        else { return nil }

        // The reply endpoint accepts an ordered answer array for every
        // question. Until the UI models that complete array, expose attention
        // but withhold the request ID so a partial answer can never be sent.
        guard questions.count == 1, let first = questions.first as? [String: Any] else {
            return QuestionProjection(requestID: requestID, question: nil)
        }
        let prompt = (first["question"] as? String) ?? (first["header"] as? String) ?? "Choose an option"
        let options = (first["options"] as? [Any] ?? []).compactMap {
            ($0 as? [String: Any])?["label"] as? String
        }
        guard !options.isEmpty else {
            return QuestionProjection(requestID: requestID, question: nil)
        }
        return QuestionProjection(
            requestID: requestID,
            question: PendingQuestion(
                prompt: prompt,
                options: options,
                multiSelect: first["multiple"] as? Bool ?? false
            )
        )
    }

    // MARK: - Local HTTP

    private static func object(
        path: String, port: Int,
        query: [URLQueryItem] = []
    ) async -> [String: Any]? {
        await json(path: path, port: port, query: query) as? [String: Any]
    }

    private static func array(
        path: String, port: Int,
        query: [URLQueryItem] = []
    ) async -> [Any]? {
        await json(path: path, port: port, query: query) as? [Any]
    }

    private static func requestExists(
        path: String, port: Int, query: [URLQueryItem],
        requestID: String, sessionID: String
    ) async -> Bool {
        guard let requests = await array(path: path, port: port, query: query) else { return false }
        return requests.contains {
            guard let request = $0 as? [String: Any] else { return false }
            return request["id"] as? String == requestID
                && request["sessionID"] as? String == sessionID
        }
    }

    private static func validate(control: OpenCodeControl) async -> Bool {
        guard processOwnsListeningPort(pid: control.processID, port: control.port),
            let health = await object(path: "/global/health", port: control.port),
            health["healthy"] as? Bool == true,
            supportsVersion(health["version"] as? String),
            let path = await object(path: "/path", port: control.port),
            let directory = path["directory"] as? String,
            standard(directory) == standard(control.directory)
        else { return false }
        return true
    }

    /// Match the profile's audited API family before reading or controlling a
    /// service. A responding loopback port is not proof of schema compatibility.
    static func supportsVersion(_ version: String?) -> Bool {
        guard let version, version.utf8.count <= 32 else { return false }
        let components = version.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 3, components[0] == "1", components[1] == "18" else { return false }
        let patch = components[2]
        return !patch.isEmpty && (patch.count == 1 || patch.first != "0")
            && patch.utf8.allSatisfy { (48...57).contains($0) }
    }

    private static func processOwnsListeningPort(pid: Int32, port: Int) -> Bool {
        guard listeningPorts(pid: pid).contains(port) else { return false }
        let args = run("/bin/ps", ["-p", String(pid), "-o", "args="])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return AgentScanner.detect(args: args) == .opencode
    }

    private static func postBoolean(
        path: String, port: Int, query: [URLQueryItem],
        body: [String: Any]
    ) async -> Bool {
        await json(path: path, port: port, query: query, method: "POST", body: body) as? Bool == true
    }

    private static func json(
        path: String, port: Int,
        query: [URLQueryItem], method: String = "GET",
        body: [String: Any]? = nil
    ) async -> Any? {
        guard let url = loopbackURL(path: path, port: port, query: query) else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = method
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
            guard request.httpBody != nil else { return nil }
        }

        do {
            let (bytes, response) = try await client.bytes(for: request)
            guard let response = response as? HTTPURLResponse,
                response.statusCode == 200
            else { return nil }
            let maximumBytes = 4 * 1024 * 1024
            guard response.expectedContentLength <= maximumBytes else { return nil }
            var data = Data()
            for try await byte in bytes {
                guard data.count < maximumBytes, !Task.isCancelled else { return nil }
                data.append(byte)
            }
            // OpenCode control endpoints return a top-level JSON boolean.
            // Without fragmentsAllowed a real `true` reply parses as nil and
            // the island reports failure even though the request was handled.
            return try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
        } catch {
            return nil
        }
    }

    /// Constructing the URL in one tested place makes the network boundary
    /// explicit: provider-controlled values can choose a valid local port and
    /// path, never a host or scheme.
    static func loopbackURL(
        path: String, port: Int,
        query: [URLQueryItem] = []
    ) -> URL? {
        guard (1...65535).contains(port), path.hasPrefix("/") else { return nil }
        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = port
        components.path = path
        components.queryItems = query.isEmpty ? nil : query
        return components.url
    }

    // MARK: - Listener discovery

    static func listeningPorts(pid: Int32) -> [Int] {
        let output = run(
            "/usr/sbin/lsof",
            [
                "-nP", "-a", "-p", String(pid), "-iTCP", "-sTCP:LISTEN", "-Fn",
            ])
        var result: [Int] = []
        for line in output.split(separator: "\n") where line.hasPrefix("n") {
            let endpoint = line.dropFirst()
            guard let colon = endpoint.lastIndex(of: ":"),
                let port = Int(endpoint[endpoint.index(after: colon)...]),
                (1...65535).contains(port), !result.contains(port)
            else { continue }
            result.append(port)
        }
        return result
    }

    private static func run(_ path: String, _ arguments: [String]) -> String {
        let result = BoundedProcess.run(path, arguments)
        return result.succeeded ? result.output : ""
    }

    private static func standard(_ path: String) -> String {
        (path as NSString).standardizingPath
    }

    private static func number(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }
}
