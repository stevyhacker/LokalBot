import XCTest
@testable import LokalBot

final class CotypingMeetingPauseTests: XCTestCase {

    func testRecordingStartPausesFromIdle() {
        XCTAssertEqual(
            CotypingMeetingPause.transition(recordingActive: true, current: .idle),
            .disabled(CotypingMeetingPause.reason))
    }

    func testRecordingStartIsIdempotentWhenAlreadyPaused() {
        XCTAssertNil(CotypingMeetingPause.transition(
            recordingActive: true, current: .disabled(CotypingMeetingPause.reason)))
    }

    func testRecordingEndRestoresIdleOnlyFromOwnPause() {
        XCTAssertEqual(
            CotypingMeetingPause.transition(
                recordingActive: false, current: .disabled(CotypingMeetingPause.reason)),
            .idle)
    }

    func testRecordingEndLeavesForeignDisabledReasonsAlone() {
        XCTAssertNil(CotypingMeetingPause.transition(
            recordingActive: false, current: .disabled("Accessibility permission needed.")))
    }

    func testRecordingEndLeavesIdleAlone() {
        XCTAssertNil(CotypingMeetingPause.transition(recordingActive: false, current: .idle))
    }
}
