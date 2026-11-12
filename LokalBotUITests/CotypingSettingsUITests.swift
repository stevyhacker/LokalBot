import XCTest

/// Hosted coverage for autocomplete inside Settings → Autocomplete.
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
        UITestHarness.selectSettingsCategory("Autocomplete", in: app)
        XCTAssertTrue(app.descendants(matching: .any)["settings.header.writing"]
            .waitForExistence(timeout: 8), "Autocomplete did not open with its header")
    }

    override func tearDownWithError() throws {
        app?.terminate()
        fixture?.cleanUp()
        UITestHarness.cleanUp(defaultsSuiteName: defaultsSuiteName)
    }

    /// The page opens with its settings; readiness is the header's status
    /// lines, and the rehearsal is the header's "Try it…" sheet.
    func testAutocompleteExperienceShowsReadinessPreviewAndPrivacy() {
        let lines = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "settings.status.writing."))
        XCTAssertGreaterThan(lines.count, 0, "The header must say whether Autocomplete is ready or what it needs")
        XCTAssertFalse(staticText("Two-step rehearsal").exists)
        XCTAssertFalse(staticText("Private by design").exists)
        let insert = app.buttons.matching(NSPredicate(format: "label == 'Insert suggestion'")).firstMatch
        XCTAssertFalse(insert.exists, "The rehearsal no longer takes the top of the page")
        XCTAssertTrue(UITestHarness.toggle("Take punctuation with the word", in: app).waitForExistence(timeout: 5),
                      "The settings come first")
        app.buttons["settings.header.writing.tryIt"].click()
        XCTAssertTrue(insert.waitForExistence(timeout: 5), "Try it… opens the rehearsal")
        XCTAssertTrue(staticText("Nothing here leaves this Mac").exists)
        XCTAssertFalse(staticText("Cotyping").exists,
                       "legacy internal name leaked into the Autocomplete settings")
        app.buttons["autocomplete.try.done"].click()
        XCTAssertTrue(UITestHarness.waitUntil { !insert.exists }, "Done closes the rehearsal")
    }

    /// Every setting the page had is still there: on the page, or on the
    /// page one of its More rows opens, with a way back.
    func testAutocompleteRowsOpenTheirPagesAndComeBack() {
        let form = app.scrollViews["settings.form"]
        let pages = [("settings.autocomplete.profile", app.buttons["Forget learned text"]),
                     ("settings.autocomplete.exclusions", UITestHarness.toggle("Suggest in integrated terminals", in: app)),
                     ("settings.autocomplete.advanced", UITestHarness.toggle("Use fast in-process runtime", in: app))]
        for (row, control) in pages {
            let button = app.buttons[row]
            UITestHarness.scrollTo(button, in: app, within: form, attempts: 16)
            button.click()
            XCTAssertTrue(app.descendants(matching: .any)["settings.subpage.title"].waitForExistence(timeout: 5),
                          "\(row) did not open its page")
            XCTAssertTrue(control.waitForExistence(timeout: 5), "\(row) lost a setting")
            XCTAssertFalse(app.buttons["settings.header.writing.tryIt"].exists, "A row's page replaces the header")
            app.buttons["settings.subpage.back"].click()
            XCTAssertTrue(app.buttons["settings.header.writing.tryIt"].waitForExistence(timeout: 5),
                          "Back must return to Autocomplete")
        }
        for label in ["Suggestions longer than one line", "Clipboard", "Facts from your meetings",
                      "Facts from your screen history", "Fix typos in the current word", "Macros"] {
            let toggle = UITestHarness.toggle(label, in: app)
            UITestHarness.scrollTo(toggle, in: app, within: form, attempts: 16)
            XCTAssertTrue(toggle.exists, "missing setting: \(label)")
        }
    }

    func testAutocompleteSettingsAndPreviewShareWriting() {
        let toggle = UITestHarness.toggle("Enable autocomplete", in: app)
        UITestHarness.scrollTo(toggle, in: app, within: app.scrollViews["settings.form"])
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any)["sidebar.type"].exists)
    }

    func testAutocompleteHasNoExperimentalDecoderToggle() {
        for _ in 0..<2 {
            let enable = UITestHarness.toggle("Enable autocomplete", in: app)
            UITestHarness.scrollTo(enable, in: app, within: app.scrollViews["settings.form"])
            XCTAssertTrue(enable.waitForExistence(timeout: 5))
            XCTAssertFalse(UITestHarness.toggle("Experimental hybrid suggestions", in: app).exists)
            UITestHarness.selectSettingsCategory("General", in: app)
            UITestHarness.selectSettingsCategory("Autocomplete", in: app)
        }
    }

    func testAutocompleteTabPersistsAcrossNavigation() {
        UITestHarness.clickSidebar("sidebar.timeline", in: app)
        XCTAssertTrue(app.descendants(matching: .any)["timeline.dayPicker"]
            .waitForExistence(timeout: 6), "Timeline did not render")
        UITestHarness.clickSidebar("sidebar.settings", in: app)
        UITestHarness.selectSettingsCategory("Autocomplete", in: app)
        XCTAssertTrue(app.descendants(matching: .any)["settings.header.writing"]
            .waitForExistence(timeout: 8), "Autocomplete tab was not restored")
        XCTAssertTrue(app.descendants(matching: .any)["settings.form"].exists)
    }

    private func staticText(_ fragment: String) -> XCUIElement {
        UITestHarness.staticText(containing: fragment, in: app)
    }
}
