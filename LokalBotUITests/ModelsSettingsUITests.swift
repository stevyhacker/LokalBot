import XCTest

/// Hosted-only coverage of the model role editors. Uses synthetic settings;
/// no credentials are saved and no inference or downloads are requested.
final class ModelsSettingsUITests: XCTestCase {
    private var fixture: SyntheticFixture.Library!
    private var app: XCUIApplication!
    private var suite: String?

    override func setUpWithError() throws {
        continueAfterFailure = false
        try HostedDisplay.prepareForModelLayouts()
        fixture = try SyntheticFixture.plant()
    }

    override func tearDownWithError() throws {
        app?.terminate()
        UITestHarness.cleanUp(defaultsSuiteName: suite)
        fixture?.cleanUp()
    }

    func testRemoteThinkEditorKeepsConsentExplicit() throws {
        try launch(approved: false)
        let configure = app.buttons["models.stack.change.think"]
        XCTAssertTrue(configure.waitForExistence(timeout: 8))
        configure.click()

        let manage = app.buttons["models.picker.connections"]
        XCTAssertTrue(manage.waitForExistence(timeout: 5))
        XCTAssertEqual(app.textFields["models.picker.modelID"].value as? String, "example/test-model")
        XCTAssertFalse(app.buttons["models.picker.apply"].isEnabled, "An unapproved server must not be selectable")
        manage.click()

        let server = app.textFields["models.serverURL"]
        let model = app.textFields["models.modelID"]
        XCTAssertTrue(server.waitForExistence(timeout: 5))
        XCTAssertEqual(server.value as? String, "https://openrouter.ai/api/v1")
        XCTAssertEqual(model.value as? String, "example/test-model")
        XCTAssertTrue(app.staticTexts["Server URL"].exists)
        XCTAssertTrue(app.staticTexts["Model ID"].exists)
        XCTAssertFalse(app.staticTexts["Main LLM engine"].exists)

        let consent = app.checkBoxes["models.remoteConsent"]
        UITestHarness.scrollTo(consent, in: app, within: app.scrollViews["models.content"])
        XCTAssertEqual(consent.value as? Int, 0, "Opening configuration must not grant consent")
        consent.click()
        XCTAssertTrue(UITestHarness.waitUntil { (consent.value as? Int) == 1 })
        UITestHarness.selectSegment("Active models", pickerIdentifier: "models.pages", in: app)
        XCTAssertTrue(UITestHarness.waitUntil { !server.exists })
        UITestHarness.selectSegment("Connections", pickerIdentifier: "models.pages", in: app)
        XCTAssertEqual(model.value as? String, "example/test-model", "Changing pages must preserve the saved model")
        UITestHarness.scrollTo(consent, in: app, within: app.scrollViews["models.content"])
        XCTAssertEqual(consent.value as? Int, 1, "Changing pages must preserve explicit consent")

        UITestHarness.scrollTo(server, in: app, within: app.scrollViews["models.content"])
        server.click()
        server.typeKey("a", modifierFlags: .command)
        server.typeText("https://another.example/v1")
        UITestHarness.scrollTo(consent, in: app, within: app.scrollViews["models.content"])
        XCTAssertEqual(consent.value as? Int, 0, "Consent must remain scoped to the approved origin")
        XCTAssertEqual(model.value as? String, "example/test-model")
        let save = app.buttons["models.connection.save"]
        UITestHarness.scrollTo(save, in: app, within: app.scrollViews["models.content"])
        XCTAssertTrue(save.isEnabled)
        save.click()
        UITestHarness.selectSegment("Active models", pickerIdentifier: "models.pages", in: app)
        UITestHarness.scrollTo(configure, in: app, within: app.scrollViews["models.content"])
        configure.click()
        XCTAssertTrue(app.buttons["models.picker.apply"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["models.picker.apply"].isEnabled, "A new origin requires its own approval")
        app.buttons["models.picker.connections"].click()
        XCTAssertEqual(server.value as? String, "https://another.example/v1")
        capture("models-remote-consent")
    }

    func testModelsLayoutAtNarrowAndWideWidths() throws {
        for size in ["1000x700", "1440x900"] {
            for appearance in ["light", "dark"] {
                try launch(approved: true, size: size, appearance: appearance)
                let think = app.buttons["models.stack.change.think"]
                XCTAssertTrue(think.waitForExistence(timeout: 8))
                let transcribe = app.buttons["models.stack.change.transcribe"]
                let autocomplete = app.buttons["models.stack.change.type"]
                for button in [transcribe, think, autocomplete] {
                    XCTAssertTrue(button.isHittable, "All roles should be visible before editing")
                    XCTAssertGreaterThanOrEqual(button.frame.minX, app.windows.firstMatch.frame.minX)
                    XCTAssertLessThanOrEqual(button.frame.maxX, app.windows.firstMatch.frame.maxX)
                }
                XCTAssertFalse(UITestHarness.staticText(containing: "Check passed", in: app).exists,
                               "Configured models must not claim a successful test")
                XCTAssertTrue(app.descendants(matching: .any)["sidebar.today"].exists,
                              "Settings must remain inside the main workspace")
                XCTAssertEqual(app.windows.count, 1, "Opening Models must not create a separate Settings window")
                capture("models-\(size)-\(appearance)-overview")
                think.click()
                XCTAssertTrue(app.textFields["models.picker.modelID"].waitForExistence(timeout: 5))
                XCTAssertTrue(app.buttons["models.picker.cancel"].isHittable)
                capture("models-\(size)-\(appearance)-think")
                app.terminate()
                UITestHarness.cleanUp(defaultsSuiteName: suite)
            }
        }
    }

    private func launch(approved: Bool, size: String = "1180x740", appearance: String = "light") throws {
        let origins = approved ? "[\"https://openrouter.ai\"]" : "[]"
        let result = try UITestHarness.launch(
            storageRoot: fixture.root,
            suitePrefix: "ModelsSettings",
            settingsJSON: """
            {
              "menuBarOnly": false, "trackingEnabled": false,
              "screenshotsEnabled": false, "calendarDetectionEnabled": false,
              "semanticSearchEnabled": false, "cotypingEnabled": false,
              "summarizerBackend": "OpenAI-compatible server",
              "openAIBaseURL": "https://openrouter.ai/api/v1",
              "openAIModel": "example/test-model",
              "approvedRemoteInferenceOrigins": \(origins)
            }
            """,
            environment: [
                "LOKALBOT_INITIAL_SECTION": "models",
                "LOKALBOT_MODELS_DEMO_READY": "1",
                "LOKALBOT_CAPTURE_SIZE": size,
                "LOKALBOT_CAPTURE_APPEARANCE": appearance,
            ])
        app = result.app
        suite = result.defaultsSuiteName
        let dimensions = size.split(separator: "x").compactMap { Double($0) }
        XCTAssertTrue(UITestHarness.waitUntil(timeout: 8) {
            let frame = self.app.windows.firstMatch.frame
            return abs(frame.width - dimensions[0]) < 1 && abs(frame.height - dimensions[1]) < 1
        }, "Capture window must reach the requested size")
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
