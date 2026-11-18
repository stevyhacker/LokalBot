import AVFoundation
import CoreMedia
import Foundation

#if canImport(Speech)
import Speech
#endif

enum AppleSpeechError: LocalizedError, Equatable, Sendable {
    case unavailable(String)
    case assetDownloadRefusedInUnitTests(String)
    case assetInstallationFailed(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let reason):
            return reason
        case .assetDownloadRefusedInUnitTests(let locale):
            return "Unit tests never download Apple Speech (\(locale))."
        case .assetInstallationFailed(let message):
            return "Could not install Apple Speech language asset: \(message)"
        }
    }
}

/// On-device transcription via Apple's macOS 26+ `SpeechAnalyzer` framework.
///
/// Mirrors `AppleIntelligenceEngine` by keeping macOS 26 `Speech` symbols
/// behind `#if canImport(Speech)` and `@available(macOS 26.0, *)` so the
/// macOS 15.0 deployment target stays intact.
actor AppleSpeechEngine: TranscriptionEngine {
    struct RawUtterance: Equatable, Sendable {
        var start: TimeInterval
        var end: TimeInterval
        var text: String
    }

    struct Backend: Sendable {
        var availabilityError: @Sendable () -> String?
        var resolve: @Sendable (_ language: String?) async throws -> AppleSpeechLocaleResolver.Resolution
        var ensureAsset: @Sendable (
            _ resolution: AppleSpeechLocaleResolver.Resolution,
            _ progress: (@Sendable (Double?, String) -> Void)?
        ) async throws -> Void
        var analyze: @Sendable (
            _ audio: URL,
            _ resolution: AppleSpeechLocaleResolver.Resolution
        ) async throws -> [RawUtterance]

        static var live: Self {
            Self(
                availabilityError: {
                    if #available(macOS 26.0, *) {
                        return AppleSpeechAvailability.state(
                            systemSupported: AppleSpeechAvailability.isSystemSupported,
                            osSupported: true
                        ).reason
                    }
                    return AppleSpeechAvailability.unsupportedMessage
                },
                resolve: { language in
                    #if canImport(Speech)
                    if #available(macOS 26.0, *) {
                        return try await AppleSpeechLocaleResolver.resolveLive(language: language)
                    }
                    #endif
                    throw AppleSpeechError.unavailable(AppleSpeechAvailability.unsupportedMessage)
                },
                ensureAsset: { resolution, progress in
                    #if canImport(Speech)
                    if #available(macOS 26.0, *) {
                        try await AppleSpeechEngine.ensureLiveAsset(
                            resolution: resolution,
                            progress: progress)
                        return
                    }
                    #endif
                    throw AppleSpeechError.unavailable(AppleSpeechAvailability.unsupportedMessage)
                },
                analyze: { audio, resolution in
                    #if canImport(Speech)
                    if #available(macOS 26.0, *) {
                        return try await AppleSpeechEngine.analyzeLiveFile(
                            audio: audio,
                            resolution: resolution)
                    }
                    #endif
                    throw AppleSpeechError.unavailable(AppleSpeechAvailability.unsupportedMessage)
                }
            )
        }
    }

    static let shared = AppleSpeechEngine()

    nonisolated let displayName = AppleSpeechLocaleResolver.modelDisplayName
    nonisolated let checkpointIdentity = "apple-speech"
    nonisolated let supportsStreaming = false

    private let backend: Backend

    init(backend: Backend = .live) {
        self.backend = backend
    }

    func prepare(progress: ModelPreparationProgressHandler? = nil) async throws {
        try await prepare(language: nil, progress: progress)
    }

    func prepare(language: String?, progress: ModelPreparationProgressHandler? = nil) async throws {
        try Task.checkCancellation()
        try AppleSpeechLocaleResolver.validateLanguage(language, modelName: displayName)
        if let reason = backend.availabilityError() {
            throw AppleSpeechError.unavailable(reason)
        }

        Self.report(.init(fractionCompleted: nil, status: "Checking..."), to: progress)
        let resolution = try await backend.resolve(language)
        try Task.checkCancellation()
        try await backend.ensureAsset(resolution) { fraction, status in
            Self.report(.init(fractionCompleted: fraction, status: status), to: progress)
        }
        try Task.checkCancellation()
        Self.report(.init(fractionCompleted: 1.0, status: "Ready"), to: progress)
    }

    func transcribe(audio url: URL, language: String?) async throws -> Transcript {
        try Task.checkCancellation()
        try AppleSpeechLocaleResolver.validateLanguage(language, modelName: displayName)
        if let reason = backend.availabilityError() {
            throw AppleSpeechError.unavailable(reason)
        }

        let resolution = try await backend.resolve(language)
        try Task.checkCancellation()
        try await backend.ensureAsset(resolution, nil)
        try Task.checkCancellation()

        let utterances = try await backend.analyze(url, resolution)
        try Task.checkCancellation()
        return Transcript(
            segments: Self.segments(from: utterances),
            engine: Self.engineLabel(for: resolution))
    }

    nonisolated static func engineLabel(for resolution: AppleSpeechLocaleResolver.Resolution) -> String {
        "\(AppleSpeechLocaleResolver.modelDisplayName) (\(resolution.localeIdentifier))"
    }

    nonisolated static func segments(from utterances: [RawUtterance]) -> [Transcript.Segment] {
        utterances.compactMap { utterance in
            let text = Transcript.normalizedText(utterance.text)
            guard !text.isEmpty,
                  utterance.start.isFinite,
                  utterance.end.isFinite,
                  utterance.end > utterance.start else {
                return nil
            }
            return Transcript.Segment(
                start: max(0, utterance.start),
                end: utterance.end,
                speaker: "speaker",
                text: text,
                confidence: nil,
                timingPrecision: .span)
        }
    }

    nonisolated static func configured(language: String?) -> any TranscriptionEngine {
        ConfiguredAppleSpeechEngine(language: language)
    }

    private nonisolated static func report(
        _ update: ModelPreparationUpdate,
        to handler: ModelPreparationProgressHandler?
    ) {
        guard let handler else { return }
        Task { @MainActor in handler(update) }
    }

    #if canImport(Speech)
    @available(macOS 26.0, *)
    private static func ensureLiveAsset(
        resolution: AppleSpeechLocaleResolver.Resolution,
        progress: (@Sendable (Double?, String) -> Void)?
    ) async throws {
        let module: any SpeechModule = switch resolution.module {
        case .speechTranscriber:
            SpeechTranscriber(
                locale: resolution.locale,
                transcriptionOptions: [],
                reportingOptions: [],
                attributeOptions: [.audioTimeRange])
        case .dictationTranscriber:
            DictationTranscriber(locale: resolution.locale, preset: .timeIndexedLongDictation)
        }

        if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            if UITestRuntime.isUnitTesting {
                do {
                    try UITestRuntime.refuseDownloadInUnitTests(
                        of: "Apple Speech (\(resolution.localeIdentifier))")
                } catch {
                    throw AppleSpeechError.assetDownloadRefusedInUnitTests(resolution.localeIdentifier)
                }
            }
            progress?(0, "Downloading…")
            let progressTask = Task {
                while !Task.isCancelled {
                    let fraction = request.progress.fractionCompleted
                    let clamped = fraction.isFinite ? min(1, max(0, fraction)) : nil
                    progress?(clamped, "Downloading…")
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
            defer { progressTask.cancel() }
            do {
                try await request.downloadAndInstall()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw AppleSpeechError.assetInstallationFailed(error.localizedDescription)
            }
        }
        progress?(1.0, "Ready")
    }

    @available(macOS 26.0, *)
    private static func analyzeLiveFile(
        audio: URL,
        resolution: AppleSpeechLocaleResolver.Resolution
    ) async throws -> [RawUtterance] {
        let file = try AVAudioFile(forReading: audio)
        guard file.length > 0 else { return [] }

        let options = SpeechAnalyzer.Options(priority: .utility, modelRetention: .whileInUse)
        switch resolution.module {
        case .speechTranscriber:
            let module = SpeechTranscriber(
                locale: resolution.locale,
                transcriptionOptions: [],
                reportingOptions: [],
                attributeOptions: [.audioTimeRange])
            let analyzer = SpeechAnalyzer(modules: [module], options: options)
            return try await runAnalyzer(analyzer, file: file) {
                var items: [RawUtterance] = []
                for try await result in module.results {
                    try Task.checkCancellation()
                    guard result.isFinal else { continue }
                    items.append(RawUtterance(
                        start: result.range.start.seconds,
                        end: result.range.end.seconds,
                        text: String(result.text.characters)))
                }
                return items
            }
        case .dictationTranscriber:
            let module = DictationTranscriber(locale: resolution.locale, preset: .timeIndexedLongDictation)
            let analyzer = SpeechAnalyzer(modules: [module], options: options)
            return try await runAnalyzer(analyzer, file: file) {
                var items: [RawUtterance] = []
                for try await result in module.results {
                    try Task.checkCancellation()
                    guard result.isFinal else { continue }
                    items.append(RawUtterance(
                        start: result.range.start.seconds,
                        end: result.range.end.seconds,
                        text: String(result.text.characters)))
                }
                return items
            }
        }
    }

    @available(macOS 26.0, *)
    private static func runAnalyzer(
        _ analyzer: SpeechAnalyzer,
        file: AVAudioFile,
        collectResults: @escaping @Sendable () async throws -> [RawUtterance]
    ) async throws -> [RawUtterance] {
        let readerTask = Task(operation: collectResults)
        return try await withTaskCancellationHandler {
            do {
                if let end = try await analyzer.analyzeSequence(from: file) {
                    try await analyzer.finalizeAndFinish(through: end)
                } else {
                    await analyzer.cancelAndFinishNow()
                }
                return try await readerTask.value
            } catch {
                readerTask.cancel()
                await analyzer.cancelAndFinishNow()
                throw error
            }
        } onCancel: {
            readerTask.cancel()
            Task { await analyzer.cancelAndFinishNow() }
        }
    }
    #endif
}

private struct ConfiguredAppleSpeechEngine: TranscriptionEngine {
    let language: String?

    var displayName: String { AppleSpeechEngine.shared.displayName }
    var checkpointIdentity: String { AppleSpeechEngine.shared.checkpointIdentity }
    let supportsStreaming = false

    func prepare(progress: ModelPreparationProgressHandler?) async throws {
        try await AppleSpeechEngine.shared.prepare(language: language, progress: progress)
    }

    func transcribe(audio: URL, language: String?) async throws -> Transcript {
        try await AppleSpeechEngine.shared.transcribe(audio: audio, language: language ?? self.language)
    }
}
