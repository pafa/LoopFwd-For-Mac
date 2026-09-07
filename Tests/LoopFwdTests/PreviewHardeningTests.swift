import XCTest
import SQLite3
@testable import LoopFwd

final class PreviewHardeningTests: XCTestCase {
    func testHookRemovalPreservesOtherCommandsAndSubstringCollisions() throws {
        let own = "/fixture-home/.claude/loopfwd/notify-hook.sh"
        let other = "/opt/loopfwd-project/notify.sh"
        let group: [String: Any] = [
            "matcher": "custom",
            "hooks": [
                ["type": "command", "command": own],
                ["type": "command", "command": "/opt/acme/audit.sh"],
                ["type": "prompt", "prompt": "Keep this unrelated hook"],
            ],
        ]
        let input: [String: Any] = [
            "hooks": [
                "Notification": [
                    group, ["hooks": [["type": "command", "command": other]]],
                ]
            ], "permissions": ["allow": ["Read"]],
        ]
        let result = try HookSettings.removed(from: input, hookPath: own)
        let hooks = try XCTUnwrap(result["hooks"] as? [String: Any])
        let groups = try XCTUnwrap(hooks["Notification"] as? [[String: Any]])
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[0]["matcher"] as? String, "custom")
        XCTAssertEqual((groups[0]["hooks"] as? [[String: Any]])?.count, 2)
        let data = try XCTUnwrap(HookSettings.serialize(result))
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains(other))
        XCTAssertTrue(text.contains("/opt/acme/audit.sh"))
        XCTAssertFalse(text.contains(own))
        XCTAssertNotNil(result["permissions"])
    }

    func testHookInstallIgnoresNameCollisionAndIsIdempotent() throws {
        let own = "/fixture-home/space and ' quote/loopfwd/notify-hook.sh"
        let root: [String: Any] = [
            "hooks": [
                "Notification": [
                    ["hooks": [["type": "command", "command": "/opt/loopfwd-project/not-ours.sh"]]]
                ]
            ]
        ]
        let installed = try HookSettings.merged(into: root, hookPath: own)
        XCTAssertTrue(HookSettings.isInstalled(in: installed, hookPath: own))
        XCTAssertFalse(HookSettings.isInstalled(in: root, hookPath: own))
        XCTAssertEqual(
            HookSettings.serialize(installed),
            HookSettings.serialize(try HookSettings.merged(into: installed, hookPath: own)))
        XCTAssertEqual(
            HookSettings.serialize(root),
            HookSettings.serialize(try HookSettings.removed(from: installed, hookPath: own)))
        XCTAssertTrue(HookSettings.command(for: own).contains("'\\''"))
    }

    func testHookSchemaDamageFailsClosed() {
        for root: [String: Any] in [
            ["hooks": "unexpected"], ["hooks": ["Notification": "unexpected"]],
            ["hooks": ["Notification": [["hooks": "unexpected"]]]],
            ["hooks": ["Notification": [["hooks": [["type": "command", "command": 5]]]]]],
        ] {
            XCTAssertThrowsError(try HookSettings.merged(into: root, hookPath: "/opt/observer.sh"))
            XCTAssertThrowsError(try HookSettings.removed(from: root, hookPath: "/opt/observer.sh"))
        }
    }

    func testClaudeInstallerRollsBackScriptAndRetainsPrivateBackup() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = root.appendingPathComponent("settings.json")
        let script = root.appendingPathComponent("notify-hook.sh")
        let original = Data(#"{"model":"test","hooks":{}}"#.utf8)
        let originalScript = Data("original script".utf8)
        try original.write(to: settings)
        try originalScript.write(to: script)
        XCTAssertThrowsError(
            try ClaudeHookInstaller.update(
                install: true, settings: settings, scriptURL: script, script: Data("new script".utf8),
                beforeCommit: { throw NSError(domain: "IsolatedFailure", code: 1) }))
        XCTAssertEqual(try Data(contentsOf: settings), original)
        XCTAssertEqual(try Data(contentsOf: script), originalScript)
        let backups = try FileManager.default.contentsOfDirectory(
            at: ClaudeHookInstaller.backupRoot(for: settings), includingPropertiesForKeys: nil)
        XCTAssertEqual(backups.count, 1)
        let backup = backups[0].appendingPathComponent("settings.json")
        XCTAssertEqual(try Data(contentsOf: backup), original)
        XCTAssertEqual(try mode(backup), 0o600)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".loopfwd-hook.lock").path))
    }

    func testClaudeInstallerPreservesNewerExternalEdit() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = root.appendingPathComponent("settings.json")
        let script = root.appendingPathComponent("notify-hook.sh")
        try Data("{}".utf8).write(to: settings)
        let external = Data(#"{"model":"new-user-choice"}"#.utf8)
        XCTAssertThrowsError(
            try ClaudeHookInstaller.update(
                install: true, settings: settings, scriptURL: script, script: Data("new script".utf8),
                beforeCommit: { try external.write(to: settings) }))
        XCTAssertEqual(try Data(contentsOf: settings), external)
        XCTAssertFalse(FileManager.default.fileExists(atPath: script.path))
    }

    func testClaudeProfilesShareObserverWithoutUninstallBreakingOtherProfile() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("one/settings.json")
        let second = root.appendingPathComponent("two/settings.json")
        let script = root.appendingPathComponent("shared/notify-hook.sh")
        let data = Data("test observer".utf8)
        for settings in [first, second] {
            try ClaudeHookInstaller.update(install: true, settings: settings, scriptURL: script, script: data)
            XCTAssertEqual(try mode(settings), 0o600)
        }
        try ClaudeHookInstaller.update(install: false, settings: first, scriptURL: script, script: data)
        XCTAssertEqual(try Data(contentsOf: script), data)
        XCTAssertEqual(try mode(script), 0o700)
        let secondRoot = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: second)) as? [String: Any])
        XCTAssertTrue(HookSettings.isInstalled(in: secondRoot, hookPath: script.path))
        let backups = try FileManager.default.contentsOfDirectory(
            at: ClaudeHookInstaller.backupRoot(for: first), includingPropertiesForKeys: nil)
        XCTAssertEqual(backups.count, 2)
    }

    func testClaudeInstallerRejectsSymbolicLinkAndExistingLock() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("original.json")
        let settings = root.appendingPathComponent("settings.json")
        let script = root.appendingPathComponent("notify-hook.sh")
        try Data("{}".utf8).write(to: original)
        try FileManager.default.createSymbolicLink(at: settings, withDestinationURL: original)
        XCTAssertThrowsError(
            try ClaudeHookInstaller.update(
                install: true, settings: settings, scriptURL: script, script: Data()))
        try FileManager.default.removeItem(at: settings)
        try Data("{}".utf8).write(to: settings)
        let lock = root.appendingPathComponent(".loopfwd-hook.lock")
        try Data("existing owner".utf8).write(to: lock)
        XCTAssertThrowsError(
            try ClaudeHookInstaller.update(
                install: true, settings: settings, scriptURL: script, script: Data()))
        XCTAssertEqual(try Data(contentsOf: lock), Data("existing owner".utf8))
        XCTAssertEqual(try Data(contentsOf: original), Data("{}".utf8))
    }

    func testCodexDesktopDataRootsDoNotBorrowFinderEnvironment() throws {
        func resolve(_ environments: [[String: String]?], selected: String? = nil) throws -> String {
            try ProviderDataLocations.codexDesktopRoot(
                selected: selected, processEnvironments: environments, defaultRoot: "/fixture-home/.codex")
        }
        XCTAssertEqual(try resolve([[:]]), "/fixture-home/.codex")
        XCTAssertEqual(try resolve([["CODEX_HOME": "/fixture-home/custom codex"]]), "/fixture-home/custom codex")
        XCTAssertThrowsError(try resolve([nil]))
        XCTAssertThrowsError(try resolve([[:], ["CODEX_HOME": "/fixture-home/other"]]))
        XCTAssertThrowsError(try resolve([["CODEX_HOME": "relative"]]))
        XCTAssertEqual(try resolve([nil], selected: "/fixture-home/selected"), "/fixture-home/selected")
        XCTAssertThrowsError(try resolve([[:]], selected: "../other"))
    }

    func testTerminalAppCannotSendEvenWhenLabsEnabled() {
        let agent = AgentSession(
            id: "claude:test", processID: Int32.max, kind: .claude,
            cpu: 0, elapsed: "0", cwd: nil, status: .needsAttention,
            terminalApp: "Terminal", tty: "ttys001", bypassPermissions: false)
        XCTAssertFalse(TerminalBridge.canSend(to: agent))
        XCTAssertFalse(TerminalBridge.send(text: "must not send", to: agent))
        XCTAssertFalse(TerminalBridge.sendKey("1", to: agent))
        XCTAssertFalse(
            agent.effectiveCapabilities(
                providerControlsEnabled: true, claudeControlsEnabled: true
            ).contains(.approve))
        XCTAssertFalse(
            agent.effectiveCapabilities(
                providerControlsEnabled: true, claudeControlsEnabled: true
            ).contains(.reply))
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "loopfwd-hardening-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }

    func testCodexDesktopProductionReadUsesResolvedCustomRootAndPreservesFailure() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(root.appendingPathComponent("state_5.sqlite").path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(
            sqlite3_exec(
                db,
                "CREATE TABLE threads(id TEXT, rollout_path TEXT, cwd TEXT, name TEXT, title TEXT, model TEXT, created_at_ms INTEGER, updated_at_ms INTEGER, archived INTEGER, thread_source TEXT, source TEXT)",
                nil, nil, nil), SQLITE_OK)
        let location = Result {
            try ProviderDataLocations.codexDesktopRoot(
                selected: nil, processEnvironments: [["CODEX_HOME": root.path]],
                defaultRoot: "/fixture-home/unavailable")
        }
        XCTAssertEqual(CodexDesktopSessions.read(root: location).outcome, .empty)
        XCTAssertEqual(
            CodexDesktopSessions.read(root: .failure(ProviderDataLocations.LocationError.unavailable)).outcome, .failed)
    }

    func testNewVisibleAndVoiceOverStringsHaveChineseTranslations() {
        for key in [
            "LoopFwd, %d tasks need attention", "LoopFwd, %d active tasks",
            "Observed version: %@", "%d cache hits", "Claude settings target",
            "Return only · keyboard injection disabled", "Codex Desktop data",
        ] {
            XCTAssertNotEqual(L10n.string(key, language: "zh-Hans"), key)
        }
    }

    func testDiagnosticsNeverReportSupportedRangeAsObservedVersion() {
        var agent = AgentSession(
            id: "codex:test", kind: .codex, cpu: 0, elapsed: "0", cwd: nil,
            status: .working, terminalApp: nil, tty: nil, bypassPermissions: false)
        XCTAssertEqual(DiagnosticsPane.observedVersions([agent]), "unknown")
        agent.observedVersion = .metadata("26.905.11957", source: "Running app bundle")
        XCTAssertEqual(DiagnosticsPane.observedVersions([agent]), "26.905.11957")
        XCTAssertNil(ProviderVersionEvidence.metadata("secret/path/value", source: "fixture"))
        XCTAssertNil(ProviderVersionEvidence.metadata(String(repeating: "1", count: 81), source: "fixture"))
    }

    private func mode(_ url: URL) throws -> Int {
        try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber).intValue
    }
}
