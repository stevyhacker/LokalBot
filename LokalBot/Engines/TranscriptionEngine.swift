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

enum TranscriptionModelChoice: String, Codable, CaseIterable, Identifiable {
    case parakeetUltra = "parakeet-ultra"
    case parakeetV3 = "parakeet-v3"
    case parakeetV2 = "parakeet-v2"
    case qwenASR17BLokalBotV3 = "qwen3-asr-1.7b-lokalbot-v3"
    case qwenASR17B = "qwen3-asr-1.7b"
    case qwenASR06BLokalBotV1 = "qwen3-asr-0.6b-lokalbot-v1"
    case qwenASR06B = "qwen3-asr-0.6b"
    case graniteSpeech = "granite-speech"
    case graniteSpeech5 = "granite-speech-5.0-2b"
    case whisperLarge = "whisper-large-v3-turbo"
    case funASRNano = "fun-asr-nano-2512"
    case senseVoice = "sense-voice"
    case gigaamRussian = "gigaam-russian"
    case cohere = "cohere-transcribe"
    case appleSpeech = "apple-speech"
    case remoteServer = "remote-server"
    var id: String { rawValue }
    static let recommended: Self = .qwenASR17BLokalBotV3

    var isLegacy: Bool { self == .cohere }

    var isRemote: Bool { self == .remoteServer }

    var isBuiltInSystem: Bool { self == .appleSpeech }

    var displayName: String {
        switch self {
        case .parakeetUltra: "Parakeet Ultra 0.6B (multilingual)"
        case .parakeetV3: "Parakeet TDT 0.6B v3 (multilingual)"
        case .parakeetV2: "Parakeet TDT 0.6B v2 (English)"
        case .qwenASR17BLokalBotV3: "Qwen3-ASR 1.7B (LokalBot v3)"
        case .qwenASR17B: "Qwen3-ASR 1.7B"
        case .qwenASR06BLokalBotV1: "Qwen3-ASR 0.6B (LokalBot v1)"
        case .qwenASR06B: "Qwen3-ASR 0.6B"
        case .graniteSpeech: "Granite Speech 4.1 2B"
        case .graniteSpeech5: "Granite Speech 5.0 2B"
        case .whisperLarge: "Whisper large-v3 turbo"
        case .cohere: "Cohere Transcribe (multilingual)"
        case .funASRNano: "Fun-ASR-Nano-2512"
        case .senseVoice: "SenseVoice (Chinese/Japanese/Korean)"
        case .gigaamRussian: "GigaAM (Russian)"
        case .appleSpeech: "Apple Speech"
        case .remoteServer: "Transcription server"
        }
    }

    static let removedGraniteTurbo = ["granite-speech-5-turbo", "Granite Speech 5 fast (English)"]

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        if Self.removedGraniteTurbo.contains(raw) {
            self = .parakeetV2
        } else if let choice = Self(rawValue: raw)
            ?? Self.allCases.first(where: { $0.displayName == raw }) {
            self = choice
        } else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Unknown transcription model choice: \(raw)"))
        }
    }

    var acceptsVocabularyPrompt: Bool {
        switch self {
        case .whisperLarge, .qwenASR17BLokalBotV3, .qwenASR17B, .qwenASR06BLokalBotV1, .qwenASR06B,
             .graniteSpeech5, .appleSpeech, .remoteServer: true
        default: false
        }
    }

    var sizeLabel: String? {
        guard let lead = blurb.components(separatedBy: " · ").first,
              lead.hasSuffix(" GB") || lead.hasSuffix(" MB") else { return nil }
        return lead
    }

    var blurb: String {
        switch self {
        case .parakeetUltra: "0.63 GB · 25 European languages, fast multilingual transcription"
        case .parakeetV3: "0.6 GB · 25 European languages, ~190× realtime"
        case .parakeetV2: "0.46 GB · English only, slightly higher recall"
        case .qwenASR17BLokalBotV3: "2.52 GB · llama.cpp, 52 languages/dialects, default LokalBot fine-tune"
        case .qwenASR17B: "2.52 GB · llama.cpp, 52 languages/dialects, stock Qwen baseline"
        case .qwenASR06BLokalBotV1: "1.02 GB · llama.cpp, 52 languages/dialects, compact LokalBot fine-tune"
        case .qwenASR06B: "1.02 GB · llama.cpp, 52 languages/dialects, stock compact Qwen baseline"
        case .graniteSpeech: "2B parameters · Apache-2.0, local speech recognition"
        case .graniteSpeech5: "3.12 GB · English, French, German, Spanish, Portuguese, Japanese · vocabulary prompts and punctuation"
        case .whisperLarge: "1.6 GB · 99 languages, word timestamps, wide-language legacy fallback"
        case .cohere: "2B params · legacy — no auto language detection, timestamps, or diarization"
        case .funASRNano: "Chinese · English · Japanese · local ONNX model folder"
        case .senseVoice: "Chinese · Japanese · Korean · Cantonese · English (ONNX, downloaded on first use)"
        case .gigaamRussian: "Russian — high accuracy (ONNX, downloaded on first use)"
        case .appleSpeech: "Built into macOS 26+ · on-device SpeechAnalyzer, word timestamps, and vocabulary hints"
        case .remoteServer: "OpenAI-style speech-to-text on a server you choose: OpenAI, Groq, OpenRouter, or whisper.cpp on another device. Sends audio to that server."
        }
    }

    var engine: TranscriptionEngine {
        switch self {
        case .parakeetUltra: ParakeetEngine.ultra
        case .parakeetV3: ParakeetEngine.v3
        case .parakeetV2: ParakeetEngine.v2
        case .qwenASR17BLokalBotV3: QwenASREngine.accuracyLokalBotV3
        case .qwenASR17B: QwenASREngine.accuracy
        case .qwenASR06BLokalBotV1: QwenASREngine.compactLokalBotV1
        case .qwenASR06B: QwenASREngine.compact
        case .graniteSpeech: GraniteSpeechEngine.shared
        case .graniteSpeech5: GraniteSpeechEngine.configured(.speech5)
        case .whisperLarge: WhisperEngine.shared
        case .cohere: CohereEngine.shared
        case .funASRNano: FunASRNanoEngine(directory: "")
        case .senseVoice: OnnxTranscriptionEngine.senseVoice
        case .gigaamRussian: OnnxTranscriptionEngine.gigaamRussian
        case .appleSpeech: AppleSpeechEngine.shared
        case .remoteServer: RemoteTranscriptionEngine(
            configuration: .init(baseURL: "", model: "", approvedOrigins: []), apiKey: { "" })
        }
    }
}

protocol TranscriptionEngine {
    var displayName: String { get }
    var checkpointIdentity: String { get throws }
    var supportsStreaming: Bool { get }
    var speakerAttribution: SpeakerAttributionStrategy { get }
    func prepare(progress: ModelPreparationProgressHandler?) async throws
    func transcribe(audio: URL, language: String?) async throws -> Transcript
    func transcribe(audio: URL, language: String?, prompt: String?) async throws -> Transcript
    func transcribeForWordAttribution(audio: URL, language: String?, prompt: String?) async throws -> WordTimedTranscript
    var providesWordTimings: Bool { get }
}

struct WordTimedTranscript {
    struct Segment: Sendable {
        var segment: Transcript.Segment
        var words: [AlignedWordTiming]?
    }

    var segments: [Segment]
    var engine: String
    var allowsForcedAlignment: Bool
    var trackLanguage: String?
    var needsSpeakerRegions = false

    init(segments: [Segment], engine: String, trackLanguage: String? = nil, allowsForcedAlignment: Bool = true) {
        self.segments = segments
        self.engine = engine
        self.trackLanguage = trackLanguage
        self.allowsForcedAlignment = allowsForcedAlignment
    }

    init(_ transcript: Transcript, trackLanguage: String? = nil) {
        self.init(segments: transcript.segments.map { Segment(segment: $0) }, engine: transcript.engine,
                  trackLanguage: trackLanguage)
    }

    var transcript: Transcript { Transcript(segments: segments.map(\.segment), engine: engine) }
}

enum SpeakerAttributionStrategy: Sendable {
    case regions
    case alignedWords
}

extension TranscriptionEngine {
    var checkpointIdentity: String { displayName }
    var speakerAttribution: SpeakerAttributionStrategy { .regions }

    var providesWordTimings: Bool { false }

    func transcribeForWordAttribution(audio: URL, language: String?, prompt: String?) async throws -> WordTimedTranscript {
        WordTimedTranscript(try await transcribe(audio: audio, language: language, prompt: prompt))
    }
}

extension TranscriptionEngine {
    func prepare() async throws { try await prepare(progress: nil) }

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
        guard scheduled == generation else { return }
        await onIdle()
    }
}

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
        try Task.checkCancellation()
    }

    var isRunning: Bool { task != nil }
    var waiterCount: Int { waiters.count }

    private func cancelWaiter(_ id: UUID) {
        guard let waiter = waiters.removeValue(forKey: id) else { return }
        waiter.resume(throwing: CancellationError())
        if waiters.isEmpty { task?.cancel() }
    }

    private func finish(_ result: Result<Void, Error>) {
        task = nil
        let completed = waiters.values
        waiters.removeAll()
        for waiter in completed { waiter.resume(with: result) }
    }
}


actor ParakeetEngine: TranscriptionEngine {

    enum Variant: CaseIterable, Sendable {
        case ultra, v3, v2

        var modelVersion: AsrModelVersion {
            switch self {
            case .ultra: .ultra
            case .v3: .v3
            case .v2: .v2
            }
        }

        var encoderPrecision: ParakeetEncoderPrecision {
            self == .v3 ? .int8V2 : .int8
        }

        var repository: Repo {
            switch self {
            case .ultra: .parakeetUltra
            case .v3: .parakeetV3
            case .v2: .parakeetV2
            }
        }

        var snapshotName: String {
            switch self {
            case .ultra: "parakeetUltra"
            case .v3: "parakeetV3"
            case .v2: "parakeetV2"
            }
        }

        var runtimeID: String {
            switch self {
            case .ultra: "transcription:parakeet-ultra"
            case .v3: "transcription:parakeet-v3"
            case .v2: "transcription:parakeet-v2"
            }
        }

        var displayName: String {
            switch self {
            case .ultra: "Parakeet Ultra 0.6B"
            case .v3: "Parakeet TDT 0.6B v3"
            case .v2: "Parakeet TDT 0.6B v2"
            }
        }

        var transcriptEngine: String {
            switch self {
            case .ultra: "parakeet-ultra (FluidAudio)"
            case .v3: "parakeet-tdt-0.6b-v3 (FluidAudio)"
            case .v2: "parakeet-tdt-0.6b-v2 (FluidAudio)"
            }
        }
    }

    static let ultra = ParakeetEngine(variant: .ultra)
    static let v3 = ParakeetEngine(variant: .v3)
    static let v2 = ParakeetEngine(variant: .v2)

    nonisolated let displayName: String
    nonisolated let supportsStreaming = false

    private let variant: Variant
    private var manager: AsrManager?
    private let preparation = AsyncSingleFlight()
    private var activeUses = 0
    private lazy var idle = IdleTimer(seconds: 120) { [weak self] in await self?.unload() }

    private init(variant: Variant) {
        self.variant = variant
        self.displayName = variant.displayName
    }

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
        let runtimeID = variant.runtimeID
        let runtimeLabel = variant.displayName
        let estimatedBytes = ModelRuntimeRegistry.gibibytes(0.6)
        await ModelRuntimeRegistry.shared.reserve(
            id: runtimeID, role: "Transcribe", label: runtimeLabel,
            estimatedBytes: estimatedBytes)
        do {
            try Task.checkCancellation()
            let modelDirectory = TranscriptionModelStore.Environment.live.fluidAudioModelsRoot
                .appendingPathComponent(variant.repository.folderName)
            let snapshot = try PinnedModelSnapshot.catalog(variant.snapshotName)
            try await snapshot.prepare(in: modelDirectory, progress: progress)
            guard !FileManager.default.fileExists(atPath: modelDirectory.appendingPathComponent(ModelNames.ASR.ctcHeadFile).path) else {
                throw PinnedModelSnapshot.SnapshotError.unexpectedWeights
            }
            let models = try AsrModels.loadLocal(from: modelDirectory, version: variant.modelVersion,
                                                encoderPrecision: variant.encoderPrecision)
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

    private func unload() async {
        guard activeUses == 0, !(await preparation.isRunning) else { return }
        manager = nil
        await ModelRuntimeRegistry.shared.unregister(id: variant.runtimeID)
    }

    nonisolated static func languageHint(_ language: String?, variant: Variant) throws -> Language? {
        if variant == .v2 { try TranscriptionModelChoice.parakeetV2.validateLanguage(language) }
        return language.flatMap { Language(rawValue: $0) }
    }

    func transcribe(audio url: URL, language: String?) async throws -> Transcript {
        let hint = try Self.languageHint(language, variant: variant)
        activeUses += 1
        defer { finishUse() }
        try await prepare()
        guard let manager else { throw TranscriptionEngineError.notLoaded }
        var state = try TdtDecoderState()
        let result = try await manager.transcribe(url, decoderState: &state, language: hint)
        let transcript = Transcript(segments: Self.segments(from: result, speaker: "speaker"),
                                    engine: variant.transcriptEngine)
        return transcript
    }

    private func finishUse() {
        activeUses -= 1
        guard activeUses == 0 else { return }
        Task { await idle.bump() }
    }

    static func singleSegment(text: String, duration: TimeInterval,
                              speaker: String) -> [Transcript.Segment] {
        let trimmed = Transcript.normalizedText(text)
        guard !trimmed.isEmpty else { return [] }
        return [Transcript.Segment(start: 0, end: duration, speaker: speaker,
                                   text: trimmed, confidence: nil,
                                   timingPrecision: .coarse)]
    }

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

        func isPunctuationOnly(_ token: String) -> Bool {
            token.rangeOfCharacter(from: .alphanumerics) == nil
        }
        func lastSpoken() -> TokenTiming? {
            current.last { !isPunctuationOnly($0.token) } ?? current.last
        }

        func flush() {
            guard let first = current.first, let last = lastSpoken() else { return }
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
            if !isPunctuationOnly(timing.token), let last = lastSpoken(), let first = current.first,
               let closing = current.last {
                let gap = timing.startTime - last.endTime
                let duration = last.endTime - first.startTime
                let sentenceEnded = closing.token.hasSuffix(".") || closing.token.hasSuffix("!")
                    || closing.token.hasSuffix("?")
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
            let fallback = tokenizerFolder.appendingPathComponent("models")
            guard !FileManager.default.fileExists(atPath: fallback.path) else {
                throw PinnedModelSnapshot.SnapshotError.unexpectedWeights
            }
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
        let options = Self.decodingOptions(language: language, promptTokens: promptTokens)
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

    nonisolated static func decodingOptions(language: String?, promptTokens: [Int]? = nil) -> DecodingOptions {
        DecodingOptions(language: language, detectLanguage: language == nil, promptTokens: promptTokens)
    }

    private func finishUse() {
        activeUses -= 1
        guard activeUses == 0 else { return }
        Task { await idle.bump() }
    }
}

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
        try TranscriptionModelChoice.cohere.validateLanguage(language)
        activeUses += 1
        defer { finishUse() }
        try await prepare()
        guard let models else { throw TranscriptionEngineError.notLoaded }
        let lang = language.flatMap { CohereAsrConfig.Language(rawValue: $0) } ?? .english
        let sampleRate = CohereAsrConfig.sampleRate

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

struct LiveVoiceState: Sendable {
    struct Unavailable: Error {}

    fileprivate var stream = VadStreamState.initial()

    init() {}
    fileprivate init(stream: VadStreamState) { self.stream = stream }
}

actor SpeechActivity {
    static let shared = SpeechActivity()

    private var manager: VadManager?
    private let preparation = AsyncSingleFlight()
    private var activeUses = 0
    private lazy var idle = IdleTimer(seconds: 120) { [weak self] in await self?.unload() }
    private var cachedSegments: (key: String, segments: [VadSegment])?

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

    func speechSeconds(in url: URL) async -> Double? {
        await speechSegments(in: url)?.reduce(0.0) { $0 + $1.duration }
    }

    func liveProbability(of chunk: [Float],
                         state: LiveVoiceState) async throws -> (probability: Float, state: LiveVoiceState) {
        activeUses += 1
        defer { finishUse() }
        try await prepare()
        guard let manager else { throw LiveVoiceState.Unavailable() }
        let result = try await manager.processStreamingChunk(chunk, state: state.stream)
        return (result.probability, LiveVoiceState(stream: result.state))
    }

    static let liveChunkFrames = VadManager.chunkSize

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
