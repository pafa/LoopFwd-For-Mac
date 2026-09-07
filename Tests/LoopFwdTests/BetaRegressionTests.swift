import XCTest
import SQLite3
import UserNotifications
import CryptoKit
import Darwin
@testable import LoopFwd

final class BetaRegressionTests: XCTestCase {
    func testMistralResolvesRelativeHomeAndSaveDirectoryAgainstActualWorkingDirectory() throws {
        let fixture = try mistralHookFixture(relativeSaveDirectory: true)
        try fixture.event("post_tool", extra: ["providerDataRoot": fixture.home.path])
        for args in ["Vibe CLI", "vibe --workdir project"] {
            let info = try XCTUnwrap(
                MistralSessions.info(
                    cwd: fixture.cwd, args: args, cpu: 0, vibeHome: "../vibe",
                    processID: 24680, processStartedAt: "Sun Sep 6 12:00:00 2026", observerRoot: fixture.events.path))
            XCTAssertEqual(info.sessionID, fixture.id)
            XCTAssertEqual(info.transcriptPath, fixture.transcript.path)
        }
        XCTAssertNotNil(fixture.read())
    }

    func testMistralObserverRestoresHiddenDataRootWithoutAcceptingConflicts() throws {
        let fixture = try mistralHookFixture()
        func read(_ processHome: String? = nil) -> MistralSessions.Info? {
            MistralSessions.info(
                cwd: fixture.cwd, args: "Vibe CLI", cpu: 0, vibeHome: processHome,
                processID: 24680, processStartedAt: "Sun Sep 6 12:00:00 2026", observerRoot: fixture.events.path)
        }
        try fixture.event("pre_tool")
        XCTAssertNil(read(), "An old observer cannot guess a custom root hidden by setproctitle")
        try fixture.event("pre_tool", extra: ["providerDataRoot": fixture.home.path])
        let actual = try XCTUnwrap(read())
        XCTAssertEqual(actual.sessionID, fixture.id)
        XCTAssertEqual(actual.lastPrompt, "Fix synthetic login")
        XCTAssertEqual(actual.observation.mode, .stale)
        XCTAssertEqual(actual.status, .idle)
        XCTAssertNotNil(read(fixture.home.path))
        XCTAssertNil(read("/different/root"), "Conflicting process and observer roots must fail closed")
        for invalid in ["relative", "/different/root", "/" + String(repeating: "x", count: 4096)] {
            try fixture.event("pre_tool", extra: ["providerDataRoot": invalid])
            XCTAssertNil(read())
        }
    }

    func testMistralRequiresLiveHookIdentityNotNewestHistoryOrCPU() throws {
        let fixture = try mistralHookFixture()
        XCTAssertNil(fixture.read())
        try fixture.event("pre_tool", id: "tool-1")
        let info = try XCTUnwrap(fixture.read())
        XCTAssertEqual(info.sessionID, fixture.id)
        XCTAssertEqual(info.status, .idle)
        XCTAssertEqual(info.activity, "Tool requested: read_file")
        XCTAssertEqual(info.observation.mode, .stale)
        XCTAssertNil(fixture.read(pid: 24681))
        XCTAssertNil(fixture.read(start: "reused PID start"))
        XCTAssertFalse(
            IntegrationProfiles.profile(for: .mistralCLI, kind: .mistral).canAssertCompletion(
                authority: .versionedObserver))
        XCTAssertFalse(
            IntegrationProfiles.profile(for: .mistralCLI, kind: .mistral).canAssertAttention(
                authority: .versionedObserver))
    }

    func testMistralTracksToolIDsAndDoesNotPromotePostAgentToSuccess() throws {
        let fixture = try mistralHookFixture()
        try fixture.event("pre_tool", id: "tool-a")
        try fixture.event("pre_tool", id: "tool-b")
        try fixture.event("post_tool", id: "tool-a")
        XCTAssertEqual(fixture.read()?.activity, "Tool finished: read_file")
        try fixture.event("post_tool", id: "tool-b")
        XCTAssertEqual(fixture.read()?.status, .working)
        XCTAssertEqual(fixture.read()?.activity, "Tool finished: read_file")
        try fixture.event("post_agent")
        XCTAssertNotEqual(fixture.read()?.status, .completed)
        XCTAssertEqual(fixture.read()?.observation.mode, .stale)
        try fixture.event("pre_tool", id: "skipped-tool")
        try fixture.event("pre_tool", id: "next-tool")
        XCTAssertEqual(fixture.read()?.observation.mode, .stale)
        XCTAssertFalse(fixture.read()?.activity?.contains("Running") ?? true)
    }

    func testMistralStaleAndUnsafeHookFilesFailClosed() throws {
        let fixture = try mistralHookFixture()
        try fixture.event("pre_tool", id: "tool-a")
        let first = try XCTUnwrap(fixture.read())
        let stale = try XCTUnwrap(fixture.read(now: Date().addingTimeInterval(1801)))
        XCTAssertEqual(stale.observation.mode, .stale)
        XCTAssertEqual(stale.observation.updatedAt, first.observation.updatedAt)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fixture.events.path)
        XCTAssertNil(fixture.read())
    }

    private struct MistralFixture {
        let root: URL
        let events: URL
        let home: URL
        let transcript: URL
        let id: String
        let cwd: String
        func read(pid: Int32 = 24680, start: String = "Sun Sep  6 12:00:00 2026", now: Date = Date()) -> MistralSessions
            .Info?
        {
            MistralSessions.info(
                cwd: cwd, args: "vibe", cpu: 90, vibeHome: home.path,
                processID: pid, processStartedAt: start, observerRoot: events.path, now: now)
        }
        func event(_ name: String, id tool: String? = nil, extra: [String: Any] = [:]) throws {
            let scope = events.appendingPathComponent(
                LocalHookEvents.scopePrefix(provider: "mistral", pid: 24680, startedAt: "Sun Sep 6 12:00:00 2026")
                    + "fixture")
            try FileManager.default.createDirectory(
                at: scope, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let count = try FileManager.default.contentsOfDirectory(atPath: scope.path).count
            var record: [String: Any] = [
                "schemaVersion": 1, "provider": "mistral", "sessionID": id,
                "eventName": name, "observedAt": Date().timeIntervalSince1970 * 1000 + Double(count),
                "ownerPID": 24680, "ownerStartedAt": "Sun Sep 6 12:00:00 2026",
                "transcriptPath": transcript.path, "cwd": cwd, "toolName": "read_file",
            ]
            if let tool { record["toolID"] = tool }
            record.merge(extra) { _, new in new }
            let file = scope.appendingPathComponent("\(count).json")
            try JSONSerialization.data(withJSONObject: record).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
    }

    private func mistralHookFixture(relativeSaveDirectory: Bool = false) throws -> MistralFixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loopfwd-mistral-test-\(UUID())")
        let id = UUID().uuidString
        let home = root.appendingPathComponent("vibe")
        let cwd = relativeSaveDirectory ? root.appendingPathComponent("project").path : "/synthetic/mistral-project"
        let session =
            relativeSaveDirectory
            ? URL(fileURLWithPath: cwd).appendingPathComponent("sessions/\(id)")
            : home.appendingPathComponent("logs/session/\(id)")
        let events = root.appendingPathComponent("events")
        let transcript = session.appendingPathComponent("messages.jsonl")
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        if relativeSaveDirectory {
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            try Data("[session_logging]\nsave_dir = \"sessions\"\n".utf8).write(
                to: home.appendingPathComponent("config.toml"))
        }
        try FileManager.default.createDirectory(
            at: events, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        try JSONSerialization.data(withJSONObject: [
            "session_id": id,
            "environment": ["working_directory": cwd], "config": ["active_model": "synthetic"],
        ])
        .write(to: session.appendingPathComponent("meta.json"))
        try Data(
            "{\"role\":\"user\",\"content\":\"Fix synthetic login\"}\n{\"role\":\"assistant\",\"content\":\"Historical answer\"}\n"
                .utf8
        ).write(to: transcript)
        return .init(root: root, events: events, home: home, transcript: transcript, id: id, cwd: cwd)
    }

    func testGrokReadRequiresLiveOwnershipAndReturnsEverySession() throws {
        let fixture = try grokFixture(count: 10)
        XCTAssertEqual(fixture.read(owned: []).infos.count, 0)
        let batch = fixture.read()
        XCTAssertEqual(batch.outcome, .success)
        XCTAssertEqual(Set(batch.infos.compactMap(\.sessionID)), Set(fixture.ids))
        XCTAssertTrue(batch.infos.allSatisfy { $0.phase == .working && $0.observation.mode == .rich })
        XCTAssertEqual(
            GrokSessions.read(
                pid: 999, grokHome: fixture.root.path,
                openEvents: fixture.events.map(\.path), processStartedAt: fixture.startTime
            ).infos.count, 0)
        XCTAssertEqual(fixture.read(owned: [fixture.events[0].path]).infos.count, 1)
        try Data("{}".utf8).write(
            to: fixture.events[0].deletingLastPathComponent().appendingPathComponent("summary.json"))
        XCTAssertEqual(fixture.read().outcome, .partial)
        XCTAssertEqual(fixture.read(owned: [fixture.events[0].path]).outcome, .failed)
    }

    func testGrokExplicitOutcomesAndAttentionRemainTurnScoped() throws {
        for (outcome, expected) in [
            ("completed", GrokSessions.Phase.completed), ("cancelled", .stopped), ("error", .failed),
        ] {
            let fixture = try grokFixture()
            try fixture.append([["type": "permission_requested", "tool_name": "shell"]])
            XCTAssertEqual(fixture.read().infos.first?.phase, .needsAttention)
            try fixture.append([["type": "permission_resolved", "tool_name": "shell", "decision": "deny"]])
            XCTAssertEqual(fixture.read().infos.first?.phase, .working)
            try fixture.append([["type": "turn_ended", "outcome": outcome]])
            XCTAssertEqual(fixture.read().infos.first?.phase, expected)
            try fixture.append([["type": "permission_requested", "tool_name": "late"]])
            XCTAssertEqual(fixture.read().infos.first?.phase, expected)
            try fixture.append([fixture.start(turn: 2)])
            XCTAssertEqual(fixture.read().infos.first?.phase, .working)
            XCTAssertEqual(fixture.read().infos.first?.turnID, "2")
        }
    }

    func testGrokCorruptionAndUnsupportedBoundariesFailClosed() throws {
        let fixture = try grokFixture()
        try fixture.append([["type": "turn_ended"]])
        XCTAssertNotEqual(fixture.read().infos.first?.observation.mode, .rich)
        try fixture.append([fixture.start(turn: 2, schema: "9.0")])
        XCTAssertEqual(fixture.read().outcome, .incompatible)
        try fixture.append([fixture.start(turn: 3)])
        XCTAssertEqual(fixture.read().infos.first?.phase, .working)
        let file = try FileHandle(forWritingTo: fixture.events[0])
        try file.seekToEnd()
        try file.write(contentsOf: Data("{broken".utf8))
        try file.close()
        XCTAssertEqual(fixture.read().infos.first?.observation.mode, .stale)
        XCTAssertNotEqual(fixture.read().infos.first?.phase, .completed)
        XCTAssertEqual(
            GrokSessions.eventState(fromTailText: "{\"type\":\"turn_ended\",\"outcome\":\"completed\"}\n").phase,
            .unknown)
    }

    func testGrokCachedProgressExpiresWithoutRefreshingItsTimestamp() throws {
        let fixture = try grokFixture()
        let initial = try XCTUnwrap(fixture.read().infos.first)
        let later = try XCTUnwrap(fixture.read(now: Date().addingTimeInterval(1801)).infos.first)
        XCTAssertEqual(later.phase, .working)
        XCTAssertEqual(later.observation.mode, .stale)
        XCTAssertEqual(later.observation.updatedAt, initial.observation.updatedAt)
        let profile = IntegrationProfiles.profile(for: .grokCLI, kind: .grok)
        XCTAssertTrue(profile.canAssertCompletion(authority: .officialLocalStore))
        XCTAssertTrue(profile.canAssertAttention(authority: .officialLocalStore))
        XCTAssertEqual(profile.controlPolicy, .none)
    }

    func testGrokReopenDoesNotReviveHistoricalApprovalsOrResultsFromWarmCache() throws {
        for event in [
            ["type": "permission_requested", "tool_name": "shell"],
            ["type": "turn_ended", "outcome": "completed"],
            ["type": "turn_ended", "outcome": "error"],
            ["type": "turn_ended", "outcome": "cancelled"],
            ["type": "phase_changed", "phase": "streaming_text"],
        ] {
            let fixture = try grokFixture()
            try fixture.append([event])
            XCTAssertNotEqual(fixture.read().infos.first?.phase, .unknown)
            let reopened = Date().addingTimeInterval(10)
            try fixture.registry(opened: reopened)
            let info = try XCTUnwrap(fixture.read(now: reopened.addingTimeInterval(3)).infos.first)
            XCTAssertEqual(info.phase, .unknown)
            XCTAssertEqual(info.observation.mode, .rich)
            XCTAssertNil(info.turnID)
            XCTAssertNil(info.activity)
            XCTAssertTrue(info.todos.isEmpty)
            var start = fixture.start(turn: 2)
            start["ts"] = ISO8601DateFormatter().string(from: reopened.addingTimeInterval(1))
            try fixture.append([start])
            let current = fixture.read(now: reopened.addingTimeInterval(3)).infos.first
            XCTAssertEqual(current?.phase, .working)
            XCTAssertEqual(current?.turnID, "2")
        }
    }

    func testGrokOpeningMetadataRejectsMissingFutureAndReusedProcessIdentity() throws {
        let fixture = try grokFixture()
        for opened in [nil, Date(timeIntervalSince1970: 1), Date().addingTimeInterval(10)] {
            try fixture.registry(opened: opened)
            XCTAssertEqual(fixture.read().outcome, .failed)
            XCTAssertTrue(fixture.read().infos.isEmpty)
        }
        try fixture.registry(opened: Date().addingTimeInterval(-1))
        try Data().write(to: fixture.events[0])
        let empty = fixture.read()
        XCTAssertEqual(empty.outcome, .success)
        XCTAssertEqual(empty.infos.first?.phase, .unknown)
        XCTAssertEqual(empty.infos.first?.observation.mode, .rich)
        XCTAssertEqual(
            GrokSessions.read(
                pid: 24680, grokHome: fixture.root.path, openEvents: fixture.events.map(\.path),
                processStartedAt: nil
            ).outcome, .failed)
    }

    func testGrokConcurrentTimestampOrderAndLargeHistoryResynchronize() throws {
        let fixture = try grokFixture()
        let initial = try XCTUnwrap(fixture.read().infos.first)
        let file = try FileHandle(forWritingTo: fixture.events[0])
        try file.seekToEnd()
        try file.write(
            contentsOf: Data(
                "{\"type\":\"turn_ended\",\"outcome\":\"completed\",\"ts\":\"2026-01-01T00:00:00.000Z\"}\n".utf8))
        try file.close()
        XCTAssertEqual(fixture.read().infos.first?.phase, .completed)
        XCTAssertEqual(fixture.read().infos.first?.observation.updatedAt, initial.observation.updatedAt)

        // The bounded suffix drops the old giant record, not the fresh boundary.
        var history = Data("{\"type\":\"old_history\",\"data\":\"".utf8)
        history.append(Data(repeating: 120, count: 4 * 1024 * 1024))
        history.append(Data("\"}\n".utf8))
        try history.write(to: fixture.events[0])
        XCTAssertEqual(fixture.read().outcome, .partial, "A truncated giant record is not an empty event store")
        XCTAssertEqual(fixture.read().infos.first?.observation.mode, .stale)
        try fixture.append([fixture.start(turn: 2), ["type": "turn_ended", "outcome": "cancelled"]])
        XCTAssertEqual(fixture.read().infos.first?.phase, .stopped)
        XCTAssertEqual(fixture.read().infos.first?.observation.mode, .rich)
    }

    private struct GrokFixture {
        let root: URL
        let ids: [String]
        let events: [URL]
        let startTime: String
        func read(owned: [String]? = nil, now: Date = Date()) -> GrokSessions.ReadBatch {
            GrokSessions.read(
                pid: 24680, grokHome: root.path, openEvents: owned ?? events.map(\.path),
                processStartedAt: startTime, now: now)
        }
        func registry(opened: Date?, pid: Int = 24680) throws {
            try JSONSerialization.data(
                withJSONObject: ids.map { id -> [String: Any] in
                    var entry: [String: Any] = ["session_id": id, "pid": pid, "cwd": "/synthetic/grok-project"]
                    if let opened { entry["opened_at"] = ISO8601DateFormatter().string(from: opened) }
                    return entry
                }
            ).write(to: root.appendingPathComponent("active_sessions.json"))
        }
        func start(turn: Int = 1, schema: String = "1.0", index: Int = 0) -> [String: Any] {
            [
                "type": "turn_started", "session_id": ids[index], "turn_number": turn,
                "schema_version": schema, "session_relationship": "primary",
            ]
        }
        func append(_ records: [[String: Any]], index: Int = 0) throws {
            let file = try FileHandle(forWritingTo: events[index])
            defer { try? file.close() }
            try file.seekToEnd()
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            for var record in records {
                if record["ts"] == nil { record["ts"] = formatter.string(from: Date()) }
                try file.write(contentsOf: JSONSerialization.data(withJSONObject: record) + Data([10]))
            }
        }
    }

    private func grokFixture(count: Int = 1) throws -> GrokFixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loopfwd-grok-test-\(UUID())")
        let ids = (0..<count).map { _ in UUID().uuidString.lowercased() }
        let dirs = ids.map { root.appendingPathComponent("sessions/%2Fsynthetic%2Fgrok-project/\($0)") }
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        for (index, dir) in dirs.enumerated() {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: ["info": ["id": ids[index], "cwd": "/synthetic/grok-project"]])
                .write(to: dir.appendingPathComponent("summary.json"))
            try Data().write(to: dir.appendingPathComponent("events.jsonl"))
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        let fixture = GrokFixture(
            root: root, ids: ids, events: dirs.map { $0.appendingPathComponent("events.jsonl") },
            startTime: formatter.string(from: Date().addingTimeInterval(-60)))
        try fixture.registry(opened: Date().addingTimeInterval(-3))
        for index in ids.indices { try fixture.append([fixture.start(index: index)], index: index) }
        return fixture
    }

    func testKimiRequiresSessionOwnershipAndKeepsStableIdentity() throws {
        let fixture = try kimiFixture()
        XCTAssertNil(KimiSessions.info(cwd: fixture.cwd, args: "kimi", dataRoot: fixture.root.path))
        let info = try XCTUnwrap(fixture.read())
        XCTAssertEqual(info.sessionID, fixture.id)
        XCTAssertEqual(info.status, .idle)
        XCTAssertEqual(info.observation.mode, .rich)
        XCTAssertEqual(
            KimiSessions.info(
                cwd: fixture.cwd, args: "kimi", dataRoot: fixture.root.path,
                openWirePaths: [fixture.wire.path])?.sessionID, fixture.id)
        XCTAssertNil(
            KimiSessions.info(
                cwd: "/different", args: "kimi --session \(fixture.id)", dataRoot: fixture.root.path))
    }

    func testKimiStepEndAndHistoricalAssistantDoNotCompleteTask() throws {
        let fixture = try kimiFixture()
        try fixture.append([
            ["type": "context.append_message", "message": ["role": "assistant", "content": "Old answer"]]
        ])
        XCTAssertEqual(fixture.read()?.status, .idle)
        try fixture.append([
            ["type": "turn.prompt", "agentId": "main", "input": "Fix synthetic login form"],
            ["type": "context.append_loop_event", "event": ["type": "step.begin", "turnId": "1"]],
            ["type": "context.append_loop_event", "event": ["type": "step.end", "turnId": "1"]],
        ])
        XCTAssertEqual(fixture.read()?.status, .working)
        try fixture.append([["type": "turn.ended", "agentId": "agent-0", "turnId": 1, "reason": "completed"]])
        XCTAssertEqual(fixture.read()?.status, .working)
        try fixture.append([["type": "turn.ended", "agentId": "main", "turnId": 0, "reason": "completed"]])
        XCTAssertEqual(fixture.read()?.status, .working)
        try fixture.append([["type": "turn.ended", "agentId": "main", "turnId": 1, "reason": "completed"]])
        XCTAssertEqual(fixture.read()?.status, .completed)
        XCTAssertEqual(fixture.read()?.turnID, "1")
        try fixture.append([["type": "turn.prompt", "agentId": "main", "input": "继续"]])
        XCTAssertEqual(fixture.read()?.status, .working)
        XCTAssertEqual(fixture.read()?.lastPrompt, "Fix synthetic login form")
    }

    func testKimiExplicitFailureAndCancellationAreNotSuccess() throws {
        for (reason, expected) in [("failed", AgentStatus.failed), ("blocked", .failed), ("cancelled", .stopped)] {
            let fixture = try kimiFixture()
            try fixture.append([
                ["type": "turn.prompt", "agentId": "main", "input": "Synthetic task"],
                ["type": "turn.ended", "agentId": "main", "turnId": 1, "reason": reason],
            ])
            XCTAssertEqual(fixture.read()?.status, expected)
        }
    }

    func testKimiDamageAndUnsupportedVersionNeverBecomeRich() throws {
        let fixture = try kimiFixture()
        try Data("{\"type\":\"metadata\",\"protocol_version\":\"9.0\"}\n".utf8).write(to: fixture.wire)
        XCTAssertEqual(fixture.read()?.observation.mode, .incompatible)
        try Data("{broken\n".utf8).write(to: fixture.wire)
        XCTAssertEqual(fixture.read()?.observation.mode, .stale)
        try Data("{\"type\":\"metadata\",\"protocol_version\":\"1.5\"}\n{partial".utf8).write(to: fixture.wire)
        XCTAssertEqual(fixture.read()?.observation.mode, .stale)
        try Data(repeating: 32, count: 4 * 1024 * 1024 + 1).write(to: fixture.wire)
        XCTAssertEqual(fixture.read()?.observation.mode, .stale)
    }

    private struct KimiFixture {
        let root: URL
        let id: String
        let wire: URL
        let cwd = "/synthetic/kimi-project"

        func read() -> KimiSessions.Info? {
            KimiSessions.info(cwd: cwd, args: "kimi --session \(id)", dataRoot: root.path)
        }

        func append(_ records: [[String: Any]]) throws {
            let file = try FileHandle(forWritingTo: wire)
            defer { try? file.close() }
            try file.seekToEnd()
            for var record in records {
                record["time"] = Date().timeIntervalSince1970 * 1000
                try file.write(contentsOf: JSONSerialization.data(withJSONObject: record) + Data([10]))
            }
        }
    }

    private func kimiFixture() throws -> KimiFixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loopfwd-kimi-test-\(UUID())")
        let id = UUID().uuidString.lowercased()
        let dir = root.appendingPathComponent("sessions/wd_synthetic/\(id)")
        let wire = dir.appendingPathComponent("agents/main/wire.jsonl")
        try FileManager.default.createDirectory(at: wire.deletingLastPathComponent(), withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        let fixture = KimiFixture(root: root, id: id, wire: wire)
        try JSONSerialization.data(withJSONObject: ["cwd": fixture.cwd, "title": "Synthetic session"])
            .write(to: dir.appendingPathComponent("state.json"))
        try Data("{\"type\":\"metadata\",\"protocol_version\":\"1.5\",\"created_at\":1}\n".utf8).write(to: wire)
        return fixture
    }

    func testCopilotNativeProcessIsNotDiscardedAsItsNpmLaunchersHelper() {
        XCTAssertTrue(
            ProcessNaming.isCopilotNativeLaunch(
                childCommand: "/isolated/node_modules/@github/copilot-darwin-arm64/copilot --no-mouse",
                parentCommand: "node /isolated/node_modules/.bin/copilot --no-mouse"))
        XCTAssertFalse(ProcessNaming.isCopilotNativeLaunch(childCommand: "copilot", parentCommand: "copilot"))
        XCTAssertFalse(ProcessNaming.isCopilotNativeLaunch(childCommand: "copilot", parentCommand: "node -e copilot"))
        XCTAssertFalse(ProcessNaming.isCopilotNativeLaunch(childCommand: "other", parentCommand: "node /bin/copilot"))
    }
    func testCopilotRealReadSupportsAllTabsAndCustomHomeWithoutGuessing() throws {
        let fixture = try copilotFixture(count: 10)
        let batch = fixture.read()
        XCTAssertEqual(batch.outcome, .success)
        XCTAssertEqual(Set(batch.sessions.map(\.sessionID)), Set(fixture.ids))
        XCTAssertTrue(batch.sessions.allSatisfy { $0.status == .idle && $0.observation.mode == .rich })
        let lock = fixture.home.appendingPathComponent("session-state/\(fixture.ids[0])/inuse.23458.lock")
        try FileManager.default.removeItem(at: lock)
        XCTAssertEqual(fixture.read().sessions.count, 9)
        // A valid live tracker entry without this process's lock is not ownership.
        try Data("99999\n".utf8).write(to: lock)
        XCTAssertEqual(fixture.read().sessions.count, 9)
        try Data("23458\n".utf8).write(to: lock)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: lock.path)
        XCTAssertEqual(fixture.read().sessions.count, 9)
    }

    func testCopilotCompletionRequiresAcceptedRootResultAndCurrentTask() throws {
        let fixture = try copilotFixture()
        for (event, payload) in [
            ("assistant.message", ["content": "Historical answer"] as [String: Any]),
            ("assistant.turn_end", ["turnId": "0"]), ("session.idle", [:]), ("session.shutdown", [:]),
            ("permission.requested", ["requestId": "old-request", "resolvedByHook": true]),
            ("session.task_complete", ["success": false, "outcome": "blocked"]),
            ("session.task_complete", ["success": true, "outcome": "continue"]),
        ] {
            try fixture.events([(event, payload, nil)])
            XCTAssertEqual(fixture.read().sessions.first?.status, .idle, event)
        }
        let success: [String: Any] = ["success": true, "outcome": "completed"]
        try fixture.events([("session.task_complete", success, "child")])
        XCTAssertEqual(fixture.read().sessions.first?.status, .idle)
        try fixture.events([("session.task_complete", success, nil)])
        XCTAssertEqual(fixture.read().sessions.first?.status, .completed)
        try fixture.tracker(working: true)
        XCTAssertEqual(fixture.read().sessions.first?.status, .working)
        try fixture.tracker(working: false)
        try fixture.events([("session.task_complete", success, nil), ("user.message", ["content": "继续"], nil)])
        XCTAssertEqual(fixture.read().sessions.first?.status, .idle)
        XCTAssertEqual(fixture.read().sessions.first?.lastPrompt, "Build a synthetic project")
        for (event, status) in [("abort", AgentStatus.stopped), ("session.error", .failed)] {
            try fixture.events([(event, ["message": "Synthetic failure"], nil)])
            XCTAssertEqual(fixture.read().sessions.first?.status, status)
        }
    }

    func testCopilotFailuresDoNotBecomeSuccessfulEmptyOrIdle() throws {
        let fixture = try copilotFixture()
        try fixture.events([])
        let path = fixture.home.appendingPathComponent("session-state/\(fixture.ids[0])/events.jsonl")
        let handle = try FileHandle(forWritingTo: path)
        try handle.seekToEnd(); try handle.write(contentsOf: Data("{\"type\":".utf8)); try handle.close()
        XCTAssertEqual(fixture.read().outcome, .partial)
        XCTAssertEqual(fixture.read().sessions.first?.observation.mode, .stale)
        try fixture.events([], version: "2.0.0")
        XCTAssertEqual(fixture.read().sessions.first?.observation.mode, .incompatible)
        try Data("{".utf8).write(to: fixture.home.appendingPathComponent("open-sessions-state.json"))
        XCTAssertEqual(fixture.read().outcome, .failed)
        try fixture.tracker(working: false, opened: Date(timeIntervalSince1970: 1))
        XCTAssertTrue(fixture.read().sessions.isEmpty)
    }

    func testCopilotOptionalCompletionFieldsMatchPinnedLegacyContract() throws {
        let fixture = try copilotFixture()
        for data: [String: Any] in [
            [:], ["summary": "Synthetic complete"], ["success": true], ["outcome": "completed"],
            ["success": true, "outcome": "completed"],
        ] {
            try fixture.events([("session.task_complete", data, nil)])
            XCTAssertEqual(fixture.read().sessions.first?.status, .completed, "\(data)")
        }
        for data: [String: Any] in [
            ["success": false], ["success": false, "outcome": "completed"],
            ["outcome": "blocked"], ["outcome": "continue"], ["success": "true"], ["success": 1],
            ["outcome": NSNull()], ["objectiveId": true], ["objectiveId": 1.5], ["objectiveId": 0],
            ["summary": 123], ["reason": false], ["summary": NSNull()],
        ] {
            try fixture.events([("session.task_complete", data, nil)])
            XCTAssertEqual(fixture.read().sessions.first?.status, .idle, "\(data)")
        }
        try fixture.events([("session.task_complete", [:], "child")])
        XCTAssertEqual(fixture.read().sessions.first?.status, .idle)
    }

    func testCopilotCompletionCannotCrossObjectiveIncarnations() throws {
        let fixture = try copilotFixture()
        let result: (String, [String: Any], String?) = ("session.task_complete", ["objectiveId": 1], nil)
        let changed = "session.autopilot_objective_changed"
        try fixture.objective(["id": 1, "status": "completed"])
        try fixture.events([result])
        XCTAssertEqual(fixture.read().sessions.first?.status, .completed, "current.id, not nextId, owns the result")
        try fixture.events([result, (changed, ["operation": "update", "id": 1, "status": "completed"], nil)])
        XCTAssertEqual(fixture.read().sessions.first?.status, .completed)
        for transition: [String: Any] in [
            ["operation": "create", "id": 2, "status": "active"],
            ["operation": "update", "id": 1, "status": "active"],
            ["operation": "update", "id": 1, "status": "paused"],
            ["operation": "delete"], ["operation": "update"],
        ] {
            try fixture.events([result, (changed, transition, nil)])
            XCTAssertEqual(fixture.read().sessions.first?.status, .idle, "\(transition)")
            try fixture.events([(changed, transition, nil), result])
            XCTAssertEqual(fixture.read().sessions.first?.status, .idle, "File and latest event must reconcile")
        }
        try fixture.events([result])
        for status in ["active", "paused", "cap_reached"] {
            try fixture.objective(["id": 1, "status": status])
            XCTAssertEqual(fixture.read().sessions.first?.status, .idle)
        }
        try fixture.objective(["id": 2, "status": "completed"])
        XCTAssertEqual(fixture.read().sessions.first?.status, .idle)
        try fixture.events([("session.task_complete", ["outcome": "completed"], nil)])
        XCTAssertEqual(fixture.read().sessions.first?.status, .idle, "A current goal requires its matching identity")
        try fixture.tracker(working: true)
        XCTAssertEqual(fixture.read().sessions.first?.status, .working)
    }

    func testCopilotAutopilotPauseRetainsExplicitFailureAndCancellation() throws {
        let fixture = try copilotFixture()
        let changed = "session.autopilot_objective_changed"
        for (event, expected) in [("session.error", AgentStatus.failed), ("abort", .stopped)] {
            try fixture.objective(["id": 1, "status": "paused"])
            try fixture.events([
                (changed, ["operation": "create", "id": 1, "status": "active"], nil),
                (event, [:], nil),
                (changed, ["operation": "update", "id": 1, "status": "paused"], nil),
            ])
            XCTAssertEqual(fixture.read().sessions.first?.status, expected)
            try fixture.objective(["id": 2, "status": "active"])
            try fixture.events([
                (event, [:], nil),
                (changed, ["operation": "create", "id": 2, "status": "active"], nil),
            ])
            XCTAssertEqual(fixture.read().sessions.first?.status, .idle, "A new goal is a new boundary")
        }
    }

    func testCopilotObjectiveFailureCannotAuthorizeCompletion() throws {
        let fixture = try copilotFixture()
        try fixture.events([("session.task_complete", [:], nil)])
        let path = fixture.home.appendingPathComponent("session-state/\(fixture.ids[0])/autopilot-objective.json")
        for text in [
            "{", "{}", "{\"version\":2,\"current\":null}", "{\"version\":true,\"current\":null}",
            "{\"version\":1,\"current\":{\"id\":true,\"status\":\"completed\"}}",
            "{\"version\":1,\"current\":{\"id\":1.5,\"status\":\"completed\"}}",
        ] {
            try Data(text.utf8).write(to: path)
            XCTAssertEqual(fixture.read().sessions.first?.status, .idle)
        }
        try fixture.objective(NSNull())
        XCTAssertEqual(fixture.read().sessions.first?.status, .completed)
        try fixture.events([("session.task_complete", ["objectiveId": 1], nil)])
        XCTAssertEqual(fixture.read().sessions.first?.status, .idle)
        try FileManager.default.removeItem(at: path)
        try FileManager.default.createSymbolicLink(atPath: path.path, withDestinationPath: "missing.json")
        try fixture.events([("session.task_complete", [:], nil)])
        XCTAssertEqual(fixture.read().sessions.first?.status, .idle, "A dangling link is not optional absence")
    }

    func testCopilotProfileDoesNotBorrowApprovalOrPreciseTabControl() {
        let profile = IntegrationProfiles.profile(for: .copilotCLI, kind: .copilot)
        XCTAssertTrue(profile.canAssertCompletion(authority: .officialLocalStore))
        XCTAssertFalse(profile.canAssertAttention(authority: .officialLocalStore))
        XCTAssertEqual(profile.controlPolicy, .none)
        XCTAssertFalse(CopilotSessions.returnTarget(terminalApp: "Terminal").isExact)
        XCTAssertFalse(CopilotSessions.returnTarget(terminalApp: "iTerm").isExact)
        XCTAssertNotNil(CopilotSessions.returnTarget(terminalApp: "unverified").unavailableReason)
    }

    func testOptInCopilotActualCLIOpenSession() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let home = env["LOOPFWD_COPILOT_CONTRACT_HOME"], let start = env["LOOPFWD_COPILOT_CONTRACT_START"],
            let id = env["LOOPFWD_COPILOT_CONTRACT_ID"],
            let pid = env["LOOPFWD_COPILOT_CONTRACT_PID"].flatMap(Int32.init)
        else { throw XCTSkip("Requires the isolated, actually running Copilot CLI") }
        struct Target: Decodable {
            let id: String
            let pid: Int32
            let start: String
            let marker: String?
        }
        var targets = [Target(id: id, pid: pid, start: start, marker: env["LOOPFWD_COPILOT_CONTRACT_MARKER"])]
        if let extra = env["LOOPFWD_COPILOT_CONTRACT_EXTRA_TARGETS"] {
            targets += try JSONDecoder().decode([Target].self, from: Data(extra.utf8))
        }
        guard targets.count <= 8, Set(targets.map(\.id)).count == targets.count,
            targets.allSatisfy({ UUID(uuidString: $0.id) != nil && $0.pid > 0 && !$0.start.isEmpty })
        else { return XCTFail("Live Copilot targets must have distinct session IDs and real process identities") }
        let requested = (env["LOOPFWD_COPILOT_CONTRACT_STATES"] ?? "idle").split(separator: ",").map(String.init)
        let statuses: [String: AgentStatus] = [
            "idle": .idle, "working": .working, "completed": .completed, "failed": .failed, "stopped": .stopped,
        ]
        guard !requested.isEmpty, requested.allSatisfy({ statuses[$0] != nil || $0 == "gone" }) else {
            return XCTFail("Live Copilot check requires explicit known states")
        }
        let deadline = Date().addingTimeInterval(requested.count > 1 ? 90 : 15)
        var observed = 0
        var lastReaderState = "missing"
        var lastScannerState = "missing"
        print("Live Copilot observer ready; no model request is sent by this test")
        fflush(stdout)
        while Date() < deadline {
            let batches = targets.map { target in
                CopilotSessions.read(processID: target.pid, processStartedAt: target.start, cwd: nil, home: home)
            }
            let scan = await AgentScanner.findAgents()
            let observations = zip(targets, batches).map { target, batch in
                (
                    target: target, batch: batch,
                    direct: batch.sessions.filter { $0.sessionID == target.id },
                    projected: scan.sessions.filter { $0.id == "copilot:\(target.id)" }
                )
            }
            lastReaderState = observations.map { $0.direct.first?.status.label ?? "missing" }.joined(separator: ",")
            lastScannerState = observations.map { $0.projected.first?.status.label ?? "missing" }.joined(separator: ",")
            if requested[observed] == "gone", scan.processScanSucceeded,
                observations.allSatisfy({ item in
                    item.batch.outcome == .empty && item.direct.isEmpty && item.projected.isEmpty
                        && kill(item.target.pid, 0) == -1 && errno == ESRCH
                })
            {
                print("Live Copilot process exited; Reader and Scanner released the session")
                fflush(stdout)
                observed += 1
                if observed == requested.count { return }
                continue
            }
            if scan.processScanSucceeded,
                observations.allSatisfy({ item in
                    guard item.batch.outcome == .success, item.direct.count == 1, item.projected.count == 1,
                        let session = item.direct.first, let projection = item.projected.first,
                        session.status == statuses[requested[observed]], projection.status == session.status,
                        session.observation.mode == .rich, projection.observation.mode == .rich,
                        projection.processID == item.target.pid, projection.surfaceID == .copilotCLI,
                        session.cwd != nil
                    else { return false }
                    if requested[observed] == "working", let marker = item.target.marker {
                        return session.lastPrompt?.contains(marker) == true
                            && projection.lastPrompt?.contains(marker) == true
                    }
                    return true
                })
            {
                print("Live Copilot observed \(requested[observed]) in Reader and Scanner (\(targets.count) sessions)")
                fflush(stdout)
                observed += 1
                if observed == requested.count { return }
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        XCTFail(
            "Live Copilot sequence incomplete: \(observed)/\(requested.count); reader=\(lastReaderState), scanner=\(lastScannerState)"
        )
    }

    private struct CopilotFixture {
        let home: URL
        let ids: [String]
        let opened: Date
        let start: String
        func read() -> CopilotSessions.Batch {
            CopilotSessions.read(processID: 23458, processStartedAt: start, cwd: "/fixture", home: home.path)
        }
        func tracker(working: Bool, opened override: Date? = nil) throws {
            let timestamp = ISO8601DateFormatter().string(from: override ?? opened)
            let records = Dictionary(
                uniqueKeysWithValues: ids.map {
                    (
                        $0,
                        [
                            "schemaVersion": 1, "openedAt": timestamp, "refreshedAt": timestamp, "working": working,
                        ] as [String: Any]
                    )
                })
            try JSONSerialization.data(withJSONObject: records).write(
                to: home.appendingPathComponent("open-sessions-state.json"))
        }
        func objective(_ current: Any) throws {
            try JSONSerialization.data(withJSONObject: ["version": 1, "nextId": 99, "current": current])
                .write(to: home.appendingPathComponent("session-state/\(ids[0])/autopilot-objective.json"))
        }
        func events(_ additions: [(String, [String: Any], String?)], version: String = "1.0.83") throws {
            let prefix: [(String, [String: Any], String?)] = [
                ("session.start", ["sessionId": ids[0], "copilotVersion": version], nil),
                ("user.message", ["content": "Build a synthetic project"], nil),
            ]
            var bytes = Data()
            for (type, data, agentID) in prefix + additions {
                var record: [String: Any] = [
                    "id": UUID().uuidString, "type": type, "data": data,
                    "timestamp": ISO8601DateFormatter().string(from: opened.addingTimeInterval(1)),
                ]
                if let agentID { record["agentId"] = agentID }
                bytes.append(try JSONSerialization.data(withJSONObject: record)); bytes.append(10)
            }
            try bytes.write(to: home.appendingPathComponent("session-state/\(ids[0])/events.jsonl"))
        }
    }

    private func copilotFixture(count: Int = 1) throws -> CopilotFixture {
        let home = try temporaryFile().deletingLastPathComponent()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        let fixture = CopilotFixture(
            home: home, ids: (0..<count).map { _ in UUID().uuidString.lowercased() },
            opened: Date().addingTimeInterval(-3), start: formatter.string(from: Date().addingTimeInterval(-10)))
        for id in fixture.ids {
            let directory = home.appendingPathComponent("session-state/\(id)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("23458\n".utf8).write(to: directory.appendingPathComponent("inuse.23458.lock"))
        }
        try fixture.tracker(working: false)
        return fixture
    }

    func testQwenRegistryBindsCurrentProcessAndRejectsReusedPID() throws {
        let home = try temporaryFile().deletingLastPathComponent()
        let registry = home.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: registry, withIntermediateDirectories: true)
        let file = registry.appendingPathComponent("23456.json")
        let now = Date()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        let start = formatter.string(from: now.addingTimeInterval(-10))
        let id = UUID().uuidString.lowercased()
        let cwd = home.appendingPathComponent("project").path
        var record: [String: Any] = [
            "schemaVersion": 1, "pid": 23456, "sessionId": id, "cwd": cwd,
            "qwenVersion": "0.23.0", "startedAt": now.timeIntervalSince1970 * 1000,
        ]
        func read() throws -> QwenSessions.Binding? {
            try JSONSerialization.data(withJSONObject: record).write(to: file)
            return QwenSessions.binding(
                processID: 23456, cwd: cwd, processStartedAt: start, qwenHome: home.path, now: now)
        }
        XCTAssertEqual(try read()?.sessionID, id)
        record["startedAt"] = now.addingTimeInterval(-60).timeIntervalSince1970 * 1000
        XCTAssertNil(try read())
        record["startedAt"] = now.addingTimeInterval(60).timeIntervalSince1970 * 1000
        XCTAssertNil(try read())
        record["startedAt"] = now.timeIntervalSince1970 * 1000
        for invalid in [true, 23456.5, 23455] as [Any] {
            record["pid"] = invalid; XCTAssertNil(try read())
        }
        record["pid"] = 23456
        record["qwenVersion"] = "0.24.0"; XCTAssertNil(try read())
        record["qwenVersion"] = "0.23.0"
        record["schemaVersion"] = true; XCTAssertNil(try read())
        record["schemaVersion"] = 1
        record["sessionId"] = "../other"; XCTAssertNil(try read())
        record["sessionId"] = id
        record["cwd"] = "/other-project"; XCTAssertNil(try read())
        record["cwd"] = cwd
        XCTAssertEqual(try read()?.sessionID, id)
    }

    func testQwenProductionReaderFollowsRegistrySwitchNotNewestChatOrArgv() throws {
        let home = try temporaryFile().deletingLastPathComponent()
        let cwd = home.appendingPathComponent("project").path
        let chats = home.appendingPathComponent("projects/fixture/chats")
        let registry = home.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: chats, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: registry, withIntermediateDirectories: true)
        let first = UUID().uuidString.lowercased(), second = UUID().uuidString.lowercased()
        let now = Date()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        let started = formatter.string(from: now.addingTimeInterval(-10))
        for (id, task) in [(first, "Build project one"), (second, "Fix project two")] {
            let records: [[String: Any]] = [
                ["sessionId": id, "cwd": cwd, "type": "user", "message": ["parts": [["text": task]]]],
                ["sessionId": id, "cwd": cwd, "type": "user", "message": ["parts": [["text": "继续"]]]],
                [
                    "sessionId": id, "cwd": cwd, "type": "assistant",
                    "message": ["parts": [["text": "Historical answer"]]],
                ],
            ]
            var data = Data()
            for item in records { data.append(try JSONSerialization.data(withJSONObject: item)); data.append(10) }
            try data.write(to: chats.appendingPathComponent("\(id).jsonl"))
        }
        func bind(_ id: String) throws {
            try JSONSerialization.data(withJSONObject: [
                "schemaVersion": 1, "pid": 23457, "sessionId": id, "cwd": cwd,
                "qwenVersion": "0.23.0", "startedAt": now.timeIntervalSince1970 * 1000,
            ]).write(to: registry.appendingPathComponent("23457.json"))
        }
        func read(cpu: Double = 0) -> QwenSessions.Info? {
            QwenSessions.info(
                cwd: cwd, args: "qwen --resume \(first)", cpu: cpu,
                runtimeRoot: home.path, qwenHome: home.path, processID: 23457, processStartedAt: started)
        }
        XCTAssertNil(read())
        try bind(first)
        XCTAssertEqual(read()?.sessionID, first)
        XCTAssertEqual(read()?.lastPrompt, "Build project one")
        XCTAssertEqual(read()?.status, .idle)
        XCTAssertEqual(read()?.observation.mode, .processOnly)
        XCTAssertEqual(read(cpu: 20)?.status, .working)
        XCTAssertEqual(read(cpu: 20)?.observation.mode, .processOnly)
        try bind(second)
        XCTAssertEqual(read()?.sessionID, second)
        XCTAssertEqual(read()?.lastPrompt, "Fix project two")
        let unrecorded = UUID().uuidString
        try bind(unrecorded)
        let identityOnly = try XCTUnwrap(read())
        XCTAssertEqual(identityOnly.sessionID, unrecorded)
        XCTAssertEqual(identityOnly.observation.mode, .processOnly)
        XCTAssertEqual(identityOnly.status, .idle)
        XCTAssertNil(identityOnly.transcriptPath)
        XCTAssertNil(identityOnly.lastPrompt, "A new registry identity must not reuse the old resume task")
        XCTAssertNil(identityOnly.lastMessage)
    }

    func testOptInQwenOfficialRegistryContract() throws {
        let env = ProcessInfo.processInfo.environment
        guard let home = env["LOOPFWD_QWEN_CONTRACT_HOME"], let cwd = env["LOOPFWD_QWEN_CONTRACT_CWD"],
            let id = env["LOOPFWD_QWEN_CONTRACT_ID"], let pid = env["LOOPFWD_QWEN_CONTRACT_PID"].flatMap(Int32.init),
            let start = env["LOOPFWD_QWEN_CONTRACT_START"]
        else { throw XCTSkip("Requires the isolated official Qwen registry producer") }
        XCTAssertEqual(
            QwenSessions.binding(processID: pid, cwd: cwd, processStartedAt: start, qwenHome: home)?.sessionID, id)
    }

    func testGeminiRegistryAndCustomHomeDoNotGuessProjectOwnership() throws {
        let fixture = try geminiFixture()
        let directory = fixture.file.deletingLastPathComponent().deletingLastPathComponent()
        XCTAssertEqual(GeminiSessions.projectDir(cwd: fixture.cwd, geminiHome: fixture.home.path), directory.path)
        let marker = directory.appendingPathComponent(".project_root")
        try Data("/another-project".utf8).write(to: marker)
        XCTAssertNil(GeminiSessions.projectDir(cwd: fixture.cwd, geminiHome: fixture.home.path))
        try Data(fixture.cwd.utf8).write(to: marker)
        let registry = fixture.home.appendingPathComponent(".gemini/projects.json")
        try JSONSerialization.data(withJSONObject: ["projects": [fixture.cwd: "../escape"]]).write(to: registry)
        XCTAssertNil(GeminiSessions.projectDir(cwd: fixture.cwd, geminiHome: fixture.home.path))
    }

    func testGeminiSessionIdentityCannotBorrowTheNewestChat() throws {
        let fixture = try geminiFixture()
        XCTAssertNil(GeminiSessions.info(cwd: fixture.cwd, geminiHome: fixture.home.path).sessionID)
        let info = GeminiSessions.info(
            cwd: fixture.cwd, args: "gemini --resume \(fixture.id)", geminiHome: fixture.home.path)
        XCTAssertEqual(info.sessionID, fixture.id)
        XCTAssertEqual(info.lastPrompt, "Build the fixture project")
        XCTAssertEqual(info.turnID, "confirmation")
        XCTAssertEqual(info.model, "gemini-fixture-model")
        XCTAssertEqual(info.lastMessage, "Fixture answer")
        let otherID = UUID().uuidString.lowercased()
        let other = fixture.file.deletingLastPathComponent().appendingPathComponent(
            "session-test-\(otherID.prefix(8)).jsonl")
        let original = try String(contentsOf: fixture.file, encoding: .utf8)
        try Data(
            original.replacingOccurrences(of: fixture.id, with: otherID)
                .replacingOccurrences(of: "Build the fixture project", with: "A different task").utf8
        ).write(to: other)
        let second = GeminiSessions.info(cwd: fixture.cwd, args: "gemini -r \(otherID)", geminiHome: fixture.home.path)
        XCTAssertEqual(second.sessionID, otherID)
        XCTAssertEqual(second.lastPrompt, "A different task")
        XCTAssertNil(
            GeminiSessions.info(cwd: fixture.cwd, args: "gemini --resume latest", geminiHome: fixture.home.path)
                .sessionID)
        XCTAssertNil(
            GeminiSessions.info(cwd: fixture.cwd, args: "gemini --resume \(UUID())", geminiHome: fixture.home.path)
                .sessionID)
        XCTAssertEqual(
            GeminiSessions.info(cwd: fixture.cwd, geminiHome: fixture.home.path, openChatPaths: [other.path]).sessionID,
            otherID)
        XCTAssertNil(
            GeminiSessions.info(
                cwd: fixture.cwd, geminiHome: fixture.home.path, openChatPaths: [other.path, fixture.file.path]
            ).sessionID)
    }

    func testGeminiRecordingReplaysUpdatesRewindsAndCheckpoints() throws {
        let fixture = try geminiFixture()
        func append(_ obj: [String: Any]) throws {
            let handle = try FileHandle(forWritingTo: fixture.file)
            defer { try? handle.close() }
            try handle.seekToEnd()
            var data = try JSONSerialization.data(withJSONObject: obj)
            data.append(10)
            try handle.write(contentsOf: data)
        }
        try append(["id": "answer", "type": "gemini", "content": [["text": "Updated answer"]]])
        XCTAssertEqual(GeminiSessions.recentMessages(path: fixture.file.path).last?.text, "Updated answer")
        try append(["$rewindTo": "confirmation"])
        XCTAssertEqual(
            GeminiSessions.recentMessages(path: fixture.file.path).map(\.text), ["Build the fixture project"])
        try append([
            "$set": ["messages": [["id": "new-goal", "type": "user", "content": "Continue fixing the login issue"]]]
        ])
        XCTAssertEqual(
            GeminiSessions.recentMessages(path: fixture.file.path).map(\.text), ["Continue fixing the login issue"])
        try append(["$rewindTo": "not-present"])
        XCTAssertTrue(GeminiSessions.recentMessages(path: fixture.file.path).isEmpty)
    }

    func testGeminiTornAndOversizedRecordsDoNotExposeSupersededContent() throws {
        let fixture = try geminiFixture()
        let original = try Data(contentsOf: fixture.file)
        var torn = original
        torn.append(contentsOf: "{\"$rewindTo\":".utf8)
        try torn.write(to: fixture.file)
        XCTAssertTrue(GeminiSessions.recentMessages(path: fixture.file.path).isEmpty)
        XCTAssertNil(
            GeminiSessions.info(cwd: fixture.cwd, args: "gemini -r \(fixture.id)", geminiHome: fixture.home.path)
                .sessionID)
        var large = original
        large.append(Data(repeating: 32, count: 2 * 1024 * 1024))
        try large.write(to: fixture.file)
        XCTAssertTrue(GeminiSessions.recentMessages(path: fixture.file.path).isEmpty)
        try original.write(to: fixture.file)
        XCTAssertEqual(
            GeminiSessions.info(cwd: fixture.cwd, args: "gemini -r \(fixture.id)", geminiHome: fixture.home.path)
                .sessionID, fixture.id)
    }

    func testGeminiOfficialMigrationPrefersOnlyTheMatchingJSONLPair() throws {
        let fixture = try geminiFixture()
        let lines = try String(contentsOf: fixture.file, encoding: .utf8).split(separator: "\n")
        var metadata = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any])
        metadata["messages"] = [["id": "legacy", "type": "user", "content": "Old pre-migration task"]]
        let legacy = URL(fileURLWithPath: String(fixture.file.path.dropLast()))
        try JSONSerialization.data(withJSONObject: metadata).write(to: legacy)
        let info = GeminiSessions.info(
            cwd: fixture.cwd, args: "gemini --resume \(fixture.id)", geminiHome: fixture.home.path)
        XCTAssertEqual(info.chatPath, fixture.file.path)
        XCTAssertEqual(info.lastPrompt, "Build the fixture project")
        let intact = try Data(contentsOf: fixture.file)
        try Data("{\"$rewindTo\":".utf8).write(to: fixture.file)
        XCTAssertNil(
            GeminiSessions.info(cwd: fixture.cwd, args: "gemini --resume \(fixture.id)", geminiHome: fixture.home.path)
                .sessionID)
        try intact.write(to: fixture.file)
        let conflicting = fixture.file.deletingLastPathComponent().appendingPathComponent(
            "session-other-\(fixture.id.prefix(8)).jsonl")
        try Data(contentsOf: fixture.file).write(to: conflicting)
        XCTAssertNil(
            GeminiSessions.info(cwd: fixture.cwd, args: "gemini --resume \(fixture.id)", geminiHome: fixture.home.path)
                .sessionID)
    }

    func testOptInGeminiOfficialRecordingContract() throws {
        let env = ProcessInfo.processInfo.environment
        guard let home = env["LOOPFWD_GEMINI_CONTRACT_HOME"], let cwd = env["LOOPFWD_GEMINI_CONTRACT_CWD"],
            let id = env["LOOPFWD_GEMINI_CONTRACT_ID"]
        else { throw XCTSkip("Requires the isolated official Gemini recording producer") }
        let info = GeminiSessions.info(cwd: cwd, args: "gemini --resume \(id)", geminiHome: home)
        XCTAssertEqual(info.sessionID, id, info.reason)
        XCTAssertEqual(info.lastPrompt, "Build an isolated recording fixture")
        XCTAssertEqual(info.lastMessage, "LOOPFWD_RECORDING_ONLY")
        XCTAssertEqual(info.model, "recording-contract-fixture")
        XCTAssertEqual(info.turnID, "fixture-confirmation")
        XCTAssertNotNil(info.updatedAt)
        XCTAssertEqual(GeminiSessions.recentMessages(path: try XCTUnwrap(info.chatPath)).count, 3)
    }

    private func geminiFixture() throws -> (home: URL, cwd: String, file: URL, id: String) {
        let home = try temporaryFile().deletingLastPathComponent()
        let cwd = home.appendingPathComponent("project").path
        let directory = home.appendingPathComponent(".gemini/tmp/project/chats")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let id = UUID().uuidString.lowercased()
        let file = directory.appendingPathComponent("session-fixture-\(id.prefix(8)).jsonl")
        try JSONSerialization.data(withJSONObject: ["projects": [cwd: "project"]])
            .write(to: home.appendingPathComponent(".gemini/projects.json"))
        let hash = SHA256.hash(data: Data(cwd.utf8)).map { String(format: "%02x", $0) }.joined()
        let records: [[String: Any]] = [
            ["sessionId": id, "projectHash": hash, "kind": "main", "lastUpdated": "2026-09-06T05:00:00Z"],
            ["id": "goal", "type": "user", "content": [["text": "Build the fixture project"]]],
            ["id": "confirmation", "type": "user", "content": "继续"],
            [
                "id": "answer", "type": "gemini", "content": [["text": "Fixture answer"]],
                "model": "gemini-fixture-model",
            ],
        ]
        var data = Data()
        for record in records { data.append(try JSONSerialization.data(withJSONObject: record)); data.append(10) }
        try data.write(to: file)
        return (home, cwd, file, id)
    }

    func testMonitoringLabelsLocalizeWithoutChangingProviderNames() {
        let examples = [
            "%d need attention": "%d 个需要处理",
            "Needs your approval": "需要你审批",
            "Approve": "批准",
            "Always Allow": "始终允许",
            "Deny": "拒绝",
            "Evidence": "判断依据",
            "Rollout could not be read or parsed": "无法读取或解析会话记录",
        ]
        for (key, chinese) in examples {
            XCTAssertEqual(L10n.string(key, language: "zh-Hans"), chinese)
            XCTAssertEqual(L10n.string(key, language: "en"), key)
        }
        for name in ["Codex", "OpenCode", "GPT-6 Astra", "自定义任务标题"] {
            XCTAssertEqual(L10n.string(name, language: "zh-Hans"), name)
            XCTAssertEqual(L10n.string(name, language: "en"), name)
        }
    }

    func testHotKeyRegistrationFailureIsNotReportedAsSuccess() {
        XCTAssertNil(HotKeyCenter.registrationIssue(operation: "Open Switcher", status: 0, hasHandle: true))
        XCTAssertEqual(
            HotKeyCenter.registrationIssue(operation: "Open Switcher", status: -9878, hasHandle: false),
            L10n.format("%@ could not be registered (macOS error %d).", L10n.string("Open Switcher"), Int32(-9878)))
        XCTAssertNotNil(HotKeyCenter.registrationIssue(operation: "Open Switcher", status: -9878, hasHandle: true))
        XCTAssertEqual(
            HotKeyCenter.registrationIssue(operation: "Keyboard event handler", status: 0, hasHandle: false),
            L10n.format("macOS did not return a registration handle for %@.", L10n.string("Keyboard event handler")))
    }

    func testSystemNotificationTransportChecksPermissionBeforeSubmission() {
        let request = UNNotificationRequest(
            identifier: "fixture", content: UNMutableNotificationContent(), trigger: nil)
        for status in [UNAuthorizationStatus.notDetermined, .denied, .authorized, .provisional] {
            let completed = expectation(description: "permission \(status.rawValue)")
            var submitted = false
            let transport = SystemNotificationTransport(
                authorization: { completion in completion(status) },
                submit: { _, completion in
                    submitted = true; completion(nil)
                })
            transport.add(request) { error in
                XCTAssertTrue(Thread.isMainThread)
                let allowed = status == .authorized || status == .provisional
                XCTAssertEqual(submitted, allowed)
                XCTAssertEqual(error == nil, allowed)
                completed.fulfill()
            }
            wait(for: [completed], timeout: 2)
        }
    }

    func testSystemNotificationTransportRechecksPermissionAndPropagatesFailure() {
        let request = UNNotificationRequest(
            identifier: "fixture", content: UNMutableNotificationContent(), trigger: nil)
        var permission = UNAuthorizationStatus.denied
        var submissions = 0
        let transport = SystemNotificationTransport(
            authorization: { completion in completion(permission) },
            submit: { _, completion in
                submissions += 1
                completion(NSError(domain: "fixture-submission", code: 7))
            })
        let denied = expectation(description: "denied")
        transport.add(request) { error in
            XCTAssertNotNil(error)
            XCTAssertEqual(submissions, 0)
            denied.fulfill()
        }
        wait(for: [denied], timeout: 2)
        permission = .authorized
        let failed = expectation(description: "submission error")
        transport.add(request) { error in
            XCTAssertEqual((error as NSError?)?.domain, "fixture-submission")
            XCTAssertEqual(submissions, 1)
            failed.fulfill()
        }
        wait(for: [failed], timeout: 2)
    }

    func testProcessClassificationCacheRetainsNilAndInvalidatesChangedInputs() {
        var cache = ProcessClassificationCache()
        var reads = 0
        func detect() -> AgentKind? { reads += 1; return nil }
        XCTAssertNil(cache.classify(pid: 10, command: "system-service", tty: nil, detect: detect))
        XCTAssertNil(cache.classify(pid: 10, command: "system-service", tty: nil, detect: detect))
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(
            cache.classify(pid: 10, command: "codex", tty: nil) {
                reads += 1; return .codex
            }, .codex)
        XCTAssertEqual(reads, 2)
        _ = cache.classify(pid: 10, command: "codex", tty: "ttys001") {
            reads += 1; return .codex
        }
        XCTAssertEqual(reads, 3)
        cache.retain(livePIDs: [])
        _ = cache.classify(pid: 10, command: "codex", tty: "ttys001") {
            reads += 1; return .codex
        }
        XCTAssertEqual(reads, 4)
        let oversized = String(repeating: "x", count: 16 * 1024 + 1)
        for _ in 0..<2 { _ = cache.classify(pid: 10, command: oversized, tty: nil, detect: detect) }
        XCTAssertEqual(reads, 6)
    }

    func testCodexCustomHomesUseVerifiedOpenFilesWithoutGuessingFromHistory() throws {
        let marker = try temporaryFile()
        let root = marker.deletingLastPathComponent().resolvingSymlinksInPath()
        let homeA = root.appendingPathComponent("自定义 Codex A")
        let homeB = root.appendingPathComponent("Codex B")
        func rollout(_ home: URL, id: String) throws -> URL {
            let directory = home.appendingPathComponent("sessions/2026/09/05")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent("rollout-\(id).jsonl")
            let payload: [String: Any] = [
                "type": "session_meta", "payload": ["id": id, "cwd": "/tmp/custom-home-fixture"],
            ]
            var data = try JSONSerialization.data(withJSONObject: payload)
            data.append(10)
            try data.write(to: file)
            return file
        }
        let a = try rollout(homeA, id: "a")
        let b = try rollout(homeB, id: "b")
        let instant = Date(timeIntervalSince1970: 1000)
        let first = CodexSessions.discoverRollout(
            pid: -43, cwd: nil, codexHome: homeA.path, openFilesOutput: "n\(a.path)\n", now: instant)
        XCTAssertEqual(first.mode, .rich)
        let switched = CodexSessions.discoverRollout(
            pid: -43, cwd: nil, codexHome: homeA.path, openFilesOutput: "n\(b.path)\n",
            now: instant.addingTimeInterval(3))
        XCTAssertEqual(switched.path, b.path)
        XCTAssertEqual(switched.mode, .rich)
        let unavailable = CodexSessions.discoverRollout(
            pid: -43, cwd: nil, codexHome: homeA.path, openFilesOutput: "", now: instant.addingTimeInterval(6))
        XCTAssertEqual(unavailable.path, b.path)
        XCTAssertEqual(unavailable.mode, .stale)
        let restored = CodexSessions.discoverRollout(
            pid: -43, cwd: nil, codexHome: homeA.path, openFilesOutput: "n\(b.path)\n",
            now: instant.addingTimeInterval(9))
        XCTAssertEqual(restored.mode, .rich)
        XCTAssertEqual(CodexSessions.openRollouts(from: "p123\nn\(a.path)\nn\(a.path)\n"), [a.path])
        XCTAssertEqual(
            CodexSessions.sessionsDirectory(codexHome: homeA.path), homeA.appendingPathComponent("sessions").path)
        let unmatched = CodexSessions.discoverRollout(
            pid: -41, cwd: "/tmp/custom-home-fixture", codexHome: homeA.path, openFilesOutput: "")
        XCTAssertNil(unmatched.path)
        XCTAssertEqual(unmatched.mode, .processOnly)
        let otherHome = CodexSessions.discoverRollout(
            pid: -43, cwd: "/tmp/custom-home-fixture", codexHome: homeB.path, openFilesOutput: "")
        XCTAssertNil(otherHome.path)
        XCTAssertEqual(otherHome.mode, .processOnly)
        XCTAssertNil(
            CodexSessions.discoverRollout(
                pid: -42, cwd: "/tmp/custom-home-fixture", codexHome: homeA.path,
                openFilesOutput: "n\(a.path)\nn\(b.path)\n"
            ).path)
        let invalid = homeA.appendingPathComponent("rollout-not-codex.jsonl")
        try Data("{\"id\":\"unrelated\"}\n".utf8).write(to: invalid)
        XCTAssertTrue(CodexSessions.openRollouts(from: "n\(invalid.path)\n").isEmpty)
    }

    func testVerifiedCLIThreadSwitchRetiresOnlyTheOldProjection() {
        let now = Date()
        let reducer = AgentLifecycleReducer()
        var first = observedSession(at: now)
        first.processStartedAt = "same-process-start"
        var another = first
        another.id = "codex:another"
        another.processID = 456
        _ = reducer.reduce([first, another], suppressEvents: true, now: now)
        var switched = first
        switched.id = "codex:resumed-thread"
        switched.observation.updatedAt = now.addingTimeInterval(3)
        let result = reducer.reduce([switched, another], suppressEvents: false, now: now.addingTimeInterval(3))
        XCTAssertEqual(Set(result.sessions.map(\.id)), [switched.id, another.id])
        XCTAssertFalse(result.events.contains { $0.kind == .completed || $0.kind == .stopped })
    }

    func testTerminalReturnChecksHelpersAndCoordinatesBeforePromisingExactJump() {
        func resolve(_ app: String, tty: String? = "ttys001", helper: Bool = true) -> ReturnCapability {
            ReturnResolver.terminalCapability(
                app: app, tty: tty, processID: 123, helperAvailable: helper, ttyExists: { $0 == "ttys001" })
        }
        XCTAssertEqual(resolve("tmux"), .exact(label: "tmux"))
        XCTAssertNotNil(resolve("tmux", helper: false).unavailableReason)
        XCTAssertNotNil(resolve("WezTerm", helper: false).unavailableReason)
        XCTAssertNotNil(resolve("Terminal", tty: nil).unavailableReason)
        XCTAssertNotNil(resolve("Terminal", tty: "ttys999").unavailableReason)
        XCTAssertNotNil(resolve("Terminal", tty: "tty/../../null").unavailableReason)
        XCTAssertNotNil(resolve("Untrusted App").unavailableReason)
        XCTAssertEqual(resolve("Warp"), .providerOnly(label: "Warp"))
    }

    func testLabsGatesRepliesWithoutRemovingManagedStop() {
        var agent = observedSession(at: Date())
        agent.codexManagedControl = CodexManagedControl(threadID: "live")
        agent.surfaceID = .codexManaged
        let disabled = agent.effectiveCapabilities(providerControlsEnabled: false, claudeControlsEnabled: false)
        XCTAssertFalse(disabled.contains(.reply))
        XCTAssertTrue(disabled.contains(.stop))
        XCTAssertTrue(
            agent.effectiveCapabilities(providerControlsEnabled: true, claudeControlsEnabled: false).contains(.reply))

        agent = observedSession(at: Date(), kind: .opencode)
        agent.openCodeControl = OpenCodeControl(
            processID: 123, port: 4000, directory: "/tmp/example", sessionID: "live",
            questionRequestID: "question", permission: nil)
        // A historical request cannot re-enable controls after the task resumes.
        XCTAssertFalse(
            agent.effectiveCapabilities(providerControlsEnabled: true, claudeControlsEnabled: false).contains(.reply))
        agent.status = .needsAttention
        XCTAssertTrue(
            agent.effectiveCapabilities(providerControlsEnabled: true, claudeControlsEnabled: false).contains(.reply))
        XCTAssertFalse(
            agent.effectiveCapabilities(providerControlsEnabled: false, claudeControlsEnabled: true).contains(.reply))
    }

    func testProcessTableByteParsingPreservesUnicodeAndSpacedCommands() {
        let output = """
              123   1  0.5 ??  01:23 /Applications/Visual Studio Code.app/Contents/MacOS/Electron 中文项目
              456 123 12.0 ttys001 00:10 /opt/bin/codex 继续修复登录问题
              789 1 nan ?? 00:02 invalid
            malformed row
            """
        let rows = AgentScanner.processRows(output)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].args, "/Applications/Visual Studio Code.app/Contents/MacOS/Electron 中文项目")
        XCTAssertNil(rows[0].tty)
        XCTAssertEqual(rows[1].pid, 456)
        XCTAssertEqual(rows[1].ppid, 123)
        XCTAssertEqual(rows[1].cpu, 12)
        XCTAssertEqual(rows[1].tty, "ttys001")
        XCTAssertEqual(rows[1].elapsed, "00:10")
        XCTAssertEqual(rows[1].args, "/opt/bin/codex 继续修复登录问题")
    }

    func testProcessReadBudgetKeepsOtherProvidersReachableAndResumesUnvisitedPIDs() {
        var schedule = ProviderProcessReadSchedule()
        XCTAssertEqual(schedule.begin([1, 2, 3, 4]), [1, 2, 3, 4])
        XCTAssertTrue(schedule.admit(pid: 1, kind: .codex, budget: 0.8))
        schedule.record(kind: .codex, duration: 0.9)
        XCTAssertFalse(schedule.admit(pid: 2, kind: .codex, budget: 0.8))
        XCTAssertTrue(schedule.admit(pid: 3, kind: .claude, budget: 0.8))
        schedule.record(kind: .claude, duration: 0.1)
        XCTAssertFalse(schedule.admit(pid: 4, kind: .codex, budget: 0.8))
        XCTAssertEqual(schedule.begin([1, 2, 3, 4, 5]), [2, 4, 1, 3, 5])
        XCTAssertTrue(schedule.admit(pid: 2, kind: .codex, budget: 0.8))
        XCTAssertFalse(schedule.admit(pid: 2, kind: .codex, budget: 0.8))
        schedule.record(kind: .codex, duration: 0.8)
        XCTAssertFalse(schedule.admit(pid: 4, kind: .codex, budget: 0.8))
        // A disappeared PID is removed; adding new processes does not push
        // the oldest unvisited process to the back of the queue.
        XCTAssertEqual(schedule.begin([1, 3, 4, 5, 6]), [4, 1, 3, 5, 6])
        XCTAssertTrue(schedule.admit(pid: 4, kind: .codex, budget: 0.8))
        XCTAssertFalse(schedule.admit(pid: 99, kind: .codex, budget: 0.8))
        XCTAssertEqual(schedule.begin([]), [])
    }

    func testDeferredReadDoesNotBecomeSuccessfulEmptyOrRefreshSuccessTime() {
        let monitor = AgentMonitor()
        let now = Date()
        var result = AgentScanResult(sessions: [], providerDurations: [:], providerCacheHits: [:])
        let empty = ProviderReadResult.read([], source: "fixture")
        result.readerResults[.codexCLI] = empty
        monitor.applyScanDiagnostics(result, startedAt: now, completedAt: now)
        XCTAssertEqual(monitor.surfaceDiagnostics[.codexCLI]?.lastSuccessfulAt, now)
        XCTAssertEqual(monitor.providerDiagnostics[.codex]?.lastSuccessfulAt, now)
        let deferredRead = ProviderReadResult(
            outcome: .partial, source: "CLI process batch", sessions: [], reason: "Scan incomplete")
        result.readerResults[.codexCLI] = empty.merging(deferredRead)
        result.readerResults[.codexDesktop] = .read([], source: "Other healthy surface")
        monitor.applyScanDiagnostics(result, startedAt: now, completedAt: now.addingTimeInterval(2))
        XCTAssertEqual(monitor.surfaceDiagnostics[.codexCLI]?.outcome, "partial")
        XCTAssertEqual(monitor.surfaceDiagnostics[.codexCLI]?.lastSuccessfulAt, now)
        XCTAssertTrue(monitor.hasDataFailure)
        XCTAssertEqual(monitor.providerDiagnostics[.codex]?.outcome, "partial")
        XCTAssertEqual(monitor.providerDiagnostics[.codex]?.lastSuccessfulAt, now)
        XCTAssertNotNil(monitor.providerDiagnostics[.codex]?.errorCategory)
    }

    func testDiagnosticTicksDoNotInvalidateTaskViewsButHealthChangesDo() {
        let monitor = AgentMonitor()
        var taskChanges = 0
        var diagnosticChanges = 0
        let tasks = monitor.objectWillChange.sink { taskChanges += 1 }
        let diagnostics = monitor.diagnosticsUpdates.objectWillChange.sink { diagnosticChanges += 1 }
        defer { tasks.cancel(); diagnostics.cancel() }
        let now = Date()
        var result = AgentScanResult(sessions: [], providerDurations: [:], providerCacheHits: [:])
        monitor.applyScanDiagnostics(result, startedAt: now, completedAt: now.addingTimeInterval(0.1))
        monitor.applyScanDiagnostics(result, startedAt: now, completedAt: now.addingTimeInterval(0.2))
        XCTAssertEqual(taskChanges, 0)
        XCTAssertEqual(diagnosticChanges, 2)
        result.processScanSucceeded = false
        monitor.applyScanDiagnostics(result, startedAt: now, completedAt: now)
        XCTAssertEqual(taskChanges, 1)
        XCTAssertTrue(monitor.hasDataFailure)
        monitor.applyScanDiagnostics(result, startedAt: now, completedAt: now)
        XCTAssertEqual(taskChanges, 1)
        result.processScanSucceeded = true
        monitor.applyScanDiagnostics(result, startedAt: now, completedAt: now)
        XCTAssertEqual(taskChanges, 2)
        XCTAssertFalse(monitor.hasDataFailure)
    }

    func testClaudeProductionRegistryDistinguishesEmptyCorruptAndMissing() throws {
        let marker = try temporaryFile()
        let root = marker.deletingLastPathComponent().appendingPathComponent("claude")
        XCTAssertEqual(ClaudeSessions.readRegistry(configDirs: [root.path]).outcome, .failed)
        let directory = root.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        XCTAssertEqual(ClaudeSessions.readRegistry(configDirs: [root.path]).outcome, .empty)
        try Data("corrupt".utf8).write(to: directory.appendingPathComponent("s.json"))
        XCTAssertEqual(ClaudeSessions.readRegistry(configDirs: [root.path]).outcome, .failed)
        try Data(#"{"pid":123,"sessionId":"fixture","cwd":"/tmp/demo","status":"busy"}"#.utf8)
            .write(to: directory.appendingPathComponent("s.json"))
        let result = ClaudeSessions.readRegistry(configDirs: [root.path])
        XCTAssertEqual(result.outcome, .success)
        XCTAssertNotNil(result.sessions[123]?.statusUpdatedAt)
    }

    func testClaudeRegistryRejectsTruncatedPrefixesAndInvalidIdentities() throws {
        let marker = try temporaryFile()
        let root = marker.deletingLastPathComponent().appendingPathComponent("claude-bounds")
        let directory = root.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("session.json")
        let valid: [String: Any] = ["pid": 123, "sessionId": "fixture-session", "cwd": "/tmp/demo", "status": "busy"]
        let validData = try JSONSerialization.data(withJSONObject: valid)
        // The first 256 KiB is independently valid JSON; the complete file is
        // not. Parsing only that prefix used to incorrectly report success.
        var oversized = validData
        oversized.append(Data(repeating: 32, count: 256 * 1024 - validData.count))
        oversized.append(Data("invalid suffix".utf8))
        try oversized.write(to: file)
        XCTAssertEqual(ClaudeSessions.readRegistry(configDirs: [root.path]).outcome, .failed)

        for invalidPID: Any in [true, 123.5, 4_294_967_419, -1, 0] {
            var entry = valid
            entry["pid"] = invalidPID
            try JSONSerialization.data(withJSONObject: entry).write(to: file)
            XCTAssertTrue(ClaudeSessions.readRegistry(configDirs: [root.path]).sessions.isEmpty, "\(invalidPID)")
        }
        for invalidID in ["", ".", "..", "../outside", "folder/session", "folder\\session", "nul\0suffix"] {
            var entry = valid
            entry["sessionId"] = invalidID
            try JSONSerialization.data(withJSONObject: entry).write(to: file)
            XCTAssertEqual(ClaudeSessions.readRegistry(configDirs: [root.path]).outcome, .failed, invalidID)
        }

        try validData.write(to: file)
        let recovered = ClaudeSessions.readRegistry(configDirs: [root.path])
        XCTAssertEqual(recovered.outcome, .success)
        XCTAssertEqual(recovered.sessions[123]?.sessionId, "fixture-session")
        try oversized.write(to: directory.appendingPathComponent("bad.json"))
        let partial = ClaudeSessions.readRegistry(configDirs: [root.path])
        XCTAssertEqual(partial.outcome, .partial)
        XCTAssertNotNil(partial.sessions[123])
    }

    func testOpenCodeProductionDatabaseDistinguishesEmptyMissingAndIncompatible() throws {
        let file = try temporaryFile()
        XCTAssertEqual(OpenCodeDesktopSessions.read(hideIdleAfterMinutes: 0, databasePath: file.path).outcome, .failed)
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(file.path, &database), SQLITE_OK)
        defer { sqlite3_close(database) }
        XCTAssertEqual(
            OpenCodeDesktopSessions.read(hideIdleAfterMinutes: 0, databasePath: file.path).outcome, .incompatible)
        let schema = """
            CREATE TABLE session(id TEXT, directory TEXT, title TEXT, model TEXT, time_created INTEGER, time_updated INTEGER, parent_id TEXT, time_archived INTEGER);
            CREATE TABLE message(id TEXT, session_id TEXT, data TEXT);
            CREATE TABLE part(message_id TEXT, session_id TEXT, data TEXT, time_created INTEGER, time_updated INTEGER);
            CREATE TABLE todo(session_id TEXT, content TEXT, status TEXT, position INTEGER);
            """
        XCTAssertEqual(sqlite3_exec(database, schema, nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(OpenCodeDesktopSessions.read(hideIdleAfterMinutes: 0, databasePath: file.path).outcome, .empty)
        XCTAssertEqual(
            sqlite3_exec(
                database,
                """
                INSERT INTO session VALUES ('live', '/tmp/demo', 'Demo', NULL, 1, 1700000000000, NULL, NULL);
                INSERT INTO message VALUES ('m1', 'live', '{"role":"user","time":{"created":2}}');
                """, nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(
            sqlite3_exec(
                database,
                "UPDATE session SET time_updated=\(Int64(Date().timeIntervalSince1970 * 1000))", nil, nil, nil),
            SQLITE_OK)
        let healthy = OpenCodeDesktopSessions.read(hideIdleAfterMinutes: 1, databasePath: file.path)
        XCTAssertEqual(healthy.sessions.first?.status, .working)
        XCTAssertEqual(healthy.outcome, .success)
        let reducer = AgentLifecycleReducer()
        let now = Date()
        _ = reducer.reduce(healthy.sessions, suppressEvents: true, now: now)
        XCTAssertEqual(sqlite3_exec(database, "UPDATE message SET data='broken JSON'", nil, nil, nil), SQLITE_OK)
        let broken = OpenCodeDesktopSessions.read(hideIdleAfterMinutes: 1, databasePath: file.path)
        XCTAssertFalse(broken.successful)
        XCTAssertEqual(broken.sessions.first?.observation.mode, .stale)
        let retained = reducer.reduce(broken.sessions, suppressEvents: false, now: now.addingTimeInterval(1))
        XCTAssertEqual(retained.sessions.first?.status, .working)
        XCTAssertTrue(retained.events.isEmpty)
        XCTAssertEqual(
            sqlite3_exec(
                database,
                "UPDATE message SET data='{\"role\":\"user\",\"time\":{\"created\":3}}'", nil, nil, nil), SQLITE_OK)
        XCTAssertTrue(OpenCodeDesktopSessions.read(hideIdleAfterMinutes: 1, databasePath: file.path).successful)
    }

    func testSupportRegistryHasNoProviderProfileRecursion() {
        for kind in AgentKind.allCases {
            XCTAssertEqual(kind.supportTier, SupportRegistry.tier(kind))
            XCTAssertEqual(IntegrationProfiles.profile(for: .process, kind: kind).supportTier, .experimental)
        }
        XCTAssertEqual(SupportRegistry.tier(.codexDesktop), .previewTested)
        XCTAssertEqual(SupportRegistry.tier(.openCodeTUI), .previewTested)
        XCTAssertEqual(SupportRegistry.tier(.copilotCLI), .previewTested)
        // Real Desktop tests do not verify another surface or grant control.
        XCTAssertEqual(SupportRegistry.tier(.codexCLI), .experimental)
        XCTAssertEqual(SupportRegistry.tier(.codexManaged), .experimental)
        XCTAssertEqual(SupportRegistry.tier(.openCodeDesktop), .experimental)
    }

    func testPreviewScopeAndPreferencesCannotReenableDeferredReaders() throws {
        XCTAssertEqual(
            SupportRegistry.shippedKinds, [.codex, .opencode, .copilot, .claude, .gemini, .qwen, .kimi, .grok])
        XCTAssertEqual(SupportRegistry.deferredKinds, [.cursorAgent, .deepseek, .mistral, .workbuddy])
        let name = "LoopFwd-preview-scope-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let optional: Set<AgentKind> = [.claude, .gemini, .qwen, .kimi, .grok]
        XCTAssertEqual(Pref.disabledKinds(in: defaults), SupportRegistry.deferredKinds.union(optional))
        defaults.set("", forKey: Pref.disabledAgents)  // Older version enabled every brand.
        XCTAssertEqual(Pref.disabledKinds(in: defaults), SupportRegistry.deferredKinds)
        XCTAssertEqual(defaults.string(forKey: Pref.disabledAgents), "")
        defaults.set("codex,kimi,unknown-provider", forKey: Pref.disabledAgents)
        XCTAssertEqual(Pref.disabledKinds(in: defaults), SupportRegistry.deferredKinds.union([.codex, .kimi]))
        XCTAssertEqual(defaults.string(forKey: Pref.disabledAgents), "codex,kimi,unknown-provider")
    }

    func testProcessDiscoveryRecognizesDSHButNotNamesInsideAnotherProgram() {
        XCTAssertEqual(AgentScanner.detect(args: "/opt/bin/dsh web"), .deepseek)
        XCTAssertEqual(AgentScanner.detect(args: "/opt/bin/node /opt/bin/dsh web"), .deepseek)
        XCTAssertEqual(AgentScanner.detect(args: "/opt/bin/uv tool run kimi"), .kimi)
        XCTAssertNil(AgentScanner.detect(args: "/opt/bin/node -e 'console.log(\"claude\")'"))
        XCTAssertNil(AgentScanner.detect(args: "/opt/bin/node /tmp/demo.js claude"))
        XCTAssertNil(AgentScanner.detect(args: "/bin/echo " + String(repeating: "codex ", count: 10000)))
        XCTAssertNil(AgentScanner.detect(args: "/Applications/Claude.app/Contents/MacOS/Claude"))
    }
    private final class NotificationProbe: AgentNotificationTransport {
        var requests: [UNNotificationRequest] = []
        var callbacks: [(Error?) -> Void] = []
        var removed: [String] = []
        func add(_ request: UNNotificationRequest, completion: @escaping (Error?) -> Void) {
            requests.append(request)
            callbacks.append(completion)
        }
        func remove(_ identifiers: [String]) { removed += identifiers }
    }

    @MainActor
    func testNotificationReplacementAggregationRetryAndLateWithdrawal() {
        let domain = "LoopFwd-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(true, forKey: Pref.notifyOnAttention)
        let probe = NotificationProbe()
        var sounds = 0
        let router = AgentNotificationRouter(
            defaults: defaults, transport: probe,
            isViewing: { _ in false }, playSound: { _ in sounds += 1 })
        func event(_ id: String, kind: AgentLifecycleEventKind = .needsAttention) -> AgentLifecycleEvent {
            var session = observedSession(at: Date(timeIntervalSince1970: 1000))
            session.id = id
            return .init(kind: kind, session: session, occurredAt: Date())
        }
        router.route(event("a"))
        router.route(event("a", kind: .resumed))
        router.flush(.needsAttention)
        XCTAssertTrue(probe.requests.isEmpty)
        XCTAssertEqual(sounds, 0)

        router.route(event("a"))
        router.route(event("b"))
        router.flush(.needsAttention)
        XCTAssertEqual(probe.requests.count, 1)
        XCTAssertEqual(sounds, 1)
        probe.callbacks[0](nil)
        router.route(event("c"))
        router.flush(.needsAttention)
        XCTAssertEqual(probe.requests.last?.content.userInfo["sessionIDs"] as? [String], ["a", "b", "c"])
        probe.callbacks[1](nil)
        router.markHandled(sessionID: "a")
        XCTAssertEqual(probe.requests.last?.content.userInfo["sessionIDs"] as? [String], ["b", "c"])
        probe.callbacks[2](nil)
        router.markHandled(sessionID: "b")
        let one = probe.requests.last!
        XCTAssertEqual(one.content.userInfo["sessionID"] as? String, "c")
        router.markHandled(sessionID: "c")
        let removals = probe.removed.count
        probe.callbacks[3](nil)  // late add after explicit withdrawal
        XCTAssertGreaterThan(probe.removed.count, removals)

        router.route(event("failed-delivery"))
        router.flush(.needsAttention)
        let firstAttempt = probe.requests.count
        probe.callbacks.last?(NSError(domain: "fixture", code: 1))
        let soundsBeforeRetry = sounds
        router.route(event("failed-delivery"))
        router.flush(.needsAttention)
        XCTAssertEqual(probe.requests.count, firstAttempt + 1)
        XCTAssertEqual(sounds, soundsBeforeRetry)
        probe.callbacks.last?(nil)
        router.route(event("failed-delivery"))
        router.flush(.needsAttention)
        XCTAssertEqual(probe.requests.count, firstAttempt + 1)
    }

    @MainActor
    func testExactViewingSuppressesSoundAndBannerTogether() {
        let domain = "LoopFwd-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(true, forKey: Pref.smartSuppression)
        defaults.set(true, forKey: Pref.notifyOnComplete)
        let probe = NotificationProbe()
        var sounds = 0
        let router = AgentNotificationRouter(
            defaults: defaults, transport: probe,
            isViewing: { _ in true }, playSound: { _ in sounds += 1 })
        router.route(.init(kind: .completed, session: observedSession(at: Date()), occurredAt: Date()))
        router.flush(.completed)
        XCTAssertEqual(sounds, 0)
        XCTAssertTrue(probe.requests.isEmpty)
    }

    @MainActor
    func testLateVisibilityCannotResurrectHandledOrDisabledNotifications() {
        let domain = "LoopFwd-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(true, forKey: Pref.smartSuppression)
        defaults.set(true, forKey: Pref.notifyOnAttention)
        let probe = NotificationProbe()
        var completions: [(Set<String>) -> Void] = []
        var sounds = 0
        let router = AgentNotificationRouter(
            defaults: defaults, transport: probe,
            checkVisibility: { _, completion in completions.append(completion) },
            playSound: { _ in sounds += 1 })
        func event(_ id: String, kind: AgentLifecycleEventKind = .needsAttention) -> AgentLifecycleEvent {
            var session = observedSession(at: Date(timeIntervalSince1970: 1000))
            session.id = id
            return .init(kind: kind, session: session, occurredAt: Date())
        }
        router.route(event("a"))
        router.flush(.needsAttention)
        XCTAssertEqual(completions.count, 1)
        XCTAssertTrue(probe.requests.isEmpty)
        router.route(event("a", kind: .resumed))
        router.route(event("b"))
        router.flush(.needsAttention)
        XCTAssertEqual(completions.count, 1)  // no second simultaneous probe
        completions[0]([])
        XCTAssertTrue(probe.requests.isEmpty)
        XCTAssertEqual(completions.count, 2)
        defaults.set(false, forKey: Pref.notifyOnAttention)
        completions[1]([])
        XCTAssertEqual(sounds, 0)
        XCTAssertTrue(probe.requests.isEmpty)

        defaults.set(true, forKey: Pref.notifyOnAttention)
        router.route(event("c"))
        defaults.set(false, forKey: Pref.notifyOnAttention)
        router.flush(.needsAttention)
        XCTAssertEqual(completions.count, 2)  // disabled before the probe
        defaults.set(true, forKey: Pref.notifyOnAttention)
        router.route(event("d"))
        router.flush(.needsAttention)
        completions[2](["d"])
        XCTAssertEqual(sounds, 0)
        XCTAssertTrue(probe.requests.isEmpty)
        router.route(event("e"))
        router.flush(.needsAttention)
        completions[3]([])
        XCTAssertEqual(sounds, 1)
        XCTAssertEqual(probe.requests.count, 1)
        XCTAssertEqual(probe.requests[0].content.userInfo["sessionID"] as? String, "e")
    }

    func testRetainedNotificationDoesNotKeepTranscriptOrControlPayloads() {
        var session = observedSession(at: Date(timeIntervalSince1970: 1000))
        session.title = String(repeating: "项目", count: 2000)
        session.taskAnchor = String(repeating: "目标", count: 2000)
        session.lastPrompt = String(repeating: "private prompt ", count: 10000)
        session.lastMessage = String(repeating: "tool output ", count: 10000)
        session.activity = "private activity"
        session.plan = String(repeating: "private plan ", count: 10000)
        session.cwd = "/tmp/private-project"
        session.transcriptPath = "/tmp/private-rollout.jsonl"
        session.todos = [.init(content: "private todo", status: "in_progress")]
        session.codexManagedControl = .init(threadID: "private-control")
        session.returnTarget = .terminal(app: "Terminal", tty: "ttys001", processID: 42)
        let event = AgentLifecycleEvent(kind: .completed, session: session, occurredAt: Date())
        let record = AgentNotificationRecord(event)
        XCTAssertEqual(record.deduplicationKey, event.deduplicationKey)
        XCTAssertEqual(record.session.id, session.id)
        XCTAssertEqual(record.session.returnTarget, session.returnTarget)
        XCTAssertEqual(record.session.title?.count, 80)
        XCTAssertEqual(record.session.currentTaskSummary?.count, 180)
        XCTAssertNil(record.session.lastPrompt)
        XCTAssertNil(record.session.lastMessage)
        XCTAssertNil(record.session.activity)
        XCTAssertNil(record.session.plan)
        XCTAssertNil(record.session.cwd)
        XCTAssertNil(record.session.transcriptPath)
        XCTAssertNil(record.session.codexManagedControl)
        XCTAssertTrue(record.session.todos.isEmpty)
    }

    func testNotificationSummaryHasAnExplicitTextLimit() {
        var session = observedSession(at: Date())
        session.title = String(repeating: "长标题", count: 2000)
        session.lastPrompt = nil
        let event = AgentLifecycleEvent(kind: .failed, session: session, occurredAt: Date())
        XCTAssertLessThanOrEqual(AgentNotificationPolicy.body(for: event).count, 200)
    }

    func testOpenCodeProductionReadRejectsIncompatibleVersionBeforeReadingSessions() async {
        for version: String? in [nil, "", "1.18.29-beta.1", "1.19.0", "2.0.0", "1.18.01", "1.18.２９"] {
            var paths: [String] = []
            let result = await OpenCodeSessions.read(
                port: 4096, processID: 99990, expectedDirectory: nil,
                transport: { path, _, _ in
                    paths.append(path)
                    var health: [String: Any] = ["healthy": true]
                    health["version"] = version
                    return health
                })
            XCTAssertEqual(result.outcome, .incompatible, "Version: \(version ?? "missing")")
            XCTAssertTrue(result.infos.isEmpty)
            XCTAssertEqual(paths, ["/global/health"])
        }
        for version in ["1.18.0", "1.18.9", "1.18.29"] {
            XCTAssertTrue(OpenCodeSessions.supportsVersion(version))
        }
        let incompatible = ProviderReadResult(
            outcome: .incompatible, source: "OpenCode loopback API", sessions: [], reason: "Unsupported API")
        XCTAssertEqual(incompatible.merging(.read([], source: incompatible.source)).outcome, .incompatible)
    }

    /// Opt-in against an isolated real OpenCode server with no sessions. This
    /// verifies transport and discovery, not inference or the task lifecycle.
    func testOptInLiveOpenCodeEmptyService() async throws {
        guard let rawPort = ProcessInfo.processInfo.environment["LOOPFWD_LIVE_OPENCODE_PORT"],
            let port = Int(rawPort),
            let rawPID = ProcessInfo.processInfo.environment["LOOPFWD_LIVE_OPENCODE_PID"],
            let pid = Int32(rawPID),
            let directory = ProcessInfo.processInfo.environment["LOOPFWD_LIVE_OPENCODE_DIRECTORY"]
        else { throw XCTSkip("Set LOOPFWD_LIVE_OPENCODE_* for an isolated real service check") }
        XCTAssertTrue(OpenCodeSessions.listeningPorts(pid: pid).contains(port))
        let result = await OpenCodeSessions.read(pid: pid, expectedDirectory: directory)
        XCTAssertEqual(result.outcome, .empty, result.reason ?? "")
        XCTAssertTrue(result.infos.isEmpty)
    }

    func testOpenCodeProductionReadFindsAllActiveIDsBeyondHistoryWindow() async {
        let statuses = Dictionary(uniqueKeysWithValues: (0..<12).map { ("s\($0)", ["type": "busy"]) })
        func metadata(_ id: String) -> [String: Any] {
            [
                "id": id, "title": "Task \(id)", "directory": "/tmp/demo",
                "time": ["updated": 1_700_000_000_000.0],
            ]
        }
        let read: OpenCodeSessions.ReadTransport = { path, _, _ in
            switch path {
            case "/global/health": return ["healthy": true, "version": "1.18.9"]
            case "/path": return ["directory": "/tmp/demo"]
            case "/session/status": return statuses
            case "/session": return [metadata("s0"), metadata("s1")]
            case "/question", "/permission": return []
            default:
                if path.hasSuffix("/message") || path.hasSuffix("/todo") { return [] }
                return metadata(String(path.dropFirst("/session/".count)))
            }
        }
        let result = await OpenCodeSessions.read(
            port: 4096, processID: 99991,
            expectedDirectory: "/tmp/demo", transport: read)
        XCTAssertEqual(result.outcome, .success)
        XCTAssertEqual(Set(result.infos.map(\.control.sessionID)), Set(statuses.keys))
        XCTAssertTrue(result.infos.allSatisfy { $0.status == .working })
        let failed = await OpenCodeSessions.read(
            port: 4096, processID: 99991,
            expectedDirectory: "/tmp/demo",
            transport: { path, port, query in
                if path == "/session/status" { return nil }
                return await read(path, port, query)
            })
        XCTAssertEqual(failed.outcome, .failed)
        XCTAssertTrue(failed.infos.isEmpty)
    }

    func testOpenCodeProductionReadObservesExplicitResultsAfterBusyDisappears() async throws {
        let pid: Int32 = 99989
        defer { OpenCodeSessions.prune(livePids: []) }
        let now = Date().timeIntervalSince1970 * 1000
        var busy = true
        var revision = now
        var broken = false
        var message: [String: Any] = ["id": "a1", "role": "assistant", "parentID": "u1"]
        let reader: OpenCodeSessions.ReadTransport = { path, _, _ in
            switch path {
            case "/global/health": return ["healthy": true, "version": "1.18.29"]
            case "/path": return ["directory": "/tmp/demo"]
            case "/session/status": return busy ? ["s1": ["type": "busy"]] : [:]
            case "/session":
                return [["id": "s1", "title": "Test", "directory": "/tmp/demo", "time": ["updated": revision]]]
            case "/question", "/permission", "/session/s1/todo": return []
            case "/session/s1/message":
                if broken { return nil }
                return [
                    ["info": ["id": "u1", "role": "user"], "parts": [["type": "text", "text": "Run test"]]],
                    ["info": message, "parts": []],
                ]
            default: return nil
            }
        }
        func read() async -> OpenCodeSessions.ReadBatch {
            await OpenCodeSessions.read(port: 4098, processID: pid, expectedDirectory: "/tmp/demo", transport: reader)
        }
        let working = await read()
        XCTAssertEqual(working.infos.first?.status, .working)
        busy = false
        message["finish"] = "stop"
        message["time"] = ["created": now - 10, "completed": now]
        let completed = await read()
        XCTAssertEqual(completed.infos.first?.status, .completed)
        XCTAssertEqual(completed.infos.first?.turnID, "u1")
        XCTAssertEqual(completed.infos.first?.updatedAt, now)
        // A new header revision plus unavailable messages cannot reuse success.
        revision += 1
        broken = true
        let missing = await read()
        XCTAssertEqual(missing.outcome, .partial)
        XCTAssertTrue(missing.infos.isEmpty)
        broken = false
        message["error"] = ["name": "MessageAbortedError"]
        let stopped = await read()
        XCTAssertEqual(stopped.infos.first?.status, .stopped)
        message["error"] = ["name": "APIError"]
        let failed = await read()
        XCTAssertEqual(failed.infos.first?.status, .failed)
        busy = true
        let resumed = await read()
        XCTAssertEqual(resumed.infos.first?.status, .working)
    }

    func testOpenCodeResultRequiresCurrentTurnAndExplicitSuccess() {
        let now = Date().timeIntervalSince1970 * 1000
        let user: [String: Any] = ["info": ["id": "u1", "role": "user"], "parts": []]
        var info: [String: Any] = [
            "id": "a1", "role": "assistant", "parentID": "u1",
            "finish": "stop", "time": ["completed": now],
        ]
        func outcome() -> AgentStatus? {
            OpenCodeSessions.conversationInfo([user, ["info": info, "parts": []]]).outcome
        }
        XCTAssertEqual(outcome(), .completed)
        info["finish"] = "tool-calls"
        XCTAssertNil(outcome())
        info["finish"] = "length"
        XCTAssertNil(outcome())
        info["finish"] = "stop"
        info["parentID"] = "old-user"
        XCTAssertNil(outcome())
        info["parentID"] = "u1"
        info["summary"] = true
        XCTAssertNil(outcome())
        info["summary"] = false
        info["time"] = ["completed": now + 60_000]
        XCTAssertNil(outcome())
        info["time"] = ["completed": now]
        let newUser: [String: Any] = ["info": ["id": "u2", "role": "user"], "parts": []]
        XCTAssertNil(OpenCodeSessions.conversationInfo([user, ["info": info, "parts": []], newUser]).outcome)
        XCTAssertEqual(
            OpenCodeSessions.status(
                remoteStatus: "busy", hasAttention: false, hasContent: true, age: 0, outcome: .completed),
            .working)
    }

    func testOptInLiveOpenCodeSession() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let rawPID = env["LOOPFWD_LIVE_OPENCODE_PID"], let pid = Int32(rawPID),
            let directory = env["LOOPFWD_LIVE_OPENCODE_DIRECTORY"],
            let id = env["LOOPFWD_LIVE_OPENCODE_SESSION"],
            let expected = env["LOOPFWD_LIVE_OPENCODE_STATUS"]
        else { throw XCTSkip("Set LOOPFWD_LIVE_OPENCODE_SESSION and STATUS for a real session check") }
        let batch = await OpenCodeSessions.read(pid: pid, expectedDirectory: directory)
        let info = try XCTUnwrap(batch.infos.first { $0.control.sessionID == id }, batch.reason ?? "Session absent")
        XCTAssertEqual(String(describing: info.status), expected)
        XCTAssertNotNil(info.turnID)
        let scan = await AgentScanner.findAgents()
        XCTAssertTrue(scan.processScanSucceeded)
        let matches = scan.sessions.filter { $0.id == "opencode:\(id)" }
        XCTAssertEqual(matches.count, 1, "A real session must reach the complete scanner exactly once")
        let projected = try XCTUnwrap(matches.first)
        XCTAssertEqual(projected.processID, pid)
        XCTAssertEqual(projected.surfaceID, .openCodeTUI)
        XCTAssertEqual(projected.observation.mode, .rich)
        XCTAssertEqual(String(describing: projected.status), expected)
        if let requestID = env["LOOPFWD_LIVE_OPENCODE_QUESTION"] {
            XCTAssertEqual(projected.status, .needsAttention)
            XCTAssertEqual(projected.openCodeControl?.questionRequestID, requestID)
            XCTAssertNotNil(projected.pendingQuestion)
            XCTAssertEqual(projected.pendingQuestion?.options, ["Alpha", "Beta"])
        }
    }

    func testGUIParentDoesNotHideRealAgentProcesses() {
        XCTAssertNil(AgentScanner.detect(args: "/fixture/Codex Computer Use.app/Contents/MacOS/SkyComputerUseService"))
        XCTAssertNil(AgentScanner.detect(args: "/fixture/Cursor Preview.app/Contents/MacOS/Cursor", tty: "ttys001"))
        XCTAssertEqual(
            AgentScanner.detect(args: "/fixture/Open AI.app/Contents/Resources/codex", tty: "ttys001"), .codex)
        XCTAssertEqual(AgentScanner.detect(args: "/usr/bin/codex exec /fixture/Test.app/Contents/MacOS/Test"), .codex)
        let parent = "/Applications/ChatGPT.app/Contents/Resources/codex"
        for child in ["/tmp/tools/opencode serve --port 4096", "opencode serve", "node /tmp/copilot"] {
            XCTAssertFalse(ProcessNaming.isGUIHelper(tty: nil, childCommand: child, parentCommand: parent))
        }
        let editor = "/Applications/Cursor.app/Contents/MacOS/Cursor"
        for helper in ["Cursor Helper: shared-process", "Cursor Helper (Plugin): extension-host"] {
            XCTAssertTrue(ProcessNaming.isGUIHelper(tty: nil, childCommand: helper, parentCommand: editor))
            XCTAssertFalse(ProcessNaming.isGUIHelper(tty: "ttys001", childCommand: helper, parentCommand: editor))
            XCTAssertFalse(ProcessNaming.isGUIHelper(tty: nil, childCommand: helper, parentCommand: "/bin/zsh"))
        }
        XCTAssertFalse(ProcessNaming.isGUIHelper(tty: nil, childCommand: "cursor HelperWanted", parentCommand: editor))
    }

    /// Opt-in through the complete process scanner, not an injected transport.
    /// The caller creates only synthetic sessions on an isolated real server.
    func testOptInLiveOpenCodeConcurrentSessions() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let pid = env["LOOPFWD_LIVE_OPENCODE_PID"].flatMap(Int32.init),
            let rawIDs = env["LOOPFWD_LIVE_OPENCODE_SESSIONS"],
            let expected = env["LOOPFWD_LIVE_OPENCODE_STATUS"]
        else { throw XCTSkip("Requires two real isolated OpenCode sessions and their expected state") }
        let ids = Set(rawIDs.split(separator: ",").map { "opencode:\($0)" })
        XCTAssertGreaterThanOrEqual(ids.count, 2)
        let scan = await AgentScanner.findAgents()
        XCTAssertTrue(scan.processScanSucceeded)
        let sessions = scan.sessions.filter { ids.contains($0.id) }
        let observed = scan.sessions.filter { $0.kind == .opencode }.map {
            "\($0.id):\($0.surfaceID):\($0.status):\($0.observation.mode):\($0.observation.reason ?? "")"
        }.joined(separator: "; ")
        XCTAssertEqual(Set(sessions.map(\.id)), ids, "OpenCode projections: \(observed)")
        XCTAssertEqual(sessions.count, ids.count, "Each stable session must have only one projection")
        for session in sessions {
            XCTAssertEqual(session.processID, pid)
            XCTAssertEqual(session.surfaceID, .openCodeTUI)
            XCTAssertEqual(session.observation.mode, .rich)
            XCTAssertEqual(String(describing: session.status), expected)
            XCTAssertNotNil(session.turnID)
            XCTAssertTrue(session.lastPrompt?.contains("LoopFwd concurrent acceptance") == true)
        }
    }

    func testOpenCodeDiscoveryContinuesAcrossBudgetsAndPrunesRecycledProcesses() async {
        let processID: Int32 = 99992
        let statuses = Dictionary(uniqueKeysWithValues: (0..<12).map { ("s\($0)", ["type": "busy"]) })
        var metadataCalls = 0
        var failOne = true
        let read: OpenCodeSessions.ReadTransport = { path, _, _ in
            switch path {
            case "/global/health": return ["healthy": true, "version": "1.18.9"]
            case "/path": return ["directory": "/tmp/demo"]
            case "/session/status": return statuses
            case "/session", "/question", "/permission": return []
            default:
                if path.hasSuffix("/message") || path.hasSuffix("/todo") { return [] }
                metadataCalls += 1
                let id = String(path.dropFirst("/session/".count))
                if id == "s0", failOne { return nil }
                return ["id": id, "directory": "/tmp/demo", "title": id, "time": ["updated": 1_700_000_000_000.0]]
            }
        }
        var result = await OpenCodeSessions.read(
            port: 4097, processID: processID,
            expectedDirectory: "/tmp/demo", transport: read, metadataBudget: 2)
        XCTAssertEqual(result.outcome, .partial)
        XCTAssertLessThanOrEqual(metadataCalls, 2)
        for _ in 0..<8 {
            let before = metadataCalls
            result = await OpenCodeSessions.read(
                port: 4097, processID: processID,
                expectedDirectory: "/tmp/demo", transport: read, metadataBudget: 2)
            XCTAssertLessThanOrEqual(metadataCalls - before, 2)
        }
        XCTAssertEqual(result.infos.count, 11)  // one failed ID never starves its peers
        failOne = false
        result = await OpenCodeSessions.read(
            port: 4097, processID: processID,
            expectedDirectory: "/tmp/demo", transport: read, metadataBudget: 2)
        XCTAssertEqual(result.infos.count, 12)
        XCTAssertEqual(result.outcome, .success)
        OpenCodeSessions.prune(livePids: [])
        result = await OpenCodeSessions.read(
            port: 4097, processID: processID,
            expectedDirectory: "/tmp/demo", transport: read, metadataBudget: 2)
        XCTAssertEqual(result.infos.count, 2)
        XCTAssertEqual(result.outcome, .partial)
    }

    /// Explicit opt-in only; CI and normal tests never read private sessions.
    func testOptInLiveCodexDiscovery() async throws {
        guard let expected = ProcessInfo.processInfo.environment["LOOPFWD_LIVE_EXPECTED_SESSION"] else {
            throw XCTSkip("Set LOOPFWD_LIVE_EXPECTED_SESSION for a read-only live discovery check")
        }
        let scan = await AgentScanner.findAgents()
        XCTAssertTrue(scan.processScanSucceeded)
        let session = try XCTUnwrap(scan.sessions.first { $0.id == "codex:\(expected)" })
        XCTAssertEqual(session.status, .working)
        XCTAssertEqual(session.observation.mode, .rich)
        XCTAssertEqual(session.surfaceID, .codexDesktop)
    }
    func testAdaptivePollingPreservesExplicitUserInterval() {
        XCTAssertEqual(PollSchedule.interval(hasActiveTasks: true, explicitInterval: nil), 2)
        XCTAssertEqual(PollSchedule.interval(hasActiveTasks: false, explicitInterval: nil), 8)
        XCTAssertEqual(PollSchedule.interval(hasActiveTasks: true, explicitInterval: 0), 2)
        XCTAssertEqual(PollSchedule.interval(hasActiveTasks: true, explicitInterval: 12), 12)
    }

    func testEmptyStateExplainsSetupAndFailureSeparately() {
        XCTAssertEqual(IslandEmptyState.resolve(hasDataFailure: false, hasAvailableProvider: false), .setupRequired)
        XCTAssertEqual(IslandEmptyState.resolve(hasDataFailure: false, hasAvailableProvider: true), .noActiveTasks)
        XCTAssertEqual(IslandEmptyState.resolve(hasDataFailure: true, hasAvailableProvider: true), .unavailable)
        XCTAssertEqual(
            IslandEmptyState.resolve(hasDataFailure: true, hasAvailableProvider: false).action, "Diagnostics")
        let now = Date()
        XCTAssertEqual(L10n.relativeTime(now.addingTimeInterval(0.1), now: now), L10n.string("Just now"))
        XCTAssertEqual(
            AboutPane.commitLabel("abcdef1234567890-dirty"), "abcdef1234567890 · " + L10n.string("Local changes"))
        XCTAssertEqual(AboutPane.commitLabel("abcdef1234567890"), "abcdef1234567890")
    }
    func testDesktopReadDistinguishesMissingIncompatibleAndSuccessfulEmpty() throws {
        let url = try temporaryFile()
        XCTAssertEqual(CodexDesktopSessions.read(databasePath: url.path).outcome, .failed)
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &database), SQLITE_OK)
        defer { sqlite3_close(database) }
        XCTAssertEqual(CodexDesktopSessions.read(databasePath: url.path).outcome, .incompatible)
        XCTAssertEqual(
            sqlite3_exec(
                database,
                "CREATE TABLE threads(id TEXT, rollout_path TEXT, cwd TEXT, name TEXT, title TEXT, model TEXT, created_at_ms INTEGER, updated_at_ms INTEGER, archived INTEGER, thread_source TEXT, source TEXT)",
                nil, nil, nil), SQLITE_OK)
        let result = CodexDesktopSessions.read(databasePath: url.path)
        XCTAssertEqual(result.outcome, .empty)
        XCTAssertTrue(result.successful)

        // Exercise the actual registry + rollout read path, not a list helper.
        // The 64 KiB read ends inside a Chinese character after valid metadata.
        for index in 0..<12 {
            let rollout = url.deletingLastPathComponent().appendingPathComponent("rollout-\(index).jsonl")
            let header =
                "{\"type\":\"session_meta\",\"payload\":{\"id\":\"thread-\(index)\",\"originator\":\"Codex Desktop\"}}\n"
            var bytes = Data(header.utf8)
            bytes.append(Data(repeating: 32, count: 64 * 1024 - bytes.count - 1))
            bytes.append(
                Data(
                    "好\n{\"type\":\"event_msg\",\"payload\":{\"type\":\"task_started\",\"turn_id\":\"turn-1\"}}\n".utf8)
            )
            try bytes.write(to: rollout)
            try FileManager.default.setAttributes(
                [.modificationDate: Date().addingTimeInterval(-3600)], ofItemAtPath: rollout.path)
            let escaped = rollout.path.replacingOccurrences(of: "'", with: "''")
            XCTAssertEqual(
                sqlite3_exec(
                    database,
                    "INSERT INTO threads VALUES ('thread-\(index)', '\(escaped)', '/tmp/demo', 'Demo', 'Demo', 'fixture', 0, 0, 0, 'user', 'vscode')",
                    nil, nil, nil), SQLITE_OK)
        }
        var populated = CodexDesktopSessions.read(databasePath: url.path, pageSize: 2)
        XCTAssertEqual(populated.outcome, .partial)
        XCTAssertLessThan(populated.sessions.count, 12)
        for _ in 0..<8 {
            populated = CodexDesktopSessions.read(databasePath: url.path, pageSize: 2)
        }
        XCTAssertEqual(populated.sessions.count, 12)
        XCTAssertTrue(populated.sessions.allSatisfy { $0.status == .working })
        XCTAssertTrue(populated.successful)
        let reducer = AgentLifecycleReducer()
        let now = Date()
        let baseline = reducer.reduce(populated.sessions, suppressEvents: true, now: now)
        let first = url.deletingLastPathComponent().appendingPathComponent("rollout-0.jsonl")
        let original = try Data(contentsOf: first)
        try Data("broken metadata\n".utf8).write(to: first, options: .atomic)
        let broken = CodexDesktopSessions.read(databasePath: url.path)
        XCTAssertEqual(broken.outcome, .partial)
        XCTAssertEqual(broken.sessions.count, 12)
        XCTAssertEqual(broken.sessions.first { $0.id == "codex:thread-0" }?.observation.mode, .stale)
        let retained = reducer.reduce(broken.sessions, suppressEvents: false, now: now.addingTimeInterval(1))
        XCTAssertEqual(
            retained.sessions.first { $0.id == "codex:thread-0" }?.status,
            baseline.sessions.first { $0.id == "codex:thread-0" }?.status)
        XCTAssertTrue(retained.events.isEmpty)

        try Data(
            "{\"type\":\"session_meta\",\"payload\":{\"id\":\"wrong-thread\",\"originator\":\"Codex Desktop\"}}\n".utf8
        ).write(to: first, options: .atomic)
        let mismatch = CodexDesktopSessions.read(databasePath: url.path)
        XCTAssertEqual(mismatch.outcome, .partial)
        let invalid = try XCTUnwrap(mismatch.sessions.first { $0.id == "codex:thread-0" })
        if case .unavailable = invalid.returnTarget {} else { XCTFail("Mismatched identity must not be returnable") }

        try original.write(to: first, options: .atomic)
        XCTAssertTrue(CodexDesktopSessions.read(databasePath: url.path).successful)
        XCTAssertEqual(sqlite3_exec(database, "DELETE FROM threads", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(CodexDesktopSessions.read(databasePath: url.path).outcome, .empty)
    }

    func testSQLiteDeadlineInterruptsTheQueryAndReleasesItsCallback() throws {
        let file = try temporaryFile()
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(file.path, &database), SQLITE_OK)
        let connection = try XCTUnwrap(database)
        defer { sqlite3_close(connection) }
        let deadline = SQLiteReadDeadline(database: connection, seconds: 0)
        let started = Date()
        XCTAssertEqual(
            sqlite3_exec(
                connection,
                "WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<100000000) SELECT sum(x) FROM n",
                nil, nil, nil), SQLITE_INTERRUPT)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
        deadline.invalidate()
        XCTAssertEqual(sqlite3_exec(connection, "SELECT 1", nil, nil, nil), SQLITE_OK)
    }

    func testDesktopScanRetriesUnvisitedRowsBeforeFreshWork() throws {
        let file = try temporaryFile()
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(file.path, &database), SQLITE_OK)
        let connection = try XCTUnwrap(database)
        defer { sqlite3_close(connection) }
        XCTAssertEqual(
            sqlite3_exec(
                connection,
                "CREATE TABLE threads(id TEXT, updated_at_ms INTEGER, archived INTEGER, thread_source TEXT, source TEXT)",
                nil, nil, nil), SQLITE_OK)
        for index in 0..<12 {
            XCTAssertEqual(
                sqlite3_exec(
                    connection,
                    "INSERT INTO threads VALUES ('t\(index)', \(index), 0, 'user', 'vscode')", nil, nil, nil), SQLITE_OK
            )
        }
        let first = try DesktopRegistryScan.begin(database: connection, path: file.path, kind: .codex, pageSize: 2)
        let checked = try XCTUnwrap(first.ids.first)
        _ = first.finish(.read([], source: "fixture"), scanFinished: false, visitedIDs: [checked])
        let retry = try DesktopRegistryScan.begin(database: connection, path: file.path, kind: .codex, pageSize: 2)
        XCTAssertEqual(retry.ids.first, first.ids.dropFirst().first)
        XCTAssertNotEqual(retry.ids.first, checked)
        XCTAssertLessThanOrEqual(retry.ids.count, 14)
    }

    func testStaleProjectionExpiresWithoutReappearingOnEveryScan() {
        let start = Date()
        let reducer = AgentLifecycleReducer()
        var session = observedSession(at: start)
        _ = reducer.reduce([session], suppressEvents: true, now: start)
        session.observation.mode = .stale
        XCTAssertEqual(
            reducer.reduce([session], suppressEvents: false, now: start.addingTimeInterval(1)).sessions.count, 1)
        XCTAssertTrue(
            reducer.reduce([session], suppressEvents: false, now: start.addingTimeInterval(30)).sessions.isEmpty)
        XCTAssertTrue(
            reducer.reduce([session], suppressEvents: false, now: start.addingTimeInterval(40)).sessions.isEmpty)
        session.observation.mode = .rich
        session.observation.updatedAt = start.addingTimeInterval(41)
        XCTAssertEqual(
            reducer.reduce([session], suppressEvents: false, now: start.addingTimeInterval(41)).sessions.first?.status,
            .working)
    }

    func testEventIdentityDoesNotUseScanTime() {
        let session = observedSession(at: Date())
        XCTAssertEqual(
            AgentLifecycleEvent(kind: .completed, session: session, occurredAt: Date()).deduplicationKey,
            AgentLifecycleEvent(kind: .completed, session: session, occurredAt: Date().addingTimeInterval(30))
                .deduplicationKey)
    }

    func testSurfaceReadCannotHideAnUnhealthySessionBehindAHealthyOne() {
        let good = observedSession(at: Date())
        var stale = good
        stale.id = "codex:stale"
        stale.observation.mode = .stale
        stale.observation.reason = "Rollout unreadable"
        let healthy = ProviderReadResult.observations([good], source: "fixture")
        let unhealthy = ProviderReadResult.observations([stale], source: "fixture")
        XCTAssertEqual(unhealthy.outcome, .failed)
        let merged = healthy.merging(unhealthy)
        XCTAssertEqual(merged.outcome, .partial)
        XCTAssertEqual(merged.sessions.count, 2)
        XCTAssertEqual(merged.reason, "Rollout unreadable")
        XCTAssertFalse(merged.successful)
        XCTAssertEqual(ProviderReadResult.observations([], source: "fixture").outcome, .empty)
    }

    private func observedSession(at date: Date, kind: AgentKind = .codex) -> AgentSession {
        AgentSession(
            id: "\(kind.rawValue):live", processID: 123, kind: kind, cpu: 0, elapsed: "1m",
            cwd: "/tmp/example", status: .working, terminalApp: nil, tty: nil, bypassPermissions: false,
            returnTarget: .unavailable(reason: "fixture"), observation: .rich("Fixture", updatedAt: date),
            turnID: "turn-1", surfaceID: .codexCLI)
    }

    func testMeaningfulContinuationAndPlanTitle() {
        XCTAssertNil(TaskPresentationResolver.substantive("继续。"))
        XCTAssertEqual(TaskPresentationResolver.substantive("继续修复登录问题"), "继续修复登录问题")
        XCTAssertEqual(TaskPresentationResolver.substantive("继续。\n修复登录问题"), "修复登录问题")
        XCTAssertEqual(
            TaskPresentationResolver.substantive("PLEASE IMPLEMENT THIS PLAN:\n# Improve notifications\n\nDetails"),
            "Improve notifications")
        XCTAssertEqual(TaskPresentationResolver.substantive("/Goal Ship beta"), "Ship beta")
    }

    func testCompoundConfirmationsKeepThePreviousTaskWithoutSwallowingConcreteGoals() {
        for prompt in [
            "好的，按照你的建议修改", "好的, 按照你的建议修改。", "按照你的建议修改",
            "那加快进度继续吧", "加快进度继续吧！", "好的，继续。", "GO AHEAD!",
        ] {
            XCTAssertNil(TaskPresentationResolver.substantive(prompt), prompt)
            XCTAssertEqual(
                TaskPresentationResolver.resolve(
                    project: "LoopFwd", previousTask: "Ship beta", lastPrompt: prompt,
                    todos: [], activity: "Running tests", isActive: true
                ).task, "Ship beta", prompt)
        }
        for prompt in [
            "继续修复登录问题", "好的，按照你的建议修改通知去重", "加快进度，修复标题错误",
            "按你的建议修改登录页面", "Go ahead and fix notifications",
        ] {
            XCTAssertEqual(TaskPresentationResolver.substantive(prompt), prompt)
        }
        XCTAssertEqual(
            TaskPresentationResolver.substantive("好的，按照你的建议修改。\n修复通知去重"), "修复通知去重")
    }

    func testCodexReaderRestoresGoalBeforeCompoundConfirmation() throws {
        for confirmation in ["那加快进度继续吧", "好的，按照你的建议修改"] {
            let file = try temporaryFile()
            let rows = [
                #"{"type":"event_msg","payload":{"type":"user_message","message":"Fix notification deduplication"}}"#,
                #"{"type":"event_msg","payload":{"type":"task_started","turn_id":"current"}}"#,
                "{\"type\":\"event_msg\",\"payload\":{\"type\":\"user_message\",\"message\":\"\(confirmation)\"}}",
            ]
            try Data((rows.joined(separator: "\n") + "\n").utf8).write(to: file)
            let info = CodexSessions.tailInfo(path: file.path)
            XCTAssertEqual(info.lastPrompt, "Fix notification deduplication")
            XCTAssertEqual(info.phase, .working)
            XCTAssertEqual(CodexSessions.tailInfo(path: file.path).lastPrompt, info.lastPrompt)
        }
    }

    func testPermissionConfirmationKeepsTheTaskButNotMeaningfulPermissionWork() {
        for confirmation in ["允许", "同意。", "确认！", "批准", "Approved.", "allow"] {
            XCTAssertNil(TaskPresentationResolver.substantive(confirmation))
            XCTAssertEqual(
                TaskPresentationResolver.resolve(
                    project: "LoopFwd", previousTask: "Ship beta", lastPrompt: confirmation,
                    todos: [], activity: nil, isActive: true
                ).task, "Ship beta")
        }
        XCTAssertEqual(TaskPresentationResolver.substantive("允许用户取消导出"), "允许用户取消导出")
        XCTAssertEqual(TaskPresentationResolver.substantive("Allow users to retry"), "Allow users to retry")
        XCTAssertEqual(TaskPresentationResolver.substantive("允许。\n修复任务标题"), "修复任务标题")
    }

    func testPendingTodoIsNeverCurrentStep() {
        XCTAssertNil(
            TaskPresentationResolver.resolve(
                project: "Demo", previousTask: nil, lastPrompt: nil,
                todos: [], activity: "Thinking…", isActive: true
            ).step)
        let pending = TaskPresentationResolver.resolve(
            project: "App", previousTask: "Ship beta",
            lastPrompt: "继续", todos: [.init(content: "Release", status: "pending")], activity: nil, isActive: true)
        XCTAssertEqual(pending.task, "Ship beta")
        XCTAssertNil(pending.step)
        let active = TaskPresentationResolver.resolve(
            project: "App", previousTask: "Ship beta",
            lastPrompt: nil, todos: [.init(content: "Verify notifications", status: "in_progress")],
            activity: "Thinking…", isActive: true)
        XCTAssertEqual(active.step, "Verify notifications")
    }

    func testNewCodexTurnDoesNotReuseAnOldActivePlan() throws {
        let file = try temporaryFile()
        let rows = [
            #"{"type":"event_msg","payload":{"type":"task_started","turn_id":"first"}}"#,
            #"{"type":"response_item","payload":{"type":"function_call","name":"update_plan","arguments":"{\"plan\":[{\"step\":\"Old goal\",\"status\":\"in_progress\"}]}"}}"#,
        ]
        try Data((rows.joined(separator: "\n") + "\n").utf8).write(to: file)
        XCTAssertEqual(CodexSessions.tailInfo(path: file.path).todos.first?.content, "Old goal")
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(
            contentsOf: Data(
                (#"{"type":"event_msg","payload":{"type":"task_started","turn_id":"second"}}"# + "\n").utf8))
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(1)], ofItemAtPath: file.path)
        XCTAssertTrue(CodexSessions.tailInfo(path: file.path).todos.isEmpty)
    }

    func testHelperTimeoutAndOutputLimitAreReal() {
        let started = Date()
        let slow = BoundedProcess.run("/bin/sleep", ["5"], timeout: 0.05)
        XCTAssertTrue(slow.timedOut)
        XCTAssertFalse(slow.succeeded)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
        let large = BoundedProcess.run("/usr/bin/yes", [], timeout: 1, maximumBytes: 1024)
        XCTAssertTrue(large.exceededOutputLimit)
        XCTAssertLessThanOrEqual(large.output.utf8.count, 1024)
        XCTAssertEqual(BoundedProcess.run("/usr/bin/printf", ["hello"]).output, "hello")
    }

    func testRealCodexReadUsesMetadataAndRetainsSemanticPrompt() throws {
        let file = try temporaryFile()
        let rows = [
            #"{"type":"session_meta","payload":{"id":"actual-thread","cwd":"/tmp/demo"}}"#,
            #"{"type":"event_msg","payload":{"type":"user_message","message":"Fix notifications"}}"#,
            #"{"type":"event_msg","payload":{"type":"user_message","message":"continue"}}"#,
            #"{"type":"event_msg","payload":{"type":"user_message","message":"允许"}}"#,
            #"{"type":"event_msg","payload":{"type":"task_started","turn_id":"turn-1"}}"#,
        ]
        try Data(rows.joined(separator: "\n").utf8).write(to: file)
        XCTAssertEqual(CodexSessions.threadID(path: file.path), "actual-thread")
        XCTAssertEqual(CodexSessions.tailInfo(path: file.path).lastPrompt, "Fix notifications")
        XCTAssertEqual(CodexSessions.tailInfo(path: file.path).phase, .working)
        try Data("not valid JSON".utf8).write(to: file)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(1)], ofItemAtPath: file.path)
        let unreadable = CodexSessions.tailInfo(path: file.path)
        XCTAssertEqual(unreadable.phase, .working)
        XCTAssertFalse(unreadable.readSucceeded)
        try Data(rows.joined(separator: "\n").utf8).write(to: file)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(2)], ofItemAtPath: file.path)
        XCTAssertTrue(CodexSessions.tailInfo(path: file.path).readSucceeded)
    }

    func testCodexContextRecoveryCrossesHistoryWindowAndSurvivesUnchangedPolls() throws {
        let file = try temporaryFile()
        let prompt = #"{"type":"event_msg","payload":{"type":"user_message","message":"继续修复通知与跳转问题"}}"# + "\n"
        let oversized =
            #"{"type":"response_item","payload":{"type":"function_call_output","output":""#
            + String(repeating: "x", count: 9 * 1024 * 1024) + "\"}}\n"
        let boundary = #"{"type":"event_msg","payload":{"type":"task_started","turn_id":"current"}}"# + "\n"
        let confirmation = #"{"type":"event_msg","payload":{"type":"user_message","message":"继续"}}"# + "\n"
        try Data((prompt + oversized + boundary + confirmation).utf8).write(to: file)
        var info = CodexSessions.tailInfo(path: file.path)
        XCTAssertNil(info.lastPrompt)
        XCTAssertTrue(info.recoveringTaskContext)
        for _ in 0..<6 where info.recoveringTaskContext {
            info = CodexSessions.tailInfo(path: file.path)
        }
        XCTAssertEqual(info.lastPrompt, "继续修复通知与跳转问题")
        XCTAssertFalse(info.recoveringTaskContext)
        XCTAssertEqual(info.phase, .working)
        XCTAssertEqual(CodexSessions.tailInfo(path: file.path).lastPrompt, info.lastPrompt)

        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(
            contentsOf: Data(
                (#"{"type":"event_msg","payload":{"type":"user_message","message":"Improve the settings page"}}"#
                    + "\n" + oversized + boundary).utf8))
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(1)], ofItemAtPath: file.path)
        info = CodexSessions.tailInfo(path: file.path)
        for _ in 0..<6 where info.recoveringTaskContext {
            info = CodexSessions.tailInfo(path: file.path)
        }
        XCTAssertEqual(info.lastPrompt, "Improve the settings page")
        XCTAssertFalse(info.recoveringTaskContext)
    }

    func testContextRecoveryHasBoundedIOAndInvalidatesReplacedFile() throws {
        let file = try temporaryFile()
        let reader = CodexTaskHistory()
        try Data(("target\n" + String(repeating: "x", count: 4096) + "\n").utf8).write(to: file)
        func extract(_ data: Data) -> String? { data == Data("target".utf8) ? "target" : nil }
        var result = reader.recover(path: file.path, tailPrompt: nil, budget: 512, extract: extract)
        XCTAssertLessThanOrEqual(result.bytesRead, 512)
        XCTAssertNil(result.prompt)
        for _ in 0..<10 where result.isRecovering {
            result = reader.recover(path: file.path, tailPrompt: nil, budget: 512, extract: extract)
            XCTAssertLessThanOrEqual(result.bytesRead, 512)
        }
        XCTAssertEqual(result.prompt, "target")
        XCTAssertEqual(reader.recover(path: file.path, tailPrompt: nil, extract: extract).bytesRead, 0)
        try Data("replacement\n".utf8).write(to: file, options: .atomic)
        XCTAssertNil(reader.recover(path: file.path, tailPrompt: nil, extract: extract).prompt)
    }

    func testCodexMetadataCacheValidatesReplacementAndIgnoresToolOutput() throws {
        let file = try temporaryFile()
        let header =
            #"{"type":"session_meta","payload":{"id":"first","cwd":"/tmp/demo","originator":"Codex Desktop","base_instructions":"not needed"}}"#
            + "\n"
        try Data((header + String(repeating: "x", count: 512 * 1024)).utf8).write(to: file)
        XCTAssertEqual(CodexSessions.threadID(path: file.path), "first")
        XCTAssertNil(CodexSessions.metadata(path: file.path)?["base_instructions"])
        XCTAssertEqual(CodexSessions.threadID(path: file.path), "first")
        try Data(header.replacingOccurrences(of: "first", with: "second").utf8).write(to: file, options: .atomic)
        XCTAssertEqual(CodexSessions.threadID(path: file.path), "second")
        try Data("broken".utf8).write(to: file)
        XCTAssertNil(CodexSessions.metadata(path: file.path))
    }

    func testNoCompletionFromHistoricalOpenCodeContent() {
        XCTAssertEqual(
            OpenCodeSessions.status(remoteStatus: "idle", hasAttention: false, hasContent: true, age: 0), .idle)
        XCTAssertEqual(
            OpenCodeDesktopSessions.status(
                toolStatus: nil, hasAssistantError: false,
                age: 0, userCreated: 1, assistantCreated: 2, assistantCompleted: true,
                hasAssistant: true, hasUser: true), .idle)
        XCTAssertEqual(
            OpenCodeDesktopSessions.status(
                toolStatus: "running", hasAssistantError: false,
                age: 7200, userCreated: 1, assistantCreated: 2, assistantCompleted: false,
                hasAssistant: true, hasUser: true), .working)
    }

    func testFreshFileHeartbeatDoesNotMakeDeepSeekSourceFresh() throws {
        let file = try temporaryFile()
        let now = Date()
        let snapshot: [String: Any] = [
            "schemaVersion": 1, "harnessVersion": "0.1.2-alpha.5",
            "generatedAt": now.timeIntervalSince1970,
            "sourceReadAt": now.addingTimeInterval(-120).timeIntervalSince1970,
            "readError": "unavailable", "loopbackURL": "http://127.0.0.1:3080",
            "sessions": [
                ["sessionId": "s1", "running": true, "updatedAt": now.addingTimeInterval(-120).timeIntervalSince1970]
            ],
        ]
        try JSONSerialization.data(withJSONObject: snapshot).write(to: file)
        let result = DeepSeekHarnessSessions.read(path: file.path, processID: 1, now: now)
        XCTAssertEqual(result.health.mode, .stale)
        XCTAssertTrue(result.sessions.isEmpty)
    }

    func testLoopbackRejectsCredentialsAndInvalidPort() {
        for value in [
            "http://user:pass@localhost:3080", "http://localhost:0", "http://localhost:65536",
            "https://localhost.evil.test:3080",
        ] {
            XCTAssertNil(DeepSeekHarnessSessions.safeLoopbackURL(value))
        }
    }

    func testVersionMismatchPreventsAnyInstallerMutation() {
        var calls: [[String]] = []
        XCTAssertThrowsError(
            try DeepSeekHarnessIntegration.installObserver(
                executable: "/tmp/dsh",
                archivePath: "/tmp/observer.tgz", packageName: "@loopfwd/dsh-observer"
            ) { _, arguments in
                calls.append(arguments)
                return (true, "0.1.1-rc.2")
            })
        XCTAssertEqual(calls, [["--version"]])
    }

    func testBoundedLinesResumeWithoutParsingAnOversizedSuffix() throws {
        let file = try temporaryFile()
        let data = Data(("你好\n" + String(repeating: "x", count: 38) + "valid-looking\nend\npartial").utf8)
        try data.write(to: file)
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var offset: UInt64 = 0
        var skipping = false
        var omitted = 0
        var lines: [String] = []
        for _ in 0..<20 {
            try handle.seek(toOffset: offset)
            let read = try TailRead.consumeLines(
                handle: handle, skippingOversizedLine: &skipping,
                chunkSize: 3, maximumBytes: 17, maximumLineBytes: 8
            ) { lines.append(String($0)) }
            omitted += read.omittedRecords
            offset += read.bytes
            if read.bytes == 0 { break }
        }
        XCTAssertEqual(lines, ["你好", "end"])
        XCTAssertEqual(omitted, 1)
        XCTAssertFalse(skipping)
        XCTAssertEqual(offset, UInt64(data.count - "partial".utf8.count))
    }

    func testUsageNumbersRejectInvalidInputsAndFutureFreshness() throws {
        XCTAssertNil(UsageTracker.displayPercent(.nan))
        XCTAssertNil(UsageTracker.displayPercent(.infinity))
        XCTAssertNil(UsageTracker.displayPercent(-1))
        XCTAssertEqual(UsageTracker.displayPercent(1e300), 999)
        XCTAssertEqual(UsageTracker.displayPercent(42.6), 43)
        let now = Date(timeIntervalSince1970: 1000)
        var snapshot = UsageTracker.CodexSnapshot(reportedAt: now.addingTimeInterval(1))
        XCTAssertFalse(snapshot.isRecent(at: now))
        snapshot.reportedAt = now.addingTimeInterval(-60)
        XCTAssertTrue(snapshot.isRecent(at: now))
        snapshot.reportedAt = now.addingTimeInterval(-901)
        XCTAssertFalse(snapshot.isRecent(at: now))
        XCTAssertNil(UsageTracker.Snapshot().weekPercent(budget: 0))

        let file = try temporaryFile()
        func read(percent: Any, minutes: Any, reset: Any = 1e300, type: String = "event_msg") throws
            -> UsageTracker.CodexSnapshot?
        {
            let event: [String: Any] = [
                "type": type, "timestamp": "2026-09-05T08:00:00Z",
                "payload": [
                    "type": "token_count",
                    "rate_limits": [
                        "primary": ["used_percent": percent, "window_minutes": minutes, "resets_at": reset]
                    ],
                ],
            ]
            var data = try JSONSerialization.data(withJSONObject: event)
            data.append(10)
            try data.write(to: file)
            return UsageTracker.codexSnapshot(path: file.path)
        }
        let valid = try read(percent: 42.6, minutes: 300)
        XCTAssertEqual(valid?.primary?.usedPercent, 42.6)
        XCTAssertEqual(valid?.primary?.windowMinutes, 300)
        XCTAssertNil(valid?.primary?.resetsAt)
        XCTAssertNotNil(try read(percent: 42.6, minutes: 300, reset: 1_800_000_000)?.primary?.resetsAt)
        XCTAssertNil(try read(percent: true, minutes: 300)?.primary)
        XCTAssertNil(try read(percent: -1, minutes: 300)?.primary)
        XCTAssertNil(try read(percent: 10, minutes: 1e100)?.primary)
        XCTAssertNil(try read(percent: 10, minutes: 1.5)?.primary)
        XCTAssertNil(try read(percent: 10, minutes: 0)?.primary)
        XCTAssertNil(try read(percent: 10, minutes: true)?.primary)
        XCTAssertNil(try read(percent: 10, minutes: 300, type: "response_item"))
    }

    func testCodexUsageDoesNotMixSparkAndMainBuckets() throws {
        let file = try temporaryFile()
        func event(_ id: Any, percent: Double, minutes: Int, secondary: Any = NSNull()) -> [String: Any] {
            [
                "type": "event_msg", "timestamp": "2026-09-05T08:00:00Z",
                "payload": [
                    "type": "token_count",
                    "rate_limits": [
                        "limit_id": id, "plan_type": "pro",
                        "primary": ["used_percent": percent, "window_minutes": minutes],
                        "secondary": secondary,
                    ],
                ],
            ]
        }
        let main = event("codex", percent: 82, minutes: 10080)
        let spark = event(
            "codex_bengalfox", percent: 0, minutes: 300,
            secondary: ["used_percent": 0, "window_minutes": 10080])
        func read(_ events: [[String: Any]]) throws -> UsageTracker.CodexSnapshot? {
            var data = Data()
            for event in events {
                data.append(try JSONSerialization.data(withJSONObject: event))
                data.append(10)
            }
            try data.write(to: file)
            return UsageTracker.codexSnapshot(path: file.path)
        }
        for events in [[main, spark], [spark, main], [main, spark, spark]] {
            let result = try read(events)
            XCTAssertEqual(result?.primary?.label, "7d")
            XCTAssertEqual(result?.primary?.remainingPercent, 18)
            XCTAssertNil(result?.secondary)
        }
        XCTAssertNil(try read([spark]))
        XCTAssertNil(try read([event("unknown", percent: 0, minutes: 300)]))
        XCTAssertNil(try read([event(42, percent: 0, minutes: 300)]))
        XCTAssertEqual(try read([event(NSNull(), percent: 25, minutes: 300)])?.primary?.remainingPercent, 75)
        XCTAssertEqual(UsageTracker.CodexWindow(usedPercent: 110, windowMinutes: 300).remainingPercent, 0)
        XCTAssertNil(UsageTracker.CodexWindow(usedPercent: .nan, windowMinutes: 300).remainingPercent)
    }

    func testInterfaceLanguageSelectionOverridesSystemWithoutWritingSystemPreferences() {
        XCTAssertEqual(Pref.Default.interfaceLanguage, "system")
        XCTAssertEqual(L10n.resolvedLanguage(selection: "en", preferredLanguages: ["zh-Hans-CN"]), "en")
        XCTAssertEqual(L10n.resolvedLanguage(selection: "zh-Hans", preferredLanguages: ["en-US"]), "zh-Hans")
        XCTAssertEqual(L10n.resolvedLanguage(selection: "system", preferredLanguages: ["zh-Hans-CN"]), "zh-Hans")
        XCTAssertEqual(L10n.resolvedLanguage(selection: nil, preferredLanguages: ["en-US"]), "en")
        XCTAssertEqual(L10n.resolvedLanguage(selection: "invalid", preferredLanguages: []), "en")
        XCTAssertEqual(L10n.string("Interface language", language: "en"), "Interface language")
        XCTAssertEqual(L10n.string("Interface language", language: "zh-Hans"), "界面语言")
    }

    func testInvalidClaudeUsageDoesNotPoisonTheEstimate() throws {
        let file = try temporaryFile()
        let rows = ["true", "-2", "\"not a number\"", "10"].map {
            "{\"type\":\"assistant\",\"timestamp\":\"2026-09-05T08:00:00Z\",\"message\":{\"usage\":{\"input_tokens\":\($0)}}}\n"
        }.joined()
        try Data(rows.utf8).write(to: file)
        var state = UsageTracker.FileState(offset: 0, buckets: [:])
        UsageTracker.ingest(path: file.path, state: &state)
        XCTAssertEqual(state.omittedRecords, 3)
        XCTAssertEqual(state.buckets.values.reduce(0, +), 10)
    }

    func testUsageIngestBoundsOversizedRecordsAndRecoversAfterAppend() throws {
        let file = try temporaryFile()
        let usage =
            "{\"type\":\"assistant\",\"timestamp\":\"2026-09-05T08:00:00Z\",\"message\":{\"usage\":{\"input_tokens\":10}}}\n"
        try Data((usage + String(repeating: "x", count: 5 * 1024 * 1024)).utf8).write(to: file)
        var state = UsageTracker.FileState(offset: 0, buckets: [:])
        UsageTracker.ingest(path: file.path, state: &state)
        XCTAssertEqual(state.offset, 4 * 1024 * 1024)
        XCTAssertTrue(state.hasUnreadData)
        XCTAssertTrue(state.skippingOversizedLine)
        XCTAssertEqual(state.omittedRecords, 1)
        XCTAssertEqual(state.buckets.values.reduce(0, +), 10)
        UsageTracker.ingest(path: file.path, state: &state)
        XCTAssertFalse(state.hasUnreadData)
        XCTAssertTrue(state.skippingOversizedLine)
        let writer = try FileHandle(forWritingTo: file)
        try writer.seekToEnd()
        try writer.write(contentsOf: Data(("\n" + usage).utf8))
        try writer.close()
        UsageTracker.ingest(path: file.path, state: &state)
        XCTAssertFalse(state.hasUnreadData)
        XCTAssertFalse(state.skippingOversizedLine)
        XCTAssertEqual(state.omittedRecords, 1)
        XCTAssertEqual(state.buckets.values.reduce(0, +), 20)
        let previousOffset = state.offset
        UsageTracker.ingest(path: file.path + ".missing", state: &state)
        XCTAssertTrue(state.hasUnreadData)
        XCTAssertEqual(state.offset, previousOffset)
        XCTAssertEqual(state.buckets.values.reduce(0, +), 20)
    }

    private func temporaryFile() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "loopfwd-beta-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("fixture.jsonl")
    }
}
