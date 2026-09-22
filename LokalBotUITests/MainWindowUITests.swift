import AppKit
import XCTest

/// End-to-end UI tests that drive the dedicated `LokalBot UI Test Host`
/// against a synthetic meetings library planted on disk before launch.
///
/// The app sees `LOKALBOT_UI_TEST=1` and skips every side-effectful
/// startup path (Core Audio polling, accessibility-trusted detector,
/// Sparkle, screenshots), so the suite needs no TCC permissions and
/// never touches the user's real library.
final class MainWindowUITests: XCTestCase {

    private var fixture: SyntheticFixture.Library!
    private var app: XCUIApplication!
    private var defaultsSuiteName: String?

    override func setUpWithError() throws {
        continueAfterFailure = false
        fixture = try SyntheticFixture.plant()
        let launch = try UITestHarness.launch(
            storageRoot: fixture.root,
            suitePrefix: "MainWindow",
            environment: ["LOKALBOT_UI_TEST_DIAGNOSTICS": "1"])
        app = launch.app
        defaultsSuiteName = launch.defaultsSuiteName
        // Wait until the main window has rendered Today's header —
        // every test starts from a known surface, otherwise XCUITest races
        // the initial `loadMeetings()` + reindex sweep. (Today is the
        // default section, so the meeting list is NOT on screen yet.)
        XCTAssertTrue(app.descendants(matching: .any)["today.header"]
            .waitForExistence(timeout: 10), "today header never rendered")
    }

    override func tearDownWithError() throws {
        app?.terminate()
        fixture?.cleanUp()
        UITestHarness.cleanUp(defaultsSuiteName: defaultsSuiteName)
    }

    // MARK: - Today

    /// Today keeps the task-first digest hierarchy without repeating the host
    /// page's time chart or exposing capture/evidence bookkeeping.
    func testTodayUsesCompactDigestHierarchy() {
        XCTAssertTrue(identified("today.dayDigest.generate").waitForExistence(timeout: 6))
        UITestHarness.scrollTo(identified("today.dayDigest.generate"), in: app)
        XCTAssertTrue(identified("today.dayDigest.actions").exists)
        XCTAssertTrue(textWithContent("Updated the Timeline UI").firstMatch.exists)
        XCTAssertFalse(textWithContent("screen:4242").firstMatch.exists)
        XCTAssertTrue(textWithContent("Generated").firstMatch.exists)
        XCTAssertFalse(identified("dayDigest.fullActivityLog").exists)
        XCTAssertTrue(app.buttons["Review actions"].exists)
        UITestHarness.scrollTo(identified("today.fullBrief"), in: app)
        XCTAssertTrue(identified("today.fullBrief").exists)
    }

    // MARK: - Library

    /// LokalBot owns one split-view sidebar toggle so every navigation topology
    /// shares the same explicit visibility state. Count every sidebar control,
    /// not just the app-owned identifier — NavigationSplitView's generated
    /// toggle carries its own identity and must not ride along, in either
    /// sidebar state.
    func testToolbarShowsOneSidebarToggle() {
        XCTAssertTrue(toolbarSidebarButtons.firstMatch.waitForExistence(timeout: 4),
                      "app-owned sidebar toolbar control missing")
        XCTAssertEqual(anySidebarToggleButtons.count, 1,
                       "toolbar should contain exactly one sidebar control while the sidebar is visible")

        toolbarSidebarButtons.firstMatch.click()
        XCTAssertTrue(UITestHarness.waitUntil {
            !self.app.descendants(matching: .any)["sidebar.settings"].exists
        }, "sidebar remained exposed after hiding it")
        XCTAssertEqual(anySidebarToggleButtons.count, 1,
                       "toolbar should contain exactly one sidebar control while the sidebar is hidden")

        toolbarSidebarButtons.firstMatch.click()
        XCTAssertTrue(app.descendants(matching: .any)["sidebar.settings"]
            .waitForExistence(timeout: 5), "sidebar did not return")
    }

    /// The command palette uses one AppKit field-editor path. A printable key
    /// must update its query exactly once rather than also travelling through
    /// the palette's navigation-key handler.
    func testCommandPaletteDoesNotDuplicateTypedCharacters() {
        app.typeKey("k", modifierFlags: .command)
        let field = app.textFields["palette.input"]
        XCTAssertTrue(field.waitForExistence(timeout: 4), "command palette input missing")

        field.click()
        field.typeText("AI tooling")

        XCTAssertEqual(field.value as? String, "AI tooling")
        app.typeKey(.escape, modifierFlags: [])
    }

    /// The native toolbar item must do real work in both directions. This
    /// guards the recent split-view stabilization against a control that is
    /// present but detached from NavigationSplitView's column visibility.
    func testToolbarToggleHidesAndRestoresSidebar() {
        clickSidebar("sidebar.timeline")
        XCTAssertTrue(identified("timeline.dayPicker").waitForExistence(timeout: 5),
                      "Timeline did not render before the sidebar toggle check")
        XCTAssertTrue(toolbarSidebarButtons.firstMatch.waitForExistence(timeout: 4),
                      "native sidebar control missing")
        toolbarSidebarButtons.firstMatch.click()
        XCTAssertTrue(UITestHarness.waitUntil {
            !self.app.descendants(matching: .any)["sidebar.settings"].exists
        }, "sidebar remained exposed after hiding it")

        XCTAssertTrue(toolbarSidebarButtons.firstMatch.waitForExistence(timeout: 4),
                      "sidebar control disappeared after hiding")
        toolbarSidebarButtons.firstMatch.click()
        let timeline = app.descendants(matching: .any)["sidebar.timeline"]
        XCTAssertTrue(timeline.waitForExistence(timeout: 5), "sidebar did not return")

        let window = app.windows.firstMatch
        let privacyFooter = identified("sidebar.localPrivacy")
        XCTAssertTrue(privacyFooter.waitForExistence(timeout: 3),
                      "sidebar footer did not return")
        XCTAssertLessThan(abs(privacyFooter.frame.minX - window.frame.minX), 4,
                          "restored sidebar left an empty column at the window edge")
    }

    func testToolbarToggleWorksInThreeColumnSection() {
        clickSidebar("sidebar.ask")
        XCTAssertTrue(app.textFields["search.field"].waitForExistence(timeout: 6),
                      "Ask did not render before the sidebar toggle check")

        toolbarSidebarButtons.firstMatch.click()
        XCTAssertTrue(UITestHarness.waitUntil {
            !self.app.descendants(matching: .any)["sidebar.settings"].exists
        }, "three-column sidebar remained exposed after hiding it")

        XCTAssertTrue(toolbarSidebarButtons.firstMatch.waitForExistence(timeout: 4),
                      "three-column sidebar control disappeared after hiding")
        toolbarSidebarButtons.firstMatch.click()
        XCTAssertTrue(app.descendants(matching: .any)["sidebar.ask"]
            .waitForExistence(timeout: 5), "three-column sidebar did not return")

        let privacyFooter = identified("sidebar.localPrivacy")
        XCTAssertLessThan(abs(privacyFooter.frame.minX - app.windows.firstMatch.frame.minX), 4,
                          "three-column sidebar restored with an empty leading column")
    }

    /// The sidebar content must stay attached to the window edge even when
    /// AppKit restores or accepts an oversized first split column. A fixed-
    /// width child centered in that column creates the blank gutters this
    /// test is intended to prevent.
    func testSidebarStaysAtLeadingEdgeAfterColumnResizeAndToggle() {
        clickSidebar("sidebar.meetings")
        XCTAssertTrue(app.outlines["meeting.list"].waitForExistence(timeout: 6),
                      "Meetings did not render before the sidebar resize check")

        let window = app.windows.firstMatch
        let sidebarDivider = app.splitters.element(boundBy: 0)
        let privacyFooter = identified("sidebar.localPrivacy")
        XCTAssertTrue(sidebarDivider.waitForExistence(timeout: 4),
                      "sidebar divider missing")
        XCTAssertTrue(privacyFooter.waitForExistence(timeout: 4),
                      "sidebar footer missing")

        app.activate()
        _ = app.wait(for: .runningForeground, timeout: 3)
        let destination = window.coordinate(
            withNormalizedOffset: CGVector(dx: 0.45, dy: 0.5))
        sidebarDivider.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: destination)

        XCTAssertLessThan(abs(privacyFooter.frame.minX - window.frame.minX), 4,
                          "resizing centered the sidebar inside an oversized column")

        toolbarSidebarButtons.firstMatch.click()
        XCTAssertTrue(UITestHarness.waitUntil {
            !self.app.descendants(matching: .any)["sidebar.settings"].exists
        }, "resized sidebar remained exposed after hiding it")
        toolbarSidebarButtons.firstMatch.click()
        XCTAssertTrue(privacyFooter.waitForExistence(timeout: 5),
                      "resized sidebar did not return")
        XCTAssertLessThan(abs(privacyFooter.frame.minX - window.frame.minX), 4,
                          "restored resized sidebar detached from the window edge")
    }

    /// Query the app-owned identifier among direct toolbar children so nested
    /// accessibility wrappers cannot inflate the count.
    private var toolbarSidebarButtons: XCUIElementQuery {
        app.toolbars.firstMatch.children(matching: .button).matching(NSPredicate(
            format: "identifier == 'toolbar.sidebarToggle'"))
    }

    /// Any sidebar toggle among direct toolbar children, app-owned or
    /// system-generated (the generated item has no app identifier, only a
    /// "Hide/Show Sidebar" label).
    private var anySidebarToggleButtons: XCUIElementQuery {
        app.toolbars.firstMatch.children(matching: .button).matching(NSPredicate(
            format: "identifier == 'toolbar.sidebarToggle' OR label CONTAINS[c] 'sidebar'"))
    }

    /// Every planted fixture surfaces in the sidebar, grouped by day with
    /// the right headers — confirms `StorageManager.loadMeetings()` reads
    /// our on-disk shape, not just a happy-path single meeting.
    func testMeetingListRendersAllSyntheticMeetings() {
        openLibrary()
        let list = app.outlines["meeting.list"]
        XCTAssertTrue(list.staticTexts[fixture.designReview.title].exists,
                      "design review row missing")
        XCTAssertTrue(list.staticTexts[fixture.standup.title].exists,
                      "standup row missing")
        XCTAssertTrue(list.staticTexts[fixture.planning.title].exists,
                      "planning row missing")
        XCTAssertTrue(hasDayHeader(in: list, prefix: "TODAY"),
                      "TODAY day header missing")
        XCTAssertTrue(hasDayHeader(in: list, prefix: "YESTERDAY"),
                      "YESTERDAY day header missing")
        // The Record toolbar button is always present; assert it exists but
        // never click it — recording reaches for real audio devices.
        XCTAssertTrue(app.buttons["toolbar.record"].exists,
                      "record toolbar button missing")
    }

    func testMeetingLibrarySearchAndStatusFilterRender() {
        openLibrary()
        let search = app.textFields["meeting.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 4), "meeting search missing")
        XCTAssertTrue(app.descendants(matching: .any)["meeting.statusFilter"].exists,
                      "status filter missing")
        search.click()
        search.typeText("Q3 roadmap")
        XCTAssertTrue(meetingRow(for: fixture.planning).waitForExistence(timeout: 4))
        XCTAssertFalse(meetingRow(for: fixture.designReview).exists)
        search.typeKey("a", modifierFlags: .command)
        search.typeKey(.delete, modifierFlags: [])
    }

    /// Sidebar selection swaps the content column. Settings is the most
    /// distinctive surface (rich form). It stays in the same main window and
    /// the workspace sidebar can return directly to another destination.
    func testSidebarNavigationSwitchesSections() {
        clickSidebar("sidebar.settings")
        XCTAssertTrue(app.descendants(matching: .any)["settings.form"]
            .waitForExistence(timeout: 6),
                      "settings pane did not render")
        XCTAssertTrue(identified("settings.categories").exists,
                      "Settings category navigation missing")
        XCTAssertEqual(app.windows.count, 1, "Settings must stay in the main window")
        XCTAssertTrue(identified("sidebar.timeline").exists)
        clickSidebar("sidebar.timeline")
        XCTAssertTrue(app.descendants(matching: .any)["timeline.dayPicker"]
            .waitForExistence(timeout: 4),
                      "timeline section did not come back")
    }

    func testSidebarUsesApprovedRememberAndWriteActHierarchy() {
        XCTAssertTrue(identified("sidebar.section.remember").exists)
        XCTAssertTrue(identified("sidebar.section.writeAct").exists)
        XCTAssertFalse(app.buttons["sidebar.section.remember"].exists,
                       "Remember must be a header, not a destination")
        XCTAssertFalse(app.buttons["sidebar.section.writeAct"].exists,
                       "Write & Act must be a header, not a destination")
        let ordered = ["sidebar.today", "sidebar.meetings", "sidebar.timeline",
                       "sidebar.ask", "sidebar.type", "sidebar.agent", "sidebar.settings"]
            .map(identified)
        for item in ordered {
            XCTAssertTrue(item.exists, "approved sidebar destination missing")
        }
        for pair in zip(ordered, ordered.dropFirst()) {
            XCTAssertLessThan(pair.0.frame.midY, pair.1.frame.midY,
                              "approved sidebar order changed")
        }
        // Storage and inference destinations remain separate claims.
        XCTAssertTrue(textWithContent("Storage: this Mac").firstMatch.exists)
        XCTAssertTrue(textWithContent("AI: on this Mac").firstMatch.exists)
    }

    /// The Models category presents compact role rows and focused editors.
    func testModelsSectionRendersRoleCards() {
        clickSidebar("sidebar.settings")
        UITestHarness.selectSettingsCategory("Models", in: app)
        XCTAssertTrue(app.descendants(matching: .any)["models.overview"]
            .waitForExistence(timeout: 6), "core readiness overview missing")
        XCTAssertTrue(app.descendants(matching: .any)["models.storage"].exists,
                      "model storage summary missing")
        XCTAssertTrue(textWithContent("Core models").firstMatch.exists)
        XCTAssertFalse(app.buttons["models.advanced"].exists,
                       "Models should not hide configuration behind Advanced details")
        XCTAssertTrue(app.buttons["models.stack.change.transcribe"]
            .waitForExistence(timeout: 6),
                      "Core Transcribe row did not render its Change button")
        XCTAssertTrue(app.descendants(matching: .any)["models.supporting.dictation"].exists,
                      "dictation composition model card identifier missing")
        XCTAssertTrue(app.descendants(matching: .any)["models.supporting.search"].exists,
                      "embeddings model card identifier missing")

        for change in ["models.stack.change.transcribe", "models.stack.change.think", "models.stack.change.type"] {
            let button = app.buttons[change]
            XCTAssertTrue(button.waitForExistence(timeout: 4), "\(change) button missing")
            UITestHarness.scrollTo(button, in: app, within: app.scrollViews["models.content"])
            button.click()
            let cancel = app.buttons["models.picker.cancel"]
            XCTAssertTrue(cancel.waitForExistence(timeout: 4), "The focused model editor must open as a sheet")
            XCTAssertTrue(cancel.isHittable, "The editor must have a reachable Cancel button")
            cancel.click()
            XCTAssertTrue(UITestHarness.waitUntil {
                !cancel.exists
            }, "Cancel should close the model editor")
        }
    }

    func testModelsCanOpenCustomGraniteSpeechPicker() {
        clickSidebar("sidebar.settings")
        UITestHarness.selectSettingsCategory("Models", in: app)

        let change = app.buttons["models.stack.change.transcribe"]
        XCTAssertTrue(change.waitForExistence(timeout: 6), "Transcribe Change button missing")
        change.click()

        app.buttons["models.picker.advanced"].click()

        let customize = app.buttons["models.granite.customize"]
        UITestHarness.scrollTo(customize, in: app, attempts: 4)
        XCTAssertTrue(customize.waitForExistence(timeout: 4),
                      "custom Granite model button missing")
        customize.click()

        XCTAssertTrue(app.staticTexts["models.granite.picker.title"]
            .waitForExistence(timeout: 5), "custom Granite picker did not open")
        XCTAssertTrue(app.textFields["models.granite.repository"].exists,
                      "Hugging Face repository field missing")
        XCTAssertTrue(app.buttons["Use selected model"].exists,
                      "custom-model confirmation action missing")
    }

    func testModelPresetRequiresReviewBeforeApplying() {
        clickSidebar("sidebar.settings")
        UITestHarness.selectSettingsCategory("Models", in: app)

        let preset = app.buttons["models.choosePreset"]
        UITestHarness.scrollTo(preset, in: app)
        XCTAssertTrue(preset.waitForExistence(timeout: 5), "Choose preset button missing")
        preset.click()
        XCTAssertTrue(app.buttons["models.preset.apply"]
            .waitForExistence(timeout: 4), "preset applied without a review step")
        XCTAssertTrue(textWithContent("Estimated new download").firstMatch.exists)
        XCTAssertTrue(textWithContent("After applying").firstMatch.exists)
        let reviewSheet = app.sheets.firstMatch
        XCTAssertTrue(reviewSheet.waitForExistence(timeout: 4), "preset review sheet missing")
        reviewSheet.buttons["Cancel"].firstMatch.click()
    }

    // MARK: - Timeline

    /// Timeline is one day explorer: its persistent header and work sessions
    /// stay put while a bounded panel swaps between the day brief, session, and
    /// meeting previews.
    func testTimelineRendersTrackAndOverview() {
        clickSidebar("sidebar.timeline")
        XCTAssertTrue(app.descendants(matching: .any)["timeline.dayPicker"]
            .waitForExistence(timeout: 6), "persistent day header did not render")
        XCTAssertTrue(identified("capture.askDay").exists,
                      "persistent Timeline actions did not render")
        XCTAssertTrue(app.descendants(matching: .any)["timeline.workSessions"]
            .waitForExistence(timeout: 6), "work sessions should be visible immediately")
        let usesContextDrawer = revealTimelineContext()
        if !usesContextDrawer {
            XCTAssertLessThan(
                identified("capture.dayOverview").frame.midX,
                identified("timeline.workSessions").frame.midX,
                "Day brief should stay left of Work sessions in the wide Timeline layout")
        }
        XCTAssertTrue(identified("timeline.dayDigest.generate").waitForExistence(timeout: 5),
                      "day-digest action should remain directly visible")
        XCTAssertTrue(identified("timeline.dayDigest.actions").exists,
                      "Timeline should expose copy and Markdown export actions")
        XCTAssertFalse(identified("timeline.activityEvidence").exists,
                       "the chronological track should not be hidden behind Activity evidence")
        XCTAssertFalse(textWithContent("Needs attention").firstMatch.exists,
                       "empty outcome card should not consume Timeline space")
        XCTAssertFalse(textWithContent("Decisions").firstMatch.exists,
                       "empty decisions section should not consume Timeline space")
        XCTAssertTrue(textWithContent("Time allocation").firstMatch.waitForExistence(timeout: 6),
                      "compact time allocation missing — seeded activity did not load")
        XCTAssertTrue(textWithContent("Xcode").firstMatch.exists,
                      "seeded activity app 'Xcode' missing from Timeline")
        XCTAssertTrue(digestTasksVisible(),
                      "digest task hierarchy is missing")
        XCTAssertTrue(textWithContent("Updated the Timeline UI").firstMatch.exists,
                      "human-facing focus summary is missing")
        XCTAssertFalse(textWithContent("User updated the Timeline UI").firstMatch.exists,
                       "model bookkeeping subject leaked into the focus summary")
        XCTAssertFalse(textWithContent("screen:4242").firstMatch.exists,
                       "private evidence identifier leaked into the collapsed overview")
        XCTAssertFalse(textWithContent("No activity recorded").firstMatch.exists,
                       "empty state shown despite seeded activity blocks")
        if usesContextDrawer { closeTimelineContext() }
        // The grounded block title becomes the human-scale session title.
        XCTAssertTrue(app.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] %@", "TimelineView.swift"))
            .firstMatch.exists,
                      "seeded work-session title missing")
        // Meetings remain first-class chronological rows.
        XCTAssertTrue(app.descendants(matching: .any)["capture.meeting.\(fixture.designReview.id.uuidString)"].exists,
                      "seeded meeting missing from Work sessions")
        let rawCapture = app.buttons["timeline.rawCapture"]
        XCTAssertTrue(rawCapture.exists,
                      "raw capture disclosure is missing")
        XCTAssertFalse(app.descendants(matching: .any)["timeline.track"].exists,
                       "raw block chart should not be the default Timeline presentation")
        rawCapture.click()
        XCTAssertTrue(app.descendants(matching: .any)["timeline.track"]
            .waitForExistence(timeout: 4), "raw block chart did not expand on request")
        XCTAssertTrue(app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "capture.activity."))
            .firstMatch.exists, "raw activity blocks are no longer inspectable")
        // The four-tab inspector is gone.
        XCTAssertFalse(app.descendants(matching: .any)["timeline.inspector"].exists,
                       "legacy inspector segmented control should be removed")
    }

    func testTimelineSelectionOnlyReplacesBoundedContext() {
        clickSidebar("sidebar.timeline")
        XCTAssertTrue(app.descendants(matching: .any)["timeline.workSessions"]
            .waitForExistence(timeout: 6))

        let session = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "timeline.session."))
            .firstMatch
        XCTAssertTrue(session.waitForExistence(timeout: 4),
                      "work sessions must be keyboard-focusable buttons")
        session.click()
        XCTAssertTrue(app.descendants(matching: .any)["timeline.sessionPreview"]
            .waitForExistence(timeout: 4), "session preview did not replace the day brief")
        XCTAssertTrue(app.descendants(matching: .any)["timeline.dayPicker"].exists,
                      "session selection replaced the persistent day header")
        XCTAssertTrue(app.descendants(matching: .any)["timeline.workSessions"].exists,
                      "session selection replaced the session list")
        XCTAssertTrue(textWithContent("Representative evidence").firstMatch.exists,
                      "session preview does not explain its evidence")

        // Returning to Timeline should restore both the selected session and
        // its inspector, including on the narrow hosted desktop.
        clickSidebar("sidebar.ask")
        clickSidebar("sidebar.timeline")
        XCTAssertTrue(app.descendants(matching: .any)["timeline.sessionPreview"]
            .waitForExistence(timeout: 4), "navigation discarded the selected work session")

        let back = app.buttons["Back to day digest"].firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 3))
        back.click()
        XCTAssertTrue(app.descendants(matching: .any)["capture.dayOverview"]
            .waitForExistence(timeout: 3))
        closeTimelineContext()

        let meeting = app.buttons["capture.meeting.\(fixture.designReview.id.uuidString)"]
        XCTAssertTrue(meeting.waitForExistence(timeout: 4),
                      "meeting block is not an accessible Timeline button")
        meeting.click()
        XCTAssertTrue(app.descendants(matching: .any)["timeline.meetingPreview"]
            .waitForExistence(timeout: 4), "Timeline did not open its compact meeting preview")
        XCTAssertFalse(app.descendants(matching: .any)["meeting.detail.workspace"].exists,
                       "Timeline mounted the full Meetings workspace")
        XCTAssertTrue(app.buttons["Open meeting"].exists,
                      "compact preview must provide the explicit Meetings handoff")
        XCTAssertTrue(app.descendants(matching: .any)["timeline.workSessions"].exists,
                      "meeting selection replaced Work sessions")
    }

    /// A date change is one state transition for the whole day workspace: it
    /// clears an old meeting preview and swaps the cached track, brief, and
    /// persisted digest to the newly selected local calendar day.
    func testTimelineDateChangeRefreshesOverviewAndDigest() {
        openLibrary()
        selectMeeting(fixture.designReview)
        XCTAssertTrue(identified("detail.title").waitForExistence(timeout: 4),
                      "meeting detail did not open before changing the day")

        clickSidebar("sidebar.timeline")
        XCTAssertTrue(app.descendants(matching: .any)["timeline.dayPicker"]
            .waitForExistence(timeout: 6), "Timeline did not render")

        let previousDay = app.buttons["timeline.previousDay"]
        XCTAssertTrue(previousDay.waitForExistence(timeout: 4),
                      "previous-day control is missing")
        previousDay.click()

        _ = revealTimelineContext()
        XCTAssertTrue(textWithContent(SyntheticFixture.previousDayDigestMarker).firstMatch
            .waitForExistence(timeout: 4), "previous day's digest did not replace today's")
        XCTAssertFalse(textWithContent(SyntheticFixture.todayDigestMarker).firstMatch.exists,
                       "today's digest remained visible after changing the date")
        XCTAssertFalse(textWithContent("Time allocation").firstMatch.exists,
                       "today's activity totals remained in the previous-day overview")
    }

    /// The sidebar swaps the content column between Timeline (work sessions)
    /// and Meetings (grouped meeting list) both ways.
    func testSidebarTogglesBetweenTimelineAndMeetings() {
        clickSidebar("sidebar.timeline")
        XCTAssertTrue(app.descendants(matching: .any)["timeline.dayPicker"]
            .waitForExistence(timeout: 6), "Timeline workspace missing")

        openLibrary()
        XCTAssertFalse(app.descendants(matching: .any)["timeline.dayPicker"].exists,
                       "Timeline should leave the screen in Meetings")

        clickSidebar("sidebar.timeline")
        XCTAssertTrue(app.descendants(matching: .any)["timeline.dayPicker"]
            .waitForExistence(timeout: 4), "Timeline did not come back")
    }

    // MARK: - Detail tabs

    func testMeetingWaveformExposesSliderAndSupportsKeyboardSeeking() {
        openLibrary()
        let row = meetingRow(for: fixture.designReview)
        XCTAssertTrue(row.waitForExistence(timeout: 4))
        row.click()
        let position = app.sliders["meeting.playbackPosition"]
        XCTAssertTrue(position.waitForExistence(timeout: 5),
                      "waveform must retain native slider accessibility")
        func assertPosition(_ seconds: Double, displayedTime: String) {
            // macOS exposes a native slider's AXValue as a number. The
            // formatted accessibility description is not its numeric value.
            XCTAssertEqual((position.value as? NSNumber)?.doubleValue, seconds,
                           "Unexpected slider value: \(String(describing: position.value))")
            XCTAssertTrue(app.staticTexts["\(displayedTime) / 00:01:00"].exists,
                          "the visible playback time must follow keyboard seeking")
        }
        position.click()
        app.typeKey(.home, modifierFlags: [])
        assertPosition(0, displayedTime: "00:00:00")
        app.typeKey(.rightArrow, modifierFlags: [])
        assertPosition(5, displayedTime: "00:00:05")
        app.typeKey(.leftArrow, modifierFlags: [])
        assertPosition(0, displayedTime: "00:00:00")
        app.typeKey(.end, modifierFlags: [])
        assertPosition(60, displayedTime: "00:01:00")
    }

    func testMeetingRowOpensFullWorkspaceWithAudioPlayer() {
        openLibrary()
        let row = meetingRow(for: fixture.designReview)
        XCTAssertTrue(row.waitForExistence(timeout: 4))
        row.click()
        XCTAssertTrue(app.descendants(matching: .any)["meeting.detail.workspace"]
            .waitForExistence(timeout: 5), "row did not open the full meeting workspace")
        XCTAssertTrue(identified("meeting.audioPlayer").waitForExistence(timeout: 5),
                      "full meeting workspace did not expose recorded-audio playback")
        XCTAssertFalse(app.buttons["Open meeting"].exists,
                       "meeting selection should not require a second navigation step")
        let actions = identified("meeting.export")
        XCTAssertTrue(actions.exists, "full workspace should retain meeting copy/export actions")
        actions.click()
        XCTAssertTrue(app.menuItems["Copy Meeting as Markdown"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.menuItems["Export Meeting as Markdown…"].exists)
        app.typeKey(.escape, modifierFlags: [])
    }

    func testActionCompletionImmediatelyLeavesTodayAttention() {
        openLibrary()
        let row = meetingRow(for: fixture.designReview)
        row.click()
        let toggle = app.buttons["meeting.action.toggle.fixture-action-design-1"]
        UITestHarness.scrollTo(toggle, in: app, attempts: 8)
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "meeting action toggle missing")
        toggle.click()

        clickSidebar("sidebar.today")
        XCTAssertTrue(app.descendants(matching: .any)["today.header"]
            .waitForExistence(timeout: 5))
        XCTAssertFalse(textWithContent("Draft the eviction policy document").firstMatch.exists,
                       "completed action remained in Today attention")
    }

    func testMultiMeetingThreadCompletionRequiresConfirmation() throws {
        try relaunchWithMatchingActions()
        let toggle = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "outcome.thread.toggle.")).firstMatch
        UITestHarness.scrollTo(toggle, in: app)
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "Thread toggle missing: \(app.debugDescription)")
        toggle.click()
        // App-wide queries also include Touch Bar controls, which cannot be
        // clicked through the normal macOS event path.
        let confirm = app.windows.buttons["Mark all done"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 4), "Multi-meeting completion needs explicit approval")
        let cancel = app.windows.buttons["Cancel"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 4))
        cancel.click()
        let stateURLs = [fixture.designReview, fixture.standup].map {
            fixture.folder(for: $0).appendingPathComponent("outcome-state.json")
        }
        XCTAssertTrue(stateURLs.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) },
                      "Cancelling must not write either source overlay")
        let review = app.buttons["outcomes.review"]
        UITestHarness.scrollTo(review, in: app)
        review.click()
        UITestHarness.selectSegment("Threads", pickerIdentifier: "actions.reviewMode", in: app)
        XCTAssertTrue(identified("actions.threads").waitForExistence(timeout: 5))
        let capture = XCTAttachment(screenshot: app.screenshot())
        capture.name = "action-thread-review"
        capture.lifetime = .keepAlways
        add(capture)
        toggle.click()
        XCTAssertTrue(confirm.waitForExistence(timeout: 4))
        confirm.click()
        XCTAssertTrue(UITestHarness.waitUntil {
            stateURLs.allSatisfy { FileManager.default.fileExists(atPath: $0.path) }
        })
        for url in stateURLs {
            let state = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
            let saved = try XCTUnwrap(state["actions"] as? [String: [String: Any]])
            XCTAssertEqual(saved["fixture-action-design-1"]?["status"] as? String, "done")
        }
        let undo = app.buttons["outcomes.undo"]
        XCTAssertTrue(undo.waitForExistence(timeout: 4))
        undo.click()
        XCTAssertTrue(UITestHarness.waitUntil {
            stateURLs.allSatisfy { url in
                guard let data = try? Data(contentsOf: url),
                      let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let saved = state["actions"] as? [String: [String: Any]] else { return false }
                return saved["fixture-action-design-1"]?["status"] as? String == "open"
            }
        }, "Thread Undo must restore every confirmed source")
    }

    func testActionThreadSourceCanBeSeparatedAndRestored() throws {
        try relaunchWithMatchingActions()
        let sources = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "outcome.thread.sources.")).firstMatch
        UITestHarness.scrollTo(sources, in: app)
        XCTAssertTrue(sources.waitForExistence(timeout: 5), "Thread sources missing: \(app.debugDescription)")
        sources.click()
        let separate = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "outcome.thread.separate.")).firstMatch
        XCTAssertTrue(separate.waitForExistence(timeout: 4))
        separate.click()
        let stateURLs = [fixture.designReview, fixture.standup].map {
            fixture.folder(for: $0).appendingPathComponent("outcome-state.json")
        }
        XCTAssertTrue(UITestHarness.waitUntil {
            stateURLs.filter { FileManager.default.fileExists(atPath: $0.path) }.count == 1
        })
        let stateURL = try XCTUnwrap(stateURLs.first { FileManager.default.fileExists(atPath: $0.path) })
        let state = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as? [String: Any])
        let actions = try XCTUnwrap(state["actions"] as? [String: [String: Any]])
        XCTAssertEqual(actions["fixture-action-design-1"]?["isThreadExcluded"] as? Bool, true)
        let toggles = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "outcome.thread.toggle."))
        XCTAssertTrue(UITestHarness.waitUntil { toggles.count == 2 })
        let menus = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "outcome.thread.status."))
        var restored = false
        for index in 0..<menus.count {
            menus.element(boundBy: index).click()
            let restore = app.menuItems["Allow matching across meetings"]
            if restore.waitForExistence(timeout: 1) {
                restore.click()
                restored = true
                break
            }
            app.typeKey(.escape, modifierFlags: [])
        }
        XCTAssertTrue(restored)
        XCTAssertTrue(UITestHarness.waitUntil { toggles.count == 1 })
    }

    private func relaunchWithMatchingActions() throws {
        app.terminate()
        let source = fixture.folder(for: fixture.designReview).appendingPathComponent("outcomes.json")
        let target = fixture.folder(for: fixture.standup).appendingPathComponent("outcomes.json")
        var outcomes = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: source)) as? [String: Any])
        let actions = try XCTUnwrap(outcomes["actionItems"] as? [[String: Any]])
        outcomes["actionItems"] = [try XCTUnwrap(actions.first)]
        outcomes["decisionRecords"] = []
        outcomes["openQuestions"] = []
        try JSONSerialization.data(withJSONObject: outcomes).write(to: target, options: .atomic)
        app = try UITestHarness.relaunch(storageRoot: fixture.root,
                                        defaultsSuiteName: XCTUnwrap(defaultsSuiteName))
        XCTAssertTrue(identified("today.header").waitForExistence(timeout: 10))
    }

    /// Full detail leads with actions and keeps the full summary and transcript
    /// in their own tabs.
    func testMeetingDetailLeadsWithActionsAndHasFullSummaryTab() {
        openLibrary()
        selectMeeting(fixture.designReview)
        XCTAssertEqual(identified("detail.title").value as? String ?? identified("detail.title").label, fixture.designReview.title)
        XCTAssertTrue(textWithContent("Adopt Redis").firstMatch.waitForExistence(timeout: 4))
        XCTAssertTrue(identified("meeting.audioPlayer").exists)
        XCTAssertTrue(textWithContent("Draft the eviction policy document").firstMatch.waitForExistence(timeout: 4))
        XCTAssertFalse(identified("meeting.summary").exists)
        UITestHarness.selectSegment("Full Summary", pickerIdentifier: "meeting.contentTabs", in: app)
        XCTAssertTrue(identified("meeting.summary").waitForExistence(timeout: 4))
        UITestHarness.selectSegment("Transcript", pickerIdentifier: "meeting.contentTabs", in: app)
        let first = app.staticTexts["transcript.segment.0.text"]
        XCTAssertTrue(first.waitForExistence(timeout: 4))
        XCTAssertTrue((first.value as? String)?.contains("caching layer") == true)
        XCTAssertTrue(identified("meeting.audioPlayer").exists)
        UITestHarness.selectSegment("Notes", pickerIdentifier: "meeting.contentTabs", in: app)
        XCTAssertTrue(identified("meeting.notes.editor").waitForExistence(timeout: 4))
    }

    func testPartialMeetingShowsSavedRecapAndActions() throws {
        app.terminate()
        try SyntheticFixture.makeNotesPartial(for: fixture.designReview, in: fixture)
        app = try UITestHarness.relaunch(storageRoot: fixture.root,
                                        defaultsSuiteName: XCTUnwrap(defaultsSuiteName))
        openLibrary()
        selectMeeting(fixture.designReview)
        XCTAssertTrue(identified("meeting.notes.partial").waitForExistence(timeout: 5))
        XCTAssertTrue(textWithContent("Redis was selected for the caching layer").firstMatch.exists)
        XCTAssertTrue(textWithContent("Draft the eviction policy document").firstMatch.exists)
        XCTAssertFalse(textWithContent("No action items were extracted").firstMatch.exists)
        XCTAssertFalse(textWithContent("Transcript or speaker details changed").firstMatch.exists)
        let toggle = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "meeting.action.toggle.")).firstMatch
        XCTAssertTrue(toggle.exists)
        XCTAssertFalse(toggle.isEnabled)
        UITestHarness.selectSegment("Full Summary", pickerIdentifier: "meeting.contentTabs", in: app)
        XCTAssertTrue(identified("meeting.summary").waitForExistence(timeout: 4))
        XCTAssertTrue(textWithContent("Redis was selected for the caching layer").firstMatch.exists)
    }

    /// Calendar attendees are explicit choices for remote diarization labels;
    /// email disambiguates the local choice but never becomes the alias.
    func testSpeakerRenameOffersCalendarAttendeeIdentities() {
        openLibrary()
        selectMeeting(fixture.designReview)

        UITestHarness.selectSegment("Transcript", pickerIdentifier: "meeting.contentTabs", in: app)

        let remoteSpeaker = app.buttons["transcript.segment.1.speaker"]
        UITestHarness.scrollTo(remoteSpeaker, in: app)
        XCTAssertTrue(remoteSpeaker.waitForExistence(timeout: 3))
        remoteSpeaker.click()

        let candidate = identified("speaker.rename.calendarCandidate.0")
        XCTAssertTrue(
            candidate.waitForExistence(timeout: 3),
            "calendar candidate missing from sheet AX tree:\n\(app.sheets.firstMatch.debugDescription)")
        XCTAssertEqual(
            candidate.elementType,
            .button,
            "calendar candidate must be an AXButton: \(candidate.debugDescription)")
        XCTAssertTrue(candidate.label.contains("Ana Petrović"),
                      "calendar candidate name missing from button label: \(candidate.label)")
        XCTAssertTrue(candidate.label.contains("ana@example.com"),
                      "calendar candidate email missing from button label: \(candidate.label)")
        candidate.click()

        let name = app.textFields["speaker.rename.name"]
        XCTAssertEqual(name.value as? String, "Ana Petrović")
        identified("speaker.rename.save").click()
        XCTAssertTrue(UITestHarness.waitUntil {
            self.app.buttons["transcript.segment.1.speaker"].label.contains("Ana Petrović")
        }, "calendar attendee was not saved as the speaker alias")
    }

    func testLongTranscriptSpeakerNameStaysInsideItsColumn() {
        openLibrary()
        selectMeeting(fixture.designReview)
        UITestHarness.selectSegment("Transcript", pickerIdentifier: "meeting.contentTabs", in: app)
        let speaker = app.buttons["transcript.segment.1.speaker"]
        UITestHarness.scrollTo(speaker, in: app)
        XCTAssertTrue(speaker.waitForExistence(timeout: 3))
        speaker.click()
        let name = app.textFields["speaker.rename.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 3))
        name.click()
        name.typeKey("a", modifierFlags: .command)
        let longName = "Alexandria Montgomery-Wellington"
        name.typeText(longName)
        identified("speaker.rename.save").click()
        XCTAssertTrue(UITestHarness.waitUntil { speaker.label == longName })
        let text = app.staticTexts["transcript.segment.1.text"]
        XCTAssertTrue(text.waitForExistence(timeout: 3))
        XCTAssertLessThanOrEqual(speaker.frame.width, 133)
        XCTAssertLessThanOrEqual(speaker.frame.maxX + 8, text.frame.minX)
        XCTAssertGreaterThan(text.frame.width, 100)
        let screenshot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        screenshot.name = "transcript-long-speaker-name"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        speaker.click()
        XCTAssertTrue(name.waitForExistence(timeout: 3))
        XCTAssertEqual(name.value as? String, longName)
        app.sheets.firstMatch.buttons["Cancel"].click()
    }

    /// Frequent processing actions stay direct, while copy/export and speech
    /// utilities remain available in one clearly labelled overflow.
    func testMeetingProcessingActionsAreDirectToolbarButtons() {
        openLibrary()
        selectMeeting(fixture.designReview)
        XCTAssertTrue(identified("meeting.ask").exists)
        identified("meeting.export").click()
        for label in ["Copy Summary", "Copy Transcript", "Copy Meeting as Markdown", "Export Meeting as Markdown…"] {
            XCTAssertTrue(app.menuItems[label].waitForExistence(timeout: 3))
        }
        app.typeKey(.escape, modifierFlags: [])
        identified("toolbar.meetingActions").click()
        for label in ["Transcribe & Summarize", "Transcribe only", "Summarize again", "Export audio"] {
            XCTAssertTrue(app.menuItems[label].waitForExistence(timeout: 3), "Missing meeting action: \(label)")
        }
        app.typeKey(.escape, modifierFlags: [])
    }

    /// Command-F and the visible toolbar action search every visible meeting
    /// content node. Matches move through outcomes and summary prose into
    /// collapsed transcript evidence without switching to library-wide Ask.
    func testMeetingFindSearchesAllVisibleContent() {
        openLibrary()
        selectMeeting(fixture.designReview)
        XCTAssertTrue(identified("detail.title").waitForExistence(timeout: 4))
        XCTAssertTrue(identified("toolbar.meetingSearch").exists)

        app.typeKey("f", modifierFlags: .command)
        let field = app.textFields["meeting.search.field"]
        XCTAssertTrue(
            field.waitForExistence(timeout: 3),
            "Command-F did not open meeting find. Menu tree:\n\(app.menuBars.debugDescription)")
        XCTAssertFalse(app.staticTexts["meeting.search.status"].exists,
                       "empty search repeated the field's scope label")
        field.typeText("failover")

        let status = app.staticTexts["meeting.search.status"]
        XCTAssertTrue(status.waitForExistence(timeout: 3))
        XCTAssertEqual(status.value as? String, "1 of 4 · Action items")

        identified("meeting.search.next").click()
        identified("meeting.search.next").click()
        identified("meeting.search.next").click()
        XCTAssertEqual(status.value as? String, "4 of 4 · Transcript")
        XCTAssertTrue(app.staticTexts["transcript.segment.3.text"]
            .waitForExistence(timeout: 3), "transcript match did not expand its evidence")

        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeText("Adopt Redis for caching")
        XCTAssertTrue(UITestHarness.waitUntil {
            status.value as? String == "1 of 2 · Decisions"
        }, "decision card text was not included before its summary duplicate")

        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeText("Zoom")
        XCTAssertTrue(UITestHarness.waitUntil {
            status.value as? String == "1 of 1 · Meeting details"
        }, "meeting header metadata was not searchable")
    }

    // MARK: - Ask

    /// FTS5-backed search reindexes on every launch — typing a term that
    /// only appears in the synthetic transcripts surfaces the matching
    /// meeting, and clicking the hit deep-links to that meeting's detail.
    func testSearchFindsTranscriptHitAndDeepLinks() {
        clickSidebar("sidebar.ask")
        switchToKeywordSearch()

        let field = app.textFields["search.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 8), "search field missing")
        let layoutDeadline = Date().addingTimeInterval(4)
        while field.frame.width < 40, Date() < layoutDeadline { usleep(150_000) }
        field.click()
        field.typeText("failover")

        let segmentHit = identified(
            "search.hit.\(fixture.designReview.id.uuidString).segment")
        XCTAssertTrue(segmentHit.waitForExistence(timeout: 4),
                      "expected design review segment hit for 'failover'")
        segmentHit.click()

        let title = identified("detail.title")
        XCTAssertTrue(title.waitForExistence(timeout: 4))
        XCTAssertEqual(title.value as? String ?? title.label, fixture.designReview.title)
    }

    /// The Ask section is reachable from the sidebar and renders its merged
    /// surface: the empty state, the single input, and — once a query is
    /// typed — the pinned assistant-escalation row above live results.
    /// Stops short of sending (that would spin up the real local LLM).
    func testAskSectionRendersAndAcceptsInput() {
        clickSidebar("sidebar.ask")

        XCTAssertTrue(textWithContent("Ask your work memory").firstMatch
            .waitForExistence(timeout: 6),
                      "ask empty-state did not render")
        XCTAssertTrue(app.descendants(matching: .any)["ask.submit"].exists,
                      "explicit Ask action missing")
        XCTAssertTrue(identified("ask.sources").exists,
                      "per-question source menu missing")
        XCTAssertTrue(identified("ask.timeScope").exists,
                      "independent time-scope control missing")
        XCTAssertTrue(identified("ask.inferenceStatus").exists,
                      "local/remote inference status missing")
        XCTAssertTrue(askRetrievalSegment("Search").exists,
                      "Search mode missing")

        let field = app.textFields["search.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 4), "ask input field missing")
        let layoutDeadline = Date().addingTimeInterval(4)
        while field.frame.width < 40, Date() < layoutDeadline { usleep(150_000) }
        field.click()
        field.typeText("what did we decide")
        XCTAssertEqual(field.value as? String, "what did we decide",
                       "ask input did not accept typed text")

        XCTAssertTrue(app.buttons["ask.submit"].isEnabled,
                      "Ask action did not become available for the typed question")
    }

    func testAskSwitchesExplicitlyToKeywordSearch() {
        clickSidebar("sidebar.ask")
        let field = app.textFields["search.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 6), "ask input field missing")
        let askFrame = field.frame

        UITestHarness.selectSegment(
            "Search", pickerIdentifier: "ask.retrieval", in: app)
        XCTAssertTrue(identified("ask.facet.all").waitForExistence(timeout: 4),
                      "Search facets did not appear")
        // The top-level switch stays binary; exact/meaning is a Search-only
        // menu so it cannot be confused with asking the model.
        XCTAssertTrue(askRetrievalSegment("Ask").exists, "Ask segment missing")
        XCTAssertTrue(identified("ask.searchMatching").exists,
                      "Exact/meaning search menu missing")
        XCTAssertTrue(identified("ask.sources").exists,
                      "Search must retain the same source scope as Ask")
        XCTAssertTrue(identified("ask.timeScope").exists)
        XCTAssertEqual(field.frame.minY, askFrame.minY, accuracy: 1,
                       "Switching modes must preserve the input position")
        XCTAssertGreaterThanOrEqual(field.frame.minX, app.windows.firstMatch.frame.minX)
        XCTAssertLessThanOrEqual(field.frame.maxX, app.windows.firstMatch.frame.maxX)
    }

    /// Restored split widths from Timeline or Meetings must not let the
    /// conversation list consume the Ask workspace. Push the detail divider
    /// toward the window edge and verify both column constraints hold.
    func testAskDetailResistsConversationListSqueeze() {
        clickSidebar("sidebar.ask")

        let field = app.textFields["search.field"]
        let conversations = identified("chat.conversationList")
        XCTAssertTrue(field.waitForExistence(timeout: 6), "ask input field missing")
        XCTAssertTrue(conversations.waitForExistence(timeout: 6),
                      "conversation list missing")

        let splitters = app.splitters
        XCTAssertGreaterThanOrEqual(splitters.count, 2,
                                    "Ask should expose sidebar and detail dividers")
        let detailDivider = splitters.element(boundBy: 1)
        XCTAssertTrue(detailDivider.waitForExistence(timeout: 4),
                      "Ask detail divider missing")

        app.activate()
        _ = app.wait(for: .runningForeground, timeout: 3)
        let destination = app.windows.firstMatch.coordinate(
            withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5))
        detailDivider.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: destination)

        XCTAssertTrue(UITestHarness.waitUntil {
            let detailWidth = self.app.windows.firstMatch.frame.maxX
                - detailDivider.frame.maxX
            return conversations.frame.width <= 330 && detailWidth >= 420
        }, "conversation history squeezed Ask below its readable width "
           + "(history: \(conversations.frame.width), Ask field: \(field.frame.width))")
    }

    /// ↵ escalates the query to the assistant: the pane switches from
    /// results to the conversation transcript with the query as the user
    /// turn. The model reply itself is not awaited (no local LLM in the
    /// test host) — the transition and the persisted user turn are the
    /// contract under test.
    func testAskEscalationShowsConversationWithUserTurn() {
        clickSidebar("sidebar.ask")

        let field = app.textFields["search.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 8), "ask input field missing")
        let layoutDeadline = Date().addingTimeInterval(4)
        while field.frame.width < 40, Date() < layoutDeadline { usleep(150_000) }
        field.click()
        field.typeText("failover")
        field.typeText("\r")

        let userTurn = app.staticTexts.matching(
            NSPredicate(format: "identifier == %@ AND value CONTAINS[c] %@",
                        "chat.message.user", "failover")).firstMatch
        XCTAssertTrue(userTurn.waitForExistence(timeout: 6),
                      "user turn did not appear in the conversation after ↵")
    }

    // MARK: - Selection

    func testMeetingSwitchKeepsReadingAnchorsAndSelectionStable() throws {
        XCTAssertFalse(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
                       "This regression must exercise normal motion; Reduce Motion has its own hosted test")
        // Exercise the real loading path slowly enough to inspect the outgoing
        // document. No audio on the second meeting also checks player geometry.
        for name in ["mic.live.caf", "system.live.caf"] {
            let path = fixture.folder(for: fixture.standup).appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: path.path) { try FileManager.default.removeItem(at: path) }
        }
        app.terminate()
        app = try UITestHarness.relaunch(storageRoot: fixture.root, defaultsSuiteName: defaultsSuiteName!,
            environment: ["LOKALBOT_SLOW_MEETING_LOAD": "1", "LOKALBOT_UI_TEST_DIAGNOSTICS": "1"])
        openLibrary()
        selectMeeting(fixture.designReview)
        XCTAssertTrue(identified("meeting.audioPlayer").waitForExistence(timeout: 5))
        let titleFrame = identified("detail.title").frame
        let tabsFrame = identified("meeting.contentTabs").frame
        let listTop = app.outlines["meeting.list"].frame.minY
        let firstRowTop = meetingRow(for: fixture.designReview).frame.minY

        meetingRow(for: fixture.standup).click()
        XCTAssertTrue(UITestHarness.waitUntil(timeout: 2) { self.identified("meeting.selection.loading").exists })
        XCTAssertEqual(identified("detail.title").value as? String ?? identified("detail.title").label,
                       fixture.designReview.title)
        XCTAssertEqual(identified("detail.title").frame.minX, titleFrame.minX, accuracy: 1)
        XCTAssertFalse(identified("meeting.ask").isEnabled, "Outgoing meeting actions must not target a stale selection")
        // Supersede the in-flight selection. Its completion must not replace
        // the final meeting, or flash its unloaded content in the meantime.
        meetingRow(for: fixture.planning).click()
        waitForMeetingTitle(fixture.planning.title)
        XCTAssertFalse(identified("meeting.selection.loading").exists)
        XCTAssertEqual(identified("meeting.contentTabs").frame.minY, tabsFrame.minY, accuracy: 1)
        XCTAssertTrue(identified("meeting.ask").isEnabled)

        selectMeeting(fixture.standup)
        XCTAssertTrue(textWithContent("No recording available").firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(identified("detail.title").frame.minX, titleFrame.minX, accuracy: 1)
        XCTAssertEqual(identified("meeting.contentTabs").frame.minY, tabsFrame.minY, accuracy: 1)
        let compact = XCTAttachment(screenshot: app.screenshot())
        compact.name = "meeting-switch-stable-without-audio"; compact.lifetime = .keepAlways; add(compact)

        selectTwo(fixture.designReview, fixture.standup)
        XCTAssertEqual(app.outlines["meeting.list"].frame.minY, listTop, accuracy: 1)
        XCTAssertEqual(meetingRow(for: fixture.designReview).frame.minY, firstRowTop, accuracy: 1,
                       "Multi-select controls must not push the meeting rows down")
        let multi = XCTAttachment(screenshot: app.screenshot())
        multi.name = "meeting-multiselect-stable-list"; multi.lifetime = .keepAlways; add(multi)
    }

    /// Cmd-clicking a second row enters the multi-select state — the detail
    /// pane swaps to the "N meetings selected" affordance with the deletion
    /// button and the hint copy. Guards against `selectedMeeting` accidentally
    /// returning non-nil for sets larger than one.
    func testMultiSelectShowsAggregateState() {
        openLibrary()
        selectTwo(fixture.designReview, fixture.standup)
        XCTAssertTrue(textWithContent("2 meetings selected").firstMatch.exists,
                      "multi-select headline missing")
        XCTAssertTrue(textWithContent("Press Delete or use the list menu").firstMatch.exists,
                      "multi-select description missing")
    }

    // MARK: - Delete confirmation

    /// Cancelling the confirmation dialog leaves both the list rows and the
    /// on-disk folders untouched — the dialog is the only friction protecting
    /// recordings from a stray click, so this regression test is load-bearing.
    func testDeleteConfirmationCancelsCleanly() {
        openLibrary()
        let deleteButton = selectTwo(fixture.standup, fixture.planning)
        deleteButton.click()

        // `.confirmationDialog` renders as a Sheet labelled "alert"; scope
        // the Cancel query to that sheet so we don't ambiguously match the
        // TouchBar's own Cancel button when one is present.
        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 5),
                      "confirmation sheet never appeared")
        sheet.buttons["Cancel"].click()

        XCTAssertTrue(meetingRow(for: fixture.standup).waitForExistence(timeout: 3),
                      "standup meeting must remain after a cancelled delete")
        XCTAssertTrue(meetingRow(for: fixture.planning).exists,
                      "planning meeting must remain after a cancelled delete")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: fixture.folder(for: fixture.standup).path),
            "standup folder must survive a cancelled delete")
    }

    /// Confirming runs the full destructive path — MainWindowView →
    /// `AppState.deleteMeetings` → `StorageManager.deleteMeeting` — removing
    /// both the list rows and the on-disk folders. Safe to actually delete:
    /// the fixture lives in a throwaway tmp root.
    func testDeleteConfirmedRemovesMeetingsFromListAndDisk() {
        openLibrary()
        let deleteButton = selectTwo(fixture.standup, fixture.planning)
        let standupFolder = fixture.folder(for: fixture.standup)
        let planningFolder = fixture.folder(for: fixture.planning)
        XCTAssertTrue(FileManager.default.fileExists(atPath: standupFolder.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: planningFolder.path))

        deleteButton.click()
        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 5),
                      "confirmation sheet never appeared")
        sheet.buttons["Delete (removes recordings & transcripts)"].click()

        // Rows vanish from the list…
        expectation(for: NSPredicate(format: "exists == false"),
                    evaluatedWith: meetingRow(for: fixture.standup))
        expectation(for: NSPredicate(format: "exists == false"),
                    evaluatedWith: meetingRow(for: fixture.planning))
        waitForExpectations(timeout: 5)

        // …and so do their folders on disk.
        XCTAssertFalse(FileManager.default.fileExists(atPath: standupFolder.path),
                       "standup folder must be removed from disk")
        XCTAssertFalse(FileManager.default.fileExists(atPath: planningFolder.path),
                       "planning folder must be removed from disk")
        XCTAssertTrue(meetingRow(for: fixture.designReview).exists,
                      "untouched meeting must remain in the list")
    }

    // MARK: - Settings

    /// ⌘, must land on the one in-window Settings home — the separate
    /// macOS Settings scene is gone (spec: one home per concern).
    func testSettingsShortcutLandsInWindow() {
        app.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(app.descendants(matching: .any)["settings.form"]
            .waitForExistence(timeout: 6),
                      "⌘, did not open Settings in the main window")
    }

    // MARK: - Helpers

    /// Click a sidebar entry by accessibility identifier. The identifier
    /// lives on the inner `Label`; descend-by-id is unambiguous because
    /// each sidebar item carries a unique identifier (`sidebar.<section>`).
    private func clickSidebar(_ identifier: String) {
        UITestHarness.clickSidebar(identifier, in: app)
    }

    /// Open the Meetings section and wait for the meeting list —
    /// the precondition for every list/detail/delete test.
    private func openLibrary() {
        clickSidebar("sidebar.meetings")
        XCTAssertTrue(app.outlines["meeting.list"].waitForExistence(timeout: 6),
                      "meeting list did not render in Meetings")
    }

    private func selectMeeting(_ meeting: SyntheticFixture.Meeting) {
        let row = meetingRow(for: meeting)
        XCTAssertTrue(row.waitForExistence(timeout: 4),
                      "meeting row for \(meeting.title) not found")
        row.click()
        XCTAssertTrue(app.descendants(matching: .any)["meeting.detail.workspace"]
            .waitForExistence(timeout: 5), "full meeting workspace did not render")
        waitForMeetingTitle(meeting.title)
    }

    private func waitForMeetingTitle(_ title: String) {
        XCTAssertTrue(UITestHarness.waitUntil(timeout: 5) {
            let element = self.identified("detail.title")
            return element.exists && (element.value as? String ?? element.label) == title
        }, "Selected meeting title did not settle: \(title)")
    }

    /// Select two rows (click + ⌘-click) and wait until the multi-select
    /// detail pane's destructive button appears, so callers begin from a
    /// known multi-select state. Returns that button for the delete flows.
    @discardableResult
    private func selectTwo(_ a: SyntheticFixture.Meeting,
                           _ b: SyntheticFixture.Meeting) -> XCUIElement {
        let first = meetingRow(for: a)
        XCTAssertTrue(first.waitForExistence(timeout: 4),
                      "row for \(a.title) not found")
        first.click()
        // Confirm the first selection committed before extending it: the
        // modifier-held ⌘-click can otherwise race an unsettled selection and
        // land as a plain click (leaving a single selection, so the aggregate
        // "Delete 2 meetings" button never appears).
        _ = identified("detail.title").waitForExistence(timeout: 4)
        XCUIElement.perform(withKeyModifiers: .command) { meetingRow(for: b).click() }
        let deleteButton = app.buttons["Delete 2 meetings"]
        XCTAssertTrue(deleteButton.waitForExistence(timeout: 4),
                      "multi-select Delete button never appeared")
        return deleteButton
    }

    private func meetingRow(for meeting: SyntheticFixture.Meeting) -> XCUIElement {
        // SwiftUI surfaces the row's accessibility identifier on the merged
        // StaticText element after `.accessibilityElement(children: .combine)`.
        // Multiple children may carry the same identifier; take the first.
        app.staticTexts.matching(
            NSPredicate(format: "identifier == %@",
                        "meeting.row.\(meeting.id.uuidString)"))
            .firstMatch
    }

    private func identified(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == %@", identifier)).firstMatch
    }

    /// Prefer the stable identifier; fall back to visible copy if AX role differs.
    private func digestTasksVisible() -> Bool {
        let identifiedHeader = app.descendants(matching: .any)["dayDigest.tasks"]
        if identifiedHeader.waitForExistence(timeout: 5) { return true }
        return textWithContent("Tasks").firstMatch.exists
    }

    private func switchToKeywordSearch() {
        UITestHarness.selectSegment(
            "Search", pickerIdentifier: "ask.retrieval", in: app)
        XCTAssertTrue(identified("ask.facet.all").waitForExistence(timeout: 5),
                      "Ask did not enter Search mode")
    }

    private func askRetrievalSegment(_ name: String) -> XCUIElement {
        UITestHarness.segment(name, pickerIdentifier: "ask.retrieval", in: app)
    }

    /// Timeline keeps the day context side by side when wide and behind an
    /// explicit drawer when narrow. Return whether the responsive drawer was
    /// needed so callers only make wide-layout frame assertions when valid.
    @discardableResult
    private func revealTimelineContext() -> Bool {
        let overview = identified("capture.dayOverview")
        let toggle = identified("timeline.context.toggle")
        let usesDrawer = toggle.exists
        if usesDrawer, !overview.exists { toggle.click() }
        XCTAssertTrue(overview.waitForExistence(timeout: 6),
                      "Timeline day context did not render")
        return usesDrawer
    }

    private func closeTimelineContext() {
        let overview = identified("capture.dayOverview")
        let toggle = identified("timeline.context.toggle")
        guard toggle.exists, overview.exists else { return }
        toggle.click()
        XCTAssertTrue(UITestHarness.waitUntil { !overview.exists },
                      "Timeline context drawer did not close")
    }

    /// True when the meeting list shows a day-group header beginning with
    /// `prefix` (e.g. "TODAY", "YESTERDAY"). Checks both `label` and `value`
    /// since SwiftUI may route the header text through either axis.
    private func hasDayHeader(in list: XCUIElement, prefix: String) -> Bool {
        list.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH %@ OR value BEGINSWITH %@",
                        prefix, prefix)).count > 0
    }

    /// Match a StaticText whose visible text (`label` or `value`) contains
    /// the fragment, case-insensitively. Scoped to `staticTexts` because
    /// `descendants(matching: .any)` evaluates predicates against every
    /// element type — too slow to use as a routine query.
    private func textWithContent(_ fragment: String) -> XCUIElementQuery {
        app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] %@ OR value CONTAINS[c] %@",
                        fragment, fragment))
    }
}
