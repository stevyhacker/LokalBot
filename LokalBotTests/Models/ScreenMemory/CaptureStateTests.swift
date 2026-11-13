import XCTest
@testable import LokalBot

/// The Timeline/Meetings detail pane's pure policy (spec §2.2 + §6): the
/// selection→inspector-state resolution, testable without any view or
/// AppState.
final class CaptureStateTests: XCTestCase {

    // MARK: Inspector state (meeting vs. block vs. none)

    func testSingleMeetingSelectionWinsOverBlock() {
        let id = UUID()
        XCTAssertEqual(
            CaptureInspectorState.resolve(meetingIDs: [id], blockSelection: 7,
                                          allowsBlockSelection: true),
            .meeting(id))
    }

    func testMultiSelectionMapsToCount() {
        XCTAssertEqual(
            CaptureInspectorState.resolve(meetingIDs: [UUID(), UUID()], blockSelection: nil,
                                          allowsBlockSelection: true),
            .multiSelection(count: 2))
    }

    func testBlockSelectionWithoutMeetingSelection() {
        XCTAssertEqual(
            CaptureInspectorState.resolve(meetingIDs: [], blockSelection: 42,
                                          allowsBlockSelection: true),
            .block(42))
    }

    /// A block picked in Timeline lingers in the shared model; on a surface
    /// without a block list (Meetings) it must not outrank the empty state.
    func testStaleBlockSelectionIgnoredWhereBlocksAreNotShown() {
        XCTAssertEqual(
            CaptureInspectorState.resolve(meetingIDs: [], blockSelection: 42,
                                          allowsBlockSelection: false),
            .overview)
    }

    func testNothingSelectedIsOverview() {
        XCTAssertEqual(
            CaptureInspectorState.resolve(meetingIDs: [], blockSelection: nil,
                                          allowsBlockSelection: true),
            .overview)
    }

    // MARK: Day digest presentation and local-day identity

    func testSelectableDigestBuildsOneContinuousVisibleString() {
        let rendered = SelectableDigestText.attributedText(from: """
        ## Daily focus

        - Ship the **date refresh**
        - [x] Keep inline `code`
        1. Verify yesterday
        > Local-only context
        """)

        XCTAssertEqual(String(rendered.characters), """
        Daily focus

        • Ship the date refresh
        ☑ Keep inline code
        1. Verify yesterday
        ▎ Local-only context
        """)
    }

    func testDayKeyUsesTheSelectedLocalCalendarDay() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Podgorica"))
        let instant = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2026-08-02T22:30:00Z"))

        XCTAssertEqual(DreamDay.key(for: instant, calendar: calendar), "2026-08-03")
    }
}
