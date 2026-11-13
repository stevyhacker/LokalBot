import AVFoundation
import XCTest
@testable import LokalBot

/// On 2026-10-01 a 33-minute Meet recording raised two "Recording needs
/// attention" notifications mid-call (a 1.9-second accessibility hiccup and
/// one dropped buffer) and was then marked "Audio capture was interrupted"
/// although every frame was saved.
final class RecordingHealthNotificationTests: XCTestCase {
    private let callStatus = CaptureWarningNotifications.callStatusUnavailableWarning
    private let dropped = CaptureWarningNotifications.droppedBuffersWarning

    func testBriefCallStatusHiccupDoesNotNotify() {
        var policy = CaptureWarningNotifications()
        XCTAssertEqual(policy.due([], elapsed: 1_190), [])
        XCTAssertEqual(policy.due([callStatus], elapsed: 1_191.8), [])
        XCTAssertEqual(policy.due([callStatus], elapsed: 1_193.7), [])
        XCTAssertEqual(policy.due([], elapsed: 1_194.3), [], "observation recovered after 1.9 s")
        XCTAssertEqual(policy.due([callStatus], elapsed: 1_344.6), [], "a new loss starts a new wait")
        XCTAssertEqual(policy.due([], elapsed: 1_369.8), [])
    }

    func testCallStatusLostLongerThanTheDetectorGraceNotifiesOnce() {
        var policy = CaptureWarningNotifications()
        XCTAssertEqual(policy.due([callStatus], elapsed: 100), [])
        XCTAssertEqual(policy.due([callStatus], elapsed: 100 + MeetingDetector.browserObservationGrace),
                       [callStatus])
        XCTAssertEqual(policy.due([callStatus], elapsed: 400), [], "at most once per recording")
    }

    func testDroppedBuffersNeverInterruptTheCall() {
        var policy = CaptureWarningNotifications()
        XCTAssertEqual(policy.due([dropped], elapsed: 10), [])
        XCTAssertEqual(policy.due([dropped], elapsed: 3_600), [])
    }

    func testMissingAudioMustPersistAndDiskWarningsAreImmediate() {
        var policy = CaptureWarningNotifications()
        let audio = "Meeting audio is not arriving. Trying to recover it; the microphone continues."
        let disk = "Disk space is low. Free space now to keep saving this recording."
        XCTAssertEqual(policy.due([audio, disk], elapsed: 20), [disk])
        XCTAssertEqual(policy.due([audio], elapsed: 34), [])
        XCTAssertEqual(policy.due([audio], elapsed: 35), [audio])
    }

    func testOneDroppedBufferIsNotACaptureIssue() {
        var report = RecordingHealthReport()
        report.systemDroppedBuffers = 1
        XCTAssertFalse(report.hasCaptureIssues)
        report.systemDroppedBuffers = RecordingHealthReport.noticeableDroppedBuffers
        XCTAssertTrue(report.hasCaptureIssues)
        report.systemDroppedBuffers = 0
        report.hadMissingAudio = true
        XCTAssertTrue(report.hasCaptureIssues)
    }

    func testBrowsersArePrimedWithoutVoiceOverMode() {
        XCTAssertEqual(BrowserMeetingSession.webAccessibilityPrimingAttribute(bundleID: "com.google.Chrome"),
                       "AXManualAccessibility")
        XCTAssertEqual(BrowserMeetingSession.webAccessibilityPrimingAttribute(bundleID: "company.thebrowser.Browser"),
                       "AXManualAccessibility")
        XCTAssertNil(BrowserMeetingSession.webAccessibilityPrimingAttribute(bundleID: "com.apple.Safari"))
        XCTAssertEqual(BrowserMeetingSession.webAccessibilityPrimingAttribute(bundleID: "org.mozilla.firefox"),
                       "AXEnhancedUserInterface")
    }

    // MARK: - Lock-free buffer ring

    private func buffers(_ count: Int) throws -> [AVAudioPCMBuffer] {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        var result: [AVAudioPCMBuffer] = []
        for _ in 0..<count {
            result.append(try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512)))
        }
        return result
    }

    func testRingHandsOutEachBufferOnceAndReusesReturnedOnes() throws {
        let ring = RealtimeBufferRing(buffers: try buffers(2))
        let first = try XCTUnwrap(ring.borrow())
        let second = try XCTUnwrap(ring.borrow())
        XCTAssertFalse(first === second)
        XCTAssertNil(ring.borrow())
        XCTAssertEqual(ring.availableCount, 0)

        ring.giveBack(first)
        XCTAssertEqual(ring.availableCount, 1)
        XCTAssertTrue(try XCTUnwrap(ring.borrow()) === first)

        ring.giveBack(try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: first.format, frameCapacity: 16)))
        XCTAssertEqual(ring.availableCount, 0, "a foreign buffer is ignored")
        ring.giveBack(first)
        ring.giveBack(second)
        ring.giveBack(second)
        XCTAssertEqual(ring.availableCount, 2, "a double return cannot overfill the ring")
    }

    func testRingStaysConsistentBetweenARealtimeBorrowerAndAWriterQueue() throws {
        let ring = RealtimeBufferRing(buffers: try buffers(4))
        let writer = DispatchQueue(label: "ring-writer")
        let iterations = 20_000
        let done = expectation(description: "borrower finished")
        Thread.detachNewThread {
            var borrowed = 0
            while borrowed < iterations {
                guard let buffer = ring.borrow() else { continue }
                borrowed += 1
                writer.async { ring.giveBack(buffer) }
            }
            done.fulfill()
        }
        wait(for: [done], timeout: 30)
        writer.sync {}
        XCTAssertEqual(ring.availableCount, 4, "every buffer came back exactly once")
    }
}
