import CoreGraphics
import XCTest
@testable import LokalBot

final class PermissionOverlayTrackerTests: XCTestCase {
    private let settingsFrame = CGRect(x: 120, y: 80, width: 720, height: 620)

    func testPresentsWhenSettingsFirstAppears() {
        XCTAssertEqual(
            transition(settingsFrame: settingsFrame, hasPresented: false),
            .present)
    }

    func testHidesOnlyWhenVisibleOverlayLosesSettingsWindow() {
        XCTAssertEqual(
            transition(settingsFrame: nil, hasPresented: true, isVisible: true),
            .hide)
        XCTAssertEqual(
            transition(settingsFrame: nil, hasPresented: true, isVisible: false),
            .none)
    }

    func testRepositionsWhenWindowMovesOrOverlayReturns() {
        let previousFrame = settingsFrame.offsetBy(dx: -40, dy: 20)

        XCTAssertEqual(
            transition(
                settingsFrame: settingsFrame,
                hasPresented: true,
                isVisible: true,
                lastFrame: previousFrame),
            .reposition)
        XCTAssertEqual(
            transition(
                settingsFrame: settingsFrame,
                hasPresented: true,
                isVisible: false,
                lastFrame: settingsFrame),
            .reposition)
    }

    func testStableVisibleWindowDoesNothing() {
        XCTAssertEqual(
            transition(
                settingsFrame: settingsFrame,
                hasPresented: true,
                isVisible: true,
                lastFrame: settingsFrame),
            .none)
    }

    func testOnlyListBasedPermissionsUseDragGuidance() {
        XCTAssertEqual(AppPermission.microphone.guidanceStyle, .nativePrompt)

        for permission in [
            AppPermission.accessibility,
            .inputMonitoring,
            .screenRecording,
        ] {
            XCTAssertEqual(permission.guidanceStyle, .guidedOverlay)
        }
    }

    /// Turning a permission on from the command line started a walkthrough
    /// nothing dismissed: after System Settings was closed, a timer ran three
    /// times a second for the rest of the session.
    func testWalkthroughEndsWhenSystemSettingsIsClosedOrNeverOpens() {
        let grace = PermissionOverlayTracker.launchGraceSeconds
        XCTAssertFalse(PermissionOverlayTracker.shouldEnd(settingsRunning: true, hasPresented: true, secondsTracked: 3_600),
                       "System Settings is still open, perhaps behind another app")
        XCTAssertTrue(PermissionOverlayTracker.shouldEnd(settingsRunning: false, hasPresented: true, secondsTracked: 5),
                      "closed after the overlay was shown")
        XCTAssertFalse(PermissionOverlayTracker.shouldEnd(settingsRunning: false, hasPresented: false, secondsTracked: grace - 1),
                       "System Settings may still be launching")
        XCTAssertTrue(PermissionOverlayTracker.shouldEnd(settingsRunning: false, hasPresented: false, secondsTracked: grace))
    }

    private func transition(
        settingsFrame: CGRect?,
        hasPresented: Bool,
        isVisible: Bool = false,
        lastFrame: CGRect? = nil
    ) -> PermissionOverlayTracker.Transition {
        PermissionOverlayTracker.transition(
            settingsFrame: settingsFrame,
            hasPresented: hasPresented,
            isVisible: isVisible,
            lastFrame: lastFrame)
    }
}
