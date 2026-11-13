import Foundation
import XCTest
@testable import LokalBot

struct ModelRecording: Codable, Equatable {
    struct Call: Codable, Equatable {
        var purpose: ModelRequestPurpose
        var maxTokens: Int?
        var reasoningBudgetTokens: Int?
        var content: String
        var finishReason: String
        var completionTokens: Int?
        var reasoningTokens: Int?
        var latencyMilliseconds: Int
    }

    var model: String
    var caseName: String
    var recordedAt: Date
    var calls: [Call]

    static func directoryName(for model: String) -> String {
        model.replacingOccurrences(of: "/", with: "__")
    }

    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    /// Every committed recording in the test bundle. Recordings live in one
    /// `<vendor>__<model>` folder per model; other files (the purpose
    /// markers) sit beside those folders.
    static func committed() throws -> [ModelRecording] {
        guard let root = Bundle(for: RecordingTextEngine.self).url(
            forResource: "model-recordings", withExtension: nil, subdirectory: "Fixtures") else { return [] }
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        return try (enumerator?.allObjects as? [URL] ?? [])
            .filter { $0.pathExtension == "json" && $0.deletingLastPathComponent().lastPathComponent.contains("__") }
            .map { try decoder.decode(ModelRecording.self, from: Data(contentsOf: $0)) }
    }

    /// Stub rules that answer each purpose's requests in recorded order.
    func stubRules() -> [[String: Any]] {
        var seen: [ModelRequestPurpose: Int] = [:]
        return calls.map { call in
            let nth = (seen[call.purpose] ?? 0) + 1
            seen[call.purpose] = nth
            let marker = call.purpose.systemMarker
            if call.finishReason == "length" {
                return StubRule.truncate(call.content, keep: 1, system: marker, nth: nth)
            }
            return StubRule.reply(call.content, system: marker, nth: nth)
        }
    }
}

/// Wraps `OpenAICompatibleEngine`, builds requests with LokalBot's own
/// `makeChatRequest`, sends them non-streaming, and records the raw result.
final class RecordingTextEngine: TextEngine, @unchecked Sendable {
    private let base: OpenAICompatibleEngine
    private let lock = NSLock()
    private(set) var calls: [ModelRecording.Call] = []
    private(set) var requestCount = 0
    let requestLimit: Int

    init(base: OpenAICompatibleEngine, requestLimit: Int) {
        self.base = base
        self.requestLimit = requestLimit
    }

    var displayName: String { base.displayName }
    var accountsForGenerationRequests: Bool { base.accountsForGenerationRequests }
    var minimumStructuredOutputTokens: Int { base.minimumStructuredOutputTokens }

    func tokenCount(_ text: String) async throws -> Int? { try await base.tokenCount(text) }

    func generate(system: String, prompt: String, context: [String],
                  options: TextGenerationOptions) async throws -> String {
        try await send(system: system, prompt: prompt, context: context, schema: nil, options: options)
    }

    func generate(system: String, prompt: String, context: [String],
                  schema: [String: Any]) async throws -> String {
        try await send(system: system, prompt: prompt, context: context, schema: schema,
                       options: TextGenerationOptions())
    }

    func generate(system: String, prompt: String, context: [String]) async throws -> String {
        try await send(system: system, prompt: prompt, context: context, schema: nil,
                       options: TextGenerationOptions())
    }

    func generate(system: String, prompt: String, context: [String], schema: [String: Any],
                  options: TextGenerationOptions) async throws -> String {
        try await send(system: system, prompt: prompt, context: context, schema: schema, options: options)
    }

    private func send(system: String, prompt: String, context: [String], schema: [String: Any]?,
                      options: TextGenerationOptions) async throws -> String {
        lock.lock()
        requestCount += 1
        let over = requestCount > requestLimit
        lock.unlock()
        if over { throw TextEngineError.unavailable("recording request limit reached") }
        var request = try base.makeChatRequest(system: system, prompt: prompt, context: context,
                                               schema: schema, options: options)
        if var body = try request.httpBody.flatMap({ try JSONSerialization.jsonObject(with: $0) as? [String: Any] }) {
            body["stream"] = false
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        request.timeoutInterval = 180
        let started = Date()
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw TextEngineError.fromHTTPResponse(response as? HTTPURLResponse, data: data)
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let choice = (json["choices"] as? [[String: Any]])?.first ?? [:]
        let content = (choice["message"] as? [String: Any])?["content"] as? String ?? ""
        let finish = choice["finish_reason"] as? String ?? "stop"
        let usage = json["usage"] as? [String: Any] ?? [:]
        let call = ModelRecording.Call(
            purpose: ModelRequestPurpose.classify(system: system) ?? .ask,
            maxTokens: options.maxTokens,
            reasoningBudgetTokens: options.reasoningBudgetTokens,
            content: content,
            finishReason: finish,
            completionTokens: usage["completion_tokens"] as? Int,
            reasoningTokens: (usage["completion_tokens_details"] as? [String: Any])?["reasoning_tokens"] as? Int,
            latencyMilliseconds: Int(Date().timeIntervalSince(started) * 1_000))
        lock.lock()
        calls.append(call)
        lock.unlock()
        if finish == "length" { throw TextEngineError.outputTruncated }
        return content
    }
}
