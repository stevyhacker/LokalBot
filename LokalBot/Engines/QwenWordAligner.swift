import Foundation
import Qwen3ASR

/// A transcript word located in the audio, on the caller's timeline.
struct AlignedWordTiming: Sendable, Equatable {
    /// Surface form, including adjacent punctuation.
    var text: String
    var start: TimeInterval
    var end: TimeInterval
}

/// Word timings for Qwen3-ASR text from speech-swift's CoreML Qwen3 forced
/// aligner. It lets a diarized track be transcribed whole and attributed word
/// by word, instead of cutting the audio into speaker regions before ASR.
///
/// The CoreML export replaced the MLX 4-bit aligner after attributing as well
/// on identical text (AMI cpWER −0.10, −0.58…+0.36) at about a quarter of the
/// memory (0.9 GB against 3.5–4.1 GB peak footprint; Benchmarks/transcribe/
/// QwenSpanLength/results/2026-11-15). Its shapes are fixed: at most 30 s of
/// audio, and one 768-token pass that holds the prompt, 13 audio tokens a
/// second, and each word with two timestamp slots.
actor QwenWordAligner {
    static let shared = QwenWordAligner()

    static let snapshot = PinnedModelSnapshot.qwenAligner
    private static let runtimeID = "alignment:qwen3-forced-aligner"
    private static let label = "Qwen3 forced aligner"
    private static let sampleRate = 16_000

    /// The audio encoder's 3,000 mel frames. The extractor makes one frame per
    /// full 160 samples, so 30 s fits with a frame to spare for rounding at
    /// the segment's edges. Callers keep segments within `maxSegmentSeconds`.
    static let maxSegmentSeconds: TimeInterval = 30
    static let maxSamples = 3_000 * 160 + 159

    /// Peak physical footprint while aligning long meeting tracks: 0.89 GB
    /// on the benchmark, mostly the mapped embedding table and the decoder.
    static let estimatedBytes = ModelRuntimeRegistry.gibibytes(0.9)

    /// Languages Qwen3-ForcedAligner-0.6B is trained on (model card). Other
    /// languages keep region attribution rather than unmeasured timings.
    static let supportedLanguages: Set<String> = ["zh", "en", "yue", "fr", "de", "it", "ja", "ko", "pt", "ru", "es"]

    private let directoryOverride: URL?
    private var model: CoreMLForcedAligner?
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
        // The unit-test host shares the release app's folders; never touch them there.
        let replacesObsolete = directoryOverride == nil && !UITestRuntime.isUnitTesting
        try await downloading.run {
            try await Self.snapshot.prepare(in: directory)
            if replacesObsolete { try Self.removeObsoleteModels() }
        }
    }

    /// Aligners this app used before. Their folders are never read again and
    /// are deleted, by exact path, once the current snapshot is verified.
    nonisolated static let obsoleteRepositories = ["aufklarer/Qwen3-ForcedAligner-0.6B-4bit"]

    nonisolated static func removeObsoleteModels(in root: URL? = nil) throws {
        let base = try root ?? modelsRoot()
        for repository in obsoleteRepositories where repository != snapshot.repository {
            let folder = QwenASREngine.hubStyleCacheDir(base: base, modelID: repository)
            let values = try? folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values?.isDirectory == true, values?.isSymbolicLink != true else { continue }
            do {
                try FileManager.default.removeItem(at: folder)
                lokalbotLog("removed obsolete aligner folder repository=\(repository)")
            } catch {
                lokalbotLog("could not remove obsolete aligner folder repository=\(repository): \(error.localizedDescription)")
            }
        }
    }

    /// Word timings for `text` within `samples` (16 kHz mono), relative to the
    /// first sample. Words the aligner cannot tokenize ride on their neighbour.
    /// Throws for a segment longer than 30 s or with more text than one pass
    /// holds; the caller then keeps one speaker for the segment.
    func align(_ samples: [Float], text: String, language: String) async throws -> [AlignedWordTiming] {
        guard samples.count <= Self.maxSamples else {
            throw AlignerError.segmentTooLong(seconds: Double(samples.count) / Double(Self.sampleRate))
        }
        activeUses += 1
        defer { finishUse() }
        try await load()
        guard let model else { throw AlignerError.notLoaded }
        try Task.checkCancellation()
        let audio = QwenASREngine.samplesForInference(samples)
        do {
            // Each pass returns autoreleased MLMultiArrays (about 12 MB, mostly
            // logits). A track aligns in one task, so without a pool per pass
            // they piled up: 0.8 GB grew to 4.6 GB over 101 minutes of audio.
            return try autoreleasepool {
                try model.align(audio: audio, text: text, sampleRate: Self.sampleRate, language: language)
                    .map { AlignedWordTiming(text: $0.text, start: TimeInterval($0.startTime), end: TimeInterval($0.endTime)) }
            }
        } catch {
            throw AlignerError.rejected(String(describing: error))
        }
    }

    /// Called once a track's segments are aligned. The CoreML aligner keeps
    /// no scratch state between passes; the weights stay loaded for the next
    /// track until the idle unload.
    func finishBatch() {}

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
        await ModelRuntimeRegistry.shared.reserve(
            id: Self.runtimeID, role: "Speaker attribution", label: Self.label, estimatedBytes: Self.estimatedBytes)
        do {
            try await downloadIfNeeded()
            try Task.checkCancellation()
            // The repository ships compiled bundles, so nothing compiles here.
            // The first load on a Mac still specializes them for the Neural
            // Engine (about 13 s); macOS caches that, and later loads take 0.6 s.
            let started = Date()
            model = try CoreMLForcedAligner.fromDirectory(try modelDirectory())
            lokalbotLog("qwen aligner loaded engine=coreml-int8 elapsed=\(String(format: "%.1fs", Date().timeIntervalSince(started)))")
            try Task.checkCancellation()
            await ModelRuntimeRegistry.shared.register(
                id: Self.runtimeID, role: "Speaker attribution", label: Self.label, estimatedBytes: Self.estimatedBytes)
        } catch {
            model = nil
            await ModelRuntimeRegistry.shared.unregister(id: Self.runtimeID)
            throw error
        }
    }

    private func unload() async {
        guard activeUses == 0, !(await loading.isRunning) else { return }
        model = nil
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

    /// Next to the Qwen ASR models, in the same Hub-style layout.
    private static func directory() throws -> URL {
        QwenASREngine.hubStyleCacheDir(base: try modelsRoot(), modelID: snapshot.repository)
    }

    private nonisolated static func modelsRoot() throws -> URL {
        let root = AppDirectories.applicationSupport.appendingPathComponent("qwen3-asr-models", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    enum AlignerError: LocalizedError {
        case notLoaded
        case segmentTooLong(seconds: Double)
        case rejected(String)

        var errorDescription: String? {
            switch self {
            case .notLoaded:
                "The Qwen3 forced aligner failed to load."
            case .segmentTooLong(let seconds):
                "The segment is \(String(format: "%.1f", seconds)) s; the Qwen3 forced aligner takes at most 30 s."
            case .rejected(let reason):
                "The Qwen3 forced aligner rejected the segment: \(reason)"
            }
        }
    }
}
