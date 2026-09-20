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
/// Pinned to llama.cpp `v0.4.1`; symbols verified against the vendored dylib.
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
    private(set) var lastPrefillTokenCount: Int = 0
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

    init(postLoadAdmissionHook: @escaping PostLoadAdmissionHook = {}) {
        self.postLoadAdmissionHook = postLoadAdmissionHook
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
            bytes: ModelResidency.weightBytes(at: URL(fileURLWithPath: modelPath)))
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
        let threads = Int32(max(1, ProcessInfo.processInfo.activeProcessorCount - 2))
        cparams.n_threads = threads
        cparams.n_threads_batch = threads
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
    func handleMemoryPressure() {
        unload()
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

    private func piece(for token: Int32) -> String {
        String(decoding: pieceBytes(for: token), as: UTF8.self)
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
    private func decode(_ tokens: [Int32], startPos: Int32, logitsLastOnly: Bool) -> Bool {
        guard let ctx, !tokens.isEmpty else { return true }
        var batch = llama_batch_init(Int32(tokens.count), 0, 1)
        defer { llama_batch_free(batch) }
        for i in 0..<tokens.count {
            batch.token[i] = tokens[i]
            batch.pos[i] = startPos + Int32(i)
            batch.n_seq_id[i] = 1
            batch.seq_id[i]![0] = 0
            batch.logits[i] = (logitsLastOnly ? (i == tokens.count - 1) : true) ? 1 : 0
        }
        batch.n_tokens = Int32(tokens.count)
        return llama_decode(ctx, batch) == 0
    }

    private func decodeCancellable(
        _ tokens: [Int32],
        startPos: Int32,
        logitsLastOnly: Bool
    ) throws {
        let chunkSize = 256
        var offset = 0
        while offset < tokens.count {
            try Task.checkCancellation()
            let end = min(tokens.count, offset + chunkSize)
            try decodeOrThrow(
                Array(tokens[offset..<end]),
                startPos: startPos + Int32(offset),
                logitsLastOnly: logitsLastOnly)
            offset = end
        }
        try Task.checkCancellation()
    }

    private func decodeOrThrow(
        _ tokens: [Int32],
        startPos: Int32,
        logitsLastOnly: Bool
    ) throws {
        guard decode(tokens, startPos: startPos, logitsLastOnly: logitsLastOnly) else {
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
    func generate(
        promptTokens: [Int32],
        maxTokens: Int,
        samplerSpecs: [LlamaSamplerSpec],
        stopAtArgmaxEOG: Bool = true,
        requiredPrefixUTF8: [UInt8] = [],
        preferWordExtendingOvershoot: Bool = false,
        onToken: @Sendable (String) -> Bool
    ) throws -> String {
        guard let ctx, let vocab, !promptTokens.isEmpty else { return "" }
        guard let sampler = makeSampler(samplerSpecs) else { return "" }
        decodeAbortState.beginDecode()
        defer { decodeAbortState.endDecode() }
        defer { llama_sampler_free(sampler) }

        let mem = llama_get_memory(ctx)

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

        var output = ""
        var pos = Int32(promptTokens.count)

        // Constrained phase: force-decode the healed word fragment. Each step
        // consumes >=1 byte, so the loop terminates in <=count steps.
        var remaining = requiredPrefixUTF8[...]
        var constraintStopped = false
        while !remaining.isEmpty {
            try Task.checkCancellation()
            guard let tok = constrainedToken(
                matching: remaining,
                vocab: vocab,
                preferWordExtendingOvershoot: preferWordExtendingOvershoot) else {
                // No vocab token can extend the constraint (pathological bytes).
                // Surface nothing rather than a suggestion that skips the fragment.
                return ""
            }
            llama_sampler_accept(sampler, tok)
            switch CotypingRequiredPrefixMatcher.match(
                pieceBytes: pieceBytes(for: tok), remaining: remaining) {
            case .consumes(let count):
                remaining = remaining.dropFirst(count)
            case .overshoots(let extraBytes):
                remaining = remaining.dropFirst(remaining.count)
                let text = String(decoding: extraBytes, as: UTF8.self)
                output += text
                if !onToken(text) { constraintStopped = true }
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
                break
            }
            let tok = llama_sampler_sample(sampler, ctx, -1)
            if llama_vocab_is_eog(vocab, tok) { break }
            llama_sampler_accept(sampler, tok)
            let text = piece(for: tok)
            output += text
            if !onToken(text) { break }
            // A mid-generation decode failure discards the partial output and
            // propagates so the selector falls back to HTTP, rather than
            // surfacing a truncated ghost as if it were a complete suggestion.
            try decodeOrThrow([tok], startPos: pos, logitsLastOnly: true)
            pos += 1
        }
        return output
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

    nonisolated static func argmaxToken(
        in logits: UnsafePointer<Float>?,
        vocabularySize: Int32
    ) -> Int32? {
        guard let logits, vocabularySize > 0 else { return nil }
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

    /// How many top-logit candidates to try before falling back to canonical
    /// tokenization. Natural text puts a compatible piece in the top few.
    private static let constrainedCandidateScanLimit = 64

    /// Highest-logit vocab token whose piece extends the remaining required
    /// prefix (token healing). Scans candidates in descending logit order on a
    /// copied logit buffer; when none of the top candidates match, falls back
    /// to the canonical tokenization of the remaining bytes, whose first token
    /// matches by construction (correct, just not logit-optimal).
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
        let vocabularySize = llama_vocab_n_tokens(vocab)
        var exactBoundaryFallback: Int32?
        if let ctx, let logits = llama_get_logits_ith(ctx, -1), vocabularySize > 0 {
            var scores = Array(UnsafeBufferPointer(start: logits, count: Int(vocabularySize)))
            for _ in 0..<Self.constrainedCandidateScanLimit {
                let candidate: Int32? = scores.withUnsafeBufferPointer {
                    Self.argmaxToken(in: $0.baseAddress, vocabularySize: vocabularySize)
                }
                guard let candidate else { break }
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
                scores[Int(candidate)] = -.infinity
            }
        }
        if let exactBoundaryFallback { return exactBoundaryFallback }
        let text = String(decoding: remaining, as: UTF8.self)
        return tokenize(text, addBOS: false).first
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
