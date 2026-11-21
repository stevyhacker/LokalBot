import AppKit
import XCTest

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
        XCTAssertTrue(app.descendants(matching: .any)["today.header"]
            .waitForExistence(timeout: 10), "today header never rendered")
    }

    override func tearDownWithError() throws {
        app?.terminate()
        fixture?.cleanUp()
        UITestHarness.cleanUp(defaultsSuiteName: defaultsSuiteName)
    }

    func testTodayUsesCompactDigestHierarchy() {
        XCTAssertTrue(identified("today.dayDigest.text").waitForExistence(timeout: 6))
        UITestHarness.scrollTo(identified("today.dayDigest.text"), in: app)
        XCTAssertTrue(textWithContent(SyntheticFixture.todayDigestMarker).firstMatch.exists)
        XCTAssertTrue(textWithContent("Digest written").firstMatch.exists)
        XCTAssertFalse(textWithContent("Fixture implementation").firstMatch.exists,
                       "the digest's tasks belong to Timeline")
        XCTAssertFalse(textWithContent("screen:4242").firstMatch.exists)
        XCTAssertFalse(identified("today.dayDigest.actions").exists)
        XCTAssertFalse(identified("today.sessions").exists, "work sessions belong to Timeline")
        XCTAssertFalse(identified("dayDigest.fullActivityLog").exists)
        for meeting in [fixture.designReview, fixture.standup] {
            XCTAssertTrue(identified("today.meeting.recording-\(meeting.id.uuidString)").exists)
        }
        XCTAssertTrue(app.buttons["outcomes.review"].exists)
        XCTAssertTrue(app.buttons["today.meetings.all"].exists, "Meetings today links to Meetings")
        XCTAssertTrue(app.buttons["today.openTimeline"].exists, "So far today links to Timeline")
        XCTAssertTrue(identified("today.tracked").exists, "tracked time and its bars are in So far today")
        XCTAssertFalse(app.buttons["outcomes.planInAgent"].exists, "planning with Agent moved to Actions")
        XCTAssertFalse(identified("today.memoryStatus").exists)
        XCTAssertFalse(identified("today.githubStar").exists)
        XCTAssertFalse(textWithContent("Morning brief").firstMatch.exists)
        XCTAssertFalse(textWithContent("Today’s brief").firstMatch.exists)
        XCTAssertFalse(textWithContent("Nothing recording right now").firstMatch.exists)
        XCTAssertFalse(app.toolbars.firstMatch.buttons["toolbar.record"].exists)
        XCTAssertTrue(app.buttons["today.record"].exists, "Record lives in Today's toolbar")
        XCTAssertFalse(identified("today.live").exists, "no card leads while nothing is recording")
    }

    func testToolbarShowsOneSidebarToggle() {
        XCTAssertTrue(toolbarSidebarButtons.firstMatch.waitForExistence(timeout: 4),
                      "native sidebar toolbar control missing")
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

    func testCommandPaletteDoesNotDuplicateTypedCharacters() {
        app.typeKey("k", modifierFlags: .command)
        let field = app.textFields["quickRecall.input"]
        XCTAssertTrue(field.waitForExistence(timeout: 4), "⌘K did not open Quick Recall")
        XCTAssertFalse(app.textFields["palette.input"].exists, "the separate palette window is gone")
        XCTAssertTrue(app.buttons["quickRecall.row.command.record"].waitForExistence(timeout: 4))

        field.click()
        field.typeText("AI tooling")

        XCTAssertEqual(field.value as? String, "AI tooling")
        app.typeKey(.escape, modifierFlags: [])
    }

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
        assertFooterAtLeadingEdge(privacyFooter, in: window,
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
        XCTAssertTrue(privacyFooter.waitForExistence(timeout: 4), "sidebar footer missing")
        assertFooterAtLeadingEdge(privacyFooter, in: app.windows.firstMatch,
                                  "three-column sidebar restored with an empty leading column")
    }

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

        assertFooterAtLeadingEdge(privacyFooter, in: window,
                                  "resizing centered the sidebar inside an oversized column")

        toolbarSidebarButtons.firstMatch.click()
        XCTAssertTrue(UITestHarness.waitUntil {
            !self.app.descendants(matching: .any)["sidebar.settings"].exists
        }, "resized sidebar remained exposed after hiding it")
        toolbarSidebarButtons.firstMatch.click()
        XCTAssertTrue(privacyFooter.waitForExistence(timeout: 5),
                      "resized sidebar did not return")
        assertFooterAtLeadingEdge(privacyFooter, in: window,
                                  "restored resized sidebar detached from the window edge")
    }

    private func assertFooterAtLeadingEdge(_ footer: XCUIElement, in window: XCUIElement, _ message: String,
                                           file: StaticString = #filePath, line: UInt = #line) {
        let inset = footer.frame.minX - window.frame.minX
        XCTAssertGreaterThanOrEqual(inset, 6, message, file: file, line: line)
        XCTAssertLessThanOrEqual(inset, 24, message, file: file, line: line)
    }

    private var toolbarSidebarButtons: XCUIElementQuery {
        app.toolbars.firstMatch.children(matching: .button).matching(NSPredicate(
            format: "label CONTAINS[c] 'sidebar'"))
    }

    private var anySidebarToggleButtons: XCUIElementQuery {
        app.toolbars.firstMatch.children(matching: .button).matching(NSPredicate(
            format: "identifier == 'toolbar.sidebarToggle' OR label CONTAINS[c] 'sidebar'"))
    }

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
        XCTAssertTrue(app.buttons["toolbar.record"].exists,
                      "record toolbar button missing")
    }

    func testMeetingLibrarySearchAndStatusFilterRender() {
        openLibrary()
        let search = app.textFields["meeting.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 4), "meeting search missing")
        XCTAssertFalse(app.descendants(matching: .any)["meeting.statusFilter"].exists,
                       "processing states belong on affected rows")
        search.click()
        search.typeText("Q3 roadmap")
        XCTAssertTrue(meetingRow(for: fixture.planning).waitForExistence(timeout: 4))
        XCTAssertFalse(meetingRow(for: fixture.designReview).exists)
        search.typeKey("a", modifierFlags: .command)
        search.typeKey(.delete, modifierFlags: [])
    }

    func testSidebarNavigationSwitchesSections() {
        clickSidebar("sidebar.settings")
        let settings = UITestHarness.settingsWindow(in: app)
        XCTAssertTrue(settings.waitForExistence(timeout: 6), "Settings did not open in its own window")
        XCTAssertTrue(settings.descendants(matching: .any)["settings.overview"].waitForExistence(timeout: 6),
                      "Settings did not open on Overview")
        XCTAssertTrue(settings.descendants(matching: .any)["settings.categories"].exists,
                      "Settings category navigation missing")
        XCTAssertEqual(app.windows.count, 2, "Settings must open beside the main window, not replace it")
        XCTAssertTrue(identified("today.header").exists, "The main window must stay on Today behind Settings")
        XCTAssertTrue(identified("sidebar.timeline").exists)
        app.typeKey(",", modifierFlags: .command)
        XCTAssertEqual(app.windows.count, 2, "⌘, must bring the open Settings window forward")
        clickSidebar("sidebar.timeline")
        XCTAssertFalse(settings.exists)
        XCTAssertTrue(app.descendants(matching: .any)["timeline.dayPicker"]
            .waitForExistence(timeout: 4),
                      "timeline section did not come back")
    }

    func testSidebarUsesApprovedRememberAndAssistantHierarchy() {
        XCTAssertTrue(identified("sidebar.section.remember").exists)
        XCTAssertTrue(identified("sidebar.section.assistant").exists)
        XCTAssertFalse(app.buttons["sidebar.section.remember"].exists,
                       "Remember must be a header, not a destination")
        XCTAssertFalse(app.buttons["sidebar.section.assistant"].exists,
                       "Assistant must be a header, not a destination")
        let ordered = ["sidebar.today", "sidebar.actions", "sidebar.meetings", "sidebar.timeline",
                       "sidebar.people", "sidebar.projects", "sidebar.ask", "sidebar.agent",
                       "sidebar.settings", "sidebar.localPrivacy"]
            .map(identified)
        for item in ordered {
            XCTAssertTrue(item.exists, "approved sidebar destination missing")
        }
        for pair in zip(ordered, ordered.dropFirst()) {
            XCTAssertLessThan(pair.0.frame.midY, pair.1.frame.midY,
                              "approved sidebar order changed")
        }
        XCTAssertFalse(identified("sidebar.type").exists)
        XCTAssertTrue(textWithContent("On this Mac").firstMatch.exists)
        XCTAssertFalse(textWithContent("AI: local + remote").firstMatch.exists)
    }

    func testActionsOpensFromTheSidebar() {
        clickSidebar("sidebar.actions")
        XCTAssertTrue(app.textFields["actions.search"].waitForExistence(timeout: 6),
                      "Actions did not open from the sidebar")
        clickSidebar("sidebar.today")
        XCTAssertTrue(UITestHarness.waitUntil { !self.app.textFields["actions.search"].exists },
                      "Today did not replace Actions")
    }

    func testModelsSectionRendersRoleCards() {
        clickSidebar("sidebar.settings")
        UITestHarness.selectSettingsCategory("Models", in: app)
        let content = app.scrollViews["models.content"]
        XCTAssertTrue(app.descendants(matching: .any)["models.overview"]
            .waitForExistence(timeout: 6), "core readiness overview missing")
        let heading = app.descendants(matching: .any)["models.heading.roles"]
        XCTAssertTrue(heading.waitForExistence(timeout: 4), "the role rows have no heading")
        XCTAssertTrue([heading.label, heading.value as? String ?? ""].joined(separator: " ")
            .contains("What each model does"), "the heading must say what the rows are")
        XCTAssertTrue(textWithContent("Turns meeting audio and dictation into text").firstMatch.exists,
                      "each role says what it does in plain words")
        XCTAssertTrue(app.buttons["models.stack.change.transcribe"]
            .waitForExistence(timeout: 6),
                      "Core Transcribe row did not render its Change button")
        for role in ["transcribe", "think", "autocomplete"] {
            XCTAssertTrue(app.descendants(matching: .any)["models.stack.chip.\(role)"].exists,
                          "\(role) has no status chip")
        }

        let advanced = app.buttons["models.advanced"]
        UITestHarness.scrollTo(advanced, in: app, within: content)
        XCTAssertTrue(advanced.exists, "Advanced group missing")
        XCTAssertFalse(app.descendants(matching: .any)["models.storage"].exists,
                       "Advanced starts folded")
        XCTAssertFalse(app.buttons["models.testAll"].exists,
                       "Check Setup is no longer a button on the page")
        advanced.click()
        let checks = app.buttons["models.testAll"]
        UITestHarness.scrollTo(checks, in: app, within: content)
        XCTAssertTrue(checks.waitForExistence(timeout: 4), "the checks stay reachable under Advanced")
        XCTAssertTrue(app.descendants(matching: .any)["models.storage"].exists,
                      "model storage summary missing")
        advanced.click()

        let other = app.buttons["models.more.other"]
        UITestHarness.scrollTo(other, in: app, within: content)
        other.click()
        XCTAssertTrue(app.descendants(matching: .any)["models.supporting.dictation"].waitForExistence(timeout: 4),
                      "dictation composition model card identifier missing")
        XCTAssertTrue(app.descendants(matching: .any)["models.supporting.search"].exists,
                      "embeddings model card identifier missing")
        app.buttons["models.back"].click()

        for change in ["models.stack.change.transcribe", "models.stack.change.think", "models.stack.change.type"] {
            let button = app.buttons[change]
            XCTAssertTrue(button.waitForExistence(timeout: 4), "\(change) button missing")
            UITestHarness.scrollTo(button, in: app, within: content)
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

        let preset = app.descendants(matching: .any)["models.choosePreset"].firstMatch
        XCTAssertTrue(preset.waitForExistence(timeout: 5), "Model set menu missing")
        UITestHarness.scrollTo(preset, in: app)
        preset.click()
        let lighter = app.menuItems.matching(NSPredicate(
            format: "identifier == %@ OR title BEGINSWITH %@", "models.preset.lightweight", "Lightweight local")).firstMatch
        XCTAssertTrue(lighter.waitForExistence(timeout: 4), "The menu must offer the app's own presets")
        lighter.click()
        XCTAssertTrue(app.buttons["models.preset.apply"]
            .waitForExistence(timeout: 4), "preset applied without a review step")
        XCTAssertTrue(textWithContent("Estimated new download").firstMatch.exists)
        XCTAssertTrue(textWithContent("After applying").firstMatch.exists)
        let reviewSheet = app.sheets.firstMatch
        XCTAssertTrue(reviewSheet.waitForExistence(timeout: 4), "preset review sheet missing")
        reviewSheet.buttons["Cancel"].firstMatch.click()
    }

    func testTimelineRendersTrackAndOverview() {
        clickSidebar("sidebar.timeline")
        XCTAssertTrue(app.descendants(matching: .any)["timeline.dayPicker"]
            .waitForExistence(timeout: 6), "the date in the toolbar did not render")
        XCTAssertTrue(identified("capture.askDay").exists,
                      "Ask about this day is missing from the toolbar")
        XCTAssertTrue(app.descendants(matching: .any)["timeline.workSessions"]
            .waitForExistence(timeout: 6), "the day's sessions should be listed immediately")
        XCTAssertFalse(identified("timeline.sessionPreview").exists,
                       "the day digest shows until something is selected")
        XCTAssertFalse(app.buttons["timeline.dayDigest.row"].exists,
                       "the rail lists sessions; Day digest is not a row")
        XCTAssertFalse(app.buttons["timeline.backToDigest"].exists,
                       "the day's page needs no link back to itself")
        XCTAssertLessThanOrEqual(
            identified("timeline.evidencePane").frame.maxX,
            identified("timeline.list").frame.minX + 1,
            "the day's page sits before the rail")
        XCTAssertFalse(textWithContent("Needs Attention").firstMatch.exists,
                       "Needs Attention moved to Today and Actions")
        let dayActions = identified("timeline.dayActions")
        XCTAssertTrue(dayActions.waitForExistence(timeout: 6),
                      "the day's actions panel is missing")
        let actionRows = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "outcome.thread.toggle."))
        XCTAssertTrue(actionRows.firstMatch.waitForExistence(timeout: 4),
                      "the day's open actions should be listed in their panel")
        XCTAssertTrue(app.buttons["timeline.dayActions.all"].exists,
                      "the actions panel should lead to Actions")
        let dayMenu = identified("timeline.dayDigest.actions")
        XCTAssertTrue(dayMenu.waitForExistence(timeout: 5),
                      "Timeline should expose its digest and day-memory menu")
        dayMenu.click()
        XCTAssertTrue(app.menuItems["timeline.dayDigest.regenerate"].waitForExistence(timeout: 3),
                      "Updating or rewriting the digest should stay one click away in the menu")
        XCTAssertTrue(app.menuItems["Copy digest"].exists)
        XCTAssertTrue(app.menuItems["Export as Markdown…"].exists)
        XCTAssertTrue(app.menuItems["Pause day memory"].exists)
        XCTAssertTrue(app.menuItems["Reload"].exists)
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertFalse(identified("timeline.activityEvidence").exists,
                       "the chronological track should not be hidden behind Activity evidence")
        XCTAssertFalse(textWithContent("Decisions").firstMatch.exists,
                       "empty decisions section should not consume Timeline space")
        XCTAssertTrue(textWithContent(SyntheticFixture.todayDigestMarker).firstMatch.exists,
                      "the digest's highlights should lead the page")
        XCTAssertTrue(identified("timeline.highlights").exists, "the highlights have their own panel")
        XCTAssertLessThan(
            identified("timeline.highlights").frame.minY,
            dayActions.frame.minY,
            "the highlights belong above the day's actions")
        XCTAssertLessThan(
            textWithContent(SyntheticFixture.todayDigestMarker).firstMatch.frame.maxX,
            identified("capture.dayOverview").frame.minX,
            "the day's totals and strip are in the rail, after the page")
        XCTAssertGreaterThanOrEqual(
            identified("capture.dayOverview").frame.minX,
            identified("timeline.list").frame.minX,
            "the day's totals and strip belong to the rail")
        XCTAssertTrue(textWithContent("tracked").firstMatch.waitForExistence(timeout: 6),
                      "day totals missing — seeded activity did not load")
        XCTAssertTrue(identified("timeline.dayStrip").exists, "the day strip is missing")
        XCTAssertLessThan(
            identified("capture.dayOverview").frame.minY,
            identified("timeline.workSessions").frame.minY,
            "the sessions are listed under the tracked time")
        XCTAssertTrue(digestTasksVisible(),
                      "digest task hierarchy is missing")
        XCTAssertTrue(textWithContent("Updated the Timeline UI").firstMatch.exists,
                      "human-facing focus summary is missing")
        XCTAssertFalse(textWithContent("User updated the Timeline UI").firstMatch.exists,
                       "model bookkeeping subject leaked into the focus summary")
        XCTAssertFalse(textWithContent("Source moment unavailable").firstMatch.exists,
                       "a missing source should leave no line behind")
        XCTAssertTrue(textWithContent("Xcode").firstMatch.waitForExistence(timeout: 4),
                      "seeded activity app 'Xcode' missing from the strip's legend")
        XCTAssertFalse(textWithContent("screen:4242").firstMatch.exists,
                       "private evidence identifier leaked into the collapsed overview")
        XCTAssertFalse(textWithContent("Nothing recorded").firstMatch.exists,
                       "empty state shown despite seeded activity blocks")
        XCTAssertTrue(app.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] %@", "TimelineView.swift"))
            .firstMatch.exists,
                      "seeded work-session title missing")
        XCTAssertTrue(app.descendants(matching: .any)["capture.meeting.\(fixture.designReview.id.uuidString)"].exists,
                      "seeded meeting missing from the day's list")
        let rawCapture = app.buttons["timeline.rawCapture"]
        XCTAssertTrue(rawCapture.exists,
                      "All captured activity is missing from the rail's foot")
        XCTAssertGreaterThan(
            rawCapture.frame.minY,
            identified("timeline.workSessions").frame.minY,
            "All captured activity sits under the sessions")
        XCTAssertFalse(app.descendants(matching: .any)["timeline.track"].exists,
                       "raw block chart should not be the default Timeline presentation")
        rawCapture.click()
        XCTAssertTrue(app.descendants(matching: .any)["timeline.track"]
            .waitForExistence(timeout: 4), "raw block chart did not open on request")
        XCTAssertTrue(app.buttons["timeline.backToDigest"].exists,
                      "All captured activity should offer the way back to the day's page")
        XCTAssertTrue(identified("capture.dayOverview").exists,
                      "the rail stays while All captured activity is open")
        XCTAssertTrue(app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "capture.activity."))
            .firstMatch.exists, "raw activity blocks are no longer inspectable")
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
            .waitForExistence(timeout: 4), "the session's page did not replace the digest")
        XCTAssertTrue(app.descendants(matching: .any)["timeline.dayPicker"].exists,
                      "session selection replaced the date in the toolbar")
        XCTAssertTrue(app.descendants(matching: .any)["timeline.workSessions"].exists,
                      "session selection replaced the session list")
        let whatWasOpen = identified("timeline.session.titleEvidence")
        XCTAssertTrue(whatWasOpen.waitForExistence(timeout: 4),
                      "the session's page does not list what was open")
        XCTAssertEqual(whatWasOpen.label, "What was open")

        clickSidebar("sidebar.ask")
        clickSidebar("sidebar.timeline")
        XCTAssertTrue(app.descendants(matching: .any)["timeline.sessionPreview"]
            .waitForExistence(timeout: 4), "navigation discarded the selected work session")

        XCTAssertTrue(identified("capture.dayOverview").exists,
                      "session selection replaced the rail's tracked time")
        XCTAssertFalse(identified("timeline.highlights").exists,
                       "the session's page replaces the day's page")
        XCTAssertFalse(app.buttons["Back to day"].exists,
                       "a row's page has one way back, Day digest")
        let digestLink = app.buttons["timeline.backToDigest"]
        XCTAssertTrue(digestLink.waitForExistence(timeout: 3))
        digestLink.click()
        let sessionPreview = app.descendants(matching: .any)["timeline.sessionPreview"]
        XCTAssertTrue(UITestHarness.waitUntil { !sessionPreview.exists },
                      "Day digest did not return to the day's page")
        XCTAssertTrue(identified("timeline.highlights").waitForExistence(timeout: 3),
                      "the day's page did not come back")

        let meeting = app.buttons["capture.meeting.\(fixture.designReview.id.uuidString)"]
        XCTAssertTrue(meeting.waitForExistence(timeout: 4),
                      "meeting row is not an accessible Timeline button")
        meeting.click()
        XCTAssertTrue(app.descendants(matching: .any)["timeline.meetingPreview"]
            .waitForExistence(timeout: 4), "Timeline did not open its compact meeting preview")
        XCTAssertFalse(app.descendants(matching: .any)["meeting.detail.workspace"].exists,
                       "Timeline mounted the full Meetings workspace")
        XCTAssertTrue(app.buttons["Open meeting"].exists,
                      "compact preview must provide the explicit Meetings handoff")
        XCTAssertTrue(app.descendants(matching: .any)["timeline.workSessions"].exists,
                      "meeting selection replaced the day's list")
    }

    func testTimelineDateChangeRefreshesOverviewAndDigest() {
        openLibrary()
        selectMeeting(fixture.designReview)
        XCTAssertTrue(identified("detail.title").waitForExistence(timeout: 4),
                      "meeting detail did not open before changing the day")

        clickSidebar("sidebar.timeline")
        XCTAssertTrue(app.descendants(matching: .any)["timeline.dayPicker"]
            .waitForExistence(timeout: 6), "Timeline did not render")

        let previousDay = app.buttons.matching(identifier: "timeline.previousDay").firstMatch
        XCTAssertTrue(previousDay.waitForExistence(timeout: 4),
                      "previous-day control is missing")
        previousDay.click()

        XCTAssertTrue(textWithContent(SyntheticFixture.previousDayDigestMarker).firstMatch
            .waitForExistence(timeout: 4), "previous day's digest did not replace today's")
        XCTAssertFalse(textWithContent(SyntheticFixture.todayDigestMarker).firstMatch.exists,
                       "today's digest remained visible after changing the date")
        XCTAssertFalse(textWithContent("Time allocation").firstMatch.exists,
                       "today's activity totals remained in the previous-day overview")
    }

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

    func testMeetingWaveformExposesSliderAndSupportsKeyboardSeeking() {
        openLibrary()
        let row = meetingRow(for: fixture.designReview)
        XCTAssertTrue(row.waitForExistence(timeout: 4))
        row.click()
        let position = app.sliders["meeting.playbackPosition"]
        XCTAssertTrue(position.waitForExistence(timeout: 5),
                      "waveform must retain native slider accessibility")
        func assertPosition(_ seconds: Double, displayedTime: String) {
            XCTAssertEqual((position.value as? NSNumber)?.doubleValue, seconds,
                           "Unexpected slider value: \(String(describing: position.value))")
            XCTAssertTrue(app.staticTexts["\(displayedTime) / 1:00"].exists,
                          "the visible playback time must follow keyboard seeking")
        }
        position.click()
        app.typeKey(.home, modifierFlags: [])
        assertPosition(0, displayedTime: "0:00")
        app.typeKey(.rightArrow, modifierFlags: [])
        assertPosition(5, displayedTime: "0:05")
        app.typeKey(.leftArrow, modifierFlags: [])
        assertPosition(0, displayedTime: "0:00")
        app.typeKey(.end, modifierFlags: [])
        assertPosition(60, displayedTime: "1:00")
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
        XCTAssertTrue(app.menuItems["Copy as Markdown"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.menuItems["Export as Markdown…"].exists)
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
        XCTAssertTrue(identified("actions.list").waitForExistence(timeout: 5))
        XCTAssertTrue(UITestHarness.staticText(containing: "In 2 meetings", in: app).waitForExistence(timeout: 5),
                      "A thread's row should say how many meetings it was said in")
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

    func testMeetingDetailLeadsWithActionsAndHasFullSummaryTab() {
        openLibrary()
        selectMeeting(fixture.designReview)
        XCTAssertEqual(identified("detail.title").value as? String ?? identified("detail.title").label, fixture.designReview.title)
        XCTAssertTrue(textWithContent("Adopt Redis").firstMatch.waitForExistence(timeout: 4))
        XCTAssertTrue(identified("meeting.audioPlayer").exists)
        XCTAssertTrue(textWithContent("Draft the eviction policy document").firstMatch.waitForExistence(timeout: 4))
        for panel in ["meeting.decisions", "meeting.actions", "meeting.questions"] {
            XCTAssertTrue(identified(panel + ".title").exists, "\(panel) has no panel header")
        }
        let player = identified("meeting.audioPlayer").frame
        let actions = identified("meeting.actions").frame
        let content = app.scrollViews["meeting.content.scroll"].frame
        XCTAssertEqual(actions.minX, player.minX, accuracy: 1)
        XCTAssertEqual(actions.maxX, player.maxX, accuracy: 1)
        XCTAssertEqual(actions.minX - content.minX, 24, accuracy: 1)
        XCTAssertLessThanOrEqual(content.maxX - actions.maxX, 24 + 20,
                                 "The panels run the width of the pane up to its gutter")
        XCTAssertFalse(identified("meeting.summary").exists)
        UITestHarness.scrollTo(identified("meeting.fullNotes"), in: app)
        XCTAssertEqual(identified("meeting.fullNotes").value as? String, "Collapsed",
                       "Full summary is only its header until opened")
        identified("meeting.fullNotes").click()
        XCTAssertTrue(identified("meeting.summary").waitForExistence(timeout: 4))
        UITestHarness.selectSegment("Transcript", pickerIdentifier: "meeting.contentTabs", in: app)
        let first = app.staticTexts["transcript.segment.0.text"]
        XCTAssertTrue(first.waitForExistence(timeout: 4))
        XCTAssertTrue((first.value as? String)?.contains("caching layer") == true)
        XCTAssertTrue(identified("meeting.transcript.title").exists, "The transcript is one titled panel")
        XCTAssertTrue(identified("meeting.audioPlayer").exists)
        UITestHarness.selectSegment("Notes", pickerIdentifier: "meeting.contentTabs", in: app)
        XCTAssertTrue(identified("meeting.notes.editor").waitForExistence(timeout: 4))
        XCTAssertTrue(identified("meeting.notes.title").exists, "The notes editor is the body of a titled panel")
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
        UITestHarness.scrollTo(identified("meeting.fullNotes"), in: app)
        identified("meeting.fullNotes").click()
        XCTAssertTrue(identified("meeting.summary").waitForExistence(timeout: 4))
        XCTAssertTrue(textWithContent("Redis was selected for the caching layer").firstMatch.exists)
    }

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
        XCTAssertTrue(candidate.label.contains("Calendar"), "Suggestions retain their provenance")
        XCTAssertTrue(identified("speaker.rename.leaveUnidentified").exists)
        XCTAssertFalse(app.staticTexts["Suggestions from calendar guests"].exists)
        candidate.click()

        let name = app.textFields["speaker.rename.name"]
        XCTAssertEqual(name.value as? String, "Ana Petrović")
        identified("speaker.rename.save").click()
        XCTAssertTrue(UITestHarness.waitUntil {
            self.app.buttons["transcript.segment.1.speaker"].label.contains("Ana Petrović")
        }, "calendar attendee was not saved as the speaker alias")
    }

    func testSpeakerRenameReturnFillsInTopSuggestion() {
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
        name.typeText("marko")
        XCTAssertTrue(UITestHarness.waitUntil { !self.identified("speaker.rename.calendarCandidate.0").exists },
                      "Typing a name must filter out suggestions that don't match")
        name.typeText("\r")
        XCTAssertEqual(name.value as? String, "Marko Marković")
        XCTAssertTrue(identified("speaker.rename.calendarCandidate.0").waitForExistence(timeout: 3),
                      "Filling in a match shows every suggestion again")
        name.typeText("\r")
        XCTAssertTrue(UITestHarness.waitUntil { speaker.label.contains("Marko Marković") },
                      "Return after filling in a match must save it")
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
        XCTAssertLessThanOrEqual(speaker.frame.maxY, text.frame.minY + 1)
        XCTAssertGreaterThanOrEqual(speaker.frame.minX + 24, text.frame.minX)
        XCTAssertLessThanOrEqual(speaker.frame.maxX, text.frame.maxX + 1)
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

    func testMeetingProcessingActionsAreDirectToolbarButtons() {
        openLibrary()
        selectMeeting(fixture.designReview)
        XCTAssertTrue(identified("meeting.ask").exists)
        identified("meeting.export").click()
        for label in ["Copy summary", "Copy transcript", "Copy as Markdown", "Export as Markdown…",
                      "Export audio…", "Export spoken summary…", "Copy meeting path"] {
            XCTAssertTrue(app.menuItems[label].waitForExistence(timeout: 3), "Missing share action: \(label)")
        }
        app.typeKey(.escape, modifierFlags: [])
        identified("toolbar.meetingActions").click()
        for label in ["Draft follow-up…", "Read summary aloud", "Edit start and end…", "Reprocess", "Show in Finder"] {
            XCTAssertTrue(app.menuItems[label].waitForExistence(timeout: 3), "Missing meeting action: \(label)")
        }
        app.menuItems["Reprocess"].hover()
        for label in ["Transcribe & Summarize", "Transcribe only", "Summarize again"] {
            XCTAssertTrue(app.menuItems[label].waitForExistence(timeout: 3), "Missing reprocess action: \(label)")
        }
        app.typeKey(.escape, modifierFlags: [])
        app.typeKey(.escape, modifierFlags: [])
    }

    func testMeetingFindSearchesAllVisibleContent() {
        openLibrary()
        selectMeeting(fixture.designReview)
        XCTAssertTrue(identified("detail.title").waitForExistence(timeout: 4))
        XCTAssertFalse(identified("toolbar.meetingSearch").exists,
                       "Find lives in the Edit menu and on Command-F, not in the toolbar")

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

    func testAskSectionRendersAndAcceptsInput() {
        clickSidebar("sidebar.ask")

        let heading = identified("ask.heading")
        XCTAssertTrue(heading.waitForExistence(timeout: 6), "ask empty-state did not render")
        XCTAssertTrue([heading.label, heading.value as? String ?? ""].joined(separator: " ")
            .contains("Ask about your meetings, screen and files"), "the empty page must say what Ask is for")
        XCTAssertFalse(app.buttons["ask.submit"].isEnabled, "Ask must be disabled while the field is empty")
        XCTAssertTrue(app.descendants(matching: .any)["ask.submit"].exists,
                      "explicit Ask action missing")
        XCTAssertTrue(identified("ask.sources").exists,
                      "per-question source menu missing")
        XCTAssertTrue(identified("ask.timeScope").exists,
                      "independent time-scope control missing")
        XCTAssertFalse(identified("ask.inferenceStatus").exists,
                       "a model on this Mac needs no line under the field")
        XCTAssertFalse(identified("ask.retrieval").exists,
                       "live recall must not require a mode switch")

        let field = app.textFields["search.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 4), "ask input field missing")
        let layoutDeadline = Date().addingTimeInterval(4)
        while field.frame.width < 40, Date() < layoutDeadline { usleep(150_000) }
        field.click()
        field.typeText("what did we decide")
        XCTAssertEqual(field.value as? String, "what did we decide",
                       "ask input did not accept typed text")

        XCTAssertTrue(UITestHarness.waitUntil { self.app.buttons["ask.submit"].isEnabled },
                      "Ask action did not become available for the typed question")
    }

    func testAskSwitchesExplicitlyToKeywordSearch() {
        clickSidebar("sidebar.ask")
        let field = app.textFields["search.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 6), "ask input field missing")
        let askFrame = field.frame

        field.click()
        field.typeText("failover")
        XCTAssertTrue(identified("search.results").waitForExistence(timeout: 5))
        XCTAssertFalse(identified("ask.retrieval").exists)
        XCTAssertFalse(identified("ask.searchMatching").exists)
        XCTAssertTrue(identified("ask.sources").exists,
                      "Search must retain the same source scope as Ask")
        XCTAssertTrue(identified("ask.timeScope").exists)
        XCTAssertEqual(field.frame.minY, askFrame.minY, accuracy: 1,
                       "Switching modes must preserve the input position")
        XCTAssertGreaterThanOrEqual(field.frame.minX, app.windows.firstMatch.frame.minX)
        XCTAssertLessThanOrEqual(field.frame.maxX, app.windows.firstMatch.frame.maxX)
    }

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
            return conversations.frame.width <= 340 && detailWidth >= 420
        }, "conversation history squeezed Ask below its readable width "
           + "(history: \(conversations.frame.width), Ask field: \(field.frame.width))")
    }

    func testAskEscalationShowsConversationWithUserTurn() {
        clickSidebar("sidebar.ask")

        let field = app.textFields["search.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 8), "ask input field missing")
        let layoutDeadline = Date().addingTimeInterval(4)
        while field.frame.width < 40, Date() < layoutDeadline { usleep(150_000) }
        field.click()
        field.typeText("What did we decide about failover?")
        field.typeText("\r")

        let userTurn = app.staticTexts.matching(
            NSPredicate(format: "identifier == %@ AND value CONTAINS[c] %@",
                        "chat.message.user", "failover")).firstMatch
        XCTAssertTrue(userTurn.waitForExistence(timeout: 6),
                      "user turn did not appear in the conversation after ↵")
        XCTAssertEqual(identified("ask.sources").value as? String, "All sources")
    }

    func testMeetingSwitchKeepsReadingAnchorsAndSelectionStable() throws {
        XCTAssertFalse(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
                       "This regression must exercise normal motion; Reduce Motion has its own hosted test")
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

    func testMultiSelectShowsAggregateState() {
        openLibrary()
        selectTwo(fixture.designReview, fixture.standup)
        XCTAssertTrue(textWithContent("2 meetings selected").firstMatch.exists,
                      "multi-select headline missing")
        XCTAssertTrue(textWithContent("Press Delete or use the list menu").firstMatch.exists,
                      "multi-select description missing")
    }

    func testDeleteConfirmationCancelsCleanly() {
        openLibrary()
        let deleteButton = selectTwo(fixture.standup, fixture.planning)
        deleteButton.click()

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

        expectation(for: NSPredicate(format: "exists == false"),
                    evaluatedWith: meetingRow(for: fixture.standup))
        expectation(for: NSPredicate(format: "exists == false"),
                    evaluatedWith: meetingRow(for: fixture.planning))
        waitForExpectations(timeout: 5)

        XCTAssertFalse(FileManager.default.fileExists(atPath: standupFolder.path),
                       "standup folder must be removed from disk")
        XCTAssertFalse(FileManager.default.fileExists(atPath: planningFolder.path),
                       "planning folder must be removed from disk")
        XCTAssertTrue(meetingRow(for: fixture.designReview).exists,
                      "untouched meeting must remain in the list")
    }

    func testNemotronSpeakerModelSelectionPersistsAndRespectsDiarizationToggle() {
        clickSidebar("sidebar.settings")
        UITestHarness.selectSettingsCategory("Meetings", in: app)
        let picker = app.popUpButtons["settings.diarizationModel"]
        UITestHarness.scrollTo(picker, in: app)
        XCTAssertTrue(picker.waitForExistence(timeout: 4))
        XCTAssertEqual(picker.label, "Speaker model")
        XCTAssertEqual(picker.value as? String, "Pyannote Community-1")
        picker.click()
        app.menuItems["Nemotron 3 (Preview)"].click()
        XCTAssertTrue(UITestHarness.waitUntil { picker.value as? String == "Nemotron 3 (Preview)" })

        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = "Nemotron speaker model settings"
        attachment.lifetime = .keepAlways
        add(attachment)

        let toggle = UITestHarness.toggle("Separate voices by speaker", in: app)
        UITestHarness.scrollTo(toggle, in: app, within: app.scrollViews["settings.form"])
        XCTAssertTrue(toggle.waitForExistence(timeout: 4))
        toggle.click()
        XCTAssertTrue(UITestHarness.waitUntil { !picker.isEnabled })
        toggle.click()
        XCTAssertTrue(UITestHarness.waitUntil { picker.isEnabled })

        clickSidebar("sidebar.meetings")
        clickSidebar("sidebar.settings")
        UITestHarness.selectSettingsCategory("Meetings", in: app)
        UITestHarness.scrollTo(picker, in: app)
        XCTAssertEqual(picker.value as? String, "Nemotron 3 (Preview)")
    }

    func testSettingsShortcutLandsInWindow() {
        app.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(UITestHarness.settingsWindow(in: app).descendants(matching: .any)["settings.categories"]
            .waitForExistence(timeout: 6),
                      "⌘, did not open the Settings window")
        XCTAssertTrue(identified("today.header").exists, "The main window must stay where it was")
    }

    private func clickSidebar(_ identifier: String) {
        UITestHarness.clickSidebar(identifier, in: app)
    }

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

    @discardableResult
    private func selectTwo(_ a: SyntheticFixture.Meeting,
                           _ b: SyntheticFixture.Meeting) -> XCUIElement {
        let first = meetingRow(for: a)
        XCTAssertTrue(first.waitForExistence(timeout: 4),
                      "row for \(a.title) not found")
        first.click()
        _ = identified("detail.title").waitForExistence(timeout: 4)
        XCUIElement.perform(withKeyModifiers: .command) { meetingRow(for: b).click() }
        let deleteButton = app.buttons["Delete 2 meetings"]
        XCTAssertTrue(deleteButton.waitForExistence(timeout: 4),
                      "multi-select Delete button never appeared")
        return deleteButton
    }

    private func meetingRow(for meeting: SyntheticFixture.Meeting) -> XCUIElement {
        app.staticTexts.matching(
            NSPredicate(format: "identifier == %@",
                        "meeting.row.\(meeting.id.uuidString)"))
            .firstMatch
    }

    private func identified(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == %@", identifier)).firstMatch
    }

    private func digestTasksVisible() -> Bool {
        let identifiedHeader = app.descendants(matching: .any)["dayDigest.tasks"]
        if identifiedHeader.waitForExistence(timeout: 5) { return true }
        return textWithContent("Work summary").firstMatch.exists
    }

    private func switchToKeywordSearch() {
        XCTAssertTrue(identified("search.field").waitForExistence(timeout: 5))
        XCTAssertFalse(identified("ask.retrieval").exists)
    }

    private func hasDayHeader(in list: XCUIElement, prefix: String) -> Bool {
        list.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH[c] %@ OR value BEGINSWITH[c] %@",
                        prefix, prefix)).count > 0
    }

    private func textWithContent(_ fragment: String) -> XCUIElementQuery {
        app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] %@ OR value CONTAINS[c] %@",
                        fragment, fragment))
    }
}
