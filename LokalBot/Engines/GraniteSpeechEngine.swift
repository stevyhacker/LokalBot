import Foundation
import FluidAudio

/// IBM Granite Speech 4.1 2B through the bundled llama.cpp server. The model is
/// local-only: first use downloads the GGUF model and multimodal projector from
/// Hugging Face, then LokalBot talks to llama-server's OpenAI-compatible audio
/// transcription endpoint on localhost.
actor GraniteSpeechEngine: TranscriptionEngine {
    static let shared = GraniteSpeechEngine()

    nonisolated let displayName = "Granite Speech 4.1 2B"
    nonisolated let supportsStreaming = false

    nonisolated static let modelFileName =
        GraniteSpeechModelConfiguration.defaultModel.localModelFileName
    private static let prompt = "transcribe the speech with proper punctuation and capitalization."
    private static let maxSegmentSeconds = 30.0
    private static let serverPort = 17_875

    private var server: LlamaServer?
    private let preparation = AsyncSingleFlight()
    private var activeConfiguration = GraniteSpeechModelConfiguration.defaultModel
    private var configurationUses = 0
    private var isSwitchingConfiguration = false
    private var configurationWaiters: [CheckedContinuation<Void, Never>] = []
    private lazy var idle = IdleTimer(seconds: 120) { [weak self] in await self?.stop() }

    func prepare(progress: ModelPreparationProgressHandler? = nil) async throws {
        try await prepare(
            configuration: .defaultModel,
            progress: progress)
    }

    func prepare(configuration: GraniteSpeechModelConfiguration,
                 progress: ModelPreparationProgressHandler? = nil) async throws {
        let pin = await ModelResidency.shared.pin(id: "llama-server:\(Self.serverPort)")
        defer { Task { @MainActor in ModelResidency.shared.unpin(pin) } }
        await acquire(configuration)
        defer { releaseConfigurationUse() }
        try await prepareCurrentConfiguration(
            configuration,
            progress: progress)
    }

    private func prepareCurrentConfiguration(
        _ configuration: GraniteSpeechModelConfiguration,
        progress: ModelPreparationProgressHandler?
    ) async throws {
        report(.init(fractionCompleted: nil, status: "Checking..."), to: progress)
        try await preparation.run { [weak self] in
            guard let self else { return }
            try await self.performPreparation(
                configuration: configuration,
                progress: progress)
        }
        report(.init(fractionCompleted: 1, status: "Ready"), to: progress)
    }

    func shutdown() async {
        await server?.stop()
        server = nil
    }

    private func performPreparation(
        configuration: GraniteSpeechModelConfiguration,
        progress: ModelPreparationProgressHandler?
    ) async throws {
        let paths = try await preparedPaths(
            configuration: configuration,
            progress: progress)
        report(.init(fractionCompleted: nil, status: "Starting local server..."), to: progress)
        try await server(for: paths).ensureRunning(modelAt: paths.model)
    }

    func transcribe(audio url: URL, language: String?) async throws -> Transcript {
        try await transcribe(
            configuration: .defaultModel,
            audio: url,
            language: language)
    }

    func transcribe(configuration: GraniteSpeechModelConfiguration,
                    audio url: URL, language: String?) async throws -> Transcript {
        let pin = await ModelResidency.shared.pin(id: "llama-server:\(Self.serverPort)")
        defer { Task { @MainActor in ModelResidency.shared.unpin(pin) } }
        await acquire(configuration)
        defer { releaseConfigurationUse() }
        try await prepareCurrentConfiguration(configuration, progress: nil)
        let started = Date()
        let regions = try await SpeechActivity.shared.spans(
            in: url, maxSegmentSeconds: Self.maxSegmentSeconds)
        let work = try Self.makeWorkDir()
        defer { try? FileManager.default.removeItem(at: work) }

        let segments = try await SpanTranscription.segments(in: url, spans: regions) { samples, index in
            let wav = work.appendingPathComponent("\(index).wav")
            try OnnxTranscriptionEngine.writeWav(samples, to: wav)
            return try await self.transcribeWav(
                wav,
                modelFileName: configuration.localModelFileName,
                language: language)
        }

        let elapsed = Date().timeIntervalSince(started)
        let duration = regions.last?.end ?? 0
        lokalbotLog(
            "granite-asr profile regions=\(regions.count) elapsed=\(String(format: "%.2fs", elapsed)) rtfx=\(String(format: "%.1fx", elapsed > 0 ? duration / elapsed : 0))")
        return Transcript(
            segments: segments,
            engine: "\(configuration.repository):\(configuration.model.path) (llama.cpp)")
    }

    private func server(for paths: PreparedPaths) -> LlamaServer {
        if let server { return server }
        let instance = LlamaServer(
            port: Self.serverPort,
            contextTokens: 4_096,
            extraArgs: ["--mmproj", paths.projector.path,
                        "--parallel", "1", "--cache-ram", "256"],
            runtimeAllowanceBytes: 768 * 1_048_576)
        server = instance
        return instance
    }

    private func stop() async {
        guard configurationUses == 0, !(await preparation.isRunning) else { return }
        await shutdown()
    }

    private func acquire(_ requested: GraniteSpeechModelConfiguration) async {
        while isSwitchingConfiguration
                || (configurationUses > 0 && activeConfiguration != requested) {
            await withCheckedContinuation { continuation in
                configurationWaiters.append(continuation)
            }
        }

        if activeConfiguration != requested {
            isSwitchingConfiguration = true
            let previousServer = server
            server = nil
            await previousServer?.stop()
            activeConfiguration = requested
            isSwitchingConfiguration = false
            resumeConfigurationWaiters()
        }
        configurationUses += 1
    }

    private func releaseConfigurationUse() {
        configurationUses = max(0, configurationUses - 1)
        if configurationUses == 0 { resumeConfigurationWaiters() }
        // Recording-time prewarm must not pin Granite for an entire meeting.
        // Actual transcription refreshes the same two-minute idle window.
        Task { await idle.bump() }
    }

    private func resumeConfigurationWaiters() {
        let waiters = configurationWaiters
        configurationWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    private nonisolated func report(_ update: ModelPreparationUpdate,
                                    to handler: ModelPreparationProgressHandler?) {
        guard let handler else { return }
        Task { @MainActor in handler(update) }
    }

    // MARK: - Download / paths

    struct PreparedPaths: Sendable {
        let model: URL
        let projector: URL
    }

    private nonisolated static var appSupport: URL { AppDirectories.applicationSupport }

    nonisolated static func modelRoot() -> URL {
        modelRoot(appSupport: appSupport)
    }

    nonisolated static func modelRoot(appSupport: URL) -> URL {
        modelRoot(
            configuration: .defaultModel,
            appSupport: appSupport)
    }

    nonisolated static func modelRoot(
        configuration: GraniteSpeechModelConfiguration,
        appSupport: URL
    ) -> URL {
        let base = appSupport.appendingPathComponent("granite-speech", isDirectory: true)
        if let cacheDirectoryName = configuration.cacheDirectoryName {
            return base
                .appendingPathComponent("custom", isDirectory: true)
                .appendingPathComponent(cacheDirectoryName, isDirectory: true)
        }
        return base.appendingPathComponent("4.1-2b", isDirectory: true)
    }

    nonisolated static func modelURL() -> URL {
        modelURL(appSupport: appSupport)
    }

    nonisolated static func modelURL(appSupport: URL) -> URL {
        modelURL(
            configuration: .defaultModel,
            appSupport: appSupport)
    }

    nonisolated static func modelURL(
        configuration: GraniteSpeechModelConfiguration,
        appSupport: URL
    ) -> URL {
        modelRoot(configuration: configuration, appSupport: appSupport)
            .appendingPathComponent(configuration.localModelFileName)
    }

    nonisolated static func projectorURL() -> URL {
        projectorURL(appSupport: appSupport)
    }

    nonisolated static func projectorURL(appSupport: URL) -> URL {
        projectorURL(
            configuration: .defaultModel,
            appSupport: appSupport)
    }

    nonisolated static func projectorURL(
        configuration: GraniteSpeechModelConfiguration,
        appSupport: URL
    ) -> URL {
        modelRoot(configuration: configuration, appSupport: appSupport)
            .appendingPathComponent(configuration.localProjectorFileName)
    }

    private nonisolated func preparedPaths(
        configuration: GraniteSpeechModelConfiguration,
        progress: ModelPreparationProgressHandler?
    ) async throws -> PreparedPaths {
        let root = Self.modelRoot(
            configuration: configuration,
            appSupport: Self.appSupport)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let model = Self.modelURL(
            configuration: configuration,
            appSupport: Self.appSupport)
        guard let modelDownloadURL = configuration.downloadURL(for: configuration.model) else {
            throw EngineError.modelUnavailable
        }
        try await Self.downloadIfNeeded(
            source: modelDownloadURL,
            destination: model,
            expectedBytes: configuration.model.sizeBytes,
            expectedSHA256: configuration.model.sha256,
            status: "Downloading Granite \(configuration.quantization) model...",
            progress: progress)

        let projector = Self.projectorURL(
            configuration: configuration,
            appSupport: Self.appSupport)
        guard let projectorDownloadURL = configuration.downloadURL(
            for: configuration.projector) else {
            throw EngineError.modelUnavailable
        }
        try await Self.downloadIfNeeded(
            source: projectorDownloadURL,
            destination: projector,
            expectedBytes: configuration.projector.sizeBytes,
            expectedSHA256: configuration.projector.sha256,
            status: "Downloading Granite projector...",
            progress: progress)

        guard ModelFileValidator.looksLikeGGUF(model),
              ModelFileValidator.looksLikeGGUF(projector) else {
            throw EngineError.modelUnavailable
        }
        return .init(model: model, projector: projector)
    }

    /// Fetches one GGUF through the shared download stack (ranged when the CDN
    /// supports it, with real progress either way), validates, and installs it
    /// atomically.
    private nonisolated static func downloadIfNeeded(
        source: URL,
        destination: URL,
        expectedBytes: Int64,
        expectedSHA256: String,
        status: String,
        progress: ModelPreparationProgressHandler?
    ) async throws {
        if ModelFileValidator.looksLikeGGUF(destination),
           await DownloadIntegrity.verifiedExisting(
               at: destination, expectedBytes: expectedBytes,
               expectedSHA256: expectedSHA256) {
            return
        }
        DownloadIntegrity.removeFileAndMarker(at: destination)
        report(.init(fractionCompleted: 0, status: status), to: progress)

        let stashed = try await ParallelRangeDownloader.download(from: source, session: .shared) { update in
            report(.init(fractionCompleted: update.fractionCompleted, status: status), to: progress)
        }
        do {
            guard ModelFileValidator.looksLikeGGUF(stashed) else {
                throw EngineError.modelUnavailable
            }
            try await DownloadIntegrity.verifyDownloaded(
                at: stashed, expectedBytes: expectedBytes, expectedSHA256: expectedSHA256)
        } catch {
            DownloadFileRescuer.cleanup(stashed)
            throw error
        }
        try DownloadFileRescuer.install(stashed: stashed, to: destination)
        DownloadIntegrity.removeFileAndMarker(at: stashed)
        try DownloadIntegrity.markInstalled(
            at: destination, expectedBytes: expectedBytes, expectedSHA256: expectedSHA256)
    }

    private nonisolated static func report(_ update: ModelPreparationUpdate,
                                           to handler: ModelPreparationProgressHandler?) {
        guard let handler else { return }
        Task { @MainActor in handler(update) }
    }

    private nonisolated static func makeWorkDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("granite-asr-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - llama-server request

    private func transcribeWav(_ wav: URL, modelFileName: String,
                               language: String?) async throws -> String {
        guard let server else { throw EngineError.serverUnavailable }
        let boundary = "lokalbot-\(UUID().uuidString)"
        let authenticationToken = await server.authenticationToken()
        let request = try Self.makeTranscriptionRequest(
            serverBaseURL: server.baseURL,
            authenticationToken: authenticationToken,
            boundary: boundary,
            wav: wav,
            language: language,
            modelFileName: modelFileName)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw EngineError.transcriptionFailed("no response") }
        guard (200..<300).contains(http.statusCode) else {
            let message = String(decoding: data.prefix(512), as: UTF8.self)
            throw EngineError.transcriptionFailed("HTTP \(http.statusCode): \(message)")
        }
        guard let payload = try? JSONDecoder().decode(TranscriptionResponse.self, from: data),
              let text = payload.text else {
            throw EngineError.transcriptionFailed("invalid response")
        }
        return text
    }

    nonisolated static func makeTranscriptionRequest(
        serverBaseURL: URL,
        authenticationToken: String,
        boundary: String,
        wav: URL,
        language: String?
    ) throws -> URLRequest {
        try makeTranscriptionRequest(
            serverBaseURL: serverBaseURL,
            authenticationToken: authenticationToken,
            boundary: boundary,
            wav: wav,
            language: language,
            modelFileName: Self.modelFileName)
    }

    nonisolated static func makeTranscriptionRequest(
        serverBaseURL: URL,
        authenticationToken: String,
        boundary: String,
        wav: URL,
        language: String?,
        modelFileName: String
    ) throws -> URLRequest {
        var request = URLRequest(
            url: serverBaseURL.appendingPathComponent("audio/transcriptions"))
        request.httpMethod = "POST"
        request.timeoutInterval = 600
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        LocalLlamaServerAuthentication.apply(to: &request, token: authenticationToken)
        var fields = [
            "model": modelFileName,
            "prompt": Self.prompt,
        ]
        if let language, !language.isEmpty {
            // llama.cpp's transcription endpoint appends this ISO language
            // hint to the ASR prompt. Omitting it preserves real auto-detect.
            fields["language"] = language
        }
        request.httpBody = try Self.multipartBody(
            boundary: boundary,
            fields: fields,
            fileURL: wav)
        return request
    }

    private nonisolated static func multipartBody(boundary: String,
                                                  fields: [String: String],
                                                  fileURL: URL) throws -> Data {
        var body = Data()
        func append(_ string: String) { body.append(Data(string.utf8)) }

        for (name, value) in fields {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            append("\(value)\r\n")
        }

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n")
        append("Content-Type: audio/wav\r\n\r\n")
        body.append(try Data(contentsOf: fileURL))
        append("\r\n--\(boundary)--\r\n")
        return body
    }

    private struct TranscriptionResponse: Decodable {
        let text: String?
    }

    enum EngineError: LocalizedError {
        case modelUnavailable
        case serverUnavailable
        case transcriptionFailed(String)

        var errorDescription: String? {
            switch self {
            case .modelUnavailable:
                "Granite Speech files are missing or invalid."
            case .serverUnavailable:
                "Granite Speech local server is not running."
            case .transcriptionFailed(let detail):
                "Granite Speech transcription failed: \(detail)"
            }
        }
    }
}

/// Immutable façade captured with one settings snapshot. The shared actor
/// serializes switches between different Granite configurations while still
/// allowing concurrent tracks to use the same loaded model.
private struct ConfiguredGraniteSpeechEngine: TranscriptionEngine {
    let configuration: GraniteSpeechModelConfiguration

    var displayName: String { configuration.displayName }
    let supportsStreaming = false

    func prepare(progress: ModelPreparationProgressHandler?) async throws {
        try await GraniteSpeechEngine.shared.prepare(
            configuration: configuration,
            progress: progress)
    }

    func transcribe(audio: URL, language: String?) async throws -> Transcript {
        try await GraniteSpeechEngine.shared.transcribe(
            configuration: configuration,
            audio: audio,
            language: language)
    }
}

extension GraniteSpeechEngine {
    nonisolated static func configured(
        _ configuration: GraniteSpeechModelConfiguration
    ) -> any TranscriptionEngine {
        ConfiguredGraniteSpeechEngine(configuration: configuration)
    }
}
