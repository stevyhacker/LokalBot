import Foundation
import FluidAudio

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
    nonisolated var speakerAttribution: SpeakerAttributionStrategy { .alignedWords }

    private static let sampleRate = 16_000
    private static let maxSegmentSeconds = 15.0

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
    private var server: LlamaServer?
    private var serverProjectorPath: String?
    private let preparation = AsyncSingleFlight()
    private var activeUses = 0
    private lazy var idle = IdleTimer(seconds: 120) { [weak self] in await self?.unload() }

    private init(variant: Variant) {
        self.variant = variant
    }

    func prepare(progress: ModelPreparationProgressHandler? = nil) async throws {
        try await prepare(upgradingLegacyWeights: false, progress: progress)
    }

    func upgradeWeights(progress: ModelPreparationProgressHandler? = nil) async throws {
        try await prepare(upgradingLegacyWeights: true, progress: progress)
    }

    private func prepare(upgradingLegacyWeights: Bool, progress: ModelPreparationProgressHandler?) async throws {
        report(.init(fractionCompleted: 0, status: "Checking..."), to: progress)
        try await preparation.run { [weak self] in
            guard let self else { return }
            try await self.performPreparation(upgradingLegacyWeights: upgradingLegacyWeights, progress: progress)
        }
        await idle.bump()
        report(.init(fractionCompleted: 1, status: "Ready"), to: progress)
    }

    private func performPreparation(upgradingLegacyWeights: Bool,
                                    progress: ModelPreparationProgressHandler?) async throws {
        try await prepareServer(upgradingLegacyWeights: upgradingLegacyWeights, progress: progress)
    }

    private func prepareServer(upgradingLegacyWeights: Bool,
                               progress: ModelPreparationProgressHandler?) async throws {
        let paths = try await variant.weights.prepareFiles(
            appSupport: AppDirectories.applicationSupport,
            upgradingLegacyWeights: upgradingLegacyWeights,
            progress: progress)
        report(.init(fractionCompleted: nil, status: "Starting local server..."), to: progress)
        if let existing = server, serverProjectorPath != paths.projector.path {
            await existing.stop()
            server = nil
            serverProjectorPath = nil
        }
        let server = self.server ?? variant.weights.makeServer(projector: paths.projector)
        self.server = server
        self.serverProjectorPath = paths.projector.path
        try await server.ensureRunning(modelAt: paths.model)
    }

    func transcribe(audio url: URL, language: String?) async throws -> Transcript {
        try await transcribe(audio: url, language: language, prompt: nil)
    }

    func transcribe(audio url: URL, language: String?, prompt: String?) async throws -> Transcript {
        try await transcribe(audio: url, language: language, prompt: prompt, windows: nil).transcript
    }

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

    typealias SpanDecoder = (_ spans: [SpeechSpan], _ language: String?) async throws -> [Transcript.Segment]

    struct AutoLanguageDecision: Equatable, Sendable {
        var segments: [Transcript.Segment]
        var pinned: String?
        var sampled: Int
        var decodedTwice: Bool
        var needsSpeakerRegions: Bool
    }

    static let languageSampleSize = 12

    static let sampleShare = 0.9

    nonisolated static func languageSample(_ spans: [SpeechSpan], count: Int = languageSampleSize) -> [Int] {
        guard count > 0, spans.count > count else { return Array(spans.indices) }
        func length(_ index: Int) -> TimeInterval { spans[index].end - spans[index].start }
        return (0..<count).map { group in
            let range = (group * spans.count / count)..<((group + 1) * spans.count / count)
            return range.reduce(range.lowerBound) { length($1) > length($0) ? $1 : $0 }
        }
    }

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

    func shutdown() async {
        await server?.stop()
        server = nil
        serverProjectorPath = nil
    }

    private func unload() async {
        guard activeUses == 0, !(await preparation.isRunning) else { return }
        await server?.stop()
        server = nil
        serverProjectorPath = nil
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

    nonisolated static func hubStyleCacheDir(base: URL, modelID: String) -> URL {
        var dir = base.appendingPathComponent("models", isDirectory: true)
        for component in modelID.split(separator: "/") {
            dir = dir.appendingPathComponent(String(component), isDirectory: true)
        }
        return dir
    }

    nonisolated static func samplesForInference(_ samples: [Float]) -> [Float] {
        let minimumSamples = 160
        guard !samples.isEmpty, samples.count < minimumSamples else { return samples }
        return samples + [Float](repeating: 0, count: minimumSamples - samples.count)
    }

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

    static let supportedLanguages: Set<String> = [
        "zh", "en", "yue", "ar", "de", "fr", "es", "pt", "id", "it", "ko", "ru", "th", "vi", "ja",
        "tr", "hi", "ms", "nl", "sv", "da", "fi", "pl", "cs", "fil", "fa", "el", "hu", "mk", "ro",
    ]

    nonisolated static func pinnedLanguage(for texts: [String], minimumShare: Double = 0.8) -> String? {
        guard texts.count >= 2,
              let vote = TranscriptLanguageVote.dominant(
                  in: texts, aliases: TranscriptLanguageVote.serbianCroatianAliases),
              vote.share >= minimumShare,
              supportedLanguages.contains(vote.code) || vote.code == "hr" else { return nil }
        return vote.code
    }

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
