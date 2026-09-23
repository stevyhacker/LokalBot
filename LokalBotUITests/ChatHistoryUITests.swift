import XCTest

/// The Chat section surfaces persisted conversation history. A conversation
/// seeded on disk (under `<root>/chats/`) before launch must appear in the
/// conversation-list column and open its messages in the transcript — proving
/// `ChatStore` load + the three-column chat wiring end to end, without ever
/// touching the local LLM.
///
/// Its own `setUp` (separate from `MainWindowUITests`) plants a chat-seeded
/// root, so the shared empty-state chat test stays unaffected.
final class ChatHistoryUITests: XCTestCase {

    private var root: URL!
    private var app: XCUIApplication!
    private var defaultsSuiteName: String?

    private let conversationTitle = "Pricing decision"
    private let conversationID = "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"
    private let assistantLine = "You chose tiered pricing."
    private let olderConversationTitle = "Roadmap review"
    private let olderConversationID = "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB"
    private let olderAssistantLine = "The team moved launch to August."

    override func setUpWithError() throws {
        continueAfterFailure = false
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChatHistoryUITests-\(UUID().uuidString)", isDirectory: true)
        // The app expects a `meetings/` dir; chat history lives under `chats/`.
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("meetings"), withIntermediateDirectories: true)
        try seedConversation()

        let launch = try UITestHarness.launch(storageRoot: root, suitePrefix: "ChatHistory")
        app = launch.app
        defaultsSuiteName = launch.defaultsSuiteName
    }

    override func tearDownWithError() throws {
        app?.terminate()
        try? FileManager.default.removeItem(at: root)
        UITestHarness.cleanUp(defaultsSuiteName: defaultsSuiteName)
    }

    func testPersistedConversationLoadsIntoChat() {
        UITestHarness.clickSidebar("sidebar.ask", in: app)

        // The seeded conversation appears in the history list…
        let conversation = conversationButton(conversationID)
        XCTAssertTrue(conversation.waitForExistence(timeout: 6),
                      "seeded conversation title missing from the chat history list")
        XCTAssertTrue(conversation.label.localizedCaseInsensitiveContains(conversationTitle),
                      "seeded conversation row did not expose its title")

        // …and the most-recent conversation opens, rendering its messages.
        XCTAssertTrue(text(containing: assistantLine).waitForExistence(timeout: 6),
                      "seeded assistant message missing from the transcript")

        // The new-chat affordance is present in the history column.
        let newQuestion = app.buttons.matching(NSPredicate(
            format: "identifier == %@ OR label == %@", "chat.new", "New Question"
        )).firstMatch
        XCTAssertTrue(newQuestion.waitForExistence(timeout: 4),
                      "new-chat button missing")
        let questionSearch = app.textFields.matching(NSPredicate(
            format: "identifier == %@ OR placeholderValue == %@",
            "chat.history.search", "Search questions"
        )).firstMatch
        XCTAssertTrue(questionSearch.waitForExistence(timeout: 4),
                      "question search should live inside the history column")
    }

    func testSelectingConversationClearsActiveSearch() {
        UITestHarness.clickSidebar("sidebar.ask", in: app)

        XCTAssertTrue(app.descendants(matching: .any)["ask.sources"]
            .waitForExistence(timeout: 4), "source filter menu missing")
        let field = app.textFields["search.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 6), "ask search field missing")
        field.click()
        field.typeText("a query that would otherwise mask the transcript")
        XCTAssertTrue(app.descendants(matching: .any)["ask.submit"]
            .waitForExistence(timeout: 4), "keyword results did not appear")

        let older = conversationButton(olderConversationID)
        XCTAssertTrue(older.waitForExistence(timeout: 4), "older conversation missing")
        XCTAssertTrue(older.label.localizedCaseInsensitiveContains(olderConversationTitle),
                      "older conversation row did not expose its title")
        older.click()

        XCTAssertTrue(text(containing: olderAssistantLine).waitForExistence(timeout: 6),
                      "selected conversation remained hidden behind the old search query")
        XCTAssertEqual(field.value as? String, "", "conversation selection did not clear search")

        field.click(); field.typeText("another search")
        older.click()
        XCTAssertTrue(app.buttons["ask.submit"].waitForExistence(timeout: 4))
        XCTAssertEqual(field.value as? String, "", "Selecting the current conversation must open it too")
        XCTAssertTrue(text(containing: olderAssistantLine).exists)

        app.buttons["chat.new"].click()
        field.click(); field.typeText("unsent search")
        app.buttons["chat.new"].click()
        XCTAssertTrue(app.buttons["ask.submit"].waitForExistence(timeout: 4))
        XCTAssertEqual(field.value as? String, "", "New Question must open Ask even when already empty")
    }

    private func text(containing fragment: String) -> XCUIElement {
        app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] %@ OR value CONTAINS[c] %@",
                        fragment, fragment)).firstMatch
    }

    private func conversationButton(_ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == %@", "chat.conversation.\(id)"))
            .firstMatch
    }

    /// Write one conversation JSON in exactly the shape `ChatStore` decodes
    /// (per-conversation file, ISO-8601 dates, `role` raw values).
    private func seedConversation() throws {
        let chats = root.appendingPathComponent("chats", isDirectory: true)
        try FileManager.default.createDirectory(at: chats, withIntermediateDirectories: true)
        let formatter = ISO8601DateFormatter()
        let now = Date()
        let latest = """
        {
          "id": "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA",
          "title": "\(conversationTitle)",
          "createdAt": "\(formatter.string(from: now))",
          "updatedAt": "\(formatter.string(from: now))",
          "messages": [
            { "id": "11111111-1111-4111-8111-111111111111", "role": "user", "text": "What did we decide on pricing?" },
            { "id": "22222222-2222-4222-8222-222222222222", "role": "assistant", "text": "\(assistantLine)" }
          ]
        }
        """
        let older = """
        {
          "id": "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB",
          "title": "\(olderConversationTitle)",
          "createdAt": "\(formatter.string(from: now.addingTimeInterval(-3_600)))",
          "updatedAt": "\(formatter.string(from: now.addingTimeInterval(-3_600)))",
          "messages": [
            { "id": "33333333-3333-4333-8333-333333333333", "role": "user", "text": "When do we launch?" },
            { "id": "44444444-4444-4444-8444-444444444444", "role": "assistant", "text": "\(olderAssistantLine)" }
          ]
        }
        """
        try latest.write(
            to: chats.appendingPathComponent("AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA.json"),
            atomically: true,
            encoding: .utf8)
        try older.write(
            to: chats.appendingPathComponent("BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB.json"),
            atomically: true,
            encoding: .utf8)
    }
}
