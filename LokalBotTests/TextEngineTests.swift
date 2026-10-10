import XCTest
@testable import LokalBot

final class TextEngineTests: XCTestCase {
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

    func testBuiltInHighReasoningBudgetReservesHalfOfBoundedOutput() {
        var body: [String: Any] = [:]

        OpenAICompatibleEngine.applyGenerationOptions(
            to: &body,
            options: TextGenerationOptions(maxTokens: 8_192),
            defaultThinkingBudgetTokens: MainLLMRuntimePolicy.highReasoningBudgetTokens,
            dialect: .llamaServer,
            model: "local")

        XCTAssertEqual(body["max_tokens"] as? Int, 8_192)
        XCTAssertEqual(body["thinking_budget_tokens"] as? Int, 4_096)
    }

    func testBuiltInHighReasoningUsesFullCeilingWithoutOutputLimit() {
        var body: [String: Any] = [:]

        OpenAICompatibleEngine.applyGenerationOptions(
            to: &body,
            options: nil,
            defaultThinkingBudgetTokens: MainLLMRuntimePolicy.highReasoningBudgetTokens,
            dialect: .llamaServer,
            model: "local")

        XCTAssertNil(body["max_tokens"])
        XCTAssertEqual(body["thinking_budget_tokens"] as? Int, 8_192)
    }

    func testOllamaRequestsSetTheirPlannedContextAndDisableThinkingOnAZeroBudget() {
        let plain = OllamaEngine.chatBody(model: "m", system: "s", user: "u", schema: nil, options: nil)
        let plainOptions = plain["options"] as? [String: Any]
        XCTAssertEqual(plainOptions?["num_ctx"] as? Int, MeetingSummaryGenerator.conservativeExternalContextTokens)
        XCTAssertNil(plain["think"])
        XCTAssertNil(plain["format"])

        let notes = OllamaEngine.chatBody(
            model: "m", system: "s", user: "u", schema: ["type": "object"],
            options: TextGenerationOptions(maxTokens: 512, reasoningBudgetTokens: 0, temperature: 0))
        let notesOptions = notes["options"] as? [String: Any]
        XCTAssertEqual(notes["think"] as? Bool, false)
        XCTAssertEqual(notesOptions?["num_ctx"] as? Int, MeetingSummaryGenerator.conservativeExternalContextTokens)
        XCTAssertEqual(notesOptions?["num_predict"] as? Int, 512)
        XCTAssertEqual(notesOptions?["temperature"] as? Double, 0)
        XCTAssertNotNil(notes["format"])
    }

    func testDictationComposeNeverOpensAThinkingTurn() {
        var body: [String: Any] = [:]
        OpenAICompatibleEngine.applyGenerationOptions(
            to: &body,
            options: DictationTextPreparation.composeOptions,
            defaultThinkingBudgetTokens: MainLLMRuntimePolicy.highReasoningBudgetTokens,
            dialect: .llamaServer,
            model: "local")
        XCTAssertEqual(body["thinking_budget_tokens"] as? Int, 0)
        XCTAssertEqual((body["chat_template_kwargs"] as? [String: Any])?["enable_thinking"] as? Bool, false)
        XCTAssertEqual(body["max_tokens"] as? Int, 4_096)
    }

    func testExplicitReasoningBudgetCanDisableThinkingForOneRequest() {
        var body: [String: Any] = [:]

        OpenAICompatibleEngine.applyGenerationOptions(
            to: &body,
            options: TextGenerationOptions(
                maxTokens: 512,
                reasoningBudgetTokens: 0,
                temperature: 0.2),
            defaultThinkingBudgetTokens: MainLLMRuntimePolicy.highReasoningBudgetTokens,
            dialect: .llamaServer,
            model: "local")

        XCTAssertEqual(body["thinking_budget_tokens"] as? Int, 0)
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
            to: &body, options: TextGenerationOptions(maxTokens: 512),
            defaultThinkingBudgetTokens: 0, dialect: .llamaServer, model: "local")

        let template = body["chat_template_kwargs"] as? [String: Any]
        XCTAssertEqual(template?["enable_thinking"] as? Bool, false)
        XCTAssertEqual(template?["custom_argument"] as? String, "keep")
    }

    func testPositiveThinkingBudgetPreservesTemplatePolicy() {
        var body: [String: Any] = ["chat_template_kwargs": ["custom_argument": "keep"]]
        OpenAICompatibleEngine.applyGenerationOptions(
            to: &body, options: TextGenerationOptions(maxTokens: 512, reasoningBudgetTokens: 128),
            defaultThinkingBudgetTokens: 0, dialect: .llamaServer, model: "local")

        let template = body["chat_template_kwargs"] as? [String: Any]
        XCTAssertNil(template?["enable_thinking"])
        XCTAssertEqual(template?["custom_argument"] as? String, "keep")
        XCTAssertEqual(body["thinking_budget_tokens"] as? Int, 128)
    }

    func testGenericExternalEngineLeavesReasoningAtServerDefault() {
        var body: [String: Any] = [:]

        OpenAICompatibleEngine.applyGenerationOptions(
            to: &body,
            options: TextGenerationOptions(maxTokens: 700,
                                           reasoningBudgetTokens: 256,
                                           temperature: 0.2),
            defaultThinkingBudgetTokens: nil,
            dialect: .generic,
            model: "generic")

        XCTAssertNil(body["thinking_budget_tokens"])
        XCTAssertNil(body["reasoning_effort"])
        XCTAssertEqual(body["max_tokens"] as? Int, 700)
        XCTAssertEqual(body["temperature"] as? Double, 0.2)
    }

    func testRequestLevelIsTheChosenLevelCappedByTheTaskAndClampedToTheModel() {
        let common = ReasoningSupport.common
        XCTAssertNil(common.requestLevel(.automatic, taskBudget: nil))
        XCTAssertEqual(common.requestLevel(.medium, taskBudget: nil), .medium)
        XCTAssertEqual(common.requestLevel(.high, taskBudget: 256), .low)
        XCTAssertEqual(common.requestLevel(.high, taskBudget: 1_024), .medium)
        XCTAssertEqual(common.requestLevel(.high, taskBudget: 0), .off)
        XCTAssertEqual(common.requestLevel(.low, taskBudget: 8_192), .low)

        // GLM 5.3 on OpenRouter: low/high/max and no way to switch it off.
        let glm = ReasoningSupport(levels: [.max, .low, .high])
        XCTAssertEqual(glm.levels, [.low, .high, .max])
        XCTAssertEqual(glm.clamp(.medium), .low)
        XCTAssertEqual(glm.clamp(.off), .low)
        XCTAssertEqual(glm.clamp(.xhigh), .high)
        XCTAssertEqual(glm.displayed(.medium), .low)
        XCTAssertEqual(glm.displayed(.automatic), .automatic)

        XCTAssertNil(ReasoningSupport.unavailable.requestLevel(.high, taskBudget: nil))
        XCTAssertEqual(ReasoningSupport.unavailable.displayed(.high), .automatic)
        XCTAssertEqual(ThinkReasoningLevel(effort: "none"), .off)
        XCTAssertEqual(ThinkReasoningLevel(effort: "xhigh"), .xhigh)
        XCTAssertNil(ThinkReasoningLevel(effort: "automatic"))
    }

    /// On 2026-10-07, on Automatic, Cerebras Qwen reasoned at its default for
    /// every notes request and returned no notes.
    func testAutomaticSwitchesReasoningOffForANoReasoningTaskOnAModelThatReasonsByDefault() throws {
        let qwen = ReasoningSupport.known(provider: .cerebras, model: "qwen-3.8-27b")
        XCTAssertEqual(qwen.requestLevel(.automatic, taskBudget: 0), .off)
        XCTAssertNil(qwen.requestLevel(.automatic, taskBudget: nil), "other tasks keep the server default")
        XCTAssertNil(qwen.requestLevel(.automatic, taskBudget: 1_024))
        XCTAssertEqual(ReasoningSupport.known(provider: .openAI, model: "gpt-5.4-mini")
            .requestLevel(.automatic, taskBudget: 0), .off)
        XCTAssertNil(ReasoningSupport.known(provider: .cerebras, model: "gemma-4-31b")
            .requestLevel(.automatic, taskBudget: 0), "already off by default")
        XCTAssertNil(ReasoningSupport.known(provider: .cerebras, model: "gpt-oss-120b")
            .requestLevel(.automatic, taskBudget: 0), "cannot switch reasoning off")
        XCTAssertNil(ReasoningSupport.common.requestLevel(.automatic, taskBudget: 0), "an unknown server's default")

        let engine = OpenAICompatibleEngine(baseURL: URL(string: "https://api.cerebras.ai/v1")!,
                                            model: "qwen-3.8-27b", apiKey: "test-token", reasoningLevel: .automatic)
        func effort(_ options: TextGenerationOptions?) throws -> String? {
            let request = try engine.makeChatRequest(system: "s", prompt: "p", context: [], schema: nil, options: options)
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
            return body["reasoning_effort"] as? String
        }
        XCTAssertEqual(try effort(.init(reasoningBudgetTokens: 0)), "none")
        XCTAssertNil(try effort(nil))
    }

    /// What a no-reasoning notes request sends to popular models on Automatic.
    func testPopularModelsGetNoReasoningForNotesOrTheLeastTheyAllow() throws {
        func body(_ baseURL: String, _ model: String, dialect: ChatCompletionDialect? = nil) throws -> [String: Any] {
            let url = URL(string: baseURL)!
            let engine = OpenAICompatibleEngine(baseURL: url, model: model, apiKey: "test-token",
                                                chatDialect: dialect ?? .inferred(from: url), reasoningLevel: .automatic)
            let request = try engine.makeChatRequest(system: "s", prompt: "p", context: [], schema: nil,
                                                     options: .init(maxTokens: 4_096, reasoningBudgetTokens: 0))
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
        // Cerebras's documented values.
        XCTAssertEqual(levels(.cerebras, "qwen-3.8-27b"), [.off, .low, .medium, .high])
        XCTAssertEqual(ReasoningSupport.known(provider: .cerebras, model: "qwen-3.8-27b").defaultLevel, .high)
        XCTAssertEqual(levels(.cerebras, "gpt-oss-120b"), [.low, .medium, .high])
        XCTAssertEqual(levels(.cerebras, "gemma-4-31b"), [.off, .low, .medium, .high])
        XCTAssertEqual(levels(.cerebras, "kimi-k2.7-code"), [])
        // OpenAI generations.
        XCTAssertEqual(levels(.openAI, "o3-mini"), [.low, .medium, .high])
        XCTAssertEqual(levels(.openAI, "gpt-5-mini"), [.minimal, .low, .medium, .high])
        XCTAssertEqual(levels(.openAI, "gpt-5.1"), [.off, .low, .medium, .high])
        XCTAssertEqual(levels(.openAI, "gpt-5.4-mini"), [.off, .low, .medium, .high, .xhigh])
        XCTAssertEqual(levels(.openAI, "gpt-4.1-mini"), [])
        // Built-in models.
        XCTAssertEqual(levels(.builtIn, "qwen3.5-4b"), [.off, .low, .medium, .high])
        XCTAssertEqual(levels(.builtIn, "lfm2.5-2.6b"), [.low, .medium, .high])
        XCTAssertEqual(levels(.builtIn, "ministral-3-3b-instruct-2512"), [])
        // Unlisted servers and models.
        XCTAssertEqual(levels(.openRouter, "openai/gpt-5.4-mini"), [.off, .low, .medium, .high, .xhigh])
        XCTAssertEqual(levels(.generic, "gpt-oss-20b"), [.low, .medium, .high])
        XCTAssertEqual(levels(.generic, "some-model"), [.off, .low, .medium, .high])
        XCTAssertEqual(levels(.ollama, "qwen3:8b"), [.off])
        XCTAssertEqual(ReasoningSupport.Provider(dialect: .generic, baseURL: URL(string: "https://api.cerebras.ai/v1")!),
                       .cerebras)
    }

    func testCerebrasRequestCarriesTheChosenEffortCappedByTheTask() throws {
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
        XCTAssertEqual(try body(.init(reasoningBudgetTokens: 256))["reasoning_effort"] as? String, "low")
        XCTAssertEqual(try body(.init(reasoningBudgetTokens: 0))["reasoning_effort"] as? String, "none")
        XCTAssertEqual(try body(.init(reasoningBudgetTokens: 0), fallback: true)["reasoning_effort"] as? String,
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
                defaultThinkingBudgetTokens: MainLLMRuntimePolicy.highReasoningBudgetTokens,
                dialect: .llamaServer,
                model: "local",
                requestLevel: level)
            return body
        }

        let off = body(.off)
        XCTAssertEqual(off["thinking_budget_tokens"] as? Int, 0)
        XCTAssertEqual((off["chat_template_kwargs"] as? [String: Any])?["enable_thinking"] as? Bool, false)
        XCTAssertEqual(body(.medium)["thinking_budget_tokens"] as? Int, 4_096)
        XCTAssertEqual(body(.high, options: .init(maxTokens: 2_000))["thinking_budget_tokens"] as? Int, 1_000)
        XCTAssertNil(body(.medium)["reasoning_effort"])
    }

    func testOpenAIReasoningLevelOffSendsNoneAndRetriesAtLow() {
        func body(_ level: ThinkReasoningLevel?, fallback: Bool) -> [String: Any] {
            var body: [String: Any] = [:]
            OpenAICompatibleEngine.applyGenerationOptions(
                to: &body,
                options: .init(reasoningBudgetTokens: 0),
                defaultThinkingBudgetTokens: nil,
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
            options: TextGenerationOptions(maxTokens: 700,
                                           reasoningBudgetTokens: 256,
                                           temperature: 0.2))
        let data = try XCTUnwrap(request.httpBody)
        let body = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(body["max_completion_tokens"] as? Int, 700)
        XCTAssertEqual(body["reasoning_effort"] as? String, "low")
        XCTAssertNil(body["max_tokens"])
        XCTAssertNil(body["thinking_budget_tokens"])
        XCTAssertNil(body["temperature"])
    }

    func testOfficialNonReasoningModelKeepsTemperature() {
        var body: [String: Any] = [:]

        OpenAICompatibleEngine.applyGenerationOptions(
            to: &body,
            options: TextGenerationOptions(maxTokens: 300,
                                           reasoningBudgetTokens: 256,
                                           temperature: 0.4),
            defaultThinkingBudgetTokens: nil,
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

    func testOpenRouterUsesNativeReasoningAndPrivacyRouting() throws {
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
            options: TextGenerationOptions(maxTokens: 700,
                                           reasoningBudgetTokens: 256,
                                           temperature: 0.2))
        let data = try XCTUnwrap(request.httpBody)
        let body = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        let reasoning = try XCTUnwrap(body["reasoning"] as? [String: Any])
        let provider = try XCTUnwrap(body["provider"] as? [String: Any])

        XCTAssertEqual(request.url?.absoluteString,
                       "https://openrouter.ai/api/v1/chat/completions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"),
                       "Bearer test-token")
        XCTAssertEqual(body["max_tokens"] as? Int, 700)
        XCTAssertEqual(reasoning["max_tokens"] as? Int, 256)
        XCTAssertEqual(reasoning["exclude"] as? Bool, true)
        XCTAssertEqual(provider["data_collection"] as? String, "deny")
        XCTAssertEqual(provider["require_parameters"] as? Bool, true)
        XCTAssertNil(body["max_completion_tokens"])
        XCTAssertNil(body["thinking_budget_tokens"])
        XCTAssertNil(body["reasoning_effort"])
        XCTAssertNil(body["temperature"])
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

        XCTAssertEqual(body["max_tokens"] as? Int, 300)
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
                reasoningBudgetTokens: 0,
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
                reasoningBudgetTokens: 0,
                temperature: 0),
            defaultThinkingBudgetTokens: nil,
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

        XCTAssertTrue(OpenAICompatibleEngine.shouldFallbackToReasoningEffort(
            dialect: .openRouter, error: mismatch, usedFallback: false,
            requestedReasoningBudget: 256))
        XCTAssertTrue(OpenAICompatibleEngine.shouldFallbackToReasoningEffort(
            dialect: .openRouter, error: mismatch, usedFallback: false,
            requestedReasoningBudget: 0),
                       "effort:none can retry with supported effort")
        XCTAssertFalse(OpenAICompatibleEngine.shouldFallbackToReasoningEffort(
            dialect: .openRouter, error: mismatch, usedFallback: false,
            requestedReasoningBudget: nil),
                       "schema-only errors cannot be fixed by changing reasoning or dropping the schema")
        XCTAssertFalse(OpenAICompatibleEngine.shouldFallbackToReasoningEffort(
            dialect: .openRouter, error: mismatch, usedFallback: true,
            requestedReasoningBudget: 256))
        XCTAssertFalse(OpenAICompatibleEngine.shouldFallbackToReasoningEffort(
            dialect: .openRouter, error: missingModel, usedFallback: false,
            requestedReasoningBudget: 256))
        XCTAssertFalse(OpenAICompatibleEngine.shouldFallbackToReasoningEffort(
            dialect: .generic, error: mismatch, usedFallback: false,
            requestedReasoningBudget: 256))
        XCTAssertFalse(OpenAICompatibleEngine.shouldFallbackToReasoningEffort(
            dialect: .openRouter, error: mismatch, usedFallback: false,
            requestedReasoningBudget: nil))
    }

    func testOpenRouterMandatoryReasoningErrorTriggersEffortFallbackOnce() {
        let mandatory = TextEngineError.httpStatus(
            code: 400,
            detail: "Reasoning is mandatory for this endpoint and cannot be disabled.",
            retryAfter: nil)
        let unrelated = TextEngineError.httpStatus(
            code: 400, detail: "Invalid JSON schema", retryAfter: nil)

        XCTAssertTrue(OpenAICompatibleEngine.shouldFallbackToReasoningEffort(
            dialect: .openRouter, error: mandatory, usedFallback: false,
            requestedReasoningBudget: 0))
        XCTAssertFalse(OpenAICompatibleEngine.shouldFallbackToReasoningEffort(
            dialect: .openRouter, error: mandatory, usedFallback: true,
            requestedReasoningBudget: 0))
        XCTAssertFalse(OpenAICompatibleEngine.shouldFallbackToReasoningEffort(
            dialect: .openRouter, error: mandatory, usedFallback: false,
            requestedReasoningBudget: 256))
        XCTAssertFalse(OpenAICompatibleEngine.shouldFallbackToReasoningEffort(
            dialect: .generic, error: mandatory, usedFallback: false,
            requestedReasoningBudget: 0))
        XCTAssertFalse(OpenAICompatibleEngine.shouldFallbackToReasoningEffort(
            dialect: .openRouter, error: unrelated, usedFallback: false,
            requestedReasoningBudget: 0))
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
                reasoningBudgetTokens: 0,
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

    /// Pressing Stop cancels the Task mid-request; `send` must surface that as
    /// cancellation, not a `serverUnreachable` error the chat UI renders red.
    func testGenerateMapsTaskCancellationToCancellationError() async {
        let task = Task { () -> String in
            // Blackholed TEST-NET address (RFC 5737): the request can only resolve
            // via cancellation, never a real connection or a fast refusal.
            let engine = OpenAICompatibleEngine(baseURL: URL(string: "http://192.0.2.1:9/")!,
                                                model: "test", apiKey: nil)
            return try await engine.generate(system: "s", prompt: "p", context: [])
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("a cancelled request should throw")
        } catch is CancellationError {
            // Correct: Stop surfaces as cancellation.
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
    }
}
