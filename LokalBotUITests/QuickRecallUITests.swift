import XCTest

final class QuickRecallUITests: XCTestCase {
    private var fixture: SyntheticFixture.Library!
    private var app: XCUIApplication!
    private var defaultsSuiteName: String?

    override func setUpWithError() throws {
        continueAfterFailure = false
        fixture = try SyntheticFixture.plant()
        var environment = ["LOKALBOT_UI_TEST_WINDOW": "quick-recall"]
        if name.contains("testSearchShowsLocalMeetingEvidenceAndInlineAsk")
            || name.contains("testBackFromInlineAnswerRestoresRecallQuery") {
            environment["LOKALBOT_QUICK_RECALL_QUERY"] = "failover"
        } else if name.contains("testTypedCommandLeadsTheResults") {
            environment["LOKALBOT_QUICK_RECALL_QUERY"] = "record"
        }
        let launch = try UITestHarness.launch(
            storageRoot: fixture.root,
            suitePrefix: "QuickRecall",
            environment: environment)
        app = launch.app
        defaultsSuiteName = launch.defaultsSuiteName
        XCTAssertTrue(input.waitForExistence(timeout: 8),
                      "Quick Recall search input did not render")
    }

    override func tearDownWithError() throws {
        app?.terminate()
        fixture?.cleanUp()
        UITestHarness.cleanUp(defaultsSuiteName: defaultsSuiteName)
    }

    func testSearchShowsLocalMeetingEvidenceAndInlineAsk() {
        XCTAssertEqual(input.value as? String, "failover")
        let meeting = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@",
            "quickRecall.row.meeting.\(fixture.designReview.id.uuidString).segment.")).firstMatch
        XCTAssertTrue(meeting.waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["quickRecall.ask"].exists, "Ask is one row pinned under the results")
        XCTAssertFalse(app.buttons["Open full Ask"].exists)
        input.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(app.descendants(matching: .any)["detail.title"].firstMatch.waitForExistence(timeout: 6))
        XCTAssertFalse(app.staticTexts["chat.message.user"].exists)
    }

    func testTypedCommandLeadsTheResults() {
        XCTAssertEqual(input.value as? String, "record")
        let command = app.buttons["quickRecall.row.command.record"]
        XCTAssertTrue(command.waitForExistence(timeout: 8), "a typed command is offered in the system-wide window")
        XCTAssertFalse(app.buttons["quickRecall.row.command.dictation"].exists)
    }

    func testClearReturnsToAskEmptyState() {
        input.click()
        input.typeText("nothing-local-matches-this")
        XCTAssertTrue(app.descendants(matching: .any)["quickRecall.noMatches"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["quickRecall.ask"].exists)
        input.typeKey(.return, modifierFlags: [])
        XCTAssertFalse(app.staticTexts["chat.message.user"].exists)
        app.buttons["Clear"].click()
        XCTAssertEqual(input.value as? String, "")
        XCTAssertTrue(app.buttons["quickRecall.row.command.record"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.buttons["quickRecall.row.command.nav.settings"].exists,
                      "every command the ⌘K palette ran is listed")
        XCTAssertTrue(app.buttons["quickRecall.row.recent.meeting.\(fixture.designReview.id.uuidString)"].exists)
        XCTAssertFalse(app.buttons["quickRecall.ask"].exists, "there is nothing to ask about yet")
    }

    func testBackFromInlineAnswerRestoresRecallQuery() {
        XCTAssertEqual(input.value as? String, "failover")
        let meeting = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@",
            "quickRecall.row.meeting.\(fixture.designReview.id.uuidString).segment.")).firstMatch
        XCTAssertTrue(meeting.waitForExistence(timeout: 8))
        let ask = app.buttons["quickRecall.ask"]
        XCTAssertTrue(ask.waitForExistence(timeout: 6))
        ask.click()
        XCTAssertTrue(app.staticTexts["chat.message.user"].waitForExistence(timeout: 6))
        XCTAssertFalse(app.textFields["search.field"].exists, "the main window's Ask page is not opened")
        XCTAssertEqual(input.value as? String, "")
        XCTAssertTrue(app.buttons["quickRecall.continue"].exists)
        XCTAssertFalse(meeting.exists)
        let back = app.buttons["quickRecall.back"]
        XCTAssertTrue(back.exists)
        back.click()
        XCTAssertTrue(meeting.waitForExistence(timeout: 8))
        XCTAssertEqual(input.value as? String, "failover")
        XCTAssertTrue(app.buttons["quickRecall.ask"].exists)
    }

    private var input: XCUIElement {
        app.textFields["quickRecall.input"]
    }
}
