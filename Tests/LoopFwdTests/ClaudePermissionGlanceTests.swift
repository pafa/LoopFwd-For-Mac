import XCTest

@testable import LoopFwd

final class ClaudePermissionGlanceTests: XCTestCase {
    func testFormatBashCommand() {
        let detail = ClaudePermissionGlance.formatInput(
            toolName: "Bash",
            toolInput: ["command": "ls -la /tmp/example"])
        XCTAssertEqual(detail, "ls -la /tmp/example")
    }

    func testFormatReadPathUsesBasename() {
        let detail = ClaudePermissionGlance.formatInput(
            toolName: "Read",
            toolInput: ["file_path": "/tmp/example-project/Sources/App.swift"])
        XCTAssertEqual(detail, "App.swift")
    }

    func testApprovalTitleIncludesCategory() {
        XCTAssertEqual(
            ClaudePermissionGlance.approvalTitle(toolName: "Bash", category: "app"),
            "Allow Bash · App / Shell")
        XCTAssertEqual(
            ClaudePermissionGlance.approvalTitle(toolName: "Read", category: "files"),
            "Allow Read · Files")
        XCTAssertEqual(
            ClaudePermissionGlance.approvalTitle(toolName: nil, category: nil),
            "Allow tool")
    }

    func testRemoteApprovalRequestEncodesCategory() throws {
        let request = RemoteApprovalRequest(
            title: "Allow Bash · App / Shell",
            toolName: "Bash",
            permissionCategory: "app",
            message: "npm test",
            actions: [.approve, .alwaysAllow, .deny],
            requestId: "claude-appr:s:1:t",
            expiresAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let data = try ProtocolJSON.encoder.encode(request)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["permissionCategory"] as? String, "app")
        XCTAssertEqual(object["toolName"] as? String, "Bash")
        XCTAssertEqual(object["message"] as? String, "npm test")
    }
}
