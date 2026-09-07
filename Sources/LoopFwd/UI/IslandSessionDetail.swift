import AppKit
import SwiftUI

// MARK: - Session detail (click a card)

struct SessionDetail: View {
    let agent: AgentSession
    let onBack: () -> Void
    let onViewed: () -> Void

    @AppStorage(Pref.providerControlsEnabled) private var providerControlsEnabled = Pref.Default.providerControlsEnabled
    @AppStorage(Pref.claudeControlsEnabled) private var claudeControlsEnabled = Pref.Default.claudeControlsEnabled

    @State private var messages: [ChatMessage] = []
    @State private var replyText = ""
    @State private var justSent = false
    @State private var replySending = false
    @State private var replyFailed = false
    @State private var showingRemoveConfirmation = false
    @State private var removeInFlight = false
    @State private var removeFailed = false
    @State private var loadingMessages = false
    @State private var reloadPending = false
    @State private var detailVisible = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white.opacity(0.7))
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(.white.opacity(0.1)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.string("Back to active tasks"))

                AgentIconView(kind: agent.kind, status: agent.status, size: 20)

                Text(agent.displayTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                Spacer()

                Chip(
                    text: agent.kind.displayName,
                    textColor: .white.opacity(0.85),
                    background: agent.kind.color.opacity(0.28))
                if agent.codexManagedControl != nil {
                    Chip(
                        text: L10n.string("Managed"), textColor: AgentKind.codex.color,
                        background: AgentKind.codex.color.opacity(0.12))
                }
                if agent.codexManagedControl != nil {
                    Button {
                        removeFailed = false
                        showingRemoveConfirmation = true
                    } label: {
                        Image(systemName: "minus.circle")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white.opacity(agent.status == .working ? 0.2 : 0.55))
                    }
                    .buttonStyle(.plain)
                    .disabled(agent.status.isActive || removeInFlight)
                    .help(
                        L10n.string(
                            agent.status.isActive
                                ? "Stop this task before removing its card"
                                : "Remove this card from LoopFwd")
                    )
                    .accessibilityLabel(L10n.string("Remove managed task from LoopFwd"))
                }
                if ReturnResolver.resolve(agent).reason == nil {
                    Button {
                        TerminalBridge.jump(to: agent) { result in
                            if result.exact {
                                onViewed()
                            } else if !result.opened {
                                OperationalDiagnostics.shared.showNotice(
                                    sessionID: agent.id,
                                    title: agent.displayTitle,
                                    message: result.reason ?? "The task target could not be reached."
                                )
                            }
                        }
                    } label: {
                        HStack(spacing: 3) {
                            Text(ReturnResolver.resolve(agent).capability.actionLabel)
                            Image(systemName: "arrow.up.forward")
                                .font(.system(size: 7, weight: .bold))
                        }
                        .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.7))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(.white.opacity(0.09)))
                    }
                    .buttonStyle(.plain)
                    .help(ReturnResolver.resolve(agent).capability.actionLabel)
                } else if let reason = ReturnResolver.resolve(agent).reason {
                    Text(L10n.string(reason))
                        .font(.system(size: 9.5))
                        .foregroundStyle(.white.opacity(0.35))
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 4)

            if agent.transcriptPath == nil && agent.openCodeDesktopSessionID == nil {
                fallbackInfo
            } else {
                transcript
            }

            if let plan = agent.plan {
                PlanSection(markdown: plan)
            }

            if !agent.todos.isEmpty {
                TasksSection(todos: agent.todos)
            }

            if !agent.subagents.isEmpty {
                SubagentsSection(subagents: agent.subagents)
            }

            if agent.status.isActive, let activity = agent.currentStepSummary {
                HStack(spacing: 5) {
                    ProgressView().controlSize(.mini).tint(.white)
                    Text(activity)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color(red: 0.40, green: 0.58, blue: 1.0))
                    Spacer(minLength: 8)
                    if let control = agent.codexManagedControl {
                        ManagedStopButton(threadID: control.threadID)
                    }
                }
                .padding(.horizontal, 6)
            }

            if canReply {
                replyField
            }

            if removeFailed {
                Text(L10n.string("Couldn’t remove this card. The Codex conversation was not changed."))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color(red: 1.0, green: 0.45, blue: 0.45))
                    .padding(.horizontal, 6)
            }
        }
        .onAppear {
            detailVisible = true
            load()
        }
        .onDisappear {
            detailVisible = false
            reloadPending = false
        }
        .onChange(of: agent) { _, _ in load() }
        .alert(L10n.string("Remove this card from LoopFwd?"), isPresented: $showingRemoveConfirmation) {
            Button(L10n.string("Cancel"), role: .cancel) {}
            Button(L10n.string("Remove"), role: .destructive, action: removeManagedCard)
        } message: {
            Text(L10n.string("The conversation and rollout stay in Codex. LoopFwd will only forget this card."))
        }
    }

    /// Quick-reply straight into the agent's terminal session.
    private var canReply: Bool {
        guard
            agent.effectiveCapabilities(
                providerControlsEnabled: providerControlsEnabled,
                claudeControlsEnabled: claudeControlsEnabled
            ).contains(.reply)
        else { return false }
        if agent.codexManagedControl != nil { return true }
        if agent.openCodeControl?.questionRequestID != nil { return true }
        return agent.kind == .claude
            && claudeControlsEnabled
            && TerminalBridge.canSend(to: agent)
    }

    private var replyField: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                TextField(L10n.format("Reply to %@…", agent.kind.displayName), text: $replyText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(.white)
                    .onSubmit(sendReply)
                Button(action: sendReply) {
                    Image(systemName: justSent ? "checkmark.circle.fill" : "arrow.up.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(
                            justSent
                                ? AgentStatus.working.color
                                : replyText.isEmpty ? .white.opacity(0.3) : .white.opacity(0.9))
                }
                .buttonStyle(.plain)
                .disabled(replyText.isEmpty || replySending)
                .accessibilityLabel(L10n.format("Send answer to %@", agent.kind.displayName))
            }
            if replySending {
                Text(L10n.string("Sending…"))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.4))
            } else if replyFailed {
                Text(L10n.string(replyFailureMessage))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color(red: 1.0, green: 0.45, blue: 0.45))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.white.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.white.opacity(0.08), lineWidth: 1))
    }

    private var replyFailureMessage: String {
        if agent.codexManagedControl != nil {
            return "The Codex connection stopped. Your reply was not sent."
        }
        if TerminalBridge.needsAccessibilityAccess(for: agent) {
            return "Allow LoopFwd in System Settings → Privacy & Security → Accessibility, then try again."
        }
        return "Couldn’t reach this terminal session. Your reply was not sent."
    }

    private func sendReply() {
        let text = replyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !replySending, canReply else { return }
        let target = agent
        replySending = true
        replyFailed = false
        if let control = agent.codexManagedControl {
            CodexAppServer.shared.send(text, to: control.threadID) { result in
                let ok = (try? result.get()) != nil
                replySending = false
                replyFailed = !ok
                if ok {
                    replyText = ""
                    justSent = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { justSent = false }
                } else {
                    recordControlFailure()
                }
            }
            return
        }
        if let control = agent.openCodeControl, control.questionRequestID != nil {
            OpenCodeSessions.answerQuestion(control: control, answers: [text]) { ok in
                replySending = false
                replyFailed = !ok
                if ok {
                    replyText = ""
                    justSent = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { justSent = false }
                } else {
                    recordControlFailure()
                }
            }
            return
        }
        if agent.kind == .claude {
            ApprovalCenter.shared.answerQuestion(text: text, to: target) { ok in
                replySending = false
                replyFailed = !ok
                if ok {
                    replyText = ""
                    justSent = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { justSent = false }
                } else {
                    recordControlFailure()
                }
            }
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = TerminalBridge.send(text: text, to: target)
            DispatchQueue.main.async {
                replySending = false
                replyFailed = !ok
                if ok {
                    replyText = ""
                    justSent = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { justSent = false }
                } else {
                    recordControlFailure()
                }
            }
        }
    }

    private func recordControlFailure() {
        OperationalDiagnostics.shared.recordControlFailure(
            "\(agent.kind.rawValue)/\(agent.surfaceID.rawValue): \(replyFailureMessage)"
        )
    }

    private func removeManagedCard() {
        guard let control = agent.codexManagedControl, !removeInFlight else { return }
        removeInFlight = true
        removeFailed = false
        CodexAppServer.shared.remove(threadID: control.threadID) { result in
            removeInFlight = false
            removeFailed = (try? result.get()) == nil
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(messages) { message in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(message.isUser ? L10n.string("You") : agent.kind.displayName)
                                .font(.system(size: 9, weight: .bold, design: .rounded))
                                .foregroundStyle(message.isUser ? .white.opacity(0.4) : agent.kind.color)
                            Text(message.text)
                                .font(.system(size: 11.5))
                                .foregroundStyle(.white.opacity(message.isUser ? 0.6 : 0.9))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .id(message.id)
                    }
                    if messages.isEmpty {
                        Text(L10n.string("No conversation yet"))
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.4))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                    }
                }
                .padding(10)
            }
            .frame(maxHeight: 380)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.white.opacity(0.04))
            )
            .onChange(of: messages) { _, new in
                if let last = new.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
            .onAppear {
                if let last = messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }

    private var fallbackInfo: some View {
        VStack(alignment: .leading, spacing: 6) {
            InfoRow(label: "Status", value: agent.displayStatusLabel)
            if let attention = agent.attentionKind {
                InfoRow(label: "Attention", value: L10n.string(attention.rawValue.capitalized))
            }
            if let duration = agent.taskElapsedLabel {
                InfoRow(label: "Task time", value: duration)
            }
            InfoRow(label: "Updated", value: agent.freshnessLabel)
            InfoRow(label: "Evidence", value: L10n.string(agent.observation.authority.shortLabel))
            InfoRow(label: "Source", value: agent.observation.source)
            if let reason = agent.observation.reason {
                InfoRow(label: "Observation", value: L10n.string(reason))
            }
            InfoRow(label: "Directory", value: agent.cwd ?? "—")
            InfoRow(label: "Session", value: agent.id)
            if let pid = agent.processID { InfoRow(label: "PID", value: "\(pid)") }
            InfoRow(label: "CPU", value: String(format: "%.1f%%", agent.cpu))
            InfoRow(label: "Uptime", value: agent.elapsed)

            if let prompt = agent.lastPrompt {
                compactMessage(label: L10n.string("You"), text: prompt, color: .white.opacity(0.45))
            }
            if let message = agent.lastMessage {
                compactMessage(label: agent.kind.displayName, text: message, color: agent.kind.color)
            }
            if agent.lastPrompt == nil, agent.lastMessage == nil {
                Text(
                    L10n.string(
                        "Conversation preview is unavailable for this session. Return to its provider to continue.")
                )
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.35))
                .padding(.top, 4)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.white.opacity(0.04)))
    }

    private func compactMessage(label: String, text: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundStyle(color)
            Text(text)
                .font(.system(size: 11.5))
                .foregroundStyle(.white.opacity(0.82))
                .lineLimit(5)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.top, 6)
    }

    private func load() {
        guard detailVisible else { return }
        guard !loadingMessages else {
            reloadPending = true
            return
        }
        let kind = agent.kind
        let path = agent.transcriptPath
        let openCodeSessionID = agent.openCodeDesktopSessionID
        guard path != nil || openCodeSessionID != nil else { return }
        loadingMessages = true
        DispatchQueue.global(qos: .userInitiated).async {
            let loaded: [ChatMessage]
            switch kind {
            case .codex: loaded = path.map { CodexSessions.recentMessages(path: $0) } ?? []
            case .claude: loaded = path.map { ClaudeSessions.recentMessages(path: $0) } ?? []
            case .opencode:
                loaded =
                    openCodeSessionID.map {
                        OpenCodeDesktopSessions.recentMessages(sessionID: $0)
                    } ?? []
            case .gemini:
                loaded = path.map { GeminiSessions.recentMessages(path: $0) } ?? []
            case .cursorAgent:
                loaded = path.map { CursorSessions.recentMessages(path: $0) } ?? []
            case .grok:
                loaded = path.map { GrokSessions.recentMessages(path: $0) } ?? []
            case .copilot:
                loaded = path.map { CopilotSessions.recentMessages(path: $0) } ?? []
            case .kimi:
                loaded = path.map { KimiSessions.recentMessages(path: $0) } ?? []
            case .qwen:
                loaded = path.map { QwenSessions.recentMessages(path: $0) } ?? []
            case .deepseek:
                // The Harness observer deliberately exposes only bounded latest
                // text, never a full transcript path.
                loaded = []
            case .mistral:
                loaded = path.map { MistralSessions.recentMessages(path: $0) } ?? []
            case .workbuddy:
                loaded = path.map { WorkBuddySessions.recentMessages(path: $0) } ?? []
            }
            DispatchQueue.main.async {
                loadingMessages = false
                guard detailVisible else { return }
                if loaded != messages { messages = loaded }
                if reloadPending {
                    reloadPending = false
                    load()
                }
            }
        }
    }
}

struct TasksSection: View {
    let todos: [Todo]
    var compact = false

    private var done: Int { todos.filter { $0.status == "completed" }.count }
    private var inProgress: Int { todos.filter { $0.status == "in_progress" }.count }
    private var open: Int { todos.count - done - inProgress }

    /// Active items first, then a couple of recent completions.
    private var visible: [Todo] {
        let active = todos.filter { $0.status != "completed" }
        let completed = todos.filter { $0.status == "completed" }
        return Array((active + completed).prefix(compact ? 4 : 6))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text(L10n.string("Tasks"))
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white.opacity(0.8))
                Text(L10n.format("%d/%d steps · %d active · %d open", done, todos.count, inProgress, open))
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.4))
            }

            ForEach(Array(visible.enumerated()), id: \.offset) { _, todo in
                HStack(alignment: .top, spacing: 7) {
                    todoIcon(todo.status)
                        .padding(.top, 2)
                    Text(todo.content)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(todo.status == "completed" ? 0.35 : 0.85))
                        .strikethrough(todo.status == "completed", color: .white.opacity(0.35))
                        .lineLimit(1)
                }
            }

            if todos.count > visible.count {
                Text(L10n.format("… +%d more", todos.count - visible.count))
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.35))
            }
        }
        .padding(compact ? 8 : 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: compact ? 10 : 12, style: .continuous)
                .fill(.white.opacity(compact ? 0.05 : 0.04)))
    }

    @ViewBuilder
    private func todoIcon(_ status: String) -> some View {
        switch status {
        case "completed":
            Image(systemName: "checkmark.square.fill")
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.35))
        case "in_progress":
            Circle()
                .fill(Color(red: 0.35, green: 0.55, blue: 1.0))
                .frame(width: 8, height: 8)
        default:
            Image(systemName: "square")
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.5))
        }
    }
}

/// Fan-out Task subagents: running ones with a pulsing dot, recent finishes dimmed.
struct SubagentsSection: View {
    let subagents: [Subagent]
    var compact = false

    private var running: Int { subagents.filter { !$0.done }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white.opacity(0.6))
                Text(L10n.string("Agents"))
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white.opacity(0.8))
                Text(L10n.format("(%d running)", running))
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.4))
            }

            ForEach(Array(subagents.prefix(compact ? 3 : 6).enumerated()), id: \.offset) { _, sub in
                HStack(spacing: 7) {
                    if sub.done {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.white.opacity(0.3))
                    } else {
                        StatusDot(color: AgentStatus.working.color)
                    }
                    Text(sub.description)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(sub.done ? 0.35 : 0.85))
                        .lineLimit(1)
                    if let type = sub.type {
                        Text(type)
                            .font(.system(size: 9, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.4))
                    }
                    Spacer(minLength: 0)
                    if sub.done {
                        Text(L10n.string("Done"))
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(.white.opacity(0.35))
                    }
                }
            }
        }
        .padding(compact ? 8 : 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: compact ? 10 : 12, style: .continuous)
                .fill(.white.opacity(compact ? 0.05 : 0.04)))
    }
}

/// The plan Claude presented via ExitPlanMode, lightly Markdown-rendered.
private struct PlanSection: View {
    let markdown: String
    @State private var collapsed = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { collapsed.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "list.clipboard")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white.opacity(0.6))
                    Text(L10n.string("Plan"))
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white.opacity(0.8))
                    Spacer()
                    Image(systemName: collapsed ? "chevron.down" : "chevron.up")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white.opacity(0.4))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if !collapsed {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(renderedLines.enumerated()), id: \.offset) { _, line in
                            line
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 180)
            } else {
                Text(firstLinePreview)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.45))
                    .lineLimit(1)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.white.opacity(0.04)))
    }

    private var firstLinePreview: String {
        markdown.split(separator: "\n").first(where: { !$0.isEmpty })
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "# ")) } ?? ""
    }

    /// Line-based Markdown: headers bold, bullets indented, inline styles
    /// via AttributedString. Good enough for plan text.
    private var renderedLines: [Text] {
        markdown.split(separator: "\n", omittingEmptySubsequences: false).prefix(80).map { raw in
            let line = String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            func inline(
                _ s: String, size: CGFloat, weight: Font.Weight = .regular,
                opacity: Double = 0.75
            ) -> Text {
                let attributed =
                    (try? AttributedString(
                        markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
                    ?? AttributedString(s)
                return Text(attributed)
                    .font(.system(size: size, weight: weight))
                    .foregroundStyle(.white.opacity(opacity))
            }
            if trimmed.hasPrefix("### ") {
                return inline(String(trimmed.dropFirst(4)), size: 11, weight: .semibold, opacity: 0.9)
            } else if trimmed.hasPrefix("## ") {
                return inline(String(trimmed.dropFirst(3)), size: 11.5, weight: .bold, opacity: 0.92)
            } else if trimmed.hasPrefix("# ") {
                return inline(String(trimmed.dropFirst(2)), size: 12, weight: .bold, opacity: 0.95)
            } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                return Text("  •  ").font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.5))
                    + inline(String(trimmed.dropFirst(2)), size: 10.5)
            } else {
                return inline(line, size: 10.5)
            }
        }
    }
}

private struct InfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .top) {
            Text(L10n.string(label))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.4))
                .frame(width: 70, alignment: .leading)
            Text(value)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.85))
        }
    }
}

// MARK: - Shared bits

struct StatusDot: View {
    let color: Color
    var active: Bool = true

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 6, height: 6)
            .shadow(color: color.opacity(active ? 0.9 : 0.5), radius: active ? 4 : 1)
            .opacity(active ? 1 : 0.45)
    }
}
