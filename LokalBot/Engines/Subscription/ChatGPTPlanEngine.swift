import Foundation

struct ChatGPTPlanEngine: TextEngine {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    enum OptionalField: String, Hashable, Sendable {
        case reasoning, textFormat
    }

    static let responsesURL = URL(string: "\(ChatGPTPlanOAuth.resource)/responses")!

    var model: String
    var account: ChatGPTPlanAccount = .shared
    var reasoningLevel: ThinkReasoningLevel = .automatic
    var transport: Transport?

    var displayName: String { "ChatGPT plan — \(model)" }
    var checkpointIdentity: String { "\(displayName)|chatgpt-plan|responses" }
    var accountsForGenerationRequests: Bool { true }
    var structuredOutputEnumLimit: Int? { 1_000 }
    var minimumStructuredOutputTokens: Int {
        let support = reasoningSupport
        return !support.isAdjustable || support.levels.contains(.off) ? 512 : 2_048
    }

    var reasoningSupport: ReasoningSupport {
        ReasoningSupport.known(provider: .openAI, model: model)
    }

    func generate(system: String, prompt: String, context: [String]) async throws -> String {
        try await respond(system: system, prompt: prompt, context: context, schema: nil, options: nil, onPartial: nil)
    }

    func generate(system: String, prompt: String, context: [String],
                  options: TextGenerationOptions) async throws -> String {
        try await respond(system: system, prompt: prompt, context: context, schema: nil, options: options, onPartial: nil)
    }

    func generate(system: String, prompt: String, context: [String],
                  schema: [String: Any]) async throws -> String {
        try await respond(system: system, prompt: prompt, context: context, schema: schema, options: nil, onPartial: nil)
    }

    func generate(system: String, prompt: String, context: [String],
                  schema: [String: Any],
                  options: TextGenerationOptions) async throws -> String {
        try await respond(system: system, prompt: prompt, context: context, schema: schema, options: options,
                          onPartial: nil)
    }

    func generateStreaming(system: String, prompt: String, context: [String],
                           options: TextGenerationOptions,
                           onPartial: @escaping @MainActor (String) -> Void) async throws -> String {
        let streamsPartials = MeetingGenerationBudget.current == nil
        let result = try await respond(system: system, prompt: prompt, context: context, schema: nil,
                                       options: options, onPartial: streamsPartials ? onPartial : nil)
        await onPartial(result)
        return result
    }

    func effort(for options: TextGenerationOptions?) -> ThinkReasoningLevel? {
        reasoningSupport.requestLevel(reasoningLevel, taskBudget: options?.reasoningBudgetTokens)
    }

    func optionalFields(schema: [String: Any]?, options: TextGenerationOptions?) -> Set<OptionalField> {
        var fields: Set<OptionalField> = []
        if effort(for: options) != nil { fields.insert(.reasoning) }
        if schema != nil { fields.insert(.textFormat) }
        return fields
    }

    func makeRequest(system: String, prompt: String, context: [String],
                     schema: [String: Any]?, options: TextGenerationOptions?,
                     accessToken: String,
                     omitting omitted: Set<OptionalField> = []) throws -> URLRequest {
        guard !model.isEmpty else { throw SubscriptionPlanError.noModel(.chatGPT) }
        if let schema, let issue = OpenAIStrictSchemaValidator.validationIssue(in: schema) {
            throw TextEngineError.badResponse("invalid strict JSON schema: \(issue)")
        }
        var request = URLRequest(url: Self.responsesURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        var content: [[String: Any]] = []
        for text in context where !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            content.append(["type": "input_text", "text": text])
        }
        if content.isEmpty || !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            content.append(["type": "input_text", "text": prompt])
        }
        var body: [String: Any] = [
            "model": model,
            "input": [["type": "message", "role": "user", "content": content]],
            "store": false,
            "stream": true,
        ]
        if !system.isEmpty { body["instructions"] = system }
        if let schema, !omitted.contains(.textFormat) {
            body["text"] = ["format": [
                "type": "json_schema", "name": "response", "strict": true, "schema": schema,
            ] as [String: Any]]
        }
        if let level = effort(for: options), !omitted.contains(.reasoning) {
            body["reasoning"] = ["effort": level.effortValue]
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return request
    }

    static func planError(status: Int, data: Data, response: HTTPURLResponse?) -> Error {
        let error = errorObject(data)
        if let mapped = planError(code: error.code, message: error.message, param: error.param) {
            return mapped
        }
        if status == 401 { return ChatGPTPlanError.signInRequired }
        return TextEngineError.fromHTTPResponse(response, data: data)
    }

    static func planError(code: String?, message: String?, param: String?) -> Error? {
        let detail = String((message ?? code ?? "").prefix(300))
        switch code {
        case "subscription_sharing_usage_limit_exceeded"?:
            return ChatGPTPlanError.usageLimitReached
        case "subscription_sharing_user_not_eligible"?:
            return ChatGPTPlanError.notEligible(detail)
        case "subscription_sharing_unsupported_capability"?:
            return ChatGPTPlanError.unsupportedRequest(param ?? detail)
        case "subscription_sharing_route_not_supported"?, "chatpass_v2_scope_not_authorized"?,
             "chatpass_v2_invalid_authorization_context"?:
            return ChatGPTPlanError.misconfigured(detail)
        case "subscription_sharing_invalid_user"?:
            return ChatGPTPlanError.signInRequired
        case "subscription_sharing_usage_unavailable"?, "subscription_sharing_user_unavailable"?:
            return TextEngineError.httpStatus(code: 503, detail: "ChatGPT plan usage is temporarily unavailable",
                                              retryAfter: nil)
        default:
            return nil
        }
    }

    static func errorObject(_ data: Data) -> (code: String?, message: String?, param: String?) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (nil, nil, nil)
        }
        let error = json["error"] as? [String: Any] ?? json
        return (error["code"] as? String, (error["message"] as? String) ?? (json["detail"] as? String),
                error["param"] as? String)
    }

    static func rejectedFields(in error: Error, sent: Set<OptionalField>) -> Set<OptionalField> {
        guard case .unsupportedRequest(let detail)? = error as? ChatGPTPlanError else { return [] }
        var rejected: Set<OptionalField> = []
        if detail.localizedCaseInsensitiveContains("reasoning") { rejected.insert(.reasoning) }
        if detail.localizedCaseInsensitiveContains("text") || detail.localizedCaseInsensitiveContains("format") {
            rejected.insert(.textFormat)
        }
        return rejected.intersection(sent)
    }

    struct Usage: Equatable, Sendable {
        var inputTokens: Int?
        var outputTokens: Int?
        var cachedTokens: Int?
        var reasoningTokens: Int?

        init(json: [String: Any]?) {
            inputTokens = json?["input_tokens"] as? Int
            outputTokens = json?["output_tokens"] as? Int
            cachedTokens = (json?["input_tokens_details"] as? [String: Any])?["cached_tokens"] as? Int
            reasoningTokens = (json?["output_tokens_details"] as? [String: Any])?["reasoning_tokens"] as? Int
        }
    }

    struct StreamAccumulator {
        enum Outcome: Equatable {
            case completed
            case truncated
        }

        private(set) var text = ""
        private(set) var refusal = ""
        private(set) var usage: Usage?
        private(set) var outcome: Outcome?

        mutating func consume(_ line: String) throws -> Bool {
            guard line.hasPrefix("data:") else { return false }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard payload != "[DONE]", let data = payload.data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
            switch event["type"] as? String {
            case "response.output_text.delta":
                guard let delta = event["delta"] as? String, !delta.isEmpty else { return false }
                text += delta
                return true
            case "response.refusal.delta":
                refusal += event["delta"] as? String ?? ""
            case "response.completed":
                let response = event["response"] as? [String: Any]
                usage = Usage(json: response?["usage"] as? [String: Any])
                if text.isEmpty, let output = response?["output"] as? [[String: Any]] {
                    text = Self.outputText(output)
                }
                outcome = .completed
            case "response.incomplete":
                let response = event["response"] as? [String: Any]
                usage = Usage(json: response?["usage"] as? [String: Any])
                let reason = (response?["incomplete_details"] as? [String: Any])?["reason"] as? String
                if reason == "max_output_tokens" {
                    outcome = .truncated
                } else {
                    throw TextEngineError.badResponse("ChatGPT stopped early (\(reason ?? "incomplete"))")
                }
            case "response.failed":
                let error = (event["response"] as? [String: Any])?["error"] as? [String: Any]
                throw ChatGPTPlanEngine.streamError(code: error?["code"] as? String,
                                                    message: error?["message"] as? String,
                                                    param: error?["param"] as? String)
            case "error":
                let error = event["error"] as? [String: Any] ?? event
                throw ChatGPTPlanEngine.streamError(code: error["code"] as? String,
                                                    message: error["message"] as? String,
                                                    param: error["param"] as? String)
            default:
                break
            }
            return false
        }

        func finish() throws -> (text: String, truncated: Bool, usage: Usage?) {
            if !refusal.isEmpty, text.isEmpty {
                throw TextEngineError.badResponse("model refusal: \(refusal.prefix(600))")
            }
            switch outcome {
            case .completed?:
                guard !text.isEmpty else { throw TextEngineError.badResponse("ChatGPT returned no text") }
                return (text, false, usage)
            case .truncated?:
                return (text, true, usage)
            case nil:
                throw TextEngineError.badResponse("ChatGPT's stream ended before completion")
            }
        }

        static func outputText(_ output: [[String: Any]]) -> String {
            output.filter { $0["type"] as? String == "message" }
                .flatMap { $0["content"] as? [[String: Any]] ?? [] }
                .filter { $0["type"] as? String == "output_text" }
                .compactMap { $0["text"] as? String }
                .joined()
        }
    }

    static func streamError(code: String?, message: String?, param: String?) -> Error {
        planError(code: code, message: message, param: param)
            ?? TextEngineError.badResponse("ChatGPT request failed: \((message ?? code ?? "unknown error").prefix(600))")
    }

    private func respond(system: String, prompt: String, context: [String],
                         schema: [String: Any]?, options: TextGenerationOptions?,
                         onPartial: (@MainActor (String) -> Void)?) async throws -> String {
        guard !model.isEmpty else { throw SubscriptionPlanError.noModel(.chatGPT) }
        var omitted: Set<OptionalField> = []
        var token = try await account.accessToken()
        var refreshedAfterRejection = false
        while true {
            let request = try makeRequest(system: system, prompt: prompt, context: context, schema: schema,
                                          options: options, accessToken: token, omitting: omitted)
            do {
                return try await complete(request, options: options, onPartial: onPartial)
            } catch ChatGPTPlanError.signInRequired where !refreshedAfterRejection {
                refreshedAfterRejection = true
                token = try await account.accessTokenAfterRejection(of: token)
            } catch {
                let rejected = Self.rejectedFields(
                    in: error, sent: optionalFields(schema: schema, options: options).subtracting(omitted))
                guard !rejected.isEmpty else { throw error }
                lokalbotLog("chatgpt plan retry without=\(rejected.map(\.rawValue).sorted()) model=\(model)")
                omitted.formUnion(rejected)
            }
        }
    }

    private func complete(_ request: URLRequest, options: TextGenerationOptions?,
                          onPartial: (@MainActor (String) -> Void)?) async throws -> String {
        let budget = MeetingGenerationBudget.current
        let reservation = try await budget?.reserve(input: MeetingGenerationBudget.promptTokens,
                                                    output: options?.maxTokens ?? 4_096)
        let started = ProcessInfo.processInfo.systemUptime
        var metric = GenerationCallTelemetry(stage: MeetingGenerationBudget.stage, outcome: "failed", wallSeconds: 0)
        do {
            let reply = try await stream(request, onPartial: onPartial)
            metric.inputTokens = reply.usage?.inputTokens
            metric.outputTokens = reply.usage?.outputTokens
            metric.cachedTokens = reply.usage?.cachedTokens
            metric.reasoningTokens = reply.usage?.reasoningTokens
            metric.outcome = reply.truncated ? "truncated" : "complete"
            if reply.truncated {
                if budget != nil { throw TruncatedStructuredResponse(content: strippingReasoning(reply.text)) }
                throw TextEngineError.outputTruncated
            }
            metric.wallSeconds = ProcessInfo.processInfo.systemUptime - started
            metric.log()
            if let reservation { await budget?.finish(reservation, metric: metric) }
            return strippingReasoning(reply.text)
        } catch {
            if error is CancellationError { metric.outcome = "cancelled" }
            if case .usageLimitReached? = error as? ChatGPTPlanError { metric.outcome = "rejected" }
            metric.wallSeconds = ProcessInfo.processInfo.systemUptime - started
            metric.log()
            if let reservation { await budget?.finish(reservation, metric: metric) }
            throw error
        }
    }

    private func stream(_ request: URLRequest, onPartial: (@MainActor (String) -> Void)?)
        async throws -> (text: String, truncated: Bool, usage: Usage?) {
        var accumulator = StreamAccumulator()
        if let transport {
            let (data, response) = try await transport(request)
            let http = response as? HTTPURLResponse
            guard let status = http?.statusCode, (200...299).contains(status) else {
                throw Self.planError(status: http?.statusCode ?? 0, data: data, response: http)
            }
            for line in String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: true) {
                _ = try accumulator.consume(String(line))
            }
            return try accumulator.finish()
        }

        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await llmSession.bytes(for: request)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw TextEngineError.serverUnreachable(Self.responsesURL.absoluteString,
                                                    transportCode: (error as NSError).code)
        }
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            var body = Data()
            for try await byte in bytes where body.count < 65_536 { body.append(byte) }
            let http = response as? HTTPURLResponse
            throw Self.planError(status: http?.statusCode ?? 0, data: body, response: http)
        }
        var lastEmission = -Double.infinity
        for try await line in bytes.lines {
            try Task.checkCancellation()
            let grew = try accumulator.consume(line)
            if grew, let onPartial {
                let now = ProcessInfo.processInfo.systemUptime
                if now - lastEmission >= 0.033 {
                    await onPartial(accumulator.text)
                    lastEmission = now
                }
            }
            if accumulator.outcome != nil { break }
        }
        return try accumulator.finish()
    }
}
