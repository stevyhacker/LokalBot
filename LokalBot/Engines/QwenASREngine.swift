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

    private static let sampleRate = 16_000
    private static let maxSegmentSeconds = 15.0

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
        activeUses += 1
        defer { finishUse() }
        try await prepare()
        guard let model else { throw EngineError.notLoaded }

        let started = Date()
        let spans = try await SpeechActivity.shared.spans(
            in: url, maxSegmentSeconds: Self.maxSegmentSeconds)
        let segments = try await SpanTranscription.segments(in: url, spans: spans) { samples, _ in
            model.transcribe(
                audio: Self.samplesForInference(samples),
                sampleRate: Self.sampleRate,
                language: Self.qwenLanguage(language),
                maxTokens: Self.maxTokens(for: samples.count),
                context: TranscriptionPrompt.normalized(prompt))
        }
        let elapsed = Date().timeIntervalSince(started)
        let duration = spans.last?.end ?? 0
        lokalbotLog(
            "qwen-asr profile model=\(variant.modelID) spans=\(spans.count) elapsed=\(String(format: "%.2fs", elapsed)) rtfx=\(String(format: "%.1fx", elapsed > 0 ? duration / elapsed : 0))")
        return Transcript(segments: segments, engine: "\(variant.modelID) (Qwen3ASR MLX)")
    }

    private func unload() async {
        guard activeUses == 0, !(await preparation.isRunning) else { return }
        model = nil
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

    private static func maxTokens(for sampleCount: Int) -> Int {
        let seconds = Double(sampleCount) / Double(sampleRate)
        return min(768, max(128, Int(seconds * 18)))
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
