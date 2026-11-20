import Foundation

enum AnthropicAPI {
    static let host = "api.anthropic.com"
    static let version = "2023-06-01"
    static let serverFallbackBeta = "server-side-fallback-2026-07-01"

    static func isAnthropic(_ url: URL) -> Bool {
        url.host?.lowercased() == host
    }

    static func versionedRoot(_ baseURL: URL) -> URL {
        var components = URLComponents()
        components.scheme = baseURL.scheme
        components.host = baseURL.host
        components.port = baseURL.port
        components.path = "/v1"
        return components.url ?? baseURL
    }

    static func messagesURL(_ baseURL: URL) -> URL {
        versionedRoot(baseURL).appendingPathComponent("messages")
    }

    static func modelURL(_ baseURL: URL, model: String) -> URL {
        versionedRoot(baseURL).appendingPathComponent("models").appendingPathComponent(model)
    }

    static func authorize(_ request: inout URLRequest, apiKey: String?) {
        request.setValue(version, forHTTPHeaderField: "anthropic-version")
        if let apiKey, !apiKey.isEmpty {
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        }
    }
}

struct AnthropicModelTraits: Equatable, Sendable {
    let effortLevels: [ThinkReasoningLevel]
    let defaultEffort: ThinkReasoningLevel?
    let thinksByDefault: Bool
    let serverFallback: Bool
    let contextTokens: Int?

    private static let families: Set<String> = ["opus", "sonnet", "haiku", "fable", "mythos"]
    private static let serverFallbackModels: Set<String> = [
        "claude-fable-5-1", "claude-opus-5-5", "claude-opus-5", "claude-sonnet-5-5",
    ]

    init(model: String) {
        let name = model.lowercased()
        let parts = name.split(separator: "-").map(String.init)
        let family = parts.count > 1 ? parts[1] : ""
        guard parts.count > 2, parts[0] == "claude", Self.families.contains(family),
              let major = Int(parts[2]) else {
            effortLevels = []
            defaultEffort = nil
            thinksByDefault = false
            serverFallback = false
            contextTokens = nil
            return
        }
        let minor = parts.count > 3 && parts[3].count <= 2 ? Int(parts[3]) ?? 0 : 0
        let current = family == "fable" || family == "mythos" || major >= 5
        if current || (major == 4 && minor >= 7) {
            effortLevels = [.low, .medium, .high, .xhigh, .max]
        } else if major == 4 && minor == 6 {
            effortLevels = [.low, .medium, .high, .max]
        } else if major == 4 && minor == 5 && family == "opus" {
            effortLevels = [.low, .medium, .high]
        } else {
            effortLevels = []
        }
        let mediumDefault = major == 5 && minor == 5 && (family == "opus" || family == "haiku")
        defaultEffort = effortLevels.isEmpty ? nil : mediumDefault ? .medium : .high
        thinksByDefault = current
        serverFallback = Self.serverFallbackModels.contains(name)
        contextTokens = current || (major == 4 && minor >= 6) ? 1_000_000 : 200_000
    }

    var reasoningSupport: ReasoningSupport {
        ReasoningSupport(levels: effortLevels, defaultLevel: defaultEffort)
    }
}

enum AnthropicSchema {
    static let formats: Set<String> = [
        "date-time", "time", "date", "duration", "email", "hostname", "uri", "ipv4", "ipv6", "uuid",
    ]
    static let unsupportedKeywords: Set<String> = [
        "minimum", "maximum", "exclusiveMinimum", "exclusiveMaximum", "multipleOf",
        "minLength", "maxLength", "maxItems", "uniqueItems", "minProperties", "maxProperties",
    ]

    static func adapt(_ schema: [String: Any]) -> [String: Any] {
        var node: [String: Any] = [:]
        var notes: [String] = []
        for (key, value) in schema {
            switch key {
            case "properties", "$defs", "definitions":
                node[key] = (value as? [String: Any])?.mapValues { ($0 as? [String: Any]).map(adapt) ?? $0 } ?? value
            case "items":
                node[key] = (value as? [String: Any]).map(adapt) ?? value
            case "anyOf", "allOf", "oneOf":
                node[key] = (value as? [[String: Any]])?.map(adapt) ?? value
            case "minItems":
                if let count = value as? Int, count > 1 {
                    node[key] = 1
                    notes.append("minItems: \(count)")
                } else {
                    node[key] = value
                }
            case "format":
                if let format = value as? String, !formats.contains(format) {
                    notes.append("format: \(format)")
                } else {
                    node[key] = value
                }
            case "additionalProperties":
                node[key] = false
            default:
                if unsupportedKeywords.contains(key) {
                    notes.append("\(key): \(value)")
                } else {
                    node[key] = value
                }
            }
        }
        let type = node["type"]
        if type as? String == "object" || (type as? [String])?.contains("object") == true {
            node["additionalProperties"] = false
        }
        if !notes.isEmpty {
            let note = "{" + notes.sorted().joined(separator: ", ") + "}"
            node["description"] = (node["description"] as? String).map { "\($0) \(note)" } ?? note
        }
        return node
    }
}

struct AnthropicEngine: TextEngine {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    enum OptionalField: String, Hashable, Sendable {
        case effort, fallbacks
    }

    var baseURL: URL
    var model: String
    var apiKey: String?
    var reasoningLevel: ThinkReasoningLevel = .automatic
    var displayNameOverride: String?
    var transport: Transport?

    static let defaultAnswerTokens = 8_192
    static let maximumWholeResponseTokens = 20_000
    static let maximumStreamedTokens = 64_000

    var traits: AnthropicModelTraits { AnthropicModelTraits(model: model) }
    var displayName: String { displayNameOverride ?? "Anthropic — \(model)" }
    var checkpointIdentity: String { "\(displayName)|\(baseURL.host ?? "")|messages" }
    var accountsForGenerationRequests: Bool { true }
    var structuredOutputEnumLimit: Int? { 500 }

    func generate(system: String, prompt: String, context: [String]) async throws -> String {
        try await message(system: system, prompt: prompt, context: context, schema: nil, options: nil)
    }

    func generate(system: String, prompt: String, context: [String],
                  options: TextGenerationOptions) async throws -> String {
        try await message(system: system, prompt: prompt, context: context, schema: nil, options: options)
    }

    func generate(system: String, prompt: String, context: [String],
                  schema: [String: Any]) async throws -> String {
        try await message(system: system, prompt: prompt, context: context, schema: schema, options: nil)
    }

    func generate(system: String, prompt: String, context: [String],
                  schema: [String: Any],
                  options: TextGenerationOptions) async throws -> String {
        try await message(system: system, prompt: prompt, context: context, schema: schema, options: options)
    }

    func effort(for options: TextGenerationOptions?) -> ThinkReasoningLevel? {
        let support = traits.reasoningSupport
        let budget = options?.reasoningBudgetTokens
        if let level = support.requestLevel(reasoningLevel, taskBudget: budget) { return level }
        guard traits.thinksByDefault, let budget else { return nil }
        return support.clamp(.ceiling(forTaskBudget: budget))
    }

    func maxTokens(requested: Int?, effort: ThinkReasoningLevel?, streaming: Bool) -> Int {
        let answer = max(1, requested ?? Self.defaultAnswerTokens)
        let thinking = traits.thinksByDefault ? Self.thinkingAllowance(effort ?? traits.defaultEffort) : 0
        return min(answer + thinking, streaming ? Self.maximumStreamedTokens : Self.maximumWholeResponseTokens)
    }

    static func thinkingAllowance(_ effort: ThinkReasoningLevel?) -> Int {
        switch effort {
        case .low?: 4_096
        case .medium?: 8_192
        default: 16_384
        }
    }

    func optionalFields(for options: TextGenerationOptions?) -> Set<OptionalField> {
        var fields: Set<OptionalField> = []
        if effort(for: options) != nil { fields.insert(.effort) }
        if traits.serverFallback { fields.insert(.fallbacks) }
        return fields
    }

    func makeRequest(system: String, prompt: String, context: [String],
                     schema: [String: Any]?, options: TextGenerationOptions?,
                     streaming: Bool = false,
                     omitting omitted: Set<OptionalField> = []) throws -> URLRequest {
        guard !model.isEmpty else { throw TextEngineError.noModel }
        var request = URLRequest(url: AnthropicAPI.messagesURL(baseURL))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        AnthropicAPI.authorize(&request, apiKey: apiKey)

        let effort = omitted.contains(.effort) ? nil : effort(for: options)
        var body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens(requested: options?.maxTokens, effort: effort, streaming: streaming),
            "messages": [["role": "user", "content": Self.userContent(prompt: prompt, context: context)]],
        ]
        if !system.isEmpty {
            body["system"] = [["type": "text", "text": system, "cache_control": Self.cacheBreakpoint]]
        }
        var output: [String: Any] = [:]
        if let schema {
            output["format"] = ["type": "json_schema", "schema": AnthropicSchema.adapt(schema)]
        }
        if let effort { output["effort"] = effort.rawValue }
        if !output.isEmpty { body["output_config"] = output }
        if traits.serverFallback, !omitted.contains(.fallbacks) {
            body["fallbacks"] = "default"
            request.setValue(AnthropicAPI.serverFallbackBeta, forHTTPHeaderField: "anthropic-beta")
        }
        if streaming { body["stream"] = true }
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return request
    }

    static var cacheBreakpoint: [String: Any] { ["type": "ephemeral"] }

    static func userContent(prompt: String, context: [String]) -> [[String: Any]] {
        var blocks: [[String: Any]] = []
        for text in context where !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            blocks.append(["type": "text", "text": text])
        }
        if !blocks.isEmpty {
            blocks[blocks.count - 1]["cache_control"] = cacheBreakpoint
        }
        if blocks.isEmpty || !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            blocks.append(["type": "text", "text": prompt])
        }
        return blocks
    }

    static func rejectedFields(in error: Error, sent: Set<OptionalField>) -> Set<OptionalField> {
        guard case .httpStatus(let code, let detail, _) = error as? TextEngineError,
              code == 400 else { return [] }
        var rejected: Set<OptionalField> = []
        if detail.localizedCaseInsensitiveContains("effort") { rejected.insert(.effort) }
        if detail.localizedCaseInsensitiveContains("fallback") { rejected.insert(.fallbacks) }
        return rejected.intersection(sent)
    }

    struct Usage: Equatable, Sendable {
        var inputTokens = 0
        var cacheWriteTokens = 0
        var cacheReadTokens = 0
        var outputTokens: Int?

        var promptTokens: Int { inputTokens + cacheWriteTokens + cacheReadTokens }

        init(inputTokens: Int = 0, cacheWriteTokens: Int = 0, cacheReadTokens: Int = 0, outputTokens: Int? = nil) {
            self.inputTokens = inputTokens
            self.cacheWriteTokens = cacheWriteTokens
            self.cacheReadTokens = cacheReadTokens
            self.outputTokens = outputTokens
        }

        init(json: [String: Any]) {
            merge(json)
        }

        mutating func merge(_ json: [String: Any]) {
            if let value = json["input_tokens"] as? Int { inputTokens = value }
            if let value = json["cache_creation_input_tokens"] as? Int { cacheWriteTokens = value }
            if let value = json["cache_read_input_tokens"] as? Int { cacheReadTokens = value }
            if let value = json["output_tokens"] as? Int { outputTokens = value }
        }
    }

    struct Reply: Equatable {
        var text: String
        var truncated: Bool
        var usage: Usage?
    }

    static func parseMessage(_ data: Data) throws -> Reply {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]] else {
            throw TextEngineError.badResponse("unexpected /v1/messages payload")
        }
        let stopReason = json["stop_reason"] as? String
        if stopReason == "refusal" { throw refusal(json["stop_details"] as? [String: Any]) }
        let text = content
            .filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }
            .joined()
        let truncated = stopReason == "max_tokens" || stopReason == "model_context_window_exceeded"
        guard truncated || !text.isEmpty else {
            throw TextEngineError.badResponse("Claude returned no text")
        }
        return Reply(text: text, truncated: truncated,
                     usage: (json["usage"] as? [String: Any]).map(Usage.init(json:)))
    }

    static func refusal(_ details: [String: Any]?) -> TextEngineError {
        var detail = "Claude declined this request"
        if let category = details?["category"] as? String { detail += " (\(category))" }
        if let explanation = details?["explanation"] as? String, !explanation.isEmpty {
            detail += ": \(explanation.prefix(600))"
        }
        return .badResponse("model refusal: \(detail)")
    }

    enum StreamEvent: Equatable {
        case text(String)
        case usage([String: Int])
        case stop(reason: String?, details: [String: String], usage: [String: Int])
        case done
        case failure(String)
    }

    static func parseStreamLine(_ line: String) -> StreamEvent? {
        guard line.hasPrefix("data:") else { return nil }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard let data = payload.data(using: .utf8),
              let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        switch event["type"] as? String {
        case "message_start":
            let usage = (event["message"] as? [String: Any])?["usage"] as? [String: Any]
            return usage.map { .usage($0.compactMapValues { $0 as? Int }) }
        case "content_block_delta":
            guard let delta = event["delta"] as? [String: Any], delta["type"] as? String == "text_delta",
                  let text = delta["text"] as? String else { return nil }
            return .text(text)
        case "message_delta":
            let delta = event["delta"] as? [String: Any]
            let details = (delta?["stop_details"] as? [String: Any])?.compactMapValues { $0 as? String } ?? [:]
            let usage = (event["usage"] as? [String: Any])?.compactMapValues { $0 as? Int } ?? [:]
            return .stop(reason: delta?["stop_reason"] as? String, details: details, usage: usage)
        case "message_stop":
            return .done
        case "error":
            let message = (event["error"] as? [String: Any])?["message"] as? String
            return .failure(message ?? "stream reported an error")
        default:
            return nil
        }
    }

    private func message(system: String, prompt: String, context: [String],
                         schema: [String: Any]?, options: TextGenerationOptions?) async throws -> String {
        let request = try makeRequest(system: system, prompt: prompt, context: context,
                                      schema: schema, options: options)
        do {
            return try await complete(request, options: options)
        } catch {
            let rejected = Self.rejectedFields(in: error, sent: optionalFields(for: options))
            guard !rejected.isEmpty else { throw error }
            lokalbotLog("anthropic retry without=\(rejected.map(\.rawValue).sorted()) model=\(model)")
            return try await complete(
                try makeRequest(system: system, prompt: prompt, context: context,
                                schema: schema, options: options, omitting: rejected),
                options: options)
        }
    }

    private func logCache(_ usage: Usage) {
        lokalbotLog("anthropic prompt cache write=\(usage.cacheWriteTokens) read=\(usage.cacheReadTokens) "
            + "uncached=\(usage.inputTokens) model=\(model)")
    }

    private func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        if let transport { return try await transport(request) }
        return try await sendInferenceRequest(request, base: AnthropicAPI.versionedRoot(baseURL))
    }

    private func complete(_ request: URLRequest, options: TextGenerationOptions?) async throws -> String {
        let budget = MeetingGenerationBudget.current
        let reservation = try await budget?.reserve(input: MeetingGenerationBudget.promptTokens,
                                                    output: options?.maxTokens ?? 4_096)
        let started = ProcessInfo.processInfo.systemUptime
        var metric = GenerationCallTelemetry(stage: MeetingGenerationBudget.stage, outcome: "failed", wallSeconds: 0)
        do {
            let (data, response) = try await send(request)
            let httpResponse = response as? HTTPURLResponse
            guard let status = httpResponse?.statusCode, (200...299).contains(status) else {
                if let status = httpResponse?.statusCode, (400...499).contains(status) {
                    metric.outcome = "rejected"
                    metric.outputTokens = 0
                }
                throw TextEngineError.fromHTTPResponse(httpResponse, data: data)
            }
            let reply = try Self.parseMessage(data)
            metric.inputTokens = reply.usage?.promptTokens
            metric.outputTokens = reply.usage?.outputTokens
            metric.cachedTokens = reply.usage?.cacheReadTokens
            metric.outcome = reply.truncated ? "truncated" : "complete"
            if let usage = reply.usage { logCache(usage) }
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
            metric.wallSeconds = ProcessInfo.processInfo.systemUptime - started
            metric.log()
            if let reservation { await budget?.finish(reservation, metric: metric) }
            throw error
        }
    }

    func generateStreaming(system: String, prompt: String, context: [String],
                           options: TextGenerationOptions,
                           onPartial: @escaping @MainActor (String) -> Void) async throws -> String {
        guard MeetingGenerationBudget.current == nil, transport == nil else {
            let result = try await generate(system: system, prompt: prompt, context: context, options: options)
            await onPartial(result)
            return result
        }
        let request = try makeRequest(system: system, prompt: prompt, context: context,
                                      schema: nil, options: options, streaming: true)
        do {
            return try await stream(request, onPartial: onPartial)
        } catch {
            let rejected = Self.rejectedFields(in: error, sent: optionalFields(for: options))
            guard !rejected.isEmpty else { throw error }
            lokalbotLog("anthropic stream retry without=\(rejected.map(\.rawValue).sorted()) model=\(model)")
            return try await stream(
                try makeRequest(system: system, prompt: prompt, context: context, schema: nil,
                                options: options, streaming: true, omitting: rejected),
                onPartial: onPartial)
        }
    }

    private func stream(_ request: URLRequest,
                        onPartial: @escaping @MainActor (String) -> Void) async throws -> String {
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await llmSession.bytes(for: request)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw TextEngineError.serverUnreachable(AnthropicAPI.versionedRoot(baseURL).absoluteString,
                                                    transportCode: (error as NSError).code)
        }
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            var body = Data()
            for try await byte in bytes where body.count < 65_536 { body.append(byte) }
            throw TextEngineError.fromHTTPResponse(response as? HTTPURLResponse, data: body)
        }
        var content = ""
        var usage = Usage()
        var stopReason: String?
        var terminal = false
        var lastEmission = -Double.infinity
        for try await line in bytes.lines {
            try Task.checkCancellation()
            switch Self.parseStreamLine(line) {
            case .text(let text)?:
                content += text
                let now = ProcessInfo.processInfo.systemUptime
                if now - lastEmission >= 0.033 {
                    await onPartial(content)
                    lastEmission = now
                }
            case .usage(let counts)?:
                usage.merge(counts)
            case .stop(let reason, let details, let counts)?:
                usage.merge(counts)
                stopReason = reason
                if reason == "refusal" { throw Self.refusal(details) }
            case .done?:
                terminal = true
            case .failure(let message)?:
                throw TextEngineError.badResponse(message)
            case nil:
                continue
            }
            if terminal { break }
        }
        guard terminal else { throw TextEngineError.badResponse("Claude's stream ended before completion") }
        logCache(usage)
        if stopReason == "max_tokens" || stopReason == "model_context_window_exceeded" {
            throw TextEngineError.outputTruncated
        }
        await onPartial(content)
        return strippingReasoning(content)
    }
}
