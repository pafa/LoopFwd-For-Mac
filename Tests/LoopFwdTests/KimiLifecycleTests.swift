import CryptoKit
import XCTest
@testable import LoopFwd

final class KimiLifecycleTests: XCTestCase {
    private let pid: Int32 = 23457
    private let birth = "Mon Sep 7 01:00:00 2026"
    private let now = Date(timeIntervalSince1970: 1_788_740_000)

    func testLifecycleFindsTenClosedDescriptorsWithoutUsingLatestHistory() throws {
        let fixture = try fixture(count: 11)
        for id in fixture.ids.prefix(10) { try event(fixture, id: id, name: "SessionHeartbeat") }
        let batch = read(fixture)
        XCTAssertEqual(batch.outcome, .success)
        XCTAssertEqual(Set(batch.sessions.map(\.sessionID)), Set(fixture.ids.prefix(10)))
        XCTAssertTrue(batch.sessions.allSatisfy { $0.status == .idle && $0.observation.mode == .rich })
        XCTAssertFalse(batch.sessions.contains { $0.sessionID == fixture.ids.last })
        XCTAssertNil(KimiSessions.info(cwd: fixture.cwd, args: "kimi-code", dataRoot: fixture.home.path))
    }

    func testHeartbeatNeverAdvancesTaskAndExpiryIsStaleNotIdle() throws {
        let fixture = try fixture(count: 1)
        let id = fixture.ids[0]
        try event(fixture, id: id, name: "SessionStart")
        let wire = fixture.home.appendingPathComponent("sessions/wd_test/\(id)/agents/main/wire.jsonl")
        let file = try FileHandle(forWritingTo: wire)
        try file.seekToEnd()
        try file.write(
            contentsOf: Data(
                "{\"type\":\"turn.prompt\",\"agentId\":\"main\",\"input\":\"Synthetic goal\",\"time\":1788739990000}\n"
                    .utf8))
        try file.close()
        let initial = try XCTUnwrap(read(fixture).sessions.first)
        XCTAssertEqual(initial.status, .working)
        try event(fixture, id: id, name: "SessionHeartbeat", offset: 60)
        let heartbeat = try XCTUnwrap(read(fixture, offset: 61).sessions.first)
        XCTAssertEqual(heartbeat.updatedAt, initial.updatedAt)
        XCTAssertEqual(heartbeat.observation.updatedAt, initial.observation.updatedAt)
        let expired = try XCTUnwrap(read(fixture, offset: 211).sessions.first)
        XCTAssertEqual(expired.status, .working)
        XCTAssertEqual(expired.observation.mode, .stale)
        XCTAssertEqual(expired.updatedAt, initial.updatedAt)
    }

    func testEndSuppressesDelayedHeartbeatUntilExplicitResume() throws {
        let fixture = try fixture(count: 1), id = fixture.ids[0]
        try event(fixture, id: id, name: "SessionStart")
        try event(fixture, id: id, name: "SessionEnd", offset: 1)
        try event(fixture, id: id, name: "SessionHeartbeat", offset: 2)
        XCTAssertEqual(read(fixture, offset: 3).outcome, .empty)
        XCTAssertTrue(read(fixture, offset: 3).sessions.isEmpty)
        try event(fixture, id: id, name: "SessionStart", offset: 4)
        XCTAssertEqual(read(fixture, offset: 5).sessions.map(\.sessionID), [id])
        try event(fixture, id: id, name: "SessionEnd", offset: 4)
        XCTAssertTrue(read(fixture, offset: 5).sessions.isEmpty, "Close wins a same-millisecond tie")
    }

    func testReusedProcessAndInvalidIdentityDoNotBorrowHistory() throws {
        let fixture = try fixture(count: 1), id = fixture.ids[0]
        try event(fixture, id: id, name: "SessionHeartbeat")
        let reused = KimiSessions.read(
            processID: pid, processStartedAt: "new birth", cwd: fixture.cwd,
            args: "kimi-code", dataRoot: fixture.home.path, observerRoot: fixture.events.path, now: now)
        XCTAssertTrue(reused.sessions.isEmpty)
        let conflict = KimiSessions.read(
            processID: pid, processStartedAt: birth, cwd: fixture.cwd,
            args: "kimi-code", dataRoot: "/different", observerRoot: fixture.events.path, now: now)
        XCTAssertTrue(conflict.sessions.isEmpty)
        let relative = KimiSessions.read(
            processID: pid, processStartedAt: birth,
            cwd: fixture.home.deletingLastPathComponent().appendingPathComponent("project").path,
            args: "kimi-code", dataRoot: "../home", observerRoot: fixture.events.path, now: now)
        XCTAssertEqual(relative.sessions.map(\.sessionID), [id])
        let unknownCwd = KimiSessions.read(
            processID: pid, processStartedAt: birth, cwd: nil, args: "kimi-code",
            dataRoot: "../home", observerRoot: fixture.events.path, now: now)
        XCTAssertTrue(unknownCwd.sessions.isEmpty)
        try event(fixture, id: id, name: "SessionHeartbeat", offset: 1, extra: ["clientType": "unknown"])
        XCTAssertTrue(read(fixture, offset: 2).sessions.isEmpty)
        try event(fixture, id: id, name: "SessionHeartbeat", offset: 3, extra: ["cwd": "/wrong"])
        XCTAssertTrue(read(fixture, offset: 4).sessions.isEmpty)
        try event(fixture, id: id, name: "SessionHeartbeat", offset: 5, extra: ["providerDataRoot": "relative"])
        XCTAssertTrue(read(fixture, offset: 6).sessions.isEmpty)
    }

    func testMainStateIDAndReturnCapabilityAreNotGuessed() throws {
        let fixture = try fixture(count: 1), id = fixture.ids[0]
        try event(fixture, id: id, name: "SessionStart")
        let state = fixture.home.appendingPathComponent("sessions/wd_test/\(id)/state.json")
        try JSONSerialization.data(withJSONObject: ["id": "wrong", "cwd": fixture.cwd]).write(to: state)
        XCTAssertTrue(read(fixture).sessions.isEmpty)
        if case .application = KimiSessions.returnTarget(terminalApp: "Terminal") {} else { XCTFail("App only") }
        if case .unavailable = KimiSessions.returnTarget(terminalApp: nil) {} else { XCTFail("Unknown terminal") }
    }

    func testBadWireHealthPropagatesToBatchAndDoesNotBecomeSuccess() throws {
        let fixture = try fixture(count: 2)
        for id in fixture.ids { try event(fixture, id: id, name: "SessionHeartbeat") }
        let first = fixture.home.appendingPathComponent("sessions/wd_test/\(fixture.ids[0])/agents/main/wire.jsonl")
        try Data("{\"type\":\"metadata\",\"protocol_version\":\"9.0\"}\n".utf8).write(to: first)
        XCTAssertEqual(read(fixture).outcome, .partial)
        try event(fixture, id: fixture.ids[1], name: "SessionEnd", offset: 1)
        XCTAssertEqual(read(fixture, offset: 2).outcome, .incompatible)
        try Data("{broken\n".utf8).write(to: first)
        XCTAssertEqual(read(fixture, offset: 2).outcome, .failed)
        XCTAssertEqual(read(fixture, offset: 2).sessions.first?.observation.mode, .stale)
    }

    private struct Fixture { let home: URL; let events: URL; let ids: [String]; let cwd = "/synthetic/kimi" }

    private func fixture(count: Int) throws -> Fixture {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("loopfwd-kimi-lease-\(UUID())")
        let fixture = Fixture(
            home: base.appendingPathComponent("home"), events: base.appendingPathComponent("events"),
            ids: (0..<count).map { _ in UUID().uuidString.lowercased() })
        try FileManager.default.createDirectory(
            at: fixture.events, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try FileManager.default.removeItem(at: base) }
        for id in fixture.ids {
            let directory = fixture.home.appendingPathComponent("sessions/wd_test/\(id)")
            try FileManager.default.createDirectory(
                at: directory.appendingPathComponent("agents/main"), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: ["id": id, "cwd": fixture.cwd, "title": "Synthetic \(id)"])
                .write(to: directory.appendingPathComponent("state.json"))
            try Data("{\"type\":\"metadata\",\"protocol_version\":\"1.5\",\"created_at\":1}\n".utf8)
                .write(to: directory.appendingPathComponent("agents/main/wire.jsonl"))
        }
        return fixture
    }

    private func event(_ fixture: Fixture, id: String, name: String, offset: Double = 0, extra: [String: Any] = [:])
        throws
    {
        let digest = SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined()
        let scope = fixture.events.appendingPathComponent(
            LocalHookEvents.scopePrefix(provider: "kimi", pid: pid, startedAt: birth) + digest)
        try FileManager.default.createDirectory(
            at: scope, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var payload: [String: Any] = [
            "schemaVersion": 1, "provider": "kimi", "sessionID": id, "eventName": name,
            "observedAt": now.addingTimeInterval(offset).timeIntervalSince1970 * 1000,
            "ownerPID": pid, "ownerStartedAt": birth, "clientType": "kimi_code_cli",
            "providerDataRoot": fixture.home.path, "cwd": fixture.cwd,
        ]
        payload.merge(extra) { _, new in new }
        let file = scope.appendingPathComponent("\(Int(offset * 1000) + 1_788_740_000_000)-\(UUID()).json")
        try JSONSerialization.data(withJSONObject: payload).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    private func read(_ fixture: Fixture, offset: Double = 0) -> KimiSessions.Batch {
        KimiSessions.read(
            processID: pid, processStartedAt: birth, cwd: fixture.cwd, args: "kimi-code",
            dataRoot: nil, observerRoot: fixture.events.path, now: now.addingTimeInterval(offset))
    }
}
