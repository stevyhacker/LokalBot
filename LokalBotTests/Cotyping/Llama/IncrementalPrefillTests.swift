import XCTest
@testable import LokalBot

final class IncrementalPrefillTests: XCTestCase {
    func testEmptyInputs() {
        XCTAssertEqual(IncrementalPrefill.commonPrefixLength([], []), 0)
        XCTAssertEqual(IncrementalPrefill.commonPrefixLength([1, 2], []), 0)
        XCTAssertEqual(IncrementalPrefill.commonPrefixLength([], [1, 2]), 0)
    }

    func testIdenticalSequences() {
        XCTAssertEqual(IncrementalPrefill.commonPrefixLength([1, 2, 3], [1, 2, 3]), 3)
    }

    func testDivergeAtZero() {
        XCTAssertEqual(IncrementalPrefill.commonPrefixLength([9, 2, 3], [1, 2, 3]), 0)
    }

    func testOneIsPrefixOfOther() {
        XCTAssertEqual(IncrementalPrefill.commonPrefixLength([1, 2, 3], [1, 2, 3, 4, 5]), 3)
        XCTAssertEqual(IncrementalPrefill.commonPrefixLength([1, 2, 3, 4, 5], [1, 2, 3]), 3)
    }

    func testDivergeInMiddle() {
        XCTAssertEqual(IncrementalPrefill.commonPrefixLength([1, 2, 3, 4], [1, 2, 9, 4]), 2)
    }
}
