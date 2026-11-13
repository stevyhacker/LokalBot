import XCTest
@testable import LokalBot

final class AnthropicEngineTests: XCTestCase {
    private actor Recorder {
        var bodies: [[String: Any]] = []
        func record(_ request: URLRequest) -> Int {
            let body = request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            bodies.append(body ?? [:])
            return bodies.count
        }
    }

    private func engine(_ model: String = "claude-sonnet-5-5", level: ThinkReasoningLevel = .automatic,
                        transport: AnthropicEngine.Transport? = nil) -> AnthropicEngine {
        AnthropicEngine(baseURL: URL(string: "https://api.anthropic.com/v1")!, model: model,
                        apiKey: "sk-ant-test", reasoningLevel: level, transport: transport)
    }

    private func body(_ request: URLRequest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
    }

    private func json(_ object: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }

    private static func response(_ request: URLRequest, status: Int, headers: [String: String]? = nil) -> URLResponse {
        HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
    }

    func testRequestUsesMessagesAPIWithCacheBreakpointsAfterSharedMaterial() throws {
        for base in ["https://api.anthropic.com", "https://api.anthropic.com/v1", "https://api.anthropic.com/v1/"] {
            var claude = engine()
            claude.baseURL = URL(string: base)!
            let request = try claude.makeRequest(system: "S", prompt: "P", context: [], schema: nil, options: nil)
            XCTAssertEqual(request.url?.absoluteString, "https://api.anthropic.com/v1/messages", base)
        }

        let request = try engine().makeRequest(
            system: "System", prompt: "Question", context: ["Transcript", "  ", "History"],
            schema: nil, options: .init(maxTokens: 900, temperature: 0.2))
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "sk-ant-test")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))

        let body = try body(request)
        XCTAssertEqual(body["model"] as? String, "claude-sonnet-5-5")
        // Current Claude models reject non-default sampling.
        XCTAssertNil(body["temperature"])
        XCTAssertNil(body["thinking"])
        let system = try XCTUnwrap(body["system"] as? [[String: Any]])
        XCTAssertEqual(system.count, 1)
        XCTAssertEqual(system[0]["text"] as? String, "System")
        XCTAssertEqual(system[0]["cache_control"] as? [String: String], ["type": "ephemeral"])

        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0]["role"] as? String, "user")
        let blocks = try XCTUnwrap(messages[0]["content"] as? [[String: Any]])
        XCTAssertEqual(blocks.map { $0["text"] as? String }, ["Transcript", "History", "Question"])
        XCTAssertNil(blocks[0]["cache_control"])
        XCTAssertEqual(blocks[1]["cache_control"] as? [String: String], ["type": "ephemeral"])
        XCTAssertNil(blocks[2]["cache_control"], "the varying instruction must not end the cached prefix")

        let bare = try self.body(engine().makeRequest(system: "", prompt: "Only", context: [], schema: nil, options: nil))
        XCTAssertNil(bare["system"])
        let bareBlocks = (bare["messages"] as? [[String: Any]])?.first?["content"] as? [[String: Any]]
        XCTAssertEqual(bareBlocks?.count, 1)
        XCTAssertNil(bareBlocks?.first?["cache_control"])
    }

    func testStructuredOutputMovesUnsupportedConstraintsIntoDescriptions() throws {
        let schema: [String: Any] = [
            "type": "object", "required": ["items", "when"],
            "properties": [
                "items": ["type": "array", "maxItems": 4, "minItems": 2,
                          "items": ["type": "string", "minLength": 1, "maxLength": 80, "description": "One item."]],
                "when": ["type": "string", "format": "regex", "pattern": "^[0-9]+$"],
                "kind": ["type": "string", "format": "date", "enum": ["a", "b"]],
            ],
        ]
        let request = try engine().makeRequest(system: "S", prompt: "P", context: [], schema: schema, options: nil)
        let output = try XCTUnwrap(body(request)["output_config"] as? [String: Any])
        let format = try XCTUnwrap(output["format"] as? [String: Any])
        XCTAssertEqual(format["type"] as? String, "json_schema")
        let wire = try XCTUnwrap(format["schema"] as? [String: Any])
        XCTAssertEqual(wire["additionalProperties"] as? Bool, false)
        let properties = try XCTUnwrap(wire["properties"] as? [String: Any])
        let items = try XCTUnwrap(properties["items"] as? [String: Any])
        XCTAssertNil(items["maxItems"])
        XCTAssertEqual(items["minItems"] as? Int, 1)
        XCTAssertEqual(items["description"] as? String, "{maxItems: 4, minItems: 2}")
        let item = try XCTUnwrap(items["items"] as? [String: Any])
        XCTAssertNil(item["maxLength"])
        XCTAssertEqual(item["description"] as? String, "One item. {maxLength: 80, minLength: 1}")
        let when = try XCTUnwrap(properties["when"] as? [String: Any])
        XCTAssertNil(when["format"])
        XCTAssertEqual(when["pattern"] as? String, "^[0-9]+$")
        let kind = try XCTUnwrap(properties["kind"] as? [String: Any])
        XCTAssertEqual(kind["format"] as? String, "date")
        XCTAssertNil(kind["description"])
    }

    /// Anthropic's OpenAI compatibility layer rejected meeting notes with
    /// "For 'array' type, property 'maxItems' is not supported" (2026-10-08).
    func testMeetingNotesSchemaFitsAnthropicsSubset() {
        let units = [
            MeetingNotesEvidence.Unit(source: "s1", speaker: "p1", text: "We ship the release on Friday."),
            MeetingNotesEvidence.Unit(source: "s2", speaker: "p2", text: "I'll write the release notes."),
        ]
        let schema = MeetingNotesEvidence.schema(units: units, speakers: ["p1", "p2"], template: .meeting,
                                                 maximumNotes: 6, maximumActions: 4)
        XCTAssertTrue(Self.unsupportedKeywords(in: schema).contains("maxItems"), "the fixture must exercise the adapter")
        XCTAssertEqual(Self.unsupportedKeywords(in: AnthropicSchema.adapt(schema)), [])
    }

    private static func unsupportedKeywords(in node: Any) -> Set<String> {
        if let array = node as? [Any] {
            var found: Set<String> = []
            for element in array { found.formUnion(unsupportedKeywords(in: element)) }
            return found
        }
        guard let object = node as? [String: Any] else { return [] }
        var found = Set(object.keys).intersection(AnthropicSchema.unsupportedKeywords)
        if let minItems = object["minItems"] as? Int, minItems > 1 { found.insert("minItems") }
        if object["type"] as? String == "object", object["additionalProperties"] as? Bool != false {
            found.insert("additionalProperties")
        }
        if let format = object["format"] as? String, !AnthropicSchema.formats.contains(format) { found.insert("format") }
        for (key, value) in object where !["enum", "required", "description"].contains(key) {
            found.formUnion(unsupportedKeywords(in: value))
        }
        return found
    }

    func testEffortFollowsTaskBudgetAndChosenLevel() throws {
        let sonnet = engine()
        XCTAssertNil(sonnet.effort(for: nil), "Automatic leaves interactive requests at the model default")
        XCTAssertEqual(sonnet.effort(for: .init(reasoningBudgetTokens: 0)), .low)
        XCTAssertEqual(sonnet.effort(for: .init(reasoningBudgetTokens: 4_096)), .medium)
        XCTAssertEqual(engine(level: .xhigh).effort(for: nil), .xhigh)
        XCTAssertEqual(engine(level: .max).effort(for: .init(reasoningBudgetTokens: 0)), .low)
        XCTAssertEqual(engine("claude-opus-4-6", level: .xhigh).effort(for: nil), .high)
        XCTAssertNil(engine("claude-haiku-4-5", level: .high).effort(for: .init(reasoningBudgetTokens: 0)))
        // Opus 4.8 does not think unless asked, so Automatic leaves it alone.
        XCTAssertNil(engine("claude-opus-4-8").effort(for: .init(reasoningBudgetTokens: 0)))

        let notes = try body(sonnet.makeRequest(system: "S", prompt: "P", context: [], schema: nil,
                                                options: .init(maxTokens: 4_096, reasoningBudgetTokens: 0)))
        XCTAssertEqual((notes["output_config"] as? [String: Any])?["effort"] as? String, "low")
        XCTAssertEqual(notes["max_tokens"] as? Int, 4_096 + 4_096, "thinking shares max_tokens with the answer")

        let plain = try body(engine("claude-haiku-4-5").makeRequest(system: "S", prompt: "P", context: [], schema: nil,
                                                                    options: .init(maxTokens: 4_096, reasoningBudgetTokens: 0)))
        XCTAssertNil(plain["output_config"])
        XCTAssertEqual(plain["max_tokens"] as? Int, 4_096)
    }

    func testMaxTokensStayWithinTheResponseWindow() {
        let sonnet = engine()
        XCTAssertEqual(sonnet.maxTokens(requested: nil, effort: nil, streaming: false),
                       AnthropicEngine.maximumWholeResponseTokens)
        XCTAssertEqual(sonnet.maxTokens(requested: nil, effort: nil, streaming: true), 8_192 + 16_384)
        XCTAssertEqual(sonnet.maxTokens(requested: 900, effort: .medium, streaming: false), 900 + 8_192)
    }

    func testServerFallbackOnlyForModelsThatAcceptIt() throws {
        for model in ["claude-sonnet-5-5", "claude-opus-5-5", "claude-opus-5", "claude-fable-5-1"] {
            let request = try engine(model).makeRequest(system: "S", prompt: "P", context: [], schema: nil, options: nil)
            XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-beta"), "server-side-fallback-2026-07-01", model)
            XCTAssertEqual(try body(request)["fallbacks"] as? String, "default", model)
        }
        for model in ["claude-haiku-5-5", "claude-sonnet-5", "claude-sonnet-4-6", "claude-haiku-4-5"] {
            let request = try engine(model).makeRequest(system: "S", prompt: "P", context: [], schema: nil, options: nil)
            XCTAssertNil(request.value(forHTTPHeaderField: "anthropic-beta"), model)
            XCTAssertNil(try body(request)["fallbacks"], model)
        }
    }

    func testRepliesJoinTextBlocksAndReportCacheUse() throws {
        let reply = try AnthropicEngine.parseMessage(json([
            "type": "message",
            "content": [
                ["type": "thinking", "thinking": "", "signature": "sig"],
                ["type": "text", "text": "{\"a\":"],
                ["type": "fallback", "from": ["model": "claude-sonnet-5-5"], "to": ["model": "claude-sonnet-5"]],
                ["type": "text", "text": "1}"],
            ],
            "stop_reason": "end_turn",
            "usage": ["input_tokens": 12, "cache_creation_input_tokens": 0,
                      "cache_read_input_tokens": 3_000, "output_tokens": 40],
        ]))
        XCTAssertEqual(reply.text, "{\"a\":1}")
        XCTAssertFalse(reply.truncated)
        XCTAssertEqual(reply.usage?.promptTokens, 3_012)
        XCTAssertEqual(reply.usage?.cacheReadTokens, 3_000)
        XCTAssertEqual(reply.usage?.outputTokens, 40)

        let cut = try AnthropicEngine.parseMessage(json([
            "content": [["type": "text", "text": "par"]], "stop_reason": "max_tokens",
        ]))
        XCTAssertTrue(cut.truncated)

        XCTAssertThrowsError(try AnthropicEngine.parseMessage(json([
            "content": [], "stop_reason": "refusal",
            "stop_details": ["type": "refusal", "category": "cyber", "explanation": "Declined."],
        ]))) { error in
            XCTAssertTrue(error.localizedDescription.contains("model refusal"), error.localizedDescription)
            XCTAssertTrue(error.localizedDescription.contains("cyber"), error.localizedDescription)
        }
        XCTAssertThrowsError(try AnthropicEngine.parseMessage(json(["content": [], "stop_reason": "end_turn"])))
    }

    func testStreamLinesYieldTextUsageAndStop() {
        XCTAssertNil(AnthropicEngine.parseStreamLine("event: content_block_delta"))
        XCTAssertNil(AnthropicEngine.parseStreamLine(#"data: {"type":"ping"}"#))
        XCTAssertEqual(
            AnthropicEngine.parseStreamLine(#"data: {"type":"message_start","message":{"usage":{"input_tokens":5,"cache_read_input_tokens":900}}}"#),
            .usage(["input_tokens": 5, "cache_read_input_tokens": 900]))
        XCTAssertEqual(
            AnthropicEngine.parseStreamLine(#"data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Hi"}}"#),
            .text("Hi"))
        XCTAssertNil(AnthropicEngine.parseStreamLine(
            #"data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"x"}}"#))
        XCTAssertEqual(
            AnthropicEngine.parseStreamLine(#"data: {"type":"message_delta","delta":{"stop_reason":"refusal","stop_details":{"type":"refusal","category":"bio","explanation":null}},"usage":{"output_tokens":3}}"#),
            .stop(reason: "refusal", details: ["type": "refusal", "category": "bio"], usage: ["output_tokens": 3]))
        XCTAssertEqual(AnthropicEngine.parseStreamLine(#"data: {"type":"message_stop"}"#), .done)
        XCTAssertEqual(
            AnthropicEngine.parseStreamLine(#"data: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#),
            .failure("Overloaded"))
    }

    func testRejectedEffortRetriesOnceWithoutIt() async throws {
        let recorder = Recorder()
        let reply = json(["content": [["type": "text", "text": "ok"]], "stop_reason": "end_turn",
                          "usage": ["input_tokens": 3, "output_tokens": 1]])
        let rejection = json(["type": "error", "error": [
            "type": "invalid_request_error", "message": "output_config.effort: 'low' is not supported for this model",
        ]])
        let claude = engine(transport: { request in
            if await recorder.record(request) == 1 {
                return (rejection, Self.response(request, status: 400))
            }
            return (reply, Self.response(request, status: 200))
        })

        let text = try await claude.generate(system: "S", prompt: "P", context: [],
                                             options: .init(maxTokens: 512, reasoningBudgetTokens: 0))
        XCTAssertEqual(text, "ok")
        let bodies = await recorder.bodies
        XCTAssertEqual(bodies.count, 2)
        XCTAssertEqual((bodies[0]["output_config"] as? [String: Any])?["effort"] as? String, "low")
        XCTAssertNil(bodies[1]["output_config"])
        XCTAssertEqual(bodies[1]["fallbacks"] as? String, "default", "only the rejected field is dropped")
    }

    /// A schema rejection is not permission to weaken structured output.
    func testOtherRejectionsAreReportedWithAnthropicsRequestID() async {
        let recorder = Recorder()
        let rejection = json(["type": "error", "error": [
            "type": "invalid_request_error", "message": "output_config.format.schema: Schema is too complex for compilation",
        ]])
        let claude = engine(transport: { request in
            _ = await recorder.record(request)
            return (rejection, Self.response(request, status: 400, headers: ["request-id": "req_011"]))
        })
        do {
            _ = try await claude.generate(system: "S", prompt: "P", context: [],
                                          schema: ["type": "object", "properties": [:], "required": []])
            XCTFail("a rejected schema must surface")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("HTTP 400"), error.localizedDescription)
            XCTAssertTrue(error.localizedDescription.contains("(request ID: req_011)"), error.localizedDescription)
        }
        let count = await recorder.bodies.count
        XCTAssertEqual(count, 1)
    }

    func testClaudeModelsPublishEffortLevelsAndWindows() {
        let url = URL(string: "https://api.anthropic.com/v1")!
        let provider = ReasoningSupport.Provider(dialect: .inferred(from: url), baseURL: url)
        XCTAssertEqual(provider, .anthropic)
        XCTAssertEqual(ReasoningSupport.known(provider: provider, model: "claude-sonnet-5-5"),
                       ReasoningSupport(levels: [.low, .medium, .high, .xhigh, .max], defaultLevel: .high))
        XCTAssertEqual(ReasoningSupport.known(provider: provider, model: "claude-opus-5-5").defaultLevel, .medium)
        XCTAssertEqual(ReasoningSupport.known(provider: provider, model: "claude-opus-4-6").levels, [.low, .medium, .high, .max])
        XCTAssertFalse(ReasoningSupport.known(provider: provider, model: "claude-haiku-4-5").isAdjustable)

        XCTAssertEqual(MeetingSummaryGenerator.documentedContextTokens(provider: provider, model: "claude-sonnet-5-5"), 1_000_000)
        XCTAssertEqual(MeetingSummaryGenerator.documentedContextTokens(provider: provider, model: "claude-haiku-4-5"), 200_000)
        XCTAssertEqual(MeetingSummaryGenerator.documentedContextTokens(provider: provider, model: "claude-sonnet-4-20250514"), 200_000)
        XCTAssertNil(MeetingSummaryGenerator.documentedContextTokens(provider: provider, model: "claude-3-5-haiku-latest"))

        var settings = AppSettings()
        settings.summarizerBackend = .openAICompatible
        settings.openAIBaseURL = url.absoluteString
        settings.openAIModel = "claude-sonnet-5-5"
        XCTAssertEqual(MeetingSummaryGenerator.contextTokenLimit(for: settings), 1_000_000)
    }

    @MainActor
    func testAnthropicURLSelectsNativeEngineAndAgentKeepsCompatibilityEndpoint() async throws {
        let execution = ThinkExecution(storage: StorageManager())
        var settings = AppSettings()
        settings.summarizerBackend = .openAICompatible
        settings.openAIBaseURL = "https://api.anthropic.com"
        settings.openAIModel = "claude-sonnet-5-5"
        settings.approvedRemoteInferenceOrigins = ["https://api.anthropic.com"]
        settings.thinkReasoningLevel = .medium

        let engine = try await execution.makeTextEngine(
            settings, includingCredentials: false, priority: .pipeline, purpose: "meeting notes")
        let gated = try XCTUnwrap(engine as? GatedTextEngine)
        XCTAssertEqual(gated.origin, "https://api.anthropic.com")
        let claude = try XCTUnwrap(gated.base as? AnthropicEngine)
        XCTAssertEqual(claude.model, "claude-sonnet-5-5")
        XCTAssertNil(claude.apiKey)
        XCTAssertEqual(claude.reasoningLevel, .medium)
        XCTAssertTrue(ChatPrompt.inferencePrivacy(for: engine).contains("api.anthropic.com"))

        guard case .ready(let endpoint) = ThinkExecution.agentResolution(
            settings: settings, includingCredentials: false) else {
            return XCTFail("expected a ready Agent endpoint")
        }
        XCTAssertEqual(endpoint.baseURL.absoluteString, "https://api.anthropic.com/v1")

        settings.approvedRemoteInferenceOrigins = []
        do {
            _ = try await execution.makeTextEngine(settings, includingCredentials: false)
            XCTFail("an unapproved Anthropic origin must not receive context")
        } catch InferenceEndpointPolicy.PolicyError.remoteApprovalRequired {}
    }
}
