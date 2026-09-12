import XCTest

@testable import LoopFwd

final class StickyPermissionAllowTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "StickyPermissionAllowTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testCategoryMapsFilesAndAppAliases() {
        XCTAssertEqual(StickyPermissionAllow.category(from: "files"), "files")
        XCTAssertEqual(StickyPermissionAllow.category(from: "Read"), "files")
        XCTAssertEqual(StickyPermissionAllow.category(from: "Write"), "files")
        XCTAssertEqual(StickyPermissionAllow.category(from: "external_directory"), "files")
        XCTAssertEqual(StickyPermissionAllow.category(from: "App"), "app")
        XCTAssertEqual(StickyPermissionAllow.category(from: "Bash"), "app")
        XCTAssertEqual(StickyPermissionAllow.category(from: "shell"), "app")
        XCTAssertEqual(StickyPermissionAllow.category(from: "webfetch"), "webfetch")
        XCTAssertNil(StickyPermissionAllow.category(from: "  "))
        XCTAssertNil(StickyPermissionAllow.category(from: nil))
    }

    func testRememberIsStickyByCategoryAndClearResets() {
        StickyPermissionAllow.remember("Read", defaults: defaults)
        XCTAssertTrue(StickyPermissionAllow.isRemembered("Write", defaults: defaults))
        XCTAssertTrue(StickyPermissionAllow.isRemembered("files", defaults: defaults))
        XCTAssertFalse(StickyPermissionAllow.isRemembered("Bash", defaults: defaults))

        StickyPermissionAllow.remember("Bash", defaults: defaults)
        XCTAssertTrue(StickyPermissionAllow.isRemembered("app", defaults: defaults))
        XCTAssertEqual(
            StickyPermissionAllow.remembered(defaults: defaults),
            Set(["app", "files"]))

        StickyPermissionAllow.clear(defaults: defaults)
        XCTAssertTrue(StickyPermissionAllow.remembered(defaults: defaults).isEmpty)
        XCTAssertFalse(StickyPermissionAllow.isRemembered("files", defaults: defaults))
    }

    func testApproveAndDenyDoNotPersistViaRememberAPIAlone() {
        // Remember is only called from Always paths; Approve/Deny never touch it.
        XCTAssertTrue(StickyPermissionAllow.remembered(defaults: defaults).isEmpty)
        StickyPermissionAllow.remember("webfetch", defaults: defaults)
        XCTAssertEqual(StickyPermissionAllow.remembered(defaults: defaults), ["webfetch"])
    }
}
