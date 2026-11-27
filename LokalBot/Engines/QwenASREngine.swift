import Foundation
import FluidAudio

actor QwenASREngine: TranscriptionEngine {
    enum Variant: Sendable {
        case accuracyLokalBotV3
        case accuracy
        case compactLokalBotV1
        case compact

        var weights: QwenLlamaASR.Weights {
            switch self {
            case .accuracyLokalBotV3: QwenLlamaASR.accuracyLokalBotV3
            case .accuracy: QwenLlamaASR.accuracy
            case .compactLokalBotV1: QwenLlamaASR.compactLokalBotV1
            case .compact: QwenLlamaASR.compact
            }
        }

        var displayName: String {
            switch self {
            case .accuracyLokalBotV3: "Qwen3-ASR 1.7B (LokalBot v3)"
            case .accuracy: "Qwen3-ASR 1.7B"
            case .compactLokalBotV1: "Qwen3-ASR 0.6B (LokalBot v1)"
            case .compact: "Qwen3-ASR 0.6B"
            }
        }

        var choice: TranscriptionModelChoice {
            switch self {
            case .accuracyLokalBotV3: .qwenASR17BLokalBotV3
            case .accuracy: .qwenASR17B
            case .compactLokalBotV1: .qwenASR06BLokalBotV1
            case .compact: .qwenASR06B
            }
        }

        var modelID: String { "\(weights.repository):\(weights.model.name)" }
    }

    protocol ManagedServer: AnyObject, Sendable {
        func ensureRunning(modelAt url: URL) async throws
        func stop() async
    }

    struct ServerPaths: Equatable, Sendable {
        let model: URL
        let projector: URL
    }

    struct ServerLease<Server: ManagedServer>: Sendable {
        let server: Server
        fileprivate let generation: UInt64
    }

    enum PreparationOutcome: Equatable, Sendable {
        case ready
        case deferredUntilIdle
    }

    actor TierRuntime<Server: ManagedServer> {
        typealias FilePreparer = @Sendable (
            QwenLlamaASR.Weights, ModelPreparationProgressHandler?
        ) async throws -> ServerPaths
        typealias ServerFactory = @Sendable (QwenLlamaASR.Weights, URL) -> Server

        private struct ServerReservation {
            let server: Server
            let generation: UInt64
        }

        private let prepareFiles: FilePreparer
        private let makeServer: ServerFactory
        private let idleSeconds: TimeInterval

        private var server: Server?
        private var serverPaths: ServerPaths?
        private var serverGeneration: UInt64 = 0
        private var activeUses = 0
        private var activeLeaseUses = 0
        private var activeStartupUses = 0
        private var isReplacingServer = false
        private var pendingDeferredResetGeneration: UInt64?
        private var filePreparations: [String: AsyncSingleFlight] = [:]
        private var preparedPaths: [String: ServerPaths] = [:]
        private var stateWaiters: [UUID: CheckedContinuation<Void, Error>] = [:]
        private lazy var idle = IdleTimer(seconds: idleSeconds) { [weak self] in await self?.unload() }

        init(
            idleSeconds: TimeInterval = 120,
            prepareFiles: @escaping FilePreparer,
            makeServer: @escaping ServerFactory
        ) {
            self.idleSeconds = idleSeconds
            self.prepareFiles = prepareFiles
            self.makeServer = makeServer
        }

        @discardableResult
        func prepare(
            weights: QwenLlamaASR.Weights,
            progress: ModelPreparationProgressHandler? = nil
        ) async throws -> PreparationOutcome {
            try Task.checkCancellation()
            activeUses += 1
            defer { finishUse() }
            report(.init(fractionCompleted: 0, status: "Checking..."), to: progress)
            let paths = try await ensureFiles(for: weights, progress: progress)
            try Task.checkCancellation()
            guard let reservation = try await reserveServer(
                weights: weights, paths: paths, waitIfBusy: false
            ) else {
                report(
                    .init(
                        fractionCompleted: 1,
                        status: "Downloaded; will load after current transcription"),
                    to: progress)
                return .deferredUntilIdle
            }
            report(.init(fractionCompleted: nil, status: "Starting local server..."), to: progress)
            do {
                try await reservation.server.ensureRunning(modelAt: paths.model)
                try Task.checkCancellation()
            } catch {
                releaseStartup(generation: reservation.generation)
                throw error
            }
            let stillCurrent = reservation.generation == serverGeneration && server === reservation.server
            releaseStartup(generation: reservation.generation)
            guard stillCurrent else { throw EngineError.notLoaded }
            report(.init(fractionCompleted: 1, status: "Ready"), to: progress)
            return .ready
        }

        func acquireServer(weights: QwenLlamaASR.Weights) async throws -> ServerLease<Server> {
            try Task.checkCancellation()
            activeUses += 1
            do {
                let paths = try await ensureFiles(for: weights, progress: nil)
                try Task.checkCancellation()
                guard let reservation = try await reserveServer(
                    weights: weights, paths: paths, waitIfBusy: true
                ) else {
                    throw EngineError.notLoaded
                }
                do {
                    try await reservation.server.ensureRunning(modelAt: paths.model)
                    try Task.checkCancellation()
                } catch {
                    releaseStartup(generation: reservation.generation)
                    throw error
                }
                guard promoteStartupToLease(
                    generation: reservation.generation, expectedServer: reservation.server
                ) else {
                    throw EngineError.notLoaded
                }
                return ServerLease(server: reservation.server, generation: reservation.generation)
            } catch {
                finishUse()
                throw error
            }
        }

        func releaseServer(_ lease: ServerLease<Server>) {
            if lease.generation == serverGeneration, activeLeaseUses > 0 {
                activeLeaseUses -= 1
                finishServerActivity(for: lease.generation)
            }
            finishUse()
        }

        func shutdown() async {
            pendingDeferredResetGeneration = nil
            while isReplacingServer {
                do {
                    try await waitForStateChange()
                } catch {
                    return
                }
            }
            await stopCurrentServer()
        }

        private func ensureFiles(
            for weights: QwenLlamaASR.Weights,
            progress: ModelPreparationProgressHandler?
        ) async throws -> ServerPaths {
            let key = weightsKey(weights)
            let flight: AsyncSingleFlight
            if let existing = filePreparations[key] {
                flight = existing
            } else {
                let created = AsyncSingleFlight()
                filePreparations[key] = created
                flight = created
            }
            try await flight.run { [weak self, prepareFiles] in
                let paths = try await prepareFiles(weights, progress)
                guard let self else { throw CancellationError() }
                await self.recordPreparedPaths(paths, for: key)
            }
            if let paths = preparedPaths[key] {
                return paths
            }
            let paths = try await prepareFiles(weights, progress)
            preparedPaths[key] = paths
            return paths
        }

        private func recordPreparedPaths(_ paths: ServerPaths, for key: String) {
            preparedPaths[key] = paths
        }

        private func weightsKey(_ weights: QwenLlamaASR.Weights) -> String {
            "\(weights.repository):\(weights.model.name)"
        }

        private func reserveServer(
            weights: QwenLlamaASR.Weights,
            paths: ServerPaths,
            waitIfBusy: Bool
        ) async throws -> ServerReservation? {
            while true {
                try Task.checkCancellation()
                if isReplacingServer {
                    try await waitForStateChange()
                    continue
                }
                let busyCount = waitIfBusy ? (activeLeaseUses + activeStartupUses) : activeLeaseUses
                switch QwenASREngine.serverTransition(
                    hasServer: server != nil,
                    loadedModelPath: serverPaths?.model.path,
                    loadedProjectorPath: serverPaths?.projector.path,
                    nextModelPath: paths.model.path,
                    nextProjectorPath: paths.projector.path,
                    activeServerUses: busyCount
                ) {
                case .deferReplacement:
                    if waitIfBusy {
                        try await waitForStateChange()
                        continue
                    }
                    pendingDeferredResetGeneration = serverGeneration
                    return nil
                case .replaceNow:
                    if activeStartupUses > 0 {
                        try await waitForStateChange()
                        continue
                    }
                    await stopCurrentServer()
                    continue
                case .reuse:
                    let reservedServer: Server
                    let reservedGeneration: UInt64
                    if let existing = server {
                        reservedServer = existing
                        reservedGeneration = serverGeneration
                        if !waitIfBusy {
                            pendingDeferredResetGeneration = nil
                        }
                    } else {
                        reservedServer = makeServer(weights, paths.projector)
                        serverGeneration &+= 1
                        reservedGeneration = serverGeneration
                        server = reservedServer
                        serverPaths = paths
                        pendingDeferredResetGeneration = nil
                    }
                    activeStartupUses += 1
                    return ServerReservation(server: reservedServer, generation: reservedGeneration)
                }
            }
        }

        private func promoteStartupToLease(generation: UInt64, expectedServer: Server) -> Bool {
            guard generation == serverGeneration, server === expectedServer, activeStartupUses > 0 else {
                return false
            }
            activeStartupUses -= 1
            activeLeaseUses += 1
            if activeStartupUses == 0 {
                wakeWaiters()
            }
            return true
        }

        private func releaseStartup(generation: UInt64) {
            guard generation == serverGeneration, activeStartupUses > 0 else { return }
            activeStartupUses -= 1
            finishServerActivity(for: generation)
        }

        private func finishServerActivity(for generation: UInt64) {
            if activeStartupUses == 0 {
                wakeWaiters()
            }
            guard activeLeaseUses == 0, activeStartupUses == 0 else { return }
            if pendingDeferredResetGeneration == serverGeneration, serverGeneration == generation {
                pendingDeferredResetGeneration = nil
                Task { await self.resetDeferredServer(generation: generation) }
            }
        }

        private func waitForStateChange() async throws {
            try Task.checkCancellation()
            let id = UUID()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    guard !Task.isCancelled else {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    stateWaiters[id] = continuation
                }
            } onCancel: {
                Task { await self.cancelWaiter(id) }
            }
            try Task.checkCancellation()
        }

        private func cancelWaiter(_ id: UUID) {
            guard let waiter = stateWaiters.removeValue(forKey: id) else { return }
            waiter.resume(throwing: CancellationError())
        }

        private func wakeWaiters() {
            let waiters = stateWaiters.values
            stateWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }

        private func unload() async {
            guard activeUses == 0,
                  activeLeaseUses == 0,
                  activeStartupUses == 0,
                  !isReplacingServer else { return }
            for flight in filePreparations.values where await flight.isRunning {
                return
            }
            guard activeUses == 0,
                  activeLeaseUses == 0,
                  activeStartupUses == 0,
                  !isReplacingServer else { return }
            await stopCurrentServer()
        }

        private func finishUse() {
            activeUses -= 1
            guard activeUses == 0 else { return }
            Task { await idle.bump() }
        }

        private func resetDeferredServer(generation: UInt64) async {
            guard serverGeneration == generation, server != nil, !isReplacingServer else { return }
            guard activeLeaseUses == 0, activeStartupUses == 0 else {
                pendingDeferredResetGeneration = generation
                return
            }
            await stopCurrentServer()
        }

        private func stopCurrentServer() async {
            guard let existing = server else { return }
            isReplacingServer = true
            server = nil
            serverPaths = nil
            pendingDeferredResetGeneration = nil
            serverGeneration &+= 1
            activeLeaseUses = 0
            activeStartupUses = 0
            await existing.stop()
            isReplacingServer = false
            wakeWaiters()
        }

        private nonisolated func report(_ update: ModelPreparationUpdate,
                                        to handler: ModelPreparationProgressHandler?) {
            guard let handler else { return }
            Task { @MainActor in handler(update) }
        }
    }

    private static let accuracyRuntime = TierRuntime<LlamaServer>.live()
    private static let compactRuntime = TierRuntime<LlamaServer>.live()

    static let accuracyLokalBotV3 = QwenASREngine(variant: .accuracyLokalBotV3, runtime: accuracyRuntime)
    static let accuracy = QwenASREngine(variant: .accuracy, runtime: accuracyRuntime)
    static let compactLokalBotV1 = QwenASREngine(variant: .compactLokalBotV1, runtime: compactRuntime)
    static let compact = QwenASREngine(variant: .compact, runtime: compactRuntime)

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
        case .accuracyLokalBotV3, .accuracy: .init(maxSeconds: QwenWordAligner.maxSegmentSeconds, maxGapSeconds: 5)
        case .compactLokalBotV1, .compact: .init(maxSeconds: 15, maxGapSeconds: 5)
        }
    }

    enum ServerTransition: Equatable, Sendable {
        case reuse
        case replaceNow
        case deferReplacement
    }

    nonisolated static func serverTransition(
        hasServer: Bool,
        loadedModelPath: String?,
        loadedProjectorPath: String?,
        nextModelPath: String,
        nextProjectorPath: String,
        activeServerUses: Int
    ) -> ServerTransition {
        guard hasServer,
              loadedModelPath != nextModelPath || loadedProjectorPath != nextProjectorPath else {
            return .reuse
        }
        return activeServerUses > 0 ? .deferReplacement : .replaceNow
    }

    private let variant: Variant
    private let runtime: TierRuntime<LlamaServer>

    private init(variant: Variant, runtime: TierRuntime<LlamaServer>) {
        self.variant = variant
        self.runtime = runtime
    }

    func prepare(progress: ModelPreparationProgressHandler? = nil) async throws {
        _ = try await runtime.prepare(weights: variant.weights, progress: progress)
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
        try variant.choice.validateLanguage(language)
        let pin = await ModelResidency.shared.pin(id: variant.weights.role.residencyID)
        defer { Task { @MainActor in ModelResidency.shared.unpin(pin) } }
        let lease = try await runtime.acquireServer(weights: variant.weights)
        defer { Task { await runtime.releaseServer(lease) } }

        let started = Date()
        var spans = try await SpeechActivity.shared.spans(
            in: url, maxSegmentSeconds: Self.maxSegmentSeconds)
        if let windows {
            spans = Self.merged(spans, maxGap: windows.maxGapSeconds, maxLength: windows.maxSeconds)
        }
        let server = lease.server
        let decode: SpanDecoder = { batch, qwenLanguage in
            let segments = try await SpanTranscription.segments(
                in: url, spans: batch, maxConcurrent: QwenLlamaASR.maxConcurrentWindows
            ) { samples, _ in
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

    static let sampleKeptShare = 0.5

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
        let chosen = Set(sample)
        let unsampled = spans.indices.filter { !chosen.contains($0) }.map { spans[$0] }
        func agrees(_ segments: [Transcript.Segment], on vote: String) -> Bool {
            !TranscriptLanguageVote.serbianCroatianAliases.values.contains(vote)
                && TranscriptLanguageVote.unanimous(segments.map(\.text), code: vote)
        }
        if sample.count < spans.count, let vote = pinnedLanguage(for: sampled.map(\.text), minimumShare: sampleShare) {
            let aligns = !wordAttribution || QwenWordAligner.supports(vote)
            guard aligns, Double(sample.count) >= sampleKeptShare * Double(spans.count),
                  agrees(sampled, on: vote) else {
                return try await pinned(vote, segments: [], twice: false)
            }
            let rest = try await decode(unsampled, vote)
            return AutoLanguageDecision(segments: (sampled + rest).sorted { $0.start < $1.start }, pinned: vote,
                                        sampled: sample.count, decodedTwice: false, needsSpeakerRegions: false)
        }
        let rest = unsampled.isEmpty ? [] : try await decode(unsampled, nil)
        let all = (sampled + rest).sorted { $0.start < $1.start }
        guard let vote = pinnedLanguage(for: all.map(\.text)) else {
            return AutoLanguageDecision(segments: all, pinned: nil, sampled: sample.count,
                                        decodedTwice: false, needsSpeakerRegions: false)
        }
        if sample.count == spans.count, agrees(all, on: vote) {
            return AutoLanguageDecision(segments: all, pinned: vote, sampled: sample.count, decodedTwice: false,
                                        needsSpeakerRegions: wordAttribution && !QwenWordAligner.supports(vote))
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
        await runtime.shutdown()
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

extension QwenASREngine.TierRuntime where Server == LlamaServer {
    static func live() -> QwenASREngine.TierRuntime<LlamaServer> {
        QwenASREngine.TierRuntime<LlamaServer>(
            prepareFiles: { weights, progress in
                let paths = try await weights.prepareFiles(
                    appSupport: AppDirectories.applicationSupport,
                    progress: progress)
                return QwenASREngine.ServerPaths(model: paths.model, projector: paths.projector)
            },
            makeServer: { weights, projector in
                weights.makeServer(projector: projector)
            }
        )
    }
}

extension LlamaServer: QwenASREngine.ManagedServer {}
