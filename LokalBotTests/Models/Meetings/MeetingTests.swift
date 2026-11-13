import XCTest
@testable import LokalBot

final class MeetingTests: XCTestCase {
    func testMergedDisplayTitleHidesLegacyBookkeepingWithoutChangingStoredTitle() {
        var meeting = Meeting(id: UUID(), title: "Merged: Demo Day + 1 more",
                              appName: "Merged meetings", startedAt: .now,
                              relativePath: "meetings/demo")
        meeting.mergedSourceMeetingIDs = [UUID(), UUID()]
        XCTAssertEqual(meeting.displayTitle, "Demo Day")
        XCTAssertEqual(meeting.title, "Merged: Demo Day + 1 more")
        meeting.title = "Release working session"
        XCTAssertEqual(meeting.displayTitle, "Release working session")
        meeting.title = "Merged: Demo Day + 1 more"
        meeting.mergedSourceMeetingIDs = nil
        XCTAssertEqual(meeting.displayTitle, meeting.title)
    }

    func testDurationLabelForInProgressMeeting() {
        let meeting = Meeting(
            id: UUID(),
            title: "Planning",
            appName: "Zoom",
            startedAt: Date(timeIntervalSince1970: 0),
            endedAt: nil,
            relativePath: "meetings/2026/06/16-planning"
        )

        XCTAssertEqual(meeting.durationLabel, "in progress")
    }

    func testDurationLabelForMinutes() {
        let meeting = Meeting(
            id: UUID(),
            title: "Planning",
            appName: "Zoom",
            startedAt: Date(timeIntervalSince1970: 0),
            endedAt: Date(timeIntervalSince1970: 90),
            relativePath: "meetings/2026/06/16-planning"
        )

        XCTAssertEqual(meeting.durationLabel, "1 min")
    }

    func testDurationLabelForHoursAndMinutes() {
        let meeting = Meeting(
            id: UUID(),
            title: "Planning",
            appName: "Zoom",
            startedAt: Date(timeIntervalSince1970: 0),
            endedAt: Date(timeIntervalSince1970: 7_500),
            relativePath: "meetings/2026/06/16-planning"
        )

        XCTAssertEqual(meeting.durationLabel, "2h 5m")
    }

    func testMeetingTitleDoesNotDuplicateMeetingSuffix() {
        XCTAssertEqual(MeetingMatcher.meetingTitle(for: "Google Chrome"), "Google Chrome meeting")
        XCTAssertEqual(MeetingMatcher.meetingTitle(for: "Google Chrome meeting"), "Google Chrome meeting")
    }

    func testDurationLabelPrefersRecordedAudioLength() {
        // Wall-clock span is 40 min, but only ~16 min of audio was captured.
        var meeting = Meeting(
            id: UUID(),
            title: "Coding Principles",
            appName: "Google Chrome",
            startedAt: Date(timeIntervalSince1970: 0),
            endedAt: Date(timeIntervalSince1970: 2_400),  // 40 min wall-clock
            relativePath: "meetings/2026/06/25-coding-principles"
        )
        XCTAssertEqual(meeting.durationLabel, "40 min")    // falls back to wall-clock
        meeting.recordedDuration = 977                      // 16:17 of actual audio
        XCTAssertEqual(meeting.durationLabel, "16 min")    // reports the playable length
    }
}
