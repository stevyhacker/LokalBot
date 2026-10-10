import Foundation

/// In-process `CotypingCompleting` conformer. Tokenizes the already-built
/// prompt, drives `LlamaCotypingRuntime`, and reuses the EXACT same
/// normalization + decode-stop policy as the HTTP engine so suggestions are
/// shaped identically. Stops on the stop policy, the token budget, or task
/// cancellation (superseded keystroke).
@MainActor
final class LocalLlamaCotypingEngine: CotypingCompleting {
    private let runtime: LlamaCotypingRuntime
    private let modelPath: String
    private var memoryPressureSource: DispatchSourceMemoryPressure?
    private var inflightPrewarmTask: Task<Void, Never>?
    /// The confidence gate for suggestions at the start of a word; 0 turns it
    /// off (the quality replay does, to compare).
    var minimumFirstWordProbability = CotypingFirstWordConfidence.minimumProbability

    init(runtime: LlamaCotypingRuntime, modelPath: String) {
        self.runtime = runtime
        self.modelPath = modelPath

        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical], queue: .global(qos: .utility))
        // The handler's hold on the source ends when deinit cancels it.
        source.setEventHandler { [runtime, source] in
            let isCritical = source.data.contains(.critical)
            Task { await runtime.handleMemoryPressure(isCritical: isCritical) }
        }
        source.resume()
        self.memoryPressureSource = source
    }

    deinit {
        inflightPrewarmTask?.cancel()
        memoryPressureSource?.cancel()
    }

    /// Loads + primes the model so the first keystroke isn't cold.
    func prewarm() async throws {
        inflightPrewarmTask?.cancel()
        inflightPrewarmTask = nil
        try await runtime.prewarm(modelPath: modelPath)
    }

    /// Best-effort prompt KV prefill for the focused field. A real generation
    /// cancels this so it does not sit behind obsolete warmup work. Prefills
    /// the HEALED prompt so a mid-word generation's KV-reuse probe hits.
    func prewarm(for request: CotypingRequest) async throws {
        inflightPrewarmTask?.cancel()
        let prompt = Self.healedGeneration(for: request).prompt
        let task = Task { [runtime, modelPath] in
            do {
                try await runtime.loadIfNeeded(modelPath: modelPath)
                let promptTokens = await runtime.tokenize(prompt, addBOS: true)
                guard !promptTokens.isEmpty else { return }
                try Task.checkCancellation()
                try await withTaskCancellationHandler {
                    try await runtime.prefill(promptTokens: promptTokens)
                } onCancel: {
                    runtime.abortInFlightDecode()
                }
            } catch {
                // Prompt prefill is opportunistic; the following generation can
                // still run a normal prefill or fall back through the selector.
            }
        }
        inflightPrewarmTask = task
        await task.value
    }

    /// Frees the in-process model + context. Called when the selector routes
    /// away from local (flag toggled off, or the model stops resolving) so the
    /// selected model's weights don't stay resident while completions go to HTTP.
    func unload() async {
        inflightPrewarmTask?.cancel()
        inflightPrewarmTask = nil
        await runtime.unload()
    }

    func generate(_ request: CotypingRequest) async throws -> CotypingNormalizationResult {
        try await run(request, onPartial: nil)
    }

    func generateStreaming(
        _ request: CotypingRequest,
        onPartial: @escaping @Sendable (CotypingNormalizationResult) -> Void
    ) async throws -> CotypingNormalizationResult {
        try await run(request, onPartial: onPartial)
    }

    /// `onPartial` is nil when nobody watches the suggestion form; it is then
    /// normalized once at the end instead of after every token.
    private func run(
        _ request: CotypingRequest,
        onPartial: (@Sendable (CotypingNormalizationResult) -> Void)?
    ) async throws -> CotypingNormalizationResult {
        inflightPrewarmTask?.cancel()
        inflightPrewarmTask = nil
        try Task.checkCancellation()
        try await runtime.loadIfNeeded(modelPath: modelPath)
        try Task.checkCancellation()
        let healed = Self.healedGeneration(for: request)
        let promptTokens = await runtime.tokenize(healed.prompt, addBOS: true)
        try Task.checkCancellation()
        guard !promptTokens.isEmpty else {
            return CotypingNormalizationResult(text: "", suppression: .emptyGeneration)
        }

        let specs = LlamaSamplerSpec.specs(
            temperature: Float(request.temperature),
            topK: Int32(request.topK),
            topP: Float(request.topP),
            minP: Float(request.minP),
            repeatPenalty: Float(request.repeatPenalty),
            repeatLastN: 64,
            seed: UInt32(truncatingIfNeeded: request.seed))

        let accumulator = TokenAccumulator()
        let hybrid = runtime.selectiveOneWordHybrid
        // `try` (not silent `await`): a thrown LlamaRuntimeError.decodeFailed
        // propagates out of run() → the selector's `catch let error as
        // LlamaRuntimeError`, so a decode failure reaches the HTTP fallback
        // instead of surfacing a silent empty/truncated ghost.
        let raw = try await withTaskCancellationHandler {
            try await runtime.generate(
                promptTokens: promptTokens,
                maxTokens: request.maxTokens,
                samplerSpecs: specs,
                requiredPrefixUTF8: healed.requiredPrefixUTF8,
                // A fragment that is not a valid standalone word must keep
                // being spelled across the caret, not merely reach it.
                preferWordExtendingOvershoot: !request.wordPrefixIsValidWord,
                // Inside a word the first token is forced, so it is not weighed.
                minimumFirstWordProbability: request.wordPrefixAtCaret.isEmpty ? minimumFirstWordProbability : 0,
                onLowConfidence: { accumulator.markUnsure() },
                onHybridFallback: { accumulator.markHybridFallback() }
            ) { piece in
                if Task.isCancelled { return false }
                accumulator.append(piece)
                // A fallback is capped only after full normalization, which can
                // still suppress it (for example when a later question mark arrives).
                if !hybrid { onPartial?(CotypingTextNormalizer.normalizeDetailed(accumulator.raw, for: request)) }
                // Native decode-stop at the SAME boundary the HTTP path stops at.
                if CotypingDecodeStopPolicy.verdict(
                    accumulated: accumulator.raw,
                    tokensGenerated: accumulator.count) != nil {
                    return false
                }
                return true
            }
        } onCancel: {
            runtime.abortInFlightDecode()
        }

        if Task.isCancelled { throw CancellationError() }
        if accumulator.isUnsure {
            let result = CotypingNormalizationResult(text: "", suppression: .lowConfidence)
            if hybrid { onPartial?(result) }
            return result
        }
        let normalized = CotypingTextNormalizer.normalizeDetailed(raw, for: request)
        let result = accumulator.isHybridFallback ? Self.oneWordFallback(normalized) : normalized
        if hybrid { onPartial?(result) }
        return result
    }

    /// Cap only the completed normalization result, preserving its suppression.
    /// Matches the offline policy's Unicode word/apostrophe/hyphen definition.
    nonisolated static func oneWordFallback(_ normalized: CotypingNormalizationResult) -> CotypingNormalizationResult {
        guard normalized.suppression == nil, !normalized.text.isEmpty else { return normalized }
        guard let range = normalized.text.range(
            of: #"^\s*[\p{L}\p{N}]+(?:['’\-][\p{L}\p{N}]+)*"#, options: .regularExpression) else {
            return CotypingNormalizationResult(text: "", suppression: .normalizedToEmpty)
        }
        return CotypingNormalizationResult(text: String(normalized.text[range]), suppression: nil)
    }

    /// The healed (prompt, required-prefix) pair for a request. Healing applies
    /// only when the request carries a word fragment at the caret — the same
    /// signal the typo gate and normalizer key off — so boundary caret
    /// positions keep today's prompt byte-for-byte.
    static func healedGeneration(
        for request: CotypingRequest
    ) -> (prompt: String, requiredPrefixUTF8: [UInt8]) {
        guard !request.wordPrefixAtCaret.isEmpty || request.precedingEndsWithWhitespace,
              let split = CotypingTokenHealing.split(prompt: request.prompt) else {
            return (request.prompt, [])
        }
        return (split.healedPrompt, Array(split.requiredPrefix.utf8))
    }
}

/// Reference-typed accumulator the decode closure mutates across token calls.
/// The runtime invokes `onToken` serially on one thread, so no synchronization
/// is required; marked `@unchecked Sendable` only to cross the actor boundary.
private final class TokenAccumulator: @unchecked Sendable {
    private(set) var raw = ""
    private(set) var count = 0
    private(set) var isUnsure = false
    private(set) var isHybridFallback = false
    func markHybridFallback() { isHybridFallback = true }
    func append(_ piece: String) { raw += piece; count += 1 }
    func markUnsure() { isUnsure = true }
}
