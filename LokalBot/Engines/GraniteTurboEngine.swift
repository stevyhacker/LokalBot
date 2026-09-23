import Foundation

/// Optional English fast mode. SpeechActivity supplies timestamped spans;
/// TurboCTC supplies unpunctuated text. Diarization stays in the meeting pipeline.
actor GraniteTurboEngine: TranscriptionEngine {
    static let shared = GraniteTurboEngine()
    nonisolated let displayName = "Granite Speech 5 fast (English)"
    nonisolated let supportsStreaming = false
    nonisolated static let repository = "ibm-granite/granite-speech-5.0-470m-turboctc"
    nonisolated static let revision = "18ca3c1de6cd092b5a30c39fb0f04550b38ed1a0"

    struct Artifact: Sendable {
        let name: String
        let bytes: Int64
        let sha256: String
    }

    nonisolated static let artifacts: [Artifact] = [
        Artifact(name: "model.safetensors", bytes: 946_180_704,
                 sha256: "8b98a8c34fd5fcb081caef719638eded31bb6d197d62053eefc5c1703aaf1ad4"),
        Artifact(name: "tokenizer.json", bytes: 1_137_492,
                 sha256: "3ee80b02f0119a040a70eb909c20fac8271c173d7e71d195a3b35f77780061e6"),
    ]
    private let preparation = AsyncSingleFlight()
    private let appSupport: URL
    private var model: GraniteTurboModel?
    private var activeUses = 0
    private static let runtimeID = "transcription:granite-5-turbo"
    private lazy var idle = IdleTimer(seconds: 120) { [weak self] in await self?.unload() }

    init(appSupport: URL = AppDirectories.applicationSupport) {
        self.appSupport = appSupport
    }

    func prepare(progress: ModelPreparationProgressHandler? = nil) async throws {
        if model != nil { return }
        try await preparation.run { [weak self] in
            try await self?.performPreparation(progress: progress)
        }
        report(.init(fractionCompleted: 1, status: "Ready"), to: progress)
        await idle.bump()
    }

    private func performPreparation(progress: ModelPreparationProgressHandler?) async throws {
        guard model == nil else { return }
        let directory = Self.modelRoot(appSupport: appSupport)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let totalBytes = Self.artifacts.reduce(Int64(0)) { $0 + $1.bytes }
        var completedBytes: Int64 = 0
        for artifact in Self.artifacts {
            try Task.checkCancellation()
            let destination = directory.appendingPathComponent(artifact.name)
            report(.init(fractionCompleted: nil, status: "Checking model files..."), to: progress)
            if await DownloadIntegrity.verifiedExisting(
                at: destination, expectedBytes: artifact.bytes, expectedSHA256: artifact.sha256) {
                completedBytes += artifact.bytes
                continue
            }
            let url = URL(string: "https://huggingface.co/\(Self.repository)/resolve/\(Self.revision)/\(artifact.name)")!
            let completedBeforeDownload = completedBytes
            let stashed = try await ParallelRangeDownloader.download(from: url, session: .shared) { fraction in
                let complete = Double(completedBeforeDownload) + fraction.fractionCompleted * Double(artifact.bytes)
                self.report(.init(fractionCompleted: complete / Double(totalBytes), status: "Downloading English fast mode..."), to: progress)
            }
            do {
                try Task.checkCancellation()
                try await DownloadIntegrity.verifyDownloaded(
                    at: stashed, expectedBytes: artifact.bytes, expectedSHA256: artifact.sha256)
                try DownloadFileRescuer.install(stashed: stashed, to: destination)
                DownloadIntegrity.removeFileAndMarker(at: stashed)
                try DownloadIntegrity.markInstalled(
                    at: destination, expectedBytes: artifact.bytes, expectedSHA256: artifact.sha256)
                completedBytes += artifact.bytes
            } catch {
                DownloadIntegrity.removeFileAndMarker(at: stashed)
                throw error
            }
        }
        try Task.checkCancellation()
        report(.init(fractionCompleted: nil, status: "Loading English fast mode..."), to: progress)
        let estimatedBytes = ModelRuntimeRegistry.gibibytes(1.4)
        await ModelRuntimeRegistry.shared.reserve(
            id: Self.runtimeID, role: "Transcribe", label: displayName, estimatedBytes: estimatedBytes)
        do {
            model = try GraniteTurboModel(directory: directory)
            await ModelRuntimeRegistry.shared.register(
                id: Self.runtimeID, role: "Transcribe", label: displayName, estimatedBytes: estimatedBytes)
        } catch {
            await ModelRuntimeRegistry.shared.unregister(id: Self.runtimeID)
            throw error
        }
    }

    func transcribe(audio: URL, language: String?) async throws -> Transcript {
        guard Self.accepts(language: language) else { throw GraniteTurboError.unsupportedLanguage }
        activeUses += 1
        defer {
            activeUses -= 1
            Task { await idle.bump() }
        }
        try await prepare()
        let spans = try await SpeechActivity.shared.spans(in: audio, maxSegmentSeconds: 30)
        let segments = try await SpanTranscription.segments(in: audio, spans: spans) { samples, _ in
            try await self.decode(samples)
        }
        return Transcript(segments: segments, engine: "\(Self.repository) (native MLX)")
    }

    private func decode(_ samples: [Float]) throws -> String {
        guard let model else { throw TranscriptionEngineError.notLoaded }
        return try model.transcribe(samples)
    }

    nonisolated static func accepts(language: String?) -> Bool {
        guard let language else { return true }
        return ["", "auto", "en", "english"].contains(language.lowercased())
    }

    nonisolated static func modelRoot(appSupport: URL) -> URL {
        appSupport.appendingPathComponent("granite-turbo/5.0-470m", isDirectory: true)
    }

    nonisolated static func isDownloaded(appSupport: URL) -> Bool {
        let root = modelRoot(appSupport: appSupport)
        return artifacts.allSatisfy { artifact in
            let attributes = try? FileManager.default.attributesOfItem(atPath: root.appendingPathComponent(artifact.name).path)
            return (attributes?[.size] as? NSNumber)?.int64Value == artifact.bytes
        }
    }

    private func unload() async {
        guard activeUses == 0, !(await preparation.isRunning) else { return }
        model = nil
        await ModelRuntimeRegistry.shared.unregister(id: Self.runtimeID)
    }

    private nonisolated func report(_ update: ModelPreparationUpdate, to handler: ModelPreparationProgressHandler?) {
        guard let handler else { return }
        Task { @MainActor in handler(update) }
    }
}
