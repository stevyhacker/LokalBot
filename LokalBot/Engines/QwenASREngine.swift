import Foundation
import FluidAudio
import Qwen3ASR

/// Qwen3-ASR through Speech Swift's MLX implementation. This is intentionally
/// a post-meeting engine: LokalBot keeps using its existing file-based pipeline,
/// VAD-splits each track into timestamped spans, then transcribes those spans
/// with Qwen.
actor QwenASREngine: TranscriptionEngine {
    enum Variant: Sendable {
        case accuracy
        case compact

        var displayName: String {
            switch self {
            case .accuracy: "Qwen3-ASR 1.7B"
            case .compact: "Qwen3-ASR 0.6B"
            }
        }

        var modelID: String {
            switch self {
            case .accuracy: "aufklarer/Qwen3-ASR-1.7B-MLX-8bit"
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
    /// never engages (Benchmarks/QwenSpanLength).
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
    private let preparation = AsyncSingleFlight()
    private var activeUses = 0
    private lazy var idle = IdleTimer(seconds: 120) { [weak self] in await self?.unload() }

    private init(variant: Variant) {
        self.variant = variant
    }

    func prepare(progress: ModelPreparationProgressHandler? = nil) async throws {
        if model != nil { return }
        report(.init(fractionCompleted: 0, status: "Checking..."), to: progress)
        try await preparation.run { [weak self] in
            guard let self else { return }
            try await self.performPreparation(progress: progress)
        }
        await idle.bump()
        report(.init(fractionCompleted: 1, status: "Ready"), to: progress)
    }

    private func performPreparation(progress: ModelPreparationProgressHandler?) async throws {
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
            let snapshot = variant == .accuracy ? PinnedModelSnapshot.qwenAccuracy : .qwenCompact
            try await snapshot.prepare(in: cacheDir, progress: progress)

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

    func transcribe(audio url: URL, language: String?) async throws -> Transcript {
        try await transcribe(audio: url, language: language, prompt: nil)
    }

    func transcribe(audio url: URL, language: String?, prompt: String?) async throws -> Transcript {
        try await transcribe(audio: url, language: language, prompt: prompt, windows: nil)
    }

    /// Decodes merged windows, because the forced aligner re-times every word
    /// afterwards: segment granularity no longer depends on the decode window.
    func transcribeForWordAttribution(audio url: URL, language: String?, prompt: String?) async throws -> WordTimedTranscript {
        WordTimedTranscript(try await transcribe(audio: url, language: language, prompt: prompt,
                                                 windows: Self.wordAttributionWindows(for: variant)))
    }

    private func transcribe(audio url: URL, language: String?, prompt: String?,
                            windows: WordAttributionWindows?) async throws -> Transcript {
        let choice: TranscriptionModelChoice = variant == .accuracy ? .qwenASR17B : .qwenASR06B
        try choice.validateLanguage(language)
        activeUses += 1
        defer { finishUse() }
        try await prepare()
        guard let model else { throw EngineError.notLoaded }

        let started = Date()
        var spans = try await SpeechActivity.shared.spans(
            in: url, maxSegmentSeconds: Self.maxSegmentSeconds)
        if let windows {
            spans = Self.merged(spans, maxGap: windows.maxGapSeconds, maxLength: windows.maxSeconds)
        }
        let unblocked = windows?.disablesRepetitionBlocking == true
        func decode(language qwenLanguage: String?) async throws -> [Transcript.Segment] {
            try await SpanTranscription.segments(in: url, spans: spans) { samples, _ in
                try Self.transcribeWindow(
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
            segments = try await decode(language: vote)
            segments = Self.withoutPromptEchoes(segments, prompt: prompt)
        }
        let elapsed = Date().timeIntervalSince(started)
        let duration = spans.last?.end ?? 0
        lokalbotLog(
            "qwen-asr profile model=\(variant.modelID) spans=\(spans.count) merged=\(windows != nil) language=\(Self.qwenLanguage(language) ?? pinned.map { "auto→\($0)" } ?? "auto") elapsed=\(String(format: "%.2fs", elapsed)) rtfx=\(String(format: "%.1fx", elapsed > 0 ? duration / elapsed : 0))")
        return Transcript(segments: segments, engine: "\(variant.modelID) (Qwen3ASR MLX)")
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

    private func unload() async {
        guard activeUses == 0, !(await preparation.isRunning) else { return }
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

    private static func maxTokens(for sampleCount: Int) -> Int {
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
    /// German by text length (Benchmarks/QwenSpanLength).
    ///
    /// A single window is never pinned: its only vote is its own decode, so
    /// decoding it again in that language cannot correct anything. Short
    /// dictations are one window, and pinning them doubled their decode time.
    nonisolated static func pinnedLanguage(for texts: [String]) -> String? {
        guard texts.count >= 2,
              let vote = TranscriptLanguageVote.dominant(in: texts), vote.share >= 0.8,
              supportedLanguages.contains(vote.code) else { return nil }
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

        var errorDescription: String? {
            switch self {
            case .notLoaded: "Qwen3-ASR failed to load."
            }
        }
    }
}
