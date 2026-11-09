import Foundation

/// EmbeddingGemma 2's image and audio projector, the one extra file Files
/// needs. The text model is the one search by meaning already uses
/// (`EmbeddingIndex.preparedModel`); both come from the same pinned revision.
enum FileSearchModels {
    static let projectorFile = "mmproj-embeddinggemma-2-Q8_0.gguf"
    static let projectorBytes: Int64 = 554_821_024
    static let projectorSHA256 = "c4a8a52691ecef40618438928bdf9e68379b854e24166f292592353db0aab64f"
    static let projectorURL = URL(string:
        "https://huggingface.co/ggml-org/embeddinggemma-2-GGUF/resolve/bfcd298762cc34d0357ece5ebdd31791a3a374d8/"
        + projectorFile)!

    /// What indexing needs to download before it can start, in bytes.
    static func missingDownloadBytes(storageRoot: URL) -> Int64 {
        let folder = storageRoot.appendingPathComponent("models", isDirectory: true)
        var missing: Int64 = 0
        if !FileManager.default.fileExists(atPath: folder.appendingPathComponent(EmbeddingIndex.modelFile).path) {
            missing += 309_855_456
        }
        if !FileManager.default.fileExists(atPath: folder.appendingPathComponent(projectorFile).path) {
            missing += projectorBytes
        }
        return missing
    }

    private static let preparation = EmbeddingModelPreparationCoordinator()

    /// The verified projector in the library's models folder, downloading it
    /// first if needed (checked against the pinned size and SHA-256).
    static func preparedProjector(
        storageRoot: URL,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> URL {
        let key = storageRoot.appendingPathComponent("models/\(projectorFile)")
            .standardizedFileURL.resolvingSymlinksInPath().path
        return try await preparation.prepare(key: key) {
            try await prepareProjector(storageRoot: storageRoot, progress: progress)
        }
    }

    private static func prepareProjector(
        storageRoot: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        let folder = storageRoot.appendingPathComponent("models", isDirectory: true)
        let path = folder.appendingPathComponent(projectorFile)
        if ModelFileValidator.looksLikeGGUF(path),
           await DownloadIntegrity.verifiedExisting(
               at: path, expectedBytes: projectorBytes, expectedSHA256: projectorSHA256) {
            return path
        }
        DownloadIntegrity.removeFileAndMarker(at: path)
        try UITestRuntime.refuseDownloadInUnitTests(of: "the image and audio projector")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stashed = try await ModelDownloadRouting.download(
            from: projectorURL, session: .shared,
            expectedSHA256: projectorSHA256, expectedBytes: projectorBytes) { progress($0.fractionCompleted) }
        do {
            guard ModelFileValidator.looksLikeGGUF(stashed) else {
                throw TextEngineError.badResponse("projector download was not a GGUF model")
            }
            try await DownloadIntegrity.verifyDownloaded(
                at: stashed, expectedBytes: projectorBytes, expectedSHA256: projectorSHA256)
        } catch {
            DownloadFileRescuer.cleanup(stashed)
            throw error
        }
        try DownloadFileRescuer.install(stashed: stashed, to: path)
        DownloadIntegrity.removeFileAndMarker(at: stashed)
        try DownloadIntegrity.markInstalled(
            at: path, expectedBytes: projectorBytes, expectedSHA256: projectorSHA256)
        return path
    }
}

/// The media embedder's llama-server (`LlamaServerRole.mediaEmbedder`): the
/// text model plus the projector, started for an indexing pass and stopped two
/// minutes after the last one. Searches never use it; they embed their words
/// on the small text-only embedder, whose vectors are identical
/// (Benchmarks/EmbeddingGemma2/2026-10-30-media-embedder).
actor FileMediaEmbedderRuntime {
    static let shared = FileMediaEmbedderRuntime()

    /// The embedder's arguments plus the projector. With images resized for
    /// their budget before they are sent (`FileImageSizing`), the token limits
    /// keep llama.cpp from rescaling them.
    static func serverArguments(projector: URL) -> [String] {
        ["--embeddings", "-b", "2048", "-ub", "2048", "--parallel", "1",
         "--mmproj", projector.path, "--image-min-tokens", "1", "--image-max-tokens", "1120"]
    }

    /// Weights are counted separately (865 MB with the projector). The 30
    /// October run peaked at 1.2 GiB RSS while indexing.
    static let runtimeAllowanceBytes: Int64 = 512 * 1_048_576
    static let idleSeconds: TimeInterval = 120

    private var server: LlamaServer?
    private var serverProjector: URL?
    private var pins: [UUID: UUID] = [:]
    private lazy var idle = IdleTimer(seconds: Self.idleSeconds) { [weak self] in await self?.stopIfIdle() }

    /// Starts (or reuses) the server for one pass and keeps it resident until
    /// `end(_:)`. Returns the endpoint and a token to end the pass with.
    func begin(model: URL, projector: URL) async throws -> (endpoint: FileMediaEmbedder.Endpoint, pass: UUID) {
        let pass = UUID()
        pins[pass] = await ModelResidency.shared.pin(id: LlamaServerRole.mediaEmbedder.residencyID)
        do {
            let server = await server(for: projector)
            try await server.ensureRunning(modelAt: model)
            let token = await server.authenticationToken()
            return (FileMediaEmbedder.Endpoint(
                baseURL: URL(string: "http://127.0.0.1:\(server.port)")!, token: token), pass)
        } catch {
            await end(pass)
            throw error
        }
    }

    func end(_ pass: UUID) async {
        guard let pin = pins.removeValue(forKey: pass) else { return }
        await ModelResidency.shared.unpin(pin)
        await idle.bump()
    }

    func shutdown() async {
        await server?.stop()
        server = nil
        serverProjector = nil
    }

    private func stopIfIdle() async {
        guard pins.isEmpty else { return }
        await shutdown()
    }

    private func server(for projector: URL) async -> LlamaServer {
        if let server, serverProjector == projector { return server }
        await server?.stop()
        let instance = LlamaServer(
            role: .mediaEmbedder, contextTokens: 2_048,
            extraArgs: Self.serverArguments(projector: projector),
            runtimeAllowanceBytes: Self.runtimeAllowanceBytes)
        server = instance
        serverProjector = projector
        return instance
    }
}
