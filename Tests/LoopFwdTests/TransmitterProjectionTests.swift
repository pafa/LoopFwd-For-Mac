import XCTest

@testable import LoopFwd

final class TransmitterProjectionTests: XCTestCase {
    func testReplyTextNormalizationCap() {
        var env = RemoteActionEnvelope(
            action: .replyText,
            sessionId: "s",
            macDeviceId: "m",
            requestId: "r",
            clientActionId: "c",
            issuedAt: Date(),
            deviceToken: "t",
            text: String(repeating: "x", count: 600)
        )
        env.normalize()
        XCTAssertEqual(env.text?.count, RemoteActionLimits.replyTextMaxLength)
    }

    func testClaudeApprovalRequestIdFormat() {
        let id = SessionProjector.claudeApprovalRequestIdComponents(
            sessionID: "sess", processID: 4242, processStartedAt: "2026-09-12T00:00:00Z")
        XCTAssertEqual(id, "claude-appr:sess:4242:2026-09-12T00:00:00Z")
    }
}
