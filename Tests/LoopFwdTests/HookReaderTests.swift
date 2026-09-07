import CryptoKit
import SQLite3
import XCTest
@testable import LoopFwd

final class HookReaderTests: XCTestCase {
    func testWorkBuddyInstallationChecksActualMetadataWithoutStartingTheCLI() throws {
        let app = FileManager.default.temporaryDirectory.appendingPathComponent(
            "loopfwd-workbuddy-package-\(UUID()).app")
        defer { try? FileManager.default.removeItem(at: app) }
        let contents = app.appendingPathComponent("Contents")
        let package = contents.appendingPathComponent("Resources/app.asar.unpacked/cli/package.json")
        try FileManager.default.createDirectory(
            at: package.deletingLastPathComponent(), withIntermediateDirectories: true)
        func writeApp(_ id: String = "com.tencent.workbuddy.mac", version: String = "5.5.3") throws {
            try PropertyListSerialization.data(
                fromPropertyList: ["CFBundleIdentifier": id, "CFBundleShortVersionString": version], format: .xml,
                options: 0
            )
            .write(to: contents.appendingPathComponent("Info.plist"))
        }
        try writeApp()
        XCTAssertFalse(WorkBuddySessions.installationCompatible(at: app))
        try Data(#"{"version":"0.0.0","publishConfig":{"customPackage":{"version":"2.137.1"}}}"#.utf8).write(
            to: package)
        XCTAssertTrue(WorkBuddySessions.installationCompatible(at: app), "No executable exists in this fixture")
        try writeApp(version: "future")
        XCTAssertFalse(WorkBuddySessions.installationCompatible(at: app))
        try writeApp("other.app")
        XCTAssertFalse(WorkBuddySessions.installationCompatible(at: app))
        try writeApp()
        try Data(#"{"version":"0.0.0"}"#.utf8).write(to: package)
        XCTAssertFalse(WorkBuddySessions.installationCompatible(at: app))
    }

    func testWorkBuddyDesktopReaderFindsAllSessionsWithoutTranscriptPersistence() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loopfwd-workbuddy-reader-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let app = "/Applications/Work Buddy.app", pid: Int32 = 12345, host: Int32 = 12344
        let birth = "Sun Sep 6 12:00:00 2026", now = Date()
        let command =
            app + "/Contents/MacOS/WorkBuddy " + app
            + "/Contents/Resources/app.asar.unpacked/cli/bin/codebuddy --serve --no-session-persistence"
        var processes: [Int32: WorkBuddySessions.ProcessIdentity] = [
            pid: .init(command: command, startedAt: birth),
            host: .init(command: app + "/Contents/MacOS/WorkBuddy", startedAt: birth),
        ]
        let config = root.appendingPathComponent("config")
        func emit(_ id: String, _ name: String, seconds: Double = -2, owner: Int32 = 12345, extra: [String: Any] = [:])
            throws
        {
            let scope = root.appendingPathComponent(
                LocalHookEvents.scopePrefix(provider: "workbuddy", pid: owner, startedAt: birth)
                    + SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined())
            try FileManager.default.createDirectory(
                at: scope, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
            var event: [String: Any] = [
                "schemaVersion": 1, "provider": "workbuddy", "sessionID": id, "runtimeSessionID": id,
                "eventName": name, "providerVersion": "2.137.1", "ownerPID": owner, "ownerStartedAt": birth,
                "ownerHostPID": host, "ownerHostStartedAt": birth, "ownerAppPath": app,
                "observedAt": now.addingTimeInterval(seconds).timeIntervalSince1970 * 1000,
                "cwd": "/synthetic/work", "transcriptPath": "/missing/\(id).jsonl", "toolName": "Read",
            ]
            event.merge(extra) { _, new in new }
            let file = scope.appendingPathComponent("1700000000000-\(UUID()).json")
            try JSONSerialization.data(withJSONObject: event).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
        func read(_ date: Date = now) -> ProviderReadResult {
            WorkBuddySessions.read(
                processes: processes, applications: [app: "5.5.3"], configRoot: { _ in config.path },
                observerRoot: root.path, now: date)
        }
        XCTAssertEqual(read().outcome, .failed, "A missing observer is not a successful empty read")
        for index in 0..<11 { try emit("s\(index)", "PostToolUse") }
        let active = read()
        XCTAssertEqual(active.sessions.count, 11)
        XCTAssertEqual(Set(active.sessions.map(\.id)).count, 11)
        XCTAssertTrue(active.sessions.allSatisfy { $0.status == .working && $0.observation.mode == .rich })
        XCTAssertTrue(active.sessions.allSatisfy { $0.transcriptPath == nil && $0.turnID == nil })
        var old = try XCTUnwrap(active.sessions.first)
        old.processID = 54321
        old.status = .stopped
        old.observation.updatedAt = now.addingTimeInterval(-10)
        XCTAssertEqual(WorkBuddySessions.mergeSessions([old] + active.sessions).first?.processID, pid)
        XCTAssertEqual(WorkBuddySessions.mergeSessions(active.sessions + [old]).first?.processID, pid)
        old.observation.updatedAt = try XCTUnwrap(active.sessions.first?.observation.updatedAt)
        let ambiguous = try XCTUnwrap(WorkBuddySessions.mergeSessions(active.sessions + [old]).first)
        XCTAssertEqual(ambiguous.observation.mode, .stale)
        XCTAssertNotNil(ambiguous.returnTarget.unavailableReason)
        let target = try XCTUnwrap(active.sessions.first?.returnTarget)
        XCTAssertTrue(target.isExact)
        XCTAssertTrue(read(now.addingTimeInterval(30)).sessions.allSatisfy { $0.observation.mode == .stale })
        try emit(
            "s0", "FinalStop", seconds: -1, extra: ["stopReason": "completed", "generationID": "request-not-turn"])
        try emit("s1", "FinalStop", seconds: -1, extra: ["stopReason": "cancelled"])
        try emit("s2", "FinalStop", seconds: -1, extra: ["stopReason": "failed"])
        try emit("s3", "PermissionRequest", seconds: -1)
        try emit("s4", "StopFailure", seconds: -1)
        try emit("s5", "PostToolUse", seconds: -1, extra: ["providerVersion": "future"])
        let result = Dictionary(uniqueKeysWithValues: read().sessions.map { ($0.id, $0) })
        XCTAssertEqual(result["workbuddy:s0"]?.status, .idle, "Normal run end is not user-goal completion")
        XCTAssertEqual(result["workbuddy:s1"]?.status, .stopped)
        XCTAssertEqual(result["workbuddy:s2"]?.status, .failed)
        XCTAssertEqual(result["workbuddy:s3"]?.status, .idle, "Another Hook can immediately decide the permission")
        XCTAssertEqual(result["workbuddy:s4"]?.status, .idle, "Stop hook failure is not model task failure")
        XCTAssertEqual(result["workbuddy:s5"]?.observation.mode, .incompatible)
        XCTAssertFalse(result.values.contains { $0.status == .completed || $0.status == .needsAttention })
        XCTAssertEqual(read(now.addingTimeInterval(600)).sessions.first { $0.id == "workbuddy:s2" }?.status, .failed)
        let transcript = config.appendingPathComponent("projects/synthetic-work/s6.jsonl")
        try FileManager.default.createDirectory(
            at: transcript.deletingLastPathComponent(), withIntermediateDirectories: true)
        let texts: [[String: Any]] =
            [
                [
                    "type": "message", "role": "user",
                    "content": [["type": "text", "text": "Fix the synthetic sign-in flow"]],
                ],
                [
                    "type": "message", "role": "user",
                    "content": [["type": "tool_result", "content": "Not a user goal"]],
                ],
            ] + Array(repeating: ["type": "message", "role": "user", "content": "继续"], count: 15)
        var content = Data()
        for line in texts { content.append(try JSONSerialization.data(withJSONObject: line)); content.append(10) }
        try content.write(to: transcript)
        try emit("s6", "PostToolUse", seconds: -0.5, extra: ["transcriptPath": transcript.path])
        XCTAssertEqual(read().sessions.first { $0.id == "workbuddy:s6" }?.lastPrompt, "Fix the synthetic sign-in flow")
        processes[54321] = .init(command: command, startedAt: birth)
        try emit("s6", "FinalStop", seconds: -10, owner: 54321, extra: ["stopReason": "cancelled"])
        let merged = read().sessions.filter { $0.id == "workbuddy:s6" }
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.processID, pid, "An older higher-PID host must not replace fresh progress")
        let future = WorkBuddySessions.read(
            processes: processes, applications: [app: "future"], configRoot: { _ in nil }, observerRoot: root.path,
            now: now)
        XCTAssertTrue(future.sessions.allSatisfy { $0.observation.mode == .incompatible && !$0.returnTarget.isExact })
        processes[host] = .init(command: app + "/Contents/MacOS/WorkBuddy", startedAt: "recycled")
        XCTAssertTrue(read().sessions.isEmpty, "The host's old birth cannot authorize current observations")
        processes[host] = nil
        XCTAssertTrue(read().sessions.isEmpty)
    }

    func testWorkBuddyReturnAndDiscoveryDoNotConfuseTasksWithPrewarmOrCommandMentions() throws {
        let app = "/Applications/Renamed WorkBuddy.app"
        let cli = app + "/Contents/Resources/app.asar.unpacked/cli/bin/codebuddy"
        let fallback = app + "/Contents/Resources/app.asar.unpacked/cli/dist/codebuddy.js"
        for command in [
            cli + " --prewarm", "/usr/bin/node " + cli, "/usr/bin/node " + fallback,
            app + "/Contents/MacOS/WorkBuddy " + cli,
            app + "/Contents/Frameworks/WorkBuddy Helper.app/Contents/MacOS/WorkBuddy Helper " + cli,
        ] {
            XCTAssertTrue(WorkBuddySessions.cliCommand(command, belongsTo: app), command)
        }
        for command in [
            "/usr/bin/node other.js " + cli, "/bin/echo " + cli, app + "/Contents/MacOS/WorkBuddy --eval 0 " + cli,
            "/usr/bin/codebuddy --serve", cli.replacingOccurrences(of: app, with: "/Applications/Other.app"),
            "/usr/bin/node other.js " + fallback, "/usr/bin/node " + fallback + ".bak",
        ] {
            XCTAssertFalse(WorkBuddySessions.cliCommand(command, belongsTo: app), command)
        }
        XCTAssertNil(AgentScanner.detect(args: "workbuddy"), "Desktop discovery is not a basename alias")
        XCTAssertNil(AgentScanner.detect(args: cli))
        XCTAssertEqual(WorkBuddySessions.sessionURL("main:a-b_1")?.absoluteString, "workbuddy://chat/main%3Aa-b_1")
        for id in ["", "../escape", "a?start=true", "a/b", "-first", String(repeating: "a", count: 129)] {
            XCTAssertNil(WorkBuddySessions.sessionURL(id))
        }
        let profile = IntegrationProfiles.profile(for: .workBuddyDesktop, kind: .workbuddy)
        XCTAssertEqual(profile.supportTier, .experimental)
        XCTAssertEqual(profile.controlPolicy, .none)
        XCTAssertFalse(profile.canAssertCompletion(authority: .versionedObserver))
        XCTAssertFalse(profile.canAssertAttention(authority: .versionedObserver))
    }

    func testWorkBuddySharedHostKeepsIndependentMainSessionsAndRejectsChildOrUnknownIdentity() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loopfwd-workbuddy-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let birth = "Sun Sep 6 12:00:00 2026", pid: Int32 = 54321, now = Date()
        func emit(_ id: String, runtime: String?, agent: String?, extra: [String: Any] = [:]) throws {
            let scope = root.appendingPathComponent(
                LocalHookEvents.scopePrefix(provider: "workbuddy", pid: pid, startedAt: birth)
                    + SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined())
            try FileManager.default.createDirectory(
                at: scope, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
            var event: [String: Any] = [
                "schemaVersion": 1, "provider": "workbuddy", "sessionID": id,
                "eventName": "FinalStop", "generationID": "generation-\(id)", "stopReason": "completed",
                "observedAt": now.timeIntervalSince1970 * 1000,
                "ownerPID": pid, "ownerStartedAt": birth, "providerVersion": "2.137.1",
                "ownerAppPath": "/Applications/Work Buddy.app", "ownerHostPID": 123,
                "ownerHostStartedAt": birth,
            ]
            event["runtimeSessionID"] = runtime
            event["agentID"] = agent
            event.merge(extra) { _, new in new }
            let file = scope.appendingPathComponent("event-\(UUID()).json")
            try JSONSerialization.data(withJSONObject: event).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
        try emit("main-a", runtime: "main-a", agent: "named-main")
        try emit("main-b", runtime: "main-b", agent: nil)
        try emit("main-a", runtime: "child", agent: nil)
        try emit("unknown", runtime: nil, agent: nil)
        try emit("bad-host", runtime: "bad-host", agent: nil, extra: ["ownerHostPID": 0])
        try emit("parent", runtime: "parent", agent: nil, extra: ["parentSessionID": "other"])
        let result = LocalHookEvents.read(provider: "workbuddy", pid: pid, startedAt: birth, root: root.path, now: now)
        XCTAssertEqual(Set(result.map(\.sessionID)), ["main-a", "main-b"])
        XCTAssertEqual(result.count, 2, "Shared CLI PID is not one session; children must not overwrite their parent")
        XCTAssertEqual(result.first { $0.sessionID == "main-a" }?.agentID, "named-main")
        XCTAssertTrue(
            LocalHookEvents.read(provider: "workbuddy", pid: pid, startedAt: "reused", root: root.path, now: now)
                .isEmpty)
    }

    func testCursorHookOwnershipAndQueuedOrLateEventsNeverManufactureTaskState() throws {
        let profile = IntegrationProfiles.profile(for: .cursorCLI, kind: .cursorAgent)
        XCTAssertEqual(profile.supportTier, .experimental)
        XCTAssertNil(profile.phaseAuthority)
        XCTAssertFalse(profile.canAssertCompletion(authority: .versionedObserver))
        XCTAssertFalse(profile.canAssertAttention(authority: .versionedObserver))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "loopfwd-cursor-hooks-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID().uuidString.lowercased(), generation = UUID().uuidString
        let data = root.appendingPathComponent("data"), events = root.appendingPathComponent("events")
        let transcript = data.appendingPathComponent("projects/fixture-project/agent-transcripts/\(id)/\(id).jsonl")
        try FileManager.default.createDirectory(
            at: transcript.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{\"role\":\"user\",\"message\":{\"content\":\"Synthetic goal\"}}\n".utf8).write(to: transcript)
        let start = "Sun Sep 6 12:00:00 2026", pid: Int32 = 12345, now = Date()
        func emit(_ name: String, _ offset: Double, extra: [String: Any] = [:]) throws {
            let scope = events.appendingPathComponent(
                LocalHookEvents.scopePrefix(provider: "cursor", pid: pid, startedAt: start)
                    + SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined())
            try FileManager.default.createDirectory(
                at: scope, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: events.path)
            var record: [String: Any] = [
                "schemaVersion": 1, "provider": "cursor", "sessionID": id, "generationID": generation,
                "providerVersion": "2026.09.02-c22c1a3", "eventName": name,
                "observedAt": now.addingTimeInterval(offset).timeIntervalSince1970 * 1000,
                "ownerPID": pid, "ownerStartedAt": start, "cwd": "/fixture/project",
                "transcriptPath": transcript.path,
            ]
            record.merge(extra) { _, new in new }
            let file = scope.appendingPathComponent("1700000000000-" + UUID().uuidString + ".json")
            try JSONSerialization.data(withJSONObject: record).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
        func read(birth: String = start, at: Date = now, args: String = "cursor-agent") -> CursorSessions.Info? {
            CursorSessions.info(
                cwd: "/fixture/project", args: args, cpu: 900,
                configDirectory: root.path, xdgConfigHome: nil, dataDirectory: data.path,
                processID: pid, processStartedAt: birth, observerRoot: events.path, now: at)
        }
        XCTAssertNil(read(), "No argv or open-file identity: do not guess historical files")
        try emit("beforeSubmitPrompt", -8)
        XCTAssertEqual(read()?.sessionID, id, "A process-owned Hook can locate the exact closed writer")
        XCTAssertEqual(read()?.status, .idle, "Prompt may be blocked or queued")
        XCTAssertNil(read(birth: "Sun Sep 6 12:01:00 2026"), "PID reuse must invalidate the Hook")
        try emit("afterAgentThought", -7, extra: ["hasModelContent": true])
        XCTAssertEqual(read()?.activity, "Recent model progress")
        XCTAssertEqual(read()?.observation.mode, .processOnly, "A completed thought is not a busy API")
        try emit("beforeSubmitPrompt", -6, extra: ["generationID": UUID().uuidString])
        XCTAssertEqual(read()?.activity, "Recent model progress", "Queued prompt must not erase current progress")
        try emit("stop", -5, extra: ["stopReason": "completed"])
        try emit("afterAgentThought", -4, extra: ["hasModelContent": true])
        XCTAssertNil(read()?.activity, "Late thought must not reopen the same generation")
        XCTAssertEqual(read()?.status, .idle, "stop may schedule a follow-up: no invented completion")
        XCTAssertEqual(read()?.observation.mode, .stale)
        XCTAssertNil(
            read(at: now.addingTimeInterval(176))?.activity, "Expired stop still closes a later-arriving thought")
        let staleIdentity = read(at: now.addingTimeInterval(3600), args: "cursor-agent --resume " + UUID().uuidString)
        XCTAssertEqual(staleIdentity?.sessionID, id, "Stale Hook identity must not revive an old resume argument")
        XCTAssertEqual(staleIdentity?.observation.mode, .stale)
        try emit("afterAgentThought", -3, extra: ["generationID": UUID().uuidString, "hasModelContent": true])
        XCTAssertEqual(read()?.activity, "Recent model progress", "Automatic follow-up need not emit beforeSubmit")
        try emit("postToolUseFailure", -2, extra: ["providerVersion": "future-version"])
        XCTAssertEqual(read()?.observation.mode, .incompatible)
        XCTAssertNotEqual(read()?.status, .failed, "Tool failure is not whole-task failure")
        XCTAssertNotEqual(read()?.status, .needsAttention)
    }

    func testCursorMetadataRequiresMatchingIdentityAndExactConfigWorkspace() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "loopfwd-cursor-meta-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID().uuidString.lowercased()
        let cwd = "/fixture/project"
        let data = root.appendingPathComponent("data ")
        let xdg = root.appendingPathComponent("xdg ")
        let config = xdg.appendingPathComponent("cursor")
        let transcript = data.appendingPathComponent("projects/fixture-project/agent-transcripts/\(id)/\(id).jsonl")
        try FileManager.default.createDirectory(
            at: transcript.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(
            "{\"role\":\"user\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"Synthetic goal\"}]}}\n".utf8
        )
        .write(to: transcript)
        let store = URL(fileURLWithPath: CursorSessions.metadataPath(config: config.path, cwd: cwd, id: id))
        try FileManager.default.createDirectory(
            at: store.deletingLastPathComponent(), withIntermediateDirectories: true)
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(store.path, &database), SQLITE_OK)
        let db = try XCTUnwrap(database)
        defer { sqlite3_close(db) }
        XCTAssertEqual(
            sqlite3_exec(db, "CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT)", nil, nil, nil), SQLITE_OK)
        func writeMetadata(_ value: [String: Any]) throws {
            // Official aY serializer -> nj hex encoder stores UTF-8 JSON here.
            let hex = try JSONSerialization.data(withJSONObject: value).map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(
                sqlite3_exec(db, "INSERT OR REPLACE INTO meta VALUES ('0','\(hex)')", nil, nil, nil), SQLITE_OK)
        }
        func read(configOverride: String? = nil) -> CursorSessions.Info? {
            CursorSessions.info(
                cwd: cwd, args: "cursor-agent --resume " + id, cpu: 0,
                configDirectory: configOverride, xdgConfigHome: xdg.path, dataDirectory: data.path)
        }
        try writeMetadata(["agentId": id, "name": "中文会话", "lastUsedModel": "synthetic-model", "latestRootBlobId": ""])
        let matching = try XCTUnwrap(read())
        XCTAssertEqual(matching.title, "中文会话")
        XCTAssertEqual(matching.model, "synthetic-model")
        XCTAssertEqual(matching.lastPrompt, "Synthetic goal")
        XCTAssertEqual(matching.observation.mode, .processOnly)
        XCTAssertNil(read(configOverride: root.appendingPathComponent("explicit-config").path)?.title)
        try writeMetadata(["agentId": UUID().uuidString, "name": "Wrong session"])
        XCTAssertNil(read()?.title)
        try writeMetadata(["name": "Missing identity"])
        XCTAssertNil(read()?.title)
        for invalid in ["zz", "7b0", "", String(repeating: "61", count: 33000)] {
            XCTAssertEqual(sqlite3_exec(db, "UPDATE meta SET value='\(invalid)'", nil, nil, nil), SQLITE_OK)
            XCTAssertNil(read()?.title)
            XCTAssertEqual(read()?.lastPrompt, "Synthetic goal")
        }
    }

    func testCursorSeparateDataRootAndOfficialWorkspaceAddressing() throws {
        // Expected values were checked against the pure path modules shipped in
        // Cursor CLI 2026.09.02-c22c1a3, using synthetic inputs and no CLI entrypoint.
        let cases = [
            ("/fixture/project", "fixture-project", "10f149aa3b52a8dfc9119ec0e15c2a2e"),
            ("/fixture/中文 Project_2/🚀", "fixture-Project-2", "e491dc1a26503ed79563ba3ba1a6558e"),
            ("/项目/中文", "", "207db2e422ba7b5cce5482189029bb7c"),
            ("/fixture/a.b--c", "fixture-a-b-c", "7f0086cccef5862fcd3614fbaddbe358"),
            ("/fixture/café", "fixture-caf", "7a41582728d053fc3aa7a0161c4c2280"),
        ]
        XCTAssertNil(CursorSessions.providerDirectory("  ", cwd: "/fixture/project"))
        XCTAssertEqual(CursorSessions.providerDirectory("~/data", cwd: "/fixture/project"), "/fixture/project/~/data")
        XCTAssertEqual(
            CursorSessions.providerDirectory(" ./data ", cwd: "/fixture/project"), "/fixture/project/ ./data ")
        XCTAssertEqual(CursorSessions.providerDirectory("/fixture/ data ", cwd: "/fixture/project"), "/fixture/ data ")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "loopfwd-cursor-paths-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let config = root.appendingPathComponent("config")
        let data = root.appendingPathComponent("data")
        for (cwd, slug, digest) in cases {
            let id = UUID().uuidString.lowercased()
            XCTAssertEqual(CursorSessions.projectSlug(cwd), slug)
            XCTAssertEqual(
                CursorSessions.metadataPath(config: config.path, cwd: cwd, id: id),
                config.path + "/chats/" + digest + "/" + id + "/store.db")
            let suffix = "projects/" + slug + "/agent-transcripts/" + id + "/" + id + ".jsonl"
            for (base, prompt) in [(data, "Real data root"), (config, "Wrong config root")] {
                let file = base.appendingPathComponent(suffix)
                try FileManager.default.createDirectory(
                    at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONSerialization.data(withJSONObject: ["role": "user", "message": ["content": prompt]])
                    .write(to: file)
            }
            let path = data.appendingPathComponent(suffix).standardizedFileURL.path
            for opened in [[], [path]] {
                let info = try XCTUnwrap(
                    CursorSessions.info(
                        cwd: cwd, args: opened.isEmpty ? "cursor-agent --resume " + id : "cursor-agent", cpu: 0,
                        configDirectory: config.path, xdgConfigHome: root.appendingPathComponent("xdg").path,
                        dataDirectory: data.path, openChatPaths: opened))
                XCTAssertEqual(info.lastPrompt, "Real data root")
                XCTAssertEqual(info.transcriptPath, path)
                XCTAssertEqual(info.observation.mode, .processOnly)
            }
            XCTAssertNil(
                CursorSessions.info(
                    cwd: cwd, args: "cursor-agent --resume " + id, cpu: 0,
                    configDirectory: config.path, xdgConfigHome: nil,
                    dataDirectory: root.appendingPathComponent("absent").path),
                "A config-root transcript must not substitute for the configured data root")
        }
    }

    func testCursorDoesNotGuessNewestConversationOrPromoteHistoryAndCPU() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loopfwd-cursor-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let ids = [UUID().uuidString.lowercased(), UUID().uuidString.lowercased()]
        var paths: [String] = []
        for id in ids {
            let directory = root.appendingPathComponent("projects/fixture-project/agent-transcripts/" + id)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let path = directory.appendingPathComponent(id + ".jsonl")
            try Data(
                "{\"role\":\"user\",\"message\":{\"content\":\"<user_query>Fix synthetic login</user_query>\"}}\n{\"role\":\"assistant\",\"message\":{\"content\":\"historical response\"}}\n{\"type\":\"turn_ended\"}\n"
                    .utf8
            ).write(to: path)
            paths.append(path.path)
        }
        func read(_ args: String, opened: [String] = []) -> CursorSessions.Info? {
            CursorSessions.info(
                cwd: "/fixture/project", args: args, cpu: 999,
                configDirectory: root.path, xdgConfigHome: nil, dataDirectory: root.path, openChatPaths: opened)
        }
        XCTAssertNil(read("cursor-agent"))
        XCTAssertNil(read("cursor-agent --resume \(ids[0].prefix(8))"))
        let exact = try XCTUnwrap(read("cursor-agent --resume \(ids[0])"))
        XCTAssertEqual(exact.sessionID, ids[0])
        XCTAssertEqual(exact.lastPrompt, "Fix synthetic login")
        XCTAssertEqual(exact.status, .idle)
        XCTAssertEqual(exact.observation.mode, .processOnly)
        XCTAssertNil(exact.activity)
        XCTAssertEqual(read("cursor-agent --resume \(ids[0])", opened: [paths[1]])?.sessionID, ids[1])
        XCTAssertNil(read("cursor-agent --resume \(ids[0])", opened: paths))
        XCTAssertNil(
            read(
                "cursor-agent --resume \(ids[0])",
                opened: [
                    root.path + "/projects/another-workspace/agent-transcripts/\(ids[1])/\(ids[1]).jsonl"
                ]), "An unresolved live conversation in another workspace must not revive the old resume")
        let removed = URL(fileURLWithPath: paths[1])
        try FileManager.default.removeItem(at: removed)
        XCTAssertNil(
            read("cursor-agent --resume \(ids[0])", opened: [paths[1]]),
            "Do not revive old resume after a live file disappears")
        let file = URL(fileURLWithPath: paths[0])
        try Data("{broken}\n".utf8).write(to: file, options: .atomic)
        XCTAssertEqual(read("cursor-agent --resume \(ids[0])")?.observation.mode, .stale)
        XCTAssertNil(read("cursor-agent --resume \(ids[0])")?.lastPrompt)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(atPath: file.path, withDestinationPath: "/dev/null")
        XCTAssertNil(read("cursor-agent --resume \(ids[0])"))
    }

    func testVersionProbeCanRemoveAnOverrideWithoutChangingOtherCalls() {
        let key = "LOOPFWD_TEST_VERSION_OVERRIDE"
        setenv(key, "synthetic-version", 1)
        defer { unsetenv(key) }
        XCTAssertEqual(
            BoundedProcess.run("/usr/bin/printenv", [key]).output.trimmingCharacters(in: .whitespacesAndNewlines),
            "synthetic-version")
        let removed = BoundedProcess.run("/usr/bin/printenv", [key], removingEnvironmentKeys: [key])
        XCTAssertEqual(removed.output, "")
        XCTAssertEqual(
            BoundedProcess.run("/usr/bin/printenv", [key]).output.trimmingCharacters(in: .whitespacesAndNewlines),
            "synthetic-version")
    }
    private struct Fixture {
        let root: URL
        let cwd: String
        let events: URL
        let now: Date
        let start: String
        let id: String
        let gemini: URL
        let qwen: URL
        let pid: Int32 = 34567

        func emit(
            _ provider: String, _ name: String, source: Double, arrival: Double? = nil, extra: [String: Any] = [:]
        ) throws {
            let transcript = provider == "gemini" ? gemini : qwen
            let digest = SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined()
            let scope = events.appendingPathComponent(
                LocalHookEvents.scopePrefix(provider: provider, pid: pid, startedAt: start) + digest)
            try FileManager.default.createDirectory(
                at: scope, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            var record: [String: Any] = [
                "schemaVersion": 1, "provider": provider, "sessionID": id,
                "eventName": name, "ownerPID": pid, "ownerStartedAt": start, "transcriptPath": transcript.path,
                "cwd": cwd, "observedAt": now.addingTimeInterval(arrival ?? source).timeIntervalSince1970 * 1000,
                "sourceAt": now.addingTimeInterval(source).timeIntervalSince1970 * 1000,
            ]
            record.merge(extra) { _, new in new }
            let file = scope.appendingPathComponent("1700000000000-" + UUID().uuidString + ".json")
            try JSONSerialization.data(withJSONObject: record).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }

        func readGemini(now: Date? = nil, start: String? = nil) -> GeminiSessions.Info {
            GeminiSessions.info(
                cwd: cwd, args: "gemini --resume latest", geminiHome: root.path,
                processID: pid, processStartedAt: start ?? self.start, observerRoot: events.path, now: now ?? self.now)
        }

        func readQwen() -> QwenSessions.Info? {
            QwenSessions.info(
                cwd: cwd, args: "qwen", cpu: 0, runtimeRoot: root.path, qwenHome: root.path,
                processID: pid, processStartedAt: start, observerRoot: events.path, now: now)
        }
    }

    private func fixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "loopfwd-live-hooks-" + UUID().uuidString)
        let events = root.appendingPathComponent("events")
        let geminiChats = root.appendingPathComponent(".gemini/tmp/fixture/chats")
        let qwenChats = root.appendingPathComponent("projects/fixture/chats")
        for directory in [events, geminiChats, qwenChats, root.appendingPathComponent("sessions")] {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        let cwd = root.appendingPathComponent("project").path
        let now = Date(), id = UUID().uuidString.lowercased()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        let start = formatter.string(from: now.addingTimeInterval(-60))
        let gemini = geminiChats.appendingPathComponent("session-fixture-\(id.prefix(8)).jsonl")
        let qwen = qwenChats.appendingPathComponent("\(id).jsonl")
        try JSONSerialization.data(withJSONObject: ["projects": [cwd: "fixture"]]).write(
            to: root.appendingPathComponent(".gemini/projects.json"))
        let hash = SHA256.hash(data: Data(cwd.utf8)).map { String(format: "%02x", $0) }.joined()
        let metadata: [String: Any] = ["sessionId": id, "projectHash": hash, "kind": "main"]
        var recording = try JSONSerialization.data(withJSONObject: metadata)
        recording.append(Data("\n{\"id\":\"task\",\"type\":\"user\",\"content\":\"Fix synthetic login\"}\n".utf8))
        try recording.write(to: gemini)
        var record = try JSONSerialization.data(withJSONObject: [
            "sessionId": id, "cwd": cwd, "type": "user", "message": ["parts": [["text": "Fix synthetic login"]]],
        ])
        record.append(10)
        try record.write(to: qwen)
        try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1, "pid": 34567, "sessionId": id, "cwd": cwd,
            "qwenVersion": "0.23.0", "startedAt": now.addingTimeInterval(-30).timeIntervalSince1970 * 1000,
        ])
        .write(to: root.appendingPathComponent("sessions/34567.json"))
        return Fixture(root: root, cwd: cwd, events: events, now: now, start: start, id: id, gemini: gemini, qwen: qwen)
    }

    func testGeminiHookBindsLiveSessionAndOrdersBySourceNotArrival() throws {
        let f = try fixture()
        XCTAssertNil(f.readGemini().sessionID)
        try f.emit("gemini", "AfterModel", source: -2, extra: ["hasModelContent": true])
        try f.emit("gemini", "Notification", source: -4, arrival: -1, extra: ["notificationType": "ToolPermission"])
        let info = f.readGemini()
        XCTAssertEqual(info.sessionID, f.id)
        XCTAssertEqual(info.lastPrompt, "Fix synthetic login")
        XCTAssertEqual(info.status, .working)
        XCTAssertEqual(info.observation?.mode, .rich)
        XCTAssertEqual(
            info.observation?.updatedAt.timeIntervalSince1970 ?? 0, f.now.addingTimeInterval(-2).timeIntervalSince1970,
            accuracy: 0.001)
        XCTAssertNil(f.readGemini(start: "reused PID").sessionID)
        XCTAssertEqual(f.readGemini(now: f.now.addingTimeInterval(200)).observation?.mode, .stale)
        try f.emit("gemini", "AfterAgent", source: -0.5)
        XCTAssertEqual(f.readGemini().status, .idle)
        XCTAssertEqual(f.readGemini().observation?.mode, .stale)
    }

    func testGeminiRejectsWrongPathChildAndAmbiguousEvents() throws {
        let f = try fixture()
        try f.emit(
            "gemini", "AfterModel", source: -3,
            extra: ["hasModelContent": true, "transcriptPath": "/unrelated/session.jsonl"])
        XCTAssertNil(f.readGemini().sessionID)
        try f.emit("gemini", "AfterModel", source: -2, extra: ["hasModelContent": true])
        try f.emit("gemini", "Notification", source: -2, extra: ["notificationType": "ToolPermission"])
        XCTAssertEqual(f.readGemini().observation?.mode, .stale)
        try f.emit("gemini", "AfterModel", source: -1, extra: ["hasModelContent": true, "agentID": "child"])
        XCTAssertEqual(f.readGemini().observation?.mode, .stale)
    }

    func testQwenRegistryIdentityWithoutRecordingDoesNotBorrowHistory() throws {
        let f = try fixture()
        // Keep unrelated history, as on a real CLI's first setup screen.
        let otherID = UUID().uuidString.lowercased()
        let unrelated = f.qwen.deletingLastPathComponent().appendingPathComponent(otherID + ".jsonl")
        try String(contentsOf: f.qwen).replacingOccurrences(of: f.id, with: otherID)
            .write(to: unrelated, atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: f.qwen)
        let info = try XCTUnwrap(f.readQwen())
        XCTAssertEqual(info.sessionID, f.id)
        XCTAssertEqual(info.cwd, f.cwd)
        XCTAssertEqual(info.status, .idle)
        XCTAssertEqual(info.observation.mode, .processOnly)
        XCTAssertEqual(
            info.observation.updatedAt.timeIntervalSince1970, f.now.timeIntervalSince1970 - 30, accuracy: 0.001)
        XCTAssertNil(info.transcriptPath)
        XCTAssertNil(info.lastPrompt)
        XCTAssertNil(info.lastMessage)
        XCTAssertNil(info.activity)
    }

    func testQwenMessageFinalCannotBeRevivedByLateNonfinalOrOldPermission() throws {
        let f = try fixture()
        XCTAssertEqual(f.readQwen()?.observation.mode, .processOnly)
        try f.emit(
            "qwen", "MessageDisplay", source: -5, extra: ["messageID": "m1", "isFinal": false, "hasModelContent": true])
        XCTAssertEqual(f.readQwen()?.status, .working)
        XCTAssertEqual(f.readQwen()?.observation.mode, .rich)
        try f.emit(
            "qwen", "MessageDisplay", source: -3, extra: ["messageID": "m1", "isFinal": true, "hasModelContent": true])
        try f.emit(
            "qwen", "MessageDisplay", source: -2, extra: ["messageID": "m1", "isFinal": false, "hasModelContent": true])
        try f.emit("qwen", "Notification", source: -4, arrival: -1, extra: ["notificationType": "permission_prompt"])
        XCTAssertEqual(f.readQwen()?.status, .idle)
        XCTAssertEqual(f.readQwen()?.observation.mode, .stale)
    }

    func testQwenFailureRequiresSubmissionAndDoesNotOverrideNewerTask() throws {
        let f = try fixture()
        try f.emit("qwen", "StopFailure", source: -10, extra: ["failureCode": "server_error"])
        XCTAssertEqual(f.readQwen()?.observation.mode, .stale)
        try f.emit("qwen", "UserPromptSubmit", source: -8, extra: ["hasSubmittedPrompt": true])
        try f.emit("qwen", "StopFailure", source: -6, extra: ["failureCode": "server_error"])
        XCTAssertEqual(f.readQwen()?.status, .failed)
        try f.emit("qwen", "UserPromptSubmit", source: -4, extra: ["hasSubmittedPrompt": true])
        XCTAssertNotEqual(f.readQwen()?.status, .failed)
        try f.emit("qwen", "Stop", source: -2)
        XCTAssertNotEqual(f.readQwen()?.status, .completed)
        XCTAssertNotEqual(f.readQwen()?.status, .needsAttention)
    }

    func testProfilesCannotBorrowApprovalOrCompletionAuthority() {
        for (surface, kind) in [(IntegrationSurfaceID.geminiCLI, AgentKind.gemini), (.qwenCLI, .qwen)] {
            let profile = IntegrationProfiles.profile(for: surface, kind: kind)
            XCTAssertFalse(profile.canAssertCompletion(authority: .versionedObserver))
            XCTAssertFalse(profile.canAssertAttention(authority: .versionedObserver))
            XCTAssertEqual(profile.controlPolicy, .none)
        }
    }

    func testQwenSwitchWaitsForRegistryRatherThanRevivingOldSession() throws {
        let f = try fixture()
        let next = UUID().uuidString.lowercased()
        let nextPath = f.qwen.deletingLastPathComponent().appendingPathComponent(next + ".jsonl")
        try Data(String(contentsOf: f.qwen).replacingOccurrences(of: f.id, with: next).utf8).write(to: nextPath)
        try f.emit(
            "qwen", "MessageDisplay", source: -5, extra: ["messageID": "m1", "isFinal": false, "hasModelContent": true])
        XCTAssertEqual(f.readQwen()?.status, .working)
        try f.emit("qwen", "SessionStart", source: -2, extra: ["sessionID": next, "transcriptPath": nextPath.path])
        XCTAssertEqual(f.readQwen()?.sessionID, f.id)
        XCTAssertEqual(f.readQwen()?.observation.mode, .stale)
        XCTAssertEqual(f.readQwen()?.status, .idle)
        let registry = f.root.appendingPathComponent("sessions/34567.json")
        var record = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: registry)) as? [String: Any])
        record["sessionId"] = next
        try JSONSerialization.data(withJSONObject: record).write(to: registry)
        try f.emit(
            "qwen", "MessageDisplay", source: -0.5,
            extra: [
                "messageID": "m2", "isFinal": false, "hasModelContent": true, "sessionID": next,
                "transcriptPath": nextPath.path,
            ])
        XCTAssertEqual(f.readQwen()?.sessionID, next)
        XCTAssertEqual(f.readQwen()?.observation.mode, .rich)
        XCTAssertEqual(f.readQwen()?.status, .working)
    }

    func testToolResultOrInterruptionDoesNotInventContinuedExecution() throws {
        let f = try fixture()
        try f.emit("qwen", "PostToolUseFailure", source: -2, extra: ["isInterrupt": true, "toolName": "shell"])
        XCTAssertEqual(f.readQwen()?.status, .idle)
        XCTAssertEqual(f.readQwen()?.observation.mode, .stale)
        XCTAssertEqual(f.readQwen()?.activity, "Tool interrupted: shell")
        try f.emit("gemini", "AfterTool", source: -2, extra: ["toolName": "shell"])
        XCTAssertEqual(f.readGemini().status, .idle)
        XCTAssertEqual(f.readGemini().observation?.mode, .stale)
    }
}
