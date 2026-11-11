import XCTest

/// Covers the newer compose-by-default Dictation surface and its independent
/// composition-model selector. Tests stop before recording, so no microphone,
/// model download, focused-app insertion, or other real side effect occurs.
final class DictationSettingsUITests: XCTestCase {
    private var fixture: SyntheticFixture.Library!
    private var app: XCUIApplication!
    private var defaultsSuiteName: String?

    override func setUpWithError() throws {
        continueAfterFailure = false
        fixture = try SyntheticFixture.plant()
        let models = fixture.root.appendingPathComponent("models", isDirectory: true)
        try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
        // Exercise the real preparation and digest checks without loading a
        // model or downloading weights. This fixture is only used for selection.
        try Data("GGUF".utf8).write(to: models.appendingPathComponent("ui-dictation.gguf"))
        let launch = try UITestHarness.launch(
            storageRoot: fixture.root,
            suitePrefix: "DictationSettings",
            settingsJSON: Self.fixtureSettings)
        app = launch.app
        defaultsSuiteName = launch.defaultsSuiteName

        XCTAssertTrue(app.descendants(matching: .any)["today.header"]
            .waitForExistence(timeout: 10), "main window never rendered its Today landing")
        UITestHarness.clickSidebar("sidebar.settings", in: app)
        UITestHarness.selectSettingsCategory("Dictation", in: app)
        UITestHarness.scrollTo(app.buttons["Try here"], in: app, within: app.scrollViews["settings.form"], attempts: 16)
        XCTAssertTrue(dictationForm.waitForExistence(timeout: 8),
                      "Dictation tab did not render")
    }

    override func tearDownWithError() throws {
        app?.terminate()
        fixture?.cleanUp()
        UITestHarness.cleanUp(defaultsSuiteName: defaultsSuiteName)
    }

    func testComposeByDefaultControlsRenderWithoutStartingRecording() {
        XCTAssertTrue(app.buttons["Try here"].exists)
        XCTAssertTrue(formText(containing: "never inserts into another app").exists)
        XCTAssertFalse(app.buttons["Dictation settings…"].exists)
        XCTAssertTrue(formText(containing: "Speech uses the meeting ASR model").exists)
        XCTAssertTrue(formText(containing: "Compose").exists)
        XCTAssertFalse(formText(containing: "Listening").exists)
    }

    /// The page header says where Dictation stands: "Off" while the switch
    /// is off, and once it is on, one line for each thing it still needs,
    /// with the button that asks for it. The page has no permission list
    /// of its own any more; Privacy & permissions is the one home for those.
    func testEnablingGlobalShortcutRevealsPermissionRepairRows() {
        let toggle = UITestHarness.toggle("Enable dictation shortcut", in: app)
        UITestHarness.scrollTo(toggle, in: app, within: app.scrollViews["settings.form"])
        XCTAssertTrue(toggle.waitForExistence(timeout: 4))
        let off = app.descendants(matching: .any)["settings.status.dictation.off"]
        XCTAssertTrue(off.waitForExistence(timeout: 4), "With the switch off the header says Off")
        toggle.click()
        XCTAssertTrue(UITestHarness.waitUntil { String(describing: toggle.value ?? "") == "1" },
                      "The dictation shortcut switch must turn on before leaving settings")
        XCTAssertTrue(UITestHarness.waitUntil { !off.exists }, "Once on, the header shows what Dictation needs instead")
        let lines = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "settings.status.dictation."))
        XCTAssertGreaterThan(lines.count, 0, "The header must say whether Dictation is ready or what it needs")
        UITestHarness.clickSidebar("sidebar.settings", in: app)
        UITestHarness.selectSettingsCategory("Dictation", in: app)
        XCTAssertFalse(formText(containing: "Records your voice for the current dictation").exists,
                       "Dictation no longer lists permissions itself")
        UITestHarness.scrollTo(toggle, in: app, within: app.scrollViews["settings.form"])
        toggle.click()
        XCTAssertTrue(UITestHarness.waitUntil { String(describing: toggle.value ?? "") == "0" })
        XCTAssertTrue(off.waitForExistence(timeout: 4))
    }

    func testDedicatedCompositionModelSelectionPersistsAcrossRelaunch() throws {
        openModels()
        var picker = compositionModelPicker
        XCTAssertTrue(picker.waitForExistence(timeout: 6),
                      "Dictation composition model picker missing")
        UITestHarness.scrollTo(picker, in: app, within: app.scrollViews["models.content"])
        picker.click()

        let model = UITestHarness.staticText(containing: "Synthetic dictation model", in: app)
        XCTAssertTrue(model.waitForExistence(timeout: 4), "prepared Dictation model missing")
        model.click()
        let apply = app.buttons["models.picker.apply"]
        XCTAssertTrue(apply.isEnabled, "A prepared model should be selectable")
        apply.click()
        XCTAssertTrue(UITestHarness.waitUntil { !apply.exists }, "Applying should close the model picker")
        XCTAssertTrue(UITestHarness.waitUntil {
            picker.label.contains("Synthetic dictation model")
        },
            "Dictation composition card did not render the selected model")

        app = try UITestHarness.relaunch(
            storageRoot: fixture.root,
            defaultsSuiteName: try XCTUnwrap(defaultsSuiteName))
        XCTAssertTrue(app.descendants(matching: .any)["today.header"]
            .waitForExistence(timeout: 10), "main window did not return to Today after relaunch")
        openModels()

        picker = compositionModelPicker
        XCTAssertTrue(picker.waitForExistence(timeout: 6),
                      "composition picker missing after relaunch")
        UITestHarness.scrollTo(picker, in: app, within: app.scrollViews["models.content"])
        XCTAssertTrue(UITestHarness.waitUntil {
            picker.label.contains("Synthetic dictation model")
        },
            "dedicated Dictation composition model did not render after relaunch")
    }

    private var dictationForm: XCUIElement {
        app.descendants(matching: .any)["dictation.form"]
    }

    private var compositionModelPicker: XCUIElement {
        app.buttons["models.supporting.dictation"]
    }

    private func formText(containing fragment: String) -> XCUIElement {
        UITestHarness.staticText(containing: fragment, in: app)
    }

    private func openModels() {
        UITestHarness.clickSidebar("sidebar.settings", in: app)
        UITestHarness.selectSettingsCategory("Models", in: app)
        let composition = compositionModelPicker
        UITestHarness.scrollTo(composition, in: app, within: app.scrollViews["models.content"])
        XCTAssertTrue(composition.waitForExistence(timeout: 8),
                      "Models pane did not render Dictation composition")
    }

    private static let fixtureSettings = """
    {
      "menuBarOnly": false, "trackingEnabled": true, "screenshotsEnabled": false,
      "calendarDetectionEnabled": false, "semanticSearchEnabled": false, "cotypingEnabled": false,
      "customBuiltInModels": [{
        "id": "ui-dictation", "displayName": "Synthetic dictation model", "fileName": "ui-dictation.gguf",
        "url": "https://example.invalid/ui-dictation.gguf", "sizeBytes": 4, "sizeGB": 0.000000004,
        "sha256": "b83633aa785344791618f2fddf131b010ea04912a60430760b070bad293f65bd",
        "blurb": "Selection-only test fixture", "disablesThinking": true
      }]
    }
    """
}
