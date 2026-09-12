import Foundation

/// Permission approvals from the island.
///
/// A Claude Code **Notification hook** (installed via Settings → Integrations)
/// writes each notification's JSON to ~/.claude/loopfwd/notifications/.
/// This center watches that spool, matches "needs your permission" events to
/// running sessions, and answers the terminal prompt by sending the digit
/// keys: 1 = Yes, 2 = Yes for this session, 3 = No. The hook never blocks
/// Claude — the terminal prompt stays usable in parallel.
final class ApprovalCenter: ObservableObject {
    static let shared = ApprovalCenter()

    struct RequestIdentity: Hashable {
        let sessionID: String
        let processID: Int32
        let processStartedAt: String

        init?(agent: AgentSession, sessionID: String) {
            guard agent.kind == .claude, agent.id == "claude:\(sessionID)",
                agent.observation.mode == .rich,
                let pid = agent.processID, let birth = agent.processStartedAt, !birth.isEmpty
            else { return nil }
            self.sessionID = sessionID
            processID = pid
            processStartedAt = birth
        }

        func matches(_ agent: AgentSession) -> Bool {
            agent.kind == .claude && agent.id == "claude:\(sessionID)"
                && agent.processID == processID && agent.processStartedAt == processStartedAt
                && agent.observation.mode == .rich
        }
    }

    struct Approval: Equatable {
        let identity: RequestIdentity
        let message: String  // "Claude needs your permission to use Bash"
        let toolName: String?
        let at: Date
        var activityAtCreate: String?
    }

    enum Action {
        case approve, alwaysAllow, deny

        var key: String {
            switch self {
            case .approve: return "1"
            case .alwaysAllow: return "2"
            case .deny: return "3"
            }
        }
    }

    @Published private(set) var pending: [Int32: Approval] = [:]
    var hasPending: Bool { !pending.isEmpty }
    var hasControllablePending: Bool {
        pending.contains { pid, request in
            AgentMonitor.shared.agents.contains {
                $0.processID == pid && request.identity.matches($0)
                    && $0.status == .needsAttention && TerminalBridge.canSend(to: $0)
            }
        }
    }

    /// Live AskUserQuestion prompts, delivered by the PreToolUse hook the moment
    /// the question opens (the transcript only records it after it's answered).
    struct QuestionEntry: Equatable {
        let identity: RequestIdentity
        let requestID: String
        let question: PendingQuestion
        let at: Date
    }
    @Published private(set) var questions: [Int32: QuestionEntry] = [:]
    private struct QuestionKey: Hashable {
        let identity: RequestIdentity
        let requestID: String
    }
    private var closedQuestions: [QuestionKey: Date] = [:]
    private var questionObservationSuspendedUntil = Date.distantPast

    func question(for agent: AgentSession) -> QuestionEntry? {
        guard let pid = agent.processID, let entry = questions[pid], entry.identity.matches(agent) else { return nil }
        return entry
    }

    func approval(for agent: AgentSession) -> Approval? {
        guard let pid = agent.processID, let entry = pending[pid], entry.identity.matches(agent) else { return nil }
        return entry
    }

    func receiveQuestion(_ entry: QuestionEntry) {
        let now = Date()
        closedQuestions = closedQuestions.filter { $0.value > now }
        guard now >= questionObservationSuspendedUntil,
            closedQuestions[.init(identity: entry.identity, requestID: entry.requestID)] == nil
        else { return }
        if let previous = questions[entry.identity.processID], previous.at > entry.at { return }
        questions[entry.identity.processID] = entry
    }

    func closeQuestion(identity: RequestIdentity, requestID: String) {
        let now = Date()
        closedQuestions = closedQuestions.filter { $0.value > now }
        let key = QuestionKey(identity: identity, requestID: requestID)
        // Async hooks can deliver Post before Pre, even across spool drains.
        // Never evict a live close barrier to make room for another event.
        if closedQuestions[key] == nil, closedQuestions.count >= 128 {
            questionObservationSuspendedUntil = now.addingTimeInterval(30 * 60)
            questions.removeAll()
            OperationalDiagnostics.shared.recordControlFailure(
                "Claude question observation paused: event capacity exceeded")
        } else {
            closedQuestions[key] = now.addingTimeInterval(30 * 60)
        }
        if let entry = questions[identity.processID], entry.identity == identity, entry.requestID == requestID {
            questions[identity.processID] = nil
        }
    }

    /// Source ancestry is captured by the hook when the event is emitted,
    /// not invented when a later process resumes the same session ID.
    static func hookSourceMatches(_ envelope: [String: Any], meta: ClaudeSessions.Meta) -> Bool {
        guard let version = envelope["loopfwdHookVersion"] as? NSNumber,
            CFGetTypeID(version) != CFBooleanGetTypeID(), version == 1,
            let ancestry = envelope["ancestors"] as? [[String: Any]], ancestry.count <= 8,
            let expected = meta.processStartUTC, !expected.isEmpty
        else { return false }
        return ancestry.contains { origin in
            guard let pid = origin["pid"] as? NSNumber, CFGetTypeID(pid) != CFBooleanGetTypeID(),
                Int32(exactly: pid.doubleValue) == meta.pid, let birth = origin["startedAtUTC"] as? String
            else { return false }
            return birth.split(whereSeparator: \.isWhitespace).joined(separator: " ")
                == expected.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
    }

    private var timer: Timer?
    private static let home = FileManager.default.homeDirectoryForCurrentUser.path
    static var supportDirectoryOverride: String?
    static var supportDir: String { supportDirectoryOverride ?? home + "/.claude/loopfwd" }
    static var spoolDir: String { supportDir + "/notifications" }
    static var hookScriptPath: String { supportDir + "/notify-hook.sh" }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.drainSpool()
        }
    }

    // MARK: - Spool

    private func drainSpool() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: Self.spoolDir), !files.isEmpty
        else { return }

        let registry = ClaudeSessions.sessionsByPid()
        func identity(for sessionID: String, envelope: [String: Any]) -> RequestIdentity? {
            let matching = registry.values.filter { $0.sessionId == sessionID }
            guard matching.count == 1, let meta = matching.first,
                let agent = AgentMonitor.shared.agents.first(where: { $0.processID == meta.pid }),
                agent.transcriptPath == ClaudeSessions.transcriptPath(for: meta),
                Self.hookSourceMatches(envelope, meta: meta)
            else { return nil }
            return RequestIdentity(agent: agent, sessionID: sessionID)
        }
        for file in files.sorted() where file.hasSuffix(".json") {
            let path = Self.spoolDir + "/" + file
            guard let attributes = try? fm.attributesOfItem(atPath: path),
                attributes[.type] as? FileAttributeType == .typeRegular,
                let size = attributes[.size] as? NSNumber, size.intValue <= 256 * 1024,
                let at = attributes[.modificationDate] as? Date,
                Date().timeIntervalSince(at) >= -1, Date().timeIntervalSince(at) <= 30,
                let handle = FileHandle(forReadingAtPath: path)
            else { try? fm.removeItem(atPath: path); continue }  // unparseable → drop
            defer { try? handle.close() }
            guard let data = try? handle.read(upToCount: 256 * 1024 + 1), data.count <= 256 * 1024,
                let envelope = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                let obj = envelope["event"] as? [String: Any]
            else {
                OperationalDiagnostics.shared.recordControlFailure(
                    "Claude hook has no verified source identity; reinstall the observer")
                try? fm.removeItem(atPath: path); continue
            }

            let event = obj["hook_event_name"] as? String

            // AskUserQuestion lifecycle: PreToolUse fires the moment the prompt
            // opens (with the full questions/options JSON); PostToolUse when it's
            // answered. This is the only real-time source — the transcript gets
            // the tool_use only after the answer.
            if event == "PreToolUse" || event == "PostToolUse" {
                guard obj["tool_name"] as? String == "AskUserQuestion",
                    let sessionId = obj["session_id"] as? String,
                    let requestID = obj["tool_use_id"] as? String, !requestID.isEmpty, requestID.utf8.count <= 256
                else {
                    try? fm.removeItem(atPath: path); continue
                }
                guard let identity = identity(for: sessionId, envelope: envelope) else {
                    // Hook can beat the registry file — retry briefly, then drop.
                    if spoolFileAge(path) > 30 { try? fm.removeItem(atPath: path) }
                    continue
                }
                try? fm.removeItem(atPath: path)
                if event == "PreToolUse",
                    let input = obj["tool_input"] as? [String: Any],
                    let questionList = input["questions"] as? [[String: Any]],
                    questionList.count == 1,
                    let first = questionList.first
                {
                    let prompt =
                        (first["question"] as? String)
                        ?? (first["header"] as? String) ?? "Choose an option"
                    let options = (first["options"] as? [[String: Any]] ?? [])
                        .compactMap { $0["label"] as? String }
                    if !options.isEmpty {
                        let entry = QuestionEntry(
                            identity: identity,
                            requestID: requestID,
                            question: PendingQuestion(
                                prompt: prompt, options: options,
                                multiSelect: first["multiSelect"] as? Bool ?? false), at: at)
                        DispatchQueue.main.async {
                            self.receiveQuestion(entry)
                            AgentMonitor.shared.scanNow()
                        }
                    }
                } else if event == "PostToolUse" {
                    DispatchQueue.main.async {
                        self.closeQuestion(identity: identity, requestID: requestID)
                    }
                }
                continue
            }

            // PermissionRequest events carry the tool name directly; plain
            // Notification events only when the message mentions permission
            // (The card already carries the explicit needs-attention state.)
            let message = obj["message"] as? String ?? ""
            var tool: String?
            if event == "PermissionRequest" {
                tool = obj["tool_name"] as? String
            } else if event == "Notification", obj["notification_type"] as? String == "permission_prompt" {
                tool = toolName(from: message)
            } else {
                try? fm.removeItem(atPath: path); continue  // not a permission event
            }
            guard let sessionId = obj["session_id"] as? String else {
                try? fm.removeItem(atPath: path); continue
            }
            guard let identity = identity(for: sessionId, envelope: envelope) else {
                // The hook can beat Claude's own session-registry file to disk.
                // Keep the event so a later tick can match it once the pid is
                // known — but don't spool a never-matching event forever.
                if spoolFileAge(path) > 30 { try? fm.removeItem(atPath: path) }
                continue
            }
            let pid = identity.processID
            try? fm.removeItem(atPath: path)  // matched → consume
            let agent = AgentMonitor.shared.agents.first { $0.processID == pid }
            let toolName = tool
            DispatchQueue.main.async {
                if let previous = self.pending[pid], previous.at > at { return }
                self.pending[pid] = Approval(
                    identity: identity,
                    message: message,
                    toolName: toolName,
                    at: at,
                    activityAtCreate: agent?.activity
                )
                // Sticky Always by category: approve once without Island interrupt.
                if StickyPermissionAllow.isRemembered(toolName) {
                    self.stickyAutoApproving.insert(pid)
                    self.respond(pid: pid, action: .approve)
                    return
                }
                HotKeyCenter.shared.update()
                AgentMonitor.shared.scanNow()
            }
        }
    }

    /// Seconds since a spool file was written (greatestFiniteMagnitude if unknown).
    private func spoolFileAge(_ path: String) -> TimeInterval {
        let mtime = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        return mtime.map { Date().timeIntervalSince($0) } ?? .greatestFiniteMagnitude
    }

    /// "Claude needs your permission to use Bash" → "Bash"
    private func toolName(from message: String) -> String? {
        guard let range = message.range(of: "to use ") else { return nil }
        let tail = message[range.upperBound...]
        let name = tail.split(separator: " ").first.map(String.init)
        return name?.trimmingCharacters(in: CharacterSet(charactersIn: ".,:"))
    }

    // MARK: - Responding

    private var stickyAutoApproving: Set<Int32> = []

    func respond(pid: Int32, action: Action, completion: @escaping (Bool) -> Void = { _ in }) {
        guard UserDefaults.standard.bool(forKey: Pref.claudeControlsEnabled) else { completion(false); return }
        guard let request = pending[pid],
            let agent = AgentMonitor.shared.agents.first(where: { $0.processID == pid }),
            request.identity.matches(agent),
            agent.status == .needsAttention || stickyAutoApproving.contains(pid)
        else {
            pending[pid] = nil
            stickyAutoApproving.remove(pid)
            completion(false)
            return
        }
        // An unavailable control path does not resolve the real request.
        guard TerminalBridge.canSend(to: agent) else { completion(false); return }
        DispatchQueue.global(qos: .userInitiated).async {
            let success = TerminalBridge.sendKey(action.key, to: agent)
            DispatchQueue.main.async {
                self.stickyAutoApproving.remove(pid)
                if success, self.pending[pid] == request {
                    self.pending[pid] = nil
                    if action == .alwaysAllow {
                        StickyPermissionAllow.remember(request.toolName)
                    }
                    HotKeyCenter.shared.update()
                }
                completion(success)
            }
        }
    }

    func answerQuestion(text: String, to agent: AgentSession, completion: @escaping (Bool) -> Void) {
        guard UserDefaults.standard.bool(forKey: Pref.claudeControlsEnabled),
            let request = question(for: agent), agent.status == .needsAttention,
            let current = AgentMonitor.shared.agents.first(where: { $0.id == agent.id }),
            request.identity.matches(current), current.status == .needsAttention,
            agent.pendingQuestion == request.question, current.pendingQuestion == request.question
        else { completion(false); return }
        DispatchQueue.global(qos: .userInitiated).async {
            let success = TerminalBridge.send(text: text, to: current)
            DispatchQueue.main.async {
                if success {
                    self.closeQuestion(identity: request.identity, requestID: request.requestID)
                }
                completion(success)
            }
        }
    }

    /// Hotkey path: acts on the most recent pending approval.
    func respondToNewest(action: Action) {
        let eligible = pending.filter { pid, request in
            AgentMonitor.shared.agents.contains {
                $0.processID == pid && request.identity.matches($0) && TerminalBridge.canSend(to: $0)
            }
        }
        guard let pid = eligible.max(by: { $0.value.at < $1.value.at })?.key else { return }
        respond(pid: pid, action: action)
    }

    /// Called after each monitor scan: drop approvals answered in the
    /// terminal (activity moved on / turn ended) or gone stale.
    func sync(agents: [AgentSession]) {
        guard hasPending || !questions.isEmpty else { return }
        let byPid = Dictionary(
            agents.compactMap { agent in
                agent.processID.map { ($0, agent) }
            }, uniquingKeysWith: { first, _ in first })

        // Questions: answered in the terminal (agent busy again), session gone,
        // or stale → drop. The PostToolUse hook usually clears them first.
        for (pid, entry) in questions {
            let agent = byPid[pid]
            if agent.map({ !entry.identity.matches($0) }) ?? true
                || (agent?.status == .working && (agent?.observation.updatedAt ?? .distantPast) > entry.at)
                || Date().timeIntervalSince(entry.at) > 30 * 60
            {
                closeQuestion(identity: entry.identity, requestID: entry.requestID)
            }
        }

        guard hasPending else { return }
        var changed = false
        for (pid, approval) in pending {
            let agent = byPid[pid]
            let answeredInTerminal =
                agent.map {
                    $0.observation.updatedAt > approval.at
                        && ((!$0.status.isActive && $0.status != .needsAttention)
                            || $0.activity != approval.activityAtCreate)
                } ?? true
            if agent.map({ !approval.identity.matches($0) }) ?? true
                || answeredInTerminal || Date().timeIntervalSince(approval.at) > 10 * 60
            {
                pending[pid] = nil
                changed = true
            }
        }
        if changed { HotKeyCenter.shared.update() }
    }

    // MARK: - Hook installation (Settings → Integrations)

    /// Only a matched, non-expired live hook enters the shared state model.
    /// The resulting observation still grants no automatic control authority.
    func projectLiveRequests(_ agents: [AgentSession]) -> [AgentSession] {
        sync(agents: agents)
        return agents.map { original in
            guard original.kind == .claude, let pid = original.processID else { return original }
            var agent = original
            if let request = pending[pid], request.identity.matches(original) {
                agent.status = .needsAttention
                agent.attentionKind = .approval
                agent.lastMessage = request.message
                agent.observation = .rich("Claude hook", updatedAt: request.at, authority: .officialLive)
            } else if let request = questions[pid], request.identity.matches(original) {
                agent.status = .needsAttention
                agent.attentionKind = .question
                agent.pendingQuestion = request.question
                agent.observation = .rich("Claude hook", updatedAt: request.at, authority: .officialLive)
            }
            return agent
        }
    }

    /// Claude Code settings file the hook is registered in.
    /// (Overridable so tests never touch the real file.)
    static var settingsPathOverride: String?
    static var claudeSettingsPath: String {
        settingsPathOverride ?? ProviderDataLocations.claudeConfigurationDirectory + "/settings.json"
    }

    static var hookBackupDirectory: URL {
        ClaudeHookInstaller.backupRoot(for: URL(fileURLWithPath: claudeSettingsPath))
    }

    static var hookInstalled: Bool {
        guard let data = FileManager.default.contents(atPath: claudeSettingsPath),
            case .parsed(let root) = HookSettings.load(data: data)
        else { return false }
        return HookSettings.isInstalled(in: root, hookPath: hookScriptPath)
    }

    static var hookNeedsUpdate: Bool {
        hookInstalled
            && (try? String(contentsOfFile: hookScriptPath, encoding: .utf8)) != hookScript(spoolDirectory: spoolDir)
    }

    static func hookScript(spoolDirectory: String) -> String {
        let directory = "'" + spoolDirectory.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return #"""
            #!/bin/bash
            # Installed by LoopFwd. Source-bound Claude hook v1.
            umask 077
            dir=\#(directory)
            /bin/mkdir -p "$dir" || exit 0
            /bin/chmod 700 "$dir" || exit 0
            origin=$PPID
            ancestors=""
            for ((i=0; i<8; i++)); do
                [[ "$origin" =~ ^[0-9]+$ ]] && (( origin > 1 )) || break
                row=$(LC_ALL=C TZ=UTC /bin/ps -p "$origin" -o ppid=,lstart=) || break
                read -r parent birth <<< "$row"
                [[ "$birth" =~ ^[A-Za-z0-9:\ ]+$ ]] || break
                ancestors+="${ancestors:+,}{\"pid\":$origin,\"startedAtUTC\":\"$birth\"}"
                origin=$parent
            done
            name="$(/bin/date +%s)-$$-$RANDOM.json"
            tmp="$dir/.$name.partial"
            {
                printf '{"loopfwdHookVersion":1,"ancestors":[%s],"event":' "$ancestors"
                /usr/bin/head -c 262145
                printf '}\n'
            } > "$tmp" && /bin/mv -f "$tmp" "$dir/$name" || /bin/rm -f "$tmp"
            exit 0
            """#
    }

    @discardableResult
    static func installHook() -> Result<Void, Error> {
        do {
            try installHookThrowing()
            return .success(())
        } catch {
            NSLog("[LoopFwd] hook installation failed: %@", error.localizedDescription)
            return .failure(error)
        }
    }

    private static func installHookThrowing() throws {
        try ClaudeHookInstaller.update(
            install: true,
            settings: URL(fileURLWithPath: claudeSettingsPath),
            scriptURL: URL(fileURLWithPath: hookScriptPath),
            script: Data(hookScript(spoolDirectory: spoolDir).utf8))
    }

    @discardableResult
    static func uninstallHook() -> Result<Void, Error> {
        do {
            try ClaudeHookInstaller.update(
                install: false,
                settings: URL(fileURLWithPath: claudeSettingsPath),
                scriptURL: URL(fileURLWithPath: hookScriptPath),
                script: Data(hookScript(spoolDirectory: spoolDir).utf8))
            return .success(())
        } catch {
            NSLog("[LoopFwd] hook removal failed: %@", error.localizedDescription)
            return .failure(error)
        }
    }
}

extension Notification.Name {
    /// Posted with the pid as `object` when a permission request arrives.
    static let approvalNeeded = Notification.Name("approvalNeeded")
}
