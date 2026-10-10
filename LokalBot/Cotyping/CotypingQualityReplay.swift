import Foundation

/// Explicit, headless replay of synthetic writing. References/scoring stay in the
/// caller: the model receives only the already-typed text and permitted context.
/// Uses production request construction, token healing, decoding and normalization.
enum CotypingQualityReplay {
    /// Which model serves the replay. Remote runs exist only to compare hosted
    /// models against the local one; the app itself never sends autocomplete text out.
    enum Engine: Equatable {
        /// The production in-process GGUF runtime.
        case local(model: URL)
        /// A hosted raw `/v1/completions` endpoint behind the HTTP `CotypingEngine`.
        /// The key comes from `LOKALBOT_REPLAY_API_KEY`, never the command line.
        /// `extraBodyJSON` is a JSON object merged into every request body.
        /// `chat` asks through `/chat/completions` instead, for hosts whose raw
        /// endpoint cannot serve the model: the prompt is the user message.
        case remote(baseURL: URL, model: String, extraBodyJSON: String?, chat: Bool = false)

        static let apiKeyEnvironmentKey = "LOKALBOT_REPLAY_API_KEY"

        static func parse(_ args: [String]) -> Engine? {
            func value(after flag: String) -> String? {
                args.firstIndex(of: flag).flatMap { args.count > $0 + 1 ? args[$0 + 1] : nil }
            }
            if let model = value(after: "--model-path") {
                return .local(model: URL(fileURLWithPath: model))
            }
            guard let base = value(after: "--completions-url"), let baseURL = URL(string: base),
                  baseURL.scheme == "https" || ["127.0.0.1", "localhost"].contains(baseURL.host ?? ""),
                  let model = value(after: "--completions-model"), !model.isEmpty else { return nil }
            return .remote(baseURL: baseURL, model: model, extraBodyJSON: value(after: "--completions-extra-body"),
                           chat: args.contains("--completions-chat"))
        }
    }

    /// A rate limit or provider hiccup is retried so it does not score as a miss;
    /// only the attempt that answered is timed.
    static let remoteRetryLimit = 5

    struct Input: Decodable {
        var cases: [Case]
        var maxWords: Int?
        var maxTokens: Int?
        var maxPrefixCharacters: Int?
        var maxPrefixWords: Int?
        var temperature: Double?
        var repeatPenalty: Double?
        var appContext: Bool?
        var userName: String?
        var styleNote: String?
        var languageHint: String?
        var extendedContext: String?
        var memoryItems: [CotypingMemoryContext.Item]?
        var useMeetingMemory: Bool?
        var useScreenMemory: Bool?
        var memoryNow: Date?
        var useVisibleContext: Bool?
        /// False turns the confidence gate off, to compare against it.
        var confidenceGate: Bool?
        /// Same opt-in flag as Settings → Writing → Autocomplete.
        var selectiveOneWordHybrid: Bool?
    }

    struct Case: Decodable {
        var id: String
        var prefix: String
        var trailing: String?
        var appName: String?
        var bundleID: String?
        var windowTitle: String?
        var placeholder: String?
        var wordPrefixIsValidWord: Bool?
        /// Explicit experiment control, recorded in output. Omit for product replay.
        var promptOverride: String?
        var visibleContext: CotypingVisibleContextReplay.Fixture?
    }

    struct Observation: Encodable {
        var id: String
        var prompt: String
        var text: String
        var suppression: String?
        var latencyMs: Double
        var error: String?
        var usedPromptOverride: Bool
        var memoryIDs: [String] = []
        var visibleIDs: [String] = []
        var visibleTextReadIDs: [String] = []
        var attempts = 1
        var selectiveOneWordHybrid = false
    }

    @MainActor
    static func run(input: URL, engine engineChoice: Engine) async -> Int32 {
        var activeEngine: CotypingCompleting?
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let fixture = try decoder.decode(Input.self, from: Data(contentsOf: input))
            guard !fixture.cases.isEmpty,
                  Set(fixture.cases.map(\.id)).count == fixture.cases.count else {
                throw ReplayError.invalidCases
            }
            try validateHybrid(fixture, engine: engineChoice)
            let config = try configuration(for: fixture)
            let engine: CotypingCompleting
            var retryLimit = 0
            switch engineChoice {
            case .local(let model):
                engine = LocalLlamaCotypingEngine(runtime: LlamaCotypingRuntime(selectiveOneWordHybrid: fixture.selectiveOneWordHybrid == true), modelPath: model.path)
            case .remote(let baseURL, let model, let extraBodyJSON, let chat):
                guard let extraBody = extraBody(from: extraBodyJSON) else {
                    try? FileHandle.standardError.write(contentsOf: Data("Cotyping replay: --completions-extra-body must be a JSON object\n".utf8))
                    return 1
                }
                let remote = OpenAICompatibleEngine(
                    baseURL: baseURL, model: model,
                    apiKey: ProcessInfo.processInfo.environment[Engine.apiKeyEnvironmentKey],
                    extraBody: extraBody, sendsLlamaSamplingExtensions: false,
                    chatDialect: .inferred(from: baseURL))
                // A chat message has no token boundary at the caret, so it is not healed.
                engine = chat
                    ? CotypingEngine(makeEngine: { ChatContinuationEngine(base: remote) })
                    : CotypingEngine(makeEngine: { remote }, healsCaretBoundary: true)
                retryLimit = remoteRetryLimit
            }
            activeEngine = engine
            // The gate reads the local model's token probabilities; hosted engines have none.
            if fixture.confidenceGate == false, let local = engine as? LocalLlamaCotypingEngine {
                local.minimumFirstWordProbability = 0
            }
            let personalization = CotypingPersonalization(
                userName: fixture.userName, styleNote: fixture.styleNote,
                languageHint: fixture.languageHint, isMultiLine: false,
                appContextEnabled: fixture.appContext ?? true,
                extendedContext: fixture.extendedContext)
            // Loading/Metal priming is outside warm prediction latency.
            try await engine.prewarm()
            if case .remote = engineChoice {
                // Opens the connection outside the timed cases, and stops a bad key,
                // model ID or rejected field before it fails every case.
                try await warmUpConnection(engine, config: config)
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            var failed = false
            for (index, item) in fixture.cases.enumerated() {
                var observation = await replay(item, generation: UInt64(index), config: config,
                                               personalization: personalization, engine: engine, fixture: fixture,
                                               retryLimit: retryLimit)
                observation.selectiveOneWordHybrid = fixture.selectiveOneWordHybrid == true
                failed = failed || observation.error != nil
                let line = try encoder.encode(observation) + Data([10])
                try FileHandle.standardOutput.write(contentsOf: line)
            }
            await engine.unload()
            return failed ? 1 : 0
        } catch {
            try? FileHandle.standardError.write(contentsOf: Data("Cotyping replay: \(error)\n".utf8))
            await activeEngine?.unload()
            return 1
        }
    }

    static func validateHybrid(_ input: Input, engine: Engine) throws {
        guard input.selectiveOneWordHybrid == true else { return }
        guard case .local = engine, input.confidenceGate != false else {
            throw ReplayError.invalidConfiguration
        }
    }

    static func configuration(for input: Input) throws -> CotypingConfiguration {
        var config = CotypingConfiguration.standard
        let settings = AppSettings()
        config.maxResponseWords = input.maxWords ?? settings.cotypingMaxWords
        config.maxResponseTokens = input.maxTokens ?? settings.cotypingMaxResponseTokens
        config.maxPrefixCharacters = input.maxPrefixCharacters ?? config.maxPrefixCharacters
        config.maxPrefixWords = input.maxPrefixWords ?? config.maxPrefixWords
        config.temperature = input.temperature ?? config.temperature
        config.repeatPenalty = input.repeatPenalty ?? config.repeatPenalty
        guard (1...30).contains(config.maxResponseWords), (1...120).contains(config.maxResponseTokens),
              (1...14000).contains(config.maxPrefixCharacters), (1...2400).contains(config.maxPrefixWords),
              config.temperature.isFinite, (0...2).contains(config.temperature),
              config.repeatPenalty.isFinite, (0.5...2).contains(config.repeatPenalty) else {
            throw ReplayError.invalidConfiguration
        }
        return config
    }

    static func extraBody(from json: String?) -> [String: Any]? {
        guard let json else { return [:] }
        return (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]
    }

    /// Seconds to wait before retrying a remote failure, or nil when retrying
    /// cannot help (bad key, unknown model, rejected request field).
    static func retryDelay(after error: Error, attempt: Int) -> TimeInterval? {
        let backoff = min(pow(2, Double(attempt - 1)), 16)
        switch error as? TextEngineError {
        case .httpStatus(let code, _, let retryAfter)? where code == 429 || code >= 500:
            return min(retryAfter ?? backoff, 30)
        case .serverUnreachable?:
            return backoff
        default:
            return nil
        }
    }

    @MainActor
    private static func warmUpConnection(_ engine: CotypingCompleting, config: CotypingConfiguration) async throws {
        let field = CotypingField(
            appName: "Notes", bundleID: "com.apple.Notes", processID: 0, role: "AXTextArea",
            precedingText: "Thanks for the ", trailingText: "", selectionLength: 0,
            caretRect: .zero, isSecure: false, caretIsExact: true)
        guard let request = CotypingRequestBuilder.build(
            field: field, config: config, personalization: .none, generation: 0) else { return }
        _ = try await engine.generate(request)
    }

    @MainActor
    private static func replay(
        _ item: Case, generation: UInt64, config: CotypingConfiguration,
        personalization: CotypingPersonalization, engine: CotypingCompleting, fixture: Input,
        retryLimit: Int
    ) async -> Observation {
        var field = CotypingField(
            appName: item.appName ?? "Notes", bundleID: item.bundleID ?? "com.apple.Notes",
            processID: 0, role: "AXTextArea", precedingText: item.prefix,
            trailingText: item.trailing ?? "", selectionLength: 0,
            caretRect: .zero, isSecure: false, caretIsExact: true,
            windowTitle: item.windowTitle, fieldPlaceholder: item.placeholder)
        let visibleSource = item.visibleContext.map(CotypingVisibleContextReplay.init)
        let visible = visibleSource?.capture(enabled: fixture.useVisibleContext ?? false)
        field.visibleContext = visible
        let memory = CotypingMemoryContext.select(
            items: fixture.memoryItems ?? [], for: field, includeTitle: personalization.appContextEnabled,
            policy: .init(meetings: fixture.useMeetingMemory ?? false, screenDerived: fixture.useScreenMemory ?? false),
            now: fixture.memoryNow ?? Date())
        guard let built = CotypingRequestBuilder.build(
            field: field, config: config, personalization: personalization, generation: generation,
            memoryContext: memory.text,
            visibleContext: visible?.text,
            wordPrefixIsValidWord: item.wordPrefixIsValidWord ?? true) else {
            return Observation(id: item.id, prompt: "", text: "", suppression: "pre-generation-gate",
                               latencyMs: 0, usedPromptOverride: false)
        }
        let request = overridingPrompt(item.promptOverride, in: built)
        var attempt = 1
        while true {
            let start = ContinuousClock.now
            do {
                let result = try await engine.generate(request)
                return Observation(id: item.id, prompt: request.prompt, text: result.text,
                                   suppression: result.suppression?.rawValue,
                                   latencyMs: milliseconds(since: start), usedPromptOverride: item.promptOverride != nil,
                                   memoryIDs: memory.items.map(\.id),
                                   visibleIDs: visible?.excerpts.map(\.id) ?? [],
                                   visibleTextReadIDs: visibleSource?.textReadIDs ?? [],
                                   attempts: attempt)
            } catch {
                if attempt <= retryLimit, let delay = retryDelay(after: error, attempt: attempt) {
                    try? await Task.sleep(for: .seconds(delay))
                    attempt += 1
                    continue
                }
                return Observation(id: item.id, prompt: request.prompt, text: "",
                                   latencyMs: milliseconds(since: start), error: String(describing: error),
                                   usedPromptOverride: item.promptOverride != nil, attempts: attempt)
            }
        }
    }

    private static func milliseconds(since start: ContinuousClock.Instant) -> Double {
        let elapsed = start.duration(to: .now).components
        return Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
    }

    private static func overridingPrompt(_ prompt: String?, in request: CotypingRequest) -> CotypingRequest {
        guard let prompt else { return request }
        return CotypingRequest(
            prompt: prompt, prefixText: request.prefixText, trailingText: request.trailingText,
            isMultiLine: request.isMultiLine, maxTokens: request.maxTokens, maxWords: request.maxWords,
            temperature: request.temperature, topP: request.topP, topK: request.topK, minP: request.minP,
            repeatPenalty: request.repeatPenalty, seed: request.seed, generation: request.generation,
            forceWordContinuation: request.forceWordContinuation, wordPrefixAtCaret: request.wordPrefixAtCaret,
            wordPrefixIsValidWord: request.wordPrefixIsValidWord, conditioningPreface: request.conditioningPreface)
    }

    enum ReplayError: Error { case invalidCases, invalidConfiguration }
}

/// Autocomplete through a chat endpoint: the app's autocomplete instruction as the
/// system message and the rendered prompt as the user message, with thinking off.
/// The reply budget is at least 32 tokens, so a phrase that runs a little long is
/// trimmed by the normalizer instead of failing as truncated. An empty reply means
/// the model had nothing to add, which is an empty suggestion rather than an error.
private struct ChatContinuationEngine: TextEngine {
    let base: OpenAICompatibleEngine

    var displayName: String { base.displayName }

    func generate(system: String, prompt: String, context: [String]) async throws -> String {
        try await base.generate(system: system, prompt: prompt, context: context)
    }

    func complete(_ request: CompletionRequest) async throws -> String {
        do {
            return try await base.generate(
                system: PromptTemplates.autocompleteSystem, prompt: request.prompt, context: [],
                options: TextGenerationOptions(maxTokens: max(request.maxTokens, 32), reasoningBudgetTokens: 0,
                                               temperature: request.temperature))
        } catch TextEngineError.badResponse(let detail) where detail.contains("contained no text") {
            return ""
        }
    }
}
