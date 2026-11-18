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

enum AppleSpeechVocabulary {
    static let maxContextualPhrases = 100

    /// Parses comma-, semicolon-, middot-, or newline-separated vocabulary hints
    /// into deduplicated phrases capped at Apple Speech's 100-phrase limit.
    static func contextualStrings(from prompt: String?) -> [String] {
        guard let normalized = TranscriptionPrompt.normalized(prompt) else { return [] }
        let separators = CharacterSet(charactersIn: ",;·").union(.newlines)
        var seen = Set<String>()
        var phrases: [String] = []
        for component in normalized.components(separatedBy: separators) {
            let trimmed = component
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            guard !trimmed.isEmpty else { continue }
            let key = trimmed.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            guard seen.insert(key).inserted else { continue }
            phrases.append(trimmed)
            if phrases.count == maxContextualPhrases { break }
        }
        return phrases
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
        var words: [AlignedWordTiming] = []
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
            _ resolution: AppleSpeechLocaleResolver.Resolution,
            _ contextualStrings: [String]
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
                analyze: { audio, resolution, contextualStrings in
                    #if canImport(Speech)
                    if #available(macOS 26.0, *) {
                        return try await AppleSpeechEngine.analyzeLiveFile(
                            audio: audio,
                            resolution: resolution,
                            contextualStrings: contextualStrings)
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
    nonisolated let speakerAttribution: SpeakerAttributionStrategy = .alignedWords
    nonisolated let providesWordTimings = true

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
        try await transcribe(audio: url, language: language, prompt: nil)
    }

    func transcribe(audio url: URL, language: String?, prompt: String?) async throws -> Transcript {
        try await transcribeForWordAttribution(audio: url, language: language, prompt: prompt).transcript
    }

    func transcribeForWordAttribution(
        audio url: URL,
        language: String?,
        prompt: String?
    ) async throws -> WordTimedTranscript {
        try Task.checkCancellation()
        try AppleSpeechLocaleResolver.validateLanguage(language, modelName: displayName)
        if let reason = backend.availabilityError() {
            throw AppleSpeechError.unavailable(reason)
        }

        let resolution = try await backend.resolve(language)
        try Task.checkCancellation()
        try await backend.ensureAsset(resolution, nil)
        try Task.checkCancellation()

        let contextualStrings = AppleSpeechVocabulary.contextualStrings(from: prompt)
        let utterances = try await backend.analyze(url, resolution, contextualStrings)
        try Task.checkCancellation()
        var segments = Self.buildTimedSegments(from: utterances)
        if let echo = TranscriptionPromptEcho(prompt: prompt) {
            let originalCount = segments.count
            segments = segments.filter { !echo.matches($0.segment.displayText) }
            if segments.count < originalCount {
                lokalbotLog("apple-speech: dropped \(originalCount - segments.count) row(s) echoing the vocabulary prompt")
            }
        }
        return WordTimedTranscript(
            segments: segments,
            engine: Self.engineLabel(for: resolution),
            trackLanguage: resolution.languageCode)
    }

    nonisolated static func engineLabel(for resolution: AppleSpeechLocaleResolver.Resolution) -> String {
        "\(AppleSpeechLocaleResolver.modelDisplayName) (\(resolution.localeIdentifier))"
    }

    #if canImport(Speech)
    @available(macOS 26.0, *)
    nonisolated static func extractWordTimings(from attributed: AttributedString) -> [AlignedWordTiming] {
        var words: [AlignedWordTiming] = []
        for run in attributed.runs {
            let chunk = String(attributed[run.range].characters)
            let tokens = chunk.split(whereSeparator: \.isWhitespace).map(String.init)
            guard !tokens.isEmpty else { continue }
            for token in tokens {
                let core = token.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
                guard !core.isEmpty else {
                    if !words.isEmpty {
                        words[words.count - 1].text += token
                    }
                    continue
                }
                guard let range = run.audioTimeRange else { continue }
                let start = range.start.seconds
                let end = range.end.seconds
                guard start.isFinite, end.isFinite, end > start else { continue }
                words.append(AlignedWordTiming(
                    text: token,
                    start: max(0, start),
                    end: end))
            }
        }
        return words
    }
    #endif

    nonisolated static func buildTimedSegments(
        from utterances: [RawUtterance],
        maxPause: TimeInterval = AttributedTrackTranscriber.wordPauseSplit,
        maxDuration: TimeInterval = AttributedTrackTranscriber.maxSegmentSeconds
    ) -> [WordTimedTranscript.Segment] {
        var result: [WordTimedTranscript.Segment] = []
        for utterance in utterances {
            let normalized = Transcript.normalizedText(utterance.text)
            guard !normalized.isEmpty else { continue }

            let validWords = utterance.words.filter { word in
                let core = word.text.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
                return !core.isEmpty && word.start.isFinite && word.end.isFinite && word.end > word.start
            }
            guard !validWords.isEmpty else {
                guard utterance.start.isFinite, utterance.end.isFinite, utterance.end > utterance.start else {
                    continue
                }
                result.append(WordTimedTranscript.Segment(
                    segment: Transcript.Segment(
                        start: max(0, utterance.start),
                        end: utterance.end,
                        speaker: "speaker",
                        text: normalized,
                        confidence: nil,
                        timingPrecision: .span),
                    words: nil))
                continue
            }

            let allStarts = AttributedTrackTranscriber.wordStarts(
                validWords.map(\.text),
                in: normalized)

            var chunkStartIndex = 0
            while chunkStartIndex < validWords.count {
                var chunkEndIndex = chunkStartIndex + 1
                let chunkStartTime = validWords[chunkStartIndex].start
                while chunkEndIndex < validWords.count {
                    let previous = validWords[chunkEndIndex - 1]
                    let next = validWords[chunkEndIndex]
                    if next.start - previous.end >= maxPause || next.end - chunkStartTime > maxDuration {
                        break
                    }
                    chunkEndIndex += 1
                }

                let chunkWords = Array(validWords[chunkStartIndex..<chunkEndIndex])
                let text = chunkText(
                    original: normalized,
                    allStarts: allStarts,
                    chunkRange: chunkStartIndex..<chunkEndIndex,
                    totalWords: validWords.count,
                    chunkWords: chunkWords)
                if !text.isEmpty, let first = chunkWords.first, let last = chunkWords.last {
                    let start = max(0, first.start)
                    let end = max(start, last.end)
                    if end > start {
                        result.append(WordTimedTranscript.Segment(
                            segment: Transcript.Segment(
                                start: start,
                                end: end,
                                speaker: "speaker",
                                text: text,
                                confidence: nil,
                                timingPrecision: .token),
                            words: chunkWords))
                    }
                }
                chunkStartIndex = chunkEndIndex
            }
        }
        return result
    }

    private nonisolated static func chunkText(
        original: String,
        allStarts: [String.Index]?,
        chunkRange: Range<Int>,
        totalWords: Int,
        chunkWords: [AlignedWordTiming]
    ) -> String {
        if let allStarts, allStarts.count == totalWords {
            let startIdx = chunkRange.lowerBound == 0 ? original.startIndex : allStarts[chunkRange.lowerBound]
            let endIdx = chunkRange.upperBound < totalWords ? allStarts[chunkRange.upperBound] : original.endIndex
            if startIdx <= endIdx {
                let sliced = Transcript.normalizedText(String(original[startIdx..<endIdx]))
                if !sliced.isEmpty,
                   AttributedTrackTranscriber.wordStarts(chunkWords.map(\.text), in: sliced) != nil {
                    return sliced
                }
            }
        }
        return Transcript.normalizedText(chunkWords.map(\.text).joined(separator: " "))
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

        let currentStatus = await AssetInventory.status(forModules: [module])
        if currentStatus == .installed {
            progress?(1.0, "Ready")
            return
        }

        if UITestRuntime.isUnitTesting {
            do {
                try UITestRuntime.refuseDownloadInUnitTests(
                    of: "Apple Speech (\(resolution.localeIdentifier))")
            } catch {
                throw AppleSpeechError.assetDownloadRefusedInUnitTests(resolution.localeIdentifier)
            }
        }

        try await reserveLocaleIfNeeded(resolution.locale)

        if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            let statusLabel = "Downloading \(resolution.localeIdentifier)…"
            progress?(0, statusLabel)
            let progressTask = Task {
                while !Task.isCancelled {
                    let fraction = request.progress.fractionCompleted
                    let clamped = fraction.isFinite ? min(1, max(0, fraction)) : nil
                    progress?(clamped, statusLabel)
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
    private static func reserveLocaleIfNeeded(_ locale: Locale) async throws {
        let targetKey = normalizedReservationKey(locale.identifier)
        let reserved = await AssetInventory.reservedLocales
        guard !reserved.contains(where: { normalizedReservationKey($0.identifier) == targetKey }) else {
            return
        }
        let maxReserved = AssetInventory.maximumReservedLocales
        if maxReserved > 0, reserved.count >= maxReserved, let oldest = reserved.first {
            _ = await AssetInventory.release(reservedLocale: oldest)
        }
        do {
            try await AssetInventory.reserve(locale: locale)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw AppleSpeechError.assetInstallationFailed(error.localizedDescription)
        }
    }

    private nonisolated static func normalizedReservationKey(_ identifier: String) -> String {
        identifier.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "_")
            .lowercased()
    }

    @available(macOS 26.0, *)
    private static func analyzeLiveFile(
        audio: URL,
        resolution: AppleSpeechLocaleResolver.Resolution,
        contextualStrings: [String]
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
            return try await runAnalyzer(analyzer, file: file, contextualStrings: contextualStrings) {
                var items: [RawUtterance] = []
                for try await result in module.results {
                    try Task.checkCancellation()
                    guard result.isFinal else { continue }
                    items.append(RawUtterance(
                        start: result.range.start.seconds,
                        end: result.range.end.seconds,
                        text: String(result.text.characters),
                        words: extractWordTimings(from: result.text)))
                }
                return items
            }
        case .dictationTranscriber:
            let module = DictationTranscriber(locale: resolution.locale, preset: .timeIndexedLongDictation)
            let analyzer = SpeechAnalyzer(modules: [module], options: options)
            return try await runAnalyzer(analyzer, file: file, contextualStrings: contextualStrings) {
                var items: [RawUtterance] = []
                for try await result in module.results {
                    try Task.checkCancellation()
                    guard result.isFinal else { continue }
                    items.append(RawUtterance(
                        start: result.range.start.seconds,
                        end: result.range.end.seconds,
                        text: String(result.text.characters),
                        words: extractWordTimings(from: result.text)))
                }
                return items
            }
        }
    }

    @available(macOS 26.0, *)
    private static func runAnalyzer(
        _ analyzer: SpeechAnalyzer,
        file: AVAudioFile,
        contextualStrings: [String],
        collectResults: @escaping @Sendable () async throws -> [RawUtterance]
    ) async throws -> [RawUtterance] {
        if !contextualStrings.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings[.general] = contextualStrings
            try await analyzer.setContext(context)
        }
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
    var speakerAttribution: SpeakerAttributionStrategy { AppleSpeechEngine.shared.speakerAttribution }
    var providesWordTimings: Bool { AppleSpeechEngine.shared.providesWordTimings }

    func prepare(progress: ModelPreparationProgressHandler?) async throws {
        try await AppleSpeechEngine.shared.prepare(language: language, progress: progress)
    }

    func transcribe(audio: URL, language: String?) async throws -> Transcript {
        try await AppleSpeechEngine.shared.transcribe(audio: audio, language: language ?? self.language)
    }

    func transcribe(audio: URL, language: String?, prompt: String?) async throws -> Transcript {
        try await AppleSpeechEngine.shared.transcribe(
            audio: audio,
            language: language ?? self.language,
            prompt: prompt)
    }

    func transcribeForWordAttribution(
        audio: URL,
        language: String?,
        prompt: String?
    ) async throws -> WordTimedTranscript {
        try await AppleSpeechEngine.shared.transcribeForWordAttribution(
            audio: audio,
            language: language ?? self.language,
            prompt: prompt)
    }
}
