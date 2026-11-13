import XCTest
@testable import LokalBot

/// A split pane with an opening width keeps it until the user drags its
/// divider, even when SwiftUI re-divides the split after the sibling pane's
/// content changes (the Timeline swapping its day column for a selection).
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
        // The window shrank; the split clamps the pane to 420.
        XCTAssertEqual(held.resized(to: 420, byUser: false), 600)
        held.restoreFailed(at: 420)
        XCTAssertNil(held.resized(to: 420, byUser: false), "the same clamped width must not loop")
        // The window grew again: the pane returns to the width it held.
        XCTAssertEqual(held.resized(to: 480, byUser: false), 600)
    }

    func testSmallDifferencesAreIgnored() {
        var held = HeldPaneWidth()
        held.settle(at: 360)
        XCTAssertNil(held.resized(to: 360.5, byUser: false))
    }
}
