import XCTest
@testable import LokalBot

final class ScreenContextPrivacyTests: XCTestCase {
    func testRedactsCredentialsBeforePersistence() {
        let source = """
        API_KEY=supersecretvalue123
        Authorization: Bearer abcdefghijklmnopqrstuvwxyz
        GitHub ghp_abcdefghijklmnopqrstuvwxyz123456
        OpenAI sk-proj-abcdefghijklmnopqrstuvwxyz123456
        """

        let result = ScreenContextPrivacy.redact(source)

        XCTAssertGreaterThanOrEqual(result.count, 4)
        XCTAssertFalse(result.text.contains("supersecretvalue123"))
        XCTAssertFalse(result.text.contains("abcdefghijklmnopqrstuvwxyz123456"))
        XCTAssertTrue(result.text.contains("[REDACTED"))
    }

    func testPrivateWindowsAndDomainRulesFailClosed() {
        XCTAssertTrue(ScreenContextPrivacy.isPrivateWindow(title: "New Incognito Window"))
        XCTAssertTrue(ScreenContextPrivacy.isPrivateWindow(title: "InPrivate browsing"))
        XCTAssertFalse(ScreenContextPrivacy.isPrivateWindow(title: "Quarterly plan"))

        XCTAssertTrue(ScreenContextPrivacy.isExcluded(
            sourceURL: "https://docs.private.test/report",
            rules: ["*.private.test"]))
        XCTAssertTrue(ScreenContextPrivacy.isExcluded(
            sourceURL: "https://example.com/account/billing",
            rules: ["example.com/account"]))
        XCTAssertFalse(ScreenContextPrivacy.isExcluded(
            sourceURL: "https://example.com.evil.test/account",
            rules: ["example.com"]))
    }

    func testMetadataSanitizationDropsSecretsAndLocalPaths() {
        XCTAssertEqual(
            ScreenContextPrivacy.sanitizedURL(
                "https://alice:password@example.com/private/report?token=secret#section"),
            "https://example.com/private/report")
        XCTAssertEqual(
            ScreenContextPrivacy.sanitizedDocumentName(
                "file:///Users/alice/Private/Launch%20Plan.md"),
            "Launch Plan.md")
    }

    func testRichTextThresholdAvoidsTreatingLabelsAsDocumentContext() {
        XCTAssertFalse(ScreenContextPrivacy.hasRichAccessibleText("Save Cancel Name"))
        XCTAssertTrue(ScreenContextPrivacy.hasRichAccessibleText(String(repeating: "context ", count: 12)))
    }

    func testContentPolicyRejectsUnknownBrowserURLAndSecureFieldState() {
        var observation = ScreenContextPrivacy.Observation(
            appName: "Safari", bundleIdentifier: "com.apple.Safari",
            windowTitle: "Account", sourceURL: nil, focusedSecureField: false)
        func allowed(_ value: ScreenContextPrivacy.Observation) -> Bool {
            ScreenContextPrivacy.permitsContent(
                value, excludedApps: [], excludedDomains: ["private.test"])
        }
        XCTAssertFalse(allowed(observation), "An unreadable browser address cannot establish domain consent")
        observation.sourceURL = "https://private.test/account"
        XCTAssertFalse(allowed(observation))
        observation.sourceURL = "https://public.test/document"
        XCTAssertTrue(allowed(observation))
        observation.focusedSecureField = nil
        XCTAssertFalse(allowed(observation), "AX failures must not become a safe-field result")
        observation.focusedSecureField = true
        XCTAssertFalse(allowed(observation))
        observation.focusedSecureField = false
        observation.windowTitle = nil
        XCTAssertFalse(allowed(observation))
        observation.windowTitle = ""
        XCTAssertTrue(allowed(observation), "An untitled browser window is still tracked")
    }

    func testBrowserWebAppAndPrivateWindowsAreTrackedRegardlessOfTitleOrLocale() {
        for title in ["Quarterly plan", "Privat", "Navigation privée", "New Incognito Window", ""] {
            let observation = ScreenContextPrivacy.Observation(
                appName: "Safari", bundleIdentifier: "com.apple.Safari",
                windowTitle: title, sourceURL: "https://public.test", focusedSecureField: false)
            XCTAssertTrue(ScreenContextPrivacy.permitsContent(
                observation, excludedApps: [], excludedDomains: []), title)
        }
        var webApp = ScreenContextPrivacy.Observation(
            appName: "Claude", bundleIdentifier: "com.anthropic.claudefordesktop",
            windowTitle: "Claude", sourceURL: nil, focusedSecureField: false)
        webApp.hasWebContent = true
        XCTAssertTrue(ScreenContextPrivacy.permitsContent(webApp, excludedApps: [], excludedDomains: []),
                      "Web-based desktop apps are tracked like native apps")
    }

    func testScreenCaptureAcceptsUnknownFocusOnlyWithoutVisibleSecureFields() {
        // Chrome exposes window titles and text but not keyboard focus.
        var chrome = ScreenContextPrivacy.Observation(
            appName: "Google Chrome", bundleIdentifier: "com.google.Chrome",
            windowTitle: "Meet - Product Standup", sourceURL: nil, focusedSecureField: nil)
        chrome.hasWebContent = true
        func capture(_ observation: ScreenContextPrivacy.Observation, domains: [String] = []) -> Bool {
            ScreenContextPrivacy.permitsContent(
                observation, excludedApps: [], excludedDomains: domains, allowsUnknownFocus: true)
        }
        XCTAssertTrue(capture(chrome))
        XCTAssertFalse(ScreenContextPrivacy.permitsContent(chrome, excludedApps: [], excludedDomains: []),
                       "Other consumers still require a known, non-secure focus")
        chrome.containsSecureField = true
        XCTAssertFalse(capture(chrome), "A visible password field keeps an unknown-focus window out")
        chrome.containsSecureField = false
        XCTAssertFalse(capture(chrome, domains: ["private.test"]),
                       "An unreadable address still cannot rule out a site exclusion")
        chrome.focusedSecureField = true
        XCTAssertFalse(capture(chrome))
    }

    func testOnlyInputsCountAsVisibleSecureFields() {
        XCTAssertTrue(ScreenAccessibilityReader.isTextEntry(role: "AXTextField"))
        XCTAssertTrue(ScreenAccessibilityReader.isTextEntry(role: "AXSecureTextField"))
        XCTAssertFalse(ScreenAccessibilityReader.isTextEntry(role: "AXButton"),
                       "Chrome's 'Connection is secure' and 'Manage passwords' buttons are not inputs")
        XCTAssertFalse(ScreenAccessibilityReader.isTextEntry(role: "AXStaticText"))
        XCTAssertFalse(ScreenAccessibilityReader.isTextEntry(role: nil))
    }

    func testCaptureValidationRejectsSecureFieldsAppearingDuringCapture() {
        let expected = ScreenAccessibilitySnapshot(
            text: "", sourceURL: nil, documentName: nil, focusedSecureField: nil,
            windowTitle: "Meet", windowFrame: CGRect(x: 0, y: 0, width: 10, height: 10))
        var current = expected
        XCTAssertTrue(ScreenshotWindowFocusValidation.matches(
            expected: expected, current: .init(snapshot: current, timedOut: false)))
        current.containsSecureField = true
        XCTAssertFalse(ScreenshotWindowFocusValidation.matches(
            expected: expected, current: .init(snapshot: current, timedOut: false)))
        current.containsSecureField = false
        current.focusedSecureField = false
        XCTAssertTrue(ScreenshotWindowFocusValidation.matches(
            expected: expected, current: .init(snapshot: current, timedOut: false)),
                      "Learning that an unknown focus is a plain field keeps the pixels")
        current.focusedSecureField = true
        XCTAssertFalse(ScreenshotWindowFocusValidation.matches(
            expected: expected, current: .init(snapshot: current, timedOut: false)),
                       "Focus moving into a secure field during capture discards the pixels")
    }

    func testReadKeepsOnlyAnUnknownFocusThatTurnsOutPlain() {
        XCTAssertTrue(ScreenAccessibilityReader.settledFocus(before: nil, after: false) == (true, false),
                      "Chrome exposes focus only after its tree is read")
        XCTAssertTrue(ScreenAccessibilityReader.settledFocus(before: false, after: false) == (true, false))
        XCTAssertTrue(ScreenAccessibilityReader.settledFocus(before: nil, after: nil) == (true, nil))
        XCTAssertFalse(ScreenAccessibilityReader.settledFocus(before: nil, after: true).accepted)
        XCTAssertFalse(ScreenAccessibilityReader.settledFocus(before: false, after: true).accepted)
        XCTAssertFalse(ScreenAccessibilityReader.settledFocus(before: false, after: nil).accepted)
        XCTAssertFalse(ScreenAccessibilityReader.settledFocus(before: true, after: false).accepted)
    }

    func testVisibleTextPolicyDoesNotReadWholeDocumentsOrClippedLabels() {
        let viewport = CGRect(x: 0, y: 0, width: 100, height: 100)
        let frame = CGRect(x: 10, y: 10, width: 80, height: 80)
        XCTAssertEqual(ScreenVisibleTextPolicy.text(
            role: "AXTextArea", frame: frame, viewport: viewport, hidden: false,
            title: "document title", visibleRangeText: "visible paragraph", staticValue: "entire document"),
                       ["visible paragraph"])
        XCTAssertEqual(ScreenVisibleTextPolicy.text(
            role: "AXTextArea", frame: frame, viewport: viewport, hidden: false,
            title: nil, visibleRangeText: nil, staticValue: "entire document"), [])
        for bounds in [CGRect(x: 90, y: 90, width: 30, height: 30), CGRect(x: 200, y: 200, width: 30, height: 30)] {
            XCTAssertEqual(ScreenVisibleTextPolicy.text(
                role: "AXStaticText", frame: bounds, viewport: viewport, hidden: false,
                title: "clipped", visibleRangeText: nil, staticValue: "hidden text"), [])
        }
        XCTAssertEqual(ScreenVisibleTextPolicy.text(
            role: "AXStaticText", frame: frame, viewport: viewport, hidden: true,
            title: "hidden", visibleRangeText: "hidden", staticValue: "hidden"), [])
        XCTAssertEqual(ScreenVisibleTextPolicy.text(
            role: "AXStaticText", frame: frame, viewport: nil, hidden: false,
            title: "unknown viewport", visibleRangeText: nil, staticValue: "hidden"), [])
    }

    func testDomainRulesAllowNativeDocumentsButRejectUnknownEmbeddedWebOrigins() {
        var observation = ScreenContextPrivacy.Observation(
            appName: "Editor", bundleIdentifier: "test.editor",
            windowTitle: "Work.swift", sourceURL: nil, focusedSecureField: false)
        XCTAssertTrue(ScreenContextPrivacy.permitsContent(
            observation, excludedApps: [], excludedDomains: ["private.test"]))
        observation.hasWebContent = true
        XCTAssertFalse(ScreenContextPrivacy.permitsContent(
            observation, excludedApps: [], excludedDomains: ["private.test"]))
    }

    func testActivityKeepsAppNamesUnlessTheAppOrKnownSiteIsExcluded() {
        func disposition(_ observation: ScreenContextPrivacy.Observation?, apps: [String] = [],
                         domains: [String] = []) -> ScreenContextPrivacy.ActivityDisposition {
            ScreenContextPrivacy.activityDisposition(
                appName: "Claude", observation: observation, excludedApps: apps, excludedDomains: domains)
        }
        var webApp = ScreenContextPrivacy.Observation(
            appName: "Claude", bundleIdentifier: "com.anthropic.claudefordesktop",
            windowTitle: "Planning chat", sourceURL: nil, focusedSecureField: nil)
        webApp.hasWebContent = true
        XCTAssertEqual(disposition(webApp), .init(keepsApp: true, keepsTitle: true))
        XCTAssertEqual(disposition(nil), .init(keepsApp: true, keepsTitle: false))
        XCTAssertEqual(disposition(webApp, apps: ["claude"]), .init(keepsApp: false, keepsTitle: false))
        XCTAssertEqual(disposition(webApp, domains: ["private.test"]), .init(keepsApp: true, keepsTitle: false))
        webApp.sourceURL = "https://private.test/chat"
        XCTAssertEqual(disposition(webApp, domains: ["private.test"]), .init(keepsApp: false, keepsTitle: false))
        webApp.sourceURL = nil
        webApp.focusedSecureField = true
        XCTAssertEqual(disposition(webApp), .init(keepsApp: true, keepsTitle: false))
    }

    func testPrivateWindowsStillRespectAppDomainAndSecureFieldExclusions() {
        var observation = ScreenContextPrivacy.Observation(
            appName: "Safari", bundleIdentifier: "com.apple.Safari",
            windowTitle: "Private Window", sourceURL: "https://public.test", focusedSecureField: false)
        XCTAssertTrue(ScreenContextPrivacy.permitsContent(
            observation, excludedApps: [], excludedDomains: []))
        XCTAssertFalse(ScreenContextPrivacy.permitsContent(
            observation, excludedApps: ["Safari"], excludedDomains: []))
        XCTAssertFalse(ScreenContextPrivacy.permitsContent(
            observation, excludedApps: [], excludedDomains: ["public.test"]))
        observation.focusedSecureField = true
        XCTAssertFalse(ScreenContextPrivacy.permitsContent(
            observation, excludedApps: [], excludedDomains: []))
    }

    func testScreenAccessibilityReaderTimeoutReturnsNoPartialPrivacySnapshot() async {
        let reader = ScreenAccessibilityReader(deadlineMilliseconds: 10) { _ in
            Thread.sleep(forTimeInterval: 0.1)
            return .init(text: "Late", sourceURL: "https://public.test", documentName: nil,
                         focusedSecureField: false, windowTitle: "Late", windowFrame: nil)
        }
        let result = await reader.capture(processID: 42)

        XCTAssertTrue(result.timedOut)
        XCTAssertNil(result.snapshot)
    }

    /// macOS answers an app's accessibility queries about itself in-process on
    /// the calling thread, which runs SwiftUI off the main actor and traps.
    /// Sampling while LokalBot is frontmost must never reach the resolver.
    func testScreenAccessibilityReaderNeverResolvesLokalBotItself() async {
        let calls = LockedCounter()
        let reader = ScreenAccessibilityReader(deadlineMilliseconds: 50) { _ in
            calls.increment()
            return .init(text: "Own UI", sourceURL: nil, documentName: nil,
                         focusedSecureField: false, windowTitle: "LokalBot", windowFrame: nil)
        }
        let own = await reader.capture(processID: ProcessInfo.processInfo.processIdentifier)
        XCTAssertNil(own.snapshot)
        XCTAssertFalse(own.timedOut)
        XCTAssertEqual(calls.value, 0)
        XCTAssertNil(ScreenAccessibilityReader.resolve(processID: ProcessInfo.processInfo.processIdentifier))

        let other = await reader.capture(processID: 42)
        XCTAssertEqual(other.snapshot?.windowTitle, "LokalBot")
        XCTAssertEqual(calls.value, 1)
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}
