import Darwin
import XCTest
@testable import LoopFwd

final class ProviderReaderTests: XCTestCase {
    func testOptInLiveKimiPreauthenticationProcess() async throws {
        guard let pid = ProcessInfo.processInfo.environment["LOOPFWD_LIVE_KIMI_PID"].flatMap(Int32.init) else {
            throw XCTSkip("Requires a selected existing Kimi CLI before any authenticated model task")
        }
        let scan = await AgentScanner.findAgents()
        XCTAssertTrue(scan.processScanSucceeded)
        let own = scan.sessions.filter { $0.processID == pid }
        XCTAssertEqual(own.count, 1)
        let session = try XCTUnwrap(own.first)
        XCTAssertEqual(session.kind, .kimi)
        XCTAssertEqual(session.surfaceID, .kimiCLI)
        XCTAssertEqual(session.observation.mode, .processOnly)
        XCTAssertNil(session.attentionKind)
        XCTAssertNil(session.lastPrompt)
        XCTAssertFalse([AgentStatus.completed, .needsAttention, .failed].contains(session.status))
        if case .exact = ReturnResolver.resolve(session).capability {
            XCTFail("Process identity is not an exact session return")
        }
    }

    func testOptInLiveMistralWelcomeScreen() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let pid = env["LOOPFWD_LIVE_MISTRAL_PID"].flatMap(Int32.init),
            let root = env["LOOPFWD_LIVE_MISTRAL_HOME"]
        else { throw XCTSkip("Requires a selected isolated Mistral CLI before authentication") }
        // Real Vibe 2.25.0 setproctitle removes the macOS environment snapshot.
        // If the OS can return it, it must still match the selected instance.
        if let observed = AgentScanner.processEnvironmentValues(pid: pid, keys: ["VIBE_HOME"])?["VIBE_HOME"] {
            XCTAssertEqual(observed, root)
        }
        let before = await AgentScanner.findAgents()
        XCTAssertTrue(before.processScanSucceeded)
        let own = before.sessions.filter { $0.processID == pid }
        XCTAssertEqual(own.count, 1)
        let session = try XCTUnwrap(own.first)
        XCTAssertEqual(session.kind, .mistral)
        XCTAssertEqual(session.surfaceID, .mistralCLI)
        XCTAssertEqual(session.observation.mode, .processOnly)
        XCTAssertNil(session.lastPrompt)
        XCTAssertNil(session.attentionKind)
        XCTAssertFalse([AgentStatus.completed, .needsAttention, .failed].contains(session.status))
        if case .exact = ReturnResolver.resolve(session).capability {
            XCTFail("A tool PTY is not a verified user Terminal window")
        }
        if env["LOOPFWD_LIVE_MISTRAL_WAIT_FOR_EXIT"] == "1" {
            try FileHandle.standardOutput.write(contentsOf: Data("MISTRAL_WELCOME_VALIDATED\n".utf8))
            let deadline = ProcessInfo.processInfo.systemUptime + 90
            func alive() -> Bool { Darwin.kill(pid, 0) == 0 || errno != ESRCH }
            while alive(), ProcessInfo.processInfo.systemUptime < deadline {
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            XCTAssertFalse(alive(), "The selected welcome screen has not exited")
            let after = await AgentScanner.findAgents()
            XCTAssertTrue(after.processScanSucceeded)
            XCTAssertFalse(after.sessions.contains { $0.processID == pid })
        }
    }

    func testOptInLiveNodeClientsExitReclaimsWarmCache() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let raw = env["LOOPFWD_LIVE_NODE_EXIT_PIDS"] else {
            throw XCTSkip("Requires selected isolated Node clients; the operator exits them without authenticating")
        }
        let pids = Set(raw.split(separator: ",").compactMap { Int32($0) })
        XCTAssertFalse(pids.isEmpty)
        let before = await AgentScanner.findAgents()
        XCTAssertTrue(before.processScanSucceeded)
        for kind in [AgentKind.qwen, .gemini] {
            XCTAssertEqual(before.sessions.filter { $0.kind == kind && pids.contains($0.processID ?? -1) }.count, 1)
        }
        try FileHandle.standardOutput.write(contentsOf: Data("NODE_CLIENTS_VALIDATED\n".utf8))
        // This is an operator handoff budget, not the scanner's cleanup latency.
        let deadline = ProcessInfo.processInfo.systemUptime + 90
        func stillRunning() -> Bool { pids.contains { Darwin.kill($0, 0) == 0 || errno != ESRCH } }
        while stillRunning(), ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertFalse(stillRunning(), "Selected test clients have not exited")
        let after = await AgentScanner.findAgents()
        XCTAssertTrue(after.processScanSucceeded)
        XCTAssertFalse(after.sessions.contains { pids.contains($0.processID ?? -1) })
    }

    func testOptInLiveQwenUnauthenticatedSession() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let home = env["LOOPFWD_LIVE_QWEN_HOME"], let cwd = env["LOOPFWD_LIVE_QWEN_CWD"],
            let id = env["LOOPFWD_LIVE_QWEN_SESSION"],
            let pid = env["LOOPFWD_LIVE_QWEN_PID"].flatMap(Int32.init)
        else { throw XCTSkip("Requires a selected isolated Qwen CLI at its provider setup screen") }
        let birth = BoundedProcess.run("/bin/ps", ["-p", String(pid), "-o", "lstart="]).output
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(
            QwenSessions.binding(processID: pid, cwd: cwd, processStartedAt: birth, qwenHome: home)?.sessionID, id)
        let scan = await AgentScanner.findAgents()
        let launchers = Set((env["LOOPFWD_LIVE_QWEN_LAUNCHERS"] ?? "").split(separator: ",").compactMap { Int32($0) })
        XCTAssertTrue(scan.processScanSucceeded)
        let own = scan.sessions.filter { $0.processID == pid || launchers.contains($0.processID ?? -1) }
        XCTAssertEqual(own.count, 1)
        let session = try XCTUnwrap(own.first { $0.processID == pid })
        XCTAssertEqual(session.kind, .qwen)
        XCTAssertEqual(session.id, "qwen:\(id)")
        XCTAssertEqual(session.surfaceID, .qwenCLI)
        XCTAssertEqual(session.observation.mode, .processOnly)
        XCTAssertNil(session.attentionKind)
        XCTAssertFalse([AgentStatus.completed, .needsAttention, .failed].contains(session.status))
        if case .exact = ReturnResolver.resolve(session).capability {
            XCTFail("A tool-owned PTY is not a verified user terminal")
        }
    }

    func testOptInLiveGeminiUnauthenticatedStartup() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let pid = env["LOOPFWD_LIVE_GEMINI_PID"].flatMap(Int32.init),
            let launcher = env["LOOPFWD_LIVE_GEMINI_LAUNCHER"].flatMap(Int32.init)
        else { throw XCTSkip("Requires a selected isolated Gemini CLI at its setup screen") }
        let scan = await AgentScanner.findAgents()
        XCTAssertTrue(scan.processScanSucceeded)
        let own = scan.sessions.filter { $0.processID == pid || $0.processID == launcher }
        XCTAssertEqual(own.count, 1)
        let session = try XCTUnwrap(own.first { $0.processID == pid })
        XCTAssertEqual(session.kind, .gemini)
        XCTAssertEqual(session.surfaceID, .geminiCLI)
        XCTAssertEqual(session.observation.mode, .processOnly)
        XCTAssertNil(session.lastPrompt)
        XCTAssertNil(session.attentionKind)
        XCTAssertFalse([AgentStatus.completed, .needsAttention, .failed].contains(session.status))
        if case .exact = ReturnResolver.resolve(session).capability {
            XCTFail("A tool PTY is not a user Terminal window")
        }
    }

    func testOptInLiveClaudeIdleSession() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let root = environment["LOOPFWD_LIVE_CLAUDE_CONFIG"], root.hasPrefix("/"),
            let rawPID = environment["LOOPFWD_LIVE_CLAUDE_PID"], let pid = Int32(rawPID)
        else { throw XCTSkip("Requires an explicitly selected idle Claude CLI and its isolated config directory") }
        var pids = [pid]
        if let second = environment["LOOPFWD_LIVE_CLAUDE_SECOND_PID"] { pids.append(try XCTUnwrap(Int32(second))) }
        XCTAssertEqual(Set(pids).count, pids.count)
        let births = try XCTUnwrap(ClaudeSessions.processStartsUTC(pids: pids))
        let registry = ClaudeSessions.readRegistry(configDirs: [root], processStartsUTC: births)
        let scan = await AgentScanner.findAgents()
        XCTAssertTrue(scan.processScanSucceeded)
        let sessions = scan.sessions.filter { $0.kind == .claude && pids.contains($0.processID ?? -1) }
        XCTAssertEqual(sessions.count, pids.count)
        XCTAssertEqual(Set(sessions.map(\.id)).count, pids.count)
        for pid in pids {
            XCTAssertNotNil(births[pid])
            let meta = try XCTUnwrap(registry.sessions[pid])
            XCTAssertEqual(meta.status, "idle")
            let session = try XCTUnwrap(sessions.first { $0.processID == pid })
            XCTAssertEqual(session.id, "claude:\(meta.sessionId)")
            XCTAssertEqual(session.surfaceID, .claudeCLI)
            XCTAssertEqual(session.status, .idle)
            XCTAssertEqual(session.observation.mode, .rich)
            XCTAssertNotNil(session.processStartedAt)
            XCTAssertNil(session.lastPrompt)
            XCTAssertNil(session.attentionKind)
            XCTAssertFalse(SessionPresentationPolicy.visible([session]).contains { $0.id == session.id })
            if environment["LOOPFWD_LIVE_CLAUDE_NO_TERMINAL_HOST"] == "1",
                case .exact = ReturnResolver.resolve(session).capability
            {
                XCTFail("A tool-owned PTY is not a verified user Terminal window")
            }
        }
        if environment["LOOPFWD_LIVE_CLAUDE_WAIT_FOR_EXIT"] == "1" {
            // The operator exits only its own test CLIs. This test never sends
            // a prompt, kills a process or mutates provider configuration.
            try FileHandle.standardOutput.write(contentsOf: Data("CLAUDE_IDLE_VALIDATED\n".utf8))
            let deadline = ProcessInfo.processInfo.systemUptime + 45
            func stillRunning() -> Bool {
                pids.contains { Darwin.kill($0, 0) == 0 || errno != ESRCH }
            }
            while stillRunning(), ProcessInfo.processInfo.systemUptime < deadline {
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            XCTAssertFalse(stillRunning(), "The selected test clients have not exited")
            let afterExit = await AgentScanner.findAgents()
            XCTAssertTrue(afterExit.processScanSucceeded)
            XCTAssertFalse(afterExit.sessions.contains { pids.contains($0.processID ?? -1) })
        }
    }

    func testClaudeVerifiedRegistryRejectsReusedPIDAndForeignPIDDomain() throws {
        let marker = try temporaryFile("claude-registry.json")
        let root = marker.deletingLastPathComponent()
        let directory = root.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("123.json")
        let birth = "Sun Sep  6 16:57:08 2026"
        var record: [String: Any] = [
            "pid": 123, "sessionId": "real-session", "cwd": "/tmp/example", "status": "busy",
            "procStart": birth, "pidDomain": "darwin",
        ]
        func read(_ starts: [Int32: String]) throws -> ClaudeSessions.RegistryRead {
            try JSONSerialization.data(withJSONObject: record).write(to: file)
            return ClaudeSessions.readRegistry(configDirs: [root.path], processStartsUTC: starts)
        }
        let good = try read([123: "Sun Sep 6 16:57:08 2026"])
        XCTAssertEqual(good.outcome, .success)
        XCTAssertEqual(good.sessions[123]?.sessionId, "real-session")
        let recycled = try read([123: "Sun Sep 6 17:57:08 2026"])
        XCTAssertEqual(recycled.outcome, .failed)
        XCTAssertTrue(recycled.sessions.isEmpty)
        XCTAssertEqual(recycled.reason, "Claude session registry process identity could not be verified")
        XCTAssertEqual(try read([:]).outcome, .empty)
        record["pidDomain"] = "linux"
        XCTAssertTrue(try read([123: birth]).sessions.isEmpty)
        record["pidDomain"] = nil
        record["procStart"] = nil
        XCTAssertTrue(try read([123: birth]).sessions.isEmpty)
    }

    func testClaudeRegistryIgnoresCopiesInOtherConfigRoots() throws {
        let marker = try temporaryFile("claude-roots.json")
        let root = marker.deletingLastPathComponent()
        let a = root.appendingPathComponent("a")
        let b = root.appendingPathComponent("b")
        for dir in [a, b] {
            try FileManager.default.createDirectory(
                at: dir.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        }
        let birth = "Sun Sep 6 16:57:08 2026"
        let record: [String: Any] = [
            "pid": 123, "sessionId": "correct", "cwd": "/tmp/example", "procStart": birth, "status": "idle",
        ]
        try JSONSerialization.data(withJSONObject: record).write(to: a.appendingPathComponent("sessions/123.json"))
        for copy in [
            "{broken", "{\"pid\":123,\"sessionId\":\"wrong\",\"cwd\":\"/tmp\",\"procStart\":\"old\"}",
            String(decoding: try JSONSerialization.data(withJSONObject: record), as: UTF8.self),
        ] {
            try Data(copy.utf8).write(to: b.appendingPathComponent("sessions/123.json"))
            let result = ClaudeSessions.readRegistry(
                configDirs: [a.path, b.path], processStartsUTC: [123: birth], configDirsByPID: [123: a.path])
            XCTAssertEqual(result.outcome, .success)
            XCTAssertEqual(result.sessions.count, 1)
            XCTAssertEqual(result.sessions[123]?.configDir, a.path)
        }
    }

    func testClaudeProcessQueryDistinguishesNormalExitFromFailure() {
        let absent = Int32.max
        XCTAssertTrue(Darwin.kill(absent, 0) != 0 && errno == ESRCH)
        let noProcesses = BoundedProcess.Result(output: "", status: 1, timedOut: false, exceededOutputLimit: false)
        XCTAssertEqual(ClaudeSessions.processStartsUTC(query: noProcesses, selectedPIDs: [absent]), [:])
        XCTAssertNil(ClaudeSessions.processStartsUTC(query: noProcesses, selectedPIDs: [getpid()]))
        XCTAssertNil(ClaudeSessions.processStartsUTC(query: noProcesses, selectedPIDs: nil))
        XCTAssertNil(
            ClaudeSessions.processStartsUTC(
                query: .init(output: "", status: 1, timedOut: true, exceededOutputLimit: false), selectedPIDs: [absent])
        )
        XCTAssertNil(
            ClaudeSessions.processStartsUTC(
                query: .init(output: "", status: nil, timedOut: false, exceededOutputLimit: false),
                selectedPIDs: [absent]))
    }

    @MainActor
    func testClaudeQuestionCacheCannotUpgradeUnverifiedOrRecycledSessions() throws {
        var original = AgentSession(
            id: "claude:fixture", processID: 123, kind: .claude, cpu: 0, elapsed: "1m",
            status: .idle, terminalApp: "Terminal", tty: "ttys005", bypassPermissions: false,
            observation: .rich("Claude session registry", updatedAt: Date().addingTimeInterval(-1)))
        original.processStartedAt = "Sun Sep 6 16:57:08 2026"
        let identity = try XCTUnwrap(ApprovalCenter.RequestIdentity(agent: original, sessionID: "fixture"))
        let entry = ApprovalCenter.QuestionEntry(
            identity: identity, requestID: "question-1",
            question: .init(prompt: "Fixture choice?", options: ["A", "B"], multiSelect: false),
            at: Date())
        var center = ApprovalCenter()
        center.receiveQuestion(entry)
        XCTAssertEqual(center.projectLiveRequests([original]).first?.status, .needsAttention)
        for mutation in 0..<4 {
            center = ApprovalCenter()
            var changed = original
            switch mutation {
            case 0: changed.id = "claude:replacement"
            case 1: changed.processStartedAt = "Sun Sep 6 17:57:08 2026"
            case 2: changed.observation = .processOnly("Process table")
            default: changed.processID = 124
            }
            center.receiveQuestion(entry)
            XCTAssertNil(center.question(for: changed))
            XCTAssertEqual(center.projectLiveRequests([changed]).first?.status, .idle)
            XCTAssertTrue(center.questions.isEmpty)
        }
        center = ApprovalCenter()
        center.receiveQuestion(entry)
        var resumed = original
        resumed.status = .working
        resumed.observation.updatedAt = entry.at.addingTimeInterval(1)
        XCTAssertEqual(center.projectLiveRequests([resumed]).first?.status, .working)
        XCTAssertTrue(center.questions.isEmpty)

        center = ApprovalCenter()
        center.closeQuestion(identity: identity, requestID: entry.requestID)
        center.receiveQuestion(entry)
        XCTAssertTrue(center.questions.isEmpty, "Post before Pre must not revive the answered request")
        let next = ApprovalCenter.QuestionEntry(
            identity: identity, requestID: "question-2", question: entry.question, at: Date())
        center.receiveQuestion(next)
        center.closeQuestion(identity: identity, requestID: entry.requestID)
        XCTAssertEqual(center.question(for: original)?.requestID, next.requestID)
        for index in 0..<129 { center.closeQuestion(identity: identity, requestID: "closed-\(index)") }
        center.receiveQuestion(next)
        XCTAssertTrue(
            center.questions.isEmpty, "Capacity exhaustion must not discard a close barrier and revive a request")

        let output = "Sun Sep  6 16:57:08 2026 ttys005 /fixture/claude\n"
        func query(_ output: String) -> BoundedProcess.Result {
            .init(output: output, status: 0, timedOut: false, exceededOutputLimit: false)
        }
        XCTAssertTrue(TerminalBridge.controlProcessMatches(original, query: query(output)))
        XCTAssertFalse(
            TerminalBridge.controlProcessMatches(
                original, query: query(output.replacingOccurrences(of: "16:57", with: "17:57"))))
        XCTAssertFalse(
            TerminalBridge.controlProcessMatches(
                original, query: query(output.replacingOccurrences(of: "ttys005", with: "ttys006"))))
        XCTAssertFalse(
            TerminalBridge.controlProcessMatches(
                original, query: query(output.replacingOccurrences(of: "/fixture/claude", with: "/bin/zsh"))))
        XCTAssertFalse(TerminalBridge.controlProcessMatches(original, query: query("")))
    }

    func testClaudeHookCapturesSourceBirthBeforeSpooling() throws {
        let script = try temporaryFile("notify.sh")
        let root = script.deletingLastPathComponent()
        let spool = root.appendingPathComponent("spool with ' quote")
        let payload = root.appendingPathComponent("payload.json")
        let event: [String: Any] = [
            "session_id": "fixture", "hook_event_name": "PreToolUse", "tool_name": "AskUserQuestion",
            "tool_use_id": "question-1",
            "tool_input": ["questions": [["question": "Fixture choice?", "options": [["label": "A"]]]]],
        ]
        try JSONSerialization.data(withJSONObject: event).write(to: payload)
        try Data(ApprovalCenter.hookScript(spoolDirectory: spool.path).utf8).write(to: script)
        let run = BoundedProcess.run(
            "/bin/bash", ["-c", "exec /bin/bash \"$1\" < \"$2\"", "loopfwd-hook-test", script.path, payload.path],
            timeout: 3)
        XCTAssertTrue(run.succeeded)
        XCTAssertEqual(run.output, "")
        let files = try FileManager.default.contentsOfDirectory(at: spool, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 1)
        let file = try XCTUnwrap(files.first)
        XCTAssertFalse(file.lastPathComponent.hasPrefix("."))
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        XCTAssertEqual((envelope["event"] as? [String: Any])?["tool_use_id"] as? String, "question-1")
        let birth = try XCTUnwrap(ClaudeSessions.processStartsUTC(pids: [getpid()])?[getpid()])
        var source = ClaudeSessions.Meta(
            pid: getpid(), sessionId: "fixture", cwd: root.path, name: nil, status: "idle", statusUpdatedAt: nil,
            configDir: root.path, processStartUTC: birth)
        XCTAssertTrue(ApprovalCenter.hookSourceMatches(envelope, meta: source))
        source.processStartUTC = "Sun Sep 6 00:00:00 2000"
        XCTAssertFalse(
            ApprovalCenter.hookSourceMatches(envelope, meta: source),
            "Resuming the same session cannot rebind an old event")
        XCTAssertFalse(ApprovalCenter.hookSourceMatches(event, meta: source), "Legacy events have no source identity")
        var invalidVersion = envelope
        invalidVersion["loopfwdHookVersion"] = true
        XCTAssertFalse(ApprovalCenter.hookSourceMatches(invalidVersion, meta: source))
    }

    /// Explicitly mutating smoke: never enabled by ordinary verify/CI. This
    /// exercises the production backup + persistent archive + official add
    /// transaction on a caller-selected, idle Harness; no model calls occur.
    func testOptInInstallDeepSeekObserverOnExistingIdleHarness() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["LOOPFWD_DSH_INSTALL_ALLOW"] == "replace-observer-only",
            let root = environment["DSH_HOME"], root.hasPrefix("/"),
            let executable = environment["LOOPFWD_DSH_INSTALL_CLI"], executable.hasPrefix("/"),
            let archive = environment["LOOPFWD_DSH_INSTALL_ARCHIVE"], archive.hasPrefix("/"),
            let source = environment["LOOPFWD_DSH_INSTALL_SOURCE"], source.hasPrefix("/")
        else { throw XCTSkip("Requires explicit authorization to replace the observer on an existing idle Harness") }
        let before = DeepSeekHarnessSessions.read(path: root + "/integrations/loopfwd/web.json")
        guard before.health.mode == .rich, before.sessions.allSatisfy({ $0.status == .idle }) else {
            return XCTFail("Refusing observer replacement without a fresh, explicitly idle Harness snapshot")
        }
        guard DeepSeekHarnessIntegration.dshRootOverride == nil else {
            return XCTFail("Another test has already selected an integration root")
        }
        // DSH_HOME is shared with the official command, so installer backup and
        // command target cannot accidentally select different profiles.
        try DeepSeekHarnessIntegration.installObserver(
            executable: executable, archivePath: archive, packageName: "@loopfwd/dsh-observer",
            command: { executable, arguments in
                let result = BoundedProcess.run(executable, arguments, timeout: 45, maximumBytes: 256 * 1024)
                return (result.succeeded, result.output.trimmingCharacters(in: .whitespacesAndNewlines))
            })
        let installed = root + "/profiles/web/node_modules/@loopfwd/dsh-observer/lib/index.js"
        XCTAssertEqual(
            try Data(contentsOf: URL(fileURLWithPath: installed)), try Data(contentsOf: URL(fileURLWithPath: source)))
    }

    func testOptInLiveDeepSeekSnapshot() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let root = environment["LOOPFWD_LIVE_DSH_HOME"], root.hasPrefix("/"),
            let rawCount = environment["LOOPFWD_LIVE_DSH_COUNT"], let count = Int(rawCount)
        else { throw XCTSkip("Requires an explicitly selected live Harness with the installed observer") }
        let path = root + "/integrations/loopfwd/web.json"
        let projection = DeepSeekHarnessSessions.read(path: path)
        XCTAssertEqual(projection.health.mode, .rich, projection.health.reason ?? "No diagnostic reason")
        XCTAssertEqual(projection.sessions.count, count)
        XCTAssertEqual(Set(projection.sessions.map(\.id)).count, count)
        XCTAssertTrue(projection.sessions.allSatisfy { $0.id.hasPrefix("dsh:") && $0.surfaceID == .deepSeekWeb })
        if environment["LOOPFWD_LIVE_DSH_IDLE"] == "1" {
            XCTAssertTrue(projection.sessions.allSatisfy { $0.status == .idle })
        }
        if let rawPID = environment["LOOPFWD_LIVE_DSH_PID"], let pid = Int32(rawPID) {
            let scan = await AgentScanner.findAgents()
            XCTAssertTrue(scan.processScanSucceeded)
            let sessions = scan.sessions.filter { $0.surfaceID == .deepSeekWeb }
            XCTAssertEqual(sessions.count, count)
            XCTAssertTrue(Set(sessions.map(\.id)) == Set(projection.sessions.map(\.id)))
            for session in sessions {
                XCTAssertEqual(session.processID, pid)
                XCTAssertNotNil(session.processStartedAt)
                XCTAssertEqual(session.observation.mode, .rich)
                guard case .providerOnly = ReturnResolver.resolve(session).capability else {
                    return XCTFail("Live Harness must expose an application-level return, not claim an exact task link")
                }
            }
        }
    }

    func testProviderWebTargetsStayOnLoopback() {
        let openCode = OpenCodeSessions.loopbackURL(
            path: "/session/status", port: 4096,
            query: [URLQueryItem(name: "directory", value: "/tmp/project")]
        )
        XCTAssertEqual(openCode?.scheme, "http")
        XCTAssertEqual(openCode?.host, "127.0.0.1")
        XCTAssertNil(OpenCodeSessions.loopbackURL(path: "session", port: 4096))
        XCTAssertNil(OpenCodeSessions.loopbackURL(path: "/session", port: 70_000))

        XCTAssertEqual(
            DeepSeekHarnessSessions.safeLoopbackURL("http://localhost:3080")?.host,
            "localhost"
        )
        XCTAssertNil(DeepSeekHarnessSessions.safeLoopbackURL("https://example.com/session"))
        XCTAssertNil(DeepSeekHarnessSessions.safeLoopbackURL("file:///tmp/session"))
    }

    func testClaudeFixtureReadsCurrentTitlePromptAndModel() throws {
        let info = ClaudeSessions.tailInfo(path: try fixture("claude-session", "jsonl").path)
        XCTAssertEqual(info.title, "LoopFwd monitor prototype")
        XCTAssertEqual(info.lastPrompt, "/Goal Complete the 1.0 prototype")
        XCTAssertEqual(info.lastMessage, "Implementing the monitor core.")
        XCTAssertEqual(info.model, "claude-sonnet-4-5")
    }

    func testCodexFixtureReadsWorkingTurnAndLatestTask() throws {
        let info = CodexSessions.tailInfo(path: try fixture("codex-rollout", "jsonl").path)
        XCTAssertEqual(info.phase, .working)
        XCTAssertEqual(info.lastPrompt, "/Goal Ship the internal beta")
        XCTAssertEqual(info.lastMessage, "Building the release candidate.")
        XCTAssertEqual(info.model, "gpt-5.6-codex")
    }

    func testCodexBrowserContextPreservesRealRequestAcrossRecordShapes() throws {
        let request = "PLEASE IMPLEMENT THIS PLAN:\n# Fix notification delivery"
        let wrapped = """
            <in-app-browser-context source="ambient-ui-state">
            PLEASE IMPLEMENT THIS PLAN:
            # This is browser context, not a user goal
            ## My request:
            Not the real request
            </in-app-browser-context>

            ## My request:
            \(request)
            """
        let records: [[String: Any]] = [
            ["type": "event_msg", "payload": ["type": "user_message", "message": wrapped]],
            [
                "type": "response_item",
                "payload": ["type": "message", "role": "user", "content": [["type": "input_text", "text": wrapped]]],
            ],
            ["type": "message", "role": "user", "content": [["type": "input_text", "text": wrapped]]],
        ]
        for (index, record) in records.enumerated() {
            let url = try temporaryFile("codex-browser-\(index).jsonl")
            var data = try JSONSerialization.data(withJSONObject: record)
            data.append(10)
            try data.write(to: url)
            let info = CodexSessions.tailInfo(path: url.path)
            XCTAssertEqual(info.lastPrompt, request)
            XCTAssertEqual(info.lastPrompt.flatMap(TaskPresentationResolver.substantive), "Fix notification delivery")
            if index > 0 {
                XCTAssertEqual(CodexSessions.recentMessages(path: url.path).first?.text, request)
            }
        }
    }

    func testCodexBrowserContextRecoveryIgnoresConfirmationsAndInjectedRequests() throws {
        let url = try temporaryFile("codex-browser-history.jsonl")
        let request = "继续修复通知问题"
        func event(_ text: String) throws -> Data {
            var data = try JSONSerialization.data(withJSONObject: [
                "type": "event_msg", "payload": ["type": "user_message", "message": text],
            ])
            data.append(10)
            return data
        }
        var data = try event(
            "<in-app-browser-context>browser</in-app-browser-context>\n\n## My request:\n\(request)")
        data.append(
            try JSONSerialization.data(withJSONObject: [
                "type": "response_item",
                "payload": [
                    "type": "function_call_output", "role": "user",
                    "content": [["type": "input_text", "text": "Not a user message"]],
                ],
            ]))
        data.append(10)
        let output: [String: Any] = [
            "type": "response_item",
            "payload": ["type": "function_call_output", "output": String(repeating: "x", count: 300_000)],
        ]
        data.append(try JSONSerialization.data(withJSONObject: output))
        data.append(10)
        for text in [
            "<in-app-browser-context>browser</in-app-browser-context>\n\n## My request:\n继续",
            "<in-app-browser-context>\n## My request:\nNot outside the context",
            "<in-app-browser-context>\n## My request:\nContext only</in-app-browser-context>",
            "<in-app-browser-context-fake>browser</in-app-browser-context>\n## My request:\nWrong tag",
            "<in-app-browser-context>browser</in-app-browser-context>\n## My request: not a heading\nFake task",
            "<in-app-browser-context>browser</in-app-browser-context>\n## My request:\n",
            "<in-app-browser-context>browser</in-app-browser-context>\n## My request:\n# AGENTS.md injected rules",
            "<in-app-browser-context>browser</in-app-browser-context>\n## My request:\n<unknown>Injected</unknown>",
            "<in-app-browser-context><in-app-browser-context>inner</in-app-browser-context>\n## My request:\nInjected title\n</in-app-browser-context>\n## My request:\nReal task",
            "<in-app-browser-context>browser</in-app-browser-context>\n## My request:\nAmbiguous task\n</in-app-browser-context>",
            "<environment_context>\n## My request:\nInjected task</environment_context>",
            "# AGENTS.md instructions\n## My request:\nRepository instructions",
            "<send_user_message_question_reply>\n## My request:\nTool reply</send_user_message_question_reply>",
        ] {
            data.append(try event(text))
        }
        try data.write(to: url)
        let info = CodexSessions.tailInfo(path: url.path)
        XCTAssertTrue(info.readSucceeded)
        XCTAssertFalse(info.recoveringTaskContext)
        XCTAssertEqual(info.lastPrompt, request)
        XCTAssertEqual(CodexSessions.tailInfo(path: url.path).lastPrompt, request)
    }

    func testCodexBrowserPartsPreserveConfirmationDetailsWithoutChangingGoal() throws {
        let url = try temporaryFile("codex-browser-parts.jsonl")
        let context = "<in-app-browser-context source=\"ambient-ui-state\">browser</in-app-browser-context>"
        var data = Data()
        for (role, texts) in [
            ("user", [context, "## My request:\nFix task summaries"]),
            ("user", [context, "## My request:\n允许"]),
            ("assistant", ["## My request:\nThis is still an assistant response"]),
        ] {
            data.append(
                try JSONSerialization.data(withJSONObject: [
                    "type": "response_item",
                    "payload": [
                        "type": "message", "role": role,
                        "content": texts.map { ["type": role == "user" ? "input_text" : "output_text", "text": $0] },
                    ],
                ]))
            data.append(10)
        }
        try data.write(to: url)
        XCTAssertEqual(CodexSessions.tailInfo(path: url.path).lastPrompt, "Fix task summaries")
        let messages = CodexSessions.recentMessages(path: url.path)
        XCTAssertEqual(
            messages.map(\.text), ["Fix task summaries", "允许", "## My request:\nThis is still an assistant response"])
        XCTAssertEqual(messages.map(\.isUser), [true, true, false])
    }

    func testTaskSummaryDoesNotPromoteQuotedRequestMarkers() {
        let request = "Fix notification delivery"
        for empty in ["## My request:\n\n", "# Files mentioned by the user:\nexample.swift\n\n## My request:"] {
            XCTAssertNil(TaskPresentationResolver.substantive(empty))
        }
        for suffix in ["PLEASE IMPLEMENT THIS PLAN:\n# A quoted example", "## My request:\nA quoted example"] {
            XCTAssertEqual(TaskPresentationResolver.substantive(request + "\n\n" + suffix), request)
        }
        XCTAssertEqual(
            TaskPresentationResolver.substantive(
                "# Files mentioned by the user:\n\nexample.swift\n\n## My request:\nPLEASE IMPLEMENT THIS PLAN:\n# Fix notification delivery"
            ),
            request)
    }

    func testCodexOutputWithoutVisibleStartRemainsWorking() throws {
        let url = try temporaryFile("codex-displaced-start.jsonl")
        let lines = [
            #"{"type":"response_item","payload":{"type":"reasoning","id":"reasoning-1"}}"#,
            #"{"type":"response_item","payload":{"type":"custom_tool_call","name":"exec","call_id":"call-1","input":""}}"#,
            #"{"type":"response_item","payload":{"type":"custom_tool_call_output","call_id":"call-1","output":"ok"}}"#,
        ]
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)

        XCTAssertEqual(CodexSessions.tailInfo(path: url.path).phase, .working)
    }

    func testCodexCompletedRequiresExplicitCompletionBoundary() throws {
        let url = try temporaryFile("codex-complete.jsonl")
        let line = #"{"type":"event_msg","payload":{"type":"task_complete"}}"#
        try Data((line + "\n").utf8).write(to: url)

        XCTAssertEqual(CodexSessions.tailInfo(path: url.path).phase, .completed)
    }

    func testCodexOversizedTailPreservesTrustedStateWithoutRefreshingHealth() throws {
        let url = try temporaryFile("codex-oversized-tail.jsonl")
        let start = #"{"type":"event_msg","payload":{"type":"task_started","turn_id":"turn-large"}}"#
        try Data((start + "\n").utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-10)], ofItemAtPath: url.path)
        let trusted = CodexSessions.tailInfo(path: url.path)
        XCTAssertTrue(trusted.readSucceeded)
        XCTAssertEqual(trusted.phase, .working)

        let output: [String: Any] = [
            "type": "response_item",
            "payload": ["type": "function_call_output", "output": String(repeating: "x", count: 300_000)],
        ]
        var oversized = Data((start + "\n").utf8)
        oversized.append(try JSONSerialization.data(withJSONObject: output))
        oversized.append(10)
        try oversized.write(to: url)
        let limited = CodexSessions.tailInfo(path: url.path)
        XCTAssertFalse(limited.readSucceeded)
        XCTAssertEqual(limited.phase, .working)
        XCTAssertEqual(limited.lastSuccessfulReadAt, trusted.lastSuccessfulReadAt)
        XCTAssertEqual(
            limited.readIssue,
            "Latest record exceeds the observation window; waiting for readable progress")

        oversized.append(Data((#"{"type":"event_msg","payload":{"type":"task_complete"}}"# + "\n").utf8))
        try oversized.write(to: url)
        let recovered = CodexSessions.tailInfo(path: url.path)
        XCTAssertTrue(recovered.readSucceeded)
        XCTAssertNil(recovered.readIssue)
        XCTAssertEqual(recovered.phase, .completed)
    }

    func testCodexUnreadableAndMalformedTailAreNotCalledOversized() throws {
        let url = try temporaryFile("codex-malformed-tail.jsonl")
        XCTAssertEqual(CodexSessions.tailInfo(path: url.path).readIssue, "Rollout could not be read or parsed")
        try Data("not-json\n".utf8).write(to: url)
        let malformed = CodexSessions.tailInfo(path: url.path)
        XCTAssertFalse(malformed.readSucceeded)
        XCTAssertEqual(malformed.phase, .unknown)
        XCTAssertEqual(malformed.readIssue, "Rollout could not be read or parsed")
    }

    func testOpenCodeFixtureReadsConversationAndStatusTransitions() throws {
        let data = try Data(contentsOf: fixture("opencode-messages", "json"))
        let messages = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [Any])
        let conversation = OpenCodeSessions.conversationInfo(messages)
        XCTAssertEqual(conversation.lastPrompt, "Fix the session state")
        XCTAssertEqual(conversation.lastMessage, "Inspecting the state reader.")
        XCTAssertEqual(conversation.activity, "read")
        XCTAssertEqual(conversation.model, "deepseek-v3")
        XCTAssertEqual(
            OpenCodeSessions.status(remoteStatus: "busy", hasAttention: false, hasContent: true, age: 1),
            .working
        )
        XCTAssertEqual(
            OpenCodeSessions.status(remoteStatus: "idle", hasAttention: true, hasContent: true, age: 1),
            .needsAttention
        )
        XCTAssertEqual(
            OpenCodeSessions.status(remoteStatus: "idle", hasAttention: false, hasContent: true, age: 1),
            .idle
        )
    }

    func testDeepSeekFixtureCreatesTwoStableSessions() throws {
        let data = try Data(contentsOf: fixture("deepseek-snapshot", "json"))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let observerDate = ISO8601DateFormatter()
        observerDate.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        object["generatedAt"] = observerDate.string(from: Date())
        object["sourceReadAt"] = observerDate.string(from: Date())
        let sessions = try XCTUnwrap(object["sessions"] as? [[String: Any]])
        object["sessions"] = sessions.map { value -> [String: Any] in
            var row = value
            row["updatedAt"] = ISO8601DateFormatter().string(from: Date())
            return row
        }
        let url = try temporaryFile("dsh.json")
        try JSONSerialization.data(withJSONObject: object).write(to: url, options: .atomic)

        let result = DeepSeekHarnessSessions.read(path: url.path, processID: 42)
        XCTAssertEqual(result.health.mode, .rich)
        XCTAssertEqual(result.sessions.map { $0.id }, ["dsh:session-a", "dsh:session-b"])
        XCTAssertEqual(result.sessions.map { $0.processID }, [42, 42])
        XCTAssertEqual(result.sessions.first?.status, .working)
        guard case .web(let target)? = result.sessions.first?.returnTarget else {
            return XCTFail("Expected a web return target")
        }
        XCTAssertEqual(target.host, "127.0.0.1")
    }

    func testDeepSeekRejectsWrongVersionAndDegradesCorruptSnapshot() throws {
        let wrong = try temporaryFile("wrong.json")
        let value: [String: Any] = [
            "schemaVersion": 1,
            "harnessVersion": "0.1.3",
            "generatedAt": ISO8601DateFormatter().string(from: Date()),
            "loopbackURL": "http://127.0.0.1:3080",
            "sessions": [],
        ]
        try JSONSerialization.data(withJSONObject: value).write(to: wrong)
        XCTAssertEqual(DeepSeekHarnessSessions.read(path: wrong.path).health.mode, .incompatible)

        let corrupt = try temporaryFile("corrupt.json")
        try Data("{bad".utf8).write(to: corrupt)
        XCTAssertEqual(DeepSeekHarnessSessions.read(path: corrupt.path).health.mode, .incompatible)
    }

    func testDeepSeekExpiredSnapshotIsHiddenAfterHarnessExits() throws {
        let data = try Data(contentsOf: fixture("deepseek-snapshot", "json"))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let now = Date()
        object["generatedAt"] = ISO8601DateFormatter().string(
            from: now.addingTimeInterval(-SessionVisibility.staleGracePeriod - 1)
        )
        let url = try temporaryFile("expired-dsh.json")
        try JSONSerialization.data(withJSONObject: object).write(to: url, options: .atomic)

        let stopped = DeepSeekHarnessSessions.read(path: url.path, now: now)
        XCTAssertEqual(stopped.health.mode, .stale)
        XCTAssertTrue(stopped.sessions.isEmpty)

        let running = DeepSeekHarnessSessions.read(path: url.path, processID: 42, now: now)
        XCTAssertEqual(running.health.mode, .stale)
        XCTAssertTrue(running.sessions.isEmpty, "A live process cannot make expired source data current")
    }

    private func fixture(_ name: String, _ ext: String) throws -> URL {
        try XCTUnwrap(
            Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures")
        )
    }

    private func temporaryFile(_ name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(name)
    }
}
