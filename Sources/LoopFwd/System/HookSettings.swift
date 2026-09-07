import Foundation

/// Reading and rewriting Claude Code's `~/.claude/settings.json` to register
/// (or remove) the LoopFwd notification hook.
///
/// Split out of ApprovalCenter and kept free of any app dependencies so the
/// merge logic can be exercised directly by scripts/tests. That matters here
/// more than most places: this code rewrites a file the user did not create and
/// does not expect us to own. Their permission rules, env, and model settings
/// all live in it.
enum HookSettings {

    enum MutationError: LocalizedError {
        case unsupportedLayout

        var errorDescription: String? {
            "Unsupported Claude hook layout. Settings were left unchanged."
        }
    }

    /// Exact legacy and shell-quoted forms only. A brand substring never
    /// grants ownership over a user's command or an entire matcher group.
    static func command(for hookPath: String) -> String {
        "'" + hookPath.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func owns(_ hook: [String: Any], path: String) -> Bool {
        guard hook["type"] as? String == "command", let value = hook["command"] as? String else { return false }
        return value == path || value == command(for: path)
    }

    /// Hook events we register. PermissionRequest is the rich one (carries
    /// tool_name); Notification is the fallback on older Claude versions; the
    /// AskUserQuestion pair tracks a prompt opening and being answered.
    static let events: [(name: String, matcher: String?)] = [
        ("PermissionRequest", nil),
        ("Notification", nil),
        ("PreToolUse", "AskUserQuestion"),
        ("PostToolUse", "AskUserQuestion"),
    ]

    /// What we found on disk.
    ///
    /// `unreadable` exists specifically so a settings file we cannot parse is
    /// never treated as an empty one. Merging into an empty dictionary and
    /// writing it back silently destroys everything the user had configured —
    /// which is exactly what this code used to do.
    enum Load: Equatable {
        case missing  // no file yet — safe to create
        case parsed([String: Any])  // valid JSON object
        case unreadable  // present but not a JSON object — do not touch

        static func == (a: Load, b: Load) -> Bool {
            switch (a, b) {
            case (.missing, .missing), (.unreadable, .unreadable): return true
            case let (.parsed(x), .parsed(y)):
                return NSDictionary(dictionary: x).isEqual(to: y)
            default: return false
            }
        }
    }

    static func load(data: Data?) -> Load {
        guard let data else { return .missing }
        // An empty file is a normal "nothing configured yet" state, not damage.
        if data.isEmpty { return .missing }
        guard let object = try? JSONSerialization.jsonObject(with: data),
            let root = object as? [String: Any]
        else { return .unreadable }
        return .parsed(root)
    }

    /// Add our hook to `root`, leaving every other key untouched. Idempotent:
    /// re-running never appends a second copy.
    static func merged(into root: [String: Any], hookPath: String) throws -> [String: Any] {
        try validate(root)
        var root = root
        var hooks = root["hooks"] as? [String: Any] ?? [:]

        for event in events {
            var entries = hooks[event.name] as? [[String: Any]] ?? []
            let alreadyThere = entries.contains { containsOurHook($0, path: hookPath) }
            entries = try entries.map { entry in
                var entry = entry
                guard let commands = entry["hooks"] as? [[String: Any]] else {
                    throw MutationError.unsupportedLayout
                }
                entry["hooks"] = commands.map { hook in
                    var hook = hook
                    if owns(hook, path: hookPath) { hook["command"] = command(for: hookPath) }
                    return hook
                }
                return entry
            }
            if !alreadyThere {
                var entry: [String: Any] = [
                    "hooks": [["type": "command", "command": command(for: hookPath), "async": true]]
                ]
                if let matcher = event.matcher { entry["matcher"] = matcher }
                entries.append(entry)
            }
            hooks[event.name] = entries
        }

        root["hooks"] = hooks
        return root
    }

    /// Strip our hook, preserving any other hooks the user registered on the
    /// same events.
    static func removed(from root: [String: Any], hookPath: String) throws -> [String: Any] {
        try validate(root)
        var root = root
        guard var hooks = root["hooks"] as? [String: Any] else { return root }

        for event in events {
            guard var entries = hooks[event.name] as? [[String: Any]] else { continue }
            entries = try entries.compactMap { entry in
                guard containsOurHook(entry, path: hookPath) else { return entry }
                var entry = entry
                guard let commands = entry["hooks"] as? [[String: Any]] else {
                    throw MutationError.unsupportedLayout
                }
                let remaining = commands.filter { !owns($0, path: hookPath) }
                guard !remaining.isEmpty else { return nil }
                entry["hooks"] = remaining
                return entry
            }
            if entries.isEmpty {
                hooks.removeValue(forKey: event.name)
            } else {
                hooks[event.name] = entries
            }
        }

        if hooks.isEmpty { root.removeValue(forKey: "hooks") } else { root["hooks"] = hooks }
        return root
    }

    private static func containsOurHook(_ entry: [String: Any], path: String) -> Bool {
        ((entry["hooks"] as? [[String: Any]]) ?? [])
            .contains { owns($0, path: path) }
    }

    static func isInstalled(in root: [String: Any], hookPath: String) -> Bool {
        guard (try? validate(root)) != nil, let hooks = root["hooks"] as? [String: Any] else { return false }
        return events.contains { event in
            (hooks[event.name] as? [[String: Any]] ?? []).contains { containsOurHook($0, path: hookPath) }
        }
    }

    private static func validate(_ root: [String: Any]) throws {
        guard let value = root["hooks"] else { return }
        guard let hooks = value as? [String: Any] else { throw MutationError.unsupportedLayout }
        for event in events {
            guard let value = hooks[event.name] else { continue }
            guard let entries = value as? [[String: Any]] else { throw MutationError.unsupportedLayout }
            for entry in entries {
                guard let commands = entry["hooks"] as? [[String: Any]],
                    commands.allSatisfy({ $0["type"] is String })
                else { throw MutationError.unsupportedLayout }
                for hook in commands where hook["type"] as? String == "command" {
                    guard let command = hook["command"] as? String, !command.isEmpty else {
                        throw MutationError.unsupportedLayout
                    }
                }
            }
        }
    }

    /// Serialized the same way every time so re-running produces no diff noise
    /// in a file the user may have under version control.
    static func serialize(_ root: [String: Any]) -> Data? {
        try? JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }
}
