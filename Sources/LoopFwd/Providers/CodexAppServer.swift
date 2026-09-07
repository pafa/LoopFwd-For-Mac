import Foundation

/// Minimal official Codex app-server client for sessions explicitly started by
/// LoopFwd. It launches lazily after a user action and speaks JSONL over stdio;
/// external terminal sessions remain observation + Jump only.
final class CodexAppServer: ObservableObject {
    static let shared = CodexAppServer()

    @Published private(set) var agents: [AgentSession] = []

    private struct ManagedThread {
        let id: String
        let createdAt: Date
        var cwd: String
        var model: String?
        var transcriptPath: String?
        var title: String
        var taskAnchor: String?
        var lastPrompt: String?
        var lastMessage: String?
        var activity: String?
        var status: AgentStatus
        var observation: ObservationHealth
        var activeTurnID: String?
        var lastTurnID: String?
        var turnStartedAt: Date?
        var interruptionRequested: Bool
    }

    /// Only the identity needed to find and resume a LoopFwd-owned thread is
    /// persisted. Conversation content remains in Codex's own rollout file.
    private struct StoredThread: Codable {
        let id: String
        let createdAt: Date
        let cwd: String
        let model: String?
        let transcriptPath: String?
        let title: String
    }

    private enum ConnectionState { case stopped, starting, ready }

    private let queue = DispatchQueue(label: "app.loopfwd.codex-app-server", qos: .userInitiated)
    private var connectionState: ConnectionState = .stopped
    private var process: Process?
    private var inputPipe: Pipe?
    private var outputPipe: Pipe?
    private var outputBuffer = Data()
    private var discardingOversizedRecord = false
    private var refreshTimer: DispatchSourceTimer?
    private var nextRequestID = 1
    private var pending: [Int: (Result<[String: Any], Error>) -> Void] = [:]
    private var readyWaiters: [(Result<Void, Error>) -> Void] = []
    private var managed: [String: ManagedThread] = [:]
    private var loadedThreads = Set<String>()
    private let lifecycle = AgentLifecycleReducer()

    private init() {
        let restored = Self.restoreStoredThreads()
        let active = restored.compactMap(Self.restore)
        managed = Dictionary(active.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        agents = lifecycle.reduce(managed.values.map(Self.agent), suppressEvents: true).sessions
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler { [weak self] in
            guard let self, !self.managed.isEmpty else { return }
            self.refreshRecovery()
            self.publish()
        }
        refreshTimer = timer
        timer.resume()
    }

    var isAvailable: Bool { AgentKind.codex.installedCLIPath != nil }

    /// Starts one workspace-scoped task. `never` + `workspace-write` means the
    /// first prototype can work in the selected folder but cannot silently
    /// escape its sandbox while approval UI is still absent.
    func startTask(
        prompt: String, cwd: String,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        guard UserDefaults.standard.bool(forKey: Pref.providerControlsEnabled) else {
            completion(.failure(ClientError.server("Enable provider controls in Labs first")))
            return
        }
        let task = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let folder = (cwd as NSString).expandingTildeInPath
        guard !task.isEmpty else {
            completion(.failure(ClientError.invalidPrompt)); return
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            completion(.failure(ClientError.invalidDirectory)); return
        }

        queue.async { [weak self] in
            self?.ensureConnected { result in
                guard let self else { return }
                switch result {
                case .failure(let error): self.finish(completion, with: .failure(error))
                case .success:
                    self.sendRequest(
                        method: "thread/start",
                        params: [
                            "cwd": folder,
                            "approvalPolicy": "never",
                            "sandbox": "workspace-write",
                        ]
                    ) { response in
                        switch response {
                        case .failure(let error):
                            self.finish(completion, with: .failure(error))
                        case .success(let result):
                            guard let thread = result["thread"] as? [String: Any],
                                let threadID = thread["id"] as? String
                            else {
                                self.finish(completion, with: .failure(ClientError.invalidResponse))
                                return
                            }
                            let title = Self.title(forProjectAt: folder)
                            self.managed[threadID] = ManagedThread(
                                id: threadID,
                                createdAt: Date(),
                                cwd: (result["cwd"] as? String) ?? folder,
                                model: result["model"] as? String,
                                transcriptPath: thread["path"] as? String,
                                title: title,
                                taskAnchor: TaskPresentationResolver.substantive(task) ?? task,
                                lastPrompt: task,
                                lastMessage: nil,
                                activity: "Starting…",
                                status: .idle,
                                observation: .rich(
                                    "Codex app-server", authority: .officialLive),
                                activeTurnID: nil,
                                lastTurnID: nil,
                                turnStartedAt: nil,
                                interruptionRequested: false
                            )
                            self.loadedThreads.insert(threadID)
                            self.persistManagedThreads()
                            self.publish()
                            self.startTurn(threadID: threadID, text: task) { turnResult in
                                if case .failure(let error) = turnResult {
                                    self.failTurn(threadID: threadID, error: error)
                                }
                                self.finish(completion, with: turnResult)
                            }
                        }
                    }
                }
            }
        }
    }

    func send(
        _ text: String, to threadID: String,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        guard UserDefaults.standard.bool(forKey: Pref.providerControlsEnabled) else {
            completion(.failure(ClientError.server("Provider controls are disabled in Labs")))
            return
        }
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else {
            completion(.failure(ClientError.invalidPrompt)); return
        }
        queue.async { [weak self] in
            guard let self, self.managed[threadID] != nil else {
                self?.finish(completion, with: .failure(ClientError.unknownThread))
                return
            }
            self.ensureConnected { result in
                switch result {
                case .failure(let error): self.finish(completion, with: .failure(error))
                case .success:
                    self.ensureLoaded(threadID: threadID) { loadResult in
                        switch loadResult {
                        case .failure(let error): self.finish(completion, with: .failure(error))
                        case .success:
                            self.update(threadID) {
                                $0.lastPrompt = prompt
                                if let substantive = TaskPresentationResolver.substantive(prompt) {
                                    $0.taskAnchor = substantive
                                }
                                $0.lastMessage = nil
                                $0.activity = "Starting…"
                            }
                            self.publishAcknowledged(threadID: threadID)
                            self.startTurn(threadID: threadID, text: prompt) { turnResult in
                                if case .failure(let error) = turnResult {
                                    self.failTurn(threadID: threadID, error: error)
                                }
                                self.finish(completion, with: turnResult)
                            }
                        }
                    }
                }
            }
        }
    }

    /// Interrupts only a turn started through this client. External Codex
    /// sessions never enter `managed`, so they cannot be controlled here.
    func interrupt(
        threadID: String,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        queue.async { [weak self] in
            guard let self, let thread = self.managed[threadID] else {
                self?.finish(completion, with: .failure(ClientError.unknownThread))
                return
            }
            guard self.connectionState == .ready, self.process?.isRunning == true else {
                self.finish(completion, with: .failure(ClientError.connectionStopped))
                return
            }
            guard let turnID = thread.activeTurnID else {
                self.finish(completion, with: .failure(ClientError.noActiveTurn))
                return
            }
            if thread.interruptionRequested {
                self.finish(completion, with: .success(()))
                return
            }

            self.update(threadID) {
                $0.interruptionRequested = true
                $0.activity = "Stopping…"
            }
            self.publish()
            self.sendRequest(
                method: "turn/interrupt",
                params: ["threadId": threadID, "turnId": turnID]
            ) { result in
                if case .failure = result {
                    self.update(threadID) {
                        guard $0.activeTurnID == turnID else { return }
                        $0.interruptionRequested = false
                        $0.activity = "Thinking…"
                    }
                    self.publish()
                }
                self.finish(completion, with: result.map { _ in () })
            }
        }
    }

    /// Forgets only LoopFwd's local card identity. Codex remains the owner of
    /// the thread and rollout file, so removing a card never deletes provider
    /// history. A live turn must be stopped first.
    func remove(
        threadID: String,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        queue.async { [weak self] in
            guard let self, let thread = self.managed[threadID] else {
                self?.finish(completion, with: .failure(ClientError.unknownThread))
                return
            }
            guard thread.status != .working, thread.activeTurnID == nil else {
                self.finish(completion, with: .failure(ClientError.turnStillRunning))
                return
            }

            self.managed.removeValue(forKey: threadID)
            self.loadedThreads.remove(threadID)
            self.persistManagedThreads()
            self.publish()
            self.finish(completion, with: .success(()))
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.refreshTimer?.cancel()
            self.outputPipe?.fileHandleForReading.readabilityHandler = nil
            self.process?.interrupt()
            self.resetConnection(error: ClientError.connectionStopped)
        }
    }

    // MARK: - Connection

    private func ensureConnected(_ completion: @escaping (Result<Void, Error>) -> Void) {
        switch connectionState {
        case .ready:
            completion(.success(()))
        case .starting:
            readyWaiters.append(completion)
        case .stopped:
            readyWaiters.append(completion)
            launch()
        }
    }

    private func launch() {
        guard let executable = AgentKind.codex.installedCLIPath else {
            completeReadyWaiters(.failure(ClientError.codexNotFound)); return
        }

        connectionState = .starting
        let process = Process()
        let input = Pipe(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["app-server", "--listen", "stdio://"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.queue.async { self?.consume(data) }
        }
        process.terminationHandler = { [weak self] _ in
            self?.queue.async { self?.resetConnection(error: ClientError.connectionStopped) }
        }

        do {
            try process.run()
            self.process = process
            inputPipe = input
            outputPipe = output
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            resetConnection(error: error)
            return
        }

        sendRequest(
            method: "initialize",
            params: [
                "clientInfo": ["name": "loopfwd", "title": "LoopFwd", "version": "0.1"]
            ]
        ) { [weak self] response in
            guard let self else { return }
            switch response {
            case .failure(let error):
                self.resetConnection(error: error)
            case .success:
                do {
                    try self.write(["method": "initialized", "params": [:] as [String: Any]])
                    self.connectionState = .ready
                    self.completeReadyWaiters(.success(()))
                } catch {
                    self.resetConnection(error: error)
                }
            }
        }
    }

    private func ensureLoaded(
        threadID: String,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        guard !loadedThreads.contains(threadID) else { completion(.success(())); return }
        sendRequest(method: "thread/resume", params: ["threadId": threadID]) { [weak self] result in
            if case .success = result { self?.loadedThreads.insert(threadID) }
            completion(result.map { _ in () })
        }
    }

    private func startTurn(
        threadID: String, text: String,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        sendRequest(
            method: "turn/start",
            params: [
                "threadId": threadID,
                "input": [["type": "text", "text": text]],
            ]
        ) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let response):
                guard let turn = response["turn"] as? [String: Any],
                    let turnID = turn["id"] as? String
                else {
                    completion(.failure(ClientError.invalidResponse))
                    return
                }
                self.update(threadID) {
                    $0.activeTurnID = turnID
                    $0.lastTurnID = turnID
                    $0.turnStartedAt = Date()
                    $0.interruptionRequested = false
                }
                self.publish()
                completion(.success(()))
            }
        }
    }

    private func sendRequest(
        method: String, params: [String: Any],
        completion: @escaping (Result<[String: Any], Error>) -> Void
    ) {
        let id = nextRequestID
        nextRequestID += 1
        pending[id] = completion
        do {
            try write(["method": method, "id": id, "params": params])
        } catch {
            pending.removeValue(forKey: id)
            completion(.failure(error))
            return
        }
        queue.asyncAfter(deadline: .now() + 45) { [weak self] in
            guard let callback = self?.pending.removeValue(forKey: id) else { return }
            callback(.failure(ClientError.timedOut))
        }
    }

    private func write(_ object: [String: Any]) throws {
        guard let handle = inputPipe?.fileHandleForWriting, process?.isRunning == true else {
            throw ClientError.connectionStopped
        }
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        try handle.write(contentsOf: data)
    }

    private func consume(_ data: Data) {
        var incoming = data
        if discardingOversizedRecord {
            guard let newline = incoming.firstIndex(of: 0x0A) else { return }
            incoming = Data(incoming[incoming.index(after: newline)...])
            discardingOversizedRecord = false
        }
        outputBuffer.append(incoming)
        while let newline = outputBuffer.firstIndex(of: 0x0A) {
            let line = outputBuffer[..<newline]
            outputBuffer.removeSubrange(...newline)
            guard !line.isEmpty, line.count <= 8 * 1024 * 1024,
                let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any]
            else { continue }
            handle(object)
        }
        if outputBuffer.count > 8 * 1024 * 1024 {
            outputBuffer.removeAll(keepingCapacity: false)
            discardingOversizedRecord = true
            for id in Array(managed.keys) {
                update(id) {
                    $0.observation.mode = .stale
                    $0.observation.reason = "Codex response exceeded the record size budget"
                }
            }
            publish()
        }
    }

    private func handle(_ object: [String: Any]) {
        if let id = object["id"] as? Int, let callback = pending.removeValue(forKey: id) {
            if let error = object["error"] as? [String: Any] {
                callback(.failure(ClientError.server(error["message"] as? String ?? "Codex request failed")))
            } else if let result = object["result"] as? [String: Any] {
                callback(.success(result))
            } else {
                callback(.failure(ClientError.invalidResponse))
            }
            return
        }
        guard let method = object["method"] as? String,
            let params = object["params"] as? [String: Any],
            let threadID = params["threadId"] as? String,
            managed[threadID] != nil
        else { return }

        switch method {
        case "turn/started":
            let turnID = (params["turn"] as? [String: Any])?["id"] as? String
            update(threadID) {
                $0.status = .working
                $0.activity = "Thinking…"
                $0.observation = .rich("Codex app-server", authority: .officialLive)
                $0.activeTurnID = turnID ?? $0.activeTurnID
                $0.lastTurnID = turnID ?? $0.lastTurnID
                $0.turnStartedAt = Date()
            }
            publish()
        case "item/agentMessage/delta":
            guard let delta = params["delta"] as? String else { return }
            update(threadID) {
                $0.lastMessage = String((($0.lastMessage ?? "") + delta.prefix(32_768)).suffix(32_768))
                $0.observation.updatedAt = Date()
                $0.activity = "Replying…"
            }
            publish()
        case "item/started":
            guard let item = params["item"] as? [String: Any],
                let activity = Self.activity(for: item)
            else { return }
            update(threadID) { $0.activity = activity }
            publish()
        case "turn/completed":
            let turn = params["turn"] as? [String: Any]
            let turnStatus = turn?["status"] as? String
            let interrupted =
                managed[threadID]?.interruptionRequested == true
                || turnStatus == "interrupted"
            let outcome: AgentStatus =
                interrupted
                ? .stopped : turnStatus == "failed" ? .failed : turnStatus == "completed" ? .completed : .idle
            if !interrupted, let turn, let message = Self.finalMessage(in: turn) {
                update(threadID) { $0.lastMessage = message }
            }
            update(threadID) {
                $0.status = outcome
                $0.activity = nil
                $0.observation = .rich("Codex app-server", authority: .officialLive)
                $0.activeTurnID = nil
                $0.interruptionRequested = false
                if interrupted { $0.lastMessage = "Stopped by you" }
            }
            publish()
        default:
            break
        }
    }

    private func resetConnection(error: Error) {
        guard connectionState != .stopped || process != nil else { return }
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        process = nil
        inputPipe = nil
        outputPipe = nil
        outputBuffer.removeAll(keepingCapacity: true)
        discardingOversizedRecord = false
        loadedThreads.removeAll()
        connectionState = .stopped
        let callbacks = Array(pending.values)
        pending.removeAll()
        callbacks.forEach { $0(.failure(error)) }
        completeReadyWaiters(.failure(error))
        for id in Array(managed.keys) {
            update(id) {
                // A transport loss is not an end-of-turn event.
                $0.observation = .init(
                    mode: .stale,
                    updatedAt: $0.observation.updatedAt,
                    source: "Codex app-server",
                    reason: "The managed Codex connection is not active"
                )
                $0.activeTurnID = nil
                $0.interruptionRequested = false
            }
        }
        publish()
        scheduleStalePrune()
    }

    private func completeReadyWaiters(_ result: Result<Void, Error>) {
        let waiters = readyWaiters
        readyWaiters.removeAll()
        waiters.forEach { $0(result) }
    }

    // MARK: - Session projection

    /// Re-read only owned rollouts after a disconnect; this never reconnects
    /// app-server or sends a task. New provider data can resolve stale state.
    private func refreshRecovery() {
        for (id, thread) in managed where thread.observation.mode == .stale {
            guard let path = thread.transcriptPath,
                let modified = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date,
                modified > thread.observation.updatedAt
            else { continue }
            let info = CodexSessions.tailInfo(path: path)
            guard info.readSucceeded, info.phase != .unknown else { continue }
            update(id) {
                switch info.phase {
                case .working: $0.status = .working
                case .completed: $0.status = .completed
                case .failed: $0.status = .failed
                case .stopped: $0.status = .stopped
                case .unknown: break
                }
                $0.lastTurnID = info.turnID ?? $0.lastTurnID
                $0.lastPrompt = info.lastPrompt ?? $0.lastPrompt
                $0.lastMessage = info.lastMessage ?? $0.lastMessage
                $0.activity = info.activity
                $0.observation = .rich("Codex rollout recovery", updatedAt: modified)
            }
        }
    }

    private func update(_ threadID: String, _ mutate: (inout ManagedThread) -> Void) {
        guard var thread = managed[threadID] else { return }
        mutate(&thread)
        managed[threadID] = thread
    }

    private func failTurn(threadID: String, error: Error) {
        update(threadID) {
            $0.lastMessage = error.localizedDescription
            $0.observation = .init(
                mode: .stale,
                updatedAt: $0.observation.updatedAt,
                source: "Codex app-server",
                reason: error.localizedDescription
            )
            $0.activeTurnID = nil
            $0.interruptionRequested = false
        }
        publish()
        scheduleStalePrune()
    }

    /// Connection failures remain visible briefly so the user can understand
    /// what happened. If no richer observation replaces them, they leave the
    /// active island without deleting the provider-owned Codex conversation.
    private func scheduleStalePrune() {
        let grace = IntegrationProfiles.profile(for: .codexManaged, kind: .codex)
            .reconciliationGrace
        queue.asyncAfter(deadline: .now() + grace) { [weak self] in
            guard let self else { return }
            // Expire only the visible projection, never the recoverable owned
            // thread identity. Removal remains an explicit user operation.
            self.publish()
        }
    }

    private func publish() {
        let reduction = lifecycle.reduce(managed.values.map(Self.agent), suppressEvents: false)
        DispatchQueue.main.async {
            self.agents = reduction.sessions
            AgentLifecycleEventEmitter.emit(reduction.events)
        }
    }

    private func publishAcknowledged(threadID: String) {
        publish()
        let id = "codex:\(threadID)"
        DispatchQueue.main.async {
            AgentNotificationRouter.shared.markHandled(sessionID: id)
        }
    }

    private func persistManagedThreads() {
        let records = managed.values
            .sorted { $0.createdAt > $1.createdAt }
            .map {
                StoredThread(
                    id: $0.id,
                    createdAt: $0.createdAt,
                    cwd: $0.cwd,
                    model: $0.model,
                    transcriptPath: $0.transcriptPath,
                    title: $0.title
                )
            }
        guard let data = try? JSONEncoder().encode(Array(records)) else { return }
        UserDefaults.standard.set(data, forKey: Pref.managedCodexThreads)
    }

    private func finish(
        _ completion: @escaping (Result<Void, Error>) -> Void,
        with result: Result<Void, Error>
    ) {
        DispatchQueue.main.async { completion(result) }
    }

    private static func agent(_ thread: ManagedThread) -> AgentSession {
        AgentSession(
            id: "codex:\(thread.id)",
            kind: .codex,
            cpu: thread.status == .working ? 1 : 0,
            elapsed: elapsed(since: thread.createdAt),
            cwd: thread.cwd,
            status: thread.status,
            terminalApp: nil,
            tty: nil,
            bypassPermissions: false,
            returnTarget: CodexDeepLink.returnTarget(threadID: thread.id),
            observation: thread.observation,
            title: thread.title,
            lastPrompt: thread.lastPrompt,
            lastMessage: thread.lastMessage,
            activity: thread.activity,
            transcriptPath: thread.transcriptPath,
            model: thread.model,
            codexManagedControl: CodexManagedControl(threadID: thread.id),
            turnID: thread.lastTurnID,
            taskStartedAt: thread.turnStartedAt,
            stateChangedAt: thread.observation.updatedAt,
            lastProgressAt: thread.observation.updatedAt,
            capabilities: [
                .observeSession, .observeTask, .observeStep, .observeCompletion,
                .observeAttention, .exactReturn, .reply, .stop,
            ],
            surfaceID: .codexManaged,
            taskAnchor: thread.taskAnchor
        )
    }

    private static func restoreStoredThreads() -> [StoredThread] {
        guard let data = UserDefaults.standard.data(forKey: Pref.managedCodexThreads),
            let records = try? JSONDecoder().decode([StoredThread].self, from: data)
        else { return [] }
        return records
    }

    private static func restore(_ record: StoredThread) -> ManagedThread? {
        let existingPath = record.transcriptPath.flatMap { path in
            FileManager.default.fileExists(atPath: path) ? path : nil
        }
        let info = existingPath.map(CodexSessions.tailInfo(path:))
        let modified = existingPath.flatMap {
            (try? FileManager.default.attributesOfItem(atPath: $0)[.modificationDate]) as? Date
        }
        let status: AgentStatus
        let observation: ObservationHealth
        switch info?.phase {
        case .working:
            status = .working
            observation = .rich("Codex rollout recovery", updatedAt: modified ?? Date())
        case .completed:
            status = .completed
            observation = .rich("Codex rollout recovery", updatedAt: modified ?? Date())
        case .failed:
            status = .failed
            observation = .rich("Codex rollout recovery", updatedAt: modified ?? Date())
        case .stopped:
            status = .stopped
            observation = .rich("Codex rollout recovery", updatedAt: modified ?? Date())
        case .unknown, .none:
            status = .idle
            observation = .init(
                mode: .stale,
                updatedAt: modified ?? record.createdAt,
                source: "Codex rollout recovery",
                reason: existingPath == nil
                    ? "The stored Codex rollout is no longer available"
                    : "No current Codex task boundary could be confirmed"
            )
        }
        return ManagedThread(
            id: record.id,
            createdAt: record.createdAt,
            cwd: record.cwd,
            model: info?.model ?? record.model,
            transcriptPath: record.transcriptPath,
            title: title(forProjectAt: record.cwd),
            taskAnchor: info?.lastPrompt.flatMap(TaskPresentationResolver.substantive),
            lastPrompt: info?.lastPrompt,
            lastMessage: info?.lastMessage,
            activity: status == .working ? info?.activity ?? "Thinking…" : nil,
            status: status,
            observation: observation,
            activeTurnID: nil,
            lastTurnID: info?.turnID,
            turnStartedAt: nil,
            interruptionRequested: false
        )
    }

    private static func elapsed(since date: Date) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince(date)))
        if seconds >= 3600 { return "\(seconds / 3600)h \((seconds % 3600) / 60)m" }
        if seconds >= 60 { return "\(seconds / 60)m" }
        return "<1m"
    }

    private static func title(forProjectAt path: String) -> String {
        let folder = (path as NSString).lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard folder.count > 1 else { return "Codex task" }
        return folder.count > 56 ? String(folder.prefix(55)) + "…" : folder
    }

    private static func activity(for item: [String: Any]) -> String? {
        switch item["type"] as? String {
        case "commandExecution": return "Running a command"
        case "fileChange": return "Editing files"
        case "reasoning": return "Thinking…"
        default: return nil
        }
    }

    private static func finalMessage(in turn: [String: Any]) -> String? {
        guard let items = turn["items"] as? [[String: Any]] else { return nil }
        return items.reversed().first { $0["type"] as? String == "agentMessage" }?["text"] as? String
    }

    enum ClientError: LocalizedError {
        case codexNotFound, invalidPrompt, invalidDirectory, invalidResponse
        case unknownThread, noActiveTurn, turnStillRunning, connectionStopped, timedOut, server(String)

        var errorDescription: String? {
            switch self {
            case .codexNotFound: return "Codex CLI was not found."
            case .invalidPrompt: return "Enter a task first."
            case .invalidDirectory: return "Choose an existing project folder."
            case .invalidResponse: return "Codex returned an unreadable response."
            case .unknownThread: return "This managed Codex task is no longer available."
            case .noActiveTurn: return "This Codex task is not currently running."
            case .turnStillRunning: return "Stop this Codex task before removing it."
            case .connectionStopped: return "The Codex connection stopped."
            case .timedOut: return "Codex did not respond in time."
            case .server(let message): return message
            }
        }
    }
}
