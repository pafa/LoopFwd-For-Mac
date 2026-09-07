import XCTest
@testable import LoopFwd

final class ReliabilityPolishTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("loopfwd-polish-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: url) }
        return url
    }

    private func rollout(root: URL, date: String, name: String, percent: Int = 25) throws -> URL {
        let url = root.appendingPathComponent("sessions/\(date)/rollout-\(name).jsonl")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let event: [String: Any] = [
            "type": "event_msg", "timestamp": ISO8601DateFormatter().string(from: Date()),
            "payload": [
                "type": "token_count",
                "rate_limits": [
                    "limit_id": "codex",
                    "secondary": [
                        "used_percent": percent, "window_minutes": 10080,
                        "resets_at": Date().addingTimeInterval(3600).timeIntervalSince1970,
                    ],
                ],
            ],
        ]
        try JSONSerialization.data(withJSONObject: event).write(to: url)
        return url
    }

    func testCodexUsageAccountBoundaryAndExplicitSelection() {
        let a = "/fixture/account-a/sessions/2026/09/07/rollout-a.jsonl"
        let b = "/fixture/account-b/sessions/2026/09/07/rollout-b.jsonl"
        let ambiguous = CodexUsageSource.resolve(
            selected: nil, desktopRoot: "/fixture/account-a", desktopRunning: true,
            rolloutPaths: [a, b], defaultRoot: "/fixture/default")
        XCTAssertNil(ambiguous.root)
        XCTAssertTrue(ambiguous.observedPaths.isEmpty)
        let selected = CodexUsageSource.resolve(
            selected: "/fixture/account-b", desktopRoot: "/fixture/account-a", desktopRunning: true,
            rolloutPaths: [a, b], defaultRoot: "/fixture/default")
        XCTAssertEqual(selected.root, "/fixture/account-b")
        XCTAssertEqual(selected.observedPaths, [b])
        XCTAssertNil(
            CodexUsageSource.resolve(
                selected: nil, desktopRoot: nil, desktopRunning: true,
                rolloutPaths: [a], defaultRoot: "/fixture/default"
            ).root)
        XCTAssertNil(CodexUsageSource.rootForRollout("/fixture/account-a/sessions/not-a-date/rollout-a.jsonl"))
        XCTAssertEqual(
            CodexUsageSource.resolve(
                selected: nil, desktopRoot: nil, desktopRunning: false,
                rolloutPaths: [], defaultRoot: "/fixture/default", cliRoots: ["/fixture/account-b"]
            ).root, "/fixture/account-b")
        XCTAssertNil(
            CodexUsageSource.resolve(
                selected: nil, desktopRoot: nil, desktopRunning: false,
                rolloutPaths: [], defaultRoot: "/fixture/default", cliRoots: [nil]
            ).root)
        XCTAssertEqual(
            CodexUsageSource.resolve(
                selected: nil, desktopRoot: nil, desktopRunning: false,
                rolloutPaths: [b], defaultRoot: "/fixture/default"
            ).root, "/fixture/account-b")
    }

    func testCodexRolloutsCrossYearEmptyMonthAndOldActiveSession() throws {
        let root = try temporaryDirectory()
        let previous = try rollout(root: root, date: "2025/12/31", name: "previous")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("sessions/2026/01/01"), withIntermediateDirectories: true)
        let old = try rollout(root: root, date: "2024/02/01", name: "active")
        let source = CodexUsageSource(root: root.path, observedPaths: [old.path])
        XCTAssertEqual(
            Set(source.rollouts().map { ($0.path as NSString).standardizingPath }),
            Set([previous, old].map { ($0.path as NSString).standardizingPath }))
        for index in 0..<12 { _ = try rollout(root: root, date: "2026/01/02", name: "\(index)") }
        XCTAssertEqual(source.rollouts().count, 8)
    }

    func testExpiredUsageWindowsDoNotInventResetBalances() {
        let now = Date()
        let snapshot = UsageTracker.CodexSnapshot(
            primary: .init(usedPercent: 42, resetsAt: now, windowMinutes: 300),
            secondary: .init(usedPercent: 71, resetsAt: now.addingTimeInterval(10), windowMinutes: 10080),
            reportedAt: now)
        let current = snapshot.removingExpiredWindows(at: now)
        XCTAssertNil(current.primary)
        XCTAssertEqual(current.secondary?.remainingPercent, 29)
        XCTAssertFalse(current.removingExpiredWindows(at: now.addingTimeInterval(10)).hasData)
    }

    @MainActor
    func testUsageSourceChangeAndInFlightInvalidation() async throws {
        let defaults = UserDefaults.standard
        let original = defaults.object(forKey: Pref.usageEnabled)
        defaults.set(true, forKey: Pref.usageEnabled)
        defer {
            if let original {
                defaults.set(original, forKey: Pref.usageEnabled)
            } else {
                defaults.removeObject(forKey: Pref.usageEnabled)
            }
        }
        let a = try temporaryDirectory()
        let b = try temporaryDirectory()
        _ = try rollout(root: a, date: "2026/09/07", name: "a")
        let latest = try rollout(root: b, date: "2026/09/07", name: "b", percent: 60)
        let tracker = UsageTracker()
        tracker.updateCodexSource(.init(root: a.path))
        for _ in 0..<100 where !tracker.codex.hasData { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(tracker.codex.secondary?.remainingPercent, 75)
        tracker.refreshCodex()
        tracker.invalidateCodexSource()
        XCTAssertFalse(tracker.codex.hasData)
        tracker.updateCodexSource(.init(root: b.path))
        for _ in 0..<100 where !tracker.codex.hasData { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(tracker.codex.secondary?.remainingPercent, 40)
        // A newer main-bucket report with no windows must not resurrect a
        // previous balance from another rollout in the same account.
        _ = try rollout(root: b, date: "2026/09/07", name: "older", percent: 10)
        let unavailable: [String: Any] = [
            "type": "event_msg",
            "timestamp": ISO8601DateFormatter().string(from: Date().addingTimeInterval(1)),
            "payload": [
                "type": "token_count",
                "rate_limits": ["limit_id": "codex", "primary": NSNull(), "secondary": NSNull()],
            ],
        ]
        try JSONSerialization.data(withJSONObject: unavailable).write(to: latest)
        tracker.refreshCodex()
        for _ in 0..<100 where tracker.codex.hasData { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(tracker.codex.hasData)
        tracker.updateCodexSource(.init(root: b.appendingPathComponent("missing").path))
        XCTAssertFalse(tracker.codex.hasData)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(tracker.codex.hasData)
    }

    func testReturnFailureClassificationIsSpecificAndDoesNotExposeStderr() {
        func result(_ message: String, timeout: Bool = false, overflow: Bool = false) -> BoundedProcess.Result {
            .init(output: message, status: 1, timedOut: timeout, exceededOutputLimit: overflow)
        }
        XCTAssertEqual(
            ReturnFailure.fromProcess(result("secret path: execution error (-1743)"), appleScript: true),
            .permissionDenied)
        XCTAssertEqual(ReturnFailure.fromProcess(result("session not found (1001)"), appleScript: true), .targetExpired)
        XCTAssertEqual(ReturnFailure.fromProcess(result("(-1712)"), appleScript: true), .timedOut)
        XCTAssertEqual(ReturnFailure.fromProcess(result("anything", timeout: true)), .timedOut)
        XCTAssertEqual(ReturnFailure.fromProcess(result("(-1743)")), .helperFailed)
        XCTAssertEqual(ReturnFailure.fromProcess(result("(-1743)", overflow: true), appleScript: true), .helperFailed)
        XCTAssertFalse(ReturnExecutionResult.failed(.permissionDenied).reason!.contains("secret"))
        XCTAssertFalse(ReturnExecutionResult.failed(.permissionDenied).exact)
    }

    func testBoundedProcessCapturesOptInStderrAndStillEnforcesDeadline() {
        let error = BoundedProcess.run(
            "/bin/sh", ["-c", "printf 'fixture-error (1001)' >&2; exit 1"], includingStandardError: true)
        XCTAssertEqual(ReturnFailure.fromProcess(error, appleScript: true), .targetExpired)
        let quiet = BoundedProcess.run("/bin/sh", ["-c", "printf 'private' >&2; exit 1"])
        XCTAssertEqual(quiet.output, "")
        let deadline = BoundedProcess.run("/bin/sleep", ["1"], timeout: 0.02, includingStandardError: true)
        XCTAssertEqual(ReturnFailure.fromProcess(deadline), .timedOut)
    }

    func testSetupDistinguishesConfigurationEmptyObservationAndFailure() {
        let empty = ProviderScanDiagnostic(
            lastAttemptAt: Date(), lastSuccessfulAt: Date(), duration: 0,
            outcome: "empty", source: "fixture", cacheHits: 0)
        XCTAssertEqual(
            ProviderReadiness.resolve(enabled: true, installed: true, observations: [], diagnostic: empty).status,
            "No active tasks")
        XCTAssertEqual(
            ProviderReadiness.resolve(enabled: true, installed: true, observations: [], diagnostic: nil).status,
            "Installed · not verified")
        XCTAssertEqual(
            ProviderReadiness.resolve(enabled: false, installed: true, observations: [.rich], diagnostic: empty).action,
            .agents)
        XCTAssertFalse(
            ProviderReadiness.resolve(enabled: false, installed: true, observations: [.rich], diagnostic: empty).ready)
        XCTAssertEqual(
            ProviderReadiness.resolve(
                enabled: true, installed: true, observations: [.rich], diagnostic: empty,
                scanFailed: true
            ).action, .diagnostics)
        XCTAssertEqual(
            ProviderReadiness.resolve(
                enabled: true, installed: true, observations: [], diagnostic: nil,
                missingConfiguration: true
            ).status, "Data folder unavailable")
        XCTAssertEqual(
            ProviderReadiness.resolve(
                enabled: true, installed: true, observations: [.processOnly], diagnostic: nil,
                usesObserver: true
            ).action, .integrations)
        XCTAssertEqual(
            ProviderReadiness.resolve(enabled: true, installed: true, observations: [.stale], diagnostic: nil).action,
            .diagnostics)
        XCTAssertTrue(
            ProviderReadiness.resolve(enabled: true, installed: true, observations: [.rich], diagnostic: empty).ready)
    }

    func testSoundImportRestoresPreviousFileAndReportsFailedRecovery() throws {
        let root = try temporaryDirectory()
        let source = root.appendingPathComponent("sound.wav")
        let destination = root.appendingPathComponent("sounds/sound.wav")
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("new".utf8).write(to: source)
        try Data("previous".utf8).write(to: destination)
        var call = 0
        let restored = SoundEngine.importSound(from: source, directory: destination.deletingLastPathComponent()) {
            from, to in
            call += 1
            if call == 2 { throw CocoaError(.fileWriteNoPermission) }
            try FileManager.default.moveItem(at: from, to: to)
        }
        if case .success = restored { XCTFail("Import should fail") }
        XCTAssertEqual(try Data(contentsOf: destination), Data("previous".utf8))
        call = 0
        let failed = SoundEngine.importSound(from: source, directory: destination.deletingLastPathComponent()) {
            from, to in
            call += 1
            if call >= 2 { throw CocoaError(.fileWriteNoPermission) }
            try FileManager.default.moveItem(at: from, to: to)
        }
        guard case .failure(let error) = failed, let recovery = error as? SoundImportRecoveryError else {
            return XCTFail("Recovery failure must be distinct")
        }
        XCTAssertEqual(try Data(contentsOf: recovery.backup), Data("previous".utf8))
        XCTAssertTrue(recovery.localizedDescription.contains(recovery.backup.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: destination.deletingLastPathComponent().path).count, 1)
    }

    func testSoundImportDoesNotOverwriteConcurrentReplacement() throws {
        let root = try temporaryDirectory()
        let source = root.appendingPathComponent("sound.wav")
        let folder = root.appendingPathComponent("sounds")
        let destination = folder.appendingPathComponent("sound.wav")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("new".utf8).write(to: source)
        try Data("previous".utf8).write(to: destination)
        var calls = 0
        let result = SoundEngine.importSound(from: source, directory: folder) { from, to in
            calls += 1
            if calls == 2 {
                try Data("concurrent".utf8).write(to: destination)
                throw CocoaError(.fileWriteFileExists)
            }
            try FileManager.default.moveItem(at: from, to: to)
        }
        guard case .failure(let error) = result, let recovery = error as? SoundImportRecoveryError else {
            return XCTFail("Must keep recovery copy")
        }
        XCTAssertEqual(try Data(contentsOf: destination), Data("concurrent".utf8))
        XCTAssertEqual(try Data(contentsOf: recovery.backup), Data("previous".utf8))
    }
}
