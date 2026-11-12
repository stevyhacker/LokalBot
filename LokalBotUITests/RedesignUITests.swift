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

    func testSavedAudioRecoveryIsReviewableAndCaptureWarningSurvivesProcessing() throws {
        let folder = fixture.folder(for: fixture.designReview)
        let metaURL = folder.appendingPathComponent("meta.json")
        var meta = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: metaURL)) as? [String: Any])
        meta["recordedDuration"] = 120
        meta["contentRange"] = ["start": 0, "end": 60]
        try JSONSerialization.data(withJSONObject: meta).write(to: metaURL, options: .atomic)
        let report: [String: Any] = ["version": 1, "events": [], "microphoneDroppedBuffers": 0,
            "systemDroppedBuffers": 0, "attachmentAttempts": 10, "hadMissingAudio": true]
        try JSONSerialization.data(withJSONObject: report).write(to: folder.appendingPathComponent("recording-health.json"))
        try launch(["LOKALBOT_INITIAL_SECTION": "meetings", "LOKALBOT_SELECT_INDEX": "0"])
        XCTAssertTrue(element("meeting.captureWarning").waitForExistence(timeout: 8))
        let review = app.buttons["meeting.reviewSavedAudio"]
        XCTAssertTrue(review.waitForExistence(timeout: 5))
        review.click()
        XCTAssertTrue(app.buttons["Use full recording"].waitForExistence(timeout: 3))
        app.buttons["Use full recording"].click()
        app.buttons["Cancel"].click()
        let unchanged = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: metaURL)) as? [String: Any])
        XCTAssertEqual((unchanged["contentRange"] as? [String: Double])?["end"], 60,
                       "Review and cancellation cannot expand a legacy or user-reviewed range")
        XCTAssertTrue(element("meeting.captureWarning").exists)
        snapshot("saved-audio-review-and-capture-warning")
    }

    /// Filmed on 2026-11-05: opening Projects showed the first project with no
    /// row highlighted, and selecting a row widened the list column to its maximum.
    /// Also covers a project nothing names yet: one message and the names sheet.
    func testProjectsHighlightsTheOpenProjectAndSelectionKeepsTheColumnWidth() throws {
        let projects = fixture.root.appendingPathComponent("projects", isDirectory: true)
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        let tracked: [String: Any] = ["version": 1, "hiddenNames": [String](), "tracked": ["Atlas", "Borealis"].map { name in
            ["id": UUID().uuidString, "name": name, "otherNames": [String](), "createdAt": "2026-11-01T09:00:00Z"] as [String: Any]
        }]
        try JSONSerialization.data(withJSONObject: tracked).write(to: projects.appendingPathComponent("tracked.json"))
        try launch(["LOKALBOT_INITIAL_SECTION": "projects", "LOKALBOT_CAPTURE_SIZE": "1440x900"])

        let list = app.outlines["projects.list"]
        XCTAssertTrue(list.waitForExistence(timeout: 8))
        let selected = list.outlineRows.matching(NSPredicate(format: "selected == true"))
        XCTAssertTrue(UITestHarness.waitUntil { selected.count == 1 },
                      "The project the page opens on must be selected in the list; selected rows: \(selected.count)")
        let width = list.frame.width
        let unselected = list.outlineRows
            .matching(NSPredicate(format: "selected == false"))
            .containing(NSPredicate(format: "value BEGINSWITH 'Atlas' OR value BEGINSWITH 'Borealis'")).firstMatch
        XCTAssertTrue(unselected.waitForExistence(timeout: 5))
        // Named once: the query above stops matching a row as soon as it's selected.
        let otherName = (unselected.staticTexts.firstMatch.value as? String ?? "").hasPrefix("Atlas") ? "Atlas" : "Borealis"
        let other = list.outlineRows.containing(NSPredicate(format: "value BEGINSWITH %@", otherName)).firstMatch
        other.click()
        XCTAssertTrue(UITestHarness.waitUntil { other.isSelected && selected.count == 1 },
                      "Clicking \(otherName) must select it and only it")
        // A re-division lands on the next layout pass, so give it one.
        usleep(800_000)
        XCTAssertEqual(list.frame.width, width, accuracy: 2, "Selecting a project must not move the divider")
        snapshot("projects-selection")

        // The list is headed by its search field. Nothing in the library names
        // these two projects, so the page is one message whose button opens
        // the names sheet on "Other names".
        XCTAssertTrue(element("projects.search").exists, "The list column starts with the search field")
        let addNames = element("project.addOtherNames")
        XCTAssertTrue(addNames.waitForExistence(timeout: 5),
                      "A project nothing names yet offers to add other names")
        XCTAssertFalse(element("project.summary").exists, "There is no note to write for a project nothing names")
        addNames.click()
        XCTAssertTrue(element("project.otherNames").waitForExistence(timeout: 5), "The names sheet opens")
        XCTAssertTrue(element("project.name").exists)
        app.buttons["Cancel"].click()
        XCTAssertTrue(UITestHarness.waitUntil { !self.element("project.otherNames").exists })
        XCTAssertTrue(UITestHarness.waitUntil { selected.count == 1 }, "Cancelling leaves the selection alone")
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
            ("settings", ["LOKALBOT_INITIAL_SECTION": "settings", "LOKALBOT_INITIAL_SETTINGS_CATEGORY": "overview"]),
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
            // The Review tab is gone; this route shows the sheet that names speakers.
            "review": "meeting.namingSheet",
            "timeline": "timeline.workSessions", "search": "search.hit.\(fixture.designReview.id.uuidString).segment",
            "ask": "ask.submit", "settings": "settings.overview", "models": "models.overview",
            // Autocomplete opens on its settings; the rehearsal is its "Try it…" sheet.
            "dictation": "dictation.form", "autocomplete": "settings.header.writing", "agent": "agent.composer",
        ]
        let identifier = try XCTUnwrap(anchors[route], "No capture anchor for \(route)")
        XCTAssertTrue(element(identifier).waitForExistence(timeout: 10), "Capture content not ready: \(route)")
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
        // ↓ moves from the field onto the first match; Return then opens it.
        input.typeKey(.downArrow, modifierFlags: [])
        input.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(app.staticTexts["transcript.segment.3.text"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["chat.message.user"].exists)
        XCTAssertTrue(app.buttons["Play"].exists, "Evidence should be paused until Play is chosen")
        app.buttons["Back"].firstMatch.click()
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        XCTAssertEqual(input.value as? String, "failover")
        XCTAssertTrue(UITestHarness.waitUntil { self.app.buttons["ask.submit"].isEnabled })
        // In the field, Return asks, even for a single word. A keyword's
        // answer is limited to the matches that were listed, and the sources
        // menu names them. (A full question would read the chosen sources.)
        input.click()
        input.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(app.staticTexts["chat.message.user"].waitForExistence(timeout: 5))
        XCTAssertEqual(input.value as? String, "")
        XCTAssertTrue(UITestHarness.waitUntil {
            (self.element("ask.sources").value as? String) == self.fixture.designReview.title
        })
        XCTAssertFalse(element("ask.selectedEvidence").exists)
        // The model connection is blocked here: the answer fails with the way
        // to fix it, and the matches stay listed under it.
        XCTAssertTrue(element("chat.answer.status").waitForExistence(timeout: 10))
        XCTAssertTrue(element("chat.answer.modelSettings").exists)
        XCTAssertTrue(element("ask.inferenceStatus").exists, "A blocked model connection is named under the field")
        XCTAssertTrue(element("search.hit.\(fixture.designReview.id.uuidString).segment").waitForExistence(timeout: 6),
                      "A failed answer keeps its matches")
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
        // Dates are chosen, shown and removed in the time menu alone.
        date.click()
        XCTAssertTrue(app.menuItems["Last 7 days"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.menuItems["Choose a date…"].exists)
        app.menuItems["Last 7 days"].click()
        XCTAssertTrue(UITestHarness.waitUntil { (date.value as? String) == "Last 7 days" })
        XCTAssertFalse(element("ask.filter.date.clear").exists)
        // Finer filters live in the sources menu, which then names them.
        let sources = element("ask.sources")
        sources.click()
        XCTAssertTrue(app.menuItems["Match type"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.menuItems["Source permissions…"].exists)
        XCTAssertFalse(app.menuItems["Screen dates"].exists)
        app.menuItems["Match type"].hover()
        XCTAssertTrue(app.menuItems["Summaries"].waitForExistence(timeout: 3))
        app.menuItems["Summaries"].click()
        XCTAssertTrue(UITestHarness.waitUntil { (sources.value as? String) == "All sources · Summaries" })
        XCTAssertFalse(element("ask.filter.resultType").exists, "Filters are not repeated as chips")
        XCTAssertFalse(element("ask.activeFilters").exists)
        snapshot("ask-unified-date-filters")
        sources.click()
        XCTAssertTrue(app.menuItems["Match type"].waitForExistence(timeout: 3))
        app.menuItems["Match type"].hover()
        XCTAssertTrue(app.menuItems["Transcripts"].waitForExistence(timeout: 3))
        app.menuItems["All"].firstMatch.click()
        XCTAssertTrue(UITestHarness.waitUntil { (sources.value as? String) == "All sources" })
        date.click()
        XCTAssertTrue(app.menuItems["Any time"].waitForExistence(timeout: 3))
        app.menuItems["Any time"].click()
        XCTAssertTrue(UITestHarness.waitUntil { (date.value as? String) == "Any time" })
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
        // The follow-up is limited to the meeting that matched: the sources
        // menu's button names it, and the menu offers to widen it again.
        XCTAssertTrue(UITestHarness.waitUntil {
            (sources.value as? String) == self.fixture.designReview.title
        })
        XCTAssertFalse(element("ask.selectedEvidence").exists)
        sources.click()
        XCTAssertTrue(app.menuItems["Only \(fixture.designReview.title)"].waitForExistence(timeout: 3))
        app.menuItems["All sources"].click()
        XCTAssertTrue(UITestHarness.waitUntil { sources.value as? String == originalSources })
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

    /// The removed Review tab's three jobs, in place: one sheet names the
    /// unnamed voices, an action's owner is a menu on its row, and a refresh
    /// of the summary is offered only once speaker names have changed. A ▶
    /// time plays where it is, and the player leads to the transcript.
    /// The test keeps its name so its measured duration still plans the shards.
    func testMeetingReviewConnectsSpeakersOwnersEvidenceAndRefresh() throws {
        try launch(["LOKALBOT_INITIAL_SECTION": "meetings", "LOKALBOT_SELECT_INDEX": "0"])
        let nameSpeakers = app.buttons["meeting.reviewSpeakers"]
        XCTAssertTrue(nameSpeakers.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["meeting.review.refresh"].exists,
                       "A summary refresh is offered only after speaker names change")
        let transport = element("meeting.audioPlayer")
        XCTAssertTrue(transport.waitForExistence(timeout: 5))
        nameSpeakers.click()
        XCTAssertTrue(element("meeting.namingSheet").waitForExistence(timeout: 3))
        let listen = app.buttons["meeting.naming.play.them"]
        XCTAssertTrue(UITestHarness.waitUntil { listen.isEnabled })
        listen.click()
        XCTAssertTrue(transport.buttons["Pause"].waitForExistence(timeout: 3))
        XCTAssertTrue(UITestHarness.waitUntil(timeout: 15) { transport.buttons["Play"].exists },
                      "A voice sample must stop instead of continuing through the meeting")
        let save = app.buttons["meeting.naming.save"]
        XCTAssertFalse(save.isEnabled, "Nothing is saved until a name is picked")
        let guest = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label == %@", "meeting.naming.choice.them.", "Ana Petrović")).firstMatch
        XCTAssertTrue(guest.waitForExistence(timeout: 3), "Invited people are offered as names")
        guest.click()
        XCTAssertTrue(save.isEnabled)
        save.click()
        XCTAssertTrue(UITestHarness.waitUntil { !self.element("meeting.namingSheet").exists })
        XCTAssertTrue(UITestHarness.waitUntil { self.app.buttons["meeting.speaker.them"].label.contains("Ana Petrović") })
        XCTAssertFalse(nameSpeakers.exists, "With every voice named, the header stops asking")

        let content = app.scrollViews["meeting.content.scroll"]
        let owner = element("meeting.action.owner.fixture-action-design-2")
        UITestHarness.scrollTo(owner, in: app, within: content)
        XCTAssertTrue(owner.isHittable)
        owner.click()
        let choice = app.menuItems["Ana Petrović"].firstMatch
        XCTAssertTrue(choice.waitForExistence(timeout: 3), "This meeting's speakers are owner choices")
        choice.click()
        XCTAssertTrue(UITestHarness.waitUntil { owner.label.contains("Ana Petrović") })

        let play = app.buttons["meeting.action.play.fixture-action-design-2"]
        UITestHarness.scrollTo(play, in: app, within: content)
        XCTAssertTrue(play.isHittable)
        play.click()
        XCTAssertTrue(transport.buttons["Pause"].waitForExistence(timeout: 3), "A cited time plays from there")
        XCTAssertTrue(owner.exists, "Playing a cited time must not leave the summary")
        XCTAssertFalse(app.staticTexts["transcript.segment.3.text"].exists)
        app.buttons["meeting.player.showInTranscript"].click()
        XCTAssertTrue(app.staticTexts["transcript.segment.3.text"].waitForExistence(timeout: 5))
        transport.buttons["Pause"].click()

        UITestHarness.selectSegment("Summary", pickerIdentifier: "meeting.contentTabs", in: app)
        let refresh = app.buttons["meeting.review.refresh"]
        XCTAssertTrue(refresh.waitForExistence(timeout: 5))
        XCTAssertTrue(refresh.isHittable)
        XCTAssertTrue(refresh.isEnabled)
        XCTAssertTrue(UITestHarness.staticText(
            containing: "Speaker names changed after this summary was written", in: app).exists)
        XCTAssertTrue(UITestHarness.staticText(containing: "Runs on this Mac", in: app).exists)
        XCTAssertTrue(app.staticTexts["meeting.action.text.fixture-action-design-2"].exists,
                      "The earlier summary stays on the page until it is refreshed")
        UITestHarness.scrollTo(owner, in: app, within: content)
        XCTAssertTrue(owner.label.contains("Ana Petrović"), "Leaving and returning must preserve the owner")
        snapshot("meeting-summary-ready-to-refresh")
    }

    func testTimelineOpensDetailsOnlyForASelection() throws {
        try SyntheticFixture.plantActivityMoment(in: fixture)
        try launch(["LOKALBOT_INITIAL_SECTION": "timeline", "LOKALBOT_CAPTURE_SIZE": "1000x700"])
        XCTAssertTrue(element("timeline.workSessions").waitForExistence(timeout: 5))
        XCTAssertFalse(app.textFields["timeline.search"].exists, "Retained moments search was removed")
        XCTAssertFalse(element("timeline.moments").exists, "Retained moments list was removed")
        XCTAssertFalse(element("timeline.fullDigest").exists, "The digest is always shown in full")
        // The list stays beside the page at the narrowest captured width, so
        // there is no drawer and nothing to toggle.
        XCTAssertFalse(app.buttons["timeline.context.toggle"].exists)
        // A session's page is known by its title: the page's wrapper is not
        // an accessibility element of its own.
        let page = element("timeline.sessionPreview")
        XCTAssertFalse(page.exists)
        XCTAssertTrue(element("capture.dayOverview").exists, "The digest page shows until a row is selected")
        openFirstTimelineSession()
        XCTAssertTrue(page.waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["Close context panel"].exists, "A row's page is not a drawer")
        let list = element("timeline.list")
        XCTAssertLessThanOrEqual(list.frame.maxX, element("timeline.evidencePane").frame.minX + 1,
                                 "The list stays beside the selected row's page")
        XCTAssertGreaterThan(page.frame.minX, list.frame.maxX, "The session's page is beside the list")
        XCTAssertFalse(element("capture.dayOverview").exists, "The session's page replaces the digest")
        // Day digest, the list's first row, returns to the digest.
        app.buttons["timeline.dayDigest.row"].click()
        XCTAssertTrue(UITestHarness.waitUntil { !page.exists })
        XCTAssertTrue(element("capture.dayOverview").waitForExistence(timeout: 3))
    }

    func testTranscriptSearchIsPersistentAndCommandFStillFindsAcrossMeeting() throws {
        try launch(["LOKALBOT_INITIAL_SECTION": "meetings", "LOKALBOT_SELECT_INDEX": "0"])
        UITestHarness.selectSegment("Transcript", pickerIdentifier: "meeting.contentTabs", in: app)
        let search = app.textFields["meeting.search.field"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        XCTAssertEqual(search.placeholderValue, "Find in transcript")
        // Find is the trailing control of the Transcript panel's header, so
        // it is part of the scrolling content, level with the panel's title.
        let content = app.scrollViews["meeting.content.scroll"]
        let panelTitle = element("meeting.transcript.title")
        XCTAssertTrue(panelTitle.exists, "The transcript is one panel with a titled header")
        XCTAssertTrue(content.frame.contains(search.frame), "Find in transcript belongs to the Transcript panel")
        XCTAssertGreaterThan(search.frame.minX, panelTitle.frame.maxX)
        XCTAssertEqual(search.frame.midY, panelTitle.frame.midY, accuracy: 10)
        search.click()
        search.typeText("failover")
        let status = app.staticTexts["meeting.search.status"]
        XCTAssertTrue(status.waitForExistence(timeout: 3))
        XCTAssertTrue((status.value as? String ?? status.label).contains("Transcript"))
        app.typeKey("f", modifierFlags: .command)
        XCTAssertTrue(UITestHarness.waitUntil { search.placeholderValue == "Search this meeting" })
        // Command-F searches every tab, so its one field is pinned above the
        // scrolling content and the panel's field makes way for it.
        XCTAssertEqual(app.textFields.matching(identifier: "meeting.search.field").count, 1)
        XCTAssertLessThanOrEqual(search.frame.maxY, content.frame.minY + 1,
                                 "Page find stays pinned under the player")
        app.buttons["meeting.search.close"].click()
        XCTAssertTrue(search.exists, "Closing page find must keep the transcript search field")
        XCTAssertTrue(UITestHarness.waitUntil { content.frame.contains(search.frame) },
                      "Find returns to the Transcript panel's header")
        XCTAssertFalse(status.exists, "Closing page find clears its query and matches")
    }

    /// An owner chosen from the row's menu keeps the reader on the summary
    /// while page search is open, and a cited time plays in place. (The name
    /// predates the removal of the Review tab; its timing plans the shards.)
    func testMeetingCorrectionKeepsReviewWithPageSearchOpenAndClearsReturnOrigin() throws {
        try launch(["LOKALBOT_INITIAL_SECTION": "meetings", "LOKALBOT_SELECT_INDEX": "0"])
        XCTAssertTrue(element("meeting.audioPlayer").waitForExistence(timeout: 5))
        app.typeKey("f", modifierFlags: .command)
        let search = app.textFields["meeting.search.field"]
        XCTAssertTrue(search.waitForExistence(timeout: 3))
        search.click(); search.typeText("failover")
        XCTAssertTrue(app.staticTexts["meeting.search.status"].waitForExistence(timeout: 3))
        let content = app.scrollViews["meeting.content.scroll"]
        let owner = element("meeting.action.owner.fixture-action-design-2")
        UITestHarness.scrollTo(owner, in: app, within: content)
        owner.click()
        let you = app.menuItems["You"].firstMatch
        XCTAssertTrue(you.waitForExistence(timeout: 3))
        you.click()
        XCTAssertTrue(UITestHarness.waitUntil { !owner.exists },
                      "An action given to You moves under For you, where no owner is shown")
        let text = app.staticTexts["meeting.action.text.fixture-action-design-2"]
        XCTAssertTrue(text.exists, "Refreshing search matches must not navigate away from Summary")

        // Wording, owner and due date stay editable together from the row's menu.
        let options = element("meeting.action.status.fixture-action-design-2")
        UITestHarness.scrollTo(options, in: app, within: content)
        options.click()
        app.menuItems["Correct owner or due date"].click()
        let field = app.textFields["meeting.action.correction.owner"]
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        XCTAssertEqual(field.value as? String, "Me", "The stored owner Me is shown as You")
        app.sheets.firstMatch.buttons["Cancel"].click()

        let play = app.buttons["meeting.action.play.fixture-action-design-2"]
        UITestHarness.scrollTo(play, in: app, within: content)
        play.click()
        XCTAssertTrue(element("meeting.audioPlayer").buttons["Pause"].waitForExistence(timeout: 3))
        XCTAssertTrue(text.exists, "A cited time plays in place")
        XCTAssertFalse(app.staticTexts["transcript.segment.3.text"].exists)
    }

    func testWorkspaceAccessibilityAuditDismissesHoverHelp() throws {
        try launch(["LOKALBOT_INITIAL_SECTION": "meetings", "LOKALBOT_SELECT_INDEX": "0",
                    "LOKALBOT_CAPTURE_APPEARANCE": "light"])
        let citation = app.buttons["meeting.action.play.fixture-action-design-1"]
        UITestHarness.scrollTo(citation, in: app, within: app.scrollViews["meeting.content.scroll"])
        XCTAssertTrue(citation.isHittable)
        citation.hover()
        let help = app.descendants(matching: .helpTag).firstMatch
        XCTAssertTrue(help.waitForExistence(timeout: 6), "The regression must open the native evidence tooltip")
        try auditWorkspaceAccessibility(includeContrast: true)
        XCTAssertFalse(help.exists, "Workspace audits must measure the unobscured controls")
    }

    func testReviewAndSearchAccessibilityInBothAppearances() throws {
        for appearance in ["light", "dark"] {
            try launch(["LOKALBOT_INITIAL_SECTION": "meetings", "LOKALBOT_SELECT_INDEX": "0",
                        "LOKALBOT_DETAIL_TAB": "review", "LOKALBOT_CAPTURE_APPEARANCE": appearance])
            // This launch opens the sheet that names speakers. The window
            // behind a sheet is dimmed and cannot be used, so its contrast is
            // audited once the sheet has closed, a few lines down.
            let namingSheet = element("meeting.namingSheet")
            XCTAssertTrue(namingSheet.waitForExistence(timeout: 5))
            try auditWorkspaceAccessibility(includeContrast: true, contrastScope: namingSheet)
            snapshot("meeting-naming-sheet-\(appearance)")
            app.buttons["meeting.naming.cancel"].click()
            XCTAssertTrue(UITestHarness.waitUntil { !self.element("meeting.namingSheet").exists })
            let owner = element("meeting.action.owner.fixture-action-design-2")
            UITestHarness.scrollTo(owner, in: app, within: app.scrollViews["meeting.content.scroll"])
            XCTAssertTrue(owner.isHittable)
            XCTAssertTrue(owner.label.hasPrefix("Owner:"))
            XCTAssertEqual(app.buttons["meeting.action.toggle.fixture-action-design-1"].label, "Mark action done")
            try auditWorkspaceAccessibility(includeContrast: true)
            snapshot("meeting-summary-owners-\(appearance)")
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

    func testTimelineListResizesAgainstThePage() throws {
        try launch(["LOKALBOT_INITIAL_SECTION": "timeline", "LOKALBOT_CAPTURE_SIZE": "1440x900"])
        let list = element("timeline.list")
        let page = element("timeline.evidencePane")
        XCTAssertTrue(list.waitForExistence(timeout: 5))
        XCTAssertTrue(page.waitForExistence(timeout: 5))
        XCTAssertFalse(element("timeline.sessionRail").exists, "The rail on the right was replaced by the list")
        let opening = list.frame.width
        let divider = try XCTUnwrap(app.splitters.allElementsBoundByIndex.min {
            abs($0.frame.midX - list.frame.maxX) < abs($1.frame.midX - list.frame.maxX)
        }, "Timeline divider missing")

        app.activate()
        let grip = divider.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        grip.press(forDuration: 0.1, thenDragTo: grip.withOffset(CGVector(dx: 100, dy: 0)))
        XCTAssertTrue(UITestHarness.waitUntil { list.frame.width >= opening + 80 },
                      "The day's list should widen past its opening width (\(list.frame.width) from \(opening))")
        XCTAssertGreaterThanOrEqual(page.frame.width, 420, "The page keeps its readable minimum")
        snapshot("timeline-wide-list")

        // Divider positions persist in the host's defaults; leave the next
        // launch at the opening width.
        let widened = divider.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        widened.press(forDuration: 0.1, thenDragTo: widened.withOffset(CGVector(dx: opening - list.frame.width, dy: 0)))
        XCTAssertTrue(UITestHarness.waitUntil { abs(list.frame.width - opening) < 8 })
    }

    func testSettingsCategoryResetsScrollAndDictationHasDirectNavigation() throws {
        try launch(["LOKALBOT_INITIAL_SECTION": "settings", "LOKALBOT_INITIAL_SETTINGS_CATEGORY": "agents"])
        let form = app.scrollViews["settings.form"]
        let cli = UITestHarness.staticText(containing: "Agent CLI", in: app)
        UITestHarness.scrollTo(cli, in: app, within: form, attempts: 16)
        UITestHarness.selectSettingsCategory("General", in: app)
        let launchToggle = UITestHarness.toggle("Launch LokalBot at login", in: app)
        XCTAssertTrue(UITestHarness.waitUntil { launchToggle.isHittable }, "A category opens at its own top")
        UITestHarness.selectSettingsCategory("Dictation", in: app)
        let toggle = UITestHarness.toggle("Enable dictation shortcut", in: app)
        XCTAssertTrue(UITestHarness.waitUntil { toggle.isHittable })
        XCTAssertFalse(UITestHarness.toggle("Enable autocomplete", in: app).exists,
                       "Dictation has its own page, separate from autocomplete")
        snapshot("settings-dictation")
        UITestHarness.selectSettingsCategory("Diagnostics", in: app)
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
        try launch(["LOKALBOT_INITIAL_SECTION": "meetings", "LOKALBOT_SELECT_INDEX": "0"])
        XCTAssertTrue(element("meeting.export").waitForExistence(timeout: 5))
        // XCTest audits the exposed actions through its authorized automation
        // service; menu interaction below separately verifies the callbacks.
        // This is not a manual VoiceOver listening test.
        try auditWorkspaceAccessibility()
        for (identifier, item) in [("meeting.export", "Copy as Markdown"),
                                   ("toolbar.meetingActions", "Reprocess"),
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
        UITestHarness.selectSettingsCategory("Autocomplete", in: app)
        let tryIt = app.buttons["settings.header.writing.tryIt"]
        XCTAssertTrue(tryIt.waitForExistence(timeout: 6))
        tryIt.click()
        let editor = app.textViews["autocomplete.rehearsal.editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 6), "Try it… did not open the rehearsal")
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
        XCTAssertTrue(app.buttons["today.record"].waitForExistence(timeout: 5))
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
        let history = app.outlines["chat.history.list"]
        XCTAssertTrue(history.waitForExistence(timeout: 5))
        XCTAssertEqual(history.label, "Saved conversations")
        app.textFields["search.field"].click()
        app.textFields["search.field"].typeText("failover")
        XCTAssertTrue(element("search.hit.\(fixture.designReview.id.uuidString).segment").waitForExistence(timeout: 6))
        try auditWorkspaceAccessibility()
        snapshot("search-reduced-motion")
    }

    func testRetentionReviewCancelPreservesPolicy() throws {
        try launch(["LOKALBOT_SCREEN_MEMORY_DEMO": "1"])
        UITestHarness.clickSidebar("sidebar.settings", in: app)
        UITestHarness.selectSettingsCategory("Screen & activity", in: app)
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

    func testActionSearchPreservesSelectionAndCompletionRecoversFromSaveFailure() throws {
        let folder = fixture.folder(for: fixture.designReview)
        // Large-list persistence belongs to RedesignContractTests, which
        // covers 0, 40 and 400 actions without an accessibility snapshot of every row.
        // Two distinct actions exercise filtering and selection here. The
        // dated one lists ahead of the other, which is therefore never the
        // row the page selects by default.
        let actions: [[String: Any]] = (0..<2).map { index in
            var action: [String: Any] = [
                "id": "search-action-\(index)", "schemaVersion": 2, "text": "Synthetic commitment \(index)",
                "owner": "Me", "isForUser": true, "citations": []]
            if index == 0 { action["due"] = "Friday" }
            return action
        }
        let data = try JSONSerialization.data(withJSONObject: ["schemaVersion": 2, "actionItems": actions])
        try data.write(to: folder.appendingPathComponent("outcomes.json"))
        try launch()
        app.buttons["outcomes.review"].click()
        let search = app.textFields["actions.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        // The details pane is open beside the list with the first row selected.
        let detailsTitle = element("actions.details.title")
        func detailsShow(_ text: String) -> Bool {
            UITestHarness.waitUntil { detailsTitle.exists && (detailsTitle.value as? String ?? detailsTitle.label) == text }
        }
        XCTAssertTrue(detailsTitle.waitForExistence(timeout: 5), "The first action should be selected when the page opens")
        // Failure messages and the details pane repeat the action title; inspect only its list row.
        func row(_ text: String) -> XCUIElement {
            element("actions.list").staticTexts.matching(
                NSPredicate(format: "label == %@ OR value == %@", text, text)).firstMatch
        }
        let action = row("Synthetic commitment 1")
        XCTAssertTrue(action.waitForExistence(timeout: 5))
        action.click()
        XCTAssertTrue(detailsShow("Synthetic commitment 1"))
        search.click(); search.typeText("Synthetic commitment 0")
        XCTAssertTrue(detailsShow("Synthetic commitment 0"),
                      "A search that hides the selected action shows the first listed one instead")
        XCTAssertFalse(action.exists)
        search.click(); search.typeKey("a", modifierFlags: .command)
        search.typeKey(.delete, modifierFlags: [])
        XCTAssertTrue(action.waitForExistence(timeout: 5))
        XCTAssertTrue(detailsShow("Synthetic commitment 1"), "Clearing the search should restore the selection")
        // ⌘-click adds a row, and the details pane offers the batch changes.
        XCTAssertFalse(element("actions.batch").exists, "The batch pane appears only for several selected rows")
        XCUIElement.perform(withKeyModifiers: .command) { row("Synthetic commitment 0").click() }
        XCTAssertTrue(element("actions.batch").waitForExistence(timeout: 3), "⌘-click should select a second action")
        XCTAssertTrue(app.buttons["actions.batch.done"].exists)
        action.click()
        XCTAssertTrue(UITestHarness.waitUntil { !self.element("actions.batch").exists },
                      "A plain click should return to one selected action")
        let complete = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND value == %@", "outcome.thread.toggle.", "Synthetic commitment 1")).firstMatch
        XCTAssertTrue(complete.waitForExistence(timeout: 4))
        let stateFile = folder.appendingPathComponent("outcome-state.json")
        try withBlockedStateFile(stateFile) {
            complete.click()
            XCTAssertTrue(UITestHarness.staticText(containing: "Could not update this action", in: app)
                .waitForExistence(timeout: 4))
            XCTAssertEqual(complete.label, "Mark action thread done", "A failed save must leave the action open")
            snapshot("action-complete-write-failure")
        }
        complete.click()
        // A completed action stays in the list, ticked, until the view changes.
        XCTAssertTrue(UITestHarness.waitUntil { complete.exists && complete.label == "Reopen action thread" })
        XCTAssertTrue(action.exists, "The ticked action should stay listed until the view changes")
        XCTAssertFalse(UITestHarness.staticText(containing: "Could not update this action", in: app).exists,
                       "A successful retry should clear the previous save error")
        XCTAssertFalse(app.windows.buttons["Undo"].exists, "Completing an action must not leave a persistent Undo bar")
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: stateFile)) as? [String: Any])
        let states = try XCTUnwrap(saved["actions"] as? [String: [String: Any]])
        XCTAssertEqual(states["search-action-1"]?["status"] as? String, "done")
        // Leaving Open and coming back closes the list up.
        UITestHarness.selectSegment("Done", pickerIdentifier: "actions.status", in: app)
        XCTAssertTrue(action.waitForExistence(timeout: 4), "The completed action belongs to the Done list")
        UITestHarness.selectSegment("Open", pickerIdentifier: "actions.status", in: app)
        XCTAssertTrue(UITestHarness.waitUntil { !action.exists }, "A completed action left the Open list")
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
        // The card asks a question that names the file. The fixture's file is
        // inside the library, so the card says so and shows the full path.
        // The question is a heading, which macOS reports with a label; plain
        // text reports a value. Read both, as VoiceOver reads either.
        let question = app.descendants(matching: .any)["agent.approval.title"]
        XCTAssertTrue(question.waitForExistence(timeout: 4), "The approval card has no question")
        let asked = [question.label, question.value as? String ?? ""].joined(separator: " ")
        XCTAssertTrue(asked.contains("Create reviewed-note.md?"), "The card asked: \(asked)")
        XCTAssertTrue(UITestHarness.staticText(containing: "own data", in: app).exists,
                      "The card says the file is inside LokalBot's own data")
        XCTAssertTrue(app.descendants(matching: .any)["agent.approval.path"].exists)
        XCTAssertFalse(app.buttons["agent.approve.session"].exists,
                       "A file in LokalBot's own data can only be allowed once")
        XCTAssertTrue(app.descendants(matching: .any)["agent.awaitingAnswer"].exists,
                      "The conversation ends with a line that points at the card")
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
    /// Blocks writes by putting a directory where the state file belongs, then
    /// restores the previous file, or its absence when no status was saved yet.
    private func withBlockedStateFile(_ file: URL, perform body: () throws -> Void) throws {
        let contents = try? Data(contentsOf: file)
        if contents != nil { try FileManager.default.removeItem(at: file) }
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: file)
            try? contents?.write(to: file, options: .atomic)
        }
        try body()
    }

    private func element(_ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    /// The day's sessions are rows of the list beside the page.
    private func openFirstTimelineSession() {
        let session = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "timeline.session.")).firstMatch
        XCTAssertTrue(session.waitForExistence(timeout: 5), "Timeline has no work session to select")
        UITestHarness.scrollTo(session, in: app)
        session.click()
    }

    private func dismissHoverHelpBeforeAuditing() {
        // Scrolling can leave the pointer over an evidence link. Its native
        // help tag obscures the text being measured and has no audit label.
        // Hovering over the titlebar preserves the current focus and menus.
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.01)).hover()
        XCTAssertTrue(app.descendants(matching: .helpTag).firstMatch.waitForNonExistence(timeout: 3),
                      "Dismiss native hover help before measuring workspace accessibility")
    }

    /// `contrastScope` limits the contrast audit to that element's own
    /// descendants, for a sheet or popover in front of dimmed content.
    private func auditWorkspaceAccessibility(includeContrast: Bool = false, contrastBounds: CGRect? = nil,
                                             contrastScope: XCUIElement? = nil) throws {
        dismissHoverHelpBeforeAuditing()
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
        dismissHoverHelpBeforeAuditing()
        try app.performAccessibilityAudit(for: types) { issue in
            guard let affected = issue.element, affected.exists else { return false }
            if issue.auditType == .contrast {
                // The macOS audit also samples offscreen text and content
                // behind popovers. Audit only painted, unclipped text here;
                // each scroll region and open popover is audited separately.
                let bounds = contrastBounds ?? self.app.windows.firstMatch.frame
                if !bounds.insetBy(dx: -1, dy: -1).contains(affected.frame) { return true }
                // Text behind a sheet can share its bounds; tell the sheet's
                // own text apart by its exact frame.
                if let contrastScope,
                   !contrastScope.descendants(matching: affected.elementType).allElementsBoundByIndex
                    .contains(where: { $0.frame == affected.frame }) { return true }
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
                // WCAG 1.4.3 exempts inactive controls, such as Ask before a
                // question is typed.
                if !affected.isEnabled, affected.elementType == .button { return true }
                // The audit also flags native sidebar rows and supporting copy
                // that render well above 4.5:1. Accept a flag only when every
                // text inside the flagged element measures at least 4.5:1 in
                // its own rendered pixels; faint text still fails.
                if self.renderedTextPassesContrast(affected) { return true }
            }
            // A native menu's items carry the actions; its container has none.
            if issue.auditType == .action, affected.elementType == .menu { return true }
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
        // The explanations in the sheet that names speakers, which replaced
        // the Review tab's.
        let labels = [
            "Play a voice, then pick who it is. LokalBot learns each voice for later meetings. Voices stay encrypted on this Mac.",
            "Skip any voice you are not sure about.",
        ]
        var verified = Set<String>()
        let content = app.scrollViews["meeting.content.scroll"]
        for label in labels {
            let text = app.staticTexts.matching(NSPredicate(format: "label == %@ OR value == %@", label, label)).firstMatch
            guard text.exists, app.windows.firstMatch.frame.contains(text.frame) else { continue }
            // Scrolled meeting content can report a frame under the pinned
            // header; its pixels there belong to the header, not this text.
            if content.exists,
               content.staticTexts.matching(NSPredicate(format: "label == %@ OR value == %@", label, label)).count > 0,
               !content.frame.insetBy(dx: -1, dy: -1).contains(text.frame) { continue }
            let screenshot = text.screenshot()
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: screenshot.pngRepresentation))
            let ratio = try XCTUnwrap(RenderedTextContrast.ratio(of: bitmap),
                                      "Expected measurable glyphs on a uniform background: \(label)")
            let evidence = XCTAttachment(screenshot: screenshot)
            evidence.name = "recall-explanation-contrast-\(String(format: "%.2f", ratio))"
            evidence.lifetime = .keepAlways
            add(evidence)
            XCTAssertGreaterThanOrEqual(ratio, 4.5, "Rendered explanation must meet 4.5:1: \(label)")
            if ratio >= 4.5 { verified.insert(label) }
        }
        return verified
    }

    /// Measures each static text in a flagged element, or the element itself
    /// when it has none (combined rows). An unmeasurable capture never passes.
    private func renderedTextPassesContrast(_ element: XCUIElement) -> Bool {
        let texts = element.descendants(matching: .staticText).allElementsBoundByIndex
            .filter { $0.exists && !$0.frame.isEmpty }
        for target in texts.isEmpty ? [element] : texts {
            let screenshot = target.screenshot()
            guard let bitmap = NSBitmapImageRep(data: screenshot.pngRepresentation),
                  let ratio = RenderedTextContrast.ratio(of: bitmap) else { return false }
            let evidence = XCTAttachment(screenshot: screenshot)
            evidence.name = "audited-contrast-\(String(format: "%.2f", ratio))"
            evidence.lifetime = .keepAlways
            add(evidence)
            if ratio < 4.5 { return false }
        }
        return true
    }

    private func snapshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
