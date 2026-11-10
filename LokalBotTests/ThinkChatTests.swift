import XCTest
@testable import LokalBot

/// The bridge from chat messages and function tools to the Think engines,
/// which take a system prompt, a prompt and context and return text.
final class ThinkChatTests: XCTestCase {
    private let tools: [[String: Any]] = [
        LiveAnswerTools.function(
            "search_code", "Search a repository.",
            ["repository": ["type": "string", "enum": ["Widget"]],
             "query": ["type": "string", "description": "Words to find."],
             "path": ["type": "string"]],
            required: ["repository", "query"]),
        LiveAnswerTools.function(
            "answer", "The answer.",
            ["text": ["type": "string"],
             "sources": ["type": "array", "items": [
                "type": "object",
                "properties": ["id": ["type": "string"], "quote": ["type": "string"]],
                "required": ["id", "quote"]] as [String: Any]]],
            required: ["text", "sources"]),
    ]

    private func object(_ text: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    // MARK: - Messages

    func testAStructuredRequestKeepsItsSystemAndPrompt() {
        let request = ThinkChat.request(
            messages: [["role": "system", "content": "Read the meeting."],
                       ["role": "user", "content": "NEW LINES:\n[L1 00:04] Me: hello"]],
            tools: [])
        XCTAssertEqual(request.system, "Read the meeting.")
        XCTAssertEqual(request.prompt, "NEW LINES:\n[L1 00:04] Me: hello")
        XCTAssertTrue(request.context.isEmpty)
    }

    func testAToolLoopPutsTheTaskFirstAndEachCallBeforeWhatItReturned() throws {
        let call: [String: Any] = ["id": "call_0", "type": "function",
                                   "function": ["name": "search_code",
                                                "arguments": #"{"repository":"Widget","query":"panel"}"#]]
        var messages: [[String: Any]] = [
            ["role": "system", "content": "Find the answer."],
            ["role": "user", "content": "QUESTION: Is the panel hidden?"],
            ["role": "assistant", "content": "", "tool_calls": [call]],
            ["role": "tool", "tool_call_id": "call_0", "content": "[R1] Widget\nPanel.swift:2: let hidden = true"],
        ]
        var request = ThinkChat.request(messages: messages, tools: tools)
        XCTAssertTrue(request.system.hasPrefix("Find the answer.\n\nTOOLS\n"))
        XCTAssertTrue(request.system.contains(ThinkChat.callFormat))
        XCTAssertTrue(request.system.contains("search_code: Search a repository."))
        XCTAssertTrue(request.system.contains("  - repository (string, one of: Widget)"))
        XCTAssertTrue(request.system.contains("  - query (string): Words to find."))
        XCTAssertTrue(request.system.contains("  - path (string, optional)"))
        XCTAssertEqual(request.prompt, ThinkChat.nextCall)
        XCTAssertEqual(request.context.count, 3)
        XCTAssertEqual(request.context[0], "QUESTION: Is the panel hidden?")
        let made = try object(String(request.context[1].dropFirst("Assistant: ".count)))
        let inner = try XCTUnwrap(made["call"] as? [String: Any])
        XCTAssertEqual(inner["tool"] as? String, "search_code")
        XCTAssertEqual((inner["arguments"] as? [String: Any])?["query"] as? String, "panel")
        XCTAssertEqual(request.context[2], "Observation: [R1] Widget\nPanel.swift:2: let hidden = true")

        // A later user message, such as the last turn's nudge, is what is asked.
        messages.append(["role": "user", "content": "Answer now with what you have read, or call no_answer."])
        request = ThinkChat.request(messages: messages, tools: tools)
        XCTAssertEqual(request.prompt, "Answer now with what you have read, or call no_answer.")
        XCTAssertEqual(request.context.count, 3)
    }

    // MARK: - Schema

    func testTheSchemaOffersOneCallPerToolAndClosesEveryObject() throws {
        let schema = ThinkChat.toolCallSchema(tools)
        XCTAssertEqual(schema["required"] as? [String], ["call"])
        XCTAssertEqual(schema["additionalProperties"] as? Bool, false)
        let variants = try XCTUnwrap((schema["properties"] as? [String: Any])?["call"] as? [String: Any])["anyOf"] as? [[String: Any]]
        XCTAssertEqual(variants?.count, 2)

        let search = try XCTUnwrap(variants?.first?["properties"] as? [String: Any])
        XCTAssertEqual((search["tool"] as? [String: Any])?["enum"] as? [String], ["search_code"])
        let arguments = try XCTUnwrap(search["arguments"] as? [String: Any])
        XCTAssertEqual(arguments["additionalProperties"] as? Bool, false)
        XCTAssertEqual(arguments["required"] as? [String], ["path", "query", "repository"],
                       "strict output lists every property as required")
        let properties = try XCTUnwrap(arguments["properties"] as? [String: Any])
        XCTAssertEqual((properties["query"] as? [String: Any])?["type"] as? String, "string")
        XCTAssertEqual((properties["path"] as? [String: Any])?["type"] as? [String], ["string", "null"],
                       "an optional argument may be null instead of left out")

        let answer = try XCTUnwrap((variants?.last?["properties"] as? [String: Any])?["arguments"] as? [String: Any])
        let sources = try XCTUnwrap((answer["properties"] as? [String: Any])?["sources"] as? [String: Any])
        let item = try XCTUnwrap(sources["items"] as? [String: Any])
        XCTAssertEqual(item["additionalProperties"] as? Bool, false, "objects inside arrays are closed too")
        XCTAssertEqual(item["required"] as? [String], ["id", "quote"])
    }

    func testAnOptionalChoiceMayBeNull() throws {
        let strict = ThinkChat.strict(["type": "object", "required": [String](),
                                       "properties": ["kind": ["type": "string", "enum": ["a", "b"]]]])
        let kind = try XCTUnwrap((strict["properties"] as? [String: Any])?["kind"] as? [String: Any])
        XCTAssertEqual(kind["type"] as? [String], ["string", "null"])
        let values = try XCTUnwrap(kind["enum"] as? [Any])
        XCTAssertEqual(values.count, 3)
        XCTAssertTrue(values.last is NSNull)
    }

    // MARK: - Reading a call

    func testACallIsReadFromProseAFenceOrABareObject() throws {
        let names: Set<String> = ["search_code", "answer"]
        let wrapped = "Let me look.\n```json\n{\"call\": {\"tool\": \"search_code\", \"arguments\": "
            + "{\"repository\": \"Widget\", \"query\": \"panel\", \"path\": null}}}\n```"
        let call = try XCTUnwrap(ThinkChat.toolCall(in: wrapped, names: names, id: "call_3"))
        XCTAssertEqual(call.id, "call_3")
        XCTAssertEqual(call.name, "search_code")
        XCTAssertEqual(call.decodedArguments["query"] as? String, "panel")
        XCTAssertNil(call.decodedArguments["path"], "an argument given as null is left out")

        let bare = try XCTUnwrap(ThinkChat.toolCall(
            in: #"{"tool": "answer", "arguments": {"text": "Yes.", "sources": [{"id": "R1", "quote": "true"}]}}"#,
            names: names, id: "call_0"))
        XCTAssertEqual(bare.name, "answer")
        XCTAssertEqual((bare.decodedArguments["sources"] as? [[String: Any]])?.first?["id"] as? String, "R1")

        let asText = try XCTUnwrap(ThinkChat.toolCall(
            in: #"{"call": {"name": "search_code", "arguments": "{\"repository\": \"Widget\", \"query\": \"x\"}"}}"#,
            names: names, id: "call_0"))
        XCTAssertEqual(asText.decodedArguments["query"] as? String, "x", "arguments sent as a JSON string are read")

        XCTAssertNil(ThinkChat.toolCall(in: #"{"call": {"tool": "delete_everything", "arguments": {}}}"#,
                                        names: names, id: "call_0"), "only the offered tools can be called")
        XCTAssertNil(ThinkChat.toolCall(in: "I don't know.", names: names, id: "call_0"))
    }

    // MARK: - Asking the engine

    func testAReplyThatIsNotACallIsAskedForOnceMore() async throws {
        let messages: [[String: Any]] = [["role": "system", "content": "Find the answer."],
                                         ["role": "user", "content": "QUESTION: Is the panel hidden?"]]
        let options = TextGenerationOptions(maxTokens: 100)

        let recovers = RadarThinkEngine(replies: [
            "I would search the code first.",
            #"{"call": {"tool": "search_code", "arguments": {"repository": "Widget", "query": "panel"}}}"#,
        ])
        let reply = try await ThinkChat.toolCall(from: recovers, messages: messages, tools: tools, options: options)
        XCTAssertEqual(reply.toolCalls.map(\.name), ["search_code"])
        XCTAssertEqual(reply.toolCalls.first?.id, "call_0")
        XCTAssertEqual(recovers.requests.count, 2)
        XCTAssertEqual(recovers.requests[0].prompt, ThinkChat.nextCall)
        XCTAssertTrue(recovers.requests[1].prompt.hasSuffix(ThinkChat.retry))
        XCTAssertNotNil(recovers.requests[0].schema?["properties"], "each turn is held to the tool-call schema")
        XCTAssertEqual(recovers.requests[0].options, options)

        let never = RadarThinkEngine(reply: "I can't call tools.")
        let none = try await ThinkChat.toolCall(from: never, messages: messages, tools: tools, options: options)
        XCTAssertTrue(none.toolCalls.isEmpty)
        XCTAssertEqual(none.content, "I can't call tools.")
        XCTAssertEqual(never.requests.count, 2, "it is asked once more, then the loop decides")
    }

    func testAStructuredReplyIsTheObjectInWhateverTheModelWrote() async throws {
        let engine = RadarThinkEngine(reply: "Sure:\n```json\n{\"items\": [], \"answered\": []}\n```")
        let reply = try await ThinkChat.structuredReply(
            from: engine,
            messages: [["role": "system", "content": "Read."], ["role": "user", "content": "NEW LINES: none"]],
            schema: ["type": "object"], options: TextGenerationOptions())
        XCTAssertEqual(reply.content, "{\"items\": [], \"answered\": []}")
        XCTAssertTrue(reply.toolCalls.isEmpty)
        XCTAssertEqual(reply.usage, MuseChatClient.Usage(), "the Think engines report no token use")
        XCTAssertEqual(engine.requests.first?.system, "Read.")
        XCTAssertEqual(engine.requests.first?.prompt, "NEW LINES: none")
    }
}
