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
    static func formatInput(toolName: String?, toolInput: [String: Any]?) -> String? {
        guard let toolInput, !toolInput.isEmpty else { return nil }
        let name = (toolName ?? "").lowercased()

        if name == "bash" || name == "shell", let command = stringValue(toolInput["command"]) {
            return truncate(command, limit: 100)
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
