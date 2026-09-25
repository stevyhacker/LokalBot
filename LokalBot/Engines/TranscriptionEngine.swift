import Foundation
import CoreML
import FluidAudio
import WhisperKit

struct ModelPreparationUpdate: Sendable {
    var fractionCompleted: Double?
    var status: String
}

typealias ModelPreparationProgressHandler = @MainActor @Sendable (ModelPreparationUpdate) -> Void

private func reportPreparationUpdate(_ update: ModelPreparationUpdate,
                                     to handler: ModelPreparationProgressHandler?) {
    guard let handler else { return }
    Task { @MainActor in handler(update) }
}

private func downloadProgressHandler(
    _ handler: ModelPreparationProgressHandler?
) -> ProgressHandler? {
    guard handler != nil else { return nil }
    return { progress in
        let status: String
        switch progress.phase {
        case .listing:
            status = "Checking..."
        case .downloading:
            status = "Downloading..."
        case .compiling:
            status = "Compiling..."
        }
        reportPreparationUpdate(
            .init(fractionCompleted: progress.fractionCompleted, status: status),
            to: handler)
    }
}

/// User-facing transcription model list (Settings). CoreML/MLX families
/// (Parakeet, Qwen3-ASR, Whisper, Cohere) plus ONNX-runtime models for languages
/// those cover poorly — SenseVoice (CJK) and GigaAM (Russian) — via the bundled
/// sherpa-onnx engine.
enum TranscriptionModelChoice: String, Codable, CaseIterable, Identifiable {
    case parakeetV3 = "parakeet-v3"
    case parakeetV2 = "parakeet-v2"
    case qwenASR17B = "qwen3-asr-1.7b"
    case qwenASR06B = "qwen3-asr-0.6b"
    case graniteSpeech = "granite-speech"
    case graniteTurbo = "granite-speech-5-turbo"
    case whisperLarge = "whisper-large-v3-turbo"
    case senseVoice = "sense-voice"
    case gigaamRussian = "gigaam-russian"
    case cohere = "cohere-transcribe"
    var id: String { rawValue }
    static let recommended: Self = .qwenASR17B

    /// Superseded choices. They stay decodable (a persisted selection keeps
    /// working) and deletable, but the Models UI hides them from new users —
    /// every language Cohere covers is served better by Granite/Qwen/Whisper,
    /// which add language detection, timestamps, and diarization support.
    var isLegacy: Bool { self == .cohere }

    var displayName: String {
        switch self {
        case .parakeetV3: "Parakeet TDT 0.6B v3 (multilingual)"
        case .parakeetV2: "Parakeet TDT 0.6B v2 (English)"
        case .qwenASR17B: "Qwen3-ASR 1.7B"
        case .qwenASR06B: "Qwen3-ASR 0.6B"
        case .graniteSpeech: "Granite Speech 4.1 2B"
        case .graniteTurbo: "Granite Speech 5 fast (English)"
        case .whisperLarge: "Whisper large-v3 turbo"
        case .cohere: "Cohere Transcribe (multilingual)"
        case .senseVoice: "SenseVoice (Chinese/Japanese/Korean)"
        case .gigaamRussian: "GigaAM (Russian)"
        }
    }

    /// Settings written before the raw values were stabilized persisted the
    /// display strings. Keep decoding them so an update never silently resets
    /// a user's model choice.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        if let choice = Self(rawValue: raw)
            ?? Self.allCases.first(where: { $0.displayName == raw }) {
            self = choice
        } else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Unknown transcription model choice: \(raw)"))
        }
    }

    /// Download size from the blurb ("0.6 GB"), when the blurb leads with one.
    var sizeLabel: String? {
        guard let lead = blurb.components(separatedBy: " · ").first,
              lead.hasSuffix(" GB") || lead.hasSuffix(" MB") else { return nil }
        return lead
    }

    var blurb: String {
        switch self {
        case .parakeetV3: "0.6 GB · 25 European languages, ~190× realtime"
        case .parakeetV2: "0.6 GB · English only, slightly higher recall"
        case .qwenASR17B: "3.2 GB · MLX, 52 languages/dialects, best Qwen accuracy tier"
        case .qwenASR06B: "0.7 GB · MLX, 52 languages/dialects, compact global tier"
        case .graniteSpeech: "2B parameters · Apache-2.0, local speech recognition"
        case .graniteTurbo: "0.95 GB · English only · fast local transcription without punctuation or vocabulary prompts"
        case .whisperLarge: "1.6 GB · 99 languages, word timestamps, wide-language legacy fallback"
        case .cohere: "2B params · legacy — no auto language detection, timestamps, or diarization"
        case .senseVoice: "Chinese · Japanese · Korean · Cantonese · English (ONNX, downloaded on first use)"
        case .gigaamRussian: "Russian — high accuracy (ONNX, downloaded on first use)"
        }
    }

    var engine: TranscriptionEngine {
        switch self {
        case .parakeetV3: ParakeetEngine.v3
        case .parakeetV2: ParakeetEngine.v2
        case .qwenASR17B: QwenASREngine.accuracy
        case .qwenASR06B: QwenASREngine.compact
        case .graniteSpeech: GraniteSpeechEngine.shared
        case .graniteTurbo: GraniteTurboEngine.shared
        case .whisperLarge: WhisperEngine.shared
        case .cohere: CohereEngine.shared
        case .senseVoice: OnnxTranscriptionEngine.senseVoice
        case .gigaamRussian: OnnxTranscriptionEngine.gigaamRussian
        }
    }
}

/// M2 contract (design doc §5). The app talks only to these protocols;
/// engines (Parakeet, WhisperKit, whisper.cpp, VibeVoice) plug in behind.
/// `prepare` downloads/loads the model (idempotent) so prewarm paths and the
/// Models UI can drive any engine through `TranscriptionModelChoice.engine`
/// without per-engine switches.
protocol TranscriptionEngine {
    var displayName: String { get }
    var supportsStreaming: Bool { get }
    func prepare(progress: ModelPreparationProgressHandler?) async throws
    func transcribe(audio: URL, language: String?) async throws -> Transcript
    func transcribe(audio: URL, language: String?, prompt: String?) async throws -> Transcript
}

extension TranscriptionEngine {
    func prepare() async throws { try await prepare(progress: nil) }

    /// Engines without a prompt API keep their existing behavior. Whisper and
    /// Qwen override this overload with their native context mechanisms.
    func transcribe(audio: URL, language: String?, prompt: String?) async throws -> Transcript {
        try await transcribe(audio: audio, language: language)
    }
}

enum TranscriptionPrompt {
    nonisolated static func normalized(_ prompt: String?) -> String? {
        guard let prompt else { return nil }
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

enum TranscriptionEngineError: LocalizedError {
    case notLoaded
    var errorDescription: String? { "Transcription model failed to load." }
}

/// Releases an idle, expensive resource (a loaded transcription model) after a
/// quiet period — mirrors Handy's idle-unload so a long-running app doesn't pin
/// hundreds of MB to >1 GB of CoreML weights between meetings. Call `bump()`
/// after each use; `onIdle` runs only if nothing bumped during the interval.
actor IdleTimer {
    private let seconds: TimeInterval
    private let onIdle: @Sendable () async -> Void
    private var generation = 0

    init(seconds: TimeInterval, onIdle: @escaping @Sendable () async -> Void) {
        self.seconds = seconds
        self.onIdle = onIdle
    }

    func bump() {
        generation += 1
        let scheduled = generation
        let delay = seconds
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            await self?.fireIfIdle(scheduled)
        }
    }

    private func fireIfIdle(_ scheduled: Int) async {
        guard scheduled == generation else { return }   // a newer use bumped us
        await onIdle()
    }
}

/// Coalesces overlapping async setup calls. Swift actors are reentrant at
/// every `await`, so a simple `guard model == nil` does not prevent two callers
/// from downloading or loading the same model concurrently.
actor AsyncSingleFlight {
    private var task: Task<Void, Never>?
    private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]

    func run(_ operation: @escaping @Sendable () async throws -> Void) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                waiters[id] = continuation
                guard task == nil else { return }
                task = Task {
                    let result: Result<Void, Error>
                    do {
                        try await operation()
                        try Task.checkCancellation()
                        result = .success(())
                    } catch {
                        result = .failure(error)
                    }
                    finish(result)
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
        // Cancellation racing successful completion must not report Ready.
        try Task.checkCancellation()
    }

    var isRunning: Bool { task != nil }
    var waiterCount: Int { waiters.count }

    private func cancelWaiter(_ id: UUID) {
        guard let waiter = waiters.removeValue(forKey: id) else { return }
        waiter.resume(throwing: CancellationError())
        // Another consumer (for example a recording prewarm) still owns the
        // shared download. Cancel actual work only after its final owner leaves.
        if waiters.isEmpty { task?.cancel() }
    }

    private func finish(_ result: Result<Void, Error>) {
        task = nil
        let completed = waiters.values
        waiters.removeAll()
        for waiter in completed { waiter.resume(with: result) }
    }
}


/// Parakeet TDT 0.6B via FluidAudio — CoreML, in-process, runs on the
/// Neural Engine (~190x realtime on M4). v3 = 25 European languages,
/// v2 = English-only with higher recall. The model (~600 MB) is fetched
/// from Hugging Face on first use and cached; the only network access.
actor ParakeetEngine: TranscriptionEngine {

    enum Variant: Sendable {
        case v3, v2
        var modelVersion: AsrModelVersion { self == .v3 ? .v3 : .v2 }
    }

    /// One instance per variant so the pipeline, dictation prewarm, and the
    /// Models UI can each target a variant without racing over shared state.
    static let v3 = ParakeetEngine(variant: .v3)
    static let v2 = ParakeetEngine(variant: .v2)

    nonisolated let displayName = "Parakeet TDT 0.6B"
    nonisolated let supportsStreaming = false

    private let variant: Variant
    private var manager: AsrManager?
    private let preparation = AsyncSingleFlight()
    private var activeUses = 0
    private lazy var idle = IdleTimer(seconds: 120) { [weak self] in await self?.unload() }

    private init(variant: Variant) { self.variant = variant }

    /// Downloads (first run) and loads the CoreML model. Idempotent.
    func prepare(progress: ModelPreparationProgressHandler? = nil) async throws {
        guard manager == nil else { return }
        reportPreparationUpdate(.init(fractionCompleted: nil, status: "Checking..."),
                                to: progress)
        try await preparation.run { [weak self] in
            guard let self else { return }
            try await self.performPreparation(progress: progress)
        }
        await idle.bump()
        reportPreparationUpdate(.init(fractionCompleted: 1, status: "Ready"), to: progress)
    }

    private func performPreparation(progress: ModelPreparationProgressHandler?) async throws {
        guard manager == nil else { return }
        let runtimeID = variant == .v3
            ? "transcription:parakeet-v3" : "transcription:parakeet-v2"
        let runtimeLabel = variant == .v3
            ? "Parakeet TDT 0.6B v3" : "Parakeet TDT 0.6B v2"
        let estimatedBytes = ModelRuntimeRegistry.gibibytes(0.6)
        await ModelRuntimeRegistry.shared.reserve(
            id: runtimeID, role: "Transcribe", label: runtimeLabel,
            estimatedBytes: estimatedBytes)
        do {
            try Task.checkCancellation()
            let modelDirectory = TranscriptionModelStore.Environment.live.fluidAudioModelsRoot
                .appendingPathComponent(variant == .v3 ? Repo.parakeetV3.folderName : Repo.parakeetV2.folderName)
            let snapshot = try PinnedModelSnapshot.catalog(variant == .v3 ? "parakeetV3" : "parakeetV2")
            try await snapshot.prepare(in: modelDirectory, progress: progress)
            guard !FileManager.default.fileExists(atPath: modelDirectory.appendingPathComponent(ModelNames.ASR.ctcHeadFile).path) else {
                throw PinnedModelSnapshot.SnapshotError.unexpectedWeights
            }
            let models = try AsrModels.loadLocal(from: modelDirectory, version: variant.modelVersion)
            reportPreparationUpdate(.init(fractionCompleted: nil, status: "Loading..."),
                                    to: progress)
            let m = AsrManager(config: .default)
            try await m.loadModels(models)
            try Task.checkCancellation()
            manager = m
            await ModelRuntimeRegistry.shared.register(
                id: runtimeID, role: "Transcribe", label: runtimeLabel,
                estimatedBytes: estimatedBytes)
        } catch {
            await ModelRuntimeRegistry.shared.unregister(id: runtimeID)
            throw error
        }
    }

    /// Free the loaded model after an idle period (driven by `idle`).
    private func unload() async {
        guard activeUses == 0, !(await preparation.isRunning) else { return }
        manager = nil
        await ModelRuntimeRegistry.shared.unregister(
            id: variant == .v3 ? "transcription:parakeet-v3" : "transcription:parakeet-v2"
        )
    }

    func transcribe(audio url: URL, language: String?) async throws -> Transcript {
        activeUses += 1
        defer { finishUse() }
        try await prepare()
        guard let manager else { throw TranscriptionEngineError.notLoaded }
        var state = try TdtDecoderState()
        let hint = language.flatMap { Language(rawValue: $0) }
        let result = try await manager.transcribe(url, decoderState: &state, language: hint)
        let transcript = Transcript(segments: Self.segments(from: result, speaker: "speaker"),
                                    engine: "\(variant == .v2 ? "parakeet-tdt-0.6b-v2" : "parakeet-tdt-0.6b-v3") (FluidAudio)")
        return transcript
    }

    private func finishUse() {
        activeUses -= 1
        guard activeUses == 0 else { return }
        Task { await idle.bump() }
    }

    // MARK: - Token timings → readable segments

    /// Group plain text into one segment per track when an engine has no
    /// timestamps (Cohere). Track-level Me/Them attribution still works.
    static func singleSegment(text: String, duration: TimeInterval,
                              speaker: String) -> [Transcript.Segment] {
        let trimmed = Transcript.normalizedText(text)
        guard !trimmed.isEmpty else { return [] }
        return [Transcript.Segment(start: 0, end: duration, speaker: speaker,
                                   text: trimmed, confidence: nil,
                                   timingPrecision: .coarse)]
    }

    /// Groups token timings into sentence-ish segments: split on silence
    /// gaps > 1 s, on sentence-ending punctuation once a segment has grown
    /// past ~200 chars, or after 30 s regardless.
    static func segments(from result: ASRResult, speaker: String) -> [Transcript.Segment] {
        guard let timings = result.tokenTimings, !timings.isEmpty else {
            let text = Transcript.normalizedText(result.text)
            guard !text.isEmpty else { return [] }
            return [Transcript.Segment(start: 0, end: result.duration, speaker: speaker,
                                       text: text, confidence: Double(result.confidence),
                                       timingPrecision: .coarse)]
        }

        var out: [Transcript.Segment] = []
        var current: [TokenTiming] = []
        var currentLength = 0

        func flush() {
            guard let first = current.first, let last = current.last else { return }
            let text = Transcript.normalizedText(current.map(\.token).joined()
                .replacingOccurrences(of: "  ", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines))
            if !text.isEmpty {
                let conf = current.map { Double($0.confidence) }.reduce(0, +) / Double(current.count)
                out.append(.init(start: first.startTime, end: last.endTime,
                                 speaker: speaker, text: text, confidence: conf,
                                 timingPrecision: .token))
            }
            current = []
            currentLength = 0
        }

        for timing in timings {
            if let last = current.last, let first = current.first {
                let gap = timing.startTime - last.endTime
                let duration = last.endTime - first.startTime
                let sentenceEnded = last.token.hasSuffix(".") || last.token.hasSuffix("!")
                    || last.token.hasSuffix("?")
                if gap > 1.0 || duration > 30 || (sentenceEnded && currentLength > 200) {
                    flush()
                }
            }
            current.append(timing)
            currentLength += timing.token.count
        }
        flush()
        return out
    }
}

/// Whisper large-v3 turbo via WhisperKit (CoreML, ~1.6 GB, auto-downloaded
/// from Hugging Face on first use). 99 languages, real segment timestamps.
actor WhisperEngine: TranscriptionEngine {
    static let shared = WhisperEngine()
    nonisolated let displayName = "Whisper large-v3 turbo"
    nonisolated let supportsStreaming = false

    private var pipe: WhisperKit?
    private let preparation = AsyncSingleFlight()
    private var activeUses = 0
    private let modelName = "large-v3-v20240930"
    private lazy var idle = IdleTimer(seconds: 120) { [weak self] in await self?.unload() }

    func prepare(progress: ModelPreparationProgressHandler? = nil) async throws {
        guard pipe == nil else { return }
        reportPreparationUpdate(.init(fractionCompleted: nil, status: "Checking..."),
                                to: progress)
        try await preparation.run { [weak self] in
            guard let self else { return }
            try await self.performPreparation(progress: progress)
        }
        await idle.bump()
        reportPreparationUpdate(.init(fractionCompleted: 1, status: "Ready"), to: progress)
    }

    private func performPreparation(progress: ModelPreparationProgressHandler?) async throws {
        guard pipe == nil else { return }
        let runtimeID = "transcription:whisper-large-v3-turbo"
        let estimatedBytes = ModelRuntimeRegistry.gibibytes(1.6)
        await ModelRuntimeRegistry.shared.reserve(
            id: runtimeID, role: "Transcribe", label: "Whisper large-v3 turbo",
            estimatedBytes: estimatedBytes)
        do {
            try Task.checkCancellation()
            let environment = TranscriptionModelStore.Environment.live
            do {
                try TranscriptionModelStore.migrateLegacyWhisperKitModels(
                    environment: environment)
            } catch {
                lokalbotLog(
                    "whisper cache migration skipped error=\(error.localizedDescription)")
            }
            let downloadRoot = environment.whisperKitDownloadRoot
            let modelFolder = environment.whisperKitRepoRoot.appendingPathComponent("openai_whisper-\(modelName)")
            try await PinnedModelSnapshot.catalog("whisper").prepare(in: modelFolder, progress: progress)
            let tokenizerFolder = modelFolder.appendingPathComponent(".lokalbot-tokenizer")
            let tokenizerSnapshot = try PinnedModelSnapshot.catalog("whisperTokenizer")
            try await tokenizerSnapshot.prepare(in: tokenizerFolder, progress: progress)
            // WhisperKit searches a nested Hub cache before this folder and
            // can populate it on a tokenizer parse failure. Never accept that
            // mutable fallback as the configured pinned tokenizer.
            let fallback = tokenizerFolder.appendingPathComponent("models")
            guard !FileManager.default.fileExists(atPath: fallback.path) else {
                throw PinnedModelSnapshot.SnapshotError.unexpectedWeights
            }
            // Fail locally if the pinned tokenizer cannot be parsed. The
            // dependency's convenience loader otherwise downloads mutable
            // Hub files even when model downloads are disabled.
            _ = try await AutoTokenizerWrapper.from(modelFolder: tokenizerFolder)
            reportPreparationUpdate(.init(fractionCompleted: nil, status: "Loading..."),
                                    to: progress)
            let prepared = try await WhisperKit(WhisperKitConfig(
                model: modelName,
                downloadBase: downloadRoot,
                modelFolder: modelFolder.path(percentEncoded: false),
                tokenizerFolder: tokenizerFolder,
                download: false))
            try tokenizerSnapshot.verify(in: tokenizerFolder)
            guard !FileManager.default.fileExists(atPath: fallback.path) else {
                throw PinnedModelSnapshot.SnapshotError.unexpectedWeights
            }
            try Task.checkCancellation()
            pipe = prepared
            await ModelRuntimeRegistry.shared.register(
                id: runtimeID, role: "Transcribe", label: "Whisper large-v3 turbo",
                estimatedBytes: estimatedBytes)
        } catch {
            pipe = nil
            await ModelRuntimeRegistry.shared.unregister(id: runtimeID)
            throw error
        }
    }

    private func unload() async {
        guard activeUses == 0, !(await preparation.isRunning) else { return }
        pipe = nil
        await ModelRuntimeRegistry.shared.unregister(
            id: "transcription:whisper-large-v3-turbo"
        )
    }

    func transcribe(audio url: URL, language: String?) async throws -> Transcript {
        try await transcribe(audio: url, language: language, prompt: nil)
    }

    func transcribe(audio url: URL, language: String?, prompt: String?) async throws -> Transcript {
        activeUses += 1
        defer { finishUse() }
        try await prepare()
        guard let pipe else { throw TranscriptionEngineError.notLoaded }
        let promptTokens = TranscriptionPrompt.normalized(prompt).flatMap { context in
            pipe.tokenizer?.encode(text: " " + context)
        }
        let options = DecodingOptions(
            language: language,
            detectLanguage: language == nil,
            promptTokens: promptTokens)
        let results = try await pipe.transcribe(audioPath: url.path, decodeOptions: options)
        let segments = results.flatMap(\.segments).map { seg in
            Transcript.Segment(start: TimeInterval(seg.start), end: TimeInterval(seg.end),
                               speaker: "speaker",
                               text: Transcript.normalizedText(seg.text),
                               confidence: nil,
                               timingPrecision: .span)
        }.filter { !$0.text.isEmpty }
        return Transcript(segments: segments, engine: "whisper-large-v3-turbo (WhisperKit)")
    }

    private func finishUse() {
        activeUses -= 1
        guard activeUses == 0 else { return }
        Task { await idle.bump() }
    }
}

/// Cohere Transcribe (03-2026) via FluidAudio — CoreML int8, 14 languages.
/// The model emits no timestamps, so each track is split into VAD speech regions
/// and transcribed per region, giving real per-utterance timing (with a
/// whole-track single-segment fallback when VAD is unavailable).
actor CohereEngine: TranscriptionEngine {
    static let shared = CohereEngine()
    nonisolated let displayName = "Cohere Transcribe"
    nonisolated let supportsStreaming = false

    private var models: CoherePipeline.LoadedModels?
    private let preparation = AsyncSingleFlight()
    private var activeUses = 0
    private let pipeline = CoherePipeline()
    private lazy var idle = IdleTimer(seconds: 120) { [weak self] in await self?.unload() }

    func prepare(progress: ModelPreparationProgressHandler? = nil) async throws {
        guard models == nil else { return }
        reportPreparationUpdate(.init(fractionCompleted: nil, status: "Checking..."),
                                to: progress)
        try await preparation.run { [weak self] in
            guard let self else { return }
            try await self.performPreparation(progress: progress)
        }
        await idle.bump()
        reportPreparationUpdate(.init(fractionCompleted: 1, status: "Ready"), to: progress)
    }

    private func performPreparation(progress: ModelPreparationProgressHandler?) async throws {
        guard models == nil else { return }
        let runtimeID = "transcription:cohere"
        let estimatedBytes = ModelRuntimeRegistry.gibibytes(2.1)
        await ModelRuntimeRegistry.shared.reserve(
            id: runtimeID, role: "Transcribe", label: "Cohere Transcribe",
            estimatedBytes: estimatedBytes)
        do {
            try Task.checkCancellation()
            let base = AppDirectories.fluidAudioRoot
            let repoDir = base.appendingPathComponent(Repo.cohereTranscribeCoreml.folderName)
            try await PinnedModelSnapshot.catalog("cohere").prepare(in: repoDir, progress: progress)
            reportPreparationUpdate(.init(fractionCompleted: nil, status: "Loading..."),
                                    to: progress)
            models = try await CoherePipeline.loadModels(
                encoderDir: repoDir, decoderDir: repoDir, vocabDir: repoDir)
            try Task.checkCancellation()
            await ModelRuntimeRegistry.shared.register(
                id: runtimeID, role: "Transcribe", label: "Cohere Transcribe",
                estimatedBytes: estimatedBytes)
        } catch {
            models = nil
            await ModelRuntimeRegistry.shared.unregister(id: runtimeID)
            throw error
        }
    }

    private func unload() async {
        guard activeUses == 0, !(await preparation.isRunning) else { return }
        models = nil
        await ModelRuntimeRegistry.shared.unregister(id: "transcription:cohere")
    }

    func transcribe(audio url: URL, language: String?) async throws -> Transcript {
        activeUses += 1
        defer { finishUse() }
        try await prepare()
        guard let models else { throw TranscriptionEngineError.notLoaded }
        let lang = language.flatMap { CohereAsrConfig.Language(rawValue: $0) } ?? .english
        let sampleRate = CohereAsrConfig.sampleRate

        // Cohere returns no timestamps, so transcribe each VAD speech region
        // (≤14 s) on its own and stamp it with the region's real start/end —
        // real per-utterance timing without forced alignment. Falls back to one
        // whole-track segment if VAD is unavailable.
        if let spans = await SpeechActivity.shared.vadSpans(in: url, maxSegmentSeconds: nil) {
            guard !spans.isEmpty else {
                return Transcript(segments: [], engine: "cohere-transcribe-03-2026 (FluidAudio, vad-segmented)")
            }
            let started = Date()
            let segments = try await SpanTranscription.segments(in: url, spans: spans) { samples, _ in
                try await self.pipeline.transcribe(
                    audio: samples, models: models, language: lang).text
            }
            if !segments.isEmpty {
                let total = spans.last?.end ?? 0
                let elapsed = Date().timeIntervalSince(started)
                lokalbotLog(
                    "cohere profile mode=vad-segmented duration=\(Self.formatSeconds(total)) regions=\(spans.count) segments=\(segments.count) elapsed=\(Self.formatSeconds(elapsed)) rtfx=\(Self.formatMultiplier(elapsed > 0 ? total / elapsed : 0)) language=\(lang.rawValue)")
                return Transcript(segments: segments,
                                  engine: "cohere-transcribe-03-2026 (FluidAudio, vad-segmented)")
            }
        }

        // Fallback: whole track as one segment (no timestamps).
        let conversionStarted = Date()
        let samples = try AudioConverter().resampleAudioFile(url)
        let conversionSeconds = Date().timeIntervalSince(conversionStarted)
        let duration = Double(samples.count) / Double(sampleRate)
        let pipelineStarted = Date()
        let result = try await pipeline.transcribeLong(audio: samples, models: models, language: lang)
        let pipelineSeconds = Date().timeIntervalSince(pipelineStarted)
        let totalSeconds = conversionSeconds + pipelineSeconds
        let rtfx = totalSeconds > 0 ? duration / totalSeconds : 0
        lokalbotLog(
            "cohere profile mode=whole-track duration=\(Self.formatSeconds(duration)) convert=\(Self.formatSeconds(conversionSeconds)) pipeline=\(Self.formatSeconds(pipelineSeconds)) encoder=\(Self.formatSeconds(result.encoderSeconds)) decoder=\(Self.formatSeconds(result.decoderSeconds)) total=\(Self.formatSeconds(totalSeconds)) rtfx=\(Self.formatMultiplier(rtfx)) language=\(lang.rawValue)")
        return Transcript(
            segments: ParakeetEngine.singleSegment(text: result.text, duration: duration,
                                                   speaker: "speaker"),
            engine: "cohere-transcribe-03-2026 (FluidAudio)")
    }

    private func finishUse() {
        activeUses -= 1
        guard activeUses == 0 else { return }
        Task { await idle.bump() }
    }

    private nonisolated static func formatSeconds(_ seconds: TimeInterval) -> String {
        String(format: "%.2fs", seconds)
    }

    private nonisolated static func formatMultiplier(_ value: Double) -> String {
        String(format: "%.2fx", value)
    }
}

/// Voice-activity gate over FluidAudio's Silero VAD. Lets the pipeline skip
/// transcribing a track with no speech (e.g. your mic while muted for the whole
/// call) rather than feeding silence to the ASR model, which can hallucinate
/// text. Conservative: any error/uncertainty reports speech so a real track is
/// never dropped. Idle-unloads the (small) VAD model like the ASR engines.
actor SpeechActivity {
    static let shared = SpeechActivity()

    private var manager: VadManager?
    private let preparation = AsyncSingleFlight()
    private var activeUses = 0
    private lazy var idle = IdleTimer(seconds: 120) { [weak self] in await self?.unload() }
    /// Single-entry segments cache. The pipeline gates each track on
    /// `speechSeconds` and the engine immediately re-requests the segments for
    /// the same file — without this, every track is decoded and VAD-swept
    /// twice. Deliberately segments-only: the decoded track (~230 MB per
    /// recorded hour) is released the moment the VAD sweep finishes, and
    /// transcription re-reads each span's window on demand (`SpanAudioReader`).
    /// Keyed on path + mtime + size; released with the idle unload.
    private var cachedSegments: (key: String, segments: [VadSegment])?

    /// Decode `url` to 16 kHz mono (transiently) and split it into ≤14 s
    /// speech regions (Silero VAD, ASR-tuned `.default` config), or nil when
    /// VAD is unavailable. Each region carries a real `startTime`/`endTime`,
    /// which lets timestamp-less engines (Cohere) emit per-region segments
    /// instead of one block per track.
    func speechSegments(in url: URL) async -> [VadSegment]? {
        activeUses += 1
        defer { finishUse() }
        let key = Self.cacheKey(for: url)
        if let cachedSegments, cachedSegments.key == key {
            return cachedSegments.segments
        }
        do {
            try await prepare()
            guard let manager else { return nil }
            let samples = try AudioConverter().resampleAudioFile(url)
            let segments = try await manager.segmentSpeech(samples)
            cachedSegments = (key, segments)
            return segments
        } catch {
            lokalbotLog("vad unavailable — transcribing without it: \(error.localizedDescription)")
            return nil
        }
    }

    /// Total seconds of detected speech in `url`, or nil when VAD is
    /// unavailable — in which case the caller should transcribe anyway.
    func speechSeconds(in url: URL) async -> Double? {
        await speechSegments(in: url)?.reduce(0.0) { $0 + $1.duration }
    }

    private nonisolated static func cacheKey(for url: URL) -> String {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let mtime = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? -1
        return "\(url.path)|\(mtime)|\(size)"
    }

    private func prepare() async throws {
        guard manager == nil else { return }
        try await preparation.run { [weak self] in
            guard let self else { return }
            try await self.performPreparation()
        }
    }

    private func performPreparation() async throws {
        guard manager == nil else { return }
        let runtimeID = "voice-activity:silero-vad"
        await ModelRuntimeRegistry.shared.reserve(
            id: runtimeID, role: "Voice activity", label: "Silero VAD",
            estimatedBytes: 1_048_576)
        do {
            let directory = TranscriptionModelStore.Environment.live.fluidAudioModelsRoot.appendingPathComponent(Repo.vad.folderName)
            try await PinnedModelSnapshot.catalog("sileroVAD").prepare(in: directory)
            let config = MLModelConfiguration()
            config.computeUnits = VadConfig.default.computeUnits
            let vadModel = try MLModel(contentsOf: directory.appendingPathComponent(ModelNames.VAD.sileroVadFile), configuration: config)
            try Task.checkCancellation()
            manager = VadManager(vadModel: vadModel)
            await ModelRuntimeRegistry.shared.register(
                id: runtimeID, role: "Voice activity", label: "Silero VAD",
                estimatedBytes: 1_048_576)
        } catch {
            await ModelRuntimeRegistry.shared.unregister(id: runtimeID)
            throw error
        }
    }

    private func unload() async {
        guard activeUses == 0, !(await preparation.isRunning) else { return }
        manager = nil
        cachedSegments = nil
        await ModelRuntimeRegistry.shared.unregister(id: "voice-activity:silero-vad")
    }

    private func finishUse() {
        activeUses -= 1
        guard activeUses == 0 else { return }
        Task { await idle.bump() }
    }
}
