import XCTest

/// Hosted regressions for retrieval submission and Timeline rewind lifetimes.
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

    func testRawCaptureRewindKeepsPlayingAndSeekingAcrossMomentDetails() throws {
        try SyntheticFixture.plantActivityMoment(in: fixture, count: 3)
        try launch(["LOKALBOT_INITIAL_SECTION": "timeline", "LOKALBOT_CAPTURE_SIZE": "1000x700"])
        let raw = app.buttons["timeline.rawCapture"]
        XCTAssertTrue(raw.waitForExistence(timeout: 8))
        raw.click()
        let play = app.buttons["Play context rewind"]
        XCTAssertTrue(play.waitForExistence(timeout: 5))
        play.click()
        // Two timer ticks must survive mounting the first moment detail.
        XCTAssertTrue(element("timeline.screenDetail.9003").waitForExistence(timeout: 8))
        XCTAssertTrue(app.sliders["Rewind position"].exists)
        let previous = app.buttons["Previous context moment"]
        XCTAssertTrue(previous.isHittable)
        previous.click()
        XCTAssertTrue(element("timeline.screenDetail.9002").waitForExistence(timeout: 4))
        app.buttons["Next context moment"].click()
        XCTAssertTrue(element("timeline.screenDetail.9003").waitForExistence(timeout: 4))

        let position = app.sliders["Rewind position"]
        let first = position.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.5))
        let last = position.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5))
        last.press(forDuration: 0.1, thenDragTo: first)
        XCTAssertTrue(element("timeline.screenDetail.9001").waitForExistence(timeout: 4))
        first.press(forDuration: 0.1, thenDragTo: last)
        XCTAssertTrue(element("timeline.screenDetail.9003").waitForExistence(timeout: 4))
        let lastPosition = String(describing: position.value)
        app.buttons["Back to raw capture"].click()
        XCTAssertTrue(element("timeline.track").waitForExistence(timeout: 4))
        XCTAssertEqual(String(describing: position.value), lastPosition,
                       "Returning to raw capture must preserve the rewind cursor")
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
