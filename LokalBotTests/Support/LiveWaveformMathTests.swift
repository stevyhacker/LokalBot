import XCTest
@testable import LokalBot

final class LiveWaveformMathTests: XCTestCase {
    func testHeightsStayWithinBounds() {
        for index in 0..<9 {
            for step in 0..<200 {
                let h = LiveWaveformMath.height(index: index, time: Double(step) * 0.05)
                XCTAssertGreaterThanOrEqual(h, 3)
                XCTAssertLessThanOrEqual(h, 18)
            }
        }
    }

    func testBarsAreOutOfPhase() {
        let heights = (0..<9).map { LiveWaveformMath.height(index: $0, time: 1.0) }
        XCTAssertGreaterThan(Set(heights.map { Int($0.rounded()) }).count, 1,
                             "neighboring bars should not all share one height")
    }

    func testCustomRangeIsRespected() {
        for step in 0..<50 {
            let h = LiveWaveformMath.height(index: 2, time: Double(step) * 0.1,
                                            minHeight: 2, maxHeight: 10)
            XCTAssertGreaterThanOrEqual(h, 2)
            XCTAssertLessThanOrEqual(h, 10)
        }
    }
}
