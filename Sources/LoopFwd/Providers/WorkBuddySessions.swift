import Foundation

/// Desktop observation only. Neither a WorkBuddy process nor its history proves
/// that a task is active. Shared CLI hosts may own several independent sessions.
enum WorkBuddySessions {
    static let bundleIdentifier = "com.tencent.workbuddy.mac"
    static let cliVersion = "2.137.1"
    static let appVersion = "5.5.3"
    static let source = "WorkBuddy desktop Hook observer schema 1"
    // Scanner calls are serialized. Deferred hosts/sessions resume first.
    private static var pendingPID: Int32?
    private static var pendingScope: [Int32: String] = [:]
    private static var previousObservations: [AgentSession] = []
    private static var previousRoot: String?

    struct ProcessIdentity {
        let command: String
        let startedAt: String
    }

    /// Setup reads package metadata instead of starting WorkBuddy's private CLI,
    /// whose normal initialization can load settings and account migrations.
    static func installationCompatible(at app: URL) -> Bool {
        func bytes(_ relative: String) -> Data? {
            guard let handle = FileHandle(forReadingAtPath: app.appendingPathComponent(relative).path) else {
                return nil
            }
            defer { try? handle.close() }
            guard let data = try? handle.read(upToCount: 128 * 1024 + 1), data.count <= 128 * 1024 else { return nil }
            return data
        }
        guard let info = bytes("Contents/Info.plist"),
            let plist = (try? PropertyListSerialization.propertyList(from: info, format: nil)) as? [String: Any],
            plist["CFBundleIdentifier"] as? String == bundleIdentifier,
            plist["CFBundleShortVersionString"] as? String == appVersion,
            let package = bytes("Contents/Resources/app.asar.unpacked/cli/package.json"),
            let object = (try? JSONSerialization.jsonObject(with: package)) as? [String: Any]
        else { return false }
        let publish = object["publishConfig"] as? [String: Any]
        let custom = publish?["customPackage"] as? [String: Any]
        return (custom?["version"] as? String ?? object["version"] as? String) == cliVersion
    }

    static func cliCommand(_ command: String, belongsTo appPath: String) -> Bool {
        guard command.contains(appPath + "/Contents/Resources/app.asar.unpacked/cli/") else { return false }
        let app = NSRegularExpression.escapedPattern(for: appPath)
        let cli =
            app + #"/Contents/Resources/app\.asar\.unpacked/cli/(?:bin/codebuddy|dist/codebuddy(?:-headless)?\.js)"#
        let launcher =
            #"(?:\S*/node|\S*/nodejs|"# + app
            + #"/Contents/(?:MacOS/WorkBuddy|Frameworks/WorkBuddy Helper(?: \([A-Za-z ]+\))?\.app/Contents/MacOS/WorkBuddy Helper(?: \([A-Za-z ]+\))?)) +"#
        return command.range(of: "^(?:" + launcher + ")?" + cli + "(?: |$)", options: .regularExpression) != nil
    }

    static func sessionURL(_ id: String) -> URL? {
        guard id.utf8.count <= 128,
            id.range(of: #"^[a-zA-Z0-9][a-zA-Z0-9_:-]*$"#, options: .regularExpression) != nil
        else { return nil }
        // encodeURIComponent's path-segment semantics, not a query or a task-creation URL.
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        guard let encoded = id.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: "workbuddy://chat/" + encoded)
    }

    /// `applications` come from currently running, Bundle-ID-verified apps,
    /// not a path supplied by the observer. All births are from this scan's ps.
    static func read(
        processes: [Int32: ProcessIdentity], applications: [String: String],
        configRoot: (Int32) -> String?, observerRoot: String? = nil, now: Date = Date()
    ) -> ProviderReadResult {
        var sessions: [AgentSession] = []
        var partial = false
        var missingObserver = false
        let eventRoot = observerRoot ?? LocalHookEvents.defaultRoot
        if previousRoot != eventRoot {
            previousRoot = eventRoot; previousObservations = []; pendingScope = [:]; pendingPID = nil
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 0.8
        pendingScope = pendingScope.filter { processes[$0.key] != nil }
        let scopes =
            (try? FileManager.default.contentsOfDirectory(atPath: observerRoot ?? LocalHookEvents.defaultRoot)) ?? []
        let ordered = processes.sorted(by: { $0.key < $1.key })
        let start = pendingPID.flatMap { id in ordered.firstIndex { $0.key == id } } ?? 0
        pendingPID = nil
        for (pid, process) in Array(ordered.dropFirst(start)) + Array(ordered.prefix(start)) {
            guard let appPath = applications.keys.sorted().first(where: { cliCommand(process.command, belongsTo: $0) })
            else {
                continue
            }
            if ProcessInfo.processInfo.systemUptime >= deadline { partial = true; pendingPID = pid; break }
            let prefix = LocalHookEvents.scopePrefix(provider: "workbuddy", pid: pid, startedAt: process.startedAt)
            let groups = scopes.filter { $0.hasPrefix(prefix) }.sorted()
            if groups.isEmpty { missingObserver = true }
            let first = pendingScope[pid].flatMap { groups.firstIndex(of: $0) } ?? 0
            pendingScope[pid] = nil
            let root = configRoot(pid)
            for scope in Array(groups.dropFirst(first)) + Array(groups.prefix(first)) {
                if ProcessInfo.processInfo.systemUptime >= deadline {
                    partial = true; pendingScope[pid] = scope; pendingPID = pid; break
                }
                let events = LocalHookEvents.read(
                    provider: "workbuddy", pid: pid, startedAt: process.startedAt, root: observerRoot, now: now,
                    scopeNames: [scope]
                ).filter { event in
                    guard event.ownerAppPath == appPath, let hostPID = event.ownerHostPID,
                        let host = processes[hostPID], host.startedAt == event.ownerHostStartedAt,
                        host.command.hasPrefix(appPath + "/Contents/MacOS/")
                            || host.command.hasPrefix(appPath + "/Contents/Frameworks/")
                    else { return false }
                    return sessionURL(event.sessionID) != nil
                }
                if events.isEmpty { missingObserver = true }
                for group in Dictionary(grouping: events, by: \.sessionID).values {
                    if let item = project(
                        group, pid: pid, birth: process.startedAt, configRoot: root,
                        hostVersion: applications[appPath], now: now)
                    {
                        sessions.append(item)
                    }
                }
            }
            if partial { break }
        }
        if partial {
            // Keep newer evidence from an unvisited host across a partial scan,
            // but never refresh its source clock or retain a recycled process.
            let retained = previousObservations.filter { previous in
                guard let pid = previous.processID, processes[pid]?.startedAt == previous.processStartedAt else {
                    return false
                }
                return !sessions.contains {
                    $0.id == previous.id && $0.processID == pid && $0.processStartedAt == previous.processStartedAt
                }
            }
            sessions += retained
        }
        sessions = mergeSessions(sessions).map { item in
            var item = item
            if item.status == .working && now.timeIntervalSince(item.observation.updatedAt) > 20 {
                item.observation.mode = .stale; item.observation.reason = "WorkBuddy progress is stale"
            }
            return item
        }
        previousObservations = sessions
        if partial {
            return .init(
                outcome: .partial, source: source, sessions: sessions,
                reason: "Scan incomplete; WorkBuddy reader budget reached")
        }
        if missingObserver {
            return .init(
                outcome: sessions.isEmpty ? .failed : .partial, source: source, sessions: sessions,
                reason: "No compatible WorkBuddy observer events matched a running engine")
        }
        return .observations(sessions, source: source)
    }

    static func mergeSessions(_ sessions: [AgentSession]) -> [AgentSession] {
        Dictionary(grouping: sessions, by: \.id).sorted(by: { $0.key < $1.key }).compactMap { _, candidates in
            let ordered = candidates.sorted {
                if $0.observation.updatedAt != $1.observation.updatedAt {
                    return $0.observation.updatedAt > $1.observation.updatedAt
                }
                return ($0.processID ?? 0) < ($1.processID ?? 0)
            }
            guard var newest = ordered.first else { return nil }
            if ordered.dropFirst().contains(where: {
                $0.observation.updatedAt == newest.observation.updatedAt
                    && ($0.processID != newest.processID || $0.processStartedAt != newest.processStartedAt
                        || $0.status != newest.status)
            }) {
                newest.status = .idle
                newest.observation.mode = .stale
                newest.observation.reason = "WorkBuddy session ownership is ambiguous"
                newest.returnTarget = .unavailable(reason: "WorkBuddy session ownership is ambiguous")
            }
            return newest
        }
    }

    private static func project(
        _ events: [LocalHookEvents.Event], pid: Int32, birth: String, configRoot: String?, hostVersion: String?,
        now: Date
    ) -> AgentSession? {
        guard let last = events.last, let url = sessionURL(last.sessionID) else { return nil }
        let compatible = hostVersion == appVersion && events.allSatisfy { $0.providerVersion == cliVersion }
        let latest = events.filter { $0.observedAt == last.observedAt }
        let ambiguous = Set(latest.map { $0.eventName + ":" + ($0.stopReason ?? "") }).count > 1
        var status: AgentStatus = .idle
        var mode: ObservationMode = .processOnly
        var reason: String? = "WorkBuddy execution state is not confirmed"
        var activity: String?
        if compatible && !ambiguous {
            switch last.eventName {
            case "PostToolUse":
                // Awaited tool-chain progress, not a guarantee of tool success.
                status = .working
                mode = .rich
                reason = nil
                activity = "Tool finished: \(last.toolName ?? "tool")"
            case "PreToolUse", "PermissionRequest":
                activity = "Tool requested: \(last.toolName ?? "tool")"
                reason = "Return to WorkBuddy to check execution or permission status"
            case "FinalStop":
                switch last.stopReason {
                case "failed": status = .failed; mode = .rich; reason = nil
                case "cancelled", "interrupted": status = .stopped; mode = .rich; reason = nil
                default:
                    // A normally ended run (including non-default agents) is not
                    // an authoritative user-turn success or background-task result.
                    reason = "WorkBuddy run ended; user-task completion is not confirmed"
                }
            default: break
            }
        }
        // Do not use generation_id as a user turn: it changes on model requests.
        if status != .failed && status != .stopped && now.timeIntervalSince(last.date) > 20 {
            mode = .stale; reason = "WorkBuddy progress is stale"
        }
        if ambiguous { mode = .stale; reason = "WorkBuddy event order is ambiguous" }
        if !compatible { mode = .incompatible; reason = "WorkBuddy CLI version is not compatible with this observer" }
        var session = AgentSession(
            id: "workbuddy:\(last.sessionID)", processID: pid, kind: .workbuddy,
            cpu: 0, elapsed: "", cwd: last.cwd, status: status, terminalApp: nil, tty: nil, bypassPermissions: false,
            returnTarget: compatible
                ? .applicationLink(bundleIdentifier: bundleIdentifier, name: "WorkBuddy", url: url)
                : .application(bundleIdentifier: bundleIdentifier, name: "WorkBuddy"),
            observation: .init(
                mode: mode, updatedAt: last.date, source: source, reason: reason, authority: .versionedObserver))
        session.surfaceID = .workBuddyDesktop
        session.processStartedAt = birth
        session.lastProgressAt = last.date
        session.stateChangedAt = last.date
        session.activity = activity
        // --no-session-persistence is a normal desktop mode. Absence of this
        // optional context file is not a failed Hook read; never guess another.
        if let transcript = contextPath(last, configRoot: configRoot) {
            session.transcriptPath = transcript
            let messages = recentMessages(path: transcript, limit: Int.max)
            session.lastPrompt =
                messages.last { $0.isUser && TaskPresentationResolver.substantive($0.text) != nil }?.text
            session.lastMessage = messages.last { !$0.isUser }?.text
        }
        return session
    }

    private static func contextPath(_ event: LocalHookEvents.Event, configRoot: String?) -> String? {
        guard let root = configRoot, root.hasPrefix("/"), let cwd = event.cwd, cwd.hasPrefix("/"),
            let transcript = event.transcriptPath, transcript.hasPrefix("/"),
            let attrs = try? FileManager.default.attributesOfItem(atPath: transcript),
            attrs[.type] as? FileAttributeType == .typeRegular
        else { return nil }
        let actual = URL(fileURLWithPath: transcript).resolvingSymlinksInPath().standardizedFileURL.path
        let compressed = URL(fileURLWithPath: cwd).resolvingSymlinksInPath().path
            .replacingOccurrences(of: #"[/\\:]"#, with: "-", options: .regularExpression)
            .replacingOccurrences(of: #"-+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let directory = URL(fileURLWithPath: root).resolvingSymlinksInPath().appendingPathComponent(
            "projects/" + compressed)
        let identities = [event.sessionID, event.agentID].compactMap { $0 }.filter { sessionURL($0) != nil }
        return identities.contains { directory.appendingPathComponent($0 + ".jsonl").path == actual } ? actual : nil
    }

    static func recentMessages(path: String, limit: Int = 12) -> [ChatMessage] {
        let messages = LocalSessionJSON.tailObjects(path: path, maxBytes: 128 * 1024).compactMap {
            object -> (Bool, String)? in
            guard object["type"] as? String == "message", let role = object["role"] as? String,
                ["user", "assistant"].contains(role), let text = messageText(object["content"])
            else { return nil }
            return (role == "user", String(text.prefix(2000)))
        }
        return messages.suffix(max(1, limit)).enumerated().map {
            ChatMessage(id: $0.offset, isUser: $0.element.0, text: $0.element.1)
        }
    }

    private static func messageText(_ content: Any?) -> String? {
        if let text = content as? String { return LocalSessionJSON.compact(text) }
        guard let blocks = content as? [[String: Any]] else { return nil }
        // A tool_result inside a user message is not a new user goal.
        return LocalSessionJSON.compact(
            blocks.compactMap {
                $0["type"] as? String == "text" ? $0["text"] as? String : nil
            }.joined(separator: "\n"))
    }
}
