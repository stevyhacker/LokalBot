import ApplicationServices
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

    func testRedactsEnvStyleNamesProviderTokensAndURLPasswords() {
        // Assembled at run time so the source never holds a token-shaped literal.
        let stripe = "sk_" + "live_" + String(repeating: "a", count: 24)
        let slack = "xox" + "b-" + String(repeating: "1", count: 12) + "-" + String(repeating: "b", count: 12)
        let google = "AI" + "za" + String(repeating: "c", count: 35)
        let fineGrained = "github_" + "pat_" + String(repeating: "d", count: 30)
        let awsSecret = "wJalrXUtnFEMI" + "K7MDENGbPxRfiCY"
        let source = """
        DB_PASSWORD=hunter2222
        aws_secret_access_key = \(awsSecret)
        GITHUB_TOKEN: \(fineGrained)
        STRIPE_KEY \(stripe)
        slack \(slack) and \(google)
        DATABASE_URL=postgres://admin:\("s3cret" + "Pass")@db.internal:5432/app
        """

        let result = ScreenContextPrivacy.redact(source)

        for secret in ["hunter2222", awsSecret, fineGrained, stripe, slack, google, "s3cretPass"] {
            XCTAssertFalse(result.text.contains(secret), "\(secret) survived:\n\(result.text)")
        }
        XCTAssertTrue(result.text.contains("DB_PASSWORD=[REDACTED]"), result.text)
        XCTAssertTrue(result.text.contains("postgres://admin:[REDACTED]@db.internal:5432/app"), result.text)
        XCTAssertEqual(result.count, 7)
    }

    func testRedactsCardNumbersAndIBANsOnlyWithValidChecksums() {
        let source = "Visa 4111 1111 1111 1111, Amex 3782-822463-10005, MC 5555555555554444, IBAN DE89 3704 0044 0532 0130 00."

        let result = ScreenContextPrivacy.redact(source)

        XCTAssertEqual(result.text, "Visa [REDACTED_CARD], Amex [REDACTED_CARD], MC [REDACTED_CARD], IBAN [REDACTED_IBAN].")
        XCTAssertEqual(result.count, 4)
        XCTAssertFalse(ScreenContextPrivacy.isIBAN("DE89 3704 0044 0532 0130 01"))
    }

    func testKeepsOrdinaryNumbersAndSettingsReadable() {
        let source = """
        max_tokens: 4096
        Order 4111 1111 1111 1112 shipped
        Tracking 1234567890123
        Call +1 415 555 0100
        Password must have 8 characters
        """

        let result = ScreenContextPrivacy.redact(source)

        XCTAssertEqual(result.text, source)
        XCTAssertEqual(result.count, 0)
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

    /// Since the 2026-09-24 privacy fixes, any second web area or one without
    /// an address made the page's own address unknown. Chrome exposes every
    /// frame as a web area, so almost no Chrome capture kept its URL.
    func testPageKeepsItsAddressWhenChromeExposesFramesAsWebAreas() {
        typealias Reader = ScreenAccessibilityReader
        let gmail = Reader.pageAddress(
            document: "https://mail.google.com/mail/u/0/#inbox",
            webAreaURLs: [
                "https://mail.google.com/mail/u/0/#inbox", "about:blank",
                "https://accounts.google.com/RotateCookiesPage?og_pid=23",
                "https://mail.google.com/mail/u/0/?ui=2&view=bsp",
            ])
        XCTAssertEqual(gmail, .init(
            sourceURL: "https://mail.google.com/mail/u/0/#inbox",
            framedURLs: ["https://accounts.google.com/RotateCookiesPage"],
            hasUnattributedWebContent: false))

        let review = Reader.pageAddress(
            document: "https://github.com/acme/app/pull/1/files#diff-abc",
            webAreaURLs: ["https://github.com/acme/app/pull/1/files", "data:text/html,<p>preview</p>"])
        XCTAssertEqual(review.sourceURL, "https://github.com/acme/app/pull/1/files#diff-abc",
                       "the same page read with and without its fragment is one address")
        XCTAssertEqual(review.framedURLs, [])

        let app = Reader.pageAddress(document: nil, webAreaURLs: ["https://app.slack.com/client/T1/C2"])
        XCTAssertEqual(app.sourceURL, "https://app.slack.com/client/T1/C2")

        let unreadable = Reader.pageAddress(
            document: nil, webAreaURLs: [nil, "https://ads.example/frame", "blob:https://evil.test/1f2e"])
        XCTAssertNil(unreadable.sourceURL, "a framed page never stands in for the page itself")
        XCTAssertEqual(unreadable.framedURLs, ["https://ads.example/frame", "https://evil.test/1f2e"])
        XCTAssertTrue(unreadable.hasUnattributedWebContent)
    }

    func testFramedPagesAreHeldToSiteExclusions() {
        var observation = ScreenContextPrivacy.Observation(
            appName: "Google Chrome", bundleIdentifier: "com.google.Chrome",
            windowTitle: "Roadmap", sourceURL: "https://docs.example/roadmap", focusedSecureField: false,
            hasWebContent: true, framedURLs: ["https://widgets.example/embed"])
        func allowed(_ rules: [String]) -> Bool {
            ScreenContextPrivacy.permitsContent(observation, excludedApps: [], excludedDomains: rules)
        }
        XCTAssertTrue(allowed([]))
        XCTAssertTrue(allowed(["private.test"]), "frames from other allowed sites do not hide the page")
        XCTAssertFalse(allowed(["widgets.example"]), "an excluded site keeps the window out wherever it is framed")
        observation.hasUnattributedWebContent = true
        XCTAssertTrue(allowed([]))
        XCTAssertFalse(allowed(["private.test"]),
                       "an unreadable framed address cannot establish it is outside an exclusion")
    }

    func testWebAddressesAreNotDocumentNames() {
        XCTAssertNil(ScreenContextPrivacy.sanitizedDocumentName("https://www.google.com/search?q=private+matter"))
        XCTAssertNil(ScreenContextPrivacy.sanitizedDocumentName("https://mail.google.com/mail/u/0/#inbox"))
        XCTAssertNil(ScreenContextPrivacy.sanitizedDocumentName("app://-/index.html"))
        XCTAssertEqual(ScreenContextPrivacy.sanitizedDocumentName("/Users/alice/Notes/Plan.md"), "Plan.md")
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

    func testPasswordManagersStayPrivateInAnyLanguageAndRulesCanNameBundleIDs() {
        let passwords = ScreenContextPrivacy.Observation(
            appName: "Passwörter", bundleIdentifier: "com.apple.Passwords",
            windowTitle: "Bankkonto", sourceURL: nil, focusedSecureField: false)
        XCTAssertFalse(ScreenContextPrivacy.permitsContent(passwords, excludedApps: [], excludedDomains: []),
                       "the German Passwords app is skipped though no rule names it")
        XCTAssertEqual(ScreenContextPrivacy.activityDisposition(
            appName: "Trousseaux d'accès", bundleIdentifier: "com.apple.keychainaccess", observation: nil,
            excludedApps: AppSettings().excludedAppList, excludedDomains: []),
            .init(keepsApp: false, keepsTitle: false), "the default \"Keychain Access\" rule misses the French name")

        let notes = ScreenContextPrivacy.Observation(
            appName: "Notizen", bundleIdentifier: "com.apple.Notes",
            windowTitle: "Ideas", sourceURL: nil, focusedSecureField: false)
        XCTAssertFalse(ScreenContextPrivacy.permitsContent(notes, excludedApps: ["com.apple.Notes"], excludedDomains: []),
                       "Choose App… stores the bundle identifier")
        XCTAssertFalse(ScreenContextPrivacy.permitsContent(notes, excludedApps: ["com.apple"], excludedDomains: []))
        XCTAssertTrue(ScreenContextPrivacy.permitsContent(notes, excludedApps: ["com.apple.Note"], excludedDomains: []))
        XCTAssertTrue(ScreenContextPrivacy.permitsContent(notes, excludedApps: ["Notes"], excludedDomains: []),
                      "a plain rule still matches the display name only")
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

    /// Walks read each element's attributes in one call; an attribute the
    /// element lacks comes back as an error value. A subrole that could not be
    /// read must leave the secure-field state unknown, never plain.
    func testBatchedElementReadKeepsUnreadableSecureFieldStateUnknown() throws {
        func error(_ code: AXError) throws -> AnyObject {
            var value = code
            return try XCTUnwrap(AXValueCreate(.axError, &value))
        }
        let names = ScreenAccessibilityReader.secureFieldAttributes
        func status(_ values: [AnyObject]) -> Bool? {
            ScreenAccessibilityReader.secureFieldStatus(.init(names: names, values: values))
        }
        XCTAssertEqual(status(["AXTextField" as NSString, try error(.noValue), "text field" as NSString,
                               "Name" as NSString, NSNull()]), false)
        XCTAssertEqual(status(["AXTextField" as NSString, "AXSecureTextField" as NSString, "text field" as NSString,
                               try error(.attributeUnsupported), try error(.noValue)]), true)
        XCTAssertEqual(status(["AXTextField" as NSString, try error(.attributeUnsupported), "text field" as NSString,
                               "Password" as NSString, try error(.noValue)]), true)
        XCTAssertNil(status(["AXTextField" as NSString, try error(.cannotComplete), "text field" as NSString,
                             "Name" as NSString, try error(.noValue)]))
        XCTAssertNil(status([try error(.noValue), "AXSecureTextField" as NSString, "secure text field" as NSString,
                             try error(.noValue), try error(.noValue)]))
        let node = ScreenAccessibilityReader.NodeAttributes(names: names, values: [
            "AXGroup" as NSString, try error(.noValue), NSNull(), "Title" as NSString, try error(.cannotComplete)])
        XCTAssertEqual(node.value(names[0]) as? String, "AXGroup")
        XCTAssertNil(node.value(names[1]))
        XCTAssertEqual(node.error(names[1]), .noValue)
        XCTAssertEqual(node.error(names[2]), .noValue)
        XCTAssertEqual(node.error(names[4]), .cannotComplete)
    }

    /// Text reads are skipped where the visible-text policy would drop them.
    func testVisibleTextPolicyPreconditionMatchesItsResult() {
        let viewport = CGRect(x: 0, y: 0, width: 100, height: 100)
        for frame in [CGRect(x: 10, y: 10, width: 20, height: 10), CGRect(x: 200, y: 200, width: 20, height: 10),
                      .zero, .null] as [CGRect?] + [nil] {
            for hidden in [false, true] {
                let shown = ScreenVisibleTextPolicy.text(role: "AXStaticText", frame: frame, viewport: viewport,
                                                         hidden: hidden, title: "Title", visibleRangeText: "Visible",
                                                         staticValue: "Value")
                XCTAssertEqual(ScreenVisibleTextPolicy.mayShowText(frame: frame, viewport: viewport, hidden: hidden),
                               !shown.isEmpty)
            }
        }
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
