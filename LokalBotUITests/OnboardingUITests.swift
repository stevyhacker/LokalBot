import XCTest

/// Drives the real first-run wizard and pins down the permission contract for
/// the day-memory layers selected by default.
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

    func testWizardExplainsDayMemoryDefaultsAndPermissionGates() {
        let before = UserDefaults(suiteName: defaultsSuiteName!)?.data(forKey: "lokalbotv3.settings")
        assertPage(title: "Choose what to remember", step: 1)
        XCTAssertTrue(app.descendants(matching: .any)["onboarding.meetingMode"].firstMatch.exists)
        XCTAssertTrue(text(containing: "applied on the final Review step").exists)
        app.buttons["Continue"].click()
        assertPage(title: "Enable the access you need", step: 2)
        XCTAssertTrue(text(containing: "Screen Recording").waitForExistence(timeout: 5),
                      "Existing visual capture must retain its permission requirement")
        app.buttons["Continue with Current Access"].click()
        assertPage(title: "Prepare your workflows", step: 3)
        XCTAssertTrue(app.buttons["onboarding.downloadModels"].exists)
        XCTAssertTrue(UITestHarness.toggle("Also prepare Autocomplete (optional)", in: app).exists)
        app.buttons["Continue"].click()
        assertPage(title: "Review and start", step: 4)
        XCTAssertTrue(app.buttons["onboarding.finish"].exists)
        app.buttons["Back"].click()
        assertPage(title: "Prepare your workflows", step: 3)
        XCTAssertEqual(UserDefaults(suiteName: defaultsSuiteName!)?.data(forKey: "lokalbotv3.settings"), before,
                       "Moving through setup must not apply capture choices")
    }

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
        XCTAssertTrue(text(containing: "Step \(step) of 4").exists,
                      "onboarding progress did not reach step \(step)")
    }

    private func text(containing fragment: String) -> XCUIElement {
        UITestHarness.staticText(containing: fragment, in: app)
    }

    private func optIn(_ title: String) -> XCUIElement {
        app.descendants(matching: .any)["onboarding.optIn.\(title)"].firstMatch
    }
}
