import AppKit
import XCTest
@testable import LokalBot

// MARK: - App/window (surface) context

final class CotypingSurfaceContextTests: XCTestCase {
    func testClassifier() {
        XCTAssertEqual(CotypingSurfaceClassifier.classify(bundleID: "com.tinyspeck.slackmacgap"), .chat)
        XCTAssertEqual(CotypingSurfaceClassifier.classify(bundleID: "com.apple.mail"), .email)
        XCTAssertEqual(CotypingSurfaceClassifier.classify(bundleID: "com.google.Chrome"), .browser)
        XCTAssertEqual(CotypingSurfaceClassifier.classify(bundleID: "com.apple.dt.Xcode"), .codeEditor)
        XCTAssertEqual(CotypingSurfaceClassifier.classify(bundleID: "com.apple.Terminal"), .terminal)
        XCTAssertEqual(CotypingSurfaceClassifier.classify(bundleID: "com.mitchellh.ghostty"), .terminal)
        XCTAssertEqual(CotypingSurfaceClassifier.classify(bundleID: "io.rio.terminal"), .terminal)
        XCTAssertEqual(CotypingSurfaceClassifier.classify(bundleID: "com.microsoft.VSCode", isIntegratedTerminal: true), .terminal)
        XCTAssertEqual(CotypingSurfaceClassifier.classify(bundleID: "com.acme.unknown"), .other)
        XCTAssertEqual(CotypingSurfaceClassifier.classify(bundleID: nil), .other)
    }

    func testIntegratedTerminalClassDetection() {
        XCTAssertTrue(CotypingSurfaceClassifier.isIntegratedTerminal(domClassList: ["xterm-helper-textarea"]))
        XCTAssertTrue(CotypingSurfaceClassifier.isIntegratedTerminal(domClassList: ["xterm-screen"]))
        XCTAssertFalse(CotypingSurfaceClassifier.isIntegratedTerminal(domClassList: ["monaco-editor"]))
        XCTAssertFalse(CotypingSurfaceClassifier.isIntegratedTerminal(domClassList: []))
    }

    func testSuppressedInCodeEditorAndTerminal() {
        XCTAssertNil(CotypingSurfaceComposer.compose(
            appName: "Xcode", bundleID: "com.apple.dt.Xcode", windowTitle: "main.swift", fieldPlaceholder: nil))
        XCTAssertNil(CotypingSurfaceComposer.compose(
            appName: "Terminal", bundleID: "com.apple.Terminal", windowTitle: "bash", fieldPlaceholder: nil))
        XCTAssertNil(CotypingSurfaceComposer.compose(
            appName: "Code",
            bundleID: "com.microsoft.VSCode",
            windowTitle: "Cloud Shell",
            fieldPlaceholder: nil,
            isIntegratedTerminal: true))
    }

    func testGenericAppWithNoCuesIsNil() {
        XCTAssertNil(CotypingSurfaceComposer.compose(
            appName: "SomeApp", bundleID: "com.acme.app", windowTitle: nil, fieldPlaceholder: nil))
    }

    func testGenericUntitledDocumentDoesNotBecomeContext() {
        XCTAssertNil(CotypingSurfaceComposer.compose(
            appName: "TextEdit",
            bundleID: "com.apple.TextEdit",
            windowTitle: "Untitled - TextEdit",
            fieldPlaceholder: nil))
    }

    func testEmailPrefaceLines() throws {
        let surface = try XCTUnwrap(CotypingSurfaceComposer.compose(
            appName: "Mail", bundleID: "com.apple.mail", windowTitle: "Re: Q3 planning", fieldPlaceholder: nil))
        let lines = CotypingSurfaceComposer.prefaceLines(for: surface)
        XCTAssertEqual(lines, ["Subject: Re: Q3 planning"])
    }

    func testTitleStripsAppSuffix() {
        XCTAssertEqual(CotypingSurfaceComposer.sanitizedTitle("Inbox - Gmail", applicationName: "Gmail"), "Inbox")
        XCTAssertEqual(CotypingSurfaceComposer.sanitizedTitle("Notes — Pages", applicationName: "Pages"), "Notes")
    }

    func testChatPlaceholderLine() throws {
        let surface = try XCTUnwrap(CotypingSurfaceComposer.compose(
            appName: "Slack", bundleID: "com.tinyspeck.slackmacgap", windowTitle: nil, fieldPlaceholder: "Message #general"))
        let lines = CotypingSurfaceComposer.prefaceLines(for: surface)
        XCTAssertEqual(lines, ["Topic: #general"])
    }

    func testPromptPutsSurfaceFirst() {
        let prompt = CotypingPromptRenderer.prompt(
            prefixText: "Thanks for", surfaceLines: ["An email being written in Mail."], userName: "Sam")
        XCTAssertEqual(prompt, "An email being written in Mail.\nWritten by Sam.\n\nThanks for")
    }

    func testRequestBuilderFoldsAppContextWhenEnabled() throws {
        let field = CotypingField(
            appName: "Mail", bundleID: "com.apple.mail", processID: 1, role: "AXTextArea",
            precedingText: "Hi Sarah,", trailingText: "", selectionLength: 0,
            caretRect: .zero, isSecure: false, caretIsExact: true,
            windowTitle: "Re: Q3 planning", fieldPlaceholder: nil)
        let on = CotypingPersonalization(
            userName: nil, styleNote: nil, languageHint: nil, isMultiLine: false, appContextEnabled: true)
        let req = try XCTUnwrap(CotypingRequestBuilder.build(field: field, config: .standard, personalization: on, generation: 0))
        XCTAssertTrue(req.prompt.hasPrefix("Subject: Re: Q3 planning\n\n"))
        XCTAssertTrue(req.prompt.contains("Re: Q3 planning"))
        XCTAssertTrue(req.prompt.hasSuffix("Hi Sarah,"))
        XCTAssertEqual(
            req.conditioningPreface,
            "Subject: Re: Q3 planning")

        let off = CotypingPersonalization(
            userName: nil, styleNote: nil, languageHint: nil, isMultiLine: false, appContextEnabled: false)
        let reqOff = try XCTUnwrap(CotypingRequestBuilder.build(field: field, config: .standard, personalization: off, generation: 0))
        XCTAssertEqual(reqOff.prompt, "Hi Sarah,")
        XCTAssertNil(reqOff.conditioningPreface)
    }

    func testAppContextSettingDefaultsOnAndRoundTrips() throws {
        XCTAssertTrue(AppSettings().cotypingUseAppContext)
        var s = AppSettings()
        s.cotypingUseAppContext = false
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(s))
        XCTAssertFalse(decoded.cotypingUseAppContext)
        XCTAssertFalse(decoded.cotypingPersonalization.appContextEnabled)
    }

    func testGenericFieldLabelDoesNotSteerTextTowardTheInterface() throws {
        let surface = try XCTUnwrap(CotypingSurfaceComposer.compose(
            appName: "Messages", bundleID: "com.apple.MobileSMS", windowTitle: nil, fieldPlaceholder: "Message"))
        XCTAssertTrue(CotypingSurfaceComposer.prefaceLines(for: surface).isEmpty)
    }

    func testSurfaceCaptureCacheReusesSameFocusedFieldSession() {
        var cache = CotypingSurfaceCaptureCache()
        let key = CotypingSurfaceCaptureCache.key(
            processID: 42,
            bundleID: "com.google.Chrome",
            role: "AXTextArea",
            subrole: nil,
            focusIdentityKey: "compose-field",
            inputFrameRect: CGRect(x: 10.2, y: 20.6, width: 300.1, height: 44.0),
            includeSurface: true,
            includeURL: true)
        var resolveCount = 0

        let first = cache.capture(forKey: key) {
            resolveCount += 1
            return CotypingSurfaceCapture(
                windowTitle: "Inbox - Gmail",
                fieldPlaceholder: "Message",
                urlString: "https://mail.google.com/mail/u/0/#inbox")
        }
        let second = cache.capture(forKey: key) {
            resolveCount += 1
            return CotypingSurfaceCapture(
                windowTitle: "Inbox (1) - Gmail",
                fieldPlaceholder: "Reply",
                urlString: "https://mail.google.com/mail/u/0/#inbox")
        }

        XCTAssertEqual(resolveCount, 1)
        XCTAssertEqual(first, second)
        XCTAssertEqual(second.windowTitle, "Inbox - Gmail")
        XCTAssertEqual(second.fieldPlaceholder, "Message")
    }

    func testSurfaceCaptureCacheRefreshesForDifferentFocusedField() {
        var cache = CotypingSurfaceCaptureCache()
        let firstKey = CotypingSurfaceCaptureCache.key(
            processID: 42,
            bundleID: "com.tinyspeck.slackmacgap",
            role: "AXTextArea",
            subrole: nil,
            focusIdentityKey: "message-a",
            inputFrameRect: CGRect(x: 10, y: 20, width: 300, height: 44),
            includeSurface: true,
            includeURL: false)
        let secondKey = CotypingSurfaceCaptureCache.key(
            processID: 42,
            bundleID: "com.tinyspeck.slackmacgap",
            role: "AXTextArea",
            subrole: nil,
            focusIdentityKey: "message-b",
            inputFrameRect: CGRect(x: 10, y: 20, width: 300, height: 44),
            includeSurface: true,
            includeURL: false)
        var resolveCount = 0

        _ = cache.capture(forKey: firstKey) {
            resolveCount += 1
            return CotypingSurfaceCapture(windowTitle: "#general", fieldPlaceholder: "Message #general", urlString: nil)
        }
        let refreshed = cache.capture(forKey: secondKey) {
            resolveCount += 1
            return CotypingSurfaceCapture(windowTitle: "#support", fieldPlaceholder: "Message #support", urlString: nil)
        }

        XCTAssertEqual(resolveCount, 2)
        XCTAssertEqual(refreshed.windowTitle, "#support")
        XCTAssertEqual(refreshed.fieldPlaceholder, "Message #support")
    }

    func testSurfaceCaptureCacheSeparatesURLAndSurfaceRequests() {
        var cache = CotypingSurfaceCaptureCache()
        let fieldFrame = CGRect(x: 10, y: 20, width: 300, height: 44)
        let surfaceOnlyKey = CotypingSurfaceCaptureCache.key(
            processID: 42,
            bundleID: "com.google.Chrome",
            role: "AXTextArea",
            subrole: nil,
            focusIdentityKey: "compose-field",
            inputFrameRect: fieldFrame,
            includeSurface: true,
            includeURL: false)
        let surfaceAndURLKey = CotypingSurfaceCaptureCache.key(
            processID: 42,
            bundleID: "com.google.Chrome",
            role: "AXTextArea",
            subrole: nil,
            focusIdentityKey: "compose-field",
            inputFrameRect: fieldFrame,
            includeSurface: true,
            includeURL: true)
        var resolveCount = 0

        _ = cache.capture(forKey: surfaceOnlyKey) {
            resolveCount += 1
            return CotypingSurfaceCapture(windowTitle: "Inbox - Gmail", fieldPlaceholder: "Message", urlString: nil)
        }
        let withURL = cache.capture(forKey: surfaceAndURLKey) {
            resolveCount += 1
            return CotypingSurfaceCapture(
                windowTitle: "Inbox - Gmail",
                fieldPlaceholder: "Message",
                urlString: "https://mail.google.com/mail/u/0/#inbox")
        }

        XCTAssertEqual(resolveCount, 2)
        XCTAssertEqual(withURL.urlString, "https://mail.google.com/mail/u/0/#inbox")
    }

    /// Chat apps keep one composer across conversations. The window title the
    /// prompt and the saved-fact lookup use must follow the conversation, not
    /// stay as long as the field keeps focus; one suggestion's reads still
    /// share a capture.
    func testAComposerReusedAcrossConversationsReadsTheNewTitle() {
        let store = CotypingSurfaceCaptureSingleFlight()
        var now: TimeInterval = 100
        var title = "Atlas conversation"
        var reads = 0
        func surfaceTitle() -> String? {
            CotypingAXHelper.cachedSurfaceCapture(in: store, forKey: "composer", clock: { now }) {
                reads += 1
                return CotypingSurfaceCapture(windowTitle: title, fieldPlaceholder: nil, urlString: nil)
            }.windowTitle
        }

        XCTAssertEqual(surfaceTitle(), "Atlas conversation")
        title = "Borealis conversation"
        now += 0.3
        XCTAssertEqual(surfaceTitle(), "Atlas conversation", "a suggestion's validation reuses its prediction read")
        now += 2
        XCTAssertEqual(surfaceTitle(), "Borealis conversation")
        XCTAssertEqual(reads, 2)
    }
}
