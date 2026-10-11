import Accelerate
import Foundation
import LlamaCore

enum LlamaRuntimeError: Error, Equatable {
    case modelLoadFailed(String)
    case contextInitFailed
    case decodeFailed
}

private final class LlamaDecodeAbortState: @unchecked Sendable {
    private let lock = NSLock()
    private var abortRequested = false
    private var decodeActive = false

    /// Starts one decode scope. Abort requests made while no decode is active
    /// are intentionally ignored, so cancelling an old request cannot poison
    /// the next generation.
    func beginDecode() {
        lock.lock()
        decodeActive = true
        abortRequested = false
        lock.unlock()
    }

    func endDecode() {
        lock.lock()
        decodeActive = false
        abortRequested = false
        lock.unlock()
    }

    func requestAbort() {
        lock.lock()
        if decodeActive { abortRequested = true }
        lock.unlock()
    }

    var isAbortRequested: Bool {
        lock.lock()
        defer { lock.unlock() }
        return abortRequested
    }
}

private func llamaCotypingAbortCallback(_ rawState: UnsafeMutableRawPointer?) -> Bool {
    guard let rawState else { return false }
    let state = Unmanaged<LlamaDecodeAbortState>.fromOpaque(rawState).takeUnretainedValue()
    return state.isAbortRequested
}

/// In-process llama.cpp runtime for cotyping. Owns the model, a persistent
/// context + memory, and serializes all inference on the actor's executor
/// (off the main actor).
///
/// The KV-reuse probe (`IncrementalPrefill`) reports how much of each prompt
/// overlaps the previous one. On a pure-attention model this drives true
/// partial-prefix reuse: the shared prefix KV is kept and only the diverged
/// suffix is re-decoded. Hybrid/recurrent models cannot rewind their rolling
/// state to a prefix, so focus prefill records only the logical prompt baseline
/// and generation falls back to a full re-prefill; `lastPrefillTokenCount` still
/// surfaces the diverged-suffix length as the meaningful reuse signal either
/// way. The capability is cached once at load (`supportsPartialReuse`).
///
/// Built against the llama.cpp pinned in `Scripts/fetch-llama.sh`; symbols are
/// verified against the vendored dylib.
actor LlamaCotypingRuntime {
    typealias PostLoadAdmissionHook = @Sendable () async -> Void

    private var model: OpaquePointer?
    private var ctx: OpaquePointer?
    private var vocab: OpaquePointer?
    private var loadedModelPath: String?
    private var residencyGeneration: UUID?
    /// Actor methods are reentrant at `await` points. Serialize model loads so
    /// concurrent prewarm and first-generation calls cannot mmap the same
    /// weights twice while `willLoad` is suspended.
    private var loadInProgress = false
    private var loadWaiters: [CheckedContinuation<Void, Never>] = []
    /// Invalidates a load that was already in flight when `unload()` ran.
    /// Actor isolation alone is insufficient here: `loadIfNeeded` suspends while
    /// consulting the main-actor residency ledger, so `unload()` can otherwise
    /// observe an empty runtime and return before that older load resumes and
    /// installs its model.
    private var unloadEpoch: UInt64 = 0
    /// Test seam placed immediately after residency admission. Production uses
    /// the no-op default; tests suspend here to deterministically exercise the
    /// unload-vs-load race without loading a multi-gigabyte GGUF.
    private let postLoadAdmissionHook: PostLoadAdmissionHook
    /// The prompt most recently prefilled into the context (basis for the
    /// incremental KV-reuse probe against the next prompt).
    private var cachedTokens: [Int32] = []
    private var lastDecodeTokenCount = 0
    private var lastLogitsPosition: Int32?
    private var lastLogitsToken: Int32?
    private var tokenPrefixIndex: CotypingTokenPrefixIndex?
    private(set) var lastPrefillTokenCount: Int = 0
    /// Reused for the confidence gate's softmax, one float per vocabulary entry.
    private var probabilityScratch: [Float] = []
    private var boundaryTokenMask: [Float] = []
    private let confidenceBoundaryMode: CotypingConfidenceBoundaryMode
    nonisolated let selectiveOneWordHybrid: Bool
    nonisolated let confidenceTraceEnabled: Bool
    nonisolated let healingTraceEnabled: Bool
    nonisolated let searchExperiment: CotypingSearchExperiment
    nonisolated let replayThreadCount: Int32?
    nonisolated let replayBatchThreadCount: Int32?
    /// Replay-only cancellation experiments; app policy remains unchanged until measured.
    nonisolated let replayPrefillChunkSize: Int
    nonisolated let replayPrefillFirstChunkSize: Int?
    nonisolated let replayFinalPrefillLogitsOnly: Bool
    nonisolated let replaySynchronizePrefillChunks: Bool
    private(set) var lastHealingTrace: CotypingHealingTrace?
    private(set) var lastReplayDiagnostics = CotypingReplayDiagnostics()
    /// When a suggestion was last generated, for the memory-pressure policy.
    private var lastUsedUptime: TimeInterval?
    /// True only for pure-attention models, whose per-position KV cells can be
    /// partially evicted (`seq_rm` at a non-zero p0). Recurrent/hybrid (SSM/Mamba)
    /// models cannot rewind their rolling state to a prefix, so they full-reprefill.
    private var supportsPartialReuse = false
    /// Thread-safe bridge into llama.cpp's abort callback. A superseded Task can
    /// flip this from outside the actor while `llama_decode` is still running.
    private let decodeAbortState = LlamaDecodeAbortState()

    /// Initializes the llama backend exactly once across ALL instances. Swift
    /// guarantees a static `let` initializer runs once and is thread-safe, which
    /// removes the cross-instance check-then-set race a `static var` flag would have
    /// (actor isolation does not protect static storage).
    private static let backendReady: Void = {
        llama_backend_init()
    }()

    init(confidenceBoundaryMode: CotypingConfidenceBoundaryMode = .selectedToken,
         selectiveOneWordHybrid: Bool = false,
         confidenceTraceEnabled: Bool = false, healingTraceEnabled: Bool = false,
         searchExperiment: CotypingSearchExperiment = .baseline, replayThreadCount: Int32? = nil,
         replayBatchThreadCount: Int32? = nil,
         replayPrefillChunkSize: Int = 256, replayPrefillFirstChunkSize: Int? = nil,
         replayFinalPrefillLogitsOnly: Bool = false,
         replaySynchronizePrefillChunks: Bool = false,
         postLoadAdmissionHook: @escaping PostLoadAdmissionHook = {}) {
        self.confidenceBoundaryMode = confidenceBoundaryMode
        self.selectiveOneWordHybrid = selectiveOneWordHybrid
        self.confidenceTraceEnabled = confidenceTraceEnabled
        self.healingTraceEnabled = healingTraceEnabled
        self.searchExperiment = searchExperiment
        self.replayThreadCount = replayThreadCount
        self.replayBatchThreadCount = replayBatchThreadCount
        self.replayPrefillChunkSize = min(2048, max(1, replayPrefillChunkSize))
        self.replayPrefillFirstChunkSize = replayPrefillFirstChunkSize.map { min(256, max(1, $0)) }
        self.replayFinalPrefillLogitsOnly = replayFinalPrefillLogitsOnly
        self.replaySynchronizePrefillChunks = replaySynchronizePrefillChunks
        self.postLoadAdmissionHook = postLoadAdmissionHook
    }

    /// All app autocomplete uses the measured hybrid policy. Replay keeps its
    /// explicit controls and baseline initializer defaults for historical parity.
    /// Two generation/prefill threads won the fixed-E2B M4 Max latency study;
    /// other hardware and cancellation responsiveness still need broader trials.
    nonisolated static func forAutocomplete() -> LlamaCotypingRuntime {
        LlamaCotypingRuntime(selectiveOneWordHybrid: true, searchExperiment: .certified, replayThreadCount: 2)
    }

    var isLoaded: Bool { model != nil && ctx != nil }

    var canReusePromptPrefix: Bool { supportsPartialReuse }

    nonisolated func abortInFlightDecode() {
        decodeAbortState.requestAbort()
    }

    // MARK: - Lifecycle

    func loadIfNeeded(modelPath: String) async throws {
        let loadEpoch = unloadEpoch
        while loadInProgress {
            await withCheckedContinuation { continuation in
                loadWaiters.append(continuation)
            }
        }
        try requireActiveLoad(epoch: loadEpoch)
        if isLoaded, loadedModelPath == modelPath {
            await ModelResidency.shared.touch(id: Self.residencyID)
            try requireActiveLoad(epoch: loadEpoch)
            return
        }
        loadInProgress = true
        defer { finishLoad() }
        releaseLoadedResources()
        // Make room before llama mmaps the weights: evict LRU models first
        // if this load would push total resident weights past the budget.
        let loadReservation = await ModelResidency.shared.willLoad(
            id: Self.residencyID,
            bytes: ModelResidency.weightBytes(at: URL(fileURLWithPath: modelPath)),
            currentReservedBytes: {
                Int64(clamping: ModelRuntimeRegistry.shared.totalEstimatedBytes)
            })
        await postLoadAdmissionHook()
        do {
            try requireActiveLoad(epoch: loadEpoch)
        } catch {
            await ModelResidency.shared.cancelLoad(loadReservation)
            throw error
        }

        _ = Self.backendReady   // forces the run-once backend init (idempotent)

        var mparams = llama_model_default_params()
        mparams.n_gpu_layers = 99   // full Metal offload (matches LlamaServer's -ngl 99)
        guard let m = llama_model_load_from_file(modelPath, mparams) else {
            await ModelResidency.shared.cancelLoad(loadReservation)
            throw LlamaRuntimeError.modelLoadFailed(modelPath)
        }
        do {
            try requireActiveLoad(epoch: loadEpoch)
        } catch {
            llama_model_free(m)
            await ModelResidency.shared.cancelLoad(loadReservation)
            throw error
        }

        var cparams = llama_context_default_params()
        cparams.n_ctx = 2048        // matches LlamaServer.cotyping.contextTokens
        cparams.n_batch = 2048
        let threads = replayThreadCount ?? Int32(max(1, ProcessInfo.processInfo.activeProcessorCount - 2))
        cparams.n_threads = threads
        cparams.n_threads_batch = replayBatchThreadCount ?? threads
        guard let c = llama_init_from_model(m, cparams) else {
            llama_model_free(m)
            await ModelResidency.shared.cancelLoad(loadReservation)
            throw LlamaRuntimeError.contextInitFailed
        }
        do {
            try requireActiveLoad(epoch: loadEpoch)
        } catch {
            llama_free(c)
            llama_model_free(m)
            await ModelResidency.shared.cancelLoad(loadReservation)
            throw error
        }
        llama_set_abort_callback(
            c,
            llamaCotypingAbortCallback,
            Unmanaged.passUnretained(decodeAbortState).toOpaque())

        model = m
        ctx = c
        vocab = llama_model_get_vocab(m)
        loadedModelPath = modelPath
        cachedTokens = []
        lastPrefillTokenCount = 0
        // Cache the architecture capability once, at load: probing inside generate
        // would emit a dylib stderr warning on every call for recurrent models.
        supportsPartialReuse = !llama_model_is_recurrent(m) && !llama_model_is_hybrid(m)
        if confidenceBoundaryMode == .boundaryMass || selectiveOneWordHybrid, let vocab {
            boundaryTokenMask = (0..<llama_vocab_n_tokens(vocab)).map { token in
                if llama_vocab_is_eog(vocab, token) { return 1 }
                if llama_vocab_is_control(vocab, token) { return 0 }
                return CotypingFirstWordConfidence.tokenStartsBoundary(pieceBytes(for: token)) ? 1 : 0
            }
        }
        warmup()
        let generation = UUID()
        residencyGeneration = generation
        await ModelResidency.shared.register(
            id: Self.residencyID,
            label: URL(fileURLWithPath: modelPath).lastPathComponent + " · in-process",
            bytes: ModelResidency.weightBytes(at: URL(fileURLWithPath: modelPath)),
            generation: generation,
            unload: { [weak self] in await self?.unload() })
        do {
            try requireActiveLoad(epoch: loadEpoch)
        } catch {
            // If the epoch moved, the explicit unload already freed the pointers.
            // If only this task was cancelled while registration was suspended,
            // free them here. In both cases remove only this load's ledger row;
            // a replacement runtime may already have registered under the same ID.
            if unloadEpoch == loadEpoch {
                releaseLoadedResources(scheduleResidencyUnregister: false)
            }
            await ModelResidency.shared.unregister(
                id: Self.residencyID,
                ifGenerationMatches: generation)
            throw error
        }
    }

    /// One in-process runtime holds weights at a time, so a single ledger row.
    private static let residencyID = "cotyping-in-process"

    /// Frees the llama context + model when the actor is deallocated. Without
    /// this the Metal backend's residency set is still live at process exit,
    /// which trips a teardown assertion in the vendored ggml-metal build.
    deinit {
        let generation = residencyGeneration
        if let c = ctx { llama_free(c) }
        if let m = model { llama_model_free(m) }
        if let generation {
            Task { @MainActor in
                ModelResidency.shared.unregister(
                    id: Self.residencyID,
                    ifGenerationMatches: generation)
            }
        }
    }

    private func finishLoad() {
        loadInProgress = false
        let waiters = loadWaiters
        loadWaiters.removeAll(keepingCapacity: true)
        waiters.forEach { $0.resume() }
    }

    private func requireActiveLoad(epoch: UInt64) throws {
        try Task.checkCancellation()
        guard unloadEpoch == epoch else { throw CancellationError() }
    }

    /// Prewarm == load + the priming decode `loadIfNeeded` already performs.
    func prewarm(modelPath: String) async throws { try await loadIfNeeded(modelPath: modelPath) }

    /// Decodes a prompt into KV without sampling so a later generation can reuse
    /// it. Cancellation/failure clears KV because a partial prefill must never
    /// masquerade as the prompt represented by `cachedTokens`.
    func prefill(promptTokens: [Int32]) throws {
        guard let ctx, !promptTokens.isEmpty else { return }
        let promptTokens = Self.boundedPromptTokens(
            promptTokens, contextSize: Int(llama_n_ctx(ctx)), outputReserve: 120)
        decodeAbortState.beginDecode()
        defer { decodeAbortState.endDecode() }
        try Task.checkCancellation()
        guard supportsPartialReuse else {
            // CoTabby avoids speculative prefills once a model cannot reuse a
            // prompt KV prefix. For hybrid/recurrent models this keeps focus
            // prewarm from doubling the first real autocomplete decode while
            // preserving the logical prefix baseline used for diagnostics.
            cachedTokens = promptTokens
            lastPrefillTokenCount = 0
            return
        }
        let mem = llama_get_memory(ctx)
        let shared = IncrementalPrefill.commonPrefixLength(cachedTokens, promptTokens)
        let reuse = min(shared, promptTokens.count - 1)

        do {
            if supportsPartialReuse, reuse > 0,
               llama_memory_seq_rm(mem, 0, Int32(reuse), -1) {
                try decodeCancellable(
                    Array(promptTokens[reuse...]),
                    startPos: Int32(reuse),
                    logitsLastOnly: true)
            } else {
                llama_memory_seq_rm(mem, 0, 0, -1)
                try decodeCancellable(promptTokens, startPos: 0, logitsLastOnly: true)
            }
            lastPrefillTokenCount = promptTokens.count - reuse
            cachedTokens = promptTokens
        } catch {
            llama_memory_seq_rm(mem, 0, 0, -1)
            cachedTokens = []
            lastPrefillTokenCount = 0
            throw error
        }
    }

    func unload() {
        unloadEpoch &+= 1
        releaseLoadedResources()
    }

    /// Frees the currently installed pointers without invalidating the load that
    /// intentionally called it while switching model paths. External teardown
    /// must go through `unload()`, which advances `unloadEpoch` first.
    private func releaseLoadedResources(scheduleResidencyUnregister: Bool = true) {
        let generation = residencyGeneration
        residencyGeneration = nil
        if let c = ctx { llama_free(c) }
        if let m = model { llama_model_free(m) }
        ctx = nil
        model = nil
        vocab = nil
        loadedModelPath = nil
        cachedTokens = []
        supportsPartialReuse = false
        tokenPrefixIndex = nil
        boundaryTokenMask = []
        probabilityScratch = []
        // Keep this path synchronous for memory pressure, but only remove the
        // generation that was actually freed. A reload may register before
        // this main-actor task gets its turn.
        if scheduleResidencyUnregister, let generation {
            Task { @MainActor in
                ModelResidency.shared.unregister(
                    id: Self.residencyID,
                    ifGenerationMatches: generation)
            }
        }
    }

    /// Frees the model + context under memory pressure. The next `generate`
    /// call lazily reloads via `loadIfNeeded` (or the engine routes to HTTP if
    /// reload fails). Keeps cotyping from OOMing the app under a large model.
    ///
    /// A warning while someone is typing leaves the model loaded: dropping it
    /// would make their next keystroke wait for a reload. Critical pressure,
    /// or a warning after a minute without suggestions, frees it.
    func handleMemoryPressure(isCritical: Bool = true) {
        guard isCritical || Self.isIdle(lastUsedUptime: lastUsedUptime, now: ProcessInfo.processInfo.systemUptime) else {
            return
        }
        unload()
    }

    nonisolated static let idleUnloadSeconds: TimeInterval = 60

    nonisolated static func isIdle(lastUsedUptime: TimeInterval?, now: TimeInterval) -> Bool {
        guard let lastUsedUptime else { return true }
        return now - lastUsedUptime >= idleUnloadSeconds
    }

    /// Runs one priming decode so Metal pipelines are hot before the first real
    /// keystroke, then clears the KV so generation starts from a clean cache.
    private func warmup() {
        guard let vocab, let ctx else { return }
        decodeAbortState.beginDecode()
        defer { decodeAbortState.endDecode() }
        let bos = llama_vocab_bos(vocab)
        _ = decode([bos], startPos: 0, logitsLastOnly: true)
        llama_memory_clear(llama_get_memory(ctx), true)
        cachedTokens = []
    }

    /// Replay/test reset; model weights remain resident.
    func clearReplayCache() {
        if let ctx { llama_memory_clear(llama_get_memory(ctx), true) }
        cachedTokens = []
    }

    // MARK: - Tokenize / detokenize

    func tokenize(_ text: String, addBOS: Bool) -> [Int32] {
        guard let vocab else { return [] }
        return text.withCString { cstr -> [Int32] in
            let textLen = Int32(strlen(cstr))
            var capacity = textLen + (addBOS ? 1 : 0) + 8
            var tokens = [Int32](repeating: 0, count: Int(capacity))
            var n = llama_tokenize(vocab, cstr, textLen, &tokens, capacity, addBOS, true)
            if n < 0 {                      // buffer too small: -n is required size
                capacity = -n
                tokens = [Int32](repeating: 0, count: Int(capacity))
                n = llama_tokenize(vocab, cstr, textLen, &tokens, capacity, addBOS, true)
            }
            return Array(tokens.prefix(Int(max(0, n))))
        }
    }

    private func pieceBytes(for token: Int32) -> [UInt8] {
        guard let vocab else { return [] }
        var buf = [CChar](repeating: 0, count: 64)
        var n = llama_token_to_piece(vocab, token, &buf, Int32(buf.count), 0, false)
        if n < 0 {
            buf = [CChar](repeating: 0, count: Int(-n))
            n = llama_token_to_piece(vocab, token, &buf, Int32(buf.count), 0, false)
        }
        guard n > 0 else { return [] }
        return buf.prefix(Int(n)).map { UInt8(bitPattern: $0) }
    }

    // MARK: - Decode

    /// Decodes `tokens` starting at `startPos` in sequence 0. When
    /// `logitsLastOnly` is true only the final token requests logits (prefill).
    @discardableResult
    private func decode(
        _ tokens: [Int32], startPos: Int32, logitsLastOnly: Bool, requestLogits: Bool = true
    ) -> Bool {
        guard let ctx, !tokens.isEmpty else { return true }
        lastReplayDiagnostics.decodedTokens += tokens.count
        lastReplayDiagnostics.decodeCalls += 1
        lastLogitsPosition = nil
        lastLogitsToken = nil
        lastDecodeTokenCount = 0
        var batch = llama_batch_init(Int32(tokens.count), 0, 1)
        defer { llama_batch_free(batch) }
        for i in 0..<tokens.count {
            batch.token[i] = tokens[i]
            batch.pos[i] = startPos + Int32(i)
            batch.n_seq_id[i] = 1
            batch.seq_id[i]![0] = 0
            batch.logits[i] = requestLogits && (!logitsLastOnly || i == tokens.count - 1) ? 1 : 0
        }
        batch.n_tokens = Int32(tokens.count)
        let succeeded = llama_decode(ctx, batch) == 0
        if succeeded, requestLogits {
            lastDecodeTokenCount = tokens.count
            lastLogitsPosition = startPos + Int32(tokens.count - 1)
            lastLogitsToken = tokens.last
        }
        return succeeded
    }

    private func decodeCancellable(
        _ tokens: [Int32],
        startPos: Int32,
        logitsLastOnly: Bool
    ) throws {
        // Adaptive experiments protect the existing single-chunk path. Only
        // a multi-chunk prefill gets an early checkpoint and a larger remainder.
        let firstChunk = tokens.count > 256 ? replayPrefillFirstChunkSize : nil
        let chunkSize = replayPrefillFirstChunkSize != nil && firstChunk == nil ? 256 : replayPrefillChunkSize
        var offset = 0
        while offset < tokens.count {
            try Task.checkCancellation()
            let size = offset == 0 ? firstChunk ?? chunkSize : chunkSize
            let end = min(tokens.count, offset + size)
            let requestLogits = !replayFinalPrefillLogitsOnly || !logitsLastOnly || end == tokens.count
            lastReplayDiagnostics.prefillChunks += 1
            if requestLogits { lastReplayDiagnostics.prefillLogitRows += logitsLastOnly ? 1 : end - offset }
            try decodeOrThrow(
                Array(tokens[offset..<end]),
                startPos: startPos + Int32(offset),
                logitsLastOnly: logitsLastOnly, requestLogits: requestLogits)
            // A native call can queue Metal work. Include completion at each
            // intermediate boundary when measuring cooperative interruption.
            if replaySynchronizePrefillChunks, end < tokens.count, let ctx { llama_synchronize(ctx) }
            offset = end
        }
        try Task.checkCancellation()
    }

    private func decodeOrThrow(
        _ tokens: [Int32],
        startPos: Int32,
        logitsLastOnly: Bool,
        requestLogits: Bool = true
    ) throws {
        guard decode(tokens, startPos: startPos, logitsLastOnly: logitsLastOnly, requestLogits: requestLogits) else {
            if decodeAbortState.isAbortRequested || Task.isCancelled {
                throw CancellationError()
            }
            throw LlamaRuntimeError.decodeFailed
        }
    }

    // MARK: - Generate

    /// - Parameters:
    ///   - requiredPrefixUTF8: token-healing constraint. When non-empty,
    ///     generation must first re-produce exactly these bytes (the whitespace +
    ///     word fragment cut from the prompt tail by `CotypingTokenHealing`) via
    ///     naturally tokenized pieces, then continue freely. Only the text AFTER
    ///     the constraint (including the overshoot of a boundary-merging token
    ///     like " follow" against " follo") is emitted and returned — it is the
    ///     ghost text that extends the word the user is typing.
    ///   - preferWordExtendingOvershoot: when the fragment is NOT a valid
    ///     standalone word, a candidate that merely lands exactly on the caret
    ///     leaves the model in the same awkward mid-word state healing exists to
    ///     avoid (free decode after "…tomorro" can emit "ow."). Prefer a
    ///     boundary-crossing candidate that keeps spelling the word — Cotypist's
    ///     transition-expansion behavior.
    ///   - minimumFirstWordProbability: the confidence gate
    ///     (`CotypingFirstWordConfidence`); 0 turns it off. When the first
    ///     word falls below it, generation stops, `onLowConfidence` is called
    ///     and nothing is returned.
    func generate(
        promptTokens: [Int32],
        maxTokens: Int,
        samplerSpecs: [LlamaSamplerSpec],
        stopAtArgmaxEOG: Bool = true,
        requiredPrefixUTF8: [UInt8] = [],
        preferWordExtendingOvershoot: Bool = false,
        prefixSearchWidth: Int = 1,
        minimumFirstWordProbability: Float = 0,
        hybridFallbackMinimum: Float = CotypingConfidenceDecision.hybridMinimum,
        onLowConfidence: @Sendable () -> Void = {},
        onHybridFallback: @Sendable () -> Void = {},
        onToken: @Sendable (String) -> Bool
    ) throws -> String {
        guard let ctx, let vocab, !promptTokens.isEmpty else { return "" }
        lastReplayDiagnostics = .init()
        lastHealingTrace = healingTraceEnabled
            ? CotypingHealingTrace(promptTokens: promptTokens, requiredPrefix: requiredPrefixUTF8) : nil
        lastUsedUptime = ProcessInfo.processInfo.systemUptime
        let promptTokens = Self.boundedPromptTokens(
            promptTokens, contextSize: Int(llama_n_ctx(ctx)),
            outputReserve: maxTokens + requiredPrefixUTF8.count)
        guard let sampler = makeSampler(samplerSpecs) else { return "" }
        decodeAbortState.beginDecode()
        defer { decodeAbortState.endDecode() }
        defer { llama_sampler_free(sampler) }

        let mem = llama_get_memory(ctx)
        let prefillStart = ContinuousClock.now

        // KV-reuse probe: how many leading tokens this prompt shares with the cache.
        // Clamp to count-1 so we ALWAYS decode >=1 token and get fresh logits for the
        // next-token sample — required when the new prompt equals/prefixes the cached
        // one (e.g. an identical re-generation), else we'd sample from stale logits.
        let shared = IncrementalPrefill.commonPrefixLength(cachedTokens, promptTokens)
        let reuse = min(shared, promptTokens.count - 1)

        do {
            try Task.checkCancellation()
            if supportsPartialReuse, reuse > 0,
               llama_memory_seq_rm(mem, 0, Int32(reuse), -1) {
                // Attention model: the shared prefix KV is kept and only the diverged
                // suffix is re-decoded. seq_rm dropped [reuse, end) — the diverged tail
                // plus any stale tokens the previous generation appended past the prompt.
                //
                // Cotyping prompts are NOT guaranteed to stay inside the production
                // Gemma4 model's 512-token sliding window: worst case is ~850–1100
                // tokens (a 150-word prefix + the ~900-char preface + up to 2500 prefix
                // chars). The load-bearing guard is the `llama_memory_seq_rm` return
                // value below: it returns false when the partial removal can't be
                // honored (e.g. the kept prefix [0, reuse) aged out of the SWA window on
                // a long prompt), and we then fall through to the full re-prefill in the
                // `else` branch. DO NOT remove that fallback — partial reuse is only
                // safe when seq_rm confirms the kept prefix is still resident.
                try decodeCancellable(
                    Array(promptTokens[reuse...]),
                    startPos: Int32(reuse),
                    logitsLastOnly: true)
            } else {
                // Recurrent/hybrid model (SSM/Mamba) cannot partially rewind its rolling
                // state, or a partial seq_rm above was not honored. Reset and prefill the
                // whole prompt from position 0. `reuse` above is still the meaningful
                // KV-reuse *signal* callers read via lastPrefillTokenCount.
                llama_memory_seq_rm(mem, 0, 0, -1)
                try decodeCancellable(promptTokens, startPos: 0, logitsLastOnly: true)
            }
            lastPrefillTokenCount = promptTokens.count - reuse
            cachedTokens = promptTokens
        } catch {
            llama_memory_seq_rm(mem, 0, 0, -1)
            cachedTokens = []
            lastPrefillTokenCount = 0
            throw error
        }

        lastReplayDiagnostics.prefillMs = Self.elapsedMilliseconds(since: prefillStart)
        let searchStart = ContinuousClock.now
        var plannedHealing = [Int32]().makeIterator()
        if prefixSearchWidth > 1, !requiredPrefixUTF8.isEmpty, supportsPartialReuse {
            plannedHealing = try searchPrefixPath(prompt: promptTokens, requiredPrefix: requiredPrefixUTF8,
                preferOvershoot: preferWordExtendingOvershoot, width: min(searchExperiment.width, prefixSearchWidth)).makeIterator()
        }
        lastReplayDiagnostics.prefixSearchMs = Self.elapsedMilliseconds(since: searchStart)
        let generationStart = ContinuousClock.now
        defer { lastReplayDiagnostics.afterSearchMs = Self.elapsedMilliseconds(since: generationStart) }
        var output = ""
        var textDecoder = CotypingUTF8TokenDecoder()
        var pos = Int32(promptTokens.count)
        var confidence = CotypingConfidenceDecision(
            minimum: minimumFirstWordProbability, boundaryMode: confidenceBoundaryMode,
            selectiveOneWordHybrid: selectiveOneWordHybrid, fallbackMinimum: hybridFallbackMinimum,
            traceOnly: confidenceTraceEnabled && minimumFirstWordProbability > 0)
        var confidenceEvaluations = 0
        defer {
            lastReplayDiagnostics.confidenceTrace = confidenceTraceEnabled
            lastReplayDiagnostics.confidenceGateEligible = minimumFirstWordProbability > 0
            if minimumFirstWordProbability > 0, confidenceEvaluations > 0 {
                lastReplayDiagnostics.firstWordProbability = confidence.primary.probability
                lastReplayDiagnostics.firstWordGateSettled = confidence.primary.isSettled
                if selectiveOneWordHybrid {
                    lastReplayDiagnostics.hybridFallbackProbability = confidence.fallback?.probability
                    lastReplayDiagnostics.hybridFallbackSettled = confidence.fallback?.isSettled
                    lastReplayDiagnostics.hybridPrimaryPassed = confidence.primaryPassed
                    lastReplayDiagnostics.hybridUsedFallback = confidence.usesFallback
                }
            }
            if confidence.usesFallback { onHybridFallback() }
        }
        func confident(_ token: Int32, _ piece: String, isEOG: Bool = false) -> Bool {
            guard confidence.needsEvaluation else { return true }
            confidenceEvaluations += 1
            let probability = tokenProbability(token, ctx: ctx, vocab: vocab)
            let boundary = confidence.needsBoundaryMass(for: piece)
                ? Self.boundaryMass(numerators: probabilityScratch, mask: boundaryTokenMask) : nil
            return confidence.accept(piece: piece, probability: probability, boundaryProbability: boundary, isEOG: isEOG)
        }

        // Constrained phase: force-decode the healed word fragment. Each step
        // consumes >=1 byte, so the loop terminates in <=count steps.
        var remaining = requiredPrefixUTF8[...]
        var constraintStopped = false
        while !remaining.isEmpty {
            try Task.checkCancellation()
            guard let tok = plannedHealing.next() ?? constrainedToken(
                matching: remaining,
                vocab: vocab,
                preferWordExtendingOvershoot: preferWordExtendingOvershoot) else {
                // No vocab token can extend the constraint (pathological bytes).
                // Surface nothing rather than a suggestion that skips the fragment.
                return ""
            }
            llama_sampler_accept(sampler, tok)
            lastHealingTrace?.steps.append(.init(token: tok, bytes: pieceBytes(for: tok), remaining: remaining.count))
            switch CotypingRequiredPrefixMatcher.match(
                pieceBytes: pieceBytes(for: tok), remaining: remaining) {
            case .consumes(let count):
                remaining = remaining.dropFirst(count)
            case .overshoots(let extraBytes):
                remaining = remaining.dropFirst(remaining.count)
                guard let text = textDecoder.append(extraBytes) else { return "" }
                guard confident(tok, text) else { onLowConfidence(); return "" }
                output += text
                if !text.isEmpty, !onToken(text) { constraintStopped = true }
            case .mismatch:
                return ""   // constrainedToken guarantees a match; defensive.
            }
            try decodeOrThrow([tok], startPos: pos, logitsLastOnly: true)
            pos += 1
        }
        if constraintStopped { return output }

        for _ in 0..<maxTokens {
            try Task.checkCancellation()
            if stopAtArgmaxEOG, argmaxTokenIsEOG(ctx: ctx, vocab: vocab) {
                if confidence.needsEOGEvaluation,
                   let token = Self.argmaxToken(in: llama_get_logits_ith(ctx, -1), vocabularySize: llama_vocab_n_tokens(vocab)),
                   !confident(token, " ", isEOG: true) { onLowConfidence(); return "" }
                break
            }
            let tok = llama_sampler_sample(sampler, ctx, -1)
            if llama_vocab_is_eog(vocab, tok) {
                if confidence.needsEOGEvaluation, !confident(tok, " ", isEOG: true) { onLowConfidence(); return "" }
                break
            }
            llama_sampler_accept(sampler, tok)
            lastHealingTrace?.freeTokens.append(tok)
            guard let text = textDecoder.append(pieceBytes(for: tok)) else { return "" }
            guard confident(tok, text) else { onLowConfidence(); return "" }
            output += text
            if !text.isEmpty, !onToken(text) { break }
            // A mid-generation decode failure discards the partial output and
            // propagates so the selector falls back to HTTP, rather than
            // surfacing a truncated ghost as if it were a complete suggestion.
            try decodeOrThrow([tok], startPos: pos, logitsLastOnly: true)
            pos += 1
        }
        return output
    }

    /// The model's probability of `token` given the current logits (softmax at
    /// temperature 1, whatever the sampler's settings). Unknown is 0, which
    /// keeps the gate closed rather than showing an unweighed suggestion.
    private func tokenProbability(_ token: Int32, ctx: OpaquePointer, vocab: OpaquePointer) -> Float {
        let vocabularySize = Int(llama_vocab_n_tokens(vocab))
        if probabilityScratch.count != vocabularySize {
            probabilityScratch = [Float](repeating: 0, count: vocabularySize)
        }
        return probabilityScratch.withUnsafeMutableBufferPointer { scratch in
            Self.probability(of: token, in: llama_get_logits_ith(ctx, -1), scratch: scratch)
        } ?? 0
    }

    /// `probability(of:)` leaves exp(logit - max) in scratch. Reuse it instead
    /// of another softmax or decode. The mask is tokenizer-only, built at load.
    nonisolated static func boundaryMass(numerators: [Float], mask: [Float]) -> Float {
        guard !numerators.isEmpty, numerators.count == mask.count else { return 0 }
        var total: Float = 0
        var boundary: Float = 0
        vDSP_sve(numerators, 1, &total, vDSP_Length(numerators.count))
        vDSP_dotpr(numerators, 1, mask, 1, &boundary, vDSP_Length(numerators.count))
        guard total.isFinite, total > 0, boundary.isFinite else { return 0 }
        return min(1, max(0, boundary / total))
    }

    /// Softmax probability of `token`, vectorized over the whole vocabulary.
    /// `scratch` holds one float per vocabulary entry and is overwritten.
    nonisolated static func probability(
        of token: Int32, in logits: UnsafePointer<Float>?, scratch: UnsafeMutableBufferPointer<Float>
    ) -> Float? {
        guard let logits, let buffer = scratch.baseAddress, !scratch.isEmpty,
              token >= 0, Int(token) < scratch.count else { return nil }
        let count = vDSP_Length(scratch.count)
        var maximum: Float = 0
        vDSP_maxv(logits, 1, &maximum, count)
        guard maximum.isFinite else { return nil }
        var negativeMaximum = -maximum
        vDSP_vsadd(logits, 1, &negativeMaximum, buffer, 1, count)
        var length = Int32(scratch.count)
        vvexpf(buffer, buffer, &length)
        var sum: Float = 0
        vDSP_sve(buffer, 1, &sum, count)
        guard sum > 0, sum.isFinite else { return nil }
        return buffer[Int(token)] / sum
    }

    private func argmaxTokenIsEOG(ctx: OpaquePointer, vocab: OpaquePointer) -> Bool {
        guard let token = Self.argmaxToken(
            in: llama_get_logits_ith(ctx, -1),
            vocabularySize: llama_vocab_n_tokens(vocab))
        else {
            return false
        }
        return llama_vocab_is_eog(vocab, token)
    }

    /// Runs once per generated token over the whole vocabulary (262k entries
    /// for Gemma), so it is vectorized. The vector maximum is wrong when a
    /// NaN is present, which the sum reveals; the scalar scan below then
    /// decides, as it does when every logit is -infinity.
    nonisolated static func argmaxToken(
        in logits: UnsafePointer<Float>?,
        vocabularySize: Int32
    ) -> Int32? {
        guard let logits, vocabularySize > 0 else { return nil }
        let count = vDSP_Length(vocabularySize)
        var sum: Float = 0
        vDSP_sve(logits, 1, &sum, count)
        var maximum: Float = 0
        var maximumIndex: vDSP_Length = 0
        vDSP_maxvi(logits, 1, &maximum, &maximumIndex, count)
        if !sum.isNaN, maximum > -Float.infinity, maximumIndex < count {
            return Int32(maximumIndex)
        }
        var bestToken: Int32?
        var bestLogit = -Float.infinity
        for index in 0..<Int(vocabularySize) {
            let value = logits[index]
            guard !value.isNaN else { continue }
            if value > bestLogit {
                bestLogit = value
                bestToken = Int32(index)
            }
        }
        return bestToken
    }

    /// Bound the physical prompt by tokens, not English character estimates.
    /// Dense Unicode text can exceed the context even inside the character cap.
    /// Keep the caret end and reserve space for healing plus visible generation.
    nonisolated static func boundedPromptTokens(
        _ tokens: [Int32], contextSize: Int, outputReserve: Int
    ) -> [Int32] {
        let limit = max(1, contextSize - max(0, outputReserve) - 1)
        return tokens.count > limit ? Array(tokens.suffix(limit)) : tokens
    }

    /// How many global candidates to try before consulting the prefix index.
    /// Natural text usually finds a compatible piece in this cheap first pass.
    private static let constrainedCandidateScanLimit = 64

    /// Highest-logit vocab token whose piece extends the remaining required
    /// prefix (token healing). Ranks a bounded set in one vocabulary pass,
    /// without copying or changing native logits. Rare fragments use a cached
    /// byte-prefix index to find the best compatible token in the full vocabulary.
    ///
    /// With `preferWordExtendingOvershoot`, a candidate that consumes the
    /// remaining bytes EXACTLY is parked while the scan continues for one whose
    /// piece crosses the caret with a word character ("… tomorrow" beating
    /// "… tomorro"); the parked candidate is used when no such token exists.
    private func constrainedToken(
        matching remaining: ArraySlice<UInt8>,
        vocab: OpaquePointer,
        preferWordExtendingOvershoot: Bool = false
    ) -> Int32? {
        guard let ctx else { return nil }
        return constrainedToken(matching: remaining, vocab: vocab, logits: llama_get_logits_ith(ctx, -1),
                                preferWordExtendingOvershoot: preferWordExtendingOvershoot)
    }

    private func constrainedToken(
        matching remaining: ArraySlice<UInt8>, vocab: OpaquePointer, logits: UnsafePointer<Float>?,
        preferWordExtendingOvershoot: Bool
    ) -> Int32? {
        let vocabularySize = llama_vocab_n_tokens(vocab)
        var exactBoundaryFallback: Int32?
        if let logits, vocabularySize > 0 {
            let candidates = CotypingTokenCandidates.topTokens(
                in: logits,
                vocabularySize: vocabularySize,
                limit: Self.constrainedCandidateScanLimit)
            for candidate in candidates {
                if !llama_vocab_is_eog(vocab, candidate) {
                    switch CotypingRequiredPrefixMatcher.match(
                        pieceBytes: pieceBytes(for: candidate), remaining: remaining) {
                    case .consumes(let count):
                        if preferWordExtendingOvershoot, count == remaining.count {
                            // Lands exactly on the caret: park it, keep looking
                            // for a token that keeps spelling the word.
                            if exactBoundaryFallback == nil { exactBoundaryFallback = candidate }
                        } else {
                            return candidate
                        }
                    case .overshoots(let extraBytes):
                        if !preferWordExtendingOvershoot
                            || CotypingRequiredPrefixMatcher.extendsWord(extraBytes: extraBytes) {
                            return candidate
                        }
                        if exactBoundaryFallback == nil { exactBoundaryFallback = candidate }
                    case .mismatch:
                        break
                    }
                }
            }
        }
        if let exactBoundaryFallback { return exactBoundaryFallback }
        if let logits {
            if tokenPrefixIndex == nil {
                tokenPrefixIndex = CotypingTokenPrefixIndex(vocabularySize: vocabularySize) { token in
                    llama_vocab_is_eog(vocab, token) ? [] : pieceBytes(for: token)
                }
            }
            if let compatible = tokenPrefixIndex?.bestToken(
                in: logits, matching: remaining,
                preferWordExtendingOvershoot: preferWordExtendingOvershoot) {
                return compatible
            }
        }
        let text = String(decoding: remaining, as: UTF8.self)
        return tokenize(text, addBOS: false).first
    }

    /// Search only the hidden prefix path. No free token is sampled or scored
    /// here, and the sampler's RNG/history remains untouched until replay.
    private func searchPrefixPath(
        prompt: [Int32], requiredPrefix: [UInt8], preferOvershoot: Bool, width: Int
    ) throws -> [Int32] {
        guard let ctx, let vocab else { return [] }
        let vocabularySize = llama_vocab_n_tokens(vocab)
        // A highest-ranked compatible token that already covers the prefix
        // cannot be beaten by a lower-ranked token followed by more factors
        // <=1. Keep this common case on the original single-decode path.
        if searchExperiment != .exactOnly,
           let first = constrainedToken(matching: requiredPrefix[...], vocab: vocab,
                                        preferWordExtendingOvershoot: preferOvershoot) {
            let complete: Bool
            switch CotypingRequiredPrefixMatcher.match(pieceBytes: pieceBytes(for: first), remaining: requiredPrefix[...]) {
            case .consumes(let count): complete = count == requiredPrefix.count
            case .overshoots: complete = true
            case .mismatch: complete = false
            }
            if complete {
                if healingTraceEnabled, let logits = llama_get_logits_ith(ctx, -1),
                   let normalizer = searchLogNormalizer(logits, vocabularySize: Int(vocabularySize)) {
                    let score = min(0, Double(logits[Int(first)]) - normalizer)
                    lastHealingTrace?.search = .init(expansions: 0, baselineLogProbability: score,
                        selectedLogProbability: score, changedPath: false, certified: true, budgetFallback: false)
                }
                return [first]
            }
        }
        if tokenPrefixIndex == nil {
            tokenPrefixIndex = CotypingTokenPrefixIndex(vocabularySize: vocabularySize) { token in
                llama_vocab_is_eog(vocab, token) ? [] : pieceBytes(for: token)
            }
        }
        let memory = llama_get_memory(ctx)
        var physical = prompt
        func restore(_ path: [Int32]) throws {
            let wanted = prompt + path
            if searchExperiment.reusesIdenticalState, physical == wanted,
               lastDecodeTokenCount == 1, lastLogitsPosition == Int32(wanted.count - 1),
               lastLogitsToken == wanted.last {
                lastReplayDiagnostics.searchRestoreSkips += 1
                return
            }
            let restoreStart = ContinuousClock.now
            defer { lastReplayDiagnostics.searchRestoreMs += Self.elapsedMilliseconds(since: restoreStart) }
            lastLogitsPosition = nil
            lastLogitsToken = nil
            lastReplayDiagnostics.searchRestores += 1
            let shared = min(IncrementalPrefill.commonPrefixLength(physical, wanted), wanted.count - 1)
            if shared > 0, llama_memory_seq_rm(memory, 0, Int32(shared), -1) {
                try decodeOrThrow(Array(wanted[shared...]), startPos: Int32(shared), logitsLastOnly: true)
            } else {
                lastReplayDiagnostics.searchPrefillFallbacks += 1
                llama_memory_seq_rm(memory, 0, 0, -1)
                try decodeCancellable(wanted, startPos: 0, logitsLastOnly: true)
            }
            physical = wanted
        }
        struct RankedToken {
            let token: Int32
            let logProbability: Double
        }
        func rankedTokens(_ logits: UnsafePointer<Float>, remaining: [UInt8], normalizer: Double) -> [RankedToken] {
            let tokens = tokenPrefixIndex?.bestTokens(in: logits, matching: remaining[...],
                preferWordExtendingOvershoot: preferOvershoot, limit: width + 1,
                exactOnly: searchExperiment == .exactOnly) ?? []
            return tokens.map { RankedToken(token: $0, logProbability: min(0, Double(logits[Int($0)]) - normalizer)) }
        }
        // Per-request scalar rankings only: no retained logits, KV snapshots, or text history.
        var memo: [[Int32]: [RankedToken]] = [:]
        var active = [CotypingHealingPath(remaining: requiredPrefix)]
        var best: CotypingHealingPath?
        do {
            // Seed with the exact previous decoder path. Candidate pruning
            // must never remove the existing completion from consideration.
            let baselineStart = ContinuousClock.now
            var alternativeUpperBound = -Double.infinity
            var baseline = CotypingHealingPath(remaining: requiredPrefix)
            for _ in 0..<requiredPrefix.count {
                try Task.checkCancellation()
                try restore(baseline.tokens)
                guard let logits = llama_get_logits_ith(ctx, -1),
                      let normalizer = searchLogNormalizer(logits, vocabularySize: Int(vocabularySize)) else { break }
                let ranked = searchExperiment.memoizesRankings
                    ? rankedTokens(logits, remaining: baseline.remaining, normalizer: normalizer) : []
                let chosen = searchExperiment == .exactOnly ? ranked.first?.token
                    : constrainedToken(matching: baseline.remaining[...], vocab: vocab, logits: logits,
                                       preferWordExtendingOvershoot: preferOvershoot)
                guard let token = chosen,
                      let next = baseline.appending(token: token, bytes: pieceBytes(for: token),
                          logProbability: min(0, Double(logits[Int(token)]) - normalizer)) else { break }
                if searchExperiment.memoizesRankings { memo[baseline.tokens] = ranked }
                for alternative in ranked.prefix(width) where alternative.token != token {
                    alternativeUpperBound = max(alternativeUpperBound, baseline.logProbability + alternative.logProbability)
                }
                baseline = next
                if baseline.remaining.isEmpty { best = baseline; break }
            }
            lastReplayDiagnostics.baselinePathMs = Self.elapsedMilliseconds(since: baselineStart)
            let explorationStart = ContinuousClock.now
            let proven = searchExperiment == .certified && baseline.remaining.isEmpty
                && baseline.logProbability > alternativeUpperBound + 0.0001
            lastReplayDiagnostics.certifiedSkips = proven ? 1 : 0
            var expansions = 0
            var finished = proven
            var prunedUpperBound = -Double.infinity
            for _ in 0..<(proven ? 0 : searchExperiment.expansionLimit) {
                try Task.checkCancellation()
                guard !active.isEmpty else { finished = true; break }
                active.sort(by: CotypingHealingPath.outranks)
                let parent = active.removeFirst()
                // Additional token log probabilities are <=0, so an unfinished
                // path cannot beat a completed path above this upper bound.
                if let best, best.logProbability > parent.logProbability { finished = true; break }
                let ranked: [RankedToken]
                if let saved = memo[parent.tokens] {
                    ranked = saved
                    lastReplayDiagnostics.searchMemoHits += 1
                } else {
                    try restore(parent.tokens)
                    guard let logits = llama_get_logits_ith(ctx, -1),
                          let normalizer = searchLogNormalizer(logits, vocabularySize: Int(vocabularySize)) else {
                        throw LlamaRuntimeError.decodeFailed
                    }
                    ranked = rankedTokens(logits, remaining: parent.remaining, normalizer: normalizer)
                }
                if ranked.count > width, let pruned = ranked.last {
                    prunedUpperBound = max(prunedUpperBound, parent.logProbability + pruned.logProbability)
                }
                expansions += 1
                for candidate in ranked.prefix(width) {
                    let token = candidate.token
                    guard let child = parent.appending(token: token, bytes: pieceBytes(for: token),
                        logProbability: candidate.logProbability) else { continue }
                    if child.remaining.isEmpty {
                        if best.map({ CotypingHealingPath.outranks(child, $0) }) ?? true { best = child }
                    } else { active.append(child) }
                }
                active.sort(by: CotypingHealingPath.outranks)
                if active.count > width { prunedUpperBound = max(prunedUpperBound, active[width].logProbability) }
                active = Array(active.prefix(width))
            }
            lastReplayDiagnostics.searchExpansions = expansions
            lastReplayDiagnostics.explorationMs = Self.elapsedMilliseconds(since: explorationStart)
            try restore([])
            guard baseline.remaining.isEmpty else { return [] }
            let selected: CotypingHealingPath
            if finished, let best, best.logProbability > baseline.logProbability + 0.0001 {
                selected = best
            } else { selected = baseline }
            lastHealingTrace?.search = .init(expansions: expansions,
                baselineLogProbability: baseline.logProbability, selectedLogProbability: selected.logProbability,
                changedPath: selected.tokens != baseline.tokens,
                certified: finished && prunedUpperBound <= selected.logProbability,
                budgetFallback: !finished)
            return selected.tokens
        } catch {
            llama_memory_seq_rm(memory, 0, 0, -1)
            cachedTokens = []
            throw error
        }
    }

    private static func elapsedMilliseconds(since start: ContinuousClock.Instant) -> Double {
        let elapsed = start.duration(to: .now).components
        return Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
    }

    /// Test oracle: rescore the selected path after a cold prefill.
    func coldScore(promptTokens: [Int32], continuationTokens: [Int32]) throws -> Double {
        guard let ctx, let vocab, !promptTokens.isEmpty else { throw LlamaRuntimeError.decodeFailed }
        let memory = llama_get_memory(ctx)
        llama_memory_clear(memory, true)
        cachedTokens = []
        decodeAbortState.beginDecode()
        defer {
            llama_memory_clear(memory, true)
            cachedTokens = []
            decodeAbortState.endDecode()
        }
        try decodeCancellable(promptTokens, startPos: 0, logitsLastOnly: true)
        var score = 0.0
        for (index, token) in continuationTokens.enumerated() {
            try Task.checkCancellation()
            guard let logits = llama_get_logits_ith(ctx, -1),
                  let normalizer = searchLogNormalizer(logits, vocabularySize: Int(llama_vocab_n_tokens(vocab))) else {
                throw LlamaRuntimeError.decodeFailed
            }
            score += Double(logits[Int(token)]) - normalizer
            if index + 1 < continuationTokens.count {
                try decodeOrThrow([token], startPos: Int32(promptTokens.count + index), logitsLastOnly: true)
            }
        }
        return score
    }

    private func searchLogNormalizer(_ logits: UnsafePointer<Float>, vocabularySize: Int) -> Double? {
        if probabilityScratch.count != vocabularySize {
            probabilityScratch = [Float](repeating: 0, count: vocabularySize)
        }
        return probabilityScratch.withUnsafeMutableBufferPointer { scratch in
            guard let buffer = scratch.baseAddress else { return nil }
            var maximum: Float = 0
            vDSP_maxv(logits, 1, &maximum, vDSP_Length(vocabularySize))
            guard maximum.isFinite else { return nil }
            var offset = -maximum
            vDSP_vsadd(logits, 1, &offset, buffer, 1, vDSP_Length(vocabularySize))
            var count = Int32(vocabularySize)
            vvexpf(buffer, buffer, &count)
            var sum: Float = 0
            vDSP_sve(buffer, 1, &sum, vDSP_Length(vocabularySize))
            guard sum.isFinite, sum > 0 else { return nil }
            return Double(maximum) + log(Double(sum))
        }
    }

    private func makeSampler(_ specs: [LlamaSamplerSpec]) -> UnsafeMutablePointer<llama_sampler>? {
        guard let vocab else { return nil }
        let params = llama_sampler_chain_default_params()
        guard let chain = llama_sampler_chain_init(params) else { return nil }
        for spec in specs {
            let s: UnsafeMutablePointer<llama_sampler>?
            switch spec {
            case let .penalties(lastN, rep, freq, present):
                s = llama_sampler_init_penalties(llama_vocab_n_tokens(vocab), lastN, rep, freq, present)
            case let .topK(k):            s = llama_sampler_init_top_k(k)
            case let .topP(p, minKeep):   s = llama_sampler_init_top_p(p, minKeep)
            case let .minP(p, minKeep):   s = llama_sampler_init_min_p(p, minKeep)
            case let .temp(t):            s = llama_sampler_init_temp(t)
            case let .dist(seed):         s = llama_sampler_init_dist(seed)
            }
            if let s { llama_sampler_chain_add(chain, s) }
        }
        return chain
    }
}

/// Headless confidence and decode counters; never persisted by live autocomplete.
struct CotypingReplayDiagnostics: Codable, Sendable {
    /// Tokens submitted to native decode, including a decode that was aborted.
    var decodedTokens = 0
    var decodeCalls = 0
    var prefillChunks = 0
    var prefillLogitRows = 0
    var searchRestoreSkips = 0
    var searchPrefillFallbacks = 0
    var certifiedSkips = 0
    var prefillMs = 0.0
    var prefixSearchMs = 0.0
    var afterSearchMs = 0.0
    var baselinePathMs = 0.0
    var explorationMs = 0.0
    var searchRestoreMs = 0.0
    var searchRestores = 0
    var searchMemoHits = 0
    var searchExpansions = 0
    /// This is the existing raw first-word gate, not a calibrated acceptance probability.
    var firstWordProbability: Float?
    var firstWordGateSettled: Bool?
    var hybridFallbackProbability: Float?
    var hybridFallbackSettled: Bool?
    var hybridPrimaryPassed: Bool?
    var hybridUsedFallback: Bool?
    var confidenceTrace: Bool?
    var confidenceGateEligible: Bool?
}
