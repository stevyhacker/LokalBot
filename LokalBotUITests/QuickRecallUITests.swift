import XCTest

/// Covers the compact system-wide Ask window against the same synthetic local
/// library as the main-window search tests.
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
            // Seed the complete query before SwiftUI mounts. The clear test
            // below still drives real typing; the result/restore tests avoid a
            // race among eight per-character debounce tasks on hosted Macs.
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
        XCTAssertTrue(app.buttons["quickRecall.ask"].exists)
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
        input.typeKey(.return, modifierFlags: [])
        XCTAssertFalse(app.staticTexts["chat.message.user"].exists)
        app.buttons["Clear"].click()
        XCTAssertEqual(input.value as? String, "")
        XCTAssertTrue(text(containing: "Ask anything").waitForExistence(timeout: 4))
    }

    func testBackFromInlineAnswerRestoresRecallQuery() {
        XCTAssertEqual(input.value as? String, "failover")
        let ask = app.buttons["quickRecall.ask"]
        XCTAssertTrue(ask.waitForExistence(timeout: 6))
        ask.click()
        let draft = app.textFields["search.field"]
        XCTAssertTrue(draft.waitForExistence(timeout: 6))
        XCTAssertEqual(draft.value as? String, "failover")
        XCTAssertTrue(app.descendants(matching: .any)["ask.selectedEvidence"].firstMatch.exists)
        XCTAssertFalse(app.staticTexts["chat.message.user"].exists,
                       "Reviewing a bounded draft must not dispatch generation")
    }

    private var input: XCUIElement {
        app.textFields["quickRecall.input"]
    }

    private func text(containing fragment: String) -> XCUIElement {
        UITestHarness.staticText(containing: fragment, in: app)
    }
}
