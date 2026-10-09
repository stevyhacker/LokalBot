import XCTest
@testable import LokalBot

/// The dictation HUD's shapes and placement. The HUD used to jump at startup
/// and between states: the panel and its SwiftUI content were sized by two
/// separate rules, starting showed a different capsule from recording, and a
/// resized panel re-centered whatever was drawn inside it.
@MainActor
final class DictationOverlayLayoutTests: XCTestCase {

    func testStartingOpensAtTheShapeRecordingKeeps() throws {
        for live in [false, true] {
            let starting = try XCTUnwrap(content(isStarting: true, state: .idle, live: live))
            let recordingWhileStarting = try XCTUnwrap(content(
                isStarting: true, state: .recording(startedAt: Date()), live: live))
            let recording = try XCTUnwrap(content(
                isStarting: false, state: .recording(startedAt: Date()), live: live))
            XCTAssertEqual(starting.layout, recording.layout, "live preview \(live)")
            XCTAssertEqual(starting.face, recording.face, "no cross-fade when recording begins (live \(live))")
            XCTAssertEqual(recordingWhileStarting.face, recording.face)
        }
    }

    func testCompactActivitiesShareOnePillSize() throws {
        let states: [DictationCoordinator.State] = [
            .recording(startedAt: Date()), .transcribing(startedAt: Date()), .composing(startedAt: Date()),
        ]
        for state in states {
            XCTAssertEqual(try XCTUnwrap(content(state: state)).layout, .pill, "\(state)")
        }
    }

    func testMicrophoneStatusWidensThePillOnlyWhileListening() throws {
        let status = "Reconnecting microphone"
        XCTAssertEqual(try XCTUnwrap(content(
            state: .recording(startedAt: Date()), captureStatus: status)).layout, .statusPill)
        let transcribing = try XCTUnwrap(content(
            state: .transcribing(startedAt: Date()), captureStatus: status))
        XCTAssertEqual(transcribing.layout, .pill)
        XCTAssertEqual(transcribing.captureStatus, "")
    }

    func testTranscriptPanelKeepsOneFaceWhenRecordingEnds() throws {
        let recording = try XCTUnwrap(content(state: .recording(startedAt: Date()), live: true))
        let finalizing = try XCTUnwrap(content(state: .transcribing(startedAt: Date()), live: true))
        XCTAssertEqual(recording.face, finalizing.face, "the transcript must not blink as recording ends")
        XCTAssertEqual(finalizing.layout, .transcript)
    }

    func testPreparationAndNoticeAndIdle() throws {
        let preparing = try XCTUnwrap(content(
            state: .transcribing(startedAt: Date()), showsPreparation: true))
        XCTAssertEqual(preparing.layout, .preparation)
        let notice = try XCTUnwrap(content(state: .idle, notice: DictationDeliveryNotice(text: "Hi")))
        XCTAssertEqual(notice.layout, .notice)
        XCTAssertNil(content(state: .idle), "an idle HUD shows nothing")
    }

    func testMicrophoneIsLiveOnlyWhileListening() throws {
        XCTAssertTrue(try XCTUnwrap(content(
            state: .recording(startedAt: Date()), microphoneLive: true)).microphoneLive)
        XCTAssertFalse(try XCTUnwrap(content(
            state: .transcribing(startedAt: Date()), microphoneLive: true)).microphoneLive)
    }

    /// The canvas never moves on screen, whatever size the panel takes, and
    /// every capsule sits with its bottom-center on the anchor.
    func testCanvasStaysPutOnScreenAcrossPanelSizes() {
        let anchor = DictationOverlayGeometry.anchor(in: NSRect(x: 0, y: 25, width: 1511, height: 920))
        XCTAssertEqual(anchor, CGPoint(x: 756, y: 73))
        let margins = DictationOverlayGeometry.margins
        let canvas = DictationOverlayGeometry.canvasSize
        var canvasOrigins = Set<String>()
        for layout in DictationOverlayContent.Layout.allCases {
            let size = layout.size
            let panel = DictationOverlayGeometry.panelFrame(contentSize: size, anchor: anchor)
            let origin = DictationOverlayGeometry.canvasOrigin(inPanelOfSize: panel.size)
            let canvasOnScreen = CGPoint(x: panel.minX + origin.x, y: panel.minY + origin.y)
            canvasOrigins.insert("\(canvasOnScreen)")
            XCTAssertEqual(panel.minX, panel.minX.rounded(), "\(layout) panel stays on whole points")
            XCTAssertEqual(origin.x, origin.x.rounded(), "\(layout) canvas stays on whole points")

            // The capsule, bottom-centered in the canvas above the bottom margin.
            let capsule = CGRect(
                x: canvasOnScreen.x + (canvas.width - size.width) / 2,
                y: canvasOnScreen.y + margins.bottom,
                width: size.width,
                height: size.height)
            XCTAssertEqual(capsule.midX, anchor.x, "\(layout)")
            XCTAssertEqual(capsule.minY, anchor.y, "\(layout)")
            XCTAssertTrue(panel.contains(capsule), "\(layout) capsule fits its panel")
            XCTAssertEqual(capsule.minX - panel.minX, margins.left, "\(layout) shadow room")
            XCTAssertEqual(panel.maxY - capsule.maxY, margins.top, "\(layout) shadow room")
        }
        XCTAssertEqual(canvasOrigins.count, 1, "the canvas must not shift when the panel resizes")
    }

    func testLevelBarsPutTheNewestReadingInTheMiddle() {
        XCTAssertEqual(AudioLevelBars.mirrored([0.1, 0.2, 0.9]), [0.1, 0.2, 0.9, 0.2, 0.1])
        XCTAssertEqual(AudioLevelBars.mirrored([0.4]), [0.4])
        XCTAssertEqual(AudioLevelBars.envelope(index: 5, count: 11), 1)
        XCTAssertEqual(AudioLevelBars.envelope(index: 0, count: 11), 0.55, accuracy: 0.0001)
        XCTAssertEqual(AudioLevelBars.envelope(index: 10, count: 11), 0.55, accuracy: 0.0001)
    }

    func testLevelFollowerRisesFasterThanItFalls() {
        let follower = AudioLevelFollower()
        let start = Date()
        XCTAssertEqual(follower.follow([0], at: start), [0])
        let rising = follower.follow([1], at: start.addingTimeInterval(1.0 / 30))[0]
        XCTAssertGreaterThan(rising, 0.4)
        XCTAssertLessThan(rising, 1)
        var settled: Float = rising
        for frame in 2...30 {
            settled = follower.follow([1], at: start.addingTimeInterval(Double(frame) / 30))[0]
        }
        XCTAssertEqual(settled, 1, accuracy: 0.01)
        let falling = follower.follow([0], at: start.addingTimeInterval(31.0 / 30))[0]
        XCTAssertGreaterThan(1 - falling, 0)
        XCTAssertLessThan(1 - falling, rising, "a level meter falls slower than it rises")
    }

    private func content(
        isStarting: Bool = false,
        state: DictationCoordinator.State,
        live: Bool = false,
        showsPreparation: Bool = false,
        notice: DictationDeliveryNotice? = nil,
        microphoneLive: Bool = false,
        captureStatus: String = ""
    ) -> DictationOverlayContent? {
        DictationOverlayContent.make(
            isStarting: isStarting,
            state: state,
            showsLiveTranscript: live,
            showsModelPreparation: showsPreparation,
            preparation: ModelPreparationPresentation(
                state: .preparing, title: "Preparing", status: "Checking…"),
            preparationFailed: false,
            notice: notice,
            microphoneLive: microphoneLive,
            captureStatus: captureStatus,
            timer: "00:03",
            transcript: DictationLiveTranscript())
    }
}
