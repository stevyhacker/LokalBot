import XCTest
@testable import LokalBot

/// Chat models often leave out the space before a new word. The replies here
/// are what OpenRouter returned on 2026-10-15 for the rehearsal text.
@MainActor
final class CotypingChatReplySpacingTests: XCTestCase {
    private final class ChatReply: TextEngine, @unchecked Sendable {
        var displayName: String { "chat" }
        let reply: String

        init(_ reply: String) { self.reply = reply }

        func generate(system: String, prompt: String, context: [String]) async throws -> String { reply }
        func complete(_ request: CompletionRequest) async throws -> String { reply }
    }

    func testAReplyAfterAWholeWordGetsItsSpaceBack() async throws {
        let request = try request(typing: "Hi Sarah, thanks for the update. I wanted to follow")
        let engine = CotypingEngine(makeEngine: { ChatReply("up and confirm that Thursday works") },
                                    restoresWordSpace: true)

        let result = try await engine.generate(request)

        XCTAssertTrue(result.text.hasPrefix(" up and confirm"), result.text)
    }

    func testAOneLetterWordIsAWholeWord() throws {
        let request = try request(typing: "It doesn't seem to be working at a")

        XCTAssertEqual(CotypingEngine.restoringWordSpace("higher level", for: request), " higher level")
    }

    func testRepliesThatContinueTheTextAsTheyAreAreLeftAlone() throws {
        let request = try request(typing: "I wanted to follow")
        XCTAssertEqual(CotypingEngine.restoringWordSpace(" up on the cutover", for: request), " up on the cutover")
        XCTAssertEqual(CotypingEngine.restoringWordSpace("follow up on", for: request), "follow up on",
                       "the normalizer drops the restated word")
        XCTAssertEqual(CotypingEngine.restoringWordSpace(", and the cutover", for: request), ", and the cutover")

        let fragment = try self.request(typing: "I wanted to follo", wordPrefixIsValidWord: false)
        XCTAssertEqual(CotypingEngine.restoringWordSpace("w up on", for: fragment), "w up on")

        let chinese = try self.request(typing: "我想跟进")
        XCTAssertEqual(CotypingEngine.restoringWordSpace("一下进度", for: chinese), "一下进度")
    }

    func testRawCompletionsKeepTheirOwnSpacing() async throws {
        let request = try request(typing: "I wanted to follow")
        let engine = CotypingEngine(makeEngine: { ChatReply("ing up") })

        let result = try await engine.generate(request)

        XCTAssertFalse(result.text.hasPrefix(" "), result.text)
    }

    private func request(typing text: String, wordPrefixIsValidWord: Bool = true) throws -> CotypingRequest {
        let field = CotypingField(
            appName: "Mail", bundleID: "com.apple.mail", processID: 0, role: "AXTextArea",
            precedingText: text, trailingText: "", selectionLength: 0,
            caretRect: .zero, isSecure: false, caretIsExact: true)
        return try XCTUnwrap(CotypingRequestBuilder.build(
            field: field, config: .standard, personalization: .none, generation: 1,
            wordPrefixIsValidWord: wordPrefixIsValidWord))
    }
}
