import Foundation
import CryptoKit

/// Ephemeral files from our explicitly installed observer; never a control channel.
enum LocalHookEvents {
    struct Event: Decodable {
        let schemaVersion: Int
        let provider: String
        let sessionID: String
        let eventName: String
        let observedAt: Double
        let sourceAt: Double?
        let providerVersion: String?
        let generationID: String?
        let loopCount: Int?
        let stopReason: String?
        let runtimeSessionID: String?
        let ownerAppPath: String?
        let ownerHostPID: Int32?
        let ownerHostStartedAt: String?
        let sourceType: String?
        let hasSubmittedPrompt: Bool?
        let isInterrupt: Bool?
        let failureCode: String?
        let notificationType: String?
        let messageID: String?
        let isFinal: Bool?
        let hasModelContent: Bool?
        let agentID: String?
        let ownerPID: Int32?
        let ownerStartedAt: String?
        let providerDataRoot: String?
        let clientType: String?
        let transcriptPath: String?
        let cwd: String?
        let parentSessionID: String?
        let toolName: String?
        let toolID: String?
        let toolStatus: String?
        var date: Date { Date(timeIntervalSince1970: observedAt / 1000) }
        var isMainSession: Bool {
            guard parentSessionID == nil else { return false }
            if provider == "workbuddy" {
                // WorkBuddy's named main agent can carry agent_id. Children
                // reuse payload session_id but retain their actual runtime ID.
                return runtimeSessionID == sessionID && ownerAppPath?.hasSuffix(".app") == true
                    && (ownerHostPID ?? 0) > 1 && ownerHostStartedAt?.isEmpty == false
            }
            return agentID == nil
        }
        var sourceDate: Date? {
            guard let sourceAt, sourceAt.isFinite, sourceAt > 0, sourceAt <= observedAt + 5000 else { return nil }
            return Date(timeIntervalSince1970: sourceAt / 1000)
        }
    }

    static var defaultRoot: String { NSHomeDirectory() + "/Library/Application Support/LoopFwd/hook-events" }

    static func read(
        provider: String, pid: Int32, startedAt: String, root: String? = nil, now: Date = Date(),
        scopeNames: Set<String>? = nil
    )
        -> [Event]
    {
        let directory = URL(fileURLWithPath: root ?? defaultRoot)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: directory.path),
            attributes[.type] as? FileAttributeType == .typeDirectory,
            (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
            (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700,
            let scopes = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil),
            scopes.count <= 256
        else { return [] }
        let prefix = scopePrefix(provider: provider, pid: pid, startedAt: startedAt)
        let files = scopes.filter {
            $0.lastPathComponent.hasPrefix(prefix) && (scopeNames?.contains($0.lastPathComponent) ?? true)
        }.flatMap { scope -> [URL] in
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: scope.path),
                attrs[.type] as? FileAttributeType == .typeDirectory,
                (attrs[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
                (attrs[.posixPermissions] as? NSNumber)?.intValue == 0o700,
                let files = try? FileManager.default.contentsOfDirectory(at: scope, includingPropertiesForKeys: nil),
                files.count <= 256
            else { return [] }
            return Array(
                files.filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
                    .prefix(64))
        }
        let events =
            files
            .compactMap { url -> Event? in
                guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                    attrs[.type] as? FileAttributeType == .typeRegular,
                    (attrs[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
                    (attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600,
                    (attrs[.size] as? NSNumber)?.intValue ?? Int.max <= 32 * 1024,
                    let file = FileHandle(forReadingAtPath: url.path)
                else { return nil }
                defer { try? file.close() }
                guard let data = try? file.read(upToCount: 32 * 1024 + 1), data.count <= 32 * 1024,
                    let event = try? JSONDecoder().decode(Event.self, from: data),
                    event.schemaVersion == 1, event.provider == provider,
                    event.ownerPID == pid, normalized(event.ownerStartedAt ?? "") == normalized(startedAt),
                    event.isMainSession, !event.sessionID.isEmpty,
                    event.sessionID.count <= 128,
                    event.observedAt.isFinite, event.date <= now.addingTimeInterval(5)
                else { return nil }
                return event
            }
        return events.sorted {
            if $0.observedAt != $1.observedAt { return $0.observedAt < $1.observedAt }
            // Millisecond ties must never resurrect a tool already ended.
            return rank($0.eventName) < rank($1.eventName)
        }
    }

    static func scopePrefix(provider: String, pid: Int32, startedAt: String) -> String {
        let digest = SHA256.hash(data: Data(normalized(startedAt).utf8)).map { String(format: "%02x", $0) }.joined()
        return "\(provider)-\(pid)-\(digest)-"
    }

    /// Gemini/Qwen delivery can be asynchronous. Arrival order is not task order.
    static func sourced(_ events: [Event], now: Date) -> [Event] {
        events.filter { $0.sourceType == nil && $0.sourceDate.map { $0 <= now.addingTimeInterval(5) } == true }
            .sorted { ($0.sourceDate ?? .distantPast) < ($1.sourceDate ?? .distantPast) }
    }

    struct Progress {
        let status: AgentStatus
        let activity: String?
        let observation: ObservationHealth
    }

    /// These hooks expose progress, not a live approval handle or success result.
    static func progress(_ events: [Event], provider: String, now: Date) -> Progress? {
        let ordered = sourced(events, now: now)
        guard let event = ordered.last, let date = event.sourceDate else { return nil }
        let source = provider == "gemini" ? "Gemini CLI Hook observer schema 1" : "Qwen Code Hook observer schema 1"
        let ambiguous = Set(ordered.filter { $0.sourceDate == date }.map(\.eventName)).count > 1
        var status: AgentStatus = .idle
        var activity: String?
        var reason: String? = "Hook event does not confirm the current task state"
        if !ambiguous {
            switch event.eventName {
            case "AfterModel":
                if provider == "gemini", event.hasModelContent == true {
                    status = .working; activity = "Receiving session model output"; reason = nil
                }
            case "MessageDisplay":
                if provider == "qwen", event.hasModelContent == true, let id = event.messageID, event.isFinal == false,
                    !ordered.contains(where: { $0.messageID == id && $0.isFinal == true })
                {
                    status = .working; activity = "Receiving session model output"; reason = nil
                }
            case "AfterTool", "PostToolUse", "PostToolUseFailure":
                activity =
                    event.isInterrupt == true
                    ? "Tool interrupted: \(event.toolName ?? "tool")" : "Tool finished: \(event.toolName ?? "tool")"
                reason = "Tool result received; the next execution stage is not confirmed"
            case "BeforeTool", "PreToolUse":
                activity = "Tool requested: \(event.toolName ?? "tool")"
                reason = "Tool requested; execution or approval state is not yet confirmed"
            case "Notification":
                if event.notificationType == "ToolPermission" || event.notificationType == "permission_prompt" {
                    reason = "Permission was requested; return to the terminal to check its current state"
                }
            case "SessionEnd":
                status = .stopped; reason = nil
            case "StopFailure":
                // Without a turn ID, require a prior real user submission in the
                // retained source-ordered window; do not revive an old failure.
                if provider == "qwen", let code = event.failureCode,
                    [
                        "loop_detected", "rate_limit", "authentication_failed", "billing_error", "invalid_request",
                        "server_error", "max_output_tokens", "unknown",
                    ].contains(code),
                    ordered.contains(where: {
                        $0.eventName == "UserPromptSubmit" && $0.hasSubmittedPrompt == true
                            && ($0.sourceDate.map { $0 < date } == true)
                    })
                {
                    status = .failed; reason = nil
                }
            default: break
            }
        }
        let expired = now.timeIntervalSince(date) > 180
        if expired { reason = "Hook progress is stale" }
        if ambiguous { reason = "Hook event order is ambiguous" }
        return .init(
            status: status, activity: activity,
            observation: .init(
                mode: reason == nil ? .rich : .stale, updatedAt: date, source: source,
                reason: reason, authority: .versionedObserver))
    }

    private static func normalized(_ value: String) -> String {
        value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
    private static func rank(_ name: String) -> Int { name == "post_agent" ? 2 : name == "post_tool" ? 1 : 0 }
}
