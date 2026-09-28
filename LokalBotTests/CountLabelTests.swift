import XCTest
@testable import LokalBot

final class CountLabelTests: XCTestCase {
    func testRegularPlurals() {
        XCTAssertEqual(CountLabel.format(0, "moment"), "0 moments")
        XCTAssertEqual(CountLabel.format(1, "moment"), "1 moment")
        XCTAssertEqual(CountLabel.format(2, "moment"), "2 moments")
    }

    func testIrregularPlurals() {
        XCTAssertEqual(CountLabel.format(1, "match", plural: "matches"), "1 match")
        XCTAssertEqual(CountLabel.format(3, "match", plural: "matches"), "3 matches")
    }

    func testMultiWordNouns() {
        XCTAssertEqual(CountLabel.format(1, "screen moment"), "1 screen moment")
        XCTAssertEqual(CountLabel.format(5, "screen moment"), "5 screen moments")
    }
}
