import XCTest
@testable import LokalBot

/// The Capture day track merges activity blocks and meetings into one
/// start-ordered stream (spec §2.2: meetings render as first-class blocks).
/// Pure, so the interleaving and the in-progress-meeting end rule are
/// testable without views.
final class CaptureTrackItemTests: XCTestCase {

    private let base = Date(timeIntervalSince1970: 1_750_000_000)

    private func block(id: Int64, startOffset: TimeInterval,
                       endOffset: TimeInterval) -> ActivityBlock {
        ActivityBlock(id: id, app: "Xcode", title: "CaptureView.swift",
                      start: base.addingTimeInterval(startOffset),
                      end: base.addingTimeInterval(endOffset))
    }

    private func meeting(startOffset: TimeInterval, endOffset: TimeInterval?,
                         recorded: TimeInterval? = nil) -> Meeting {
        var m = Meeting(id: UUID(), title: "Standup", appName: "Zoom",
                        startedAt: base.addingTimeInterval(startOffset),
                        endedAt: endOffset.map { base.addingTimeInterval($0) },
                        relativePath: "meetings/2026/07/03-standup")
        m.recordedDuration = recorded
        return m
    }

    func testItemsInterleaveSortedByStart() {
        let items = CaptureTrackItem.items(
            blocks: [block(id: 1, startOffset: 0, endOffset: 600),
                     block(id: 2, startOffset: 3_600, endOffset: 4_200)],
            meetings: [meeting(startOffset: 1_800, endOffset: 2_700)],
            now: base.addingTimeInterval(7_200))
        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(items.map(\.start),
                       [base, base.addingTimeInterval(1_800), base.addingTimeInterval(3_600)])
        if case .meeting = items[1] {} else {
            XCTFail("middle item should be the meeting")
        }
    }

    func testEndedMeetingUsesEndedAt() {
        let m = meeting(startOffset: 0, endOffset: 1_500, recorded: 900)
        XCTAssertEqual(CaptureTrackItem.meetingEnd(m, now: base.addingTimeInterval(9_999)),
                       base.addingTimeInterval(1_500))
    }

    func testUnendedMeetingFallsBackToRecordedDuration() {
        let m = meeting(startOffset: 0, endOffset: nil, recorded: 900)
        XCTAssertEqual(CaptureTrackItem.meetingEnd(m, now: base.addingTimeInterval(9_999)),
                       base.addingTimeInterval(900))
    }

    func testLiveMeetingEndsAtNow() {
        let m = meeting(startOffset: 0, endOffset: nil)
        XCTAssertEqual(CaptureTrackItem.meetingEnd(m, now: base.addingTimeInterval(300)),
                       base.addingTimeInterval(300))
    }

    func testLiveMeetingGetsMinimumVisibleSpan() {
        // A meeting that just started must not produce a zero-height block.
        let m = meeting(startOffset: 0, endOffset: nil)
        XCTAssertEqual(CaptureTrackItem.meetingEnd(m, now: base),
                       base.addingTimeInterval(60))
    }

    func testIDsAreDistinctAcrossKinds() {
        let items = CaptureTrackItem.items(
            blocks: [block(id: 5, startOffset: 0, endOffset: 60)],
            meetings: [meeting(startOffset: 0, endOffset: 60)],
            now: base)
        XCTAssertEqual(Set(items.map(\.id)).count, 2)
    }
}
