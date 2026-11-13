import AppKit
import XCTest
@testable import LokalBot

// MARK: - Decode stop policy

final class CotypingDecodeStopPolicyTests: XCTestCase {
    func testStopsAfterSentenceBoundaryOnceEnoughChunksArrive() {
        XCTAssertEqual(
            CotypingDecodeStopPolicy.verdict(
                accumulated: " up with the final numbers today.",
                tokensGenerated: 4),
            .sentenceBoundary)
    }

    func testDoesNotStopOnCommonAbbreviation() {
        XCTAssertNil(CotypingDecodeStopPolicy.verdict(
            accumulated: " to review e.g.",
            tokensGenerated: 4))
    }

    func testDoesNotStopOnDecimal() {
        XCTAssertNil(CotypingDecodeStopPolicy.verdict(
            accumulated: " by version 1.2",
            tokensGenerated: 4))
    }

    func testStopsOnScaffoldingMarkerWithoutMinimumTokenDelay() {
        XCTAssertEqual(
            CotypingDecodeStopPolicy.verdict(
                accumulated: "<end_of_turn>",
                tokensGenerated: 1),
            .scaffoldingMarker)
    }
}
