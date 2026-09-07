import Foundation

enum IslandEmptyState {
    case unavailable, setupRequired, noActiveTasks

    static func resolve(hasDataFailure: Bool, hasAvailableProvider: Bool) -> Self {
        if hasDataFailure { return .unavailable }
        return hasAvailableProvider ? .noActiveTasks : .setupRequired
    }

    var title: String {
        switch self {
        case .unavailable: return "Data temporarily unavailable"
        case .setupRequired: return "Set up an agent"
        case .noActiveTasks: return "No active tasks"
        }
    }

    var detail: String {
        switch self {
        case .unavailable: return "Check Diagnostics for the provider read failure"
        case .setupRequired: return "Choose an installed CLI or review agent setup to begin"
        case .noActiveTasks: return "Idle agents stay out of the island until work starts"
        }
    }

    var action: String { self == .unavailable ? "Diagnostics" : "Setup status" }
}

struct TaskPresentation: Equatable {
    let project: String
    let task: String?
    let step: String?
}

/// Deterministic, local-only task presentation. Short acknowledgements and
/// continuation commands must not replace the real task the user is tracking.
enum TaskPresentationResolver {
    private static let genericFollowUps: Set<String> = Set(
        [
            "继续", "继续做", "继续执行", "好的", "好", "可以", "开始吧", "执行吧", "按计划做", "按计划执行",
            "继续吧", "好的，继续", "那加快进度继续吧", "加快进度继续吧",
            "好的，按照你的建议修改", "按照你的建议修改", "按你的建议修改",
            "允许", "同意", "确认", "批准",
            "continue", "continue please", "go ahead", "proceed", "do it", "ok", "okay", "yes",
            "allow", "allowed", "approve", "approved", "confirmed",
        ].map(normalizedFollowUp))

    static func resolve(
        project: String,
        previousTask: String?,
        lastPrompt: String?,
        todos: [Todo],
        activity: String?,
        isActive: Bool
    ) -> TaskPresentation {
        let activeTodo = todos.first(where: { $0.status == "in_progress" })
            .flatMap { concise($0.content) }
        let explicitGoal = todos.first(where: {
            let text = $0.content.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return $0.status != "completed" && (text == "/goal" || text.hasPrefix("/goal "))
        }).flatMap { concise($0.content) }
        let prompt = lastPrompt.flatMap(substantive)
        let task = explicitGoal ?? prompt ?? previousTask ?? activeTodo
        return TaskPresentation(
            project: project,
            task: task,
            step: currentStep(todos: todos, activity: activity, isActive: isActive)
        )
    }

    /// Reading a step must not parse the user goal again. The island asks for
    /// this value multiple times during layout, even when a long goal is stable.
    static func currentStep(todos: [Todo], activity: String?, isActive: Bool) -> String? {
        guard isActive else { return nil }
        if let todo = todos.first(where: { $0.status == "in_progress" }), let step = concise(todo.content) {
            return step
        }
        let genericActivity: Set<String> = [
            "thinking", "thinking…", "thinking...", "working", "running", "processing task", "正在处理任务",
        ]
        let specificActivity = activity.flatMap(concise).flatMap {
            genericActivity.contains($0.lowercased()) ? nil : $0
        }
        return specificActivity.map(displayActivity)
    }

    private static func displayActivity(_ text: String) -> String {
        let fixed: Set<String> = [
            "Running a command", "Running a tool script", "Editing files", "Updating the plan",
            "Searching the web", "Viewing an image",
        ]
        if fixed.contains(text) { return L10n.string(text) }
        for prefix in ["Running ", "Editing ", "Using ", "Preparing "] where text.hasPrefix(prefix) {
            return L10n.format(prefix + "%@", String(text.dropFirst(prefix.count)))
        }
        return text
    }

    static func substantive(_ raw: String) -> String? {
        let body = messageBody(raw)
        guard !isGenericFollowUp(body) else { return nil }
        return conciseBody(body)
    }

    private static func isGenericFollowUp(_ text: String) -> Bool {
        // Match the whole bounded phrase, never a prefix of a concrete goal.
        text.utf8.prefix(257).count <= 256 && genericFollowUps.contains(normalizedFollowUp(text))
    }

    private static func normalizedFollowUp(_ text: String) -> String {
        let separators = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
        return String(String.UnicodeScalarView(text.lowercased().unicodeScalars.filter { !separators.contains($0) }))
    }

    static func concise(_ raw: String) -> String? {
        conciseBody(messageBody(raw))
    }

    private static func conciseBody(_ body: String) -> String? {
        // Stop at the first meaningful line instead of allocating every line
        // of a potentially large implementation plan on each layout pass.
        var remaining = body[...]
        var usefulLine: String?
        while !remaining.isEmpty {
            let end = remaining.firstIndex(where: \.isNewline) ?? remaining.endIndex
            let line = remaining[..<end].trimmingCharacters(in: .whitespacesAndNewlines)
            let hasNext = end != remaining.endIndex
            let confirmation = isGenericFollowUp(line)
            if !line.isEmpty, !line.hasPrefix("# Files"), !line.hasPrefix("<"), !(hasNext && confirmation) {
                usefulLine = line
                break
            }
            guard hasNext else { break }
            remaining = remaining[remaining.index(after: end)...]
        }
        guard var text = usefulLine else { return nil }
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        for prefix in ["/goal", "/Goal", "/GOAL"] where text.hasPrefix(prefix) {
            text.removeFirst(prefix.count)
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        while text.contains("  ") {
            text = text.replacingOccurrences(of: "  ", with: " ")
        }
        guard !text.isEmpty else { return nil }
        let limit = 96
        return text.count > limit ? String(text.prefix(limit - 1)) + "…" : text
    }

    private static func messageBody(_ raw: String) -> String {
        // Unwrap known leading sections only. A quoted plan/request marker
        // later in the user's task is content, not a replacement instruction.
        var body = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.hasPrefix("## My request:") || body.hasPrefix("# Files mentioned by the user:") {
            var remaining = body[...]
            while !remaining.isEmpty {
                let end = remaining.firstIndex(where: \.isNewline) ?? remaining.endIndex
                let line = remaining[..<end].trimmingCharacters(in: .whitespaces)
                remaining = end == remaining.endIndex ? "" : remaining[remaining.index(after: end)...]
                if line == "## My request:" {
                    body = remaining.trimmingCharacters(in: .whitespacesAndNewlines)
                    break
                }
            }
        }
        if let range = body.range(of: "PLEASE IMPLEMENT THIS PLAN:", options: [.anchored, .caseInsensitive]) {
            body = String(body[range.upperBound...])
        }
        return body
    }
}
