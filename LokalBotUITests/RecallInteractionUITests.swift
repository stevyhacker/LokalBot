import XCTest

/// Hosted regressions for retrieval submission and Timeline capture cleanup.
final class RecallInteractionUITests: XCTestCase {
    private var fixture: SyntheticFixture.Library!
    private var app: XCUIApplication!
    private var suite: String?

    override func setUpWithError() throws {
        continueAfterFailure = false
        fixture = try SyntheticFixture.plant()
    }

    override func tearDownWithError() throws {
        app?.terminate()
        UITestHarness.cleanUp(defaultsSuiteName: suite)
        fixture?.cleanUp()
    }

    func testRawCaptureOffersReviewedTimeRangeDeletion() throws {
        try SyntheticFixture.plantActivityMoment(in: fixture, count: 3)
        try launch(["LOKALBOT_INITIAL_SECTION": "timeline", "LOKALBOT_CAPTURE_SIZE": "1000x700"])
        let raw = app.buttons["timeline.rawCapture"]
        XCTAssertTrue(raw.waitForExistence(timeout: 8))
        // All captured activity is pinned to the foot of the day's list.
        raw.click()
        XCTAssertTrue(element("timeline.track").waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Play context rewind"].exists, "Context rewind was removed")
        let toggle = app.buttons["timeline.deleteRange.toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        toggle.click()
        let review = app.buttons["timeline.deleteRange"]
        XCTAssertTrue(review.waitForExistence(timeout: 3))
        XCTAssertTrue(review.isEnabled, "The default range covers the day's captures")
        review.click()
        XCTAssertTrue(UITestHarness.staticText(containing: "Review capture deletion", in: app)
            .waitForExistence(timeout: 3))
        app.buttons["Cancel"].click()
        XCTAssertTrue(UITestHarness.waitUntil {
            !UITestHarness.staticText(containing: "Review capture deletion", in: self.app).exists
        })
        XCTAssertTrue(element("timeline.track").exists, "Cancelling the review deletes nothing")
    }

    func testQuestionReturnWaitsForSourcesAndSubmitsOnce() throws {
        try launchDelayedAsk()
        let field = app.textFields["search.field"]
        field.click()
        field.typeText("failover benchmark?\r")
        // The button keeps saying Ask; the matches heading says they are still arriving.
        XCTAssertTrue(element("ask.waitingForSources").waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["ask.submit"].isEnabled, "A queued question must not be sent twice")
        XCTAssertFalse(element("chat.message.user").exists)
        XCTAssertTrue(element("chat.message.user").waitForExistence(timeout: 10))
        // The row identifier and scoped value are inherited by its metadata;
        // only the question text has this label.
        let questions = app.staticTexts.matching(NSPredicate(
            format: "identifier == %@ AND label == %@", "chat.message.user", "failover benchmark?"))
        XCTAssertTrue(questions.firstMatch.waitForExistence(timeout: 4), app.debugDescription)
        XCTAssertEqual(questions.count, 1, questions.debugDescription)
        XCTAssertEqual(field.value as? String, "")
        // The answer is limited to the meeting that matched, and the sources
        // menu is where that shows.
        XCTAssertTrue(UITestHarness.waitUntil {
            (self.element("ask.sources").value as? String) == self.fixture.designReview.title
        }, "Submission must use the retrieved meeting boundary")
        XCTAssertFalse(element("ask.selectedEvidence").exists, "Scope lives only in the composer menus")
    }

    func testEditingQueuedQuestionCancelsSubmission() throws {
        try launchDelayedAsk()
        let field = app.textFields["search.field"]
        field.click()
        field.typeText("failover benchmark?\r")
        XCTAssertTrue(element("ask.waitingForSources").waitForExistence(timeout: 3))
        field.typeKey("a", modifierFlags: .command)
        field.typeText("standup")
        let result = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@",
            "search.hit.\(fixture.standup.id.uuidString).")).firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 10))
        XCTAssertFalse(element("chat.message.user").exists)
        XCTAssertEqual(field.value as? String, "standup")
    }

    func testChangingScopeCancelsQueuedQuestion() throws {
        try launchDelayedAsk()
        let field = app.textFields["search.field"]
        field.click()
        field.typeText("failover benchmark?\r")
        XCTAssertTrue(element("ask.waitingForSources").waitForExistence(timeout: 3))
        element("ask.sources").click()
        app.menuItems["Activity"].click()
        XCTAssertTrue(element("search.hit.\(fixture.designReview.id.uuidString).segment").waitForExistence(timeout: 10))
        XCTAssertFalse(element("chat.message.user").exists)
        XCTAssertEqual(field.value as? String, "failover benchmark?")
    }

    private func launchDelayedAsk() throws {
        try launch(["LOKALBOT_INITIAL_SECTION": "ask", "LOKALBOT_ASK_SEARCH_DELAY_MS": "5000"])
        XCTAssertTrue(app.textFields["search.field"].waitForExistence(timeout: 8))
    }

    private func launch(_ environment: [String: String]) throws {
        // Invalid inference destination exercises the saved user turn and
        // source scope without downloading a model or contacting a server.
        let run = try UITestHarness.launch(storageRoot: fixture.root, suitePrefix: "RecallInteraction",
            settingsJSON: #"{"menuBarOnly":false,"calendarDetectionEnabled":false,"semanticSearchEnabled":false,"cotypingEnabled":false,"summarizerBackend":"OpenAI-compatible server","openAIBaseURL":"invalid"}"#,
            environment: environment)
        app = run.app
        suite = run.defaultsSuiteName
    }

    private func element(_ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }
}
