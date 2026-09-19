import XCTest
@testable import LokalBot

final class WorkspacePresentationTests: XCTestCase {
    func testReducedMotionDisablesEverySharedWorkspaceAnimation() {
        XCTAssertNil(WorkspaceMotion.animation(.selection, reduceMotion: true))
        XCTAssertNil(WorkspaceMotion.animation(.disclosure, reduceMotion: true))
        XCTAssertNil(WorkspaceMotion.animation(.drawer, reduceMotion: true))
        XCTAssertNil(WorkspaceMotion.animation(.autoScroll, reduceMotion: true))

        XCTAssertNotNil(WorkspaceMotion.animation(.disclosure, reduceMotion: false))
        XCTAssertNotNil(WorkspaceMotion.animation(.selection, reduceMotion: false))
        XCTAssertNotNil(WorkspaceMotion.animation(.drawer, reduceMotion: false))
        XCTAssertNotNil(WorkspaceMotion.animation(.autoScroll, reduceMotion: false))
    }

    func testReadingAndTimelineWidthsStayWithinApprovedPolicy() {
        XCTAssertGreaterThanOrEqual(WorkspaceMetric.readingMaxWidth, 720)
        XCTAssertLessThanOrEqual(WorkspaceMetric.readingMaxWidth, 800)
        XCTAssertGreaterThanOrEqual(WorkspaceMetric.timelineContextMinWidth, 420)
        XCTAssertGreaterThan(
            WorkspaceMetric.timelineDrawerBreakpoint,
            WorkspaceMetric.timelineContextMinWidth + 360)
    }

    func testCompactRadiusTokensAreNamedAndOrdered() {
        XCTAssertLessThan(Brand.Radius.tab, Brand.Radius.row)
        XCTAssertLessThan(Brand.Radius.row, Brand.Radius.control)
        XCTAssertLessThan(Brand.Radius.control, Brand.Radius.compactPanel)
        XCTAssertLessThan(Brand.Radius.compactPanel, Brand.Radius.panel)
    }
}
