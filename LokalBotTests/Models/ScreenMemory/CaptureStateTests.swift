import XCTest
@testable import LokalBot

final class CaptureStateTests: XCTestCase {

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
