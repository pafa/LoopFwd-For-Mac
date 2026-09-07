import XCTest
@testable import LoopFwd

final class DeepSeekInstallerTests: XCTestCase {
    func testFailedReplacementRestoresThePreviousObserverWithOfficialAdd() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dsh-install-\(UUID())")
        let profile = root.appendingPathComponent("profiles/web")
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        DeepSeekHarnessIntegration.dshRootOverride = root.path
        defer {
            DeepSeekHarnessIntegration.dshRootOverride = nil
            try? FileManager.default.removeItem(at: root)
        }
        let previous = root.appendingPathComponent("previous.tgz")
        let source = root.appendingPathComponent("new.tgz")
        try Data("previous archive".utf8).write(to: previous)
        try Data("new archive".utf8).write(to: source)
        let metadata = try JSONSerialization.data(withJSONObject: [
            "dependencies": ["@loopfwd/dsh-observer": "file:../../previous.tgz", "other": "1.0.0"]
        ])
        let manifest = profile.appendingPathComponent("package.json")
        try metadata.write(to: manifest)
        var calls: [[String]] = []
        XCTAssertThrowsError(
            try DeepSeekHarnessIntegration.installObserver(
                executable: "/fixture/dsh", archivePath: source.path, packageName: "@loopfwd/dsh-observer"
            ) { _, args in
                calls.append(args)
                if args == ["--version"] { return (true, "0.1.2-alpha.5") }
                if args.last == previous.path {
                    do { try metadata.write(to: manifest) } catch { return (false, "fixture restoration failed") }
                    return (true, "restored")
                }
                do { try Data("{\"partial\":true}".utf8).write(to: manifest) } catch {
                    return (false, "fixture write failed")
                }
                return (false, "failed after changing manifest")
            })
        XCTAssertEqual(calls.count, 3)
        XCTAssertEqual(calls.last, ["plugin", "--profile", "web", "add", previous.path])
        XCTAssertFalse(calls.contains { $0.contains("remove") })
        XCTAssertEqual(try Data(contentsOf: manifest), metadata)
        XCTAssertEqual(try Data(contentsOf: previous), Data("previous archive".utf8))

        try FileManager.default.removeItem(at: previous)
        calls.removeAll()
        XCTAssertThrowsError(
            try DeepSeekHarnessIntegration.installObserver(
                executable: "/fixture/dsh", archivePath: source.path, packageName: "@loopfwd/dsh-observer"
            ) { _, args in
                calls.append(args)
                return (true, "0.1.2-alpha.5")
            })
        XCTAssertEqual(calls, [["--version"]])
        XCTAssertEqual(try Data(contentsOf: manifest), metadata)
    }

    func testInstallationSurvivesMovingTheAppAndKeepsPreviousArchive() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dsh-install-\(UUID())")
        let profile = root.appendingPathComponent("profiles/web")
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        DeepSeekHarnessIntegration.dshRootOverride = root.path
        defer {
            DeepSeekHarnessIntegration.dshRootOverride = nil
            try? FileManager.default.removeItem(at: root)
        }
        let metadata = Data("{\"dependencies\":{\"existing\":\"1.0.0\"}}".utf8)
        try metadata.write(to: profile.appendingPathComponent("package.json"))
        let workspace = Data("packages: []\n".utf8)
        try workspace.write(to: profile.appendingPathComponent("pnpm-workspace.yaml"))
        let source = root.appendingPathComponent("App/observer.tgz")
        try FileManager.default.createDirectory(
            at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = Data("first archive".utf8)
        try original.write(to: source)
        var installed: [String] = []
        let command: (String, [String]) -> (ok: Bool, message: String) = { _, args in
            if args == ["--version"] { return (true, "0.1.2-alpha.5") }
            XCTAssertEqual(Array(args.prefix(4)), ["plugin", "--profile", "web", "add"])
            if let path = args.last { installed.append(path) }
            return (true, "installed")
        }
        func install() throws {
            try DeepSeekHarnessIntegration.installObserver(
                executable: "/fixture/dsh", archivePath: source.path,
                packageName: "@loopfwd/dsh-observer", command: command)
        }
        try install()
        try install()
        XCTAssertEqual(installed.count, 2)
        XCTAssertEqual(installed[0], installed[1])
        XCTAssertNotEqual(installed[0], source.path)
        XCTAssertTrue(installed[0].hasPrefix(root.path + "/integrations/loopfwd/bundles/observer-"))
        let stored = URL(fileURLWithPath: installed[0])
        XCTAssertEqual(try Data(contentsOf: stored), original)
        XCTAssertEqual(
            try FileManager.default.attributesOfItem(atPath: stored.path)[.posixPermissions] as? Int, 0o600)
        XCTAssertEqual(
            try FileManager.default.attributesOfItem(atPath: stored.deletingLastPathComponent().path)[.posixPermissions]
                as? Int, 0o700)

        try Data("updated archive".utf8).write(to: source)
        try install()
        XCTAssertNotEqual(installed[0], installed[2])
        try FileManager.default.moveItem(
            at: source.deletingLastPathComponent(), to: root.appendingPathComponent("MovedApp"))
        XCTAssertEqual(try Data(contentsOf: stored), original)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: installed[2])), Data("updated archive".utf8))
        let backups = try FileManager.default.contentsOfDirectory(
            at: root.appendingPathComponent("backups/loopfwd"), includingPropertiesForKeys: nil)
        XCTAssertEqual(backups.count, 3)
        for backup in backups {
            XCTAssertEqual(try Data(contentsOf: backup.appendingPathComponent("package.json")), metadata)
            XCTAssertEqual(try Data(contentsOf: backup.appendingPathComponent("pnpm-workspace.yaml")), workspace)
        }
    }

    func testDamagedStoredArchiveDoesNotRunPluginOrOverwriteIt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dsh-install-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        DeepSeekHarnessIntegration.dshRootOverride = root.path
        defer {
            DeepSeekHarnessIntegration.dshRootOverride = nil
            try? FileManager.default.removeItem(at: root)
        }
        let source = root.appendingPathComponent("observer.tgz")
        try Data("archive".utf8).write(to: source)
        var commands: [[String]] = []
        let command: (String, [String]) -> (ok: Bool, message: String) = { _, args in
            commands.append(args)
            return (true, args == ["--version"] ? "0.1.2-alpha.5" : "installed")
        }
        try DeepSeekHarnessIntegration.installObserver(
            executable: "/fixture/dsh", archivePath: source.path,
            packageName: "@loopfwd/dsh-observer", command: command)
        let stored = URL(fileURLWithPath: try XCTUnwrap(commands.last?.last))
        let damaged = Data("damaged".utf8)
        try damaged.write(to: stored)
        commands.removeAll()
        XCTAssertThrowsError(
            try DeepSeekHarnessIntegration.installObserver(
                executable: "/fixture/dsh", archivePath: source.path,
                packageName: "@loopfwd/dsh-observer", command: command))
        XCTAssertEqual(commands, [["--version"]])
        XCTAssertEqual(try Data(contentsOf: stored), damaged)
    }

    func testRedirectedStorageDoesNotModifyTheOtherDirectoryOrRunPlugin() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dsh-install-\(UUID())")
        let integrations = root.appendingPathComponent("integrations")
        let other = root.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: integrations, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: other.path)
        try FileManager.default.createSymbolicLink(
            at: integrations.appendingPathComponent("loopfwd"), withDestinationURL: other)
        DeepSeekHarnessIntegration.dshRootOverride = root.path
        defer {
            DeepSeekHarnessIntegration.dshRootOverride = nil
            try? FileManager.default.removeItem(at: root)
        }
        let source = root.appendingPathComponent("observer.tgz")
        try Data("archive".utf8).write(to: source)
        var calls: [[String]] = []
        XCTAssertThrowsError(
            try DeepSeekHarnessIntegration.installObserver(
                executable: "/fixture/dsh", archivePath: source.path, packageName: "@loopfwd/dsh-observer"
            ) { _, args in
                calls.append(args)
                return (true, "0.1.2-alpha.5")
            })
        XCTAssertEqual(calls, [["--version"]])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: other.path), [])
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: other.path)[.posixPermissions] as? Int, 0o755)
    }
}
