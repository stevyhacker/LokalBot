import Foundation

/// Meta's Model API (`https://api.meta.ai/v1`, OpenAI-compatible chat
/// completions). Live Radar reads the meeting with Muse Spark while it is
/// recorded; Follow-through plans and proposes the work after it with Muse
/// Wonder. Both send text only: audio, speaker labels, and search stay on
/// this Mac. Built for the Meta Global AI Developer Hackathon (2026).
enum MetaModelAPI {
    static let baseURL = URL(string: "https://api.meta.ai/v1")!
    static var origin: String { RemoteInferenceGate.origin(for: baseURL) }
    static let apiKeyAccount = "meta-model-api-key"
    static let consoleURL = URL(string: "https://dev.meta.ai")!

    /// Standard models only. Contributor variants trade a discount for Meta's
    /// right to train on the content, which meeting text must never grant.
    struct Model: Identifiable, Equatable, Sendable {
        let id: String
        let displayName: String
        let summary: String
        /// US dollars per million tokens (dev.meta.ai pricing, Oct 2026).
        let inputPrice: Double
        let cachedInputPrice: Double
        let outputPrice: Double
    }

    static let museSpark = Model(
        id: "muse-spark-1.3", displayName: "Muse Spark 1.3",
        summary: "Fast. About 3 s per radar pass.",
        inputPrice: 1.25, cachedInputPrice: 0.15, outputPrice: 4.25)
    static let museWonder = Model(
        id: "muse-wonder-1.0", displayName: "Muse Wonder 1.0",
        summary: "Strongest reasoning and tool use. About 6 s per radar pass.",
        inputPrice: 4.00, cachedInputPrice: 0.20, outputPrice: 20.00)
    static let models = [museSpark, museWonder]

    static func model(id: String) -> Model? { models.first { $0.id == id } }

    static func displayName(for id: String) -> String { model(id: id)?.displayName ?? id }

    /// Reasoning and visible output are billed at the output rate.
    static func cost(of usage: MuseChatClient.Usage, model id: String) -> Double {
        guard let model = model(id: id) else { return 0 }
        let uncached = max(0, usage.inputTokens - usage.cachedInputTokens)
        return (Double(uncached) * model.inputPrice
            + Double(usage.cachedInputTokens) * model.cachedInputPrice
            + Double(usage.outputTokens) * model.outputPrice) / 1_000_000
    }

    enum ConnectionError: LocalizedError, Equatable {
        case missingKey
        case notApproved

        var errorDescription: String? {
            switch self {
            case .missingKey:
                "Add a Meta Model API key in Settings → Recording → Meta Muse."
            case .notApproved:
                "Allow LokalBot to send meeting text to api.meta.ai in Settings → Recording → Meta Muse."
            }
        }
    }

    /// The key and approval a request needs, or why it can't be sent. The
    /// origin approval is the same list Think servers use, so revoking it in
    /// either place stops both.
    static func client(settings: AppSettings, model: String, reasoningEffort: String,
                       maxTokens: Int, priority: InferencePriority, purpose: String) throws -> MuseChatClient {
        guard settings.metaModelAPIApproved else { throw ConnectionError.notApproved }
        let key = settings.effectiveMetaModelAPIKey
        guard !key.isEmpty else { throw ConnectionError.missingKey }
        var client = MuseChatClient(apiKey: key, model: model, reasoningEffort: reasoningEffort,
                                    maxTokens: maxTokens, priority: priority, purpose: purpose)
#if LOKALBOT_UI_TEST_HOST
        if MuseUITestTransport.isEnabled { client.transport = MuseUITestTransport.reply }
#endif
        return client
    }
}

/// One `/chat/completions` call with optional function tools or a strict JSON
/// schema. `TextEngine` returns text only; Follow-through needs tool calls and
/// both features report token use, so they get this small client. Requests
/// share the origin's `RemoteInferenceGate` with Think and stay on the
/// approved origin (`InferenceURLSession` rejects cross-origin redirects).
struct MuseChatClient {
    struct ToolCall: Equatable, Sendable {
        let id: String
        let name: String
        /// The JSON object string the model produced. It is not guaranteed to
        /// match the tool's schema, so callers validate it.
        let arguments: String

        var decodedArguments: [String: Any] {
            guard let data = arguments.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
            return object
        }
    }

    struct Usage: Equatable, Sendable {
        var inputTokens = 0
        var cachedInputTokens = 0
        var outputTokens = 0
        var reasoningTokens = 0

        static func + (lhs: Usage, rhs: Usage) -> Usage {
            Usage(inputTokens: lhs.inputTokens + rhs.inputTokens,
                  cachedInputTokens: lhs.cachedInputTokens + rhs.cachedInputTokens,
                  outputTokens: lhs.outputTokens + rhs.outputTokens,
                  reasoningTokens: lhs.reasoningTokens + rhs.reasoningTokens)
        }
    }

    struct Reply: Equatable, Sendable {
        var content: String
        var toolCalls: [ToolCall]
        var usage: Usage
        var finishReason: String?
    }

    typealias Transport = (URLRequest) async throws -> (Data, URLResponse)

    var baseURL = MetaModelAPI.baseURL
    var apiKey: String
    var model: String
    /// minimal, low, medium, high, xhigh or max. Muse models reject "none".
    var reasoningEffort: String
    /// Reasoning tokens count against this limit too.
    var maxTokens: Int
    var priority: InferencePriority
    var purpose: String
    var gate: RemoteInferenceGate? = .shared
    var transport: Transport = { request in try await sendInferenceRequest(request, base: MetaModelAPI.baseURL) }

    /// Pure construction, so the wire format is covered by offline tests.
    func makeRequest(messages: [[String: Any]], tools: [[String: Any]] = [],
                     schema: (name: String, schema: [String: Any])? = nil) throws -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        var body: [String: Any] = [
            "model": model,
            "messages": messages,
            "max_tokens": maxTokens,
            "reasoning_effort": reasoningEffort,
        ]
        if !tools.isEmpty {
            body["tools"] = tools
            // The only value Meta accepts; anything else is HTTP 400.
            body["tool_choice"] = "auto"
        }
        if let schema {
            body["response_format"] = [
                "type": "json_schema",
                "json_schema": ["name": schema.name, "strict": true, "schema": schema.schema],
            ]
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return request
    }

    func send(messages: [[String: Any]], tools: [[String: Any]] = [],
              schema: (name: String, schema: [String: Any])? = nil) async throws -> Reply {
        let request = try makeRequest(messages: messages, tools: tools, schema: schema)
        let ticket = try await gate?.acquire(origin: MetaModelAPI.origin, priority: priority)
        do {
            let (data, response) = try await transport(request)
            let http = response as? HTTPURLResponse
            guard let status = http?.statusCode, (200...299).contains(status) else {
                throw TextEngineError.fromHTTPResponse(http, data: data)
            }
            let reply = try Self.parse(data)
            if let ticket { await gate?.release(ticket) }
            return reply
        } catch {
            let engineError = error as? TextEngineError
            if let ticket {
                await gate?.release(ticket, rateLimited: engineError?.isRateLimit == true,
                                    retryAfter: engineError?.retryAfter)
            }
            if !(error is CancellationError) {
                lokalbotLog("muse request failed purpose=\(purpose) model=\(model) error=\(error.localizedDescription)")
            }
            throw error
        }
    }

    static func parse(_ data: Data) throws -> Reply {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choice = (json["choices"] as? [[String: Any]])?.first,
              let message = choice["message"] as? [String: Any] else {
            throw TextEngineError.badResponse("unexpected /chat/completions payload")
        }
        if let refusal = (message["refusal"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !refusal.isEmpty {
            throw TextEngineError.badResponse("model refusal: \(String(refusal.prefix(600)))")
        }
        let finishReason = choice["finish_reason"] as? String
        let calls = (message["tool_calls"] as? [[String: Any]] ?? []).compactMap { call -> ToolCall? in
            guard let id = call["id"] as? String,
                  let function = call["function"] as? [String: Any],
                  let name = function["name"] as? String else { return nil }
            return ToolCall(id: id, name: name, arguments: function["arguments"] as? String ?? "{}")
        }
        let content = message["content"] as? String ?? ""
        if finishReason == "length", calls.isEmpty { throw TextEngineError.outputTruncated }
        let usage = json["usage"] as? [String: Any]
        let input = usage?["prompt_tokens_details"] as? [String: Any]
        let output = usage?["completion_tokens_details"] as? [String: Any]
        return Reply(
            content: content, toolCalls: calls,
            usage: Usage(inputTokens: usage?["prompt_tokens"] as? Int ?? 0,
                         cachedInputTokens: input?["cached_tokens"] as? Int ?? 0,
                         outputTokens: usage?["completion_tokens"] as? Int ?? 0,
                         reasoningTokens: output?["reasoning_tokens"] as? Int ?? 0),
            finishReason: finishReason)
    }

    /// The assistant message to append before tool results, as the API
    /// requires: its text plus every tool call it made.
    static func assistantMessage(for reply: Reply) -> [String: Any] {
        var message: [String: Any] = ["role": "assistant", "content": reply.content]
        if !reply.toolCalls.isEmpty {
            message["tool_calls"] = reply.toolCalls.map { call in
                ["id": call.id, "type": "function",
                 "function": ["name": call.name, "arguments": call.arguments]] as [String: Any]
            }
        }
        return message
    }

    static func toolResultMessage(callID: String, content: String) -> [String: Any] {
        ["role": "tool", "tool_call_id": callID, "content": content]
    }
}
