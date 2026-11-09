import XCTest

/// Hosted regression checks for the Autocomplete rehearsal: it must accept, keep,
/// and discard a suggestion the way autocomplete does in another app. The
/// host's demo mode supplies fixed suggestions, so no model is involved.
final class AutocompleteRehearsalUITests: XCTestCase {
    private static let draft = "Hi Sarah, thanks for the update. I wanted to follow"
    private static let opening = " up on the migration timeline we scoped yesterday."
    private static let following = " up on the synthetic review."

    private var app: XCUIApplication!
    private var fixture: SyntheticFixture.Library!
    private var defaultsSuiteName: String?

    override func setUpWithError() throws {
        continueAfterFailure = false
        fixture = try SyntheticFixture.plant()
    }

    override func tearDownWithError() throws {
        app?.terminate()
        fixture?.cleanUp()
        UITestHarness.cleanUp(defaultsSuiteName: defaultsSuiteName)
    }

    /// With "One word" selected, one Tab used to insert the whole suggestion.
    func testTabTakesOneWordAndKeepsTheRest() throws {
        let editor = try openRehearsal()
        XCTAssertTrue(UITestHarness.staticText(containing: "Tab accepts the next word", in: app).exists)
        editor.typeKey(.tab, modifierFlags: [])
        XCTAssertTrue(wait(editor, holds: Self.draft + " up"), "Tab must insert exactly one word")
        XCTAssertTrue(waitForGhost(" on the migration timeline we scoped yesterday."),
                      "the rest of the suggestion must stay on offer")
        editor.typeKey(.tab, modifierFlags: [])
        XCTAssertTrue(wait(editor, holds: Self.draft + " up on"))
        XCTAssertTrue(waitForGhost(" the migration timeline we scoped yesterday."))
    }

    func testFullAcceptKeyAndButtonTakeEverythingThatIsLeft() throws {
        let editor = try openRehearsal()
        editor.typeKey(.tab, modifierFlags: [])
        XCTAssertTrue(wait(editor, holds: Self.draft + " up"))
        editor.typeText("`")
        XCTAssertTrue(wait(editor, holds: Self.draft + Self.opening),
                      "the full-accept key must insert the rest, not a backtick")
        // A finished suggestion is followed by the next one.
        XCTAssertTrue(waitForGhost(Self.following))
        app.buttons["Insert suggestion"].click()
        XCTAssertTrue(wait(editor, holds: Self.draft + Self.opening + Self.following))
    }

    func testTypingTheSuggestionWalksThroughItAndOtherTextReplacesIt() throws {
        let editor = try openRehearsal()
        editor.typeText(" up")
        XCTAssertTrue(waitForGhost(" on the migration timeline we scoped yesterday."),
                      "typing the suggested characters must keep the rest")
        XCTAssertEqual(editor.value as? String, Self.draft + " up")
        editor.typeText("x")
        XCTAssertTrue(waitForGhost(Self.following), "text that departs from the suggestion needs a new one")
        XCTAssertEqual(editor.value as? String, Self.draft + " upx")
    }

    func testMovingTheCaretLeavesTheSuggestionBehind() throws {
        let editor = try openRehearsal()
        editor.typeKey(.leftArrow, modifierFlags: [])
        XCTAssertTrue(waitForGhost(""), "a suggestion continues the end of the text only")
        editor.typeKey(.tab, modifierFlags: [])
        XCTAssertEqual(editor.value as? String, Self.draft, "Tab without a suggestion must not insert")
    }

    func testPhraseSettingTakesTheWholeSentence() throws {
        let editor = try openRehearsal(granularity: "phrase")
        XCTAssertTrue(UITestHarness.staticText(containing: "Tab accepts the next phrase", in: app).exists)
        editor.typeKey(.tab, modifierFlags: [])
        XCTAssertTrue(wait(editor, holds: Self.draft + Self.opening))
    }

    func testRehearsalShowsItsSampleConversationAndContextSources() throws {
        _ = try openRehearsal()
        let conversation = app.descendants(matching: .any)["autocomplete.rehearsal.conversation"]
        XCTAssertTrue(conversation.waitForExistence(timeout: 5))
        // Every optional source is off, and the rehearsal says so. Visible text
        // is on for new installs only; these saved settings predate the key,
        // like an existing install's, so it stays off.
        for source in ["visible", "meetings", "screen"] {
            let row = app.descendants(matching: .any)["autocomplete.rehearsal.context.\(source)"]
            XCTAssertTrue(row.exists, "missing context row: \(source)")
            let text = row.label.isEmpty ? (row.value as? String ?? "") : row.label
            XCTAssertTrue(text.hasSuffix(": Off"), "\(source) should read as off, not '\(text)'")
        }
    }

    // MARK: - Helpers

    private func openRehearsal(granularity: String = "word") throws -> XCUIElement {
        let settings = """
        {
          "menuBarOnly": false,
          "trackingEnabled": true,
          "screenshotsEnabled": false,
          "calendarDetectionEnabled": false,
          "semanticSearchEnabled": false,
          "cotypingEnabled": false,
          "cotypingAcceptGranularity": "\(granularity)"
        }
        """
        let launch = try UITestHarness.launch(
            storageRoot: fixture.root,
            suitePrefix: "AutocompleteRehearsal",
            settingsJSON: settings,
            environment: ["LOKALBOT_COTYPING_DEMO": "1"])
        app = launch.app
        defaultsSuiteName = launch.defaultsSuiteName
        XCTAssertTrue(app.descendants(matching: .any)["today.header"]
            .waitForExistence(timeout: 10), "main window never rendered")
        UITestHarness.clickSidebar("sidebar.settings", in: app)
        UITestHarness.selectSettingsCategory("Autocomplete", in: app)
        let editor = app.textViews["autocomplete.rehearsal.editor"]
        UITestHarness.scrollTo(editor, in: app)
        editor.click()
        XCTAssertEqual(editor.value as? String, Self.draft)
        XCTAssertTrue(waitForGhost(Self.opening), "the demo suggestion never appeared")
        return editor
    }

    /// The suggestion is painted, not typed, so it is read from the control
    /// that would insert it.
    private func waitForGhost(_ expected: String) -> Bool {
        UITestHarness.waitUntil {
            (self.app.buttons["Insert suggestion"].value as? String ?? "") == expected
        }
    }

    private func wait(_ editor: XCUIElement, holds expected: String) -> Bool {
        UITestHarness.waitUntil { editor.value as? String == expected }
    }
}
