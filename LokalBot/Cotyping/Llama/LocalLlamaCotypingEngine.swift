import Foundation

@MainActor
final class LocalLlamaCotypingEngine: CotypingCompleting {
    private let runtime: LlamaCotypingRuntime
    private let modelPath: String
    var healingMode: CotypingHealingMode
    var replayHybridFallbackMinimum = CotypingConfidenceDecision.hybridMinimum
    private(set) var lastRawText: String?
    private(set) var lastHealingTrace: CotypingHealingTrace?
    private(set) var lastReplayDiagnostics: CotypingReplayDiagnostics?
    private var memoryPressureSource: DispatchSourceMemoryPressure?
    private var inflightPrewarmTask: Task<Void, Never>?
    var minimumFirstWordProbability = CotypingFirstWordConfidence.minimumProbability

    init(runtime: LlamaCotypingRuntime, modelPath: String) {
        self.runtime = runtime
        self.modelPath = modelPath
        self.healingMode = runtime.selectiveOneWordHybrid ? .prefixSearch : .wordBoundary

        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical], queue: .global(qos: .utility))
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

    func prewarm() async throws {
        inflightPrewarmTask?.cancel()
        inflightPrewarmTask = nil
        try await runtime.prewarm(modelPath: modelPath)
    }

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
            }
        }
        inflightPrewarmTask = task
        await task.value
    }

    func warmAfterPause() async {
        await runtime.touch(ifIdleFor: Self.warmAfterIdle)
    }

    nonisolated static let warmAfterIdle: Duration = .seconds(30)

    func unload() async {
        inflightPrewarmTask?.cancel()
        inflightPrewarmTask = nil
        await runtime.unload()
    }

    func clearReplayCache() async { await runtime.clearReplayCache() }

    func generate(_ request: CotypingRequest) async throws -> CotypingNormalizationResult {
        do {
            let result = try await run(request, onPartial: nil)
            lastReplayDiagnostics = await runtime.lastReplayDiagnostics
            return result
        } catch {
            lastReplayDiagnostics = await runtime.lastReplayDiagnostics
            throw error
        }
    }

    func generateStreaming(
        _ request: CotypingRequest,
        onPartial: @escaping @Sendable (CotypingNormalizationResult) -> Void
    ) async throws -> CotypingNormalizationResult {
        try await run(request, onPartial: onPartial)
    }

    private func run(
        _ request: CotypingRequest,
        onPartial: (@Sendable (CotypingNormalizationResult) -> Void)?
    ) async throws -> CotypingNormalizationResult {
        lastRawText = nil
        lastHealingTrace = nil
        lastReplayDiagnostics = nil
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
        let raw = try await withTaskCancellationHandler {
            try await runtime.generate(
                promptTokens: promptTokens,
                maxTokens: request.maxTokens,
                samplerSpecs: specs,
                requiredPrefixUTF8: healed.requiredPrefixUTF8,
                preferWordExtendingOvershoot: !request.wordPrefixIsValidWord,
                prefixSearchWidth: !request.wordPrefixAtCaret.isEmpty && healingMode == .prefixSearch ? 4 : 1,
                minimumFirstWordProbability: request.wordPrefixAtCaret.isEmpty ? minimumFirstWordProbability : 0,
                hybridFallbackMinimum: replayHybridFallbackMinimum,
                onLowConfidence: { accumulator.markUnsure() },
                onHybridFallback: { accumulator.markHybridFallback() }
            ) { piece in
                if Task.isCancelled { return false }
                accumulator.append(piece)
                if !hybrid { onPartial?(CotypingTextNormalizer.normalizeDetailed(accumulator.raw, for: request)) }
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
        lastRawText = raw
        if runtime.healingTraceEnabled {
            var trace = await runtime.lastHealingTrace
            trace?.canonicalTokens = await runtime.tokenize(request.prompt + raw, addBOS: true)
            lastHealingTrace = trace
        }
        let normalized = CotypingTextNormalizer.normalizeDetailed(raw, for: request)
        let result = accumulator.isHybridFallback ? Self.oneWordFallback(normalized) : normalized
        if hybrid { onPartial?(result) }
        return result
    }

    nonisolated static func oneWordFallback(_ normalized: CotypingNormalizationResult) -> CotypingNormalizationResult {
        guard normalized.suppression == nil, !normalized.text.isEmpty else { return normalized }
        guard let range = normalized.text.range(
            of: #"^\s*[\p{L}\p{N}]+(?:['’\-][\p{L}\p{N}]+)*"#, options: .regularExpression) else {
            return CotypingNormalizationResult(text: "", suppression: .normalizedToEmpty)
        }
        return CotypingNormalizationResult(text: String(normalized.text[range]), suppression: nil)
    }

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

private final class TokenAccumulator: @unchecked Sendable {
    private(set) var raw = ""
    private(set) var count = 0
    private(set) var isUnsure = false
    private(set) var isHybridFallback = false
    func markHybridFallback() { isHybridFallback = true }
    func append(_ piece: String) { raw += piece; count += 1 }
    func markUnsure() { isUnsure = true }
}
