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
                value, excludedApps: [], excludedDomains: ["private.test"],
                capturePrivateWindows: true)
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
        XCTAssertTrue(allowed(observation), "The browser opt-in explicitly accepts unverified private-window status")
    }

    func testUnknownBrowserModeRequiresExplicitOptInRegardlessOfTitleOrLocale() {
        for title in ["Quarterly plan", "Privat", "Navigation privée", ""] {
            let observation = ScreenContextPrivacy.Observation(
                appName: "Safari", bundleIdentifier: "com.apple.Safari",
                windowTitle: title, sourceURL: "https://public.test", focusedSecureField: false)
            XCTAssertFalse(ScreenContextPrivacy.permitsContent(
                observation, excludedApps: [], excludedDomains: [], capturePrivateWindows: false))
            XCTAssertTrue(ScreenContextPrivacy.permitsContent(
                observation, excludedApps: [], excludedDomains: [], capturePrivateWindows: true))
        }
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
            observation, excludedApps: [], excludedDomains: ["private.test"],
            capturePrivateWindows: false))
        observation.hasWebContent = true
        XCTAssertFalse(ScreenContextPrivacy.permitsContent(
            observation, excludedApps: [], excludedDomains: ["private.test"],
            capturePrivateWindows: false))
    }

    func testPrivateWindowOptInDoesNotBypassAppDomainOrSecureFieldExclusions() {
        var observation = ScreenContextPrivacy.Observation(
            appName: "Safari", bundleIdentifier: "com.apple.Safari",
            windowTitle: "Private Window", sourceURL: "https://public.test", focusedSecureField: false)
        XCTAssertFalse(ScreenContextPrivacy.permitsContent(
            observation, excludedApps: [], excludedDomains: [], capturePrivateWindows: false))
        XCTAssertTrue(ScreenContextPrivacy.permitsContent(
            observation, excludedApps: [], excludedDomains: [], capturePrivateWindows: true))
        XCTAssertFalse(ScreenContextPrivacy.permitsContent(
            observation, excludedApps: ["Safari"], excludedDomains: [], capturePrivateWindows: true))
        XCTAssertFalse(ScreenContextPrivacy.permitsContent(
            observation, excludedApps: [], excludedDomains: ["public.test"], capturePrivateWindows: true))
        observation.focusedSecureField = true
        XCTAssertFalse(ScreenContextPrivacy.permitsContent(
            observation, excludedApps: [], excludedDomains: [], capturePrivateWindows: true))
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
