import CoreGraphics
import JavaScriptCore
import XCTest
@testable import LokalBot

final class DictationContextBoundaryTests: XCTestCase {
    func testWindowSelectionAbstainsForMissingUnmatchedOrAmbiguousFocus() {
        let small = CGRect(x: 0, y: 0, width: 600, height: 400)
        let large = CGRect(x: 20, y: 20, width: 1_400, height: 900)
        let windows = [DictationWindowCandidate(processID: 42, title: "Reply", frame: small),
                       DictationWindowCandidate(processID: 42, title: "Unrelated document", frame: large)]
        for title in [nil, "", "Missing", "Unrelated"] as [String?] {
            XCTAssertNil(DictationWindowSelector.preferredIndex(in: windows, processID: 42, focusedWindowTitle: title))
        }
        XCTAssertEqual(DictationWindowSelector.preferredIndex(
            in: windows, processID: 42, focusedWindowTitle: "Reply", focusedWindowFrame: small), 0)
        XCTAssertNil(DictationWindowSelector.preferredIndex(
            in: windows + [windows[0]], processID: 42, focusedWindowTitle: "Reply"))
        XCTAssertNil(DictationWindowSelector.preferredIndex(
            in: windows, processID: 42, focusedWindowTitle: "Reply", focusedWindowFrame: large))
    }

    func testComposeUsesDomainPrivateWindowAndSecureFieldExclusions() {
        let target = DictationScreenTarget(processID: 42, appName: "Google Chrome", bundleID: "com.google.Chrome")
        var snapshot = ScreenAccessibilitySnapshot(text: "", sourceURL: "https://blocked.example/doc",
            focusedSecureField: false, windowTitle: "Document", windowFrame: .zero, hasWebContent: true)
        let policy = DictationScreenCapturePolicy(excludedDomains: ["blocked.example"], capturePrivateWindows: true)
        XCTAssertFalse(DictationScreenPrivacy.permits(snapshot, target: target, policy: policy))
        snapshot.sourceURL = "https://allowed.example"
        XCTAssertTrue(DictationScreenPrivacy.permits(snapshot, target: target, policy: policy))
        snapshot.focusedSecureField = nil
        XCTAssertFalse(DictationScreenPrivacy.permits(snapshot, target: target, policy: policy))
        snapshot.focusedSecureField = false
        snapshot.windowTitle = "Incognito"
        XCTAssertFalse(DictationScreenPrivacy.permits(snapshot, target: target, policy: .init()))
    }

    func testContextIdentityRejectsChangedSameAppWindowMetadata() throws {
        let frame = CGRect(x: 20, y: 40, width: 900, height: 700)
        let original = ScreenAccessibilitySnapshot(
            text: "", sourceURL: "https://mail.example/thread/1",
            focusedSecureField: false, windowTitle: "Thread one",
            windowFrame: frame, hasWebContent: true)
        let identity = try XCTUnwrap(DictationScreenContextIdentity(original))

        XCTAssertTrue(identity.matches(original))
        var changedTitle = original
        changedTitle.windowTitle = "Thread two"
        XCTAssertFalse(identity.matches(changedTitle))
        var changedFrame = original
        changedFrame.windowFrame = frame.offsetBy(dx: 300, dy: 0)
        XCTAssertFalse(identity.matches(changedFrame))
        var changedDocument = original
        changedDocument.sourceURL = "https://mail.example/thread/2"
        XCTAssertFalse(identity.matches(changedDocument))
    }

    func testMediaPauseSkipsCallStreamsAndConferenceDocuments() throws {
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript("""
            var location = {hostname: 'video.example'};
            function media(stream, duration) {
              return {paused: false, srcObject: stream, duration: duration, dataset: {},
                      pause: function() { this.paused = true; }};
            }
            var nodes = [media({getTracks: function() {return [];}}, Infinity),
                         media({}, 60), media(null, Infinity), media(null, 60)];
            var document = {querySelectorAll: function() {return nodes;}};
            """)
        let script = MediaPlaybackController.pauseHTMLMediaJavaScript(marker: "fixture")
        XCTAssertEqual(context.evaluateScript(script)?.toInt32(), 1)
        XCTAssertEqual(context.evaluateScript("nodes.map(n => n.paused).join(',')")?.toString(), "false,false,false,true")
        context.evaluateScript("location.hostname = 'meet.google.com'; nodes[3].paused = false;")
        XCTAssertEqual(context.evaluateScript(script)?.toInt32(), 0)
        XCTAssertNil(context.exception)
    }

    func testScreenCredentialsAreRedactedAtTheComposePromptBoundary() {
        let prompt = DictationComposePrompt.userPrompt(spokenText: "Draft a reply", context: .init(
            appName: "Fixture", bundleID: "fixture.app", windowTitle: "password=secretvalue123",
            visibleText: "api_key=examplekey123456"), profile: .none)
        XCTAssertFalse(prompt.contains("secretvalue123"))
        XCTAssertFalse(prompt.contains("examplekey123456"))
        XCTAssertTrue(prompt.contains("[REDACTED]"))
    }
}
