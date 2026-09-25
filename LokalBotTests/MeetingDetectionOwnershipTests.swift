import XCTest
@testable import LokalBot

final class MeetingDetectionOwnershipTests: XCTestCase {
    func testNativeEndCannotOwnManualOrDifferentRecording() {
        let owned = UUID()
        let event = MeetingDetectionEnd(sessionID: owned, contentEndedAt: nil)
        XCTAssertFalse(event.ownsRecording(detectorSessionID: nil))
        XCTAssertFalse(event.ownsRecording(detectorSessionID: UUID()))
        XCTAssertTrue(event.ownsRecording(detectorSessionID: owned))
    }

    func testNativeAudioStartsGetDistinctLifecycleIDsAndRejectStaleEnds() throws {
        let detector = MeetingDetector()
        let zoom = MeetingDetector.DetectedApp(name: "Zoom", bundleID: "us.zoom.xos", pid: 42)
        var starts: [MeetingDetectionContext] = []
        var ends: [MeetingDetectionEnd] = []
        detector.onMeetingStarted = { starts.append($0) }
        detector.onMeetingEnded = { ends.append($0) }

        detector.acceptNativeAudioStart(app: zoom, calendarEvent: nil)
        let firstID = try XCTUnwrap(starts.first?.detectorSessionID)
        XCTAssertNil(starts.first?.detectedApp?.meetingURL)
        detector.completeMeetingEnd(sessionID: firstID)
        XCTAssertEqual(ends.map(\.sessionID), [firstID])

        detector.acceptNativeAudioStart(app: zoom, calendarEvent: nil)
        let secondID = try XCTUnwrap(starts.last?.detectorSessionID)
        XCTAssertNotEqual(firstID, secondID)
        detector.completeMeetingEnd(sessionID: firstID)
        XCTAssertEqual(detector.activeSessionID, secondID)
        XCTAssertEqual(ends.count, 1)
        detector.completeMeetingEnd(sessionID: secondID)
        XCTAssertEqual(ends.map(\.sessionID), [firstID, secondID])
    }
}
