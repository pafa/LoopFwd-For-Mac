import Foundation

/// Remembers "Always Allow" by permission **category** so matching prompts
/// auto-approve without another Island / remote interrupt.
///
/// Categories come from the prompt when present (`files`, `app`, …). Claude
/// tool names are folded into the same vocabulary where they clearly map.
enum StickyPermissionAllow {
    /// UserDefaults key: sorted unique lowercase category strings.
    static let storageKey = Pref.stickyAlwaysCategories

    /// In-flight OpenCode request IDs so a sticky reply is not posted twice.
    private static var openCodeInFlight = Set<String>()
    private static let lock = NSLock()

    /// Fold a Claude tool name or OpenCode permission name into a sticky key.
    static func category(from raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 64 else { return nil }
        let key = trimmed.lowercased()

        switch key {
        case "files", "file", "read", "write", "edit", "multiedit", "notebookedit",
            "glob", "grep", "ls", "list", "external_directory":
            return "files"
        case "app", "bash", "shell", "exec", "computer":
            return "app"
        default:
            // Keep provider-native categories (webfetch, doom_loop, …) as-is.
            return key
        }
    }

    static func isRemembered(_ raw: String?, defaults: UserDefaults = .standard) -> Bool {
        guard let category = category(from: raw) else { return false }
        return remembered(defaults: defaults).contains(category)
    }

    static func remember(_ raw: String?, defaults: UserDefaults = .standard) {
        guard let category = category(from: raw) else { return }
        var set = remembered(defaults: defaults)
        guard set.insert(category).inserted else { return }
        defaults.set(Array(set).sorted(), forKey: storageKey)
    }

    static func clear(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: storageKey)
    }

    static func remembered(defaults: UserDefaults = .standard) -> Set<String> {
        let values = defaults.stringArray(forKey: storageKey) ?? []
        return Set(values.filter { !$0.isEmpty && $0.utf8.count <= 64 })
    }

    static var summary: String {
        let list = remembered().sorted()
        if list.isEmpty { return "None" }
        return list.joined(separator: ", ")
    }

    /// Auto-approve OpenCode permissions whose category was Always-remembered,
    /// and strip them from the published session so Island / phone never see them.
    @MainActor
    static func consumeStickyOpenCode(in sessions: [AgentSession]) -> [AgentSession] {
        guard UserDefaults.standard.bool(forKey: Pref.providerControlsEnabled) else { return sessions }
        return sessions.map { session in
            guard var control = session.openCodeControl,
                let permission = control.permission,
                isRemembered(permission.name)
            else { return session }

            let requestID = permission.requestID
            lock.lock()
            let shouldReply = openCodeInFlight.insert(requestID).inserted
            lock.unlock()
            if shouldReply {
                OpenCodeSessions.replyPermission(control: control, reply: .once) { _ in
                    lock.lock()
                    openCodeInFlight.remove(requestID)
                    lock.unlock()
                }
            }

            control = OpenCodeControl(
                processID: control.processID,
                port: control.port,
                directory: control.directory,
                sessionID: control.sessionID,
                questionRequestID: control.questionRequestID,
                permission: nil
            )
            var updated = session
            updated.openCodeControl = control
            if control.questionRequestID == nil, updated.pendingQuestion == nil,
                updated.status == .needsAttention
            {
                updated.status = .working
                updated.attentionKind = nil
                if updated.lastMessage?.hasPrefix("Permission needed:") == true {
                    updated.lastMessage = nil
                }
            }
            return updated
        }
    }
}
