import Foundation
import Qwen3ASR

/// A transcript word located in the audio, on the caller's timeline.
struct AlignedWordTiming: Sendable, Equatable {
    /// Surface form, including adjacent punctuation.
    var text: String
    var start: TimeInterval
    var end: TimeInterval
}

/// Word timings for Qwen3-ASR text from speech-swift's Qwen3 forced aligner.
/// It lets a diarized track be transcribed whole and attributed word by word,
/// instead of cutting the audio into speaker regions before ASR.
actor QwenWordAligner {
    static let shared = QwenWordAligner()

    static let snapshot = PinnedModelSnapshot.qwenAligner
    private static let runtimeID = "alignment:qwen3-forced-aligner"
    private static let label = "Qwen3 forced aligner"

    /// Languages Qwen3-ForcedAligner-0.6B is trained on (model card). Other
    /// languages keep region attribution rather than unmeasured timings.
    static let supportedLanguages: Set<String> = ["zh", "en", "yue", "fr", "de", "it", "ja", "ko", "pt", "ru", "es"]

    /// MLX keeps every freed buffer for reuse, but each segment's audio and
    /// text have their own length, so a pass rarely fits the last one's
    /// buffers. Untrimmed, the pool grew by about 1 GB a segment until MLX's
    /// own limit: the 95 segments of a 44-minute track peaked at 31 GB and
    /// took 46 s, against 5 GB and 24 s trimmed. Nothing else bounds it: only
    /// Qwen3-ASR 1.7B lowers the process-wide cache limit, and neither the
    /// 0.6B model nor a transcription server does.
    static let scratchCacheLimit = 512 * 1024 * 1024

    private let directoryOverride: URL?
    private var model: Qwen3ForcedAligner?
    private let downloading = AsyncSingleFlight()
    private let loading = AsyncSingleFlight()
    private var activeUses = 0
    private lazy var idle = IdleTimer(seconds: 120) { [weak self] in await self?.unload() }

    /// `directory` overrides the Application Support location (hardware tests).
    init(directory: URL? = nil) {
        directoryOverride = directory
    }

    /// True for a transcription language code the aligner supports ("zh-Hant" → "zh").
    nonisolated static func supports(_ language: String) -> Bool {
        supportedLanguages.contains(TranscriptLanguageVote.baseCode(language))
    }

    /// The aligner language for segment `texts` when the transcription
    /// language was auto-detected, or nil when their dominant language is not
    /// supported. Voted per segment, so a misdetected opening cannot decide it.
    nonisolated static func detectedLanguage(of texts: [String]) -> String? {
        guard let vote = TranscriptLanguageVote.dominant(in: texts),
              supportedLanguages.contains(vote.code) else { return nil }
        return vote.code
    }

    /// Download and verify the pinned files without loading them, so the
    /// recording-time prewarm never holds the weights in memory.
    func downloadIfNeeded() async throws {
        let directory = try modelDirectory()
        try await downloading.run {
            try await Self.snapshot.prepare(in: directory)
        }
    }

    /// Word timings for `text` within `samples` (16 kHz mono), relative to the
    /// first sample. Words the aligner cannot tokenize ride on their neighbour.
    func align(_ samples: [Float], text: String, language: String) async throws -> [AlignedWordTiming] {
        activeUses += 1
        defer { finishUse() }
        try await load()
        guard let model else { throw AlignerError.notLoaded }
        try Task.checkCancellation()
        defer { MLXMemoryRelease.trimCachedBuffers(above: Self.scratchCacheLimit) }
        return model.align(audio: QwenASREngine.samplesForInference(samples), text: text,
                           sampleRate: 16_000, language: language)
            .map { AlignedWordTiming(text: $0.text, start: TimeInterval($0.startTime), end: TimeInterval($0.endTime)) }
    }

    /// Returns the scratch buffers once a track's segments are aligned, while
    /// the weights stay loaded for the next track until the idle unload.
    func finishBatch() {
        MLXMemoryRelease.trimCachedBuffers(above: 0)
    }

    private func load() async throws {
        if model != nil { return }
        try await loading.run { [weak self] in
            guard let self else { return }
            try await self.performLoad()
        }
        await idle.bump()
    }

    private func performLoad() async throws {
        guard model == nil else { return }
        let estimatedBytes = ModelRuntimeRegistry.gibibytes(1.1)
        await ModelRuntimeRegistry.shared.reserve(
            id: Self.runtimeID, role: "Speaker attribution", label: Self.label, estimatedBytes: estimatedBytes)
        do {
            try await downloadIfNeeded()
            try Task.checkCancellation()
            model = try await Qwen3ForcedAligner.fromPretrained(
                modelId: Self.snapshot.repository, cacheDir: try modelDirectory(), offlineMode: true)
            try Task.checkCancellation()
            await ModelRuntimeRegistry.shared.register(
                id: Self.runtimeID, role: "Speaker attribution", label: Self.label, estimatedBytes: estimatedBytes)
        } catch {
            model = nil
            await ModelRuntimeRegistry.shared.unregister(id: Self.runtimeID)
            throw error
        }
    }

    private func unload() async {
        guard activeUses == 0, !(await loading.isRunning) else { return }
        model = nil
        MLXMemoryRelease.releaseCachedBuffers(after: "qwen-aligner")
        await ModelRuntimeRegistry.shared.unregister(id: Self.runtimeID)
    }

    private func finishUse() {
        activeUses -= 1
        guard activeUses == 0 else { return }
        Task { await idle.bump() }
    }

    private func modelDirectory() throws -> URL {
        try directoryOverride ?? Self.directory()
    }

    /// Same Hub-style layout as the Qwen ASR models, which speech-swift's
    /// offline loader expects (see `QwenASREngine.hubStyleCacheDir`).
    private static func directory() throws -> URL {
        let root = AppDirectories.applicationSupport.appendingPathComponent("qwen3-asr-models", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return QwenASREngine.hubStyleCacheDir(base: root, modelID: snapshot.repository)
    }

    enum AlignerError: LocalizedError {
        case notLoaded
        var errorDescription: String? { "The Qwen3 forced aligner failed to load." }
    }
}
