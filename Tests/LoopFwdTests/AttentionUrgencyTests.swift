import XCTest

@testable import LoopFwd

final class AttentionUrgencyTests: XCTestCase {
    func testLevelsAtMioIslandThresholds() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(
            AttentionUrgency.level(waitingSince: start, now: start.addingTimeInterval(10)),
            .normal)
        XCTAssertEqual(
            AttentionUrgency.level(waitingSince: start, now: start.addingTimeInterval(30)),
            .elevated)
        XCTAssertEqual(
            AttentionUrgency.level(waitingSince: start, now: start.addingTimeInterval(59)),
            .elevated)
        XCTAssertEqual(
            AttentionUrgency.level(waitingSince: start, now: start.addingTimeInterval(60)),
            .critical)
    }

    func testWaitLabelAppearsOnlyWhenElevated() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertNil(
            AttentionUrgency.normal.waitLabel(
                waitingSince: start, now: start.addingTimeInterval(10)))
        XCTAssertEqual(
            AttentionUrgency.elevated.waitLabel(
                waitingSince: start, now: start.addingTimeInterval(45)),
            L10n.format("waiting %ds", 45))
        XCTAssertEqual(
            AttentionUrgency.critical.waitLabel(
                waitingSince: start, now: start.addingTimeInterval(125)),
            L10n.format("waiting %dm", 2))
    }
}
