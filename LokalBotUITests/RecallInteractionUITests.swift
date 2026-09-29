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
        // Raw capture follows the day's summary sections, below a 700 pt fold.
        UITestHarness.scrollTo(raw, in: app)
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
        XCTAssertTrue(app.buttons["Waiting for sources…"].waitForExistence(timeout: 3))
        XCTAssertFalse(element("chat.message.user").exists)
        XCTAssertTrue(element("chat.message.user").waitForExistence(timeout: 10))
        // The row identifier and scoped value are inherited by its metadata;
        // only the question text has this label.
        let questions = app.staticTexts.matching(NSPredicate(
            format: "identifier == %@ AND label == %@", "chat.message.user", "failover benchmark?"))
        XCTAssertTrue(questions.firstMatch.waitForExistence(timeout: 4), app.debugDescription)
        XCTAssertEqual(questions.count, 1, questions.debugDescription)
        XCTAssertEqual(field.value as? String, "")
        XCTAssertTrue(element("ask.selectedEvidence").label.contains("1 meetings"),
                      "Submission must use the retrieved meeting boundary")
    }

    func testEditingQueuedQuestionCancelsSubmission() throws {
        try launchDelayedAsk()
        let field = app.textFields["search.field"]
        field.click()
        field.typeText("failover benchmark?\r")
        XCTAssertTrue(app.buttons["Waiting for sources…"].waitForExistence(timeout: 3))
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
        XCTAssertTrue(app.buttons["Waiting for sources…"].waitForExistence(timeout: 3))
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
