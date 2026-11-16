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

    /// A restore can read as missed while SwiftUI is still applying its own
    /// division, and land later. The width it seemed clamped to must not
    /// excuse the next re-division: selecting a project then left its list
    /// at the column's maximum (CI, 2026-11-16).
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
