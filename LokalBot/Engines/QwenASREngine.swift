import Foundation
import FluidAudio

/// Qwen3-ASR as a post-meeting engine: LokalBot keeps using its existing
/// file-based pipeline, VAD-splits each track into timestamped spans, then
/// transcribes those spans with Qwen. Both tiers run on the bundled llama.cpp
/// server (`QwenLlamaASR`), each on its own llama-server.
actor QwenASREngine: TranscriptionEngine {
    enum Variant: Sendable {
        case accuracy
        case compact

        var weights: QwenLlamaASR.Weights {
            switch self {
            case .accuracy: QwenLlamaASR.accuracy
            case .compact: QwenLlamaASR.compact
            }
        }

        var displayName: String {
            switch self {
            case .accuracy: "Qwen3-ASR 1.7B"
            case .compact: "Qwen3-ASR 0.6B"
            }
        }

        var modelID: String { "\(weights.repository):\(weights.model.name)" }
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
    /// short pauses. 1.7B gains from long windows. Each window is one
    /// forced-aligner segment, and the CoreML aligner takes at most 30 s, so
    /// 1.7B merges to 30 s rather than the 60 s it used with the MLX aligner;
    /// on AMI the two were within noise. 0.6B decoded long windows 5–10×
    /// slower for a small gain, so it stays at 15 s
    /// (Benchmarks/transcribe/QwenSpanLength). llama.cpp decodes greedily with
    /// no repetition block; `TranscriptSanitizer` removes runaway loops.
    struct WordAttributionWindows: Equatable, Sendable {
        var maxSeconds: TimeInterval
        var maxGapSeconds: TimeInterval
    }

    nonisolated static func wordAttributionWindows(for variant: Variant) -> WordAttributionWindows {
        switch variant {
        case .accuracy: .init(maxSeconds: QwenWordAligner.maxSegmentSeconds, maxGapSeconds: 5)
        case .compact: .init(maxSeconds: 15, maxGapSeconds: 5)
        }
    }

    private let variant: Variant
    /// The tier's llama-server, started on first use.
    private var server: LlamaServer?
    private let preparation = AsyncSingleFlight()
    private var activeUses = 0
    private lazy var idle = IdleTimer(seconds: 120) { [weak self] in await self?.unload() }

    private init(variant: Variant) {
        self.variant = variant
    }

    func prepare(progress: ModelPreparationProgressHandler? = nil) async throws {
        // The llama-server can be evicted under memory pressure, so this
        // always checks the files and the server, as Granite does; both are
        // cheap once installed and running.
        report(.init(fractionCompleted: 0, status: "Checking..."), to: progress)
        try await preparation.run { [weak self] in
            guard let self else { return }
            try await self.performPreparation(progress: progress)
        }
        await idle.bump()
        report(.init(fractionCompleted: 1, status: "Ready"), to: progress)
    }

    private func performPreparation(progress: ModelPreparationProgressHandler?) async throws {
        try await prepareServer(progress: progress)
    }

    private func prepareServer(progress: ModelPreparationProgressHandler?) async throws {
        let paths = try await variant.weights.prepareFiles(
            appSupport: AppDirectories.applicationSupport, progress: progress)
        report(.init(fractionCompleted: nil, status: "Starting local server..."), to: progress)
        let server = self.server ?? variant.weights.makeServer(projector: paths.projector)
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
    /// fallback to speaker regions decodes in it too. When that language is
    /// one the aligner cannot time, the rest of the track is not decoded:
    /// the speaker regions decode it instead.
    func transcribeForWordAttribution(audio url: URL, language: String?, prompt: String?) async throws -> WordTimedTranscript {
        let result = try await transcribe(audio: url, language: language, prompt: prompt,
                                          windows: Self.wordAttributionWindows(for: variant))
        var timed = WordTimedTranscript(result.transcript, trackLanguage: result.decision.pinned)
        timed.needsSpeakerRegions = result.decision.needsSpeakerRegions
        return timed
    }

    private func transcribe(audio url: URL, language: String?, prompt: String?,
                            windows: WordAttributionWindows?) async throws -> (transcript: Transcript, decision: AutoLanguageDecision) {
        let choice: TranscriptionModelChoice = variant == .accuracy ? .qwenASR17B : .qwenASR06B
        try choice.validateLanguage(language)
        activeUses += 1
        defer { finishUse() }
        // The server's model-memory row must not be evicted mid-track.
        let pin = await ModelResidency.shared.pin(id: variant.weights.role.residencyID)
        defer { Task { @MainActor in ModelResidency.shared.unpin(pin) } }
        try await prepare()
        guard let server = self.server else { throw EngineError.notLoaded }

        let started = Date()
        var spans = try await SpeechActivity.shared.spans(
            in: url, maxSegmentSeconds: Self.maxSegmentSeconds)
        if let windows {
            spans = Self.merged(spans, maxGap: windows.maxGapSeconds, maxLength: windows.maxSeconds)
        }
        let decode: SpanDecoder = { batch, qwenLanguage in
            let segments = try await SpanTranscription.segments(in: url, spans: batch) { samples, _ in
                try await Self.transcribeWindow(
                    samples: samples, language: qwenLanguage, prompt: prompt, server: server)
            }
            return Self.withoutPromptEchoes(segments, prompt: prompt)
        }
        let decision: AutoLanguageDecision
        if let fixed = Self.qwenLanguage(language) {
            decision = AutoLanguageDecision(segments: try await decode(spans, fixed), pinned: nil, sampled: 0,
                                            decodedTwice: false, needsSpeakerRegions: false)
        } else {
            decision = try await Self.decodeOnAuto(spans, wordAttribution: windows != nil, decode: decode)
        }
        let elapsed = Date().timeIntervalSince(started)
        let duration = spans.last?.end ?? 0
        let languageLabel = Self.qwenLanguage(language) ?? decision.pinned.map { "auto→\($0)" } ?? "auto"
        lokalbotLog(
            "qwen-asr profile model=\(variant.modelID) spans=\(spans.count) merged=\(windows != nil) language=\(languageLabel) sampled=\(decision.sampled) twice=\(decision.decodedTwice) regions=\(decision.needsSpeakerRegions) elapsed=\(String(format: "%.2fs", elapsed)) rtfx=\(String(format: "%.1fx", elapsed > 0 ? duration / elapsed : 0))")
        return (Transcript(segments: decision.segments, engine: "\(variant.modelID) (llama.cpp)"), decision)
    }

    /// Decodes `spans` in `language` (nil: auto-detect) and drops prompt echoes.
    typealias SpanDecoder = (_ spans: [SpeechSpan], _ language: String?) async throws -> [Transcript.Segment]

    /// How a track on auto-detect was decoded.
    struct AutoLanguageDecision: Equatable, Sendable {
        var segments: [Transcript.Segment]
        /// The language the track was pinned to, if a vote held.
        var pinned: String?
        /// Spans decoded on auto before the first vote.
        var sampled: Int
        /// Every span was decoded twice: once on auto, then pinned.
        var decodedTwice: Bool
        /// `pinned` is a language the forced aligner cannot time: the caller
        /// attributes by speaker regions, decoded in it, so the track was
        /// not decoded pinned here.
        var needsSpeakerRegions: Bool
    }

    /// Spans decoded on auto for the first language vote. Per-window
    /// auto-detection misfires on short or accented speech, so a track in one
    /// language decodes better pinned to it; voting on a sample instead of the
    /// whole track lets most tracks decode once rather than twice.
    ///
    /// Benchmarks/transcribe/QwenLanguageSample: whole AMI meetings and the
    /// owner's English and Serbian meetings voted 99–100% one language on
    /// any sample of 4 to 16 spans. On code-switched FLEURS tracks the old
    /// path left on auto, random samples (one span per group) pinned 4.3% of
    /// the time with 8 spans and 2.9% with 12; 12 costs about 4% of the old
    /// decode time more than 8 on long tracks.
    static let languageSampleSize = 12

    /// The sample's vote must reach this share to pin the track without
    /// hearing the rest. Below it, the track decodes as it did before
    /// sampling: everything on auto, then the whole-track vote at
    /// `pinnedLanguage`'s 80%. A sample estimates the share coarsely. At
    /// 80%, the sample of a track the whole-track vote left on auto (four
    /// Serbian utterances to one English, 79.8%) pinned it. At 85%, random
    /// 12-span samples still pinned it 39% of the time; at 90%, 23%, and
    /// tracks 73% or less in one language almost never. Tracks in one
    /// language vote 99–100%, so the stricter share costs them nothing.
    static let sampleShare = 0.9

    /// Indices of `spans` to decode first: the spans split into `count`
    /// consecutive groups of (nearly) equal size, and the longest span of
    /// each, so the vote hears the opening, the middle and the end, where a
    /// late change of language would be. Every span when there are no more
    /// than `count`, so short tracks and dictation decode as before.
    nonisolated static func languageSample(_ spans: [SpeechSpan], count: Int = languageSampleSize) -> [Int] {
        guard count > 0, spans.count > count else { return Array(spans.indices) }
        func length(_ index: Int) -> TimeInterval { spans[index].end - spans[index].start }
        return (0..<count).map { group in
            let range = (group * spans.count / count)..<((group + 1) * spans.count / count)
            // The longest span says the most; the earliest one wins ties.
            return range.reduce(range.lowerBound) { length($1) > length($0) ? $1 : $0 }
        }
    }

    /// Decodes a track whose language is on auto-detect.
    ///
    /// A sample of spans (`languageSample`) decodes on auto first. When one
    /// language holds at least `sampleShare` of its text, the whole track
    /// decodes once, pinned to it; the sampled spans decode again with the
    /// rest, so every span is decoded the same way. Otherwise the rest
    /// decodes on auto and the whole track votes as before: a mixed track
    /// stays on per-window detection, and a track the sample misjudged is
    /// still pinned, at the old cost of two passes.
    ///
    /// With `wordAttribution`, a pinned language the forced aligner cannot
    /// time (Croatian, for Serbian, Bosnian and Montenegrin speech) ends the
    /// decode: the caller attributes by speaker regions, decoded in that
    /// language, and a pass here would be thrown away.
    nonisolated static func decodeOnAuto(_ spans: [SpeechSpan], wordAttribution: Bool,
                                         sampleSize: Int = languageSampleSize,
                                         decode: SpanDecoder) async throws -> AutoLanguageDecision {
        guard !spans.isEmpty else {
            return AutoLanguageDecision(segments: [], pinned: nil, sampled: 0,
                                        decodedTwice: false, needsSpeakerRegions: false)
        }
        let sample = languageSample(spans, count: sampleSize)
        let sampled = try await decode(sample.map { spans[$0] }, nil)
        func pinned(_ vote: String, segments: [Transcript.Segment], twice: Bool) async throws -> AutoLanguageDecision {
            if wordAttribution && !QwenWordAligner.supports(vote) {
                return AutoLanguageDecision(segments: segments, pinned: vote, sampled: sample.count,
                                            decodedTwice: false, needsSpeakerRegions: true)
            }
            return AutoLanguageDecision(segments: try await decode(spans, vote), pinned: vote, sampled: sample.count,
                                        decodedTwice: twice, needsSpeakerRegions: false)
        }
        if sample.count < spans.count, let vote = pinnedLanguage(for: sampled.map(\.text), minimumShare: sampleShare) {
            return try await pinned(vote, segments: [], twice: false)
        }
        let chosen = Set(sample)
        let unsampled = spans.indices.filter { !chosen.contains($0) }.map { spans[$0] }
        let rest = unsampled.isEmpty ? [] : try await decode(unsampled, nil)
        let all = (sampled + rest).sorted { $0.start < $1.start }
        guard let vote = pinnedLanguage(for: all.map(\.text)) else {
            return AutoLanguageDecision(segments: all, pinned: nil, sampled: sample.count,
                                        decodedTwice: false, needsSpeakerRegions: false)
        }
        return try await pinned(vote, segments: all, twice: true)
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

    /// Stops the tier's llama-server at quit, like Granite's.
    func shutdown() async {
        await server?.stop()
        server = nil
    }

    private func unload() async {
        guard activeUses == 0, !(await preparation.isRunning) else { return }
        await server?.stop()
        server = nil
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

    /// The Hub-style layout `base/models/<org>/<model>` of speech-swift's
    /// loaders: the forced aligner lives there, and so did the MLX weights both
    /// Qwen tiers replaced. Pure path arithmetic (no I/O), so it is unit-testable.
    nonisolated static func hubStyleCacheDir(base: URL, modelID: String) -> URL {
        var dir = base.appendingPathComponent("models", isDirectory: true)
        for component in modelID.split(separator: "/") {
            dir = dir.appendingPathComponent(String(component), isDirectory: true)
        }
        return dir
    }

    /// Qwen's mel front end drops the final STFT frame, so fewer than one
    /// 160-sample hop (10 ms at 16 kHz) produces zero encoder frames.
    /// Speaker boundaries and VAD/split tails can be this short. Pad only the
    /// model input with silence; retain all recorded samples and the original
    /// span timestamps. Empty windows stay empty and are skipped by
    /// SpanTranscription before inference.
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
    /// language holds at least `minimumShare` (80%) of its text. Mixed-language
    /// tracks stay on per-window detection: a 50/50 English–German track votes
    /// up to 66% German by text length (Benchmarks/transcribe/QwenSpanLength).
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
    nonisolated static func pinnedLanguage(for texts: [String], minimumShare: Double = 0.8) -> String? {
        guard texts.count >= 2,
              let vote = TranscriptLanguageVote.dominant(
                  in: texts, aliases: TranscriptLanguageVote.serbianCroatianAliases),
              vote.share >= minimumShare,
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
