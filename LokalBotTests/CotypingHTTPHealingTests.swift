import XCTest
@testable import LokalBot

@MainActor
final class CotypingHTTPHealingTests: XCTestCase {
    private final class RecordingCompletionEngine: TextEngine, @unchecked Sendable {
        var displayName: String { "recording" }
        let reply: String
        var requests: [CompletionRequest] = []

        init(reply: String) { self.reply = reply }

        func generate(system: String, prompt: String, context: [String]) async throws -> String { "" }

        func complete(_ request: CompletionRequest) async throws -> String {
            requests.append(request)
            return reply
        }
    }

    private func request(typing text: String) throws -> CotypingRequest {
        let field = CotypingField(
            appName: "Notes", bundleID: "com.apple.Notes", processID: 0, role: "AXTextArea",
            precedingText: text, trailingText: "", selectionLength: 0,
            caretRect: .zero, isSecure: false, caretIsExact: true)
        return try XCTUnwrap(CotypingRequestBuilder.build(
            field: field, config: .standard, personalization: .none, generation: 1))
    }

    func testHealedPromptDropsTheTrailingSpaceAndOutputMustRetypeIt() async throws {
        let request = try request(typing: "Let's celebrate ")
        let server = RecordingCompletionEngine(reply: " this weekend")
        let result = try await CotypingEngine(makeEngine: { server }, healsCaretBoundary: true).generate(request)

        XCTAssertEqual(server.requests.first?.prompt, String(request.prompt.dropLast()))
        XCTAssertEqual(server.requests.first?.maxTokens, request.maxTokens)
        XCTAssertEqual(result.text, "this weekend")
        XCTAssertNil(result.suppression)
    }

    func testOutputThatSkipsTheHealedBoundaryIsSuppressed() async throws {
        let request = try request(typing: "Let's celebrate ")
        let server = RecordingCompletionEngine(reply: "d it")
        let result = try await CotypingEngine(makeEngine: { server }, healsCaretBoundary: true).generate(request)

        XCTAssertEqual(result.text, "")
        XCTAssertEqual(result.suppression, .wordCompletionMismatch)
    }

    func testMidWordFragmentIsRetypedThenExtended() async throws {
        let request = try request(typing: "I wanted to follo")
        let server = RecordingCompletionEngine(reply: " following up")
        let result = try await CotypingEngine(makeEngine: { server }, healsCaretBoundary: true).generate(request)

        XCTAssertEqual(server.requests.first?.prompt, String(request.prompt.dropLast(" follo".count)))
        XCTAssertEqual(server.requests.first?.maxTokens, request.maxTokens + 4)
        XCTAssertTrue(result.text.hasPrefix("wing"), result.text)
    }

    func testWithoutHealingThePromptIsSentByteForByte() async throws {
        let request = try request(typing: "Let's celebrate ")
        let server = RecordingCompletionEngine(reply: "this weekend")
        let result = try await CotypingEngine(makeEngine: { server }).generate(request)

        XCTAssertEqual(server.requests.first?.prompt, request.prompt)
        XCTAssertEqual(result.text, "this weekend")
    }
}
