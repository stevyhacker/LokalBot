import Foundation

/// Optional personalization folded into the cotyping prompt's conditioning
/// preface. Sourced from settings; all fields are opt-in.
struct CotypingPersonalization: Sendable, Equatable {
    var userName: String?
    var styleNote: String?
    var languageHint: String?
    var isMultiLine: Bool
    /// Condition the prompt on the focused app + window title / field placeholder.
    var appContextEnabled: Bool
    /// Free-form glossary / jargon / notes folded into the prompt as context.
    var extendedContext: String?

    static let none = CotypingPersonalization(
        userName: nil, styleNote: nil, languageHint: nil,
        isMultiLine: false, appContextEnabled: false)
}

/// Pure assembly of a `CotypingRequest` from a focused field. Separated from the
/// I/O engine so request construction is unit-testable without a model.
enum CotypingRequestBuilder {
    /// Returns `nil` when the field has no usable context (blank before caret).
    static func build(
        field: CotypingField,
        config: CotypingConfiguration,
        personalization: CotypingPersonalization,
        generation: UInt64,
        clipboardContext: String? = nil,
        memoryContext: String? = nil,
        visibleContext: String? = nil,
        learnedExamples: [String] = [],
        wordPrefixIsValidWord: Bool = true,
        allowsBlankPrefix: Bool = false
    ) -> CotypingRequest? {
        // A blank field gets no suggestion; its prompt can still be prefilled.
        guard allowsBlankPrefix || CotypingPrefixWindow.shouldGenerate(for: field.precedingText) else { return nil }
        let prefix = CotypingPrefixWindow.truncatedPrefix(
            from: field.precedingText,
            maxCharacters: config.maxPrefixCharacters,
            maxWords: config.maxPrefixWords)
        let surfaceLines: [String]
        if personalization.appContextEnabled,
           let surface = CotypingSurfaceComposer.compose(
               appName: field.appName, bundleID: field.bundleID,
               windowTitle: field.windowTitle,
               fieldPlaceholder: field.fieldPlaceholder,
               isIntegratedTerminal: field.isIntegratedTerminal) {
            surfaceLines = CotypingSurfaceComposer.prefaceLines(for: surface)
        } else {
            surfaceLines = []
        }
        let renderedPrompt = CotypingPromptRenderer.render(
            prefixText: prefix,
            surfaceLines: surfaceLines,
            userName: personalization.userName,
            styleNote: personalization.styleNote,
            languageHint: personalization.languageHint,
            extendedContext: personalization.extendedContext,
            clipboardContext: clipboardContext,
            memoryContext: memoryContext,
            visibleContext: visibleContext,
            learnedExamples: learnedExamples)
        return CotypingRequest(
            prompt: renderedPrompt.prompt,
            prefixText: prefix,
            trailingText: field.trailingText,
            isMultiLine: personalization.isMultiLine,
            maxTokens: config.maxResponseTokens,
            maxWords: config.maxResponseWords,
            temperature: config.temperature,
            topP: config.topP,
            topK: config.topK,
            minP: config.minP,
            repeatPenalty: config.repeatPenalty,
            seed: config.seed,
            generation: generation,
            forceWordContinuation: CotypingMidWord.shouldForceContinuation(
                precedingText: field.precedingText, trailingText: field.trailingText),
            wordPrefixAtCaret: CotypingMidWord.currentPartialWord(in: prefix),
            wordPrefixIsValidWord: wordPrefixIsValidWord,
            conditioningPreface: renderedPrompt.conditioningPreface)
    }
}

/// The I/O seam: turn a built request into normalized ghost text. Behind a
/// protocol so the coordinator and the in-app preview can run against a fake in
/// tests without a live server.
@MainActor
protocol CotypingCompleting: AnyObject {
    /// Debounce behavior for the route currently serving completions.
    /// Selectors override this as they move between local and model-server paths.
    var debounceProfile: CotypingDebouncePolicy.RuntimeProfile { get }
    func generate(_ request: CotypingRequest) async throws -> CotypingNormalizationResult
    /// Streaming variant: `onPartial` receives normalized partials as they
    /// arrive. Default (below) is non-streaming.
    func generateStreaming(_ request: CotypingRequest,
                           onPartial: @escaping @Sendable (CotypingNormalizationResult) -> Void) async throws -> CotypingNormalizationResult
    /// Loads + primes any in-process model so the first completion isn't cold.
    /// Default is a no-op: only the in-process `LocalLlamaCotypingEngine` has a
    /// model to prewarm; the HTTP engine boots its server lazily.
    func prewarm() async throws
    /// Best-effort focus-time prompt prefill for in-process engines. This lets
    /// the first real keystroke reuse prompt KV when the user pauses after focus.
    func prewarm(for request: CotypingRequest) async throws
    /// Frees resources owned by the engine. The in-process engine releases its
    /// model/context; the HTTP engine stops its dedicated `llama-server`.
    /// Selectors await this hook before changing routes so two copies of the
    /// cotyping model cannot remain resident at once.
    func unload() async
}

extension CotypingCompleting {
    var debounceProfile: CotypingDebouncePolicy.RuntimeProfile { .modelServer }

    func generateStreaming(_ request: CotypingRequest,
                           onPartial: @escaping @Sendable (CotypingNormalizationResult) -> Void) async throws -> CotypingNormalizationResult {
        let result = try await generate(request)
        onPartial(result)
        return result
    }

    func prewarm() async throws {}

    func prewarm(for request: CotypingRequest) async throws {
        try await prewarm()
    }

    func unload() async {}
}

/// Production engine: resolves LokalBot's configured `TextEngine` (the very same
/// backend used for summarization — built-in llama-server by default, or Ollama
/// / OpenAI-compatible / Apple Intelligence) and runs one raw completion through
/// the shared normalizer.
@MainActor
final class CotypingEngine: CotypingCompleting {
    /// Resolves the active `TextEngine`. In production this is
    /// `ThinkExecution.makeTextEngine(settings)`, which also boots the
    /// built-in llama-server with the selected model on first use.
    private let makeEngine: () async throws -> TextEngine
    private let stopRuntime: () async -> Void
    /// Applies the in-process engine's token healing over plain HTTP: the prompt
    /// is sent cut back to the word boundary, and only output that re-types the
    /// cut text counts. A server cannot be constrained to that prefix, so other
    /// output is suppressed. Off for llama-server, whose prompt stays byte-for-byte.
    private let healsCaretBoundary: Bool

    init(
        makeEngine: @escaping () async throws -> TextEngine,
        stopRuntime: @escaping () async -> Void = {},
        healsCaretBoundary: Bool = false
    ) {
        self.makeEngine = makeEngine
        self.stopRuntime = stopRuntime
        self.healsCaretBoundary = healsCaretBoundary
    }

    /// The resolved `TextEngine` is intentionally short-lived, but its
    /// dedicated built-in server is process-wide. Give the lifecycle owner an
    /// explicit, awaitable way to release that server.
    func unload() async {
        await stopRuntime()
    }

    func generate(_ request: CotypingRequest) async throws -> CotypingNormalizationResult {
        let engine = try await makeEngine()
        let (completion, requiredPrefix) = completionRequest(for: request)
        let raw = try await engine.complete(completion)
        return Self.normalize(raw, requiredPrefix: requiredPrefix, for: request)
    }

    func generateStreaming(_ request: CotypingRequest,
                           onPartial: @escaping @Sendable (CotypingNormalizationResult) -> Void) async throws -> CotypingNormalizationResult {
        let engine = try await makeEngine()
        let (completion, requiredPrefix) = completionRequest(for: request)
        let raw = try await engine.completeStreaming(completion) { cumulative in
            // Nothing is shown until the healed boundary has been re-typed.
            guard cumulative.count > requiredPrefix.count || requiredPrefix.isEmpty else { return }
            onPartial(Self.normalize(cumulative, requiredPrefix: requiredPrefix, for: request))
        }
        return Self.normalize(raw, requiredPrefix: requiredPrefix, for: request)
    }

    private func completionRequest(for request: CotypingRequest) -> (CompletionRequest, requiredPrefix: String) {
        var prompt = request.prompt
        var requiredPrefix = ""
        if healsCaretBoundary {
            let healed = LocalLlamaCotypingEngine.healedGeneration(for: request)
            prompt = healed.prompt
            requiredPrefix = String(decoding: healed.requiredPrefixUTF8, as: UTF8.self)
        }
        // A space joins the first word's token; a cut word fragment needs a few more.
        let healingTokens = requiredPrefix.allSatisfy(\.isWhitespace) ? 0 : 4
        let completion = CompletionRequest(
            prompt: prompt, maxTokens: request.maxTokens + healingTokens, temperature: request.temperature,
            topP: request.topP, topK: request.topK, minP: request.minP,
            repeatPenalty: request.repeatPenalty, seed: request.seed,
            // Single-line mode stops the server at the first newline; the
            // normalizer still collapses defensively.
            stop: request.isMultiLine ? [] : ["\n"])
        return (completion, requiredPrefix)
    }

    nonisolated static func normalize(_ raw: String, requiredPrefix: String,
                                      for request: CotypingRequest) -> CotypingNormalizationResult {
        guard !requiredPrefix.isEmpty else { return CotypingTextNormalizer.normalizeDetailed(raw, for: request) }
        guard raw.hasPrefix(requiredPrefix) else {
            return CotypingNormalizationResult(text: "", suppression: raw.isEmpty ? .emptyGeneration : .wordCompletionMismatch)
        }
        return CotypingTextNormalizer.normalizeDetailed(String(raw.dropFirst(requiredPrefix.count)), for: request)
    }
}
