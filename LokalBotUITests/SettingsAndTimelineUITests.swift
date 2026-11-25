import XCTest

final class SettingsUITests: XCTestCase {
    private var fixture: SyntheticFixture.Library!
    private var app: XCUIApplication!
    private var defaultsSuiteName: String?

    override func setUpWithError() throws {
        continueAfterFailure = false
        fixture = try SyntheticFixture.plant()
        if !name.contains("testCalendarDependentOptionsRenderWhenSeededOn") {
            try launch()
        }
    }

    override func tearDownWithError() throws {
        app?.terminate()
        fixture?.cleanUp()
        UITestHarness.cleanUp(defaultsSuiteName: defaultsSuiteName)
    }

    func testInterfaceLanguageUpdatesOpenHostAndPersistsAfterRelaunch() throws {
        try assertInterfaceLanguageRendersAndPersists(
            identifier: "zh-Hans", nativeName: "简体中文", theme: "主题", languageLabel: "界面语言")
    }

    func testRightToLeftInterfaceLanguageRendersAndPersistsAfterRelaunch() throws {
        try assertInterfaceLanguageRendersAndPersists(
            identifier: "ur", nativeName: "اردو", theme: "تھیم", languageLabel: "ایپ کی زبان")
    }

    private func assertInterfaceLanguageRendersAndPersists(
        identifier: String, nativeName: String, theme: String, languageLabel: String
    ) throws {
        UITestHarness.clickSidebar("sidebar.settings", in: app)
        UITestHarness.selectSettingsCategory("General", in: app)
        let picker = app.popUpButtons["settings.appLanguage"]
        UITestHarness.scrollTo(picker, in: app)
        UITestHarness.selectSegment("English", pickerIdentifier: "settings.appLanguage", in: app)
        XCTAssertTrue(UITestHarness.staticText(containing: "Theme", in: app).waitForExistence(timeout: 6))
        UITestHarness.selectSegment(nativeName, pickerIdentifier: "settings.appLanguage", in: app)
        XCTAssertTrue(UITestHarness.staticText(containing: theme, in: app).waitForExistence(timeout: 6),
                      "The existing settings host must render \(identifier)")
        XCTAssertTrue(UITestHarness.staticText(containing: languageLabel, in: app).waitForExistence(timeout: 6))
        let screenshot = XCTAttachment(screenshot: UITestHarness.settingsWindow(in: app).screenshot())
        screenshot.name = "settings-interface-\(identifier)"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        app.terminate()
        app = try UITestHarness.relaunch(
            storageRoot: fixture.root, defaultsSuiteName: XCTUnwrap(defaultsSuiteName))
        UITestHarness.clickSidebar("sidebar.settings", in: app)
        XCTAssertTrue(UITestHarness.staticText(containing: theme, in: app).waitForExistence(timeout: 6),
                      "The \(identifier) interface must survive relaunch")
        XCTAssertTrue(UITestHarness.staticText(containing: languageLabel, in: app).waitForExistence(timeout: 6))
        UITestHarness.scrollTo(app.popUpButtons["settings.appLanguage"], in: app)
        UITestHarness.selectSegment("English", pickerIdentifier: "settings.appLanguage", in: app)
        XCTAssertTrue(UITestHarness.staticText(containing: "Theme", in: app).waitForExistence(timeout: 6))
    }

    func testOverviewShowsStatusAndOpensThePagesThatFixIt() {
        UITestHarness.clickSidebar("sidebar.settings", in: app)
        let overview = app.scrollViews["settings.overview"]
        XCTAssertTrue(overview.waitForExistence(timeout: 6), "Settings must open on Overview")
        XCTAssertTrue(app.descendants(matching: .any)["settings.overview.headline"].exists,
                      "Overview leads with whether anything needs you")
        XCTAssertTrue(app.descendants(matching: .any)["settings.identity.summary"].exists,
                      "The LokalBot row at the top of the list says the same")
        XCTAssertFalse(app.buttons["settings.overview.askAnywhere.action"].exists,
                       "Overview no longer has a second set of feature switches")
        XCTAssertEqual(overview.switches.count, 0, "Features are turned on on their own pages")

        let privacy = app.buttons["settings.overview.privacy"]
        UITestHarness.scrollTo(privacy, in: app, within: overview)
        privacy.click()
        XCTAssertTrue(app.descendants(matching: .any)["settings.permission.microphone"].waitForExistence(timeout: 6),
                      "Overview's data row opens Privacy & permissions")
        app.buttons["settings.back"].click()
        XCTAssertTrue(overview.waitForExistence(timeout: 4), "Back returns to the page shown before")

        let models = app.buttons["settings.overview.models"]
        UITestHarness.scrollTo(models, in: app, within: overview)
        models.click()
        XCTAssertTrue(app.descendants(matching: .any)["models.settings"].waitForExistence(timeout: 6),
                      "Overview's Models row opens Models")

        UITestHarness.selectSettingsCategory("Overview", in: app)
        let ask = app.buttons.matching(NSPredicate(
            format: "label BEGINSWITH %@ AND NOT (label CONTAINS %@)", "Quick Recall", "in LokalBot")).firstMatch
        UITestHarness.scrollTo(ask, in: app, within: app.scrollViews["settings.overview"])
        ask.click()
        let toggle = UITestHarness.toggle("Enable the Quick Recall shortcut", in: app)
        XCTAssertTrue(toggle.waitForExistence(timeout: 6), "The shortcut's row opens the Ask page")
        XCTAssertEqual(String(describing: toggle.value ?? ""), "0", "Quick Recall's shortcut is off until its own switch turns it on")
    }

    func testPermissionRepairPaneRendersCorePermissions() {
        UITestHarness.clickSidebar("sidebar.settings", in: app)

        UITestHarness.selectSettingsCategory("Privacy & permissions", in: app)
        let microphone = UITestHarness.staticText(containing: "Microphone", in: app)
        UITestHarness.scrollTo(microphone, in: app)
        XCTAssertTrue(UITestHarness.staticText(containing: "Microphone", in: app)
            .waitForExistence(timeout: 6), "microphone permission row missing")
        for permission in ["microphone", "accessibility", "inputMonitoring", "screenRecording", "calendar"] {
            XCTAssertTrue(app.descendants(matching: .any)["settings.permission.\(permission)"].exists,
                          "\(permission) permission row missing")
        }
        XCTAssertTrue(app.buttons["settings.permissions.relaunch"].exists,
                      "relaunch affordance missing")
        let agents = app.buttons["settings.privacy.agents"]
        UITestHarness.scrollTo(agents, in: app, within: app.scrollViews["settings.form"])
        XCTAssertTrue(agents.waitForExistence(timeout: 4), "agent access summary missing")
        XCTAssertTrue(app.descendants(matching: .any)["settings.privacy.onlineModels"].exists,
                      "with every model local, Online models says none")
        XCTAssertTrue(app.buttons["settings.privacy.devices"].exists, "phone and tablet sharing summary missing")
        UITestHarness.scrollTo(app.descendants(matching: .any)["settings.library"], in: app,
                               within: app.scrollViews["settings.form"])
        XCTAssertTrue(app.buttons["settings.library.showInFinder"].exists, "library location missing")
        UITestHarness.scrollTo(agents, in: app, within: app.scrollViews["settings.form"], upward: true)
        agents.click()
        XCTAssertTrue(app.descendants(matching: .any)["settings.agentAccess"].waitForExistence(timeout: 6),
                      "AI agents on this Mac opens the AI agents page")
    }

    func testCalendarDependentOptionsHiddenWhenCalendarDetectionIsOff() {
        UITestHarness.clickSidebar("sidebar.settings", in: app)
        XCTAssertTrue(app.descendants(matching: .any)["settings.categories"]
            .waitForExistence(timeout: 6), "settings pane did not render")
        UITestHarness.selectSettingsCategory("Meetings", in: app)

        XCTAssertTrue(UITestHarness.staticText(containing: "Use calendar to improve detection", in: app)
            .waitForExistence(timeout: 6), "calendar master toggle missing")
        XCTAssertFalse(UITestHarness.staticText(containing: "Use calendar titles for recordings", in: app).exists,
                       "calendar title toggle should be gated while calendar detection is off")
        XCTAssertFalse(UITestHarness.staticText(containing: "Require a calendar match", in: app).exists,
                       "browser strict-mode toggle should be gated while calendar detection is off")
    }

    func testRememberingSpeakersIsAlwaysOnWithoutMeetNaming() {
        UITestHarness.clickSidebar("sidebar.settings", in: app)
        UITestHarness.selectSettingsCategory("Meetings", in: app)
        let manage = app.buttons["Manage remembered people…"]
        UITestHarness.scrollTo(manage, in: app)
        XCTAssertTrue(manage.waitForExistence(timeout: 6))
        XCTAssertFalse(app.switches["settings.rememberSpeakers"].exists, "Remembering speakers has no off switch")
        XCTAssertFalse(app.switches["settings.speakerVisuals"].exists, "Meet speaker naming was removed")
        manage.click()
        XCTAssertTrue(UITestHarness.staticText(containing: "No remembered voices yet", in: app).waitForExistence(timeout: 4))
        app.buttons["Done"].click()
    }

    func testCalendarDependentOptionsRenderWhenSeededOn() throws {
        try launch(settingsJSON: """
        {
          "menuBarOnly": false,
          "trackingEnabled": true,
          "screenshotsEnabled": false,
          "calendarDetectionEnabled": true,
          "useCalendarTitles": true,
          "requireCalendarForBrowser": true,
          "semanticSearchEnabled": false,
          "cotypingEnabled": false
        }
        """)

        UITestHarness.clickSidebar("sidebar.settings", in: app)
        XCTAssertTrue(app.descendants(matching: .any)["settings.categories"]
            .waitForExistence(timeout: 6), "settings pane did not render")
        UITestHarness.selectSettingsCategory("Meetings", in: app)

        XCTAssertTrue(UITestHarness.staticText(containing: "Use calendar titles for recordings", in: app)
            .waitForExistence(timeout: 6), "calendar title toggle missing when calendar detection is on")
        XCTAssertTrue(UITestHarness.staticText(containing: "Require a calendar match", in: app).exists,
                      "browser strict-mode toggle missing when calendar detection is on")
        XCTAssertEqual(app.staticTexts.matching(
            NSPredicate(format: "label ==[c] %@ OR value ==[c] %@", "Calendar access", "Calendar access")).count, 0,
                       "Meetings must not have a Calendar access row of its own")
        XCTAssertFalse(app.buttons["Grant Calendar Access…"].exists,
                       "Meetings must not ask for Calendar access in its own way")
        let headerLine = app.descendants(matching: .any)["settings.status.recording.allow.calendar"]
        let askedInHeader = headerLine.exists
        if askedInHeader {
            XCTAssertTrue(app.buttons["settings.status.recording.allow.calendar.action"].exists,
                          "The header's Calendar line carries its own fix button")
        }
        UITestHarness.selectSettingsCategory("Privacy & permissions", in: app)
        XCTAssertTrue(app.descendants(matching: .any)["settings.permission.calendar"].waitForExistence(timeout: 6),
                      "calendar permission row missing on Privacy & permissions")
        XCTAssertEqual(app.buttons["settings.permission.calendar.allow"].exists, askedInHeader,
                       "Meetings' header and Privacy & permissions must agree on Calendar access")
    }

    private func launch(settingsJSON: String = "{}") throws {
        app?.terminate()
        UITestHarness.cleanUp(defaultsSuiteName: defaultsSuiteName)
        let launch = try UITestHarness.launch(
            storageRoot: fixture.root,
            suitePrefix: "Settings",
            settingsJSON: settingsJSON)
        app = launch.app
        defaultsSuiteName = launch.defaultsSuiteName
        XCTAssertTrue(app.descendants(matching: .any)["today.header"]
            .waitForExistence(timeout: 10), "main window never rendered its Today landing")
    }
}

final class TimelineWithoutActivityUITests: XCTestCase {
    private var fixture: SyntheticFixture.Library!
    private var app: XCUIApplication!
    private var defaultsSuiteName: String?

    override func setUpWithError() throws {
        continueAfterFailure = false
        fixture = try SyntheticFixture.plant(includeActivity: false)
        let launch = try UITestHarness.launch(storageRoot: fixture.root, suitePrefix: "TimelineWithoutActivity")
        app = launch.app
        defaultsSuiteName = launch.defaultsSuiteName
        XCTAssertTrue(app.descendants(matching: .any)["today.header"]
            .waitForExistence(timeout: 10), "main window never rendered its Today landing")
        UITestHarness.clickSidebar("sidebar.timeline", in: app)
        XCTAssertTrue(app.descendants(matching: .any)["timeline.dayPicker"]
            .waitForExistence(timeout: 6), "timeline section did not render")
        XCTAssertTrue(app.descendants(matching: .any)["timeline.workSessions"]
            .waitForExistence(timeout: 6), "the day's list was not immediately visible")
    }

    override func tearDownWithError() throws {
        app?.terminate()
        fixture?.cleanUp()
        UITestHarness.cleanUp(defaultsSuiteName: defaultsSuiteName)
    }

    func testTimelineWithoutActivityShowsMeetingBlocks() {
        XCTAssertTrue(app.descendants(matching: .any)["timeline.workSessions"].exists,
                      "the day's list with meeting rows missing")
        XCTAssertTrue(app.descendants(matching: .any)[
            "capture.meeting.\(fixture.designReview.id.uuidString)"].exists,
                      "meeting row missing without activity blocks")
        XCTAssertFalse(UITestHarness.staticText(containing: "Nothing recorded", in: app).exists,
                       "empty state shown despite seeded meetings in the list")

        UITestHarness.clickSidebar("sidebar.meetings", in: app)
        XCTAssertTrue(app.outlines["meeting.list"].waitForExistence(timeout: 6),
                      "meeting list did not render in Meetings")
        XCTAssertFalse(app.descendants(matching: .any)["timeline.workSessions"].exists,
                       "Timeline sessions should not render in Meetings")
    }
}
