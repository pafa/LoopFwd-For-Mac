import Foundation

/// Read-only projection of Mistral Vibe's local session snapshots.
///
/// Vibe 2.x stores `meta.json` and `messages.jsonl` in each directory below
/// `$VIBE_HOME/logs/session`. LoopFwd reads bounded files only; it never starts
/// Vibe, resumes a session or changes provider configuration.
enum MistralSessions {
    struct Info {
        let sessionID: String
        let observation: ObservationHealth
        let transcriptPath: String
        let title: String?
        let cwd: String?
        let status: AgentStatus
        let lastPrompt: String?
        let lastMessage: String?
        let activity: String?
        let model: String?
        let updatedAt: Date
    }

    private struct Candidate {
        let id: String
        let directory: String
        let messagesPath: String
        let cwd: String?
        let title: String?
        let model: String?
        let updatedAt: Date
        let metaModified: Date
        let messagesModified: Date
    }

    private struct InfoCache {
        let metaModified: Date
        let messagesModified: Date
        let info: Info
    }

    private static let lock = NSLock()
    private static var infoCache: [String: InfoCache] = [:]
    private static let recentWindow: TimeInterval = 30 * 60

    static func info(
        cwd: String?, args: String, cpu: Double, vibeHome: String?,
        processID: Int32? = nil, processStartedAt: String? = nil, observerRoot: String? = nil, now: Date = Date()
    ) -> Info? {
        guard let processID, let processStartedAt else { return nil }
        let events = LocalHookEvents.read(
            provider: "mistral", pid: processID, startedAt: processStartedAt, root: observerRoot, now: now)
        guard let binding = events.last, let transcript = binding.transcriptPath,
            transcript.hasPrefix("/"), (transcript as NSString).lastPathComponent == "messages.jsonl"
        else { return nil }
        guard let bindingCwd = binding.cwd, bindingCwd.hasPrefix("/") else { return nil }
        let processCwd = cwd.map(LocalSessionJSON.standardPath)
        // Vibe already chdir'd for --workdir. Reapplying relative argv here
        // would resolve it twice; use the observed cwd or the bound Hook cwd.
        let effectiveCwd = processCwd ?? LocalSessionJSON.standardPath(bindingCwd)
        // setproctitle removes VIBE_HOME from macOS's process snapshot. The
        // explicitly installed Hook child still inherits the actual value.
        let processHome = LocalSessionJSON.compact(vibeHome).map { resolve($0, relativeTo: effectiveCwd) }
        let eventHome = binding.providerDataRoot
        if let eventHome {
            guard eventHome.hasPrefix("/"), eventHome.utf8.count <= 4096, !eventHome.contains("\0"),
                processHome.map({ canonical($0) == canonical(eventHome) }) ?? true
            else { return nil }
        }
        let home = processHome ?? eventHome ?? NSHomeDirectory() + "/.vibe"
        guard
            canonical(transcript).hasPrefix(
                canonical(sessionSaveDirectory(vibeHome: home, workingDirectory: effectiveCwd)) + "/"),
            let selected = candidate(messagesPath: transcript),
            let candidateCwd = selected.cwd,
            selected.id == binding.sessionID, canonical(candidateCwd) == canonical(bindingCwd),
            canonical(effectiveCwd) == canonical(candidateCwd)
        else { return nil }
        return adjusted(parse(selected), events: events.filter { $0.sessionID == binding.sessionID }, now: now)
    }

    static func recentMessages(path: String, limit: Int = 12) -> [ChatMessage] {
        var messages: [(Bool, String)] = []
        for object in LocalSessionJSON.tailObjects(path: path) {
            guard let role = object["role"] as? String else { continue }
            if role == "user" {
                append(messageText(object), isUser: true, to: &messages)
            } else if role == "assistant" {
                append(messageText(object), isUser: false, to: &messages)
            }
        }
        return messages.suffix(max(1, limit)).enumerated().map {
            ChatMessage(id: $0.offset, isUser: $0.element.0, text: $0.element.1)
        }
    }

    private static func candidate(messagesPath: String) -> Candidate? {
        let directory = (messagesPath as NSString).deletingLastPathComponent
        let metadataPath = directory + "/meta.json"
        guard let size = (try? FileManager.default.attributesOfItem(atPath: metadataPath)[.size]) as? NSNumber,
            size.intValue <= 1024 * 1024,
            let metadata = LocalSessionJSON.object(path: metadataPath),
            let id = LocalSessionJSON.compact(metadata["session_id"] as? String),
            let metaModified = LocalSessionJSON.fileDate(metadataPath),
            let messagesModified = LocalSessionJSON.fileDate(messagesPath)
        else {
            return nil
        }
        let environment = metadata["environment"] as? LocalSessionJSON.Object
        let config = metadata["config"] as? LocalSessionJSON.Object
        let updatedAt = max(
            LocalSessionJSON.date(metadata["end_time"]) ?? .distantPast,
            max(metaModified, messagesModified)
        )
        return Candidate(
            id: id,
            directory: directory,
            messagesPath: messagesPath,
            cwd: LocalSessionJSON.compact(environment?["working_directory"] as? String),
            title: LocalSessionJSON.compact(metadata["title"] as? String),
            model: LocalSessionJSON.compact(config?["active_model"] as? String),
            updatedAt: updatedAt,
            metaModified: metaModified,
            messagesModified: messagesModified
        )
    }

    private static func parse(_ candidate: Candidate) -> Info {
        lock.lock()
        if let cached = infoCache[candidate.directory],
            cached.metaModified == candidate.metaModified,
            cached.messagesModified == candidate.messagesModified
        {
            lock.unlock()
            return cached.info
        }
        lock.unlock()

        var lastPrompt: String?
        var lastMessage: String?

        for object in LocalSessionJSON.tailObjects(path: candidate.messagesPath) {
            guard let role = object["role"] as? String else { continue }
            switch role {
            case "user":
                if let text = messageText(object), TaskPresentationResolver.substantive(text) != nil {
                    lastPrompt = text
                }
            case "assistant":
                lastMessage = messageText(object) ?? lastMessage
            default:
                continue
            }
        }

        let info = Info(
            sessionID: candidate.id,
            observation: .processOnly("Mistral transcript", reason: "Transcript is context, not live task evidence"),
            transcriptPath: candidate.messagesPath,
            title: candidate.title,
            cwd: candidate.cwd,
            status: .idle,
            lastPrompt: lastPrompt,
            lastMessage: lastMessage,
            activity: nil,
            model: candidate.model,
            updatedAt: candidate.updatedAt
        )

        lock.lock()
        if infoCache.count >= 128 { infoCache.removeAll(keepingCapacity: true) }
        infoCache[candidate.directory] = InfoCache(
            metaModified: candidate.metaModified,
            messagesModified: candidate.messagesModified,
            info: info
        )
        lock.unlock()
        return info
    }

    private static func adjusted(_ info: Info, events: [LocalHookEvents.Event], now: Date) -> Info {
        guard let latest = events.last else { return info }
        // pre_tool precedes approval; skips/denials need not emit post_tool.
        // It proves a request, never execution or a user approval requirement.
        let unknownPhase = latest.eventName != "post_tool"
        let status: AgentStatus = unknownPhase ? .idle : .working
        let expired = now.timeIntervalSince(latest.date) > recentWindow
        return Info(
            sessionID: info.sessionID,
            observation: .init(
                mode: expired || unknownPhase ? .stale : .rich, updatedAt: latest.date,
                source: "Mistral tool Hook observer schema 1",
                reason: expired
                    ? "Mistral hook progress is stale"
                    : latest.eventName == "pre_tool"
                        ? "Tool requested; execution or approval state is not yet confirmed"
                        : latest.eventName == "post_agent"
                            ? "Post-agent hook does not confirm the final task outcome" : nil,
                authority: .versionedObserver),
            transcriptPath: info.transcriptPath,
            title: info.title,
            cwd: info.cwd,
            status: status,
            lastPrompt: info.lastPrompt,
            lastMessage: info.lastMessage,
            activity: latest.eventName == "pre_tool"
                ? "Tool requested: \(latest.toolName ?? "tool")"
                : latest.eventName == "post_tool" ? "Tool finished: \(latest.toolName ?? "tool")" : nil,
            model: info.model,
            updatedAt: latest.date
        )
    }

    private static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    private static func messageText(_ object: LocalSessionJSON.Object) -> String? {
        LocalSessionJSON.text(object["input_text"])
            ?? LocalSessionJSON.text(object["content"])
    }

    private static func sessionSaveDirectory(vibeHome: String, workingDirectory: String) -> String {
        let configPath = vibeHome + "/config.toml"
        guard let text = try? String(contentsOfFile: configPath, encoding: .utf8) else {
            return vibeHome + "/logs/session"
        }
        var inSessionLogging = false
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                inSessionLogging = line == "[session_logging]"
                continue
            }
            guard inSessionLogging,
                line.hasPrefix("save_dir"),
                let equals = line.firstIndex(of: "=")
            else { continue }
            var value = line[line.index(after: equals)...]
                .trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2 {
                value.removeFirst()
                value.removeLast()
            }
            if let configured = LocalSessionJSON.compact(value) {
                return resolve(configured, relativeTo: workingDirectory)
            }
        }
        return vibeHome + "/logs/session"
    }

    private static func resolve(_ path: String, relativeTo directory: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        if (expanded as NSString).isAbsolutePath {
            return LocalSessionJSON.standardPath(expanded)
        }
        return LocalSessionJSON.standardPath(directory + "/" + expanded)
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
