import Foundation
import FluidAudio
import Qwen3ASR

/// Qwen3-ASR as a post-meeting engine: LokalBot keeps using its existing
/// file-based pipeline, VAD-splits each track into timestamped spans, then
/// transcribes those spans with Qwen. The 1.7B tier runs on the bundled
/// llama.cpp server (`QwenLlamaASR`); the 0.6B tier still runs on speech-swift's
/// MLX implementation.
actor QwenASREngine: TranscriptionEngine {
    enum Variant: Sendable {
        case accuracy
        case compact

        enum Runtime: Sendable { case llama, mlx }

        var runtime: Runtime {
            switch self {
            case .accuracy: .llama
            case .compact: .mlx
            }
        }

        var displayName: String {
            switch self {
            case .accuracy: "Qwen3-ASR 1.7B"
            case .compact: "Qwen3-ASR 0.6B"
            }
        }

        var modelID: String {
            switch self {
            case .accuracy: "\(QwenLlamaASR.repository):\(QwenLlamaASR.model.name)"
            case .compact: "aufklarer/Qwen3-ASR-0.6B-MLX-4bit"
            }
        }
    }

    static let accuracy = QwenASREngine(variant: .accuracy)
    static let compact = QwenASREngine(variant: .compact)

    nonisolated var displayName: String { variant.displayName }
    nonisolated let supportsStreaming = false
    /// Both tiers transcribe whole tracks before attribution. On the
    /// benchmark, regions cost 0.6B 2.8 points of meeting WER and 9.0 of AMI
    /// WER, which outweighs the aligner being larger than the compact model.
    nonisolated var speakerAttribution: SpeakerAttributionStrategy { .alignedWords }

    private static let sampleRate = 16_000
    private static let maxSegmentSeconds = 15.0

    /// Decode windows for the word-attribution path: VAD spans merged across
    /// short pauses. 1.7B gains from 60 s windows without speech-swift's
    /// repetition blocking. 0.6B decoded long windows 5–10× slower for a small
    /// gain, and worse with blocking on, so it stays at 15 s, where blocking
    /// never engages (Benchmarks/transcribe/QwenSpanLength).
    struct WordAttributionWindows: Equatable, Sendable {
        var maxSeconds: TimeInterval
        var maxGapSeconds: TimeInterval
        var disablesRepetitionBlocking: Bool
    }

    nonisolated static func wordAttributionWindows(for variant: Variant) -> WordAttributionWindows {
        switch variant {
        case .accuracy: .init(maxSeconds: 60, maxGapSeconds: 5, disablesRepetitionBlocking: true)
        case .compact: .init(maxSeconds: 15, maxGapSeconds: 5, disablesRepetitionBlocking: false)
        }
    }

    private let variant: Variant
    private var model: Qwen3ASRModel?
    /// The 1.7B tier's llama-server, started on first use.
    private var server: LlamaServer?
    private let preparation = AsyncSingleFlight()
    private var activeUses = 0
    private lazy var idle = IdleTimer(seconds: 120) { [weak self] in await self?.unload() }

    private init(variant: Variant) {
        self.variant = variant
    }

    func prepare(progress: ModelPreparationProgressHandler? = nil) async throws {
        // The llama-server can be evicted under memory pressure, so the 1.7B
        // tier always checks its files and server, as Granite does; both are
        // cheap once installed and running.
        if variant.runtime == .mlx, model != nil { return }
        report(.init(fractionCompleted: 0, status: "Checking..."), to: progress)
        try await preparation.run { [weak self] in
            guard let self else { return }
            try await self.performPreparation(progress: progress)
        }
        await idle.bump()
        report(.init(fractionCompleted: 1, status: "Ready"), to: progress)
    }

    private func performPreparation(progress: ModelPreparationProgressHandler?) async throws {
        if variant.runtime == .llama {
            try await prepareServer(progress: progress)
            return
        }
        guard model == nil else { return }
        let runtimeID = variant == .accuracy
            ? "transcription:qwen-1.7b" : "transcription:qwen-0.6b"
        let estimatedBytes = ModelRuntimeRegistry.gibibytes(
            variant == .accuracy ? 3.2 : 0.7)
        await ModelRuntimeRegistry.shared.reserve(
            id: runtimeID, role: "Transcribe", label: variant.displayName,
            estimatedBytes: estimatedBytes)
        do {
            try Task.checkCancellation()
            let cacheDir = try Self.cacheDir(for: variant)
            try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
            try await PinnedModelSnapshot.qwenCompact.prepare(in: cacheDir, progress: progress)

            model = try await Qwen3ASRModel.fromPretrained(
                modelId: variant.modelID,
                cacheDir: cacheDir,
                offlineMode: true
            ) { fraction, status in
                Task { @MainActor in
                    progress?(.init(fractionCompleted: fraction, status: status))
                }
            }
            try Task.checkCancellation()
            await ModelRuntimeRegistry.shared.register(
                id: runtimeID, role: "Transcribe", label: variant.displayName,
                estimatedBytes: estimatedBytes)
        } catch {
            model = nil
            await ModelRuntimeRegistry.shared.unregister(id: runtimeID)
            throw error
        }
    }

    private func prepareServer(progress: ModelPreparationProgressHandler?) async throws {
        let paths = try await QwenLlamaASR.prepareFiles(
            appSupport: AppDirectories.applicationSupport, progress: progress)
        report(.init(fractionCompleted: nil, status: "Starting local server..."), to: progress)
        let server = self.server ?? QwenLlamaASR.makeServer(projector: paths.projector)
        self.server = server
        try await server.ensureRunning(modelAt: paths.model)
    }

    func transcribe(audio url: URL, language: String?) async throws -> Transcript {
        try await transcribe(audio: url, language: language, prompt: nil)
    }

    func transcribe(audio url: URL, language: String?, prompt: String?) async throws -> Transcript {
        try await transcribe(audio: url, language: language, prompt: prompt, windows: nil).transcript
    }

    /// Decodes merged windows, because the forced aligner re-times every word
    /// afterwards: segment granularity no longer depends on the decode window.
    /// On auto-detect it reports the language the track settled on, so a
    /// fallback to speaker regions decodes in it too.
    func transcribeForWordAttribution(audio url: URL, language: String?, prompt: String?) async throws -> WordTimedTranscript {
        let result = try await transcribe(audio: url, language: language, prompt: prompt,
                                          windows: Self.wordAttributionWindows(for: variant))
        return WordTimedTranscript(result.transcript, trackLanguage: result.pinned)
    }

    private func transcribe(audio url: URL, language: String?, prompt: String?,
                            windows: WordAttributionWindows?) async throws -> (transcript: Transcript, pinned: String?) {
        let choice: TranscriptionModelChoice = variant == .accuracy ? .qwenASR17B : .qwenASR06B
        try choice.validateLanguage(language)
        activeUses += 1
        defer { finishUse() }
        // The server's model-memory row must not be evicted mid-track.
        let pin: UUID? = variant.runtime == .llama
            ? await ModelResidency.shared.pin(id: LlamaServerRole.qwenASR.residencyID) : nil
        defer { if let pin { Task { @MainActor in ModelResidency.shared.unpin(pin) } } }
        try await prepare()
        let model = self.model
        let server = self.server
        switch variant.runtime {
        case .mlx: guard model != nil else { throw EngineError.notLoaded }
        case .llama: guard server != nil else { throw EngineError.notLoaded }
        }

        let started = Date()
        var spans = try await SpeechActivity.shared.spans(
            in: url, maxSegmentSeconds: Self.maxSegmentSeconds)
        if let windows {
            spans = Self.merged(spans, maxGap: windows.maxGapSeconds, maxLength: windows.maxSeconds)
        }
        let unblocked = windows?.disablesRepetitionBlocking == true
        func decode(language qwenLanguage: String?) async throws -> [Transcript.Segment] {
            try await SpanTranscription.segments(in: url, spans: spans) { samples, _ in
                if let server {
                    return try await Self.transcribeWindow(
                        samples: samples, language: qwenLanguage, prompt: prompt, server: server)
                }
                guard let model else { throw EngineError.notLoaded }
                return try Self.transcribeWindow(
                    samples: samples, language: qwenLanguage, prompt: prompt,
                    disablesRepetitionBlocking: unblocked, model: model)
            }
        }
        var segments = try await decode(language: Self.qwenLanguage(language))
        segments = Self.withoutPromptEchoes(segments, prompt: prompt)
        var pinned: String?
        if Self.qwenLanguage(language) == nil, let vote = Self.pinnedLanguage(for: segments.map(\.text)) {
            // Per-window auto-detection misfires on short or accented speech;
            // a track in one language decodes better pinned to it.
            pinned = vote
            // The forced aligner cannot time words in this language, so the
            // track is attributed by speaker regions, decoded again in `vote`.
            // A second whole-track pass here would be thrown away.
            if windows == nil || QwenWordAligner.supports(vote) {
                segments = try await decode(language: vote)
                segments = Self.withoutPromptEchoes(segments, prompt: prompt)
            }
        }
        let elapsed = Date().timeIntervalSince(started)
        let duration = spans.last?.end ?? 0
        lokalbotLog(
            "qwen-asr profile model=\(variant.modelID) spans=\(spans.count) merged=\(windows != nil) language=\(Self.qwenLanguage(language) ?? pinned.map { "auto→\($0)" } ?? "auto") elapsed=\(String(format: "%.2fs", elapsed)) rtfx=\(String(format: "%.1fx", elapsed > 0 ? duration / elapsed : 0))")
        let runtimeName = variant.runtime == .llama ? "llama.cpp" : "Qwen3ASR MLX"
        return (Transcript(segments: segments, engine: "\(variant.modelID) (\(runtimeName))"), pinned)
    }

    /// One window through llama-server's `/completion` with speech-swift's
    /// prompt. URLSession's async API cancels the request with the task.
    nonisolated static func transcribeWindow(
        samples: [Float], language: String?, prompt: String?, server: LlamaServer
    ) async throws -> String {
        let input = samplesForInference(samples)
        let request = try QwenLlamaASR.makeRequest(
            serverBaseURL: server.baseURL,
            authenticationToken: await server.authenticationToken(),
            samples: input, sampleRate: sampleRate, language: language,
            context: TranscriptionPrompt.normalized(prompt),
            maxTokens: maxTokens(for: samples.count))
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw EngineError.transcriptionFailed("no response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw EngineError.transcriptionFailed(
                "HTTP \(http.statusCode): \(String(decoding: data.prefix(512), as: UTF8.self))")
        }
        return try QwenLlamaASR.transcript(fromCompletion: data)
    }

    /// Use the throwing API for every window so an abandoned transcription
    /// stops at the next encoder/prefill/token checkpoint without saving a tail.
    nonisolated static func transcribeWindow(
        samples: [Float], language: String?, prompt: String?,
        disablesRepetitionBlocking: Bool, model: Qwen3ASRModel
    ) throws -> String {
        try model.transcribeCheckingCancellation(
            audio: samplesForInference(samples), sampleRate: sampleRate,
            options: decodingOptions(sampleCount: samples.count, language: language,
                                     prompt: prompt, disablesRepetitionBlocking: disablesRepetitionBlocking))
    }

    nonisolated static func decodingOptions(
        sampleCount: Int, language: String?, prompt: String?, disablesRepetitionBlocking: Bool
    ) -> Qwen3DecodingOptions {
        var options = Qwen3DecodingOptions(
            maxTokens: maxTokens(for: sampleCount), language: language,
            context: TranscriptionPrompt.normalized(prompt))
        if disablesRepetitionBlocking {
            // Blocking repeated 3-grams substitutes legitimate repeated phrases
            // in the accuracy model's merged word-attribution windows.
            options.longInputThresholdSeconds = .infinity
        }
        return options
    }

    /// Stops the 1.7B tier's llama-server at quit, like Granite's.
    func shutdown() async {
        await server?.stop()
        server = nil
    }

    private func unload() async {
        guard activeUses == 0, !(await preparation.isRunning) else { return }
        if variant.runtime == .llama {
            await server?.stop()
            server = nil
            return
        }
        // The package's unload frees the weights and restores the MLX cache
        // limit it lowered at load; then return the buffer pool itself.
        model?.unload()
        model = nil
        MLXMemoryRelease.releaseCachedBuffers(after: "qwen-asr")
        await ModelRuntimeRegistry.shared.unregister(
            id: variant == .accuracy ? "transcription:qwen-1.7b" : "transcription:qwen-0.6b"
        )
    }

    private func finishUse() {
        activeUses -= 1
        guard activeUses == 0 else { return }
        Task { await idle.bump() }
    }

    private nonisolated func report(_ update: ModelPreparationUpdate,
                                    to handler: ModelPreparationProgressHandler?) {
        guard let handler else { return }
        Task { @MainActor in handler(update) }
    }

    private static func cacheRoot() throws -> URL {
        let root = AppDirectories.applicationSupport
            .appendingPathComponent("qwen3-asr-models", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// The directory `Qwen3ASRModel.fromPretrained` both downloads into and
    /// loads from. The Qwen3ASR package's HuggingFace downloader only writes
    /// into a directory shaped like the Hub layout `…/models/<org>/<model>`;
    /// given a flat path its `makeHubApi` fallback silently downloads to
    /// `~/Library/Caches/<root>/models/<org>/<model>` instead, leaving the path
    /// we load from empty ("No safetensors files found"). Building the Hub-style
    /// path under our own root keeps download and load pointed at one directory.
    private static func cacheDir(for variant: Variant) throws -> URL {
        hubStyleCacheDir(base: try cacheRoot(), modelID: variant.modelID)
    }

    /// Pure path arithmetic (no I/O) — `base/models/<org>/<model>` — so the
    /// layout that must match the package's downloader is unit-testable.
    nonisolated static func hubStyleCacheDir(base: URL, modelID: String) -> URL {
        var dir = base.appendingPathComponent("models", isDirectory: true)
        for component in modelID.split(separator: "/") {
            dir = dir.appendingPathComponent(String(component), isDirectory: true)
        }
        return dir
    }

    /// speech-swift 0.0.26 drops the final STFT frame, so fewer than one
    /// 160-sample hop (10 ms at 16 kHz) produces zero encoder frames and
    /// traps in MLX's stacked([]). Speaker boundaries and VAD/split tails
    /// can be this short. Pad only the model input with silence; retain all
    /// recorded samples and the original span timestamps. Empty windows
    /// stay empty and are skipped by SpanTranscription before inference.
    nonisolated static func samplesForInference(_ samples: [Float]) -> [Float] {
        let minimumSamples = 160
        guard !samples.isEmpty, samples.count < minimumSamples else { return samples }
        return samples + [Float](repeating: 0, count: minimumSamples - samples.count)
    }

    /// Joins consecutive speech spans separated by at most `maxGap` seconds
    /// while the joined window stays within `maxLength`. The window keeps the
    /// pause audio between its spans, as the benchmark's windows did.
    nonisolated static func merged(_ spans: [SpeechSpan], maxGap: TimeInterval,
                                   maxLength: TimeInterval) -> [SpeechSpan] {
        var windows: [SpeechSpan] = []
        for span in spans {
            if let last = windows.last, span.start - last.end <= maxGap, span.end - last.start <= maxLength {
                windows[windows.count - 1] = SpeechSpan(start: last.start, end: span.end,
                                                        timingPrecision: last.timingPrecision)
            } else {
                windows.append(span)
            }
        }
        return windows
    }

    nonisolated static func maxTokens(for sampleCount: Int) -> Int {
        let seconds = Double(sampleCount) / Double(sampleRate)
        return min(768, max(128, Int(seconds * 18)))
    }

    /// Qwen3-ASR's supported languages (model card), as ISO codes.
    static let supportedLanguages: Set<String> = [
        "zh", "en", "yue", "ar", "de", "fr", "es", "pt", "id", "it", "ko", "ru", "th", "vi", "ja",
        "tr", "hi", "ms", "nl", "sv", "da", "fi", "pl", "cs", "fil", "fa", "el", "hu", "mk", "ro",
    ]

    /// With the language on auto, the track's language when one supported
    /// language holds at least 80% of its text. Mixed-language tracks stay on
    /// per-window detection: a 50/50 English–German track votes up to 66%
    /// German by text length (Benchmarks/transcribe/QwenSpanLength).
    ///
    /// A single window is never pinned: its only vote is its own decode, so
    /// decoding it again in that language cannot correct anything. Short
    /// dictations are one window, and pinning them doubled their decode time.
    ///
    /// Serbian, Croatian, Bosnian and Montenegrin vote together and pin to
    /// Croatian, which is not on the model card. Left on auto, these tracks
    /// slip window by window into Macedonian, Russian or Chinese, and lines
    /// come out in Chinese, Japanese or Hindi script. Pinned to `hr`,
    /// Benchmarks/transcribe/DualASR measured 0.1% non-Latin
    /// letters, Croatian 24.8% WER against 26.8% on auto, and the Montenegrin
    /// meeting 38.5% against 38.3%. `sr` read Serbian better (14.5% against
    /// 17.3%) but wrote half of everything in Cyrillic.
    nonisolated static func pinnedLanguage(for texts: [String]) -> String? {
        guard texts.count >= 2,
              let vote = TranscriptLanguageVote.dominant(
                  in: texts, aliases: TranscriptLanguageVote.serbianCroatianAliases),
              vote.share >= 0.8,
              supportedLanguages.contains(vote.code) || vote.code == "hr" else { return nil }
        return vote.code
    }

    /// A near-silent span decodes to the context itself ("Mila Novak, Orion
    /// Launch, Acme."). Dropped here so dictation never types the list and
    /// the language vote hears only speech; the track transcriber repeats
    /// the check for engines that do not.
    nonisolated static func withoutPromptEchoes(_ segments: [Transcript.Segment],
                                                prompt: String?) -> [Transcript.Segment] {
        guard let echo = TranscriptionPromptEcho(prompt: prompt) else { return segments }
        let kept = echo.removing(from: segments)
        if kept.count < segments.count {
            lokalbotLog("qwen-asr dropped \(segments.count - kept.count) span(s) echoing the vocabulary prompt")
        }
        return kept
    }

    private static func qwenLanguage(_ language: String?) -> String? {
        guard let language, language != "auto" else { return nil }
        return language
    }

    enum EngineError: LocalizedError {
        case notLoaded
        case transcriptionFailed(String)

        var errorDescription: String? {
            switch self {
            case .notLoaded: "Qwen3-ASR failed to load."
            case .transcriptionFailed(let detail): "Qwen3-ASR transcription failed: \(detail)"
            }
        }
    }
}
