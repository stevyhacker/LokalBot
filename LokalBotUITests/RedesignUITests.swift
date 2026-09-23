import XCTest

/// Hosted-only review of the integrated redesign against synthetic evidence.
/// Screenshots remain in the test result bundle; no private library is used.
final class RedesignUITests: XCTestCase {
    private var fixture: SyntheticFixture.Library!
    private var app: XCUIApplication!
    private var suite: String?
    private var previousVisualFixtures: [SyntheticFixture.Library] = []

    override func setUpWithError() throws {
        continueAfterFailure = false
        fixture = try SyntheticFixture.plant()
    }
    override func tearDownWithError() throws {
        app?.terminate()
        UITestHarness.cleanUp(defaultsSuiteName: suite)
        fixture?.cleanUp()
        previousVisualFixtures.forEach { $0.cleanUp() }
    }

    func testWorkspaceVisualMatrix() throws {
        // Collect route assertion failures across the matrix for review. Any
        // failed assertion still fails this test and the aggregate release gate.
        continueAfterFailure = true
        defer { continueAfterFailure = false }
        let routes: [(String, [String: String])] = [
            ("today", ["LOKALBOT_INITIAL_SECTION": "today"]),
            ("actions", ["LOKALBOT_INITIAL_ACTIONS": "1"]),
            ("meeting", ["LOKALBOT_INITIAL_SECTION": "meetings", "LOKALBOT_SELECT_INDEX": "0"]),
            ("transcript", ["LOKALBOT_INITIAL_SECTION": "meetings", "LOKALBOT_SELECT_INDEX": "0", "LOKALBOT_DETAIL_TAB": "transcript"]),
            ("review", ["LOKALBOT_INITIAL_SECTION": "meetings", "LOKALBOT_SELECT_INDEX": "0", "LOKALBOT_DETAIL_TAB": "review"]),
            ("timeline", ["LOKALBOT_INITIAL_SECTION": "timeline"]),
            ("search", ["LOKALBOT_INITIAL_SECTION": "ask", "LOKALBOT_INITIAL_ASK_MODE": "search", "LOKALBOT_INITIAL_SEARCH": "failover"]),
            ("ask", ["LOKALBOT_INITIAL_SECTION": "ask"]),
            ("settings", ["LOKALBOT_INITIAL_SECTION": "settings", "LOKALBOT_INITIAL_SETTINGS_CATEGORY": "privacy"]),
            ("models", ["LOKALBOT_INITIAL_SECTION": "models"]),
            ("dictation", ["LOKALBOT_INITIAL_SECTION": "dictation"]),
            ("autocomplete", ["LOKALBOT_INITIAL_SECTION": "autocomplete", "LOKALBOT_COTYPING_DEMO": "1"]),
            ("agent", ["LOKALBOT_INITIAL_SECTION": "agent", "LOKALBOT_AGENT_DEMO": "1"]),
        ]
        let processEnvironment = ProcessInfo.processInfo.environment
        let requestedSize = processEnvironment["LOKALBOT_VISUAL_SIZE"] ?? ""
        let allSizes = ["1000x700", "1180x740", "1440x900"]
        XCTAssertTrue(requestedSize.isEmpty || allSizes.contains(requestedSize), "Unknown visual shard")
        let sizes = requestedSize.isEmpty ? allSizes : [requestedSize]
        for size in sizes {
            for appearance in ["light", "dark"] {
                for (route, state) in routes {
                    // A complete matrix can cross midnight. Keep Today and
                    // Timeline populated on the new civil day, while retaining
                    // earlier attachment files until XCTest serializes them.
                    if !Calendar.current.isDateInToday(fixture.designReview.startedAt) {
                        previousVisualFixtures.append(fixture)
                        fixture = try SyntheticFixture.plant()
                    }
                    let name = "\(size)-\(appearance)-\(route)"
                    let destination = fixture.root.appendingPathComponent(name + ".png")
                    var environment = state
                    environment.merge([
                        "LOKALBOT_CAPTURE_FILE": destination.path,
                        "LOKALBOT_CAPTURE_SIZE": size, "LOKALBOT_CAPTURE_SCALE": "1", "LOKALBOT_CAPTURE_DELAY": "8",
                        "LOKALBOT_CAPTURE_APPEARANCE": appearance, "LOKALBOT_SCREEN_MEMORY_DEMO": "1",
                        "LOKALBOT_AGENT_UI_TEST_READY": "1",
                    ]) { _, value in value }
                    let readyFile = destination.appendingPathExtension("ready")
                    if processEnvironment["LOKALBOT_CAPTURE_MODE"] != "legacy" {
                        environment["LOKALBOT_CAPTURE_READY_FILE"] = readyFile.path
                    }
                    try launch(environment)
                    if environment["LOKALBOT_CAPTURE_READY_FILE"] != nil {
                        try acknowledgeCaptureReadiness(route: route, size: size, readyFile: readyFile)
                    }
                    XCTAssertTrue(UITestHarness.waitUntil(timeout: 20) { FileManager.default.fileExists(atPath: destination.path) },
                                  "Native capture did not finish: \(name)")
                    let bitmap = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: destination)))
                    XCTAssertEqual(bitmap.pixelsWide, Int(size.split(separator: "x")[0]), "Capture width must match the requested layout")
                    XCTAssertEqual(bitmap.pixelsHigh, Int(size.split(separator: "x")[1]), "Capture height must match the requested layout")
                    let attachment = XCTAttachment(contentsOfFile: destination)
                    attachment.name = name; attachment.lifetime = .keepAlways
                    add(attachment)
                    if let evidencePath = processEnvironment["LOKALBOT_VISUAL_EVIDENCE"] {
                        let directory = URL(fileURLWithPath: evidencePath, isDirectory: true)
                        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                        try FileManager.default.copyItem(at: destination, to: directory.appendingPathComponent(name + ".png"))
                    }
                }
            }
        }
    }

    private func acknowledgeCaptureReadiness(route: String, size: String, readyFile: URL) throws {
        let anchors = [
            "today": "today.dayDigest.text", "actions": "actions.search",
            "meeting": "meeting.audioPlayer", "transcript": "transcript.segment.0.text",
            "review": "meeting.review.speakers",
            "timeline": "timeline.workSessions", "search": "search.hit.\(fixture.designReview.id.uuidString).segment",
            "ask": "ask.submit", "settings": "settings.retention", "models": "models.overview",
            "dictation": "dictation.form", "agent": "agent.composer",
        ]
        if let identifier = anchors[route] {
            XCTAssertTrue(element(identifier).waitForExistence(timeout: 10), "Capture content not ready: \(route)")
        } else {
            XCTAssertTrue(app.staticTexts["Try the real autocomplete"].waitForExistence(timeout: 10))
        }
        if route == "timeline" {
            XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "TimelineView.swift"))
                .firstMatch.waitForExistence(timeout: 5), "Capture must include the seeded work session")
            XCTAssertTrue(element("capture.meeting.\(fixture.designReview.id.uuidString)").exists,
                          "Capture must include the seeded meeting")
        }
        if ["meeting", "transcript", "review"].contains(route) {
            let title = element("detail.title")
            let expectedTitle = fixture.designReview.title
            XCTAssertTrue(UITestHarness.waitUntil(timeout: 5) {
                (title.value as? String ?? title.label) == expectedTitle
            }, "Capture must select the requested meeting")
        }
        let dimensions = size.split(separator: "x").compactMap { Double($0) }
        XCTAssertTrue(UITestHarness.waitUntil(timeout: 5) {
            let frame = self.app.windows.firstMatch.frame
            return abs(frame.width - dimensions[0]) < 1 && abs(frame.height - dimensions[1]) < 1
        }, "Capture window has not reached the requested geometry")
        try Data("ready".utf8).write(to: readyFile, options: .atomic)
    }

    func testSearchReturnIsSilentAndExplicitAskReviewsScope() throws {
        try launch(blockedInference: true)
        UITestHarness.clickSidebar("sidebar.ask", in: app)
        let input = app.textFields["search.field"]
        input.click(); input.typeText("failover")
        XCTAssertTrue(element("search.hit.\(fixture.designReview.id.uuidString).segment").waitForExistence(timeout: 6))
        input.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(app.staticTexts["transcript.segment.3.text"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["chat.message.user"].exists)
        XCTAssertTrue(app.buttons["Play"].exists, "Evidence should be paused until Play is chosen")
        app.buttons["Back"].firstMatch.click()
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        XCTAssertEqual(input.value as? String, "failover")
        XCTAssertTrue(UITestHarness.waitUntil { self.app.buttons["ask.submit"].isEnabled })
        input.typeKey(.return, modifierFlags: .command)
        XCTAssertTrue(element("ask.selectedEvidence").waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["chat.message.user"].waitForExistence(timeout: 5))
        XCTAssertEqual(input.value as? String, "")
        snapshot("bounded-ask-question")
    }

    func testRecallKeepsInputScopeAndHistoryInPlaceAcrossModes() throws {
        try launch(["LOKALBOT_INITIAL_SECTION": "ask", "LOKALBOT_CAPTURE_SIZE": "1000x700"])
        let input = app.textFields["search.field"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        let inputFrame = input.frame
        let sourcesFrame = element("ask.sources").frame
        let dateFrame = element("ask.timeScope").frame
        let historyFrame = element("chat.conversationList").frame
        let sourceLabel = element("ask.sources").label
        let dateLabel = element("ask.timeScope").label

        XCTAssertEqual(input.frame.minX, inputFrame.minX, accuracy: 1)
        XCTAssertEqual(input.frame.minY, inputFrame.minY, accuracy: 1)
        XCTAssertEqual(element("ask.sources").frame.minY, sourcesFrame.minY, accuracy: 1)
        XCTAssertEqual(element("ask.timeScope").frame.minY, dateFrame.minY, accuracy: 1)
        XCTAssertEqual(element("chat.conversationList").frame.width, historyFrame.width, accuracy: 1)
        input.click(); input.typeText("failover")
        XCTAssertTrue(element("search.hit.\(fixture.designReview.id.uuidString).segment").waitForExistence(timeout: 6))
        XCTAssertEqual(input.frame.minY, inputFrame.minY, accuracy: 1, "Results must not relocate the input")
        XCTAssertEqual(element("ask.sources").label, sourceLabel)
        XCTAssertEqual(element("ask.timeScope").label, dateLabel)
        snapshot("search-stable-input")

        XCTAssertEqual(input.value as? String, "failover")
        XCTAssertEqual(input.frame.minX, inputFrame.minX, accuracy: 1)
        XCTAssertEqual(input.frame.minY, inputFrame.minY, accuracy: 1)
        XCTAssertEqual(element("ask.sources").label, sourceLabel)
        XCTAssertEqual(element("ask.timeScope").label, dateLabel)
        XCTAssertFalse(app.staticTexts["chat.message.user"].exists, "Switching modes must not submit the query")
    }

    func testAskHasOneDateScopeAndVisibleRemovableFilters() throws {
        try launch(["LOKALBOT_INITIAL_SECTION": "ask", "LOKALBOT_CAPTURE_SIZE": "1000x700"])
        let date = element("ask.timeScope")
        XCTAssertTrue(date.waitForExistence(timeout: 5))
        date.click()
        app.buttons["ask.timeScope.sevenDays"].click()
        XCTAssertTrue(date.label.contains("Last 7 days"))
        XCTAssertTrue(element("ask.filter.date.clear").exists)
        element("ask.sources").click()
        XCTAssertTrue(app.menuItems["Result type"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.menuItems["Screen dates"].exists)
        app.menuItems["Result type"].hover()
        XCTAssertTrue(app.menuItems["Summaries"].waitForExistence(timeout: 3))
        app.menuItems["Summaries"].click()
        let typeFilter = element("ask.filter.resultType")
        XCTAssertTrue(typeFilter.waitForExistence(timeout: 3))
        XCTAssertTrue(typeFilter.label.contains("Summaries"))
        snapshot("ask-unified-date-filters")
        typeFilter.click()
        XCTAssertFalse(typeFilter.exists)
        element("ask.filter.date.clear").click()
        XCTAssertTrue(date.label.contains("Any time"))
        XCTAssertFalse(element("ask.filter.date.clear").exists)
    }

    func testClearingResultEvidenceRestoresSearchSources() throws {
        try launch(["LOKALBOT_INITIAL_SECTION": "ask", "LOKALBOT_INITIAL_ASK_MODE": "search",
                    "LOKALBOT_INITIAL_SEARCH": "failover"], blockedInference: true)
        let sources = element("ask.sources")
        XCTAssertTrue(sources.waitForExistence(timeout: 5))
        let originalSources = sources.value as? String
        XCTAssertNotNil(originalSources)
        XCTAssertTrue(element("search.hit.\(fixture.designReview.id.uuidString).segment").waitForExistence(timeout: 6))
        XCTAssertTrue(UITestHarness.waitUntil { self.app.buttons["ask.submit"].isEnabled })
        app.buttons["ask.submit"].click()
        XCTAssertTrue(element("ask.selectedEvidence").waitForExistence(timeout: 3))
        XCTAssertNotEqual(sources.value as? String, originalSources)
        element("ask.selectedEvidence").click()
        XCTAssertTrue(UITestHarness.waitUntil { sources.value as? String == originalSources })
        XCTAssertFalse(element("ask.selectedEvidence").exists)
    }

    func testRecallDividerRestoresAfterVisitingOtherWorkspaces() throws {
        try launch(["LOKALBOT_INITIAL_SECTION": "ask", "LOKALBOT_CAPTURE_SIZE": "1440x900"])
        let history = element("chat.conversationList")
        XCTAssertTrue(history.waitForExistence(timeout: 5))
        let originalWidth = history.frame.width
        let divider = history.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 0.5))
        let resizeDelta: CGFloat = originalWidth > 280 ? -45 : 45
        divider.press(forDuration: 0.2, thenDragTo: divider.withOffset(CGVector(dx: resizeDelta, dy: 0)))
        XCTAssertTrue(UITestHarness.waitUntil { abs(history.frame.width - originalWidth) > 20 },
                      "The test must exercise a user-resized divider")
        let chosenWidth = history.frame.width
        for section in ["sidebar.timeline", "sidebar.meetings", "sidebar.settings"] {
            UITestHarness.clickSidebar(section, in: app)
            UITestHarness.clickSidebar("sidebar.ask", in: app)
            XCTAssertTrue(history.waitForExistence(timeout: 5))
            XCTAssertTrue(UITestHarness.waitUntil { abs(history.frame.width - chosenWidth) <= 2 },
                          "Recall width changed after visiting \(section)")
        }
        snapshot("recall-restored-divider")
    }

    func testMeetingReviewConnectsSpeakersOwnersEvidenceAndRefresh() throws {
        try launch(["LOKALBOT_INITIAL_SECTION": "meetings", "LOKALBOT_SELECT_INDEX": "0",
                    "LOKALBOT_DETAIL_TAB": "review"])
        let speaker = app.buttons["meeting.review.speaker.them"]
        XCTAssertTrue(speaker.waitForExistence(timeout: 5))
        let listen = app.buttons["meeting.review.listen.them"]
        XCTAssertTrue(UITestHarness.waitUntil { listen.isEnabled })
        listen.click()
        let transport = element("meeting.audioPlayer")
        XCTAssertTrue(transport.buttons["Pause"].waitForExistence(timeout: 3))
        XCTAssertTrue(UITestHarness.waitUntil(timeout: 15) { transport.buttons["Play"].exists },
                      "A review excerpt must stop instead of continuing through the meeting")
        speaker.click()
        let candidate = element("speaker.rename.calendarCandidate.0")
        XCTAssertTrue(candidate.waitForExistence(timeout: 3))
        candidate.click()
        element("speaker.rename.save").click()
        XCTAssertTrue(UITestHarness.waitUntil { speaker.label.contains("Ana Petrović") })
        XCTAssertTrue(element("meeting.review").exists, "Naming a speaker must return to the review")

        let owner = app.buttons["meeting.action.owner.fixture-action-design-2"]
        let reviewContent = app.scrollViews["meeting.content.scroll"]
        UITestHarness.scrollTo(owner, in: app, within: reviewContent)
        XCTAssertTrue(owner.isHittable)
        owner.click()
        let field = app.textFields["meeting.action.correction.owner"]
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.click(); field.typeKey("a", modifierFlags: .command); field.typeText("Ana Petrović")
        app.buttons["meeting.action.correction.save"].click()
        XCTAssertTrue(UITestHarness.waitUntil { owner.label.contains("Ana Petrović") })

        let evidence = app.buttons["Jump to evidence at 00:00:35"]
        UITestHarness.scrollTo(evidence, in: app, within: reviewContent)
        XCTAssertTrue(evidence.isHittable)
        evidence.click()
        XCTAssertTrue(app.staticTexts["transcript.segment.3.text"].waitForExistence(timeout: 5))
        app.buttons["meeting.review.return"].click()
        let refresh = app.buttons["meeting.review.refresh"]
        UITestHarness.scrollTo(refresh, in: app, within: reviewContent)
        XCTAssertTrue(refresh.isHittable)
        XCTAssertTrue(refresh.isEnabled)
        XCTAssertTrue(UITestHarness.staticText(containing: "Notes need a refresh", in: app).exists)
        XCTAssertTrue(UITestHarness.staticText(containing: "Refreshing processes the transcript on this Mac", in: app).exists)
        XCTAssertTrue(owner.label.contains("Ana Petrović"), "Evidence navigation must preserve the correction")
        snapshot("meeting-review-ready-to-refresh")
    }

    func testMeetingCorrectionKeepsReviewWithPageSearchOpenAndClearsReturnOrigin() throws {
        try launch(["LOKALBOT_INITIAL_SECTION": "meetings", "LOKALBOT_SELECT_INDEX": "0",
                    "LOKALBOT_DETAIL_TAB": "review"])
        XCTAssertTrue(element("meeting.review").waitForExistence(timeout: 5))
        app.typeKey("f", modifierFlags: .command)
        let search = app.textFields["meeting.search.field"]
        XCTAssertTrue(search.waitForExistence(timeout: 3))
        search.click(); search.typeText("failover")
        XCTAssertTrue(app.staticTexts["meeting.search.status"].waitForExistence(timeout: 3))
        UITestHarness.selectSegment("Review", pickerIdentifier: "meeting.contentTabs", in: app)
        let content = app.scrollViews["meeting.content.scroll"]
        let owner = app.buttons["meeting.action.owner.fixture-action-design-2"]
        UITestHarness.scrollTo(owner, in: app, within: content)
        owner.click()
        let field = app.textFields["meeting.action.correction.owner"]
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.click(); field.typeKey("a", modifierFlags: .command); field.typeText("Me")
        app.buttons["meeting.action.correction.save"].click()
        XCTAssertTrue(UITestHarness.waitUntil { owner.label.contains("Me") })
        XCTAssertTrue(element("meeting.review").exists, "Refreshing search matches must not navigate away from Review")

        let evidence = app.buttons["Jump to evidence at 00:00:35"]
        UITestHarness.scrollTo(evidence, in: app, within: content)
        evidence.click()
        XCTAssertTrue(app.buttons["meeting.review.return"].waitForExistence(timeout: 3))
        UITestHarness.selectSegment("Summary", pickerIdentifier: "meeting.contentTabs", in: app)
        UITestHarness.scrollTo(evidence, in: app, within: content)
        evidence.click()
        XCTAssertTrue(app.staticTexts["transcript.segment.3.text"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["meeting.review.return"].exists, "Overview evidence must not retain the old Review origin")
    }

    func testReviewAndSearchAccessibilityInBothAppearances() throws {
        for appearance in ["light", "dark"] {
            try launch(["LOKALBOT_INITIAL_SECTION": "meetings", "LOKALBOT_SELECT_INDEX": "0",
                        "LOKALBOT_DETAIL_TAB": "review", "LOKALBOT_CAPTURE_APPEARANCE": appearance])
            XCTAssertTrue(element("meeting.review.speakers").waitForExistence(timeout: 5))
            try auditWorkspaceAccessibility(includeContrast: true)
            let owner = app.buttons["meeting.action.owner.fixture-action-design-1"]
            UITestHarness.scrollTo(owner, in: app, within: app.scrollViews["meeting.content.scroll"])
            XCTAssertTrue(owner.isHittable)
            XCTAssertTrue(owner.label.hasPrefix("Correct owner:"))
            XCTAssertEqual(app.buttons["meeting.action.toggle.fixture-action-design-1"].label, "Mark action done")
            try auditWorkspaceAccessibility(includeContrast: true)
            snapshot("meeting-review-owners-\(appearance)")
            let refresh = app.buttons["meeting.review.refresh"]
            UITestHarness.scrollTo(refresh, in: app, within: app.scrollViews["meeting.content.scroll"])
            XCTAssertTrue(refresh.isHittable)
            try auditWorkspaceAccessibility(includeContrast: true)
            UITestHarness.clickSidebar("sidebar.ask", in: app)
            XCTAssertTrue(element("chat.empty").waitForExistence(timeout: 5))
            try auditWorkspaceAccessibility(includeContrast: true)
            XCTAssertTrue(app.textFields["search.field"].waitForExistence(timeout: 5))
            try auditWorkspaceAccessibility(includeContrast: true)
            element("ask.sources").click()
            XCTAssertTrue(app.menuItems["Screen"].waitForExistence(timeout: 3))
            try auditWorkspaceAccessibility()
            app.typeKey(.escape, modifierFlags: [])
            app.textFields["search.field"].click()
            app.textFields["search.field"].typeText("failover")
            XCTAssertTrue(element("search.results").waitForExistence(timeout: 5))
            XCTAssertTrue(element("search.hit.\(fixture.designReview.id.uuidString).segment").waitForExistence(timeout: 5))
            try auditWorkspaceAccessibility(includeContrast: true)
            snapshot("recall-accessibility-\(appearance)")
        }
    }

    func testTimelineTitleHasInspectableEvidenceAndReturnsToSession() throws {
        try SyntheticFixture.plantActivityMoment(in: fixture)
        try launch(["LOKALBOT_INITIAL_SECTION": "timeline", "LOKALBOT_CAPTURE_SIZE": "1440x900"])
        let session = app.buttons["timeline.session.1"]
        XCTAssertTrue(session.waitForExistence(timeout: 5))
        XCTAssertTrue(session.label.contains("TimelineView.swift"))
        session.click()
        let titles = element("timeline.session.titleEvidence")
        XCTAssertTrue(titles.waitForExistence(timeout: 5))
        let disclosure = app.buttons["timeline.titleDisclosure.timelineview.swift"]
        XCTAssertTrue(disclosure.exists)
        UITestHarness.scrollTo(disclosure, in: app)
        disclosure.click()
        let source = app.buttons["timeline.titleSource.1"]
        XCTAssertTrue(source.waitForExistence(timeout: 3))
        source.click()
        XCTAssertTrue(element("timeline.activityPreview").waitForExistence(timeout: 5))
        XCTAssertTrue(UITestHarness.staticText(containing: "TimelineView.swift", in: app).exists)
        let moment = app.buttons["timeline.activityMoment.9001"]
        XCTAssertTrue(moment.waitForExistence(timeout: 3))
        moment.click()
        XCTAssertTrue(app.buttons["Back to activity"].waitForExistence(timeout: 3))
        app.buttons["Back to activity"].click()
        XCTAssertTrue(element("timeline.activityPreview").waitForExistence(timeout: 3))
        app.buttons["Back to work session"].click()
        XCTAssertTrue(element("timeline.sessionPreview").waitForExistence(timeout: 5))
        snapshot("timeline-inspectable-title-evidence")
    }

    func testTimelineReservesMostWidthForEvidence() throws {
        try SyntheticFixture.plantActivityMoment(in: fixture)
        try launch(["LOKALBOT_INITIAL_SECTION": "timeline", "LOKALBOT_CAPTURE_SIZE": "1440x900"])
        let rail = element("timeline.sessionRail")
        let evidence = element("timeline.evidencePane")
        XCTAssertTrue(rail.waitForExistence(timeout: 5))
        XCTAssertTrue(evidence.waitForExistence(timeout: 5))
        XCTAssertLessThanOrEqual(rail.frame.width, 361)
        XCTAssertGreaterThan(evidence.frame.width, rail.frame.width * 1.5)
        XCTAssertLessThanOrEqual(evidence.frame.maxX, rail.frame.minX,
                                 "Work sessions belong to the right of the day digest")
        app.buttons["timeline.session.1"].click()
        XCTAssertTrue(element("timeline.sessionPreview").waitForExistence(timeout: 5))
        XCTAssertGreaterThan(evidence.frame.width, rail.frame.width * 1.5)
        snapshot("timeline-reading-pane")
    }

    func testSettingsCategoryResetsScrollAndDictationHasDirectNavigation() throws {
        try launch(["LOKALBOT_INITIAL_SECTION": "settings", "LOKALBOT_INITIAL_SETTINGS_CATEGORY": "advanced"])
        let form = app.scrollViews["settings.form"]
        let cli = UITestHarness.staticText(containing: "Agent CLI", in: app)
        UITestHarness.scrollTo(cli, in: app, within: form, attempts: 16)
        UITestHarness.selectSettingsCategory("General", in: app)
        let launchToggle = UITestHarness.toggle("Launch LokalBot at login", in: app)
        XCTAssertTrue(UITestHarness.waitUntil { launchToggle.isHittable }, "A category opens at its own top")
        UITestHarness.selectSettingsCategory("Writing", in: app)
        let dictation = app.segmentedControls["settings.writing.sections"].buttons["Dictation"]
        XCTAssertTrue(dictation.waitForExistence(timeout: 5))
        XCTAssertTrue(dictation.isHittable)
        dictation.click()
        let toggle = UITestHarness.toggle("Enable dictation shortcut", in: app)
        XCTAssertTrue(UITestHarness.waitUntil { toggle.isHittable })
        snapshot("writing-direct-dictation")
        UITestHarness.selectSettingsCategory("Advanced", in: app)
        let cpu = element("settings.resourceMonitor.cpu")
        UITestHarness.scrollTo(cpu, in: app, within: form, attempts: 16)
        let cells = [cpu, element("settings.resourceMonitor.memory"), element("settings.resourceMonitor.models"),
                     element("settings.resourceMonitor.modelMemory")]
        for (index, cell) in cells.enumerated() {
            XCTAssertTrue(cell.exists)
            for other in cells.dropFirst(index + 1) {
                XCTAssertFalse(cell.frame.intersects(other.frame), "Resource values must not overlap")
            }
        }
        snapshot("settings-wrapping-resources")
    }

    func testMeetingMenusHaveAccessibleActionsAndOpen() throws {
        try launch(["LOKALBOT_INITIAL_SECTION": "meetings", "LOKALBOT_SELECT_INDEX": "0",
                    "LOKALBOT_DETAIL_TAB": "review"])
        XCTAssertTrue(element("meeting.export").waitForExistence(timeout: 5))
        // XCTest audits the exposed actions through its authorized automation
        // service; menu interaction below separately verifies the callbacks.
        // This is not a manual VoiceOver listening test.
        try auditWorkspaceAccessibility()
        for (identifier, item) in [("meeting.export", "Copy Meeting as Markdown"),
                                   ("toolbar.meetingActions", "Transcribe only"),
                                   ("meeting.playbackSpeed", "Reset to 1x")] {
            let control = element(identifier)
            XCTAssertTrue(control.waitForExistence(timeout: 5))
            control.click()
            XCTAssertTrue(app.menuItems[item].waitForExistence(timeout: 3))
            app.typeKey(.escape, modifierFlags: [])
        }
        let speed = element("meeting.playbackSpeed")
        speed.click()
        app.menuItems["1.5x"].click()
        XCTAssertTrue(UITestHarness.waitUntil { speed.value as? String == "1.5x" })
    }

    func testAutocompleteAcceptsPhysicalTabAndEscapeDismissesGhost() throws {
        try launch(["LOKALBOT_COTYPING_DEMO": "1"])
        UITestHarness.clickSidebar("sidebar.settings", in: app)
        UITestHarness.selectSettingsCategory("Writing", in: app)
        let editor = app.textViews["autocomplete.rehearsal.editor"]
        UITestHarness.scrollTo(editor, in: app)
        editor.click()
        let original = editor.value as? String
        XCTAssertTrue(UITestHarness.waitUntil { self.app.buttons["Insert suggestion"].isEnabled })
        editor.typeKey(.tab, modifierFlags: [])
        XCTAssertTrue(UITestHarness.waitUntil { editor.value as? String != original })
        editor.typeText(" Next")
        XCTAssertTrue(UITestHarness.waitUntil { self.app.buttons["Insert suggestion"].isEnabled })
        editor.typeKey(.escape, modifierFlags: [])
        XCTAssertFalse(app.buttons["Insert suggestion"].isEnabled)
        let textBeforeNavigation = editor.value as? String
        XCTAssertNotNil(textBeforeNavigation)
        app.typeKey(.tab, modifierFlags: [])
        XCTAssertEqual(editor.value as? String, textBeforeNavigation, "Tab without a suggestion should navigate, not insert a tab")
        app.typeKey(.tab, modifierFlags: .shift)
        XCTAssertEqual(editor.value as? String, textBeforeNavigation, "Shift-Tab should preserve the rehearsal text")
        snapshot("autocomplete-keyboard-rehearsal")
    }

    func testHighContrastKeepsActionsAccessible() throws {
        try launch(["LOKALBOT_CAPTURE_APPEARANCE": "contrast-dark"])
        XCTAssertTrue(app.buttons["toolbar.record"].waitForExistence(timeout: 5))
        app.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(element("settings.categories").waitForExistence(timeout: 5))
        app.textFields["settings.search"].click()
        app.textFields["settings.search"].typeText("retention")
        XCTAssertTrue(element("settings.searchResults").waitForExistence(timeout: 5))
        XCTAssertTrue(UITestHarness.staticText(containing: "Results across all categories", in: app).exists)
        try auditWorkspaceAccessibility()
        snapshot("settings-high-contrast")
    }

    func testReducedMotionWorkspaceRemainsOperable() throws {
        guard UserDefaults(suiteName: "org.localhost.lokalbot.redesign-ci")?.bool(forKey: "requiresReducedMotion") == true else {
            throw XCTSkip("Runs in the dedicated hosted Reduce Motion step")
        }
        XCTAssertTrue(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
                      "The hosted runner must actually enable Reduce Motion")
        try launch(["LOKALBOT_CAPTURE_APPEARANCE": "contrast-dark", "LOKALBOT_SCREEN_MEMORY_DEMO": "1"])
        UITestHarness.clickSidebar("sidebar.timeline", in: app)
        XCTAssertTrue(element("timeline.workSessions").waitForExistence(timeout: 5))
        UITestHarness.clickSidebar("sidebar.meetings", in: app)
        for meeting in [fixture.designReview, fixture.standup] {
            element("meeting.row.\(meeting.id.uuidString)").click()
            XCTAssertTrue(UITestHarness.waitUntil {
                let title = self.element("detail.title")
                return title.exists && (title.value as? String ?? title.label) == meeting.title
            })
            XCTAssertTrue(element("meeting.contentTabs").isHittable)
        }
        UITestHarness.clickSidebar("sidebar.ask", in: app)
        app.textFields["search.field"].click()
        app.textFields["search.field"].typeText("failover")
        XCTAssertTrue(element("search.hit.\(fixture.designReview.id.uuidString).segment").waitForExistence(timeout: 6))
        try auditWorkspaceAccessibility()
        snapshot("search-reduced-motion")
    }

    func testRetentionReviewCancelPreservesPolicy() throws {
        try launch(["LOKALBOT_SCREEN_MEMORY_DEMO": "1"])
        UITestHarness.clickSidebar("sidebar.settings", in: app)
        UITestHarness.selectSettingsCategory("Privacy & Data", in: app)
        let before = UserDefaults(suiteName: suite!)?.data(forKey: "lokalbotv3.settings")
        let review = app.buttons["Review expired context…"]
        UITestHarness.scrollTo(review, in: app)
        review.click()
        XCTAssertTrue(app.buttons["retention.confirm"].waitForExistence(timeout: 5))
        snapshot("retention-review-before-cancel")
        app.buttons["Cancel"].click()
        XCTAssertTrue(UITestHarness.waitUntil { !self.app.buttons["retention.confirm"].exists },
                      "Cancel should close retention review without applying its policy")
        XCTAssertEqual(UserDefaults(suiteName: suite!)?.data(forKey: "lokalbotv3.settings"), before)
    }

    func testFourHundredActionsStaySearchableAndCompletionCanBeUndone() throws {
        let folder = fixture.folder(for: fixture.designReview)
        let actions: [[String: Any]] = (0..<400).map { index in
            ["id": "large-action-\(index)", "schemaVersion": 2, "text": "Synthetic commitment \(index)",
             "owner": "Me", "isForUser": true, "due": "Friday", "citations": []]
        }
        let data = try JSONSerialization.data(withJSONObject: ["schemaVersion": 2, "actionItems": actions])
        try data.write(to: folder.appendingPathComponent("outcomes.json"))
        try launch()
        app.buttons["outcomes.review"].click()
        let search = app.textFields["actions.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.click(); search.typeText("Synthetic commitment 399")
        // Failure messages repeat the action title; inspect only its list row.
        let action = element("actions.list").staticTexts.matching(
            NSPredicate(format: "label == %@ OR value == %@",
                        "Synthetic commitment 399", "Synthetic commitment 399")).firstMatch
        XCTAssertTrue(action.waitForExistence(timeout: 5))
        action.click()
        search.click(); search.typeKey("a", modifierFlags: .command)
        search.typeText("Synthetic commitment 398")
        XCTAssertTrue(element("actions.selection.hidden").waitForExistence(timeout: 5),
                      "Filtering should preserve the selected action while excluding it from the batch")
        XCTAssertFalse(element("actions.batch").isEnabled)
        search.click(); search.typeKey("a", modifierFlags: .command)
        search.typeText("Synthetic commitment 399")
        XCTAssertTrue(action.waitForExistence(timeout: 5))
        XCTAssertTrue(element("actions.batch").isEnabled, "Returning to the action should restore its selection")
        XCTAssertFalse(element("actions.selection.hidden").exists)
        let complete = app.buttons["outcome.action.toggle.\(fixture.designReview.id.uuidString):large-action-399"]
        XCTAssertTrue(complete.waitForExistence(timeout: 4))
        complete.click()
        XCTAssertTrue(UITestHarness.waitUntil { !action.exists })
        app.buttons["outcomes.undo"].click()
        XCTAssertTrue(action.waitForExistence(timeout: 5))
        snapshot("four-hundred-actions-search-and-undo")
        let stateFile = folder.appendingPathComponent("outcome-state.json")
        try withBlockedStateFile(stateFile) {
            complete.click()
            XCTAssertTrue(UITestHarness.staticText(containing: "Could not update this action", in: app)
                .waitForExistence(timeout: 4))
            XCTAssertTrue(action.exists, "A failed save must preserve the open action")
        }
        complete.click()
        XCTAssertTrue(UITestHarness.waitUntil { !action.exists })
        XCTAssertFalse(UITestHarness.staticText(containing: "Could not update this action", in: app).exists,
                       "A successful retry should clear the previous save error")
        try withBlockedStateFile(stateFile) {
            app.buttons["outcomes.undo"].click()
            let undoFailure = UITestHarness.staticText(containing: "Could not undo", in: app)
            XCTAssertTrue(undoFailure.waitForExistence(timeout: 4))
            XCTAssertTrue(app.buttons["outcomes.undo"].exists, "Failed Undo must remain retryable")
            XCTAssertFalse(action.exists, "A failed Undo must not pretend the state was restored")
            XCTAssertLessThanOrEqual(undoFailure.frame.maxY, app.buttons["outcomes.undo"].frame.minY,
                                     "The error must remain above the retry action without covering it")
            snapshot("action-undo-write-failure")
        }
        app.buttons["outcomes.undo"].click()
        XCTAssertTrue(action.waitForExistence(timeout: 5), "Retry should restore the action after storage recovers")
        XCTAssertFalse(UITestHarness.staticText(containing: "Could not undo", in: app).exists,
                       "A successful Undo should clear its previous error")
    }

    func testAgentApprovalDescribesEffectAndDenialAndStopReachTheController() throws {
        try launch(["LOKALBOT_AGENT_UI_TEST_READY": "1", "LOKALBOT_AGENT_UI_TEST_APPROVAL": "1"])
        UITestHarness.clickSidebar("sidebar.agent", in: app)
        let composer = app.textFields["agent.composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 6))
        composer.click(); composer.typeText("Draft a meeting follow-up")
        app.buttons["agent.send"].click()
        let assistant = app.descendants(matching: .any)["agent.assistant"]
        XCTAssertTrue(assistant.waitForExistence(timeout: 6),
                      "Agent assistant response did not render")
        let rendered = assistant.value as? String ?? ""
        XCTAssertTrue(rendered.contains("Agent result"), "Agent Markdown heading was not rendered")
        XCTAssertTrue(rendered.contains("• Parent"), "Agent Markdown list was not rendered")
        XCTAssertTrue(rendered.contains("let value = 1"), "Agent fenced code was not rendered")
        XCTAssertTrue(rendered.contains("Agent │ Ready"), "Agent Markdown table was not rendered")
        XCTAssertFalse(rendered.contains("## Agent result"), "Markdown heading syntax leaked into the answer")
        XCTAssertFalse(rendered.contains("| --- | --- |"), "Markdown table syntax leaked into the answer")
        let deny = app.buttons["agent.approve.deny"]
        XCTAssertTrue(deny.waitForExistence(timeout: 6))
        XCTAssertTrue(UITestHarness.staticText(containing: "Create or replace the file", in: app).exists)
        XCTAssertTrue(UITestHarness.staticText(containing: "reviewed-note.md", in: app).exists)
        snapshot("agent-write-approval")
        deny.click()
        XCTAssertTrue(UITestHarness.staticText(containing: "You denied this write request", in: app)
            .waitForExistence(timeout: 4))
        XCTAssertFalse(deny.exists)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("reviewed-note.md").path))
        app.buttons["agent.stop"].click()
        XCTAssertTrue(UITestHarness.waitUntil { !self.app.buttons["agent.stop"].exists })
        let lines = try String(contentsOf: fixture.root.appendingPathComponent("agent-ui-rpc.jsonl"), encoding: .utf8)
        let commands = try lines.split(separator: "\n").map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
        XCTAssertTrue(commands.contains { $0["type"] as? String == "extension_ui_response" && $0["confirmed"] as? Bool == false })
        XCTAssertEqual(commands.last?["type"] as? String, "abort")
        snapshot("agent-denied-and-stopped")
    }

    private func launch(_ environment: [String: String] = [:], blockedInference: Bool = false) throws {
        app?.terminate()
        UITestHarness.cleanUp(defaultsSuiteName: suite)
        let run: UITestHarness.Launch
        if blockedInference {
            // Deliberately invalid destination: exercise submission and saved
            // scope without downloading a model or contacting a server.
            run = try UITestHarness.launch(storageRoot: fixture.root, suitePrefix: "Redesign",
                settingsJSON: #"{"menuBarOnly":false,"calendarDetectionEnabled":false,"semanticSearchEnabled":false,"cotypingEnabled":false,"summarizerBackend":"OpenAI-compatible server","openAIBaseURL":"invalid"}"#,
                environment: environment)
        } else {
            run = try UITestHarness.launch(storageRoot: fixture.root, suitePrefix: "Redesign", environment: environment)
        }
        app = run.app; suite = run.defaultsSuiteName
    }
    private func withBlockedStateFile(_ file: URL, perform body: () throws -> Void) throws {
        let contents = try Data(contentsOf: file)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: file)
            try? contents.write(to: file, options: .atomic)
        }
        try body()
    }

    private func element(_ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }
    private func auditWorkspaceAccessibility(includeContrast: Bool = false, contrastBounds: CGRect? = nil) throws {
        // Report every app issue. The hosted virtual Mac also exposes a
        // system-generated Touch Bar and its Emoji picker outside our window;
        // neither is an app-owned control or a usable hosted input surface.
        continueAfterFailure = true
        defer { continueAfterFailure = false }
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "workspace-accessibility-hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
        var types: XCUIAccessibilityAuditType = [.sufficientElementDescription, .action]
        if includeContrast { types.insert(.contrast) }
        let verifiedText = includeContrast && contrastBounds == nil ? try verifyRecallExplanationContrast() : []
        try app.performAccessibilityAudit(for: types) { issue in
            guard let affected = issue.element, affected.exists else { return false }
            if issue.auditType == .contrast {
                // The macOS audit also samples offscreen text and content
                // behind popovers. Audit only painted, unclipped text here;
                // each scroll region and open popover is audited separately.
                let bounds = contrastBounds ?? self.app.windows.firstMatch.frame
                if !bounds.insetBy(dx: -1, dy: -1).contains(affected.frame) { return true }
                let content = self.app.scrollViews["meeting.content.scroll"]
                if content.exists,
                   content.descendants(matching: affected.elementType).matching(NSPredicate(
                    format: "identifier == %@ AND label == %@", affected.identifier, affected.label)).count > 0,
                   !content.frame.insetBy(dx: -1, dy: -1).contains(affected.frame) { return true }
                // macOS 15's audit flags these labels even at measured 14:1
                // contrast. Suppress only after checking their rendered pixels
                // in this appearance; a faint or empty label still fails.
                if verifiedText.contains(affected.label)
                    || (affected.value as? String).map(verifiedText.contains) == true { return true }
            }
            if affected.elementType == .touchBar { return true }
            let systemBar = self.app.descendants(matching: .touchBar).firstMatch
            guard affected.elementType == .popUpButton, affected.label == "emoji & symbols",
                  systemBar.exists else { return false }
            let systemPicker = systemBar.descendants(matching: .popUpButton)
                .matching(NSPredicate(format: "label == %@", "emoji & symbols")).firstMatch
            return systemPicker.exists && systemPicker.frame == affected.frame
        }
    }

    private func verifyRecallExplanationContrast() throws -> Set<String> {
        let labels = [
            "Type to find meetings and screen moments. Press Return to open a result, or ⌘Return to ask about what you found.",
        ]
        var verified = Set<String>()
        for label in labels {
            let text = app.staticTexts.matching(NSPredicate(format: "label == %@ OR value == %@", label, label)).firstMatch
            guard text.exists, app.windows.firstMatch.frame.contains(text.frame) else { continue }
            let screenshot = text.screenshot()
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: screenshot.pngRepresentation))
            let ratio = try renderedTextContrast(bitmap)
            let evidence = XCTAttachment(screenshot: screenshot)
            evidence.name = "recall-explanation-contrast-\(String(format: "%.2f", ratio))"
            evidence.lifetime = .keepAlways
            add(evidence)
            XCTAssertGreaterThanOrEqual(ratio, 4.5, "Rendered explanation must meet 4.5:1: \(label)")
            if ratio >= 4.5 { verified.insert(label) }
        }
        return verified
    }

    /// Only for the plain, single-color text labels above. The dominant color
    /// is the background; the most repeated remaining color is the glyph fill.
    /// Minimum sample counts reject blank captures and isolated dark pixels.
    private func renderedTextContrast(_ bitmap: NSBitmapImageRep) throws -> Double {
        let pixels = bitmap.pixelsWide * bitmap.pixelsHigh
        let bytes = UnsafeMutablePointer<UInt8>.allocate(capacity: pixels * 4)
        bytes.initialize(repeating: 0, count: pixels * 4)
        defer { bytes.deallocate() }
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(
            data: bytes, width: bitmap.pixelsWide, height: bitmap.pixelsHigh,
            bitsPerComponent: 8, bytesPerRow: bitmap.pixelsWide * 4, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.draw(try XCTUnwrap(bitmap.cgImage),
                     in: CGRect(x: 0, y: 0, width: bitmap.pixelsWide, height: bitmap.pixelsHigh))
        var counts: [Int: Int] = [:]
        for offset in stride(from: 0, to: pixels * 4, by: 4) {
            let rgb = (Int(bytes[offset]) << 16) | (Int(bytes[offset + 1]) << 8) | Int(bytes[offset + 2])
            counts[rgb, default: 0] += 1
        }
        let background = try XCTUnwrap(counts.max { $0.value < $1.value })
        let foreground = try XCTUnwrap(counts.filter { $0.key != background.key }.max { $0.value < $1.value })
        XCTAssertGreaterThan(background.value, pixels / 2, "Expected a uniform label background")
        XCTAssertGreaterThanOrEqual(foreground.value, max(20, pixels / 100), "Expected a supported glyph fill")
        func linear(_ byte: Int) -> Double {
            let value = Double(byte) / 255.0
            if value <= 0.04045 { return value / 12.92 }
            return pow((value + 0.055) / 1.055, 2.4)
        }
        func luminance(_ rgb: Int) -> Double {
            let red = linear((rgb >> 16) & 255)
            let green = linear((rgb >> 8) & 255)
            let blue = linear(rgb & 255)
            return red * 0.2126 + green * 0.7152 + blue * 0.0722
        }
        let first = luminance(background.key), second = luminance(foreground.key)
        return (max(first, second) + 0.05) / (min(first, second) + 0.05)
    }

    private func snapshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
