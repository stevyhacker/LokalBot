import XCTest

/// Drives the real first-run wizard (Choose, Allow access, Download) and pins
/// down the permission contract for the day-memory layers selected by default.
final class OnboardingUITests: XCTestCase {
    private var root: URL!
    private var app: XCUIApplication!
    private var defaultsSuiteName: String?

    override func setUpWithError() throws {
        continueAfterFailure = false
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OnboardingUITests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("meetings"),
            withIntermediateDirectories: true)

        let launch = try UITestHarness.launch(
            storageRoot: root,
            suitePrefix: "Onboarding",
            settingsJSON: """
            {
              "menuBarOnly": false,
              "trackingEnabled": true,
              "screenshotsEnabled": true,
              "calendarDetectionEnabled": false,
              "semanticSearchEnabled": false,
              "cotypingEnabled": false,
              "dictationEnabled": false
            }
            """,
            environment: ["LOKALBOT_UI_TEST_WINDOW": "onboarding"])
        app = launch.app
        defaultsSuiteName = launch.defaultsSuiteName
    }

    override func tearDownWithError() throws {
        app?.terminate()
        try? FileManager.default.removeItem(at: root)
        UITestHarness.cleanUp(defaultsSuiteName: defaultsSuiteName)
    }

    /// The language menu is on the first step only. Switching it must restyle
    /// the open window in place: the choice made before the switch is still
    /// there, and setup is still on its first step.
    func testLanguageSwitchKeepsTheOpenWizardOnItsCurrentStep() {
        UITestHarness.selectSegment("English", pickerIdentifier: "onboarding.appLanguage", in: app)
        let codingAgents = UITestHarness.toggle("Read coding agent sessions", in: app)
        XCTAssertTrue(codingAgents.waitForExistence(timeout: 6))
        XCTAssertTrue(isOn(codingAgents), "setup starts from the new-install default")
        codingAgents.click()
        UITestHarness.selectSegment("简体中文", pickerIdentifier: "onboarding.appLanguage", in: app)
        XCTAssertTrue(text(containing: "LokalBot 应该记住什么？").waitForExistence(timeout: 6),
                      "The existing onboarding host must update its locale")
        UITestHarness.selectSegment("English", pickerIdentifier: "onboarding.appLanguage", in: app)
        assertPage(title: "What should LokalBot remember?", step: 1)
        XCTAssertFalse(isOn(UITestHarness.toggle("Read coding agent sessions", in: app)),
                       "Switching the language must keep the choices already made")
        app.buttons["Continue"].click()
        assertPage(title: "Allow access", step: 2)
        XCTAssertFalse(app.descendants(matching: .any)["onboarding.appLanguage"].exists,
                       "The language menu belongs to the first step")
    }

    func testRightToLeftLanguagesKeepTheCurrentOnboardingStep() {
        UITestHarness.selectSegment("English", pickerIdentifier: "onboarding.appLanguage", in: app)
        let languages = [
            ("ar", "العربية", "ما الذي يجب أن يتذكره LokalBot؟"),
            ("ar-EG", "مصري", "عايز LokalBot يفتكر إيه؟"),
            ("ur", "اردو", "LokalBot کیا یاد رکھے؟")
        ]
        for (identifier, nativeName, heading) in languages {
            UITestHarness.selectSegment(nativeName, pickerIdentifier: "onboarding.appLanguage", in: app)
            XCTAssertTrue(text(containing: heading).waitForExistence(timeout: 6))
            let screenshot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
            screenshot.name = "onboarding-choose-\(identifier)"
            screenshot.lifetime = .keepAlways
            add(screenshot)
        }
        UITestHarness.selectSegment("English", pickerIdentifier: "onboarding.appLanguage", in: app)
        assertPage(title: "What should LokalBot remember?", step: 1)
    }

    func testWizardExplainsDayMemoryDefaultsAndPermissionGates() {
        let before = UserDefaults(suiteName: defaultsSuiteName!)?.data(forKey: "lokalbotv3.settings")
        assertPage(title: "Welcome to LokalBot", step: 1)
        XCTAssertTrue(text(containing: "Everything is processed and stored on this Mac").exists)
        XCTAssertTrue(app.descendants(matching: .any)["onboarding.meetingMode"].firstMatch.exists)
        XCTAssertTrue(app.descendants(matching: .any)["onboarding.contextMode"].firstMatch.exists)
        XCTAssertTrue(UITestHarness.toggle("Read coding agent sessions", in: app).exists,
                      "Setup must offer the coding agent choice before any session is read")
        XCTAssertTrue(text(containing: "Private and incognito browser windows are captured").exists)
        app.buttons["Continue"].click()
        assertPage(title: "Allow access", step: 2)
        XCTAssertTrue(text(containing: "Screen Recording").waitForExistence(timeout: 5),
                      "Existing visual capture must retain its permission requirement")
        XCTAssertTrue(text(containing: "of 3 allowed").exists,
                      "The footer counts the permissions these choices need")
        app.buttons["Continue"].click()
        // The library is new, so its models are still to download.
        assertPage(title: "Download the models", step: 3)
        XCTAssertTrue(app.buttons["onboarding.downloadModels"].exists)
        XCTAssertTrue(app.buttons["onboarding.skipDownload"].exists,
                      "Setup can finish without downloading")
        XCTAssertTrue(UITestHarness.toggle("Also prepare Autocomplete (optional)", in: app).exists)
        XCTAssertFalse(app.buttons["onboarding.finish"].exists,
                       "Nothing downloads, and setup does not end, until its button is pressed")
        app.buttons["Back"].click()
        assertPage(title: "Allow access", step: 2)
        app.buttons["onboarding.step.1"].click()
        assertPage(title: "Welcome to LokalBot", step: 1)
        XCTAssertEqual(UserDefaults(suiteName: defaultsSuiteName!)?.data(forKey: "lokalbotv3.settings"), before,
                       "Moving through setup must not apply capture choices")
    }

    /// The stepper shows finished steps as buttons that go back; the current
    /// and later steps are plain labels.
    private func assertPage(title: String, step: Int) {
        XCTAssertTrue(text(containing: title).waitForExistence(timeout: 6),
                      "onboarding page missing: \(title)")
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = "onboarding-step-\(step)"
        attachment.lifetime = .keepAlways
        add(attachment)
        let progress = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier == 'onboarding.progress'")).firstMatch
        XCTAssertTrue(progress.waitForExistence(timeout: 4),
                      "onboarding progress control missing at step \(step)")
        for finished in 1..<4 {
            XCTAssertEqual(app.buttons["onboarding.step.\(finished)"].exists, finished < step,
                           "step \(finished) must be a back button only once it is finished (at step \(step))")
        }
    }

    /// A switch reports 1 or 0, as a number or as text depending on the system.
    private func isOn(_ toggle: XCUIElement) -> Bool {
        switch toggle.value {
        case let number as NSNumber: number.boolValue
        case let text as String: text == "1"
        default: false
        }
    }

    private func text(containing fragment: String) -> XCUIElement {
        UITestHarness.staticText(containing: fragment, in: app)
    }
}
