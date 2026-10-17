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

    func testInterfaceLanguageUpdatesOpenHostAndPersistsAfterRelaunch() throws {
        UITestHarness.clickSidebar("sidebar.settings", in: app)
        let picker = app.popUpButtons["settings.appLanguage"]
        UITestHarness.scrollTo(picker, in: app)
        UITestHarness.selectSegment("English", pickerIdentifier: "settings.appLanguage", in: app)
        XCTAssertTrue(UITestHarness.staticText(containing: "Theme", in: app).waitForExistence(timeout: 6))
        UITestHarness.selectSegment("简体中文", pickerIdentifier: "settings.appLanguage", in: app)
        XCTAssertTrue(UITestHarness.staticText(containing: "主题", in: app)
            .waitForExistence(timeout: 6), "An open AppKit host must adopt the selected Chinese locale")
        let screenshot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        screenshot.name = "settings-interface-simplified-chinese"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        app.terminate()
        app = try UITestHarness.relaunch(
            storageRoot: fixture.root, defaultsSuiteName: XCTUnwrap(defaultsSuiteName))
        UITestHarness.clickSidebar("sidebar.settings", in: app)
        XCTAssertTrue(UITestHarness.staticText(containing: "主题", in: app)
            .waitForExistence(timeout: 6), "The interface language must survive relaunch")
        UITestHarness.scrollTo(app.popUpButtons["settings.appLanguage"], in: app)
        UITestHarness.selectSegment("English", pickerIdentifier: "settings.appLanguage", in: app)
        XCTAssertTrue(UITestHarness.staticText(containing: "Theme", in: app)
            .waitForExistence(timeout: 6), "The same host must switch back to English without relaunch")
    }

    func testEveryNewInterfaceLanguageRendersAndUrduPersists() throws {
        UITestHarness.clickSidebar("sidebar.settings", in: app)
        let languages = [
            ("hi", "हिन्दी", "थीम", "ऐप की भाषा"),
            ("es", "Español", "Tema", "Idioma de la app"),
            ("ar", "العربية", "السمة", "لغة التطبيق"),
            ("fr", "Français", "Thème", "Langue de l’app"),
            ("bn", "বাংলা", "থিম", "অ্যাপের ভাষা"),
            ("pt", "Português", "Tema", "Idioma do app"),
            ("id", "Bahasa Indonesia", "Tema", "Bahasa aplikasi"),
            ("ur", "اردو", "تھیم", "ایپ کی زبان")
        ]
        for (identifier, nativeName, theme, languageLabel) in languages {
            UITestHarness.scrollTo(app.popUpButtons["settings.appLanguage"], in: app)
            UITestHarness.selectSegment(nativeName, pickerIdentifier: "settings.appLanguage", in: app)
            XCTAssertTrue(UITestHarness.staticText(containing: theme, in: app).waitForExistence(timeout: 6),
                          "The existing settings host must render \(identifier)")
            XCTAssertTrue(UITestHarness.staticText(containing: languageLabel, in: app).waitForExistence(timeout: 6))
            let screenshot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
            screenshot.name = "settings-interface-\(identifier)"
            screenshot.lifetime = .keepAlways
            add(screenshot)
        }

        app.terminate()
        app = try UITestHarness.relaunch(
            storageRoot: fixture.root, defaultsSuiteName: XCTUnwrap(defaultsSuiteName))
        UITestHarness.clickSidebar("sidebar.settings", in: app)
        XCTAssertTrue(UITestHarness.staticText(containing: "تھیم", in: app).waitForExistence(timeout: 6),
                      "The Urdu interface must survive relaunch")
        UITestHarness.scrollTo(app.popUpButtons["settings.appLanguage"], in: app)
        UITestHarness.selectSegment("English", pickerIdentifier: "settings.appLanguage", in: app)
        XCTAssertTrue(UITestHarness.staticText(containing: "Theme", in: app).waitForExistence(timeout: 6))
    }

    func testRussianGermanJapanesePidginAndEgyptianArabicRender() throws {
        try assertInterfaceLanguagesRenderAndPersist([
            ("ru", "Русский", "Тема", "Язык приложения"),
            ("de", "Deutsch", "Design", "App-Sprache"),
            ("ja", "日本語", "テーマ", "アプリの言語"),
            ("pcm", "Naijá", "How e look", "Language wey app dey use"),
            ("ar-EG", "مصري", "شكل الواجهة", "لغة التطبيق")
        ])
    }

    func testMarathiVietnameseTeluguSwahiliAndHausaRender() throws {
        try assertInterfaceLanguagesRenderAndPersist([
            ("mr", "मराठी", "थीम", "अ‍ॅपची भाषा"),
            ("vi", "Tiếng Việt", "Chủ đề", "Ngôn ngữ ứng dụng"),
            ("te", "తెలుగు", "థీమ్", "యాప్ భాష"),
            ("sw", "Kiswahili", "Mandhari", "Lugha ya programu"),
            ("ha", "Hausa", "Jigo", "Harshen manhaja")
        ])
    }

    func testKoreanInterfaceRendersAndPersists() throws {
        try assertInterfaceLanguagesRenderAndPersist([
            ("ko", "한국어", "테마", "앱 언어")
        ])
    }

    private func assertInterfaceLanguagesRenderAndPersist(_ languages: [(String, String, String, String)]) throws {
        UITestHarness.clickSidebar("sidebar.settings", in: app)
        for (identifier, nativeName, theme, languageLabel) in languages {
            UITestHarness.scrollTo(app.popUpButtons["settings.appLanguage"], in: app)
            UITestHarness.selectSegment(nativeName, pickerIdentifier: "settings.appLanguage", in: app)
            XCTAssertTrue(UITestHarness.staticText(containing: theme, in: app).waitForExistence(timeout: 6),
                          "The existing settings host must render \(identifier)")
            XCTAssertTrue(UITestHarness.staticText(containing: languageLabel, in: app).waitForExistence(timeout: 6))
            let screenshot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
            screenshot.name = "settings-interface-\(identifier)"
            screenshot.lifetime = .keepAlways
            add(screenshot)
        }
        let (identifier, _, theme, languageLabel) = try XCTUnwrap(languages.last)
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
        // The metrics are a lazy grid; its second row may start below the fold.
        UITestHarness.scrollTo(app.descendants(matching: .any)["settings.resourceMonitor.modelMemory"], in: app)
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
    func testRememberingSpeakersIsAnOptInWithoutMeetNaming() {
        UITestHarness.clickSidebar("sidebar.settings", in: app)
        UITestHarness.selectSettingsCategory("Meetings", in: app)
        let remembering = app.switches["settings.rememberSpeakers"]
        UITestHarness.scrollTo(remembering, in: app)
        XCTAssertTrue(remembering.waitForExistence(timeout: 6))
        XCTAssertEqual(remembering.label, "Remember speakers on this Mac")
        XCTAssertEqual(String(describing: remembering.value ?? ""), "0")
        XCTAssertFalse(app.switches["settings.speakerVisuals"].exists, "Meet speaker naming was removed")
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
