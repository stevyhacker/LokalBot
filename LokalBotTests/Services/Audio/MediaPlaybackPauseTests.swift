import XCTest
@testable import LokalBot

/// What a dictation resumes after pausing media, by how the pause script ended.
final class MediaPlaybackPauseTests: XCTestCase {
    private func target(_ bundleID: String, _ outcome: MediaPlaybackController.ScriptOutcome)
        -> MediaPlaybackController.PausedTarget? {
        MediaPlaybackController.pausedTarget(controlBundleID: bundleID, processNames: ["Player"],
                                             outcome: outcome, token: "token-1")
    }

    /// With sixty tabs open the browser script paused the video in tab 3 and
    /// was stopped at its time limit before it could report. Nothing was
    /// recorded, so the video stayed paused after the dictation.
    func testABrowserCutOffWhilePausingIsStillResumed() {
        for browser in ["com.google.Chrome", "com.apple.Safari", "company.thebrowser.Browser"] {
            XCTAssertEqual(target(browser, .cutOff),
                           .init(controlBundleID: browser, processNames: ["Player"], resumeToken: "token-1"), browser)
        }
        // A player's script is one command: cut off means it did not run.
        XCTAssertNil(target("com.spotify.client", .cutOff))
    }

    func testOnlyWhatWasPausedIsResumed() {
        XCTAssertEqual(target("com.google.Chrome", .output("browser"))?.resumeToken, "token-1")
        XCTAssertEqual(target("com.spotify.client", .output("player"))?.resumeToken, "player")
        XCTAssertEqual(target("com.apple.QuickTimePlayerX", .output("Demo.mov"))?.resumeToken, "Demo.mov")
        for nothing in ["", "false", "0"] {
            XCTAssertNil(target("com.google.Chrome", .output(nothing)), nothing)
        }
        // The script could not run at all, for example without Automation permission.
        XCTAssertNil(target("com.google.Chrome", .failed))
    }

    func testResumingMayTakeLongerThanPausing() {
        XCTAssertGreaterThan(MediaPlaybackController.resumeTimeoutSeconds, MediaPlaybackController.pauseTimeoutSeconds)
    }
}
