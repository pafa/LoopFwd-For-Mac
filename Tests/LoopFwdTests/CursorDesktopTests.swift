import AppKit
import XCTest

@testable import LoopFwd

final class CursorDesktopTests: XCTestCase {
    typealias Node = CursorDesktopSessions.Node

    private func pane(running: Bool, count: Bool = false, title: String = "Build app") -> Node {
        Node(
            role: kAXGroupRole, label: "Panel project-conversations",
            children: [
                Node(role: kAXRadioButtonRole, label: title, selected: true),
                Node(
                    role: kAXGroupRole, label: title,
                    children: [
                        Node(role: kAXButtonRole, label: "Working Old transcript text"),
                        Node(
                            role: kAXGroupRole,
                            children: [
                                Node(role: kAXTextAreaRole, label: "Send follow-up"),
                                Node(role: kAXButtonRole, label: running ? "Stop generation" : "Send"),
                                Node(role: kAXButtonRole, label: count ? "Agents, Working 2" : "Agents"),
                            ]),
                    ]),
            ])
    }

    func testCurrentFooterControlsEstablishRunningAndIdleNotCompletion() throws {
        let running = try XCTUnwrap(CursorDesktopSessions.project(pane(running: true), processID: 12).sessions.first)
        let idle = try XCTUnwrap(CursorDesktopSessions.project(pane(running: false), processID: 12).sessions.first)
        XCTAssertEqual(running.status, .working)
        XCTAssertEqual(idle.status, .idle)
        XCTAssertNil(idle.activity)
        XCTAssertEqual(running.id, idle.id)
        XCTAssertFalse(running.integrationProfile.capabilities.contains(.observeCompletion))
        XCTAssertFalse(running.integrationProfile.capabilities.contains(.observeAttention))
        XCTAssertFalse(running.integrationProfile.capabilities.contains(.exactReturn))
        XCTAssertEqual(running.integrationProfile.controlPolicy, .none)
    }

    func testLiveChildCountWorksWhenParentHasNoStopButton() throws {
        let read = CursorDesktopSessions.project(pane(running: false, count: true), processID: 12)
        XCTAssertEqual(read.sessions.first?.status, .working)
    }

    func testTranscriptAndEditorTextCannotCreateTaskStatus() {
        let tree = Node(
            role: kAXGroupRole,
            children: [
                Node(role: kAXTextAreaRole, label: "Working Stop generation Agents, Working 1"),
                Node(role: kAXButtonRole, label: "Working"),
            ])
        XCTAssertFalse(CursorDesktopSessions.project(tree, processID: 12).successful)
        var unbound = pane(running: true)
        unbound.children.removeFirst()
        XCTAssertFalse(CursorDesktopSessions.project(unbound, processID: 12).successful)
    }

    func testDuplicateTitlesAcrossPanesFailClosed() {
        let duplicate = Node(role: kAXGroupRole, children: [pane(running: true), pane(running: false)])
        let read = CursorDesktopSessions.project(duplicate, processID: 12)
        XCTAssertFalse(read.successful)
        XCTAssertTrue(read.sessions.isEmpty)
    }

    func testUnchangedReadsDoNotInventProgressOrExportUIToHub() throws {
        let first = try XCTUnwrap(
            CursorDesktopSessions.project(
                pane(running: true), processID: 12, now: Date(timeIntervalSince1970: 100)
            ).sessions.first)
        var clock = CursorDesktopSessions.ProgressClock()
        _ = clock.stamp([first])
        var later = first
        later.observation.updatedAt = Date(timeIntervalSince1970: 200)
        XCTAssertEqual(clock.stamp([later]).first?.observation.updatedAt, first.observation.updatedAt)
        later.activity = "Working Running tests"
        XCTAssertEqual(clock.stamp([later]).first?.observation.updatedAt, later.observation.updatedAt)
        XCTAssertTrue(SessionProjector.project(agents: [first], macDeviceId: "mac", macOnline: true).isEmpty)
    }

    func testUnsupportedVersionDoesNotAttemptUIRead() {
        let read = CursorDesktopSessions.read(processID: -1, version: "3.21.0")
        XCTAssertEqual(read.outcome, .incompatible)
        XCTAssertTrue(read.sessions.isEmpty)
    }
}
