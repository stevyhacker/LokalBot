import XCTest
@testable import LokalBot

final class HeldPaneWidthTests: XCTestCase {
    func testARedivisionRestoresTheHeldWidth() {
        var held = HeldPaneWidth()
        held.settle(at: 360)
        XCTAssertEqual(held.resized(to: 640, byUser: false), 360)
    }

    func testADividerDragBecomesTheNewHeldWidth() {
        var held = HeldPaneWidth()
        held.settle(at: 360)
        XCTAssertNil(held.resized(to: 500, byUser: true))
        XCTAssertEqual(held.resized(to: 640, byUser: false), 500)
    }

    func testNothingIsRestoredBeforeThePaneSettles() {
        var held = HeldPaneWidth()
        XCTAssertNil(held.resized(to: 640, byUser: false))
    }

    func testAWidthTheSplitCannotReachIsNotRetried() {
        var held = HeldPaneWidth()
        held.settle(at: 600)
        XCTAssertEqual(held.resized(to: 420, byUser: false), 600)
        held.restoreFailed(at: 420)
        XCTAssertNil(held.resized(to: 420, byUser: false), "the same clamped width must not loop")
        XCTAssertEqual(held.resized(to: 480, byUser: false), 600)
    }

    func testReachingTheHeldWidthForgetsAnEarlierClampedWidth() {
        var held = HeldPaneWidth()
        held.settle(at: 272)
        XCTAssertEqual(held.resized(to: 340, byUser: false), 272)
        held.restoreFailed(at: 340)
        XCTAssertNil(held.resized(to: 272, byUser: false), "the restore landed after all")
        XCTAssertEqual(held.resized(to: 340, byUser: false), 272,
                       "a later re-division to the same width is put back too")
    }

    func testSmallDifferencesAreIgnored() {
        var held = HeldPaneWidth()
        held.settle(at: 360)
        XCTAssertNil(held.resized(to: 360.5, byUser: false))
    }
}
