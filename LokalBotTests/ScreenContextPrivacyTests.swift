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
                capturePrivateWindows: false)
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
        XCTAssertFalse(allowed(observation), "An empty browser title cannot establish private-window status")
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
}
