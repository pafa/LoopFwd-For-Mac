import CryptoKit
import Darwin
import XCTest
@testable import LoopFwd

final class MistralInstallerTests: XCTestCase {
    private let original = "# 用户的设置\n[[hooks]]\nname=\"existing\"\ncommand=\"echo ok\""

    private func installed() -> Data {
        let body =
            "[[hooks]]\nname = \"loopfwd-observe-pre_tool\"\ntype = \"pre_tool\"\ncommand = \"node observer.mjs\"\ntimeout = 2\nstrict = false\n\n"
        let hash = SHA256.hash(data: Data(body.utf8)).map { String(format: "%02x", $0) }.joined()
        return Data(
            (original + "\n# BEGIN LOOPFWD MISTRAL OBSERVER v1 " + hash + "\n" + body
                + "# END LOOPFWD MISTRAL OBSERVER v1\n").utf8)
    }

    private func configuration() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "loopfwd-native-remove-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("hooks.toml")
        try installed().write(to: url)
        return url
    }

    func testNativeRemovalPreservesOriginalAndPrivateBackupWithoutProviderRuntime() throws {
        let config = try configuration()
        let backup = try XCTUnwrap(MistralHookIntegration.removeConfiguration(at: config))
        XCTAssertEqual(try Data(contentsOf: config), Data(original.utf8))
        XCTAssertEqual(try Data(contentsOf: backup.appendingPathComponent("hooks.toml")), installed())
        for (url, expected) in [
            (config, 0o600), (backup, 0o700), (backup.deletingLastPathComponent(), 0o700),
            (backup.appendingPathComponent("hooks.toml"), 0o600),
        ] {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, expected)
        }
        XCTAssertNil(try MistralHookIntegration.removeConfiguration(at: config))
    }

    func testRemovalRefusesEditedBlockAndSymlink() throws {
        let config = try configuration()
        let edited = Data(
            String(decoding: installed(), as: UTF8.self).replacingOccurrences(of: "timeout = 2", with: "timeout = 3")
                .utf8)
        try edited.write(to: config)
        XCTAssertThrowsError(try MistralHookIntegration.removeConfiguration(at: config))
        XCTAssertEqual(try Data(contentsOf: config), edited)
        let link = config.deletingLastPathComponent().appendingPathComponent("linked.toml")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: config)
        XCTAssertThrowsError(try MistralHookIntegration.removeConfiguration(at: link))
    }

    func testNativeRemovalHonorsInstallerLock() throws {
        let config = try configuration()
        let root = config.deletingLastPathComponent().appendingPathComponent(".loopfwd-observer")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let descriptor = open(root.appendingPathComponent("install.lock").path, O_CREAT | O_RDWR, 0o600)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { close(descriptor) }
        XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0)
        XCTAssertThrowsError(try MistralHookIntegration.removeConfiguration(at: config))
        XCTAssertEqual(try Data(contentsOf: config), installed())
    }

    func testNativeRemovalAcceptsActualBundledPythonBlockFormat() throws {
        let helper = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Integrations/LocalHooks/install-mistral.py")
        let script = """
            import importlib.util, sys
            from pathlib import Path
            spec = importlib.util.spec_from_file_location('installer', sys.argv[1])
            module = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(module)
            sys.stdout.write(module.render(sys.argv[2], Path('/test/node'), Path("/test/中文 'observer.mjs")))
            """
        let candidates = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":")
            .map { String($0) + "/python3" }
        let python = try XCTUnwrap(candidates.first { FileManager.default.isExecutableFile(atPath: $0) })
        let result = BoundedProcess.run(
            python, ["-c", script, helper.path, original], timeout: 5, maximumBytes: 16384)
        XCTAssertTrue(result.succeeded)
        XCTAssertTrue(result.output.contains("loopfwd-observe-post_agent"))
        XCTAssertEqual(try MistralHookIntegration.removingBlock(from: Data(result.output.utf8)), Data(original.utf8))
    }

    func testRemovalSeparatesUserHookAppendedAfterManagedBlock() throws {
        let appended = "[[hooks]]\nname=\"added-later\"\ncommand=\"true\"\n"
        let data = installed() + Data(appended.utf8)
        XCTAssertEqual(try MistralHookIntegration.removingBlock(from: data), Data((original + "\n" + appended).utf8))
    }
}
