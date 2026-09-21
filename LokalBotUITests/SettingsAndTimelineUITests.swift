import XCTest

final class SettingsUITests: XCTestCase {
    private var fixture: SyntheticFixture.Library!
    private var app: XCUIApplication!
    private var defaultsSuiteName: String?

    override func setUpWithError() throws {
        continueAfterFailure = false
        fixture = try SyntheticFixture.plant()
        let launch = try UITestHarness.launch(storageRoot: fixture.root, suitePrefix: "Settings")
        app = launch.app
        defaultsSuiteName = launch.defaultsSuiteName
        // Today is the default section; its header renders unconditionally,
        // so wait on it rather than the meeting list.
        XCTAssertTrue(app.descendants(matching: .any)["today.header"]
            .waitForExistence(timeout: 10), "main window never rendered its Today landing")
    }

    override func tearDownWithError() throws {
        app?.terminate()
        fixture?.cleanUp()
        UITestHarness.cleanUp(defaultsSuiteName: defaultsSuiteName)
    }

    func testPermissionRepairPaneRendersCorePermissions() {
        UITestHarness.clickSidebar("sidebar.settings", in: app)

        UITestHarness.selectSettingsCategory("Privacy & Data", in: app)
        let microphone = UITestHarness.staticText(containing: "Microphone", in: app)
        UITestHarness.scrollTo(microphone, in: app)
        // Gate on the Microphone row, not the "Permissions" section header:
        // Form section headers surface as label-only StaticTexts that live
        // predicate queries never match on macOS, even though failure-time
        // AX hierarchies show them. Row texts are value-carrying and match.
        XCTAssertTrue(UITestHarness.staticText(containing: "Microphone", in: app)
            .waitForExistence(timeout: 6), "microphone permission row missing")
        XCTAssertTrue(UITestHarness.staticText(containing: "Screen Recording", in: app).exists,
                      "screen/system-audio permission row missing")
        XCTAssertTrue(UITestHarness.staticText(containing: "Accessibility", in: app).exists,
                      "accessibility permission row missing")
        XCTAssertTrue(UITestHarness.staticText(containing: "Input Monitoring", in: app).exists,
                      "optional input monitoring row missing")
        XCTAssertTrue(app.buttons["Relaunch"].exists,
                      "relaunch affordance missing")
    }

    func testResourceMonitorRendersUsageAndModelState() {
        UITestHarness.clickSidebar("sidebar.settings", in: app)
        UITestHarness.selectSettingsCategory("Advanced", in: app)

        let cpu = app.descendants(matching: .any)["settings.resourceMonitor.cpu"]
        UITestHarness.scrollTo(cpu, in: app)
        XCTAssertTrue(cpu.waitForExistence(timeout: 6),
                      "resource monitor CPU metric missing")
        XCTAssertTrue(app.descendants(matching: .any)["settings.resourceMonitor.memory"].exists,
                      "resource monitor memory metric missing")
        XCTAssertTrue(app.descendants(matching: .any)["settings.resourceMonitor.models"].exists,
                      "resource monitor model count missing")
        XCTAssertTrue(app.descendants(matching: .any)["settings.resourceMonitor.modelMemory"].exists,
                      "resource monitor model memory metric missing")
    }

    func testCalendarDependentOptionsHiddenWhenCalendarDetectionIsOff() {
        UITestHarness.clickSidebar("sidebar.settings", in: app)
        XCTAssertTrue(app.descendants(matching: .any)["settings.form"]
            .waitForExistence(timeout: 6), "settings pane did not render")
        UITestHarness.selectSettingsCategory("Meetings", in: app)

        XCTAssertTrue(UITestHarness.staticText(containing: "Use calendar to improve detection", in: app)
            .waitForExistence(timeout: 6), "calendar master toggle missing")
        XCTAssertFalse(UITestHarness.staticText(containing: "Use calendar titles for recordings", in: app).exists,
                       "calendar title toggle should be gated while calendar detection is off")
        XCTAssertFalse(UITestHarness.staticText(containing: "Require a calendar match", in: app).exists,
                       "browser strict-mode toggle should be gated while calendar detection is off")
    }

    /// Hosted/remote Mac only, like the rest of this suite. No live capture or
    /// enrollment is performed; the app uses an isolated synthetic library.
    func testSpeakerVisualsAndRememberingAreSeparateOptIns() {
        UITestHarness.clickSidebar("sidebar.settings", in: app)
        UITestHarness.selectSettingsCategory("Meetings", in: app)
        let visuals = app.switches["settings.speakerVisuals"]
        let remembering = app.switches["settings.rememberSpeakers"]
        UITestHarness.scrollTo(visuals, in: app)
        XCTAssertTrue(visuals.waitForExistence(timeout: 6))
        XCTAssertTrue(remembering.exists)
        XCTAssertEqual(visuals.label, "Identify speakers from Google Meet")
        XCTAssertEqual(remembering.label, "Remember speakers on this Mac")
        XCTAssertEqual(String(describing: visuals.value ?? ""), "0")
        XCTAssertEqual(String(describing: remembering.value ?? ""), "0")
        visuals.click()
        XCTAssertTrue(UITestHarness.waitUntil { String(describing: visuals.value ?? "") == "1" })
        XCTAssertEqual(String(describing: remembering.value ?? ""), "0")
        let manage = app.buttons["Manage remembered people…"]
        UITestHarness.scrollTo(manage, in: app)
        manage.click()
        XCTAssertTrue(UITestHarness.staticText(containing: "No remembered voices yet", in: app).waitForExistence(timeout: 4))
        app.buttons["Done"].click()
    }

    func testCalendarDependentOptionsRenderWhenSeededOn() throws {
        try relaunch(settingsJSON: """
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
        XCTAssertTrue(app.descendants(matching: .any)["settings.form"]
            .waitForExistence(timeout: 6), "settings pane did not render")
        UITestHarness.selectSettingsCategory("Meetings", in: app)

        XCTAssertTrue(UITestHarness.staticText(containing: "Use calendar titles for recordings", in: app)
            .waitForExistence(timeout: 6), "calendar title toggle missing when calendar detection is on")
        XCTAssertTrue(UITestHarness.staticText(containing: "Require a calendar match", in: app).exists,
                      "browser strict-mode toggle missing when calendar detection is on")
        XCTAssertTrue(UITestHarness.staticText(containing: "Calendar access", in: app).exists,
                      "calendar access row missing when calendar detection is on")
    }

    private func relaunch(settingsJSON: String) throws {
        app.terminate()
        UITestHarness.cleanUp(defaultsSuiteName: defaultsSuiteName)
        let launch = try UITestHarness.launch(
            storageRoot: fixture.root,
            suitePrefix: "Settings",
            settingsJSON: settingsJSON)
        app = launch.app
        defaultsSuiteName = launch.defaultsSuiteName
        XCTAssertTrue(app.descendants(matching: .any)["today.header"]
            .waitForExistence(timeout: 10), "main window never rendered its Today landing after relaunch")
    }
}

/// Timeline against a fixture with no activity blocks — meetings still
/// populate the primary chronological Work sessions stream.
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
        // This class pins Timeline behavior; the app now lands on Today, so
        // step onto the Timeline explicitly before each test begins.
        UITestHarness.clickSidebar("sidebar.timeline", in: app)
        XCTAssertTrue(app.descendants(matching: .any)["timeline.dayPicker"]
            .waitForExistence(timeout: 6), "timeline section did not render")
        XCTAssertTrue(app.descendants(matching: .any)["timeline.workSessions"]
            .waitForExistence(timeout: 6), "Work sessions was not immediately visible")
    }

    override func tearDownWithError() throws {
        app?.terminate()
        fixture?.cleanUp()
        UITestHarness.cleanUp(defaultsSuiteName: defaultsSuiteName)
    }

    /// With no activity blocks seeded, the seeded meetings still render as
    /// first-class chronological rows rather than the empty state,
    /// and the Meetings section shows the grouped list.
    func testTimelineWithoutActivityShowsMeetingBlocks() {
        XCTAssertTrue(app.descendants(matching: .any)["timeline.workSessions"].exists,
                      "Work sessions with meeting rows missing")
        XCTAssertTrue(app.descendants(matching: .any)[
            "capture.meeting.\(fixture.designReview.id.uuidString)"].exists,
                      "meeting row missing without activity blocks")
        XCTAssertFalse(UITestHarness.staticText(containing: "No activity recorded", in: app).exists,
                       "empty state shown despite seeded meetings in the track")

        UITestHarness.clickSidebar("sidebar.meetings", in: app)
        XCTAssertTrue(app.outlines["meeting.list"].waitForExistence(timeout: 6),
                      "meeting list did not render in Meetings")
        XCTAssertFalse(app.descendants(matching: .any)["timeline.workSessions"].exists,
                       "Timeline sessions should not render in Meetings")
    }
}
