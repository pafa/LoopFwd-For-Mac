import AppKit
import SwiftUI

// MARK: - Session card

struct SessionCard: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var accessibilityContrast
    @ScaledMetric(relativeTo: .caption) private var scaledReferenceFontSize: CGFloat = 11
    let agent: AgentSession
    var selected = false
    let onShowDetail: () -> Void
    let onActivate: () -> Void

    @AppStorage(Pref.showLastPrompt) private var showLastPrompt = Pref.Default.showLastPrompt
    @AppStorage(Pref.showActivity) private var showActivity = Pref.Default.showActivity
    @AppStorage(Pref.showTerminalChip) private var showTerminalChip = Pref.Default.showTerminalChip
    @AppStorage(Pref.showTasks) private var showTasks = Pref.Default.showTasks
    @AppStorage(Pref.showModel) private var showModel = Pref.Default.showModel
    @AppStorage(Pref.showGitBranch) private var showGitBranch = Pref.Default.showGitBranch
    @AppStorage(Pref.showSubagents) private var showSubagents = Pref.Default.showSubagents
    @AppStorage(Pref.contentFontSize) private var fontSize = Pref.Default.contentFontSize
    @AppStorage(Pref.claudeControlsEnabled) private var claudeControlsEnabled = Pref.Default.claudeControlsEnabled
    @AppStorage(Pref.providerControlsEnabled) private var providerControlsEnabled = Pref.Default.providerControlsEnabled
    @ObservedObject private var approvals = ApprovalCenter.shared
    @State private var hovered = false
    @State private var replyText = ""
    @State private var justSent = false
    @State private var controlInFlight = false
    @State private var controlFailed = false
    @State private var selectedQuestionOptions = Set<Int>()

    private var fs: CGFloat {
        AccessibilityTypography.cardFontSize(
            base: CGFloat(fontSize),
            scaledReference: scaledReferenceFontSize
        )
    }
    private let cardRadius: CGFloat = 14
    private var approval: ApprovalCenter.Approval? {
        approvals.approval(for: agent)
    }
    private var openCodePermission: OpenCodePermission? { agent.openCodeControl?.permission }
    private var hasApproval: Bool {
        agent.status == .needsAttention && (approval != nil || openCodePermission != nil)
    }
    private var approvalColor: Color { AgentStatus.needsAttention.color }
    private var controlCapabilities: AgentCapabilities {
        agent.effectiveCapabilities(
            providerControlsEnabled: providerControlsEnabled, claudeControlsEnabled: claudeControlsEnabled)
    }
    /// The provider exposed a real user-input request and has an exact reply path.
    private var canReply: Bool {
        agent.status == .needsAttention
            && controlCapabilities.contains(.reply)
            && (agent.codexManagedControl != nil || TerminalBridge.canSend(to: agent))
            && !hasApproval
    }

    /// Live question from the PreToolUse hook — the only real-time source
    /// (the transcript records AskUserQuestion only after it's answered).
    private var liveQuestion: PendingQuestion? {
        approvals.question(for: agent)?.question
    }
    private var structuredQuestion: PendingQuestion? {
        agent.status == .needsAttention ? agent.pendingQuestion : nil
    }
    private var canAnswerStructuredQuestion: Bool {
        if agent.openCodeControl?.questionRequestID != nil {
            return controlCapabilities.contains(.reply)
        }
        return claudeControlsEnabled && liveQuestion != nil && TerminalBridge.canSend(to: agent)
    }

    /// State belongs to the shared lifecycle projection, never to a view.
    private var effectiveStatus: AgentStatus { agent.status }

    /// A subtle wash of the status color behind the card (idle stays neutral).
    private var statusWash: Color {
        switch effectiveStatus {
        case .working, .stalled, .completed, .needsAttention, .failed:
            return effectiveStatus.color.opacity(hovered || selected ? 0.14 : 0.10)
        case .stopped, .idle: return .clear
        }
    }

    /// Border color: selected wins, otherwise a status tint.
    private var borderColor: Color {
        if selected { return Color(red: 0.45, green: 0.62, blue: 1.0).opacity(0.8) }
        let contrastBoost = accessibilityContrast == .increased ? 0.25 : 0
        switch effectiveStatus {
        case .working, .stalled, .completed, .needsAttention, .failed:
            return effectiveStatus.color.opacity(0.4 + contrastBoost)
        case .stopped, .idle: return .white.opacity(0.07 + contrastBoost)
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            AgentIconView(kind: agent.kind, status: effectiveStatus, size: 26)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 5) {
                // Line 1: title · detail button · time
                HStack(spacing: 8) {
                    Text(agent.projectDisplayTitle)
                        .font(.system(size: fs + 2, weight: .semibold))
                        .foregroundStyle(.white.opacity(agent.status == .idle ? 0.6 : 1))
                        .lineLimit(1)
                        .help(agent.displayTitle)
                    Spacer(minLength: 8)
                    Group {
                        Button(action: onShowDetail) {
                            Image(systemName: "chevron.right.circle.fill")
                                .font(.system(size: fs + 2))
                                .foregroundStyle(.white.opacity(0.6))
                        }
                        .buttonStyle(.plain)
                        .help(L10n.string("Show conversation"))
                        .accessibilityLabel(L10n.string("Show conversation details"))
                        // Grows out of the trailing edge rather than popping in.
                        .transition(
                            .scale(scale: 0.6, anchor: .trailing)
                                .combined(with: .opacity))
                    }
                    Text(agent.cardTimingLabel)
                        .font(.system(size: fs - 1, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.35))
                        .fixedSize()
                }

                if agent.displayTitle != agent.projectDisplayTitle {
                    Text(agent.displayTitle)
                        .font(.system(size: fs - 1))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                }

                // Line 2 answers "what is this agent doing now?". Structured
                // questions stay visible; ordinary cards prefer the current
                // plan step over a long, stale first prompt.
                if effectiveStatus == .needsAttention, let question = structuredQuestion,
                    !hasApproval
                {
                    Text(question.prompt)
                        .font(.system(size: fs))
                        .foregroundStyle(.white.opacity(0.72))
                        .lineLimit(3)
                } else if showLastPrompt, let task = agent.currentTaskSummary {
                    Text(L10n.format("Task · %@", task))
                        .font(.system(size: fs))
                        .foregroundStyle(.white.opacity(agent.status.isActive ? 0.68 : 0.48))
                        .lineLimit(2)
                }

                // Line 3: live status on the left, chips on the right
                HStack(alignment: .center, spacing: 8) {
                    statusLine
                    Spacer(minLength: 8)
                    if agent.status.isActive, let control = agent.codexManagedControl {
                        ManagedStopButton(threadID: control.threadID)
                    }
                    chips
                }
                .padding(.top, 1)

                // Task checklist from the agent's todo list
                if showTasks, !agent.todos.isEmpty {
                    TasksSection(todos: agent.todos, compact: true)
                        .padding(.top, 3)
                }

                // Fan-out subagents (only interesting while any is running)
                if showSubagents, agent.subagents.contains(where: { !$0.done }) {
                    SubagentsSection(subagents: agent.subagents, compact: true)
                        .padding(.top, 3)
                }

                // Pending permission request → answer from the island.
                if hasApproval {
                    if (approval != nil && (!claudeControlsEnabled || !TerminalBridge.canSend(to: agent)))
                        || (openCodePermission != nil && !controlCapabilities.contains(.approve))
                    {
                        attentionOnlyBar
                            .padding(.top, 3)
                    } else {
                        approvalBar
                            .padding(.top, 3)
                    }
                } else if let question = structuredQuestion, canAnswerStructuredQuestion {
                    // Claude hooks answer through the terminal; OpenCode
                    // requests answer through the validated loopback API.
                    questionBar(question)
                        .padding(.top, 3)
                } else if canReply, hovered || selected {
                    // Free-text question → answer inline without leaving.
                    replyBar
                        .padding(.top, 3)
                        // Unfurls downward instead of snapping the card taller.
                        .transition(
                            .asymmetric(
                                insertion: .opacity.combined(with: .offset(y: -6)),
                                removal: .opacity
                            ))
                }
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: cardRadius, style: .continuous)
                .fill(.white.opacity(selected ? 0.08 : hovered ? 0.06 : 0.03))
                .overlay(  // a wash of the status color so the card reads at a glance
                    RoundedRectangle(cornerRadius: cardRadius, style: .continuous)
                        .fill(statusWash)
                )
                .overlay(  // specular sheen along the top edge, only while hovered
                    RoundedRectangle(cornerRadius: cardRadius, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [.white.opacity(0.07), .clear],
                                startPoint: .top, endPoint: .center)
                        )
                        .opacity(hovered ? 1 : 0)
                )
        )
        .overlay(  // status-tinted left accent bar — elongates as you hover
            HStack(spacing: 0) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(effectiveStatus.color.opacity(effectiveStatus == .idle ? 0.3 : 0.9))
                    .frame(width: hovered || selected ? 3.5 : 3)
                    .padding(.vertical, hovered || selected ? 6 : 10)
                Spacer(minLength: 0)
            }
        )
        .overlay(
            RoundedRectangle(cornerRadius: cardRadius, style: .continuous)
                .strokeBorder(borderColor, lineWidth: selected || hasApproval ? 1.5 : 1)
        )
        // Lift: a scale small enough to stay crisp, plus a shadow that gives the
        // card somewhere to lift *from*. Both ride the same spring as the chrome.
        .shadow(
            color: .black.opacity(hovered ? 0.30 : 0),
            radius: hovered ? 11 : 0, y: hovered ? 4 : 0
        )
        .scaleEffect(hovered && !reduceMotion ? 1.012 : 1, anchor: .center)
        .animation(reduceMotion ? nil : hoverSpring, value: hovered)
        .onHover { hovered = $0 }
        .pointingHandCursor(hovered)
        .modifier(
            SessionCardAccessibility(
                label: [
                    agent.projectDisplayTitle, agent.displayTitle, agent.kind.displayName,
                    effectiveStatus.displayLabel, showLastPrompt ? agent.currentTaskSummary : nil,
                ]
                .compactMap { $0 }.joined(separator: ", "),
                hint: ReturnResolver.resolve(agent).capability.unavailableReason.map { L10n.string($0) }
                    ?? ReturnResolver.resolve(agent).capability.actionLabel,
                preservesChildren: hasApproval || structuredQuestion != nil
                    || (agent.status.isActive && agent.codexManagedControl != nil),
                onActivate: onActivate,
                onShowDetail: onShowDetail
            ))
    }

    /// Quick and fully damped — the highlight tracks the cursor without any
    /// bounce, which is what makes it read as responsive rather than springy.
    private var hoverSpring: Animation { .spring(response: 0.30, dampingFraction: 0.86) }

    /// "Needs approval: Bash" + Approve / Always / Deny. Claude replies to
    /// its live terminal prompt; OpenCode replies to its validated local API.
    private var approvalBar: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 5) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(approvalColor)
                Text(approvalName.map { L10n.format("Approval needed: %@", $0) } ?? L10n.string("Needs your approval"))
                    .font(.system(size: fs, weight: .semibold))
                    .foregroundStyle(approvalColor)
                    .lineLimit(1)
            }
            HStack(spacing: 6) {
                ApprovalButton(label: "Approve", tint: AgentStatus.working.color) {
                    respondApproval(.approve)
                }
                ApprovalButton(label: "Always Allow", tint: .white.opacity(0.75)) {
                    respondApproval(.alwaysAllow)
                }
                ApprovalButton(label: "Deny", tint: Color(red: 1.0, green: 0.45, blue: 0.45)) {
                    respondApproval(.deny)
                }
                Spacer(minLength: 0)
            }
            controlResultLine
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(approvalColor.opacity(0.10)))
    }

    private var approvalName: String? {
        approval?.toolName ?? openCodePermission?.name
    }

    private var attentionOnlyBar: some View {
        HStack(spacing: 7) {
            Image(systemName: "exclamationmark.bubble.fill")
                .font(.system(size: 10))
                .foregroundStyle(approvalColor)
            Text(
                approvalName.map { L10n.format("Approval needed: %@", $0) }
                    ?? L10n.format("%@ needs your attention", agent.kind.displayName)
            )
            .font(.system(size: fs, weight: .semibold))
            .foregroundStyle(approvalColor)
            .lineLimit(1)
            Spacer(minLength: 4)
            Text(L10n.string("Jump to answer"))
                .font(.system(size: fs - 1, weight: .medium))
                .foregroundStyle(.white.opacity(0.45))
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(approvalColor.opacity(0.10))
        )
    }

    @ViewBuilder
    private var controlResultLine: some View {
        if controlInFlight {
            Text(L10n.string("Sending…"))
                .font(.system(size: fs - 1, weight: .medium))
                .foregroundStyle(.white.opacity(0.45))
        } else if controlFailed {
            Text(L10n.string(controlFailureMessage))
                .font(.system(size: fs - 1, weight: .medium))
                .foregroundStyle(Color(red: 1.0, green: 0.45, blue: 0.45))
        }
    }

    private var controlFailureMessage: String {
        if agent.codexManagedControl != nil {
            return "Codex connection stopped; your reply was not sent"
        }
        return "Request expired or could not be reached"
    }

    private func respondApproval(_ action: ApprovalCenter.Action) {
        guard !controlInFlight else { return }
        controlFailed = false
        if approval != nil {
            guard let pid = agent.processID else { controlFailed = true; return }
            controlInFlight = true
            ApprovalCenter.shared.respond(pid: pid, action: action) { success in
                finishProviderControl(success)
            }
            return
        }
        guard let control = agent.openCodeControl, control.permission != nil else {
            controlFailed = true
            return
        }
        let reply: OpenCodeSessions.PermissionReply
        switch action {
        case .approve: reply = .once
        case .alwaysAllow: reply = .always
        case .deny: reply = .reject
        }
        controlInFlight = true
        OpenCodeSessions.replyPermission(control: control, reply: reply) { success in
            finishProviderControl(success)
        }
    }

    /// Answer the agent's question straight into its terminal, without opening
    /// the detail view or switching to the terminal.
    private var replyBar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "arrowshape.turn.up.left.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(AgentStatus.needsAttention.color)
                TextField(L10n.format("Answer %@…", agent.kind.displayName), text: $replyText)
                    .textFieldStyle(.plain)
                    .font(.system(size: fs))
                    .foregroundStyle(.white)
                    .onSubmit(sendReply)
                Button(action: sendReply) {
                    Image(systemName: justSent ? "checkmark.circle.fill" : "arrow.up.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(
                            justSent
                                ? AgentStatus.working.color
                                : replyText.trimmingCharacters(in: .whitespaces).isEmpty
                                    ? .white.opacity(0.3)
                                    : Color(red: 0.45, green: 0.62, blue: 1.0))
                }
                .buttonStyle(.plain)
                .disabled(replyText.trimmingCharacters(in: .whitespaces).isEmpty || controlInFlight)
                .accessibilityLabel(L10n.format("Send answer to %@", agent.kind.displayName))
            }
            controlResultLine
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(AgentStatus.needsAttention.color.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(AgentStatus.needsAttention.color.opacity(0.25), lineWidth: 1))
    }

    private func sendReply() {
        let text = replyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !controlInFlight, canReply || structuredQuestion != nil else { return }
        if let control = agent.openCodeControl, control.questionRequestID != nil {
            submitOpenCodeQuestion(control: control, answers: [text])
            return
        }
        if let control = agent.codexManagedControl {
            controlInFlight = true
            controlFailed = false
            CodexAppServer.shared.send(text, to: control.threadID) { result in
                let success = (try? result.get()) != nil
                if success { replyText = "" }
                finishProviderControl(success)
            }
            return
        }
        controlInFlight = true
        controlFailed = false
        if agent.kind == .claude {
            approvals.answerQuestion(text: text, to: agent) { success in
                if success { replyText = "" }
                finishProviderControl(success)
            }
            return
        }
        let target = agent
        DispatchQueue.global(qos: .userInitiated).async {
            let success = TerminalBridge.send(text: text, to: target)
            DispatchQueue.main.async {
                if success { replyText = "" }
                finishProviderControl(success)
            }
        }
    }

    /// A structured AskUserQuestion → one tappable button per option, plus a
    /// free-text box for a custom ("Other") answer.
    private func questionBar(_ question: PendingQuestion) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: "questionmark.circle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(AgentStatus.needsAttention.color)
                Text(question.prompt)
                    .font(.system(size: fs, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(2)
                if question.multiSelect {
                    Text(L10n.string("· pick any"))
                        .font(.system(size: fs - 2))
                        .foregroundStyle(.white.opacity(0.4))
                }
            }
            ForEach(Array(question.options.prefix(6).enumerated()), id: \.offset) { index, option in
                let selected = selectedQuestionOptions.contains(index)
                Button {
                    if question.multiSelect, agent.openCodeControl?.questionRequestID != nil {
                        if selected {
                            selectedQuestionOptions.remove(index)
                        } else {
                            selectedQuestionOptions.insert(index)
                        }
                    } else {
                        answerChoice(index + 1, option: option)
                    }
                } label: {
                    HStack(spacing: 7) {
                        Text(selected ? "✓" : "\(index + 1)")
                            .font(.system(size: fs - 1, weight: .bold, design: .rounded))
                            .foregroundStyle(AgentStatus.needsAttention.color)
                            .frame(width: 16, height: 16)
                            .background(Circle().fill(AgentStatus.needsAttention.color.opacity(0.18)))
                        Text(option)
                            .font(.system(size: fs))
                            .foregroundStyle(.white.opacity(0.9))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(.white.opacity(0.06))
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if question.multiSelect,
                let control = agent.openCodeControl,
                control.questionRequestID != nil
            {
                ApprovalButton(label: "Submit choices", tint: AgentStatus.working.color) {
                    let answers = selectedQuestionOptions.sorted().compactMap { index in
                        question.options.indices.contains(index) ? question.options[index] : nil
                    }
                    guard !answers.isEmpty else { return }
                    submitOpenCodeQuestion(control: control, answers: answers)
                }
            }
            replyBar  // "Other" — type a custom answer
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(AgentStatus.needsAttention.color.opacity(0.10)))
    }

    /// Answer a choice: the digit selects the option in Claude's prompt and
    /// Enter confirms it (TerminalBridge.send types text + Enter).
    private func answerChoice(_ number: Int, option: String) {
        if let control = agent.openCodeControl, control.questionRequestID != nil {
            submitOpenCodeQuestion(control: control, answers: [option])
            return
        }
        guard !controlInFlight else { return }
        controlInFlight = true
        controlFailed = false
        approvals.answerQuestion(text: String(number), to: agent) { success in
            finishProviderControl(success)
        }
    }

    private func submitOpenCodeQuestion(control: OpenCodeControl, answers: [String]) {
        guard !controlInFlight else { return }
        controlInFlight = true
        controlFailed = false
        OpenCodeSessions.answerQuestion(control: control, answers: answers) { success in
            if success {
                replyText = ""
                selectedQuestionOptions.removeAll()
            }
            finishProviderControl(success)
        }
    }

    private func finishProviderControl(_ success: Bool) {
        controlInFlight = false
        controlFailed = !success
        if success {
            justSent = true
            if agent.codexManagedControl == nil { AgentMonitor.shared.scanNow() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { justSent = false }
        } else {
            OperationalDiagnostics.shared.recordControlFailure(
                "\(agent.kind.rawValue)/\(agent.surfaceID.rawValue): \(controlFailureMessage)"
            )
        }
    }

    /// Chips drop least-important-first when the row runs out of width, so
    /// they never squeeze the status text into vertical wrapping.
    private var chips: some View {
        ViewThatFits(in: .horizontal) {
            chipRow(model: showModel, branch: showGitBranch, terminal: showTerminalChip)
            chipRow(model: showModel, branch: showGitBranch, terminal: false)
            chipRow(model: false, branch: showGitBranch, terminal: false)
            chipRow(model: false, branch: false, terminal: false)
        }
    }

    private func chipRow(model: Bool, branch: Bool, terminal: Bool) -> some View {
        HStack(spacing: 4) {
            if agent.bypassPermissions {
                Chip(
                    text: "BYPASS",
                    textColor: Color(red: 1.0, green: 0.5, blue: 0.5),
                    background: Color(red: 1.0, green: 0.3, blue: 0.3).opacity(0.15))
            }
            Chip(
                text: agent.kind.displayName,
                textColor: .white.opacity(0.85),
                background: agent.kind.color.opacity(0.25))
            if agent.codexManagedControl != nil {
                Chip(
                    text: "Managed", textColor: AgentKind.codex.color,
                    background: AgentKind.codex.color.opacity(0.12))
            }
            if model, let name = agent.modelDisplay {
                Chip(text: name, textColor: .white.opacity(0.75), background: .white.opacity(0.08))
            }
            if branch, let name = agent.gitBranch {
                // Long branch names would crowd out the status line.
                Chip(
                    text: name.count > 16 ? name.prefix(15) + "…" : name,
                    textColor: .white.opacity(0.65), background: .white.opacity(0.08),
                    icon: "arrow.triangle.branch")
            }
            if terminal, let app = agent.terminalApp, app != agent.kind.displayName {
                Chip(text: app, textColor: .white.opacity(0.65), background: .white.opacity(0.08))
            }
        }
        .fixedSize()
    }

    @ViewBuilder
    private var statusLine: some View {
        if agent.observation.mode != .rich {
            Text(agent.displayStatusLabel)
                .font(.system(size: fs, weight: .medium))
                .foregroundStyle(
                    agent.observation.mode == .processOnly
                        ? .white.opacity(0.42) : AgentStatus.needsAttention.color.opacity(0.9)
                )
                .lineLimit(1)
                .help(L10n.string(agent.observation.reason ?? agent.observation.source))
        } else if agent.status == .working, showActivity {
            Text(
                L10n.format(
                    "Step · %@", agent.currentStepSummary ?? L10n.string("Processing task")
                )
            )
            .font(.system(size: fs, weight: .medium))
            .foregroundStyle(Color(red: 0.45, green: 0.62, blue: 1.0))
            .lineLimit(1)
            .help(
                "\(L10n.string(agent.observation.authority.shortLabel)) · \(agent.observation.source) · \(agent.freshnessLabel)"
            )
        } else {
            Text("\(effectiveStatus.displayLabel) · \(L10n.string(agent.observation.authority.shortLabel))")
                .font(.system(size: fs, weight: .medium))
                .foregroundStyle(
                    effectiveStatus == .idle || effectiveStatus == .stopped
                        ? .white.opacity(0.3) : effectiveStatus.color.opacity(0.9)
                )
                .lineLimit(1)
                .fixedSize()
        }
    }
}

enum AccessibilityTypography {
    static func cardFontSize(base: CGFloat, scaledReference: CGFloat) -> CGFloat {
        let scale = min(2, max(1, scaledReference / 11))
        return base * scale
    }
}

/// Pointing-hand cursor tied to a hover flag. Tracks its own push so it always
/// balances, including when the view disappears mid-hover — an agent card can
/// vanish out from under the cursor, and a missed `pop()` strands the whole
/// cursor stack on the pointing hand.
private struct PointingHandCursor: ViewModifier {
    let active: Bool
    @State private var pushed = false

    func body(content: Content) -> some View {
        content
            .onChange(of: active) { _, now in sync(to: now) }
            .onDisappear { sync(to: false) }
    }

    private func sync(to want: Bool) {
        guard want != pushed else { return }
        pushed = want
        if want { NSCursor.pointingHand.push() } else { NSCursor.pop() }
    }
}

private extension View {
    func pointingHandCursor(_ active: Bool) -> some View {
        modifier(PointingHandCursor(active: active))
    }
}

/// A normal card is represented by a real Button so VoiceOver's default Press
/// action follows the same path as a pointer click. Cards with live inline
/// controls preserve those children and expose the card actions alongside them.
private struct SessionCardAccessibility: ViewModifier {
    let label: String
    let hint: String
    let preservesChildren: Bool
    let onActivate: () -> Void
    let onShowDetail: () -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if preservesChildren {
            content
                .accessibilityElement(children: .contain)
                .accessibilityLabel(label)
                .accessibilityAction(named: Text(L10n.string("Return to session")), onActivate)
                .accessibilityAction(named: Text(L10n.string("Show conversation")), onShowDetail)
        } else {
            content.accessibilityRepresentation {
                Button(action: onActivate) { Text(label) }
                    .accessibilityHint(hint)
                    .accessibilityAction(named: Text(L10n.string("Return to session")), onActivate)
                    .accessibilityAction(named: Text(L10n.string("Show conversation")), onShowDetail)
            }
        }
    }
}

private struct ApprovalButton: View {
    let label: String
    let tint: Color
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Text(L10n.string(label))
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(tint)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Capsule().fill(tint.opacity(hovered ? 0.22 : 0.12)))
                .overlay(Capsule().strokeBorder(tint.opacity(hovered ? 0.55 : 0.35), lineWidth: 1))
                .contentShape(Capsule())
                .scaleEffect(hovered ? 1.04 : 1)
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.26, dampingFraction: 0.82), value: hovered)
        .onHover { hovered = $0 }
        .pointingHandCursor(hovered)
    }
}

/// Deliberately available only for LoopFwd-owned Codex turns. The provider's
/// interrupt acknowledgement drives the final state; the button never fakes a
/// successful stop locally.
struct ManagedStopButton: View {
    let threadID: String
    @State private var stopping = false
    @State private var failed = false
    @State private var hovered = false

    var body: some View {
        Button(action: stop) {
            HStack(spacing: 4) {
                if stopping {
                    ProgressView().controlSize(.mini).tint(tint)
                } else {
                    Image(systemName: failed ? "exclamationmark.circle.fill" : "stop.fill")
                        .font(.system(size: 7, weight: .bold))
                }
                Text(stopping ? "Stopping" : "Stop")
            }
            .font(.system(size: 9.5, weight: .semibold, design: .rounded))
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(tint.opacity(hovered ? 0.20 : 0.10)))
            .overlay(Capsule().strokeBorder(tint.opacity(hovered ? 0.55 : 0.30), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(stopping)
        .help(failed ? "Codex did not accept the stop request. Try again." : "Stop this managed Codex task")
        .onHover { hovered = $0 }
        .pointingHandCursor(hovered && !stopping)
        .accessibilityLabel(failed ? "Retry stopping Codex task" : "Stop Codex task")
    }

    private var tint: Color { Color(red: 1.0, green: 0.45, blue: 0.45) }

    private func stop() {
        guard !stopping else { return }
        stopping = true
        failed = false
        CodexAppServer.shared.interrupt(threadID: threadID) { result in
            if case .failure = result {
                stopping = false
                failed = true
            }
        }
    }
}

struct Chip: View {
    let text: String
    let textColor: Color
    let background: Color
    var icon: String?

    var body: some View {
        HStack(spacing: 2.5) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 8, weight: .semibold))
            }
            Text(text)
        }
        .font(.system(size: 9.5, weight: .semibold, design: .rounded))
        .foregroundStyle(textColor)
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(background))
    }
}
