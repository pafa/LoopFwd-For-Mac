import Foundation

/// Formats Claude Code permission prompts for Island / phone glance.
/// Inspired by vibe-notch `PermissionContext.formattedInput` — category + short
/// tool detail — without adopting jump-to-terminal or socket control-plane UX.
enum ClaudePermissionGlance {
    /// Human label for a sticky / projected permission category.
    static func categoryLabel(_ category: String?) -> String? {
        guard let category, !category.isEmpty else { return nil }
        switch category {
        case "files": return "Files"
        case "app": return "App / Shell"
        default:
            if category.count <= 24 { return category }
            return String(category.prefix(21)) + "…"
        }
    }

    /// Short glance string from Claude `tool_input` (command, path, url, …).
    /// Edit tools prefer a compact `path · +N −M` line (MioIsland-style
    /// permission glance without shipping a full notch diff dashboard).
    static func formatInput(toolName: String?, toolInput: [String: Any]?) -> String? {
        guard let toolInput, !toolInput.isEmpty else { return nil }
        let name = (toolName ?? "").lowercased()

        if name == "bash" || name == "shell", let command = stringValue(toolInput["command"]) {
            return truncate(command, limit: 100)
        }
        if let editGlance = formatEditGlance(toolName: name, toolInput: toolInput) {
            return editGlance
        }
        if ["read", "write", "edit", "multiedit", "notebookedit"].contains(name) {
            if let path = stringValue(toolInput["file_path"]) ?? stringValue(toolInput["path"]) {
                return (path as NSString).lastPathComponent
            }
        }

        let priorityKeys = ["command", "file_path", "path", "query", "pattern", "url"]
        for key in priorityKeys {
            if let value = stringValue(toolInput[key]) {
                return truncate(value, limit: 100)
            }
        }
        for (key, raw) in toolInput where key != "description" {
            if let value = stringValue(raw) {
                return truncate(value, limit: 100)
            }
        }
        return nil
    }

    /// Compact edit summary when old/new strings are present in `tool_input`.
    static func formatEditGlance(toolName: String, toolInput: [String: Any]) -> String? {
        let editLike = ["edit", "multiedit", "notebookedit", "write"].contains(toolName)
            || toolInput["old_string"] != nil || toolInput["new_string"] != nil
        guard editLike else { return nil }

        let path = stringValue(toolInput["file_path"]) ?? stringValue(toolInput["path"])
        let basename = path.map { ($0 as NSString).lastPathComponent }

        let oldString = stringValue(toolInput["old_string"])
        let newString = stringValue(toolInput["new_string"])
            ?? stringValue(toolInput["content"])
            ?? stringValue(toolInput["new_source"])

        guard oldString != nil || newString != nil else { return basename }

        let oldLines = lineCount(oldString)
        let newLines = lineCount(newString)
        let added = max(0, newLines - (oldString == nil ? 0 : min(oldLines, newLines)))
        let removed = max(0, oldLines - (newString == nil ? 0 : min(oldLines, newLines)))
        // Prefer true replace counts when both sides exist.
        let plus: Int
        let minus: Int
        if let oldString, let newString {
            let delta = diffLineDelta(old: oldString, new: newString)
            plus = delta.added
            minus = delta.removed
        } else {
            plus = added
            minus = removed
        }

        var parts: [String] = []
        if let basename { parts.append(basename) }
        if plus > 0 || minus > 0 {
            if minus == 0 {
                parts.append("+\(max(plus, 1))")
            } else if plus == 0 {
                parts.append("−\(minus)")
            } else {
                parts.append("+\(plus) −\(minus)")
            }
        } else if newString != nil, oldString == nil {
            parts.append("+\(max(1, newLines))")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private static func lineCount(_ value: String?) -> Int {
        guard let value, !value.isEmpty else { return 0 }
        return value.split(separator: "\n", omittingEmptySubsequences: false).count
    }

    /// Cheap line-set delta for glance only (not a semantic diff).
    private static func diffLineDelta(old: String, new: String) -> (added: Int, removed: Int) {
        let oldLines = old.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let newLines = new.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var oldBag: [String: Int] = [:]
        for line in oldLines { oldBag[line, default: 0] += 1 }
        var newBag: [String: Int] = [:]
        for line in newLines { newBag[line, default: 0] += 1 }
        var removed = 0
        var added = 0
        for (line, count) in oldBag {
            removed += max(0, count - (newBag[line] ?? 0))
        }
        for (line, count) in newBag {
            added += max(0, count - (oldBag[line] ?? 0))
        }
        return (added, removed)
    }

    /// Island / remote title: tool name, optionally qualified by category.
    static func approvalTitle(toolName: String?, category: String?) -> String {
        let tool = toolName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = categoryLabel(category)
        if let tool, !tool.isEmpty, let label, label.lowercased() != tool.lowercased() {
            return "Allow \(tool) · \(label)"
        }
        if let tool, !tool.isEmpty {
            return "Allow \(tool)"
        }
        if let label {
            return "Allow \(label)"
        }
        return "Allow tool"
    }

    private static func stringValue(_ raw: Any?) -> String? {
        guard let raw else { return nil }
        if let string = raw as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let number = raw as? NSNumber {
            return number.stringValue
        }
        return nil
    }

    private static func truncate(_ value: String, limit: Int) -> String {
        guard value.count > limit else { return value }
        return String(value.prefix(limit - 1)) + "…"
    }
}
