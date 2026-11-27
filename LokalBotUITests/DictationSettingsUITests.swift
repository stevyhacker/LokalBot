import XCTest

final class DictationSettingsUITests: XCTestCase {
    private var fixture: SyntheticFixture.Library!
    private var app: XCUIApplication!
    private var defaultsSuiteName: String?

    override func setUpWithError() throws {
        continueAfterFailure = false
        fixture = try SyntheticFixture.plant()
        let models = fixture.root.appendingPathComponent("models", isDirectory: true)
        try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
        try Data("GGUF".utf8).write(to: models.appendingPathComponent("ui-dictation.gguf"))
        let launch = try UITestHarness.launch(
            storageRoot: fixture.root,
            suitePrefix: "DictationSettings",
            settingsJSON: Self.fixtureSettings)
        app = launch.app
        defaultsSuiteName = launch.defaultsSuiteName

        XCTAssertTrue(app.descendants(matching: .any)["today.header"]
            .waitForExistence(timeout: 10), "main window never rendered its Today landing")
        if !name.contains("testDedicatedCompositionModelSelectionPersistsAcrossRelaunch") {
            UITestHarness.clickSidebar("sidebar.settings", in: app)
            UITestHarness.selectSettingsCategory("Dictation", in: app)
            XCTAssertTrue(dictationForm.waitForExistence(timeout: 8),
                          "Dictation tab did not render")
        }
    }

    override func tearDownWithError() throws {
        app?.terminate()
        fixture?.cleanUp()
        UITestHarness.cleanUp(defaultsSuiteName: defaultsSuiteName)
    }

    func testComposeByDefaultControlsRenderWithoutStartingRecording() {
        XCTAssertFalse(app.buttons["dictation.try.action"].exists, "The try-out opens over the page")
        XCTAssertFalse(app.buttons["Dictation settings…"].exists)
        let form = app.scrollViews["settings.form"]
        let mode = app.descendants(matching: .any)["settings.dictationIntent"]
        UITestHarness.scrollTo(mode, in: app, within: form, attempts: 16)
        XCTAssertTrue(mode.exists, "Mode is a setting of the page")
        UITestHarness.selectSegment("Compose", pickerIdentifier: "settings.dictationIntent", in: app)
        let window = UITestHarness.toggle("The focused window", in: app)
        UITestHarness.scrollTo(window, in: app, within: form, attempts: 16)
        XCTAssertTrue(window.waitForExistence(timeout: 4), "Compose's sources are settings under Mode")
        let writer = app.descendants(matching: .any)["settings.dictation.writer"]
        UITestHarness.scrollTo(writer, in: app, within: form, attempts: 16)
        let who = writer.label.isEmpty ? (writer.value as? String ?? "") : writer.label
        XCTAssertTrue(who.contains("on this Mac"), "The row must say where the text is written, not '\(who)'")

        UITestHarness.scrollTo(app.buttons["settings.header.dictation.tryIt"], in: app, within: form, attempts: 16)
        app.buttons["settings.header.dictation.tryIt"].click()
        let action = app.buttons["dictation.try.action"]
        XCTAssertTrue(action.waitForExistence(timeout: 5), "Try it… opens the try-out")
        XCTAssertEqual(action.label, "Try here")
        XCTAssertTrue(formText(containing: "Nothing is pasted into another app").exists)
        XCTAssertFalse(formText(containing: "Listening").exists)
        app.buttons["dictation.try.done"].click()
        XCTAssertTrue(UITestHarness.waitUntil { !action.exists }, "Done closes the try-out")
    }

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
        let other = app.buttons["models.more.other"]
        if !composition.exists {
            XCTAssertTrue(other.waitForExistence(timeout: 8), "Models has no Other models row")
            UITestHarness.scrollTo(other, in: app, within: app.scrollViews["models.content"])
            other.click()
        }
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
