import XCTest
@testable import LokalBot

final class MediaPlaybackPauseTests: XCTestCase {
    private func target(_ bundleID: String, _ outcome: MediaPlaybackController.ScriptOutcome)
        -> MediaPlaybackController.PausedTarget? {
        MediaPlaybackController.pausedTarget(controlBundleID: bundleID, processNames: ["Player"],
                                             outcome: outcome, token: "token-1")
    }

    func testABrowserCutOffWhilePausingIsStillResumed() {
        for browser in ["com.google.Chrome", "com.apple.Safari", "company.thebrowser.Browser"] {
            XCTAssertEqual(target(browser, .cutOff),
                           .init(controlBundleID: browser, processNames: ["Player"], resumeToken: "token-1"), browser)
        }
        XCTAssertNil(target("com.spotify.client", .cutOff))
    }

    func testOnlyWhatWasPausedIsResumed() {
        XCTAssertEqual(target("com.google.Chrome", .output("browser"))?.resumeToken, "token-1")
        XCTAssertEqual(target("com.spotify.client", .output("player"))?.resumeToken, "player")
        XCTAssertEqual(target("com.apple.QuickTimePlayerX", .output("Demo.mov"))?.resumeToken, "Demo.mov")
        for nothing in ["", "false", "0"] {
            XCTAssertNil(target("com.google.Chrome", .output(nothing)), nothing)
        }
        XCTAssertNil(target("com.google.Chrome", .failed))
    }

    func testResumingMayTakeLongerThanPausing() {
        XCTAssertGreaterThan(MediaPlaybackController.resumeTimeoutSeconds, MediaPlaybackController.pauseTimeoutSeconds)
    }
}
