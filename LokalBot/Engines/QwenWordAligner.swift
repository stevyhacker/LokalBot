import Foundation
import Qwen3ForcedAlignerCoreML

struct AlignedWordTiming: Sendable, Equatable {
    var text: String
    var start: TimeInterval
    var end: TimeInterval
}

actor QwenWordAligner {
    static let shared = QwenWordAligner()

    static let snapshot = PinnedModelSnapshot.qwenAligner
    private static let runtimeID = "alignment:qwen3-forced-aligner"
    private static let label = "Qwen3 forced aligner"
    private static let sampleRate = 16_000

    static let maxSegmentSeconds: TimeInterval = 30
    static let maxSamples = 3_000 * 160 + 159

    static let estimatedBytes = ModelRuntimeRegistry.gibibytes(0.9)

    static let supportedLanguages: Set<String> = ["zh", "en", "yue", "fr", "de", "it", "ja", "ko", "pt", "ru", "es"]

    private let directoryOverride: URL?
    private var model: CoreMLForcedAligner?
    private let downloading = AsyncSingleFlight()
    private let loading = AsyncSingleFlight()
    private var activeUses = 0
    private lazy var idle = IdleTimer(seconds: 120) { [weak self] in await self?.unload() }

    init(directory: URL? = nil) {
        directoryOverride = directory
    }

    nonisolated static func supports(_ language: String) -> Bool {
        supportedLanguages.contains(TranscriptLanguageVote.baseCode(language))
    }

    nonisolated static func detectedLanguage(of texts: [String]) -> String? {
        guard let vote = TranscriptLanguageVote.dominant(in: texts),
              supportedLanguages.contains(vote.code) else { return nil }
        return vote.code
    }

    func downloadIfNeeded() async throws {
        let directory = try modelDirectory()
        let replacesObsolete = directoryOverride == nil && !UITestRuntime.isUnitTesting
        try await downloading.run {
            try await Self.snapshot.prepare(in: directory)
            if replacesObsolete { try Self.removeObsoleteModels() }
        }
    }

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
            return try autoreleasepool {
                try model.align(audio: audio, text: text, sampleRate: Self.sampleRate, language: language)
                    .map { AlignedWordTiming(text: $0.text, start: TimeInterval($0.startTime), end: TimeInterval($0.endTime)) }
            }
        } catch {
            throw AlignerError.rejected(String(describing: error))
        }
    }

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
