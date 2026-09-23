import XCTest

/// Hosted coverage for autocomplete inside Settings → Writing.
/// The legacy cotyping keys remain internal; user-facing language and routes
/// are Autocomplete throughout.
final class CotypingSettingsUITests: XCTestCase {
    private var app: XCUIApplication!
    private var fixture: SyntheticFixture.Library!
    private var defaultsSuiteName: String?

    override func setUpWithError() throws {
        continueAfterFailure = false
        fixture = try SyntheticFixture.plant()
        let launch = try UITestHarness.launch(
            storageRoot: fixture.root,
            suitePrefix: "Autocomplete",
            environment: ["LOKALBOT_COTYPING_DEMO": "1"])
        app = launch.app
        defaultsSuiteName = launch.defaultsSuiteName
        XCTAssertTrue(app.descendants(matching: .any)["today.header"]
            .waitForExistence(timeout: 10), "main window never rendered")
        UITestHarness.clickSidebar("sidebar.settings", in: app)
        UITestHarness.selectSettingsCategory("Writing", in: app)
        XCTAssertTrue(app.descendants(matching: .any)["autocomplete.home"]
            .waitForExistence(timeout: 8), "Writing did not expose the autocomplete preview")
    }

    override func tearDownWithError() throws {
        app?.terminate()
        fixture?.cleanUp()
        UITestHarness.cleanUp(defaultsSuiteName: defaultsSuiteName)
    }

    func testAutocompleteExperienceShowsReadinessPreviewAndPrivacy() {
        XCTAssertTrue(staticText("Autocomplete on").exists)
        XCTAssertTrue(staticText("Try the real autocomplete").exists)
        XCTAssertFalse(staticText("Two-step rehearsal").exists)
        XCTAssertFalse(staticText("Private by design").exists)
        XCTAssertTrue(app.buttons.matching(
            NSPredicate(format: "label == 'Insert suggestion'")).firstMatch.exists)
        XCTAssertFalse(staticText("Cotyping").exists,
                       "legacy internal name leaked into the Writing settings")
    }

    func testAutocompleteSettingsAndPreviewShareWriting() {
        let toggle = UITestHarness.toggle("Enable autocomplete", in: app)
        UITestHarness.scrollTo(toggle, in: app, within: app.scrollViews["settings.form"])
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any)["sidebar.type"].exists)
    }

    func testAutocompleteTabPersistsAcrossNavigation() {
        UITestHarness.clickSidebar("sidebar.timeline", in: app)
        XCTAssertTrue(app.descendants(matching: .any)["timeline.dayPicker"]
            .waitForExistence(timeout: 6), "Timeline did not render")
        UITestHarness.clickSidebar("sidebar.settings", in: app)
        UITestHarness.selectSettingsCategory("Writing", in: app)
        XCTAssertTrue(app.descendants(matching: .any)["autocomplete.home"]
            .waitForExistence(timeout: 8), "Autocomplete tab was not restored")
        XCTAssertTrue(app.descendants(matching: .any)["settings.form"].exists)
    }

    private func staticText(_ fragment: String) -> XCUIElement {
        UITestHarness.staticText(containing: fragment, in: app)
    }
}
