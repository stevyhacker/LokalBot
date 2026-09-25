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

    func testUncertainEndsReleaseUserRecordingsAndNeverBlockARestart() {
        let owned = UUID()
        let confident = MeetingDetectionEnd(sessionID: owned, contentEndedAt: nil)
        let uncertain = MeetingDetectionEnd(sessionID: owned, contentEndedAt: nil, confident: false)
        for startedByUser in [true, false] {
            XCTAssertEqual(confident.action(detectorSessionID: owned, startedByUser: startedByUser),
                           .stop(allowsAutomaticRestart: false))
            XCTAssertEqual(uncertain.action(detectorSessionID: UUID(), startedByUser: startedByUser), .ignore)
            XCTAssertEqual(uncertain.action(detectorSessionID: nil, startedByUser: startedByUser), .ignore)
        }
        XCTAssertEqual(uncertain.action(detectorSessionID: owned, startedByUser: true), .release)
        XCTAssertEqual(uncertain.action(detectorSessionID: owned, startedByUser: false),
                       .stop(allowsAutomaticRestart: true))
    }

    func testRecordingJoinsOnlyTheCallItIsCapturing() {
        let room = URL(string: "https://meet.google.com/abc-defg-hij")!
        let chrome = MeetingDetector.DetectedApp(name: "Google Chrome", bundleID: "com.google.Chrome", pid: 7, meetingURL: room)
        XCTAssertTrue(RecordingController.recordsSameCall(capturedBundleID: "com.google.Chrome",
            recordingURL: URL(string: "https://meet.google.com/abc-defg-hij?authuser=0"), detected: chrome))
        XCTAssertTrue(RecordingController.recordsSameCall(capturedBundleID: "com.google.Chrome",
            recordingURL: nil, detected: chrome))
        XCTAssertFalse(RecordingController.recordsSameCall(capturedBundleID: "com.google.Chrome",
            recordingURL: URL(string: "https://meet.google.com/xyz-uvwx-rst"), detected: chrome))
        XCTAssertFalse(RecordingController.recordsSameCall(capturedBundleID: nil, recordingURL: room, detected: chrome),
                       "A microphone-only recording is not capturing the call")
        XCTAssertFalse(RecordingController.recordsSameCall(capturedBundleID: "us.zoom.xos", recordingURL: nil, detected: chrome))
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
