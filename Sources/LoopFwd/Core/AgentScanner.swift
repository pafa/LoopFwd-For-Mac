import Darwin
import Foundation
import AppKit

struct AgentScanResult {
    let sessions: [AgentSession]
    let providerDurations: [AgentKind: TimeInterval]
    let providerCacheHits: [AgentKind: Int]
    var readerResults: [IntegrationSurfaceID: ProviderReadResult] = [:]
    var surfaceDurations: [IntegrationSurfaceID: TimeInterval] = [:]
    var processScanSucceeded = true
}

/// Pure scanning and provider-projection assembly kept separate from the
/// observable lifecycle/coalescing state in AgentMonitor.
enum AgentScanner {

    private struct ProcInfo {
        let ppid: Int32
        let command: String  // full path or command name (ps comm)
    }

    private struct CachedProcessMetadata {
        let command: String
        var cwd: String?
        var cwdRead = false
        var terminal: String?
        var terminalRead = false
        var environment: [String: String] = [:]
        var environmentReads: Set<String> = []
    }

    /// The process scanner is serialized, so one compact cache can avoid
    /// repeating lsof, KERN_PROCARGS2 and parent-host walks on every scan.
    /// Entries disappear as soon as the PID does, and a recycled PID with a
    /// different command gets a fresh entry.
    private static var processMetadata: [Int32: CachedProcessMetadata] = [:]
    private static var classificationCache = ProcessClassificationCache()
    private static var processReadSchedule = ProviderProcessReadSchedule()

    static func findAgents() async -> AgentScanResult {
        let disabled = Pref.disabledKinds
        let hideIdleMinutes = UserDefaults.standard.integer(forKey: Pref.hideIdleAfterMinutes)
        var providerDurations: [AgentKind: TimeInterval] = [:]
        var readerResults: [IntegrationSurfaceID: ProviderReadResult] = [:]
        var surfaceDurations: [IntegrationSurfaceID: TimeInterval] = [:]

        // Full process table: pid, ppid, cpu, tty, etime, args — one pass.
        let output = run("/bin/ps", ["-axwwo", "pid=,ppid=,pcpu=,tty=,etime=,args="])
        guard !output.isEmpty else {
            return .init(sessions: [], providerDurations: [:], providerCacheHits: [:], processScanSucceeded: false)
        }
        var procs: [Int32: ProcInfo] = [:]
        var candidates:
            [(pid: Int32, ppid: Int32, cpu: Double, tty: String?, etime: String, args: String, kind: AgentKind)] = []
        let runningApplications = NSWorkspace.shared.runningApplications
        let runningBundleIDs = Set(runningApplications.compactMap(\.bundleIdentifier))
        let workBuddyApps = runningApplications.reduce(into: [String: String]()) { result, application in
            guard !disabled.contains(.workbuddy),
                application.bundleIdentifier == WorkBuddySessions.bundleIdentifier,
                let url = application.bundleURL,
                Bundle(url: url)?.bundleIdentifier == WorkBuddySessions.bundleIdentifier
            else { return }
            result[url.path] =
                Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        }
        let codexDesktopRunning = runningBundleIDs.contains("com.openai.codex")
        let codexDesktopEnvironments =
            runningApplications
            .filter { $0.bundleIdentifier == "com.openai.codex" }
            .map { processEnvironmentValues(pid: $0.processIdentifier, keys: ["CODEX_HOME"]) }
        let codexDesktopRoot = Result {
            try ProviderDataLocations.codexDesktopRoot(
                selected: UserDefaults.standard.string(forKey: Pref.codexDesktopDataDirectory),
                processEnvironments: codexDesktopEnvironments, defaultRoot: NSHomeDirectory() + "/.codex")
        }
        let openCodeDesktopRunning = runningBundleIDs.contains("ai.opencode.desktop")

        for row in processRows(output) {
            let (pid, ppid, cpu, tty, args) = (row.pid, row.ppid, row.cpu, row.tty, row.args)
            // Store the full args, not a space-split first token: app bundle
            // paths contain spaces, and truncating there lost VS Code, Cursor
            // and Windsurf entirely. See ProcessNaming.
            procs[pid] = ProcInfo(ppid: ppid, command: args)
            if let kind = classificationCache.classify(
                pid: pid, command: args, tty: tty,
                detect: {
                    detect(args: args, tty: tty)
                }),
                !disabled.contains(kind),
                !isHeadless(tty: tty, args: args)
            {
                candidates.append((pid, ppid, cpu, tty, row.elapsed, args, kind))
            }
        }
        classificationCache.retain(livePIDs: Set(procs.keys))

        // Identify official bootstrap/relaunch processes before filtering helpers.
        let agentKindByPid = Dictionary(uniqueKeysWithValues: candidates.map { ($0.pid, $0.kind) })
        let candidatesByPID = Dictionary(uniqueKeysWithValues: candidates.map { ($0.pid, $0) })
        var nodeLaunchers = Set<Int32>()
        var launchEnvironments: [Int32: [String: String]] = [:]
        for child in candidates where child.kind == .qwen || child.kind == .gemini {
            guard let parent = candidatesByPID[child.ppid], parent.kind == child.kind,
                child.tty != nil, child.tty == parent.tty
            else { continue }
            for process in [parent, child] where launchEnvironments[process.pid] == nil {
                let keys =
                    process.kind == .qwen
                    ? ["QWEN_CODE_LAUNCHER_PID", "QWEN_CODE_NO_RELAUNCH"] : ["GEMINI_CLI_NO_RELAUNCH"]
                launchEnvironments[process.pid] = processEnvironmentValues(pid: process.pid, keys: Set(keys))
            }
            guard let parentEnvironment = launchEnvironments[parent.pid],
                let childEnvironment = launchEnvironments[child.pid]
            else { continue }
            if ProcessNaming.isNodeAgentRelaunch(
                parentPID: parent.pid, parentCommand: parent.args, childCommand: child.args,
                parentEnvironment: parentEnvironment, childEnvironment: childEnvironment)
            {
                nodeLaunchers.insert(parent.pid)
            }
        }
        let copilotLaunchers = Set(
            candidates.compactMap { candidate -> Int32? in
                guard candidate.kind == .copilot,
                    ProcessNaming.isCopilotNativeLaunch(
                        childCommand: candidate.args, parentCommand: procs[candidate.ppid]?.command)
                else { return nil }
                return candidate.ppid
            })
        let launchers = copilotLaunchers.union(nodeLaunchers)
        let rows = candidates.filter {
            // npm's Copilot launcher is not the process owning the live tabs.
            ProcessNaming.retainsAgentProcess(
                pid: $0.pid, kind: $0.kind, parentPID: $0.ppid,
                parentKind: agentKindByPid[$0.ppid], launchers: launchers)
                // …and GUI background helpers, which Electron names after the app
                // itself so they match an agent alias. See ProcessNaming.
                && !ProcessNaming.isGUIHelper(
                    tty: $0.tty, childCommand: $0.args, parentCommand: procs[$0.ppid]?.command)
        }
        var providerCacheHits: [AgentKind: Int] = [:]
        let starts = rows.isEmpty && workBuddyApps.isEmpty ? "" : run("/bin/ps", ["-axo", "pid=,lstart="])
        var processStarts: [Int32: String] = [:]
        for line in starts.split(separator: "\n") {
            let parts = line.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            if parts.count == 2, let pid = Int32(parts[0]) { processStarts[pid] = String(parts[1]) }
        }
        let liveCommands = Dictionary(
            uniqueKeysWithValues: rows.map {
                ($0.pid, $0.args + "|" + (processStarts[$0.pid] ?? UUID().uuidString))
            })
        for row in rows where processMetadata[row.pid]?.command == liveCommands[row.pid] {
            providerCacheHits[row.kind, default: 0] += 1
        }
        let recycled = Set(
            rows.filter {
                processMetadata[$0.pid] != nil && processMetadata[$0.pid]?.command != liveCommands[$0.pid]
            }.map(\.pid))
        CodexSessions.prune(livePids: Set(rows.filter { $0.kind == .codex }.map(\.pid)).subtracting(recycled))
        OpenCodeSessions.prune(livePids: Set(rows.filter { $0.kind == .opencode }.map(\.pid)).subtracting(recycled))
        let retainedCommands = ProcessCachePolicy.retained(
            cached: processMetadata.mapValues(\.command), live: liveCommands)
        processMetadata = processMetadata.filter { retainedCommands[$0.key] != nil }
        for row in rows where processMetadata[row.pid]?.command != liveCommands[row.pid] {
            processMetadata[row.pid] = CachedProcessMetadata(command: liveCommands[row.pid] ?? UUID().uuidString)
        }

        if ProcessInfo.processInfo.environment["LOOPFWD_DEBUG_SCAN"] == "1" {
            let summary = rows.map {
                "\($0.pid):\($0.kind.rawValue):\($0.tty ?? "no-tty")"
            }.joined(separator: ",")
            let line = "[LoopFwd] scan candidates=\(candidates.count) rows=[\(summary)]\n"
            FileHandle.standardError.write(Data(line.utf8))
        }

        let claudeConfigDirs = Dictionary(
            uniqueKeysWithValues:
                rows
                .filter { $0.kind == .claude }
                .map { ($0.pid, claudeConfigDir(for: $0.pid)) })
        let registryStartedAt = Date()
        let claudeRead: ClaudeSessions.RegistryRead
        var exitedClaudePIDs: Set<Int32> = []
        if let starts = ClaudeSessions.processStartsUTC(pids: Array(claudeConfigDirs.keys)) {
            exitedClaudePIDs = Set(claudeConfigDirs.keys).subtracting(starts.keys)
            claudeRead = ClaudeSessions.readRegistry(
                configDirs: Set(claudeConfigDirs.filter { !exitedClaudePIDs.contains($0.key) }.values),
                processStartsUTC: starts, configDirsByPID: claudeConfigDirs)
            if !exitedClaudePIDs.isEmpty {
                readerResults[.claudeCLI] = .init(
                    outcome: .empty, source: "Claude session registry", sessions: [], reason: nil)
            }
        } else {
            claudeRead = .init(
                sessions: [:], outcome: .failed,
                reason: "Claude session registry process identity could not be verified")
        }
        if !claudeConfigDirs.isEmpty {
            surfaceDurations[.claudeCLI] = Date().timeIntervalSince(registryStartedAt)
        }
        let discoveredClaudeMetas = claudeRead.sessions
        let claudeMetas = discoveredClaudeMetas.filter {
            claudeConfigDirs[$0.key] == $0.value.configDir
        }
        let needCwd = rows.filter { $0.kind != .claude || claudeMetas[$0.pid] == nil }.map(\.pid)
        let cwds = cachedCwdByPid(needCwd)

        var sessions: [AgentSession] = []
        let rowsByPID = Dictionary(uniqueKeysWithValues: rows.map { ($0.pid, $0) })
        let readOrder = processReadSchedule.begin(rows.map(\.pid).filter { !exitedClaudePIDs.contains($0) })
        for pid in readOrder {
            guard let row = rowsByPID[pid] else { continue }
            let surface = ProviderProcessReadSchedule.surface(for: row.kind)
            let budget = IntegrationProfiles.profile(for: surface, kind: row.kind).readerBudget
            guard processReadSchedule.admit(pid: pid, kind: row.kind, budget: budget) else {
                let deferredRead = ProviderReadResult(
                    outcome: .partial, source: "CLI process batch", sessions: [],
                    reason: "Scan incomplete; remaining processes will be read first next time")
                readerResults[surface] = readerResults[surface]?.merging(deferredRead) ?? deferredRead
                continue
            }
            let providerStartedAt = ProcessInfo.processInfo.systemUptime
            let bypass =
                row.args.contains("bypassPermissions")
                || row.args.contains("--dangerously-skip-permissions")
                || row.args.contains("--yolo")
            let terminal = cachedTerminalApp(for: row.pid, procs: procs)

            var session = AgentSession(
                id: "process:\(row.kind.rawValue):\(row.pid)",
                processID: row.pid,
                kind: row.kind,
                cpu: row.cpu,
                elapsed: prettyElapsed(row.etime),
                cwd: cwds[row.pid],
                status: row.cpu > 3.0 ? .working : .idle,
                terminalApp: terminal,
                tty: row.tty,
                bypassPermissions: bypass,
                returnTarget: returnTarget(terminal: terminal, tty: row.tty, processID: row.pid),
                observation: .processOnly("Process table", reason: "No compatible session data matched this process")
            )
            session.processStartedAt = processStarts[row.pid]
            session.surfaceID = surface
            let codexDiscovery =
                row.kind == .codex
                ? CodexSessions.discoverRollout(
                    pid: row.pid, cwd: cwds[row.pid],
                    codexHome: cachedProcessEnvironmentValue(pid: row.pid, key: "CODEX_HOME"))
                : nil
            if row.kind == .claude { session.surfaceID = .claudeCLI }
            if row.kind == .codex { session.surfaceID = .codexCLI }
            defer {
                let duration = ProcessInfo.processInfo.systemUptime - providerStartedAt
                processReadSchedule.record(kind: row.kind, duration: duration)
                providerDurations[row.kind, default: 0] += duration
                surfaceDurations[session.surfaceID, default: 0] += duration
                if row.kind == .codex || row.kind == .claude {
                    let source = row.kind == .codex ? "Codex CLI rollout" : "Claude session registry"
                    let read = ProviderReadResult.observations([session], source: source)
                    readerResults[session.surfaceID] = readerResults[session.surfaceID]?.merging(read) ?? read
                }
            }

            if row.kind == .claude, let meta = claudeMetas[row.pid] {
                session.surfaceID = .claudeCLI
                session.id = "claude:\(meta.sessionId)"
                session.cwd = meta.cwd
                let path = ClaudeSessions.transcriptPath(for: meta)
                session.transcriptPath = path
                let info = ClaudeSessions.tailInfo(path: path)
                // meta.name carries a hash suffix ("myproj-0d") — prefer the AI
                // title, then fall back to the clean cwd basename in the view.
                session.title = info.title
                session.lastPrompt = info.lastPrompt
                session.lastMessage = info.lastMessage
                session.model = info.model
                session.subagents = info.subagents
                session.plan = info.plan
                // Transcript questions are historical, not live input requests.
                let statusUpdatedAt =
                    meta.statusUpdatedAt.map {
                        Date(timeIntervalSince1970: $0 / 1000)
                    } ?? Date()
                session.observation =
                    ["busy", "idle"].contains(meta.status ?? "")
                    ? .rich("Claude session registry", updatedAt: statusUpdatedAt)
                    : .processOnly(
                        "Claude session registry", reason: "Registry does not expose a recognized task state")
                // Task store is the current system; TodoWrite in the
                // transcript is the legacy fallback.
                let storeTasks = ClaudeSessions.tasks(for: meta)
                session.todos = storeTasks.isEmpty ? info.todos : storeTasks

                let idleAge =
                    meta.statusUpdatedAt.map {
                        Date().timeIntervalSince1970 - $0 / 1000
                    } ?? 0
                if meta.status == "busy" {
                    session.status = .working
                    session.activity = info.activity ?? "Thinking…"
                } else {
                    session.status = .idle
                    if hideIdleMinutes > 0, idleAge > Double(hideIdleMinutes) * 60 { continue }
                }
            } else if row.kind == .codex,
                let discovery = codexDiscovery, discovery.mode != .processOnly,
                let path = discovery.path
            {
                session.surfaceID = .codexCLI
                if let threadID = CodexSessions.threadID(path: path) {
                    session.id = "codex:\(threadID)"
                }
                let info = CodexSessions.tailInfo(path: path)
                session.turnID = info.turnID
                session.transcriptPath = path
                session.lastPrompt = info.lastPrompt
                session.lastMessage = info.lastMessage
                session.model = info.model
                session.todos = info.todos
                session.observation = .rich("Codex rollout", updatedAt: modificationDate(path) ?? Date())

                let mtime = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? nil
                let idleAge = mtime.map { Date().timeIntervalSince($0) } ?? 0
                switch info.phase {
                case .working:
                    session.status = .working
                    session.activity = info.activity ?? "Thinking…"
                case .completed:
                    session.status = idleAge > 30 * 60 ? .idle : .completed
                    if discovery.mode == .rich, hideIdleMinutes > 0, idleAge > Double(hideIdleMinutes) * 60 { continue }
                case .failed:
                    session.status = .failed
                case .stopped:
                    session.status = .stopped
                case .unknown:
                    // Without an explicit task boundary, expose only the
                    // process-level signal.
                    session.observation = .processOnly(
                        "Process table + Codex rollout",
                        reason: "No current Codex task boundary could be confirmed"
                    )
                    if session.status != .working { session.status = .idle }
                    if discovery.mode == .rich, hideIdleMinutes > 0, idleAge > Double(hideIdleMinutes) * 60 { continue }
                }
                if !info.readSucceeded {
                    session.observation = .init(
                        mode: .stale,
                        updatedAt: info.lastSuccessfulReadAt ?? .distantPast,
                        source: "Codex rollout", reason: info.readIssue ?? "Rollout could not be read or parsed")
                }
                if discovery.mode == .stale {
                    session.observation.mode = .stale
                    session.observation.reason = discovery.reason
                }
            } else if row.kind == .opencode {
                session.surfaceID = .openCodeTUI
                let expectedDirectory = session.cwd
                let batch = await OpenCodeSessions.read(pid: row.pid, expectedDirectory: expectedDirectory)
                var projected: [AgentSession] = []
                for info in batch.infos {
                    var session = session
                    session.id = "opencode:\(info.control.sessionID)"
                    session.turnID = info.turnID
                    session.cwd = info.directory
                    session.title = info.title
                    session.status = info.status
                    session.model = info.model
                    session.lastPrompt = info.lastPrompt
                    session.lastMessage = info.lastMessage
                    session.activity = info.activity
                    session.todos = info.todos
                    session.pendingQuestion = info.pendingQuestion
                    session.openCodeControl = info.control
                    session.observedVersion = info.observedVersion
                    session.observation = .rich(
                        "OpenCode loopback API",
                        updatedAt: Date(timeIntervalSince1970: info.updatedAt / 1000),
                        authority: .officialLive
                    )

                    let idleAge = Date().timeIntervalSince1970 - info.updatedAt / 1000
                    if hideIdleMinutes > 0, session.status == .idle,
                        idleAge > Double(hideIdleMinutes) * 60
                    {
                        continue
                    }
                    projected.append(session)
                }
                let result = ProviderReadResult(
                    outcome: batch.outcome, source: "OpenCode loopback API",
                    sessions: projected, reason: batch.reason)
                readerResults[.openCodeTUI] = readerResults[.openCodeTUI]?.merging(result) ?? result
                if batch.outcome == .incompatible {
                    session.observation = .init(
                        mode: .incompatible, updatedAt: .distantPast,
                        source: result.source, reason: batch.reason)
                } else if batch.outcome != .failed {
                    sessions.append(contentsOf: projected)
                    continue
                }
            } else if row.kind == .grok {
                session.surfaceID = .grokCLI
                let openEvents = run("/usr/sbin/lsof", ["-a", "-p", String(row.pid), "-Fn"])
                    .split(separator: "\n").filter { $0.hasPrefix("n") && $0.hasSuffix("/events.jsonl") }
                    .map { String($0.dropFirst()) }
                let batch = GrokSessions.read(
                    pid: row.pid, grokHome: cachedProcessEnvironmentValue(pid: row.pid, key: "GROK_HOME"),
                    openEvents: openEvents, processStartedAt: processStarts[row.pid])
                let projected = batch.infos.compactMap { info -> AgentSession? in
                    guard let id = info.sessionID, let directory = info.directory else { return nil }
                    var item = session
                    item.id = "grok:\(id)"
                    item.turnID = info.turnID
                    item.cwd = info.cwd
                    item.transcriptPath = directory + "/chat_history.jsonl"
                    item.title = info.title
                    item.lastPrompt = info.lastPrompt
                    item.lastMessage = info.lastMessage
                    item.model = info.model
                    item.todos = info.todos
                    item.activity = info.activity
                    item.observation = info.observation
                    switch info.phase {
                    case .working: item.status = .working
                    case .completed: item.status = .completed
                    case .needsAttention: item.status = .needsAttention
                    case .failed: item.status = .failed
                    case .stopped: item.status = .stopped
                    case .unknown: item.status = .idle
                    }
                    if batch.infos.count > 1 {
                        item.returnTarget = CopilotSessions.returnTarget(terminalApp: item.terminalApp)
                    }
                    return item
                }
                let result = ProviderReadResult(
                    outcome: batch.outcome, source: GrokSessions.source, sessions: projected, reason: batch.reason)
                readerResults[.grokCLI] = readerResults[.grokCLI]?.merging(result) ?? result
                if !projected.isEmpty {
                    sessions.append(contentsOf: projected)
                    continue
                }
                session.observation = .processOnly(
                    GrokSessions.source, reason: batch.reason ?? "No process-owned Grok session could be verified")
            } else if row.kind == .gemini, let cwd = cwds[row.pid] {
                session.surfaceID = .geminiCLI
                let openFiles = run("/usr/sbin/lsof", ["-a", "-p", String(row.pid), "-Fn"])
                    .split(separator: "\n").filter { $0.hasPrefix("n") }.map { String($0.dropFirst()) }
                let info = GeminiSessions.info(
                    cwd: cwd, args: row.args,
                    geminiHome: cachedProcessEnvironmentValue(pid: row.pid, key: "GEMINI_CLI_HOME"),
                    openChatPaths: openFiles, processID: row.pid, processStartedAt: processStarts[row.pid],
                    observerRoot: cachedProcessEnvironmentValue(pid: row.pid, key: "LOOPFWD_HOOK_ROOT"))
                if let id = info.sessionID { session.id = "gemini:\(id.lowercased())" }
                session.turnID = info.turnID
                session.lastPrompt = info.lastPrompt
                session.lastMessage = info.lastMessage
                session.model = info.model
                session.transcriptPath = info.chatPath
                // A readable historical response cannot prove the live phase.
                // CPU activity remains explicitly process-only, not rich state.
                session.observation = info.observation ?? .processOnly("Gemini local recording", reason: info.reason)
                if let status = info.status { session.status = status }
                session.activity = info.activity
                if info.observation == nil, let updatedAt = info.updatedAt { session.observation.updatedAt = updatedAt }
            } else if row.kind == .cursorAgent {
                session.surfaceID = .cursorCLI
                let openFiles = run("/usr/sbin/lsof", ["-a", "-p", String(row.pid), "-Fn"])
                    .split(separator: "\n").filter { $0.hasPrefix("n") }.map { String($0.dropFirst()) }
                if let info = CursorSessions.info(
                    cwd: cwds[row.pid],
                    args: row.args,
                    cpu: row.cpu,
                    configDirectory: cachedProcessEnvironmentValue(
                        pid: row.pid, key: "CURSOR_CONFIG_DIR"),
                    xdgConfigHome: cachedProcessEnvironmentValue(
                        pid: row.pid, key: "XDG_CONFIG_HOME"),
                    dataDirectory: cachedProcessEnvironmentValue(pid: row.pid, key: "CURSOR_DATA_DIR"),
                    openChatPaths: openFiles, processID: row.pid, processStartedAt: processStarts[row.pid]
                ) {
                    session.id = "cursor:\(info.sessionID)"
                    session.cwd = info.cwd ?? session.cwd
                    session.transcriptPath = info.transcriptPath
                    session.title = info.title
                    session.status = info.status
                    session.lastPrompt = info.lastPrompt
                    session.lastMessage = info.lastMessage
                    session.activity = info.activity
                    session.model = info.model
                    session.observation = info.observation
                } else {
                    session.observation = .processOnly(
                        "Cursor local transcript",
                        reason: "No exact process-owned Cursor conversation could be verified")
                }
            } else if row.kind == .copilot {
                session.surfaceID = .copilotCLI
                let batch = CopilotSessions.read(
                    processID: row.pid, processStartedAt: processStarts[row.pid], cwd: cwds[row.pid],
                    home: cachedProcessEnvironmentValue(pid: row.pid, key: "COPILOT_HOME"))
                let projected = batch.sessions.map { info in
                    var item = session
                    item.id = "copilot:\(info.sessionID)"
                    item.cwd = info.cwd ?? item.cwd
                    item.transcriptPath = info.transcriptPath
                    item.title = info.title
                    item.status = info.status
                    item.lastPrompt = info.lastPrompt
                    item.lastMessage = info.lastMessage
                    item.activity = info.activity
                    item.model = info.model
                    item.turnID = info.turnID
                    item.observation = info.observation
                    // A CLI can host several tabs. A TTY jump cannot select a
                    // particular Copilot tab, so never promise exact return.
                    item.returnTarget = CopilotSessions.returnTarget(terminalApp: item.terminalApp)
                    return item
                }
                let result = ProviderReadResult(
                    outcome: batch.outcome, source: CopilotSessions.source, sessions: projected, reason: batch.reason)
                readerResults[.copilotCLI] = readerResults[.copilotCLI]?.merging(result) ?? result
                if !projected.isEmpty || batch.outcome == .empty {
                    sessions.append(contentsOf: projected)
                    continue
                }
                session.observation = .processOnly(CopilotSessions.source, reason: batch.reason)
            } else if row.kind == .kimi {
                session.surfaceID = .kimiCLI
                session.returnTarget = KimiSessions.returnTarget(terminalApp: session.terminalApp)
                let openWires = run("/usr/sbin/lsof", ["-a", "-p", String(row.pid), "-Fn"])
                    .split(separator: "\n").filter { $0.hasPrefix("n") && $0.hasSuffix("/agents/main/wire.jsonl") }
                    .map { String($0.dropFirst()) }
                let batch = KimiSessions.read(
                    processID: row.pid, processStartedAt: processStarts[row.pid],
                    cwd: cwds[row.pid],
                    args: row.args,
                    dataRoot: cachedProcessEnvironmentValue(pid: row.pid, key: "KIMI_CODE_HOME"),
                    openWirePaths: openWires,
                    observerRoot: cachedProcessEnvironmentValue(pid: row.pid, key: "LOOPFWD_HOOK_ROOT")
                )
                let projected = batch.sessions.map { info in
                    var item = session
                    item.id = "kimi:\(info.sessionID)"
                    item.turnID = info.turnID
                    item.cwd = info.cwd ?? item.cwd
                    item.transcriptPath = info.transcriptPath
                    item.title = info.title
                    item.status = info.status
                    item.lastPrompt = info.lastPrompt
                    item.lastMessage = info.lastMessage
                    item.activity = info.activity
                    item.model = info.model
                    item.observation = info.observation
                    // A lease identifies the session, not which one the TUI
                    // currently displays. Do not label opening its app exact.
                    item.returnTarget = KimiSessions.returnTarget(terminalApp: item.terminalApp)
                    return item
                }
                let result = ProviderReadResult(
                    outcome: batch.outcome, source: KimiSessions.source,
                    sessions: projected, reason: batch.reason)
                readerResults[.kimiCLI] = readerResults[.kimiCLI]?.merging(result) ?? result
                if !projected.isEmpty || batch.outcome == .empty {
                    sessions.append(contentsOf: projected)
                    continue
                }
                session.observation = .processOnly(KimiSessions.source, reason: batch.reason)
            } else if row.kind == .qwen,
                let info = QwenSessions.info(
                    cwd: cwds[row.pid],
                    args: row.args,
                    cpu: row.cpu,
                    runtimeRoot: cachedProcessEnvironmentValue(pid: row.pid, key: "QWEN_RUNTIME_DIR"),
                    qwenHome: cachedProcessEnvironmentValue(pid: row.pid, key: "QWEN_HOME"),
                    processID: row.pid, processStartedAt: processStarts[row.pid],
                    observerRoot: cachedProcessEnvironmentValue(pid: row.pid, key: "LOOPFWD_HOOK_ROOT")
                )
            {
                session.surfaceID = .qwenCLI
                session.id = "qwen:\(info.sessionID)"
                session.cwd = info.cwd ?? session.cwd
                session.transcriptPath = info.transcriptPath
                session.title = info.title
                session.status = info.status
                session.lastPrompt = info.lastPrompt
                session.lastMessage = info.lastMessage
                session.activity = info.activity
                session.model = info.model
                session.observation = info.observation

                let idleAge = Date().timeIntervalSince(info.updatedAt)
                if hideIdleMinutes > 0, session.status == .idle,
                    idleAge > Double(hideIdleMinutes) * 60
                {
                    continue
                }
            } else if row.kind == .mistral,
                let info = MistralSessions.info(
                    cwd: cwds[row.pid],
                    args: row.args,
                    cpu: row.cpu,
                    vibeHome: cachedProcessEnvironmentValue(pid: row.pid, key: "VIBE_HOME"),
                    processID: row.pid, processStartedAt: processStarts[row.pid],
                    observerRoot: cachedProcessEnvironmentValue(pid: row.pid, key: "LOOPFWD_HOOK_ROOT")
                )
            {
                session.surfaceID = .mistralCLI
                session.id = "mistral:\(info.sessionID)"
                session.cwd = info.cwd ?? session.cwd
                session.transcriptPath = info.transcriptPath
                session.title = info.title
                session.status = info.status
                session.lastPrompt = info.lastPrompt
                session.lastMessage = info.lastMessage
                session.activity = info.activity
                session.model = info.model
                session.observation = info.observation

                let idleAge = Date().timeIntervalSince(info.updatedAt)
                if hideIdleMinutes > 0, session.status == .idle,
                    idleAge > Double(hideIdleMinutes) * 60
                {
                    continue
                }
            }

            if let discovery = codexDiscovery, discovery.mode == .processOnly {
                session.observation = .processOnly("Codex process discovery", reason: discovery.reason)
            }

            // Model fallback from the command line (-m / --model), then the
            // Gemini CLI's local default.
            if session.model == nil { session.model = argsModel(row.args) }
            if session.model == nil, row.kind == .gemini {
                session.model = GeminiSessions.defaultModel(
                    geminiHome: cachedProcessEnvironmentValue(pid: row.pid, key: "GEMINI_CLI_HOME"))
            }

            // Branch reads touch project folders (often in ~/Documents, which
            // is TCC-protected) — skip them entirely when the chip is off.
            if UserDefaults.standard.bool(forKey: Pref.showGitBranch) {
                session.gitBranch = gitBranch(cwd: session.cwd)
            }
            sessions.append(session)
        }

        if !workBuddyApps.isEmpty, !disabled.contains(.workbuddy) {
            let started = ProcessInfo.processInfo.systemUptime
            let identities = procs.reduce(into: [Int32: WorkBuddySessions.ProcessIdentity]()) { result, entry in
                if let birth = processStarts[entry.key] {
                    result[entry.key] = .init(command: entry.value.command, startedAt: birth)
                }
            }
            let read = WorkBuddySessions.read(
                processes: identities, applications: workBuddyApps,
                configRoot: { pid in
                    processEnvironmentValue(pid: pid, key: "CODEBUDDY_CONFIG_DIR")
                        ?? processEnvironmentValue(pid: pid, key: "WORKBUDDY_CONFIG_DIR")
                        ?? NSHomeDirectory() + "/.workbuddy"
                })
            sessions.append(contentsOf: read.sessions)
            readerResults[.workBuddyDesktop] = read
            let duration = ProcessInfo.processInfo.systemUptime - started
            providerDurations[.workbuddy] = duration
            surfaceDurations[.workBuddyDesktop] = duration
        }

        // Each Desktop reader owns a separate database and bounded cursor.
        // At most two run together; process/TTY cache mutation above remains
        // serialized, and neither database can stall the other's own budget.
        let desktopReads = await withTaskGroup(of: DesktopRead.self) { group in
            if codexDesktopRunning, !disabled.contains(.codex) {
                group.addTask {
                    let startedAt = Date()
                    let result = CodexDesktopSessions.read(root: codexDesktopRoot)
                    return DesktopRead(
                        kind: .codex, surface: .codexDesktop, result: result,
                        duration: Date().timeIntervalSince(startedAt))
                }
            }
            if openCodeDesktopRunning, !disabled.contains(.opencode) {
                group.addTask {
                    let startedAt = Date()
                    let result = OpenCodeDesktopSessions.read(hideIdleAfterMinutes: hideIdleMinutes)
                    return DesktopRead(
                        kind: .opencode, surface: .openCodeDesktop, result: result,
                        duration: Date().timeIntervalSince(startedAt))
                }
            }
            var reads: [DesktopRead] = []
            for await read in group { reads.append(read) }
            return reads
        }
        for read in desktopReads {
            readerResults[read.surface] = read.result
            let bundleID = read.kind == .codex ? "com.openai.codex" : "ai.opencode.desktop"
            let versions = Set(
                runningApplications.filter { $0.bundleIdentifier == bundleID }.compactMap {
                    $0.bundleURL.flatMap {
                        Bundle(url: $0)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
                    }
                })
            let version = versions.count == 1 ? versions.first : nil
            sessions.append(
                contentsOf: read.result.sessions.map {
                    var session = $0
                    session.observedVersion = .metadata(version, source: "Running app bundle")
                    return session
                })
            providerDurations[read.kind, default: 0] += read.duration
            surfaceDurations[read.surface] = read.duration
        }
        if !claudeConfigDirs.isEmpty {
            if claudeRead.outcome == .failed || claudeRead.outcome == .partial || claudeRead.outcome == .incompatible {
                let failure = ProviderReadResult(
                    outcome: claudeRead.outcome, source: "Claude session registry", sessions: [],
                    reason: claudeRead.reason)
                readerResults[.claudeCLI] = readerResults[.claudeCLI]?.merging(failure) ?? failure
            }
        }

        if !disabled.contains(.deepseek) {
            let startedAt = Date()
            let dshProcess = rows.first(where: { $0.kind == .deepseek })?.pid
            let projection = DeepSeekHarnessSessions.read(processID: dshProcess)
            if dshProcess != nil || projection.health.mode == .rich {
                readerResults[.deepSeekWeb] = projection.readResult
            }
            if !projection.sessions.isEmpty {
                sessions.removeAll { $0.kind == .deepseek && $0.observation.mode == .processOnly }
                sessions.append(
                    contentsOf: projection.sessions.map { observation in
                        var observation = observation
                        observation.processStartedAt = dshProcess.flatMap { processStarts[$0] }
                        return observation
                    })
            } else if let index = sessions.firstIndex(where: { $0.kind == .deepseek }) {
                sessions[index].observation = projection.health
            }
            let duration = Date().timeIntervalSince(startedAt)
            providerDurations[.deepseek, default: 0] += duration
            surfaceDurations[.deepSeekWeb] = duration
        }

        if ProcessInfo.processInfo.environment["LOOPFWD_DEBUG_SCAN"] == "1" {
            for session in sessions {
                let task = session.currentTaskSummary ?? "—"
                let line =
                    "[LoopFwd] card kind=\(session.kind.rawValue) "
                    + "status=\(session.status.label) title=\(session.displayTitle) task=\(task)\n"
                FileHandle.standardError.write(Data(line.utf8))
            }
        }
        return AgentScanResult(
            sessions: sessions,
            providerDurations: providerDurations,
            providerCacheHits: providerCacheHits,
            readerResults: readerResults,
            surfaceDurations: surfaceDurations
        )
    }

    private struct DesktopRead {
        let kind: AgentKind
        let surface: IntegrationSurfaceID
        let result: ProviderReadResult
        let duration: TimeInterval
    }

    struct ProcessRow {
        let pid: Int32
        let ppid: Int32
        let cpu: Double
        let tty: String?
        let elapsed: String
        let args: String
    }

    /// `ps` uses ASCII delimiters even when paths/prompts are Unicode. Split
    /// bytes first so unrelated long command arguments do not incur grapheme
    /// traversal or Foundation trimming on every automatic scan.
    static func processRows(_ output: String) -> [ProcessRow] {
        output.utf8.split(separator: 10).compactMap { line in
            let fields = line.split(separator: 32, maxSplits: 5, omittingEmptySubsequences: true)
            guard fields.count == 6,
                let pid = Int32(String(decoding: fields[0], as: UTF8.self)), pid > 0,
                let ppid = Int32(String(decoding: fields[1], as: UTF8.self)),
                let cpu = Double(String(decoding: fields[2], as: UTF8.self)), cpu.isFinite, cpu >= 0
            else { return nil }
            let tty = String(decoding: fields[3], as: UTF8.self)
            return ProcessRow(
                pid: pid, ppid: ppid, cpu: cpu, tty: tty == "??" ? nil : tty,
                elapsed: String(decoding: fields[4], as: UTF8.self),
                args: String(decoding: fields[5], as: UTF8.self))
        }
    }

    private static func providerID(from path: String) -> String {
        let stem = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        return stem.isEmpty ? path : stem
    }

    private static func modificationDate(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date
    }

    private static func returnTarget(terminal: String?, tty: String?, processID: Int32) -> ReturnTarget {
        guard let terminal else {
            return .unavailable(reason: "The owning terminal could not be resolved")
        }
        return .terminal(app: terminal, tty: tty, processID: processID)
    }

    /// Background / programmatic agents: no controlling terminal AND driven over
    /// a piped protocol (`stream-json`) or in print mode (`-p` / `--print`).
    /// These are SDK / orchestrator runs (e.g. FleetView sessions under
    /// ~/.slock/agents) — the island can neither jump to nor reply into them, and
    /// counting them inflates the session badge with sessions the user never
    /// opened in a terminal. Interactive agents always own a pty, so a live tty
    /// keeps them visible.
    private static func isHeadless(tty: String?, args: String) -> Bool {
        guard tty == nil else { return false }
        if args.contains("stream-json") || args.contains("--print") { return true }
        return args.split(separator: " ").contains("-p")
    }

    /// Model from the command line: `-m x`, `--model x`, or `--model=x`.
    static func argsModel(_ args: String) -> String? {
        let tokens = args.split(separator: " ").map(String.init)
        for (index, token) in tokens.enumerated() {
            if token == "-m" || token == "--model",
                index + 1 < tokens.count, !tokens[index + 1].hasPrefix("-")
            {
                return tokens[index + 1]
            }
            if token.hasPrefix("--model=") { return String(token.dropFirst("--model=".count)) }
        }
        return nil
    }

    /// Recognize an agent from its full command line. Matches the executable
    /// basename directly, or the script argument when run via an interpreter.
    /// Binaries inside .app bundles are GUI apps, not CLI agents — the Claude
    /// Desktop app's binary is literally named "Claude" and would ghost in.
    static func detect(args: String, tty: String? = nil) -> AgentKind? {
        // Most processes are unrelated. Inspect their executable without
        // splitting an arbitrarily large command/prompt into every argument.
        guard let first = args.split(separator: " ", maxSplits: 1).first else { return nil }
        var executable = String(first)
        // A space in the app bundle's name is not an argv separator. Without
        // this, ".../Codex Computer Use.app/..." is classified as Codex. Only
        // extend the same path component: a later /Some.app in an argument
        // must not change the identity of an actual CLI executable.
        if first.hasPrefix("/"), !first.contains(".app/"),
            let marker = args.range(of: ".app/Contents/"), marker.lowerBound >= first.endIndex,
            !args[first.endIndex..<marker.lowerBound].contains("/"),
            !args[first.endIndex..<marker.lowerBound].contains(" -"),
            let binary = args[marker.upperBound...].split(separator: " ", maxSplits: 1).first
        {
            executable = String(args[..<marker.upperBound]) + binary
        }
        let exe = basename(executable)

        // GUI helpers inside .app bundles are not CLI agents. The current
        // OpenAI distribution is the exception: its interactive Codex CLI is
        // bundled inside ChatGPT.app. A real TTY distinguishes that CLI from
        // ChatGPT's headless app-server and sandbox helper processes.
        if executable.contains(".app/"), !(exe.lowercased() == "codex" && tty != nil) {
            return nil
        }

        if let kind = AgentKind(matching: exe) { return kind }
        if let entry = ProcessNaming.nodeAgentEntry(args) { return entry.kind }

        let interpreters: Set<String> = ["node", "bun", "deno", "python", "python3", "uv", "npx"]
        if interpreters.contains(exe.lowercased()) {
            for token in args.split(separator: " ", maxSplits: 16).dropFirst() {
                if ["-e", "--eval", "-c", "-p", "--print", "eval", "--require", "-r", "--import"].contains(token)
                    || token.hasPrefix("--eval=") || token.hasPrefix("--require=") || token.hasPrefix("--import=")
                {
                    return nil
                }
                if token.hasPrefix("-") || token.contains(".app/") { continue }
                if ["uv", "deno", "bun"].contains(exe), ["tool", "run", "x"].contains(token) { continue }
                // Only the launched script/program, never a later user prompt.
                return AgentKind(matching: basename(String(token)))
            }
        }
        return nil
    }

    /// Walk up the parent chain to find the hosting terminal / editor app.
    private static func terminalApp(for pid: Int32, procs: [Int32: ProcInfo]) -> String? {
        var current = pid
        for _ in 0..<40 {
            guard let info = procs[current], info.ppid > 1 else { return nil }
            current = info.ppid
            guard let parent = procs[current] else { return nil }

            if let appName = ProcessNaming.terminalHostName(fromCommand: parent.command) {
                return appName
            }
            let base = ProcessNaming.executableBasename(parent.command)
            if ["tmux", "screen", "zellij"].contains(base) { return base }
        }
        return nil
    }

    private static func cachedTerminalApp(for pid: Int32, procs: [Int32: ProcInfo]) -> String? {
        if let cached = processMetadata[pid], cached.terminalRead { return cached.terminal }
        let value = terminalApp(for: pid, procs: procs)
        processMetadata[pid]?.terminal = value
        processMetadata[pid]?.terminalRead = true
        return value
    }

    private static func basename(_ path: String) -> String {
        (path as NSString).lastPathComponent
    }

    /// Claude officially allows each process to move all ~/.claude state with
    /// CLAUDE_CONFIG_DIR. Read the target process environment directly rather
    /// than inheriting LoopFwd's environment or exposing it through `ps` text.
    private static func claudeConfigDir(for pid: Int32) -> String {
        guard let raw = cachedProcessEnvironmentValue(pid: pid, key: "CLAUDE_CONFIG_DIR"),
            !raw.isEmpty
        else { return ClaudeSessions.defaultConfigDir }
        let expanded = (raw as NSString).expandingTildeInPath
        return (expanded as NSString).standardizingPath
    }

    /// Reads one environment value from macOS KERN_PROCARGS2. Environment
    /// entries are NUL-delimited, so paths containing spaces remain intact.
    private static func processEnvironmentValue(pid: Int32, key: String) -> String? {
        processEnvironmentValues(pid: pid, keys: [key])?[key]
    }

    static func processEnvironmentValues(pid: Int32, keys: Set<String>) -> [String: String]? {
        var argMaxMib = [CTL_KERN, KERN_ARGMAX]
        var argMax: Int32 = 0
        var argMaxSize = MemoryLayout<Int32>.size
        guard sysctl(&argMaxMib, UInt32(argMaxMib.count), &argMax, &argMaxSize, nil, 0) == 0,
            argMax > 0
        else { return nil }

        var bytes = [UInt8](repeating: 0, count: Int(argMax))
        var dataSize = bytes.count
        var processMib = [CTL_KERN, KERN_PROCARGS2, pid]
        let status = bytes.withUnsafeMutableBytes { buffer in
            sysctl(&processMib, UInt32(processMib.count), buffer.baseAddress, &dataSize, nil, 0)
        }
        guard status == 0, dataSize > MemoryLayout<Int32>.size else { return nil }
        bytes.removeSubrange(dataSize..<bytes.count)

        return environmentValues(in: bytes, keys: keys)
    }

    /// KERN_PROCARGS2 pads the executable path, but each argv entry has exactly
    /// one terminator. Empty arguments must not consume the first env entry.
    static func environmentValues(in bytes: [UInt8], keys: Set<String>) -> [String: String]? {
        guard bytes.count > MemoryLayout<Int32>.size else { return nil }
        let argc = bytes.withUnsafeBytes { raw in
            raw.loadUnaligned(as: Int32.self)
        }
        guard argc >= 0, Int(argc) <= bytes.count - MemoryLayout<Int32>.size else { return nil }

        var index = MemoryLayout<Int32>.size
        func skipString() -> Bool {
            while index < bytes.count, bytes[index] != 0 { index += 1 }
            guard index < bytes.count else { return false }
            index += 1
            return true
        }

        guard skipString() else { return nil }  // executable path
        while index < bytes.count, bytes[index] == 0 { index += 1 }  // path padding only
        for _ in 0..<Int(argc) {
            guard skipString() else { return nil }
        }

        var result: [String: String] = [:]
        while index < bytes.count {
            let start = index
            while index < bytes.count, bytes[index] != 0 { index += 1 }
            guard index < bytes.count else { return nil }
            if start == index { break }
            let entry = String(decoding: bytes[start..<index], as: UTF8.self)
            if let separator = entry.firstIndex(of: "="), keys.contains(String(entry[..<separator])) {
                result[String(entry[..<separator])] = String(entry[entry.index(after: separator)...])
            }
            index += 1
        }
        return result
    }

    private static func cachedProcessEnvironmentValue(pid: Int32, key: String) -> String? {
        if let cached = processMetadata[pid], cached.environmentReads.contains(key) {
            return cached.environment[key]
        }
        let value = processEnvironmentValue(pid: pid, key: key)
        processMetadata[pid]?.environmentReads.insert(key)
        if let value { processMetadata[pid]?.environment[key] = value }
        return value
    }

    /// Current git branch of a directory — a couple of tiny file reads, no git
    /// binary. Handles worktrees (`.git` file pointing at the real gitdir).
    private static func gitBranch(cwd: String?) -> String? {
        guard let cwd, !cwd.isEmpty else { return nil }
        var gitPath = cwd + "/.git"
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: gitPath, isDirectory: &isDir) else { return nil }
        if !isDir.boolValue {
            guard let pointer = try? String(contentsOfFile: gitPath, encoding: .utf8),
                let dir = pointer.split(separator: ":", maxSplits: 1).last?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                !dir.isEmpty
            else { return nil }
            gitPath = dir
        }
        guard let head = try? String(contentsOfFile: gitPath + "/HEAD", encoding: .utf8) else { return nil }
        let trimmed = head.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("ref: refs/heads/") {
            return String(trimmed.dropFirst("ref: refs/heads/".count))
        }
        return String(trimmed.prefix(7))  // detached HEAD → short hash
    }

    /// One lsof call for all pids: `p<pid>` lines followed by `n<path>` lines.
    private static func cwdByPid(_ pids: [Int32]) -> [Int32: String] {
        guard !pids.isEmpty else { return [:] }
        let list = pids.map(String.init).joined(separator: ",")
        let output = run("/usr/sbin/lsof", ["-a", "-d", "cwd", "-p", list, "-Fn"])

        var result: [Int32: String] = [:]
        var currentPid: Int32?
        for line in output.split(separator: "\n") {
            if line.hasPrefix("p") {
                currentPid = Int32(line.dropFirst())
            } else if line.hasPrefix("n"), let pid = currentPid {
                result[pid] = String(line.dropFirst())
            }
        }
        return result
    }

    private static func cachedCwdByPid(_ pids: [Int32]) -> [Int32: String] {
        var result: [Int32: String] = [:]
        var missing: [Int32] = []
        for pid in pids {
            guard let cached = processMetadata[pid] else { continue }
            if cached.cwdRead {
                if let cwd = cached.cwd { result[pid] = cwd }
            } else {
                missing.append(pid)
            }
        }
        let discovered = cwdByPid(missing)
        for pid in missing {
            processMetadata[pid]?.cwd = discovered[pid]
            processMetadata[pid]?.cwdRead = true
            if let cwd = discovered[pid] { result[pid] = cwd }
        }
        return result
    }

    /// ps etime is [[dd-]hh:]mm:ss — condense to "3m", "1h 12m", "2d 4h".
    static func prettyElapsed(_ etime: String) -> String {
        var days = 0
        var rest = etime
        if let dash = rest.firstIndex(of: "-") {
            days = Int(rest[..<dash]) ?? 0
            rest = String(rest[rest.index(after: dash)...])
        }
        let comps = rest.split(separator: ":").compactMap { Int($0) }
        var hours = 0, minutes = 0
        if comps.count == 3 { hours = comps[0]; minutes = comps[1] } else if comps.count == 2 { minutes = comps[0] }

        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes)m" }
        return "<1m"
    }

    private static func run(_ path: String, _ arguments: [String]) -> String {
        let result = BoundedProcess.run(path, arguments, maximumBytes: 4 * 1024 * 1024)
        return result.succeeded ? result.output : ""
    }
}

/// Round-robin admission between process reads, not cancellation of synchronous
/// file I/O. Each provider gets its own budget; unvisited processes go first on
/// the next scan. No cached projection is relabelled as freshly observed.
struct ProviderProcessReadSchedule {
    private var ordered: [Int32] = []
    private var pending: Set<Int32> = []
    private var spent: [AgentKind: TimeInterval] = [:]

    mutating func begin(_ live: [Int32]) -> [Int32] {
        let liveIDs = Set(live)
        let retained = ordered.filter { liveIDs.contains($0) && pending.contains($0) }
        let retainedIDs = Set(retained)
        ordered = retained + live.filter { !retainedIDs.contains($0) }
        pending = liveIDs
        spent = [:]
        return ordered
    }

    mutating func admit(pid: Int32, kind: AgentKind, budget: TimeInterval) -> Bool {
        guard pending.contains(pid), (spent[kind] ?? 0) < budget else { return false }
        pending.remove(pid)
        return true
    }

    mutating func record(kind: AgentKind, duration: TimeInterval) {
        spent[kind, default: 0] += max(0, duration)
    }

    static func surface(for kind: AgentKind) -> IntegrationSurfaceID {
        switch kind {
        case .claude: return .claudeCLI
        case .codex: return .codexCLI
        case .opencode: return .openCodeTUI
        case .copilot: return .copilotCLI
        case .kimi: return .kimiCLI
        case .grok: return .grokCLI
        case .mistral: return .mistralCLI
        case .workbuddy: return .workBuddyDesktop
        case .gemini: return .geminiCLI
        case .qwen: return .qwenCLI
        case .deepseek: return .process
        default: return .experimentalLocal
        }
    }
}

/// A PID is only the cache coordinate, never its identity. Recycled PIDs must
/// lose metadata as soon as their executable command changes.
enum ProcessCachePolicy {
    static func retained(cached: [Int32: String], live: [Int32: String]) -> [Int32: String] {
        cached.filter { pid, command in live[pid] == command }
    }
}
