import XCTest
@testable import LokalBot

/// The day overview's per-app proportion bar (spec §3.2): per-app seconds
/// become ordered fractions of the tracked total, with a long tail folded
/// into "Other".
final class ProportionBarMathTests: XCTestCase {

    func testFractionsAreOrderedAndSumToOne() {
        let segments = ProportionBarMath.segments(
            perApp: [("Xcode", 3_000), ("Safari", 1_000)])
        XCTAssertEqual(segments.map(\.label), ["Xcode", "Safari"])
        XCTAssertEqual(segments[0].fraction, 0.75, accuracy: 0.001)
        XCTAssertEqual(segments.reduce(0) { $0 + $1.fraction }, 1.0, accuracy: 0.001)
    }

    func testTailFoldsIntoOther() {
        let apps = (1...8).map { ("App\($0)", TimeInterval(100)) }
        let segments = ProportionBarMath.segments(perApp: apps, cap: 6)
        XCTAssertEqual(segments.count, 7)
        XCTAssertEqual(segments.last?.label, "Other")
        XCTAssertEqual(segments.last!.fraction, 0.25, accuracy: 0.001)
    }

    func testZeroTotalProducesEmptyBar() {
        XCTAssertTrue(ProportionBarMath.segments(perApp: []).isEmpty)
        XCTAssertTrue(ProportionBarMath.segments(perApp: [("Xcode", 0)]).isEmpty)
    }

    func testZeroSecondAppsAreDropped() {
        let segments = ProportionBarMath.segments(perApp: [("Xcode", 600), ("Idle", 0)])
        XCTAssertEqual(segments.map(\.label), ["Xcode"])
    }

    func testHumanFacingRowsFoldSubMinuteAndLongTailAppsIntoOther() {
        let rows = AppTimePresentation.rows(perApp: [
            ("Chrome", 3_600),
            ("Xcode", 1_800),
            ("ChatGPT", 1_200),
            ("Slack", 600),
            ("Terminal", 300),
            ("Finder", 120),
            ("Helper", 20),
        ])

        XCTAssertEqual(rows.map(\.label),
                       ["Chrome", "Xcode", "ChatGPT", "Slack", "Terminal", "Other"])
        XCTAssertEqual(rows.last?.seconds, 140)
        XCTAssertEqual(rows.last?.appCount, 2)
        XCTAssertTrue(rows.last?.isOther == true)
    }
}
