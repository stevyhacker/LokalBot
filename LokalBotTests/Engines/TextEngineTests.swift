import XCTest
@testable import LokalBot

final class TextEngineTests: XCTestCase {
    func testStructuredRequestBodyHasAStableKeyOrder() throws {
        let engine = OpenAICompatibleEngine(baseURL: URL(string: "http://127.0.0.1:18781/v1")!, model: "synthetic")
        let schema: [String: Any] = ["type": "object", "properties": [
            "verdict": ["type": "string"], "issues": ["type": "array", "items": ["type": "string"]],
            "evidence_check": ["type": "string"]], "required": ["evidence_check", "verdict", "issues"]]
        let request = try engine.makeChatRequest(system: "s", prompt: "q", context: [], schema: schema,
                                                options: .init(maxTokens: 512, temperature: 0))
        let bytes = try XCTUnwrap(request.httpBody)
        let reencoded = try JSONSerialization.data(withJSONObject: JSONSerialization.jsonObject(with: bytes),
                                                   options: [.sortedKeys])
        XCTAssertEqual(bytes, reencoded, "every object, the schema included, is in sorted key order")
        let text = try XCTUnwrap(String(data: bytes, encoding: .utf8))
        var positions: [String.Index] = []
        for key in ["\"evidence_check\":", "\"issues\":", "\"verdict\":"] {
            positions.append(try XCTUnwrap(text.range(of: key)).lowerBound)
        }
        XCTAssertEqual(positions, positions.sorted())
    }

    func testStrippingReasoningRemovesThinkBlocks() {
        let text = """
        <think>hidden chain</think>
        Visible answer.
        """

        XCTAssertEqual(strippingReasoning(text), "Visible answer.")
    }

    func testStrippingReasoningRemovesMultipleThinkBlocks() {
        let text = "<think>a</think>First\n<think>b</think>Second"

        XCTAssertEqual(strippingReasoning(text), "First\nSecond")
    }

    func testBuiltInModelDefaultGetsThinkingRoomOnTopOfTheAnswer() {
        var body: [String: Any] = [:]

        OpenAICompatibleEngine.applyGenerationOptions(
            to: &body,
            options: TextGenerationOptions(maxTokens: 8_192),
            reasoningAllowance: MainLLMRuntimePolicy.highReasoningBudgetTokens,
            dialect: .llamaServer,
            model: "local")

        XCTAssertEqual(body["max_tokens"] as? Int, 16_384)
        XCTAssertEqual(body["thinking_budget_tokens"] as? Int, 8_192)
        XCTAssertNil(body["chat_template_kwargs"], "a model that thinks by default needs no switch")
    }

    func testBuiltInModelDefaultWithoutOutputLimitCapsOnlyTheThinking() {
        var body: [String: Any] = [:]

        OpenAICompatibleEngine.applyGenerationOptions(
            to: &body,
            options: nil,
            reasoningAllowance: MainLLMRuntimePolicy.highReasoningBudgetTokens,
            dialect: .llamaServer,
            model: "local")

        XCTAssertNil(body["max_tokens"])
        XCTAssertEqual(body["thinking_budget_tokens"] as? Int, 8_192)
    }

    func testBuiltInModelThatDoesNotThinkByDefaultIsToldNotTo() {
        var body: [String: Any] = [:]

        OpenAICompatibleEngine.applyGenerationOptions(
            to: &body,
            options: TextGenerationOptions(maxTokens: 1_024),
            reasoningAllowance: 0,
            templateThinksByDefault: false,
            dialect: .llamaServer,
            model: "gemma4-12b")

        XCTAssertEqual(body["max_tokens"] as? Int, 1_024)
        XCTAssertNil(body["thinking_budget_tokens"])
        XCTAssertEqual((body["chat_template_kwargs"] as? [String: Any])?["enable_thinking"] as? Bool, false,
                       "llama-server turns thinking on for every template that can think unless told otherwise")
    }

    func testChosenLevelTurnsThinkingOnForATemplateThatDefaultsOff() {
        var body: [String: Any] = [:]

        OpenAICompatibleEngine.applyGenerationOptions(
            to: &body,
            options: TextGenerationOptions(maxTokens: 512),
            reasoningAllowance: 4_096,
            templateThinksByDefault: false,
            dialect: .llamaServer,
            model: "gemma4-12b",
            requestLevel: .medium)

        XCTAssertEqual(body["max_tokens"] as? Int, 4_608)
        XCTAssertEqual(body["thinking_budget_tokens"] as? Int, 4_096)
        XCTAssertEqual((body["chat_template_kwargs"] as? [String: Any])?["enable_thinking"] as? Bool, true)
    }

    func testReasoningAllowanceFollowsTheModelDefaultTheChosenLevelAndOffTasks() {
        let qwen = ReasoningSupport.known(provider: .builtIn, model: "qwen3.5-4b")
        XCTAssertEqual(qwen.reasoningAllowance(.automatic, reasoning: .modelDefault, answerTokens: 4_096), 4_096)
        XCTAssertEqual(qwen.reasoningAllowance(.automatic, reasoning: .modelDefault, answerTokens: 20_000), 8_192)
        XCTAssertEqual(qwen.reasoningAllowance(.automatic, reasoning: .modelDefault, answerTokens: nil), 8_192)
        XCTAssertEqual(qwen.reasoningAllowance(.automatic, reasoning: .off, answerTokens: 4_096), 0)
        XCTAssertEqual(qwen.reasoningAllowance(.medium, reasoning: .modelDefault, answerTokens: 200), 4_096)
        XCTAssertEqual(qwen.reasoningAllowance(.medium, reasoning: .off, answerTokens: 200), 0)
        XCTAssertEqual(qwen.reasoningAllowance(.off, reasoning: .modelDefault, answerTokens: 4_096), 0)

        let gemma = ReasoningSupport.known(provider: .builtIn, model: "gemma4-12b")
        XCTAssertEqual(gemma.reasoningAllowance(.automatic, reasoning: .modelDefault, answerTokens: 4_096), 0)
        XCTAssertEqual(gemma.reasoningAllowance(.low, reasoning: .modelDefault, answerTokens: 4_096), 512)

        let ministral = ReasoningSupport.known(provider: .builtIn, model: "ministral-3-3b-instruct-2512")
        XCTAssertEqual(ministral.reasoningAllowance(.high, reasoning: .modelDefault, answerTokens: 4_096), 0)
        XCTAssertEqual(ReasoningSupport.common.reasoningAllowance(.automatic, reasoning: .modelDefault,
                                                                  answerTokens: 900), 900,
                       "a model whose default is unknown may reason")
    }

    func testBuiltInEngineLetsEachCatalogModelUseItsOwnDefault() throws {
        func body(_ model: String, _ options: TextGenerationOptions) throws -> [String: Any] {
            let engine = OpenAICompatibleEngine(
                baseURL: URL(string: "http://127.0.0.1:17872/v1")!, model: model, chatDialect: .llamaServer,
                reasoningSupport: .known(provider: .builtIn, model: model))
            let request = try engine.makeChatRequest(system: "s", prompt: "p", context: [], schema: nil,
                                                     options: options)
            return try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        }

        let qwen = try body("qwen3.5-4b", .init(maxTokens: 4_096))
        XCTAssertEqual(qwen["max_tokens"] as? Int, 8_192)
        XCTAssertEqual(qwen["thinking_budget_tokens"] as? Int, 4_096)
        XCTAssertNil(qwen["chat_template_kwargs"])

        let gemma = try body("gemma4-12b", .init(maxTokens: 4_096))
        XCTAssertEqual(gemma["max_tokens"] as? Int, 4_096)
        XCTAssertNil(gemma["thinking_budget_tokens"])
        XCTAssertEqual((gemma["chat_template_kwargs"] as? [String: Any])?["enable_thinking"] as? Bool, false)

        let imported = try body("hf:org/repo/model.gguf", .init(maxTokens: 4_096))
        XCTAssertEqual(imported["thinking_budget_tokens"] as? Int, 4_096, "an unknown default may reason")
        XCTAssertNil(imported["chat_template_kwargs"])

        let off = try body("qwen3.5-4b", .init(maxTokens: 4_096, reasoning: .off))
        XCTAssertEqual(off["max_tokens"] as? Int, 4_096)
        XCTAssertEqual(off["thinking_budget_tokens"] as? Int, 0)
        XCTAssertEqual((off["chat_template_kwargs"] as? [String: Any])?["enable_thinking"] as? Bool, false)
    }

    func testInklingIsSteeredThroughItsTemplateEffortAndNeverGetsABareZeroBudget() throws {
        func body(_ level: ThinkReasoningLevel, _ options: TextGenerationOptions,
                  model: String = "inkling-2-mini") throws -> [String: Any] {
            let engine = OpenAICompatibleEngine(
                baseURL: URL(string: "http://127.0.0.1:17872/v1")!, model: model, chatDialect: .llamaServer,
                reasoningLevel: level, reasoningSupport: .known(provider: .builtIn, model: model))
            let request = try engine.makeChatRequest(system: "s", prompt: "p", context: [], schema: nil,
                                                     options: options)
            return try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        }
        func kwargs(_ body: [String: Any]) -> [String: Any]? { body["chat_template_kwargs"] as? [String: Any] }

        let notes = try body(.automatic, .init(maxTokens: 4_096))
        XCTAssertNil(kwargs(notes), "the template's own effort, High")
        XCTAssertEqual(notes["thinking_budget_tokens"] as? Int, 4_096)
        XCTAssertEqual(notes["max_tokens"] as? Int, 8_192)

        let quick = try body(.automatic, .init(maxTokens: 4_096, reasoning: .off))
        XCTAssertEqual(kwargs(quick)?["reasoning_effort"] as? String, "none",
                       "a zero budget at the default effort makes Inkling loop on empty thinking")
        XCTAssertEqual(quick["thinking_budget_tokens"] as? Int, 0)
        XCTAssertEqual(quick["max_tokens"] as? Int, 4_096)

        let chosen = try body(.medium, .init(maxTokens: 1_000))
        XCTAssertEqual(kwargs(chosen)?["reasoning_effort"] as? String, "medium")
        XCTAssertEqual(chosen["thinking_budget_tokens"] as? Int, 4_096)

        let qwen = try body(.medium, .init(maxTokens: 1_000, reasoning: .off), model: "qwen3.5-4b")
        XCTAssertNil(kwargs(qwen)?["reasoning_effort"], "other templates keep today's request")
        XCTAssertEqual(kwargs(qwen)?["enable_thinking"] as? Bool, false)
    }

    func testOllamaRequestsSetTheirPlannedContextAndDisableThinkingForAnOffTask() {
        let plain = OllamaEngine.chatBody(model: "m", system: "s", user: "u", schema: nil, options: nil)
        let plainOptions = plain["options"] as? [String: Any]
        XCTAssertEqual(plainOptions?["num_ctx"] as? Int, MeetingSummaryGenerator.conservativeExternalContextTokens)
        XCTAssertNil(plain["think"])
        XCTAssertNil(plain["format"])

        let notes = OllamaEngine.chatBody(
            model: "m", system: "s", user: "u", schema: ["type": "object"],
            options: TextGenerationOptions(maxTokens: 512, reasoning: .off, temperature: 0))
        let notesOptions = notes["options"] as? [String: Any]
        XCTAssertEqual(notes["think"] as? Bool, false)
        XCTAssertEqual(notesOptions?["num_ctx"] as? Int, MeetingSummaryGenerator.conservativeExternalContextTokens)
        XCTAssertEqual(notesOptions?["num_predict"] as? Int, 512)
        XCTAssertEqual(notesOptions?["temperature"] as? Double, 0)
        XCTAssertNotNil(notes["format"])

        let thinking = OllamaEngine.chatBody(
            model: "m", system: "s", user: "u", schema: nil,
            options: TextGenerationOptions(maxTokens: 512), reasoningAllowance: 512)
        XCTAssertNil(thinking["think"], "the model keeps its own default")
        XCTAssertEqual((thinking["options"] as? [String: Any])?["num_predict"] as? Int, 1_024)
    }

    func testDictationComposeNeverOpensAThinkingTurn() {
        var body: [String: Any] = [:]
        XCTAssertEqual(DictationTextPreparation.composeOptions.reasoning, .off)
        OpenAICompatibleEngine.applyGenerationOptions(
            to: &body,
            options: DictationTextPreparation.composeOptions,
            dialect: .llamaServer,
            model: "local")
        XCTAssertEqual(body["thinking_budget_tokens"] as? Int, 0)
        XCTAssertEqual((body["chat_template_kwargs"] as? [String: Any])?["enable_thinking"] as? Bool, false)
        XCTAssertEqual(body["max_tokens"] as? Int, 4_096)
    }

    @MainActor
    func testInstantTasksAlwaysSkipReasoning() {
        XCTAssertEqual(DictationTextPreparation.composeOptions.reasoning, .off)
        XCTAssertEqual(SelectionActionPrompt.options.reasoning, .off)
        XCTAssertEqual(WindowHandoffBriefPrompt.options.reasoning, .off)
        XCTAssertEqual(MeetingRadar.passOptions.reasoning, .off)
        XCTAssertEqual(MeetingRadar.answerOptions.reasoning, .modelDefault)
    }

    func testAllReasoningRetryAppliesWhenKeepingTruncatedReplies() {
        let engine = OpenAICompatibleEngine(
            baseURL: URL(string: "https://openrouter.ai/api/v1")!,
            model: "qwen/qwen3.8-flash",
            chatDialect: .openRouter)
        XCTAssertTrue(engine.canRetryWithoutReasoning(.init(maxTokens: 1_024, keepsTruncatedReply: true)))
        XCTAssertFalse(engine.canRetryWithoutReasoning(.init(maxTokens: 1_024, reasoning: .off, keepsTruncatedReply: true)))
    }

    func testAnOffTaskDisablesThinkingForOneRequest() {
        var body: [String: Any] = [:]

        OpenAICompatibleEngine.applyGenerationOptions(
            to: &body,
            options: TextGenerationOptions(
                maxTokens: 512,
                reasoning: .off,
                temperature: 0.2),
            dialect: .llamaServer,
            model: "local")

        XCTAssertEqual(body["thinking_budget_tokens"] as? Int, 0)
        XCTAssertEqual(body["max_tokens"] as? Int, 512)
        XCTAssertEqual(body["temperature"] as? Double, 0.2)
        XCTAssertEqual(
            (body["chat_template_kwargs"] as? [String: Any])?["enable_thinking"] as? Bool,
            false)
    }

    func testDisabledThinkingPreservesOtherTemplateArguments() {
        var body: [String: Any] = [
            "chat_template_kwargs": ["enable_thinking": true, "custom_argument": "keep"],
        ]
        OpenAICompatibleEngine.applyGenerationOptions(
            to: &body, options: TextGenerationOptions(maxTokens: 512, reasoning: .off),
            dialect: .llamaServer, model: "local")

        let template = body["chat_template_kwargs"] as? [String: Any]
        XCTAssertEqual(template?["enable_thinking"] as? Bool, false)
        XCTAssertEqual(template?["custom_argument"] as? String, "keep")
    }

    func testThinkingCapPreservesTemplatePolicy() {
        var body: [String: Any] = ["chat_template_kwargs": ["custom_argument": "keep"]]
        OpenAICompatibleEngine.applyGenerationOptions(
            to: &body, options: TextGenerationOptions(maxTokens: 512),
            reasoningAllowance: 128, dialect: .llamaServer, model: "local")

        let template = body["chat_template_kwargs"] as? [String: Any]
        XCTAssertNil(template?["enable_thinking"])
        XCTAssertEqual(template?["custom_argument"] as? String, "keep")
        XCTAssertEqual(body["thinking_budget_tokens"] as? Int, 128)
        XCTAssertEqual(body["max_tokens"] as? Int, 640)
    }

    func testGenericExternalEngineLeavesReasoningAtServerDefault() {
        var body: [String: Any] = [:]

        OpenAICompatibleEngine.applyGenerationOptions(
            to: &body,
            options: TextGenerationOptions(maxTokens: 700, temperature: 0.2),
            reasoningAllowance: 300,
            dialect: .generic,
            model: "generic")

        XCTAssertNil(body["thinking_budget_tokens"])
        XCTAssertNil(body["reasoning_effort"])
        XCTAssertEqual(body["max_tokens"] as? Int, 1_000, "the answer plus room for the server's own reasoning")
        XCTAssertEqual(body["temperature"] as? Double, 0.2)
    }

    func testRequestLevelIsTheChosenLevelClampedToTheModelUnlessTheTaskIsOff() {
        let common = ReasoningSupport.common
        XCTAssertNil(common.requestLevel(.automatic, reasoning: .modelDefault))
        XCTAssertEqual(common.requestLevel(.medium, reasoning: .modelDefault), .medium)
        XCTAssertEqual(common.requestLevel(.high, reasoning: .modelDefault), .high, "no task lowers a chosen level")
        XCTAssertEqual(common.requestLevel(.high, reasoning: .off), .off)
        XCTAssertEqual(common.requestLevel(.low, reasoning: .modelDefault), .low)
        XCTAssertEqual(ReasoningSupport(levels: [.low, .medium, .high]).requestLevel(.high, reasoning: .off), .low,
                       "a model that always reasons gets its lowest level")

        let glm = ReasoningSupport(levels: [.max, .low, .high])
        XCTAssertEqual(glm.levels, [.low, .high, .max])
        XCTAssertEqual(glm.clamp(.medium), .low)
        XCTAssertEqual(glm.clamp(.off), .low)
        XCTAssertEqual(glm.clamp(.xhigh), .high)
        XCTAssertEqual(glm.displayed(.medium), .low)
        XCTAssertEqual(glm.displayed(.automatic), .automatic)

        XCTAssertNil(ReasoningSupport.unavailable.requestLevel(.high, reasoning: .modelDefault))
        XCTAssertEqual(ReasoningSupport.unavailable.displayed(.high), .automatic)
        XCTAssertEqual(ThinkReasoningLevel(effort: "none"), .off)
        XCTAssertEqual(ThinkReasoningLevel(effort: "xhigh"), .xhigh)
        XCTAssertNil(ThinkReasoningLevel(effort: "automatic"))
    }

    func testAutomaticSwitchesReasoningOffForANoReasoningTaskOnAModelThatReasonsByDefault() throws {
        let qwen = ReasoningSupport.known(provider: .cerebras, model: "qwen-3.8-27b")
        XCTAssertEqual(qwen.requestLevel(.automatic, reasoning: .off), .off)
        XCTAssertNil(qwen.requestLevel(.automatic, reasoning: .modelDefault), "other tasks keep the server default")
        XCTAssertEqual(ReasoningSupport.known(provider: .openAI, model: "gpt-5.4-mini")
            .requestLevel(.automatic, reasoning: .off), .off)
        XCTAssertNil(ReasoningSupport.known(provider: .cerebras, model: "gemma-4-31b")
            .requestLevel(.automatic, reasoning: .off), "already off by default")
        XCTAssertNil(ReasoningSupport.known(provider: .cerebras, model: "gpt-oss-120b")
            .requestLevel(.automatic, reasoning: .off), "cannot switch reasoning off")
        XCTAssertNil(ReasoningSupport.common.requestLevel(.automatic, reasoning: .off), "an unknown server's default")

        let engine = OpenAICompatibleEngine(baseURL: URL(string: "https://api.cerebras.ai/v1")!,
                                            model: "qwen-3.8-27b", apiKey: "test-token", reasoningLevel: .automatic)
        func effort(_ options: TextGenerationOptions?) throws -> String? {
            let request = try engine.makeChatRequest(system: "s", prompt: "p", context: [], schema: nil, options: options)
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
            return body["reasoning_effort"] as? String
        }
        XCTAssertEqual(try effort(.init(reasoning: .off)), "none")
        XCTAssertNil(try effort(nil))
    }

    func testDefaultFineTunedQwenDisablesThinkingInAutomaticModeAndAllowsExplicitOptIn() throws {
        let modelID = "qwen3.5-4b-lokalbot-v4"
        XCTAssertEqual(ModelCatalog.defaultSummarizationID, modelID)
        let support = ReasoningSupport.known(provider: .builtIn, model: modelID)
        XCTAssertEqual(support.defaultLevel, .off)
        XCTAssertEqual(ReasoningSupport.known(provider: .builtIn, model: "qwen3.5-4b-lokalbot-v5").defaultLevel, .off)
        XCTAssertEqual(support.automaticTitle, "Automatic (Off)")

        let automatic = OpenAICompatibleEngine(
            baseURL: URL(string: "http://127.0.0.1:17872/v1")!,
            model: modelID,
            chatDialect: .llamaServer,
            reasoningLevel: .automatic,
            reasoningSupport: support)

        for options in [nil, TextGenerationOptions(maxTokens: 900),
                        TextGenerationOptions(maxTokens: 4_000)] {
            let req = try automatic.makeChatRequest(system: "s", prompt: "p", context: [], schema: nil, options: options)
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(req.httpBody)) as? [String: Any])
            XCTAssertNil(body["thinking_budget_tokens"])
            let kwargs = try XCTUnwrap(body["chat_template_kwargs"] as? [String: Any])
            XCTAssertEqual(kwargs["enable_thinking"] as? Bool, false)
        }

        let low = OpenAICompatibleEngine(
            baseURL: URL(string: "http://127.0.0.1:17872/v1")!,
            model: modelID,
            chatDialect: .llamaServer,
            reasoningLevel: .low,
            reasoningSupport: support)
        let optInReq = try low.makeChatRequest(
            system: "s", prompt: "p", context: [], schema: nil,
            options: TextGenerationOptions(maxTokens: 2_000))
        let optInBody = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(optInReq.httpBody)) as? [String: Any])
        XCTAssertEqual(optInBody["thinking_budget_tokens"] as? Int, 512)
        XCTAssertEqual(optInBody["max_tokens"] as? Int, 2_512)
        let optInKwargs = try XCTUnwrap(optInBody["chat_template_kwargs"] as? [String: Any])
        XCTAssertEqual(optInKwargs["enable_thinking"] as? Bool, true)

        let zeroTaskReq = try low.makeChatRequest(
            system: "s", prompt: "p", context: [], schema: nil,
            options: TextGenerationOptions(maxTokens: 2_000, reasoning: .off))
        let zeroTaskBody = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(zeroTaskReq.httpBody)) as? [String: Any])
        XCTAssertEqual(zeroTaskBody["thinking_budget_tokens"] as? Int, 0)
        let zeroKwargs = try XCTUnwrap(zeroTaskBody["chat_template_kwargs"] as? [String: Any])
        XCTAssertEqual(zeroKwargs["enable_thinking"] as? Bool, false)
    }

    func testPopularModelsGetNoReasoningForNotesOrTheLeastTheyAllow() throws {
        func body(_ baseURL: String, _ model: String, dialect: ChatCompletionDialect? = nil) throws -> [String: Any] {
            let url = URL(string: baseURL)!
            let engine = OpenAICompatibleEngine(baseURL: url, model: model, apiKey: "test-token",
                                                chatDialect: dialect ?? .inferred(from: url), reasoningLevel: .automatic)
            let request = try engine.makeChatRequest(system: "s", prompt: "p", context: [], schema: nil,
                                                     options: .init(maxTokens: 4_096, reasoning: .off))
            return try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        }
        XCTAssertEqual(try body("https://api.cerebras.ai/v1", "qwen-3.8-27b")["reasoning_effort"] as? String, "none")
        let luna = try body("https://api.openai.com/v1", "gpt-5.6-luna")
        XCTAssertEqual(luna["reasoning_effort"] as? String, "none")
        XCTAssertEqual(luna["max_completion_tokens"] as? Int, 4_096)
        for model in ["openai/gpt-5.6-luna", "qwen/qwen3.8-27b"] {
            let reasoning = try body("https://openrouter.ai/api/v1", model)["reasoning"] as? [String: Any]
            XCTAssertEqual(reasoning?["effort"] as? String, "none", model)
        }
        let glm = try body("https://openrouter.ai/api/v1", "z-ai/glm-5.3-flash")["reasoning"] as? [String: Any]
        XCTAssertEqual(glm?["effort"] as? String, "low", "GLM 5.3 cannot switch reasoning off")
    }

    func testHostedServersLimitSchemaEnumsAndLocalServersDoNot() {
        func limit(_ baseURL: String, _ dialect: ChatCompletionDialect? = nil) -> Int? {
            let url = URL(string: baseURL)!
            return OpenAICompatibleEngine(baseURL: url, model: "m", chatDialect: dialect ?? .inferred(from: url))
                .structuredOutputEnumLimit
        }
        XCTAssertEqual(limit("https://api.cerebras.ai/v1"), 500)
        XCTAssertEqual(limit("https://api.openai.com/v1"), 1_000)
        XCTAssertEqual(limit("https://openrouter.ai/api/v1"), 500)
        XCTAssertEqual(limit("https://api.groq.com/openai/v1"), 500)
        XCTAssertNil(limit("http://localhost:1234/v1"))
        XCTAssertNil(limit("http://127.0.0.1:17872/v1", .llamaServer))
        XCTAssertNil(OllamaEngine(baseURL: URL(string: "http://localhost:11434")!, model: "m").structuredOutputEnumLimit)
    }

    func testKnownReasoningLevelsFollowProviderAndModel() {
        func levels(_ provider: ReasoningSupport.Provider, _ model: String) -> [ThinkReasoningLevel] {
            ReasoningSupport.known(provider: provider, model: model).levels
        }
        XCTAssertEqual(levels(.cerebras, "qwen-3.8-27b"), [.off, .low, .medium, .high])
        XCTAssertEqual(ReasoningSupport.known(provider: .cerebras, model: "qwen-3.8-27b").defaultLevel, .high)
        XCTAssertEqual(levels(.cerebras, "gpt-oss-120b"), [.low, .medium, .high])
        XCTAssertEqual(levels(.cerebras, "gemma-4-31b"), [.off, .low, .medium, .high])
        XCTAssertEqual(levels(.cerebras, "kimi-k2.7-code"), [])
        XCTAssertEqual(levels(.openAI, "o3-mini"), [.low, .medium, .high])
        XCTAssertEqual(levels(.openAI, "gpt-5-mini"), [.minimal, .low, .medium, .high])
        XCTAssertEqual(levels(.openAI, "gpt-5.1"), [.off, .low, .medium, .high])
        XCTAssertEqual(levels(.openAI, "gpt-5.4-mini"), [.off, .low, .medium, .high, .xhigh])
        XCTAssertEqual(levels(.openAI, "gpt-4.1-mini"), [])
        XCTAssertEqual(levels(.builtIn, "qwen3.5-4b"), [.off, .low, .medium, .high])
        XCTAssertEqual(levels(.builtIn, ModelCatalog.defaultSummarizationID), [.off, .low, .medium, .high])
        XCTAssertEqual(ReasoningSupport.known(provider: .builtIn, model: ModelCatalog.defaultSummarizationID).defaultLevel, .off)
        XCTAssertEqual(levels(.builtIn, "lfm2.5-2.6b"), [.low, .medium, .high])
        XCTAssertEqual(levels(.builtIn, "ministral-3-3b-instruct-2512"), [])
        func builtInDefault(_ model: String) -> ThinkReasoningLevel? {
            ReasoningSupport.known(provider: .builtIn, model: model).defaultLevel
        }
        XCTAssertTrue(ReasoningSupport.known(provider: .builtIn, model: "inkling-2-mini").templateTakesEffort)
        XCTAssertFalse(ReasoningSupport.known(provider: .builtIn, model: "qwen3.5-4b").templateTakesEffort)
        for model in ["qwen3.5-4b", "qwen3.6-35b-a3b", "qwen3.6-27b", "lfm2.5-2.6b", "inkling-2-mini"] {
            XCTAssertEqual(builtInDefault(model), .high, model)
        }
        for model in ["qwen3.5-0.8b", "qwen3.5-2b", "qwen3.5-4b-lokalbot-v4", "gemma4-e4b", "gemma4-e4b-q5-xl", "gemma4-12b",
                      "lfm2.5-1.2b-instruct", "granite-4.1-3b", "ministral-3-3b-instruct-2512"] {
            XCTAssertEqual(builtInDefault(model), .off, model)
        }
        XCTAssertNil(builtInDefault("hf:org/repo/model.gguf"), "an imported model's default is unknown")
        XCTAssertEqual(levels(.openRouter, "openai/gpt-5.4-mini"), [.off, .low, .medium, .high, .xhigh])
        XCTAssertEqual(levels(.generic, "gpt-oss-20b"), [.low, .medium, .high])
        XCTAssertEqual(levels(.generic, "some-model"), [.off, .low, .medium, .high])
        XCTAssertEqual(levels(.ollama, "qwen3:8b"), [.off])
        XCTAssertEqual(ReasoningSupport.Provider(dialect: .generic, baseURL: URL(string: "https://api.cerebras.ai/v1")!),
                       .cerebras)
    }

    func testGPT6ModelsOfferTheirDocumentedLevels() throws {
        let upToMax: [ThinkReasoningLevel] = [.low, .medium, .high, .xhigh, .max]
        let sol = ReasoningSupport.known(provider: .openAI, model: "gpt-6.1-sol")
        XCTAssertEqual(sol, ReasoningSupport(levels: upToMax, defaultLevel: .medium))
        for model in ["gpt-6-sol", "gpt-6-luna", "GPT-6-Luna"] {
            XCTAssertEqual(ReasoningSupport.known(provider: .openAI, model: model),
                           ReasoningSupport(levels: [.off] + upToMax, defaultLevel: .medium), model)
        }
        XCTAssertEqual(ReasoningSupport.known(provider: .openAI, model: "gpt-6-astra"), ReasoningSupport(levels: upToMax))
        XCTAssertEqual(ReasoningSupport.known(provider: .openAI, model: "gpt-6.2-sol").levels, upToMax,
                       "a newer GPT-6 model gets no Off")
        XCTAssertEqual(ReasoningSupport.known(provider: .openRouter, model: "openai/gpt-6.1-sol"), sol)
        XCTAssertEqual(sol.requestLevel(.high, reasoning: .off), .low, "6.1 Sol rejects none")

        var settings = AppSettings()
        settings.summarizerBackend = .chatGPTPlan
        settings.chatGPTPlanModel = "gpt-6.1-sol"
        let plan = ReasoningSupport.known(for: settings)
        XCTAssertTrue(plan.isAdjustable)
        XCTAssertEqual(plan.automaticTitle, "Automatic (Medium)")
        XCTAssertEqual(plan.levels.map(\.displayName), ["Low", "Medium", "High", "Extra high", "Max"])
        XCTAssertEqual(plan.displayed(.high), .high)

        func body(_ level: ThinkReasoningLevel) throws -> [String: Any] {
            let engine = OpenAICompatibleEngine(baseURL: URL(string: "https://api.openai.com/v1")!,
                                                model: "gpt-6.1-sol", apiKey: "test-token", chatDialect: .openAI,
                                                reasoningLevel: level)
            let request = try engine.makeChatRequest(
                system: "s", prompt: "p", context: [], schema: nil,
                options: .init(maxTokens: 900, temperature: 0.2))
            return try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        }
        let max = try body(.max)
        XCTAssertEqual(max["reasoning_effort"] as? String, "max", "no task lowers a chosen level")
        XCTAssertEqual(max["max_completion_tokens"] as? Int, 900 + 24_576)
        let automatic = try body(.automatic)
        XCTAssertNil(automatic["reasoning_effort"], "the model's own default")
        XCTAssertEqual(automatic["max_completion_tokens"] as? Int, 1_800, "the answer plus as much room to think")
        XCTAssertNil(automatic["temperature"])
    }

    func testCerebrasRequestCarriesTheChosenEffortUnlessTheTaskIsOff() throws {
        let engine = OpenAICompatibleEngine(
            baseURL: URL(string: "https://api.cerebras.ai/v1")!,
            model: "qwen-3.8-27b",
            apiKey: "test-token",
            reasoningLevel: .medium)

        func body(_ options: TextGenerationOptions?, fallback: Bool = false) throws -> [String: Any] {
            let request = try engine.makeChatRequest(system: "system", prompt: "prompt", context: [],
                                                     schema: nil, options: options,
                                                     reasoningFallback: fallback)
            return try XCTUnwrap(JSONSerialization.jsonObject(
                with: XCTUnwrap(request.httpBody)) as? [String: Any])
        }

        XCTAssertEqual(try body(nil)["reasoning_effort"] as? String, "medium")
        XCTAssertEqual(try body(.init(maxTokens: 900))["reasoning_effort"] as? String, "medium")
        XCTAssertEqual(try body(.init(reasoning: .off))["reasoning_effort"] as? String, "none")
        XCTAssertEqual(try body(.init(reasoning: .off), fallback: true)["reasoning_effort"] as? String,
                       "low")
        XCTAssertNil(try body(nil, fallback: true)["reasoning_effort"])
        XCTAssertNil(try body(nil)["thinking_budget_tokens"])
    }

    func testRequestLevelIsClampedToWhatTheModelAccepts() throws {
        let gptOss = OpenAICompatibleEngine(
            baseURL: URL(string: "https://api.cerebras.ai/v1")!, model: "gpt-oss-120b", reasoningLevel: .off)
        let kimi = OpenAICompatibleEngine(
            baseURL: URL(string: "https://api.cerebras.ai/v1")!, model: "kimi-k2.7-code", reasoningLevel: .high)
        let glm = OpenAICompatibleEngine(
            baseURL: URL(string: "https://openrouter.ai/api/v1")!, model: "z-ai/glm-5.3-flash",
            chatDialect: .openRouter, reasoningLevel: .medium,
            reasoningSupport: ReasoningSupport(levels: [.low, .high, .max]))

        XCTAssertEqual(gptOss.requestLevel(for: nil), .low, "gpt-oss cannot switch reasoning off")
        XCTAssertNil(kimi.requestLevel(for: nil), "a model without a control gets no field")
        let request = try glm.makeChatRequest(system: "s", prompt: "p", context: [], schema: nil,
                                              options: .init(temperature: 0.2))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        let reasoning = try XCTUnwrap(body["reasoning"] as? [String: Any])
        XCTAssertEqual(reasoning["effort"] as? String, "low")
        XCTAssertEqual(reasoning["exclude"] as? Bool, true)
        XCTAssertNil(body["temperature"])
        XCTAssertEqual((body["provider"] as? [String: Any])?["require_parameters"] as? Bool, true)
    }

    func testBuiltInReasoningLevelSetsTheThinkingBudget() {
        func body(_ level: ThinkReasoningLevel, options: TextGenerationOptions? = nil) -> [String: Any] {
            var body: [String: Any] = [:]
            OpenAICompatibleEngine.applyGenerationOptions(
                to: &body,
                options: options,
                reasoningAllowance: level.budgetTokens ?? 0,
                dialect: .llamaServer,
                model: "local",
                requestLevel: level)
            return body
        }

        let off = body(.off)
        XCTAssertEqual(off["thinking_budget_tokens"] as? Int, 0)
        XCTAssertEqual((off["chat_template_kwargs"] as? [String: Any])?["enable_thinking"] as? Bool, false)
        XCTAssertEqual(body(.medium)["thinking_budget_tokens"] as? Int, 4_096)
        let high = body(.high, options: .init(maxTokens: 2_000))
        XCTAssertEqual(high["thinking_budget_tokens"] as? Int, 8_192, "the chosen level, not half the answer")
        XCTAssertEqual(high["max_tokens"] as? Int, 10_192)
        XCTAssertNil(high["chat_template_kwargs"], "a model that thinks by default needs no switch")
        XCTAssertNil(body(.medium)["reasoning_effort"])
    }

    func testOpenAIReasoningLevelOffSendsNoneAndRetriesAtLow() {
        func body(_ level: ThinkReasoningLevel?, fallback: Bool) -> [String: Any] {
            var body: [String: Any] = [:]
            OpenAICompatibleEngine.applyGenerationOptions(
                to: &body,
                options: .init(reasoning: .off),
                dialect: .openAI,
                model: "gpt-5.4-mini",
                requestLevel: level,
                reasoningFallback: fallback)
            return body
        }

        XCTAssertEqual(body(.off, fallback: false)["reasoning_effort"] as? String, "none")
        XCTAssertEqual(body(.off, fallback: true)["reasoning_effort"] as? String, "low")
        XCTAssertEqual(body(.xhigh, fallback: false)["reasoning_effort"] as? String, "xhigh")
        XCTAssertNil(body(nil, fallback: false)["reasoning_effort"])
    }

    func testRejectedReasoningLevelRetriesOnceWhenTheServerNamesReasoning() {
        let rejected = TextEngineError.httpStatus(
            code: 400, detail: "Unsupported value for reasoning_effort: 'none'", retryAfter: nil)
        func retries(_ dialect: ChatCompletionDialect, _ level: ThinkReasoningLevel?,
                     _ error: Error = rejected, usedFallback: Bool = false) -> Bool {
            OpenAICompatibleEngine.shouldRetryRejectedReasoningLevel(
                dialect: dialect, requestLevel: level, error: error, usedFallback: usedFallback)
        }

        XCTAssertTrue(retries(.generic, .off))
        XCTAssertTrue(retries(.generic, .high, TextEngineError.httpStatus(
            code: 422, detail: "unknown field reasoning_effort", retryAfter: nil)))
        XCTAssertTrue(retries(.openAI, .off))
        XCTAssertFalse(retries(.openAI, .low))
        XCTAssertFalse(retries(.generic, .off, usedFallback: true))
        XCTAssertFalse(retries(.generic, nil))
        XCTAssertFalse(retries(.llamaServer, .off))
        XCTAssertFalse(retries(.generic, .off, TextEngineError.httpStatus(
            code: 400, detail: "context length exceeded", retryAfter: nil)))
        XCTAssertFalse(retries(.generic, .off, TextEngineError.httpStatus(
            code: 500, detail: "reasoning backend failed", retryAfter: nil)))
    }

    func testOllamaReasoningLevelTurnsThinkingOffOrGradesGptOss() {
        let off = OllamaEngine.chatBody(model: "qwen3:8b", system: "s", user: "u", schema: nil,
                                        options: nil, requestLevel: .off)
        XCTAssertEqual(off["think"] as? Bool, false)

        let gptOss = OllamaEngine.chatBody(model: "gpt-oss:20b", system: "s", user: "u", schema: nil,
                                           options: nil, requestLevel: .high)
        XCTAssertEqual(gptOss["think"] as? String, "high")

        XCTAssertEqual(OllamaEngine.reasoningSupport(model: "qwen3:8b", capabilities: ["completion", "thinking"]).levels,
                       [.off])
        XCTAssertEqual(OllamaEngine.reasoningSupport(model: "gpt-oss:20b", capabilities: ["thinking"]).levels,
                       [.low, .medium, .high])
        XCTAssertEqual(OllamaEngine.reasoningSupport(model: "llama3.3", capabilities: ["completion"]), .unavailable)
    }

    func testOfficialOpenAIUsesModernReasoningFieldsWithoutSamplingExtension() throws {
        let engine = OpenAICompatibleEngine(
            baseURL: URL(string: "https://api.openai.com/v1")!,
            model: "gpt-5.4-mini",
            apiKey: "test-token",
            chatDialect: .openAI)

        let request = try engine.makeChatRequest(
            system: "system",
            prompt: "prompt",
            context: [],
            schema: nil,
            options: TextGenerationOptions(maxTokens: 700, temperature: 0.2))
        let data = try XCTUnwrap(request.httpBody)
        let body = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(body["max_completion_tokens"] as? Int, 1_400, "room for the default medium effort")
        XCTAssertNil(body["reasoning_effort"], "Automatic leaves the model at its default")
        XCTAssertNil(body["max_tokens"])
        XCTAssertNil(body["thinking_budget_tokens"])
        XCTAssertNil(body["temperature"])
    }

    func testOfficialNonReasoningModelKeepsTemperature() {
        var body: [String: Any] = [:]

        OpenAICompatibleEngine.applyGenerationOptions(
            to: &body,
            options: TextGenerationOptions(maxTokens: 300, temperature: 0.4),
            dialect: .openAI,
            model: "gpt-4.1-mini")

        XCTAssertEqual(body["max_completion_tokens"] as? Int, 300)
        XCTAssertEqual(body["temperature"] as? Double, 0.4)
        XCTAssertNil(body["reasoning_effort"])
    }

    func testDialectInferenceSelectsKnownRemoteProviders() {
        XCTAssertEqual(
            ChatCompletionDialect.inferred(
                from: URL(string: "https://api.openai.com/v1")!),
            .openAI)
        XCTAssertEqual(
            ChatCompletionDialect.inferred(
                from: URL(string: "https://openrouter.ai/api/v1")!),
            .openRouter)
        XCTAssertEqual(
            ChatCompletionDialect.inferred(
                from: URL(string: "https://eu.openrouter.ai/api/v1")!),
            .openRouter)
        XCTAssertEqual(
            ChatCompletionDialect.inferred(
                from: URL(string: "http://localhost:1234/v1")!),
            .generic)
    }

    func testOpenRouterLeavesReasoningAtTheModelDefaultAndRoutesPrivately() throws {
        let engine = OpenAICompatibleEngine(
            baseURL: URL(string: "https://openrouter.ai/api/v1")!,
            model: "anthropic/example-model",
            apiKey: "test-token",
            chatDialect: .openRouter)
        let schema: [String: Any] = [
            "type": "object",
            "properties": ["answer": ["type": "string"]],
            "required": ["answer"],
            "additionalProperties": false,
        ]

        let request = try engine.makeChatRequest(
            system: "system",
            prompt: "prompt",
            context: [],
            schema: schema,
            options: TextGenerationOptions(maxTokens: 700, temperature: 0.2))
        let data = try XCTUnwrap(request.httpBody)
        let body = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        let provider = try XCTUnwrap(body["provider"] as? [String: Any])

        XCTAssertEqual(request.url?.absoluteString,
                       "https://openrouter.ai/api/v1/chat/completions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"),
                       "Bearer test-token")
        XCTAssertEqual(body["max_tokens"] as? Int, 1_400, "the answer plus room for the model's own reasoning")
        XCTAssertNil(body["reasoning"], "the model keeps its default reasoning")
        XCTAssertEqual(provider["data_collection"] as? String, "deny")
        XCTAssertEqual(provider["require_parameters"] as? Bool, true)
        XCTAssertNil(body["max_completion_tokens"])
        XCTAssertNil(body["thinking_budget_tokens"])
        XCTAssertNil(body["reasoning_effort"])
        XCTAssertEqual(body["temperature"] as? Double, 0.2)
    }

    func testOpenRouterPlainChatKeepsTemperatureWithoutForcingParameters() throws {
        let engine = OpenAICompatibleEngine(
            baseURL: URL(string: "https://openrouter.ai/api/v1")!,
            model: "openai/example-model",
            apiKey: "test-token",
            chatDialect: .openRouter)

        let request = try engine.makeChatRequest(
            system: "system",
            prompt: "prompt",
            context: [],
            schema: nil,
            options: TextGenerationOptions(maxTokens: 300, temperature: 0.4))
        let data = try XCTUnwrap(request.httpBody)
        let body = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        let provider = try XCTUnwrap(body["provider"] as? [String: Any])

        XCTAssertEqual(body["max_tokens"] as? Int, 600, "an unknown model may reason, so it gets room to")
        XCTAssertEqual(body["temperature"] as? Double, 0.4)
        XCTAssertEqual(provider["data_collection"] as? String, "deny")
        XCTAssertNil(provider["require_parameters"])
        XCTAssertNil(body["reasoning"])
    }

    func testOpenRouterCanFollowAccountDataPolicy() throws {
        let engine = OpenAICompatibleEngine(
            baseURL: URL(string: "https://openrouter.ai/api/v1")!,
            model: "deepseek/example-model",
            apiKey: "test-token",
            chatDialect: .openRouter,
            openRouterDataPolicy: .accountPolicy)

        let request = try engine.makeChatRequest(
            system: "system",
            prompt: "prompt",
            context: [],
            schema: nil,
            options: nil)
        let data = try XCTUnwrap(request.httpBody)
        let body = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        let provider = try XCTUnwrap(body["provider"] as? [String: Any])

        XCTAssertEqual(provider["data_collection"] as? String, "allow")
    }

    func testOpenRouterGLMUsesLowEffortAndStrictSchemaOnFirstRequest() throws {
        let engine = OpenAICompatibleEngine(
            baseURL: URL(string: "https://openrouter.ai/api/v1")!,
            model: "z-ai/glm-5.3-flash",
            apiKey: "test-token",
            chatDialect: .openRouter)
        let schema: [String: Any] = [
            "type": "object",
            "properties": ["answer": ["type": "string"]],
            "required": ["answer"],
            "additionalProperties": false,
        ]

        let request = try engine.makeChatRequest(
            system: "system",
            prompt: "prompt",
            context: [],
            schema: schema,
            options: TextGenerationOptions(
                maxTokens: 768,
                reasoning: .off,
                temperature: 0.2))
        let data = try XCTUnwrap(request.httpBody)
        let body = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        let reasoning = try XCTUnwrap(body["reasoning"] as? [String: Any])

        XCTAssertEqual(reasoning["effort"] as? String, "low")
        XCTAssertNil(reasoning["max_tokens"])
        XCTAssertEqual(reasoning["exclude"] as? Bool, true)
        XCTAssertEqual(body["max_tokens"] as? Int, 768)
        XCTAssertNil(body["temperature"])
        let format = try XCTUnwrap(body["response_format"] as? [String: Any])
        XCTAssertEqual(format["type"] as? String, "json_schema")
        XCTAssertEqual((format["json_schema"] as? [String: Any])?["strict"] as? Bool, true)
        let provider = try XCTUnwrap(body["provider"] as? [String: Any])
        XCTAssertEqual(provider["data_collection"] as? String, "deny")
        XCTAssertEqual(provider["require_parameters"] as? Bool, true)
    }

    func testOpenRouterEffortFallbackUsesMinimumReasoning() {
        var body: [String: Any] = [:]

        OpenAICompatibleEngine.applyGenerationOptions(
            to: &body,
            options: TextGenerationOptions(
                maxTokens: 1_600,
                reasoning: .off,
                temperature: 0),
            dialect: .openRouter,
            model: "z-ai/glm-5.3",
            openRouterReasoning: .effort)

        let reasoning = body["reasoning"] as? [String: Any]
        XCTAssertEqual(reasoning?["effort"] as? String, "low")
        XCTAssertNil(reasoning?["max_tokens"])
        XCTAssertNil(body["temperature"])
    }

    func testOpenRouterEffortCompatibilityPreservesStructuredRequirements() throws {
        let engine = OpenAICompatibleEngine(
            baseURL: URL(string: "https://openrouter.ai/api/v1")!,
            model: "stealth/ox-alpha",
            apiKey: "test-token",
            chatDialect: .openRouter)
        let schema: [String: Any] = [
            "type": "object",
            "properties": ["answer": ["type": "string"]],
            "required": ["answer"],
            "additionalProperties": false,
        ]

        let request = try engine.makeChatRequest(
            system: "system",
            prompt: "prompt",
            context: [],
            schema: schema,
            options: nil,
            openRouterReasoning: .effort)
        let data = try XCTUnwrap(request.httpBody)
        let body = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        let reasoning = try XCTUnwrap(body["reasoning"] as? [String: Any])
        let provider = try XCTUnwrap(body["provider"] as? [String: Any])

        XCTAssertEqual(reasoning["effort"] as? String, "low")
        XCTAssertNotNil(body["response_format"])
        XCTAssertEqual(provider["data_collection"] as? String, "deny")
        XCTAssertEqual(provider["require_parameters"] as? Bool, true)
    }

    func testOpenRouterParameterMismatchTriggersEffortFallbackOnce() {
        let mismatch = TextEngineError.httpStatus(
            code: 404,
            detail: "No endpoints found that can handle the requested parameters. "
                + "To learn more about provider routing, visit: "
                + "https://openrouter.ai/docs/guides/routing/provider-selection",
            retryAfter: nil)
        let missingModel = TextEngineError.httpStatus(
            code: 404, detail: "No endpoints found for model z-ai/glm-5.3", retryAfter: nil)

        func falls(_ error: Error, dialect: ChatCompletionDialect = .openRouter,
                   usedFallback: Bool = false, off: Bool = true) -> Bool {
            OpenAICompatibleEngine.shouldFallbackToReasoningEffort(
                dialect: dialect, error: error, usedFallback: usedFallback, requestsReasoningOff: off)
        }

        XCTAssertTrue(falls(mismatch), "effort:none can retry with supported effort")
        XCTAssertFalse(falls(mismatch, off: false),
                       "schema-only errors cannot be fixed by changing reasoning or dropping the schema")
        XCTAssertFalse(falls(mismatch, usedFallback: true))
        XCTAssertFalse(falls(missingModel))
        XCTAssertFalse(falls(mismatch, dialect: .generic))
    }

    func testOpenRouterMandatoryReasoningErrorTriggersEffortFallbackOnce() {
        let mandatory = TextEngineError.httpStatus(
            code: 400,
            detail: "Reasoning is mandatory for this endpoint and cannot be disabled.",
            retryAfter: nil)
        let unrelated = TextEngineError.httpStatus(
            code: 400, detail: "Invalid JSON schema", retryAfter: nil)

        func falls(_ error: Error, dialect: ChatCompletionDialect = .openRouter,
                   usedFallback: Bool = false, off: Bool = true) -> Bool {
            OpenAICompatibleEngine.shouldFallbackToReasoningEffort(
                dialect: dialect, error: error, usedFallback: usedFallback, requestsReasoningOff: off)
        }

        XCTAssertTrue(falls(mandatory))
        XCTAssertFalse(falls(mandatory, usedFallback: true))
        XCTAssertFalse(falls(mandatory, off: false), "only an Off request asks for no reasoning")
        XCTAssertFalse(falls(mandatory, dialect: .generic))
        XCTAssertFalse(falls(unrelated))
    }

    func testOpenRouterCanDisableReasoningForStructuredRetry() throws {
        let engine = OpenAICompatibleEngine(
            baseURL: URL(string: "https://openrouter.ai/api/v1")!,
            model: "deepseek/example-model",
            apiKey: "test-token",
            chatDialect: .openRouter)
        let schema: [String: Any] = [
            "type": "object",
            "properties": ["answer": ["type": "string"]],
            "required": ["answer"],
            "additionalProperties": false,
        ]

        let request = try engine.makeChatRequest(
            system: "system",
            prompt: "prompt",
            context: [],
            schema: schema,
            options: TextGenerationOptions(
                maxTokens: 1_600,
                reasoning: .off,
                temperature: 0))
        let data = try XCTUnwrap(request.httpBody)
        let body = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        let reasoning = try XCTUnwrap(body["reasoning"] as? [String: Any])
        let provider = try XCTUnwrap(body["provider"] as? [String: Any])

        XCTAssertEqual(reasoning["effort"] as? String, "none")
        XCTAssertEqual(body["temperature"] as? Double, 0)
        XCTAssertEqual(provider["require_parameters"] as? Bool, true)
    }

    func testOpenRouterRejectsInvalidStrictSchemaLocally() {
        let engine = OpenAICompatibleEngine(
            baseURL: URL(string: "https://openrouter.ai/api/v1")!,
            model: "openai/example-model",
            apiKey: "test-token",
            chatDialect: .openRouter)
        let invalidSchema: [String: Any] = [
            "type": "object",
            "properties": ["answer": ["type": "string"]],
            "required": ["answer"],
        ]

        XCTAssertThrowsError(try engine.makeChatRequest(
            system: "system",
            prompt: "prompt",
            context: [],
            schema: invalidSchema,
            options: nil)) {
            XCTAssertTrue($0.localizedDescription.contains("invalid strict JSON schema"))
        }
    }

    func testParseChatCompletionCapturesUsage() throws {
        let data = try XCTUnwrap(#"""
            {
              "choices": [{"finish_reason": "stop", "message": {"content": "Done"}}],
              "usage": {
                "prompt_tokens": 30,
                "completion_tokens": 12,
                "prompt_tokens_details": {"cached_tokens": 20},
                "completion_tokens_details": {"reasoning_tokens": 4}
              }
            }
            """#.data(using: .utf8))

        let parsed = try OpenAICompatibleEngine.parseChatCompletion(data)

        XCTAssertEqual(parsed.content, "Done")
        XCTAssertEqual(parsed.usage,
                       .init(inputTokens: 30, outputTokens: 12,
                             cachedInputTokens: 20, reasoningOutputTokens: 4))
    }

    func testParseChatCompletionRejectsTruncationAndRefusal() throws {
        let truncated = try XCTUnwrap(#"""
            {"choices": [{"finish_reason": "length", "message": {"content": "partial"}}]}
            """#.data(using: .utf8))
        XCTAssertThrowsError(try OpenAICompatibleEngine.parseChatCompletion(truncated)) {
            guard case TextEngineError.outputTruncated = $0 else {
                return XCTFail("Expected outputTruncated, got \($0)")
            }
            XCTAssertTrue($0.localizedDescription.contains("truncated"))
        }

        let refusal = try XCTUnwrap(#"""
            {"choices": [{"finish_reason": "stop", "message": {"content": null, "refusal": "Cannot comply"}}]}
            """#.data(using: .utf8))
        XCTAssertThrowsError(try OpenAICompatibleEngine.parseChatCompletion(refusal)) {
            XCTAssertTrue($0.localizedDescription.contains("refusal"))
        }
    }

    func testRetryPolicyHonorsRetryAfterAndRejectsPermanentErrors() {
        let rateLimit = TextEngineError.httpStatus(
            code: 429, detail: "slow down", retryAfter: 3)
        XCTAssertEqual(TextEngineRetryPolicy.delay(
            for: rateLimit, attempt: 0, jitter: 0), 3)

        let serverFailure = TextEngineError.httpStatus(
            code: 503, detail: "warming", retryAfter: nil)
        XCTAssertEqual(TextEngineRetryPolicy.delay(
            for: serverFailure, attempt: 0, jitter: 0.25), 1.25)

        let invalidRequest = TextEngineError.httpStatus(
            code: 400, detail: "bad schema", retryAfter: nil)
        XCTAssertNil(TextEngineRetryPolicy.delay(
            for: invalidRequest, attempt: 0, jitter: 0))
        XCTAssertNil(TextEngineRetryPolicy.delay(
            for: rateLimit, attempt: 1, jitter: 0))
    }

    func testHTTPErrorParsesSafeDetailRequestIDAndRetryAfter() throws {
        let response = try XCTUnwrap(HTTPURLResponse(
            url: URL(string: "https://api.openai.com/v1/chat/completions")!,
            statusCode: 429,
            httpVersion: nil,
            headerFields: ["Retry-After": "2", "x-request-id": "req_test"]))
        let data = try XCTUnwrap(
            #"{"error":{"message":"Rate limit reached"}}"#.data(using: .utf8))

        guard case .httpStatus(let code, let detail, let retryAfter) =
                TextEngineError.fromHTTPResponse(response, data: data) else {
            return XCTFail("expected HTTP status error")
        }
        XCTAssertEqual(code, 429)
        XCTAssertTrue(detail.contains("Rate limit reached"))
        XCTAssertTrue(detail.contains("req_test"))
        XCTAssertEqual(retryAfter, 2)
    }

    func testGenerateMapsTaskCancellationToCancellationError() async {
        let task = Task { () -> String in
            let engine = OpenAICompatibleEngine(baseURL: URL(string: "http://192.0.2.1:9/")!,
                                                model: "test", apiKey: nil)
            return try await engine.generate(system: "s", prompt: "p", context: [])
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("a cancelled request should throw")
        } catch is CancellationError {
        } catch let error as TextEngineError {
            XCTFail("cancellation misclassified as TextEngineError: \(error)")
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testRawCompletionBodyCanLeaveOutLlamaSamplingExtensions() {
        let request = CompletionRequest(prompt: "Thanks for the ", maxTokens: 8, temperature: 0.1, topP: 0.7,
                                        topK: 20, minP: 0.08, repeatPenalty: 1.05, seed: 7, stop: ["\n"])
        let llama = OpenAICompatibleEngine(baseURL: URL(string: "http://127.0.0.1:1/v1")!, model: "m")
        let local = llama.completionBody(request, stream: false)
        XCTAssertEqual(local["top_k"] as? Int, 20)
        XCTAssertEqual(local["repeat_penalty"] as? Double, 1.05)

        let hosted = OpenAICompatibleEngine(
            baseURL: URL(string: "https://api.example.com/v1")!, model: "m",
            extraBody: ["top_k": 40], sendsLlamaSamplingExtensions: false)
        let body = hosted.completionBody(request, stream: true)
        XCTAssertNil(body["min_p"])
        XCTAssertNil(body["repeat_penalty"])
        XCTAssertEqual(body["top_k"] as? Int, 40, "explicit provider fields still apply")
        XCTAssertEqual(body["top_p"] as? Double, 0.7)
        XCTAssertEqual(body["stop"] as? [String], ["\n"])
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertNil(body["provider"])
    }

    func testOpenRouterRawCompletionCarriesTheProviderDataPolicy() throws {
        let request = CompletionRequest(prompt: "Thanks for the ", maxTokens: 8, temperature: 0.1, topP: 0.7,
                                        topK: 20, minP: 0.08, repeatPenalty: 1.05, seed: 7, stop: ["\n"])
        let url = try XCTUnwrap(URL(string: "https://openrouter.ai/api/v1"))
        for policy in OpenRouterDataPolicy.allCases {
            let engine = OpenAICompatibleEngine(
                baseURL: url, model: "qwen/qwen3.8-27b", apiKey: "key",
                sendsLlamaSamplingExtensions: false, chatDialect: .openRouter, openRouterDataPolicy: policy)
            let provider = try XCTUnwrap(engine.completionBody(request, stream: true)["provider"] as? [String: Any])
            XCTAssertEqual(provider["data_collection"] as? String, policy.providerDataCollectionValue)
        }
    }

    func testLlamaServerOffRequestAlwaysSendsZeroThinkingBudget() throws {
        for level in [ThinkReasoningLevel.automatic, .high] {
            let engine = OpenAICompatibleEngine(
                baseURL: URL(string: "http://127.0.0.1:8080/v1")!,
                model: "lfm2.5-2.6b",
                apiKey: nil,
                chatDialect: .llamaServer,
                reasoningLevel: level)
            let request = try engine.makeChatRequest(
                system: "system",
                prompt: "prompt",
                context: [],
                schema: nil,
                options: TextGenerationOptions(maxTokens: 1_024, reasoning: .off))
            let body = try XCTUnwrap(
                JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any])
            XCTAssertEqual(body["max_tokens"] as? Int, 1_024)
            XCTAssertEqual(body["thinking_budget_tokens"] as? Int, 0)
            let kwargs = try XCTUnwrap(body["chat_template_kwargs"] as? [String: Any])
            XCTAssertEqual(kwargs["enable_thinking"] as? Bool, false)
        }
    }

    func testOllamaEngineAccountsForGenerationRequests() {
        let engine = OllamaEngine(baseURL: URL(string: "http://127.0.0.1:11434")!, model: "qwen3:8b")
        XCTAssertTrue(engine.accountsForGenerationRequests)
    }
}
