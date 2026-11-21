import Foundation

@MainActor
final class ModelDownloadManager: ObservableObject {

    struct ProgressSink: Sendable {
        let publish: @Sendable (ParallelRangeDownloader.Progress) -> Void
    }

    typealias StagedDownloader = @Sendable (
        URL, URLSession, URL, String?, ProgressSink
    ) async throws -> URL
    typealias SHA256Digest = @Sendable (URL) async throws -> String

    enum PreparationError: LocalizedError {
        case failed(String)
        case unusableSource(String)

        var errorDescription: String? {
            switch self {
            case .failed(let message), .unusableSource(let message): message
            }
        }

        var isRetryable: Bool {
            if case .unusableSource = self { return false }
            return true
        }
    }

    nonisolated static let unpinnedHuggingFaceMessage = "For safety, Hugging Face models must use an immutable revision and an advertised SHA-256 digest. Remove this model, then add it again from Browse Hugging Face."

    static let shared = ModelDownloadManager()

    @Published private(set) var progress: [String: Double] = [:]
    @Published private(set) var errors: [String: String] = [:]

    private var tasks: [String: Task<Void, Never>] = [:]
    private var generations: [String: UUID] = [:]
    private var verificationTasks: [String: (token: UUID, task: Task<URL?, Never>)] = [:]
    private var lastProgressPublish: [String: (fraction: Double, time: TimeInterval)] = [:]

    private let session: URLSession
    private let stagedDownloader: StagedDownloader
    private let sha256Digest: SHA256Digest

    init(
        session: URLSession? = nil,
        stagedDownloader: @escaping StagedDownloader = { url, session, stashDirectory, expectedSHA256, progress in
            try await ModelDownloadRouting.download(
                from: url,
                session: session,
                expectedSHA256: expectedSHA256,
                stashDirectory: stashDirectory,
                progress: progress.publish)
        },
        sha256Digest: @escaping SHA256Digest = { url in
            try await Task.detached(priority: .utility) {
                try SHA256Verifier.hexDigest(of: url)
            }.value
        }
    ) {
        self.session = session ?? Self.makeSession()
        self.stagedDownloader = stagedDownloader
        self.sha256Digest = sha256Digest
    }

    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 7 * 24 * 60 * 60
        configuration.waitsForConnectivity = true
        configuration.httpMaximumConnectionsPerHost = ParallelRangeDownloader.defaultMaxConcurrentParts
        configuration.networkServiceType = .responsiveData
        configuration.httpShouldSetCookies = false
        return URLSession(configuration: configuration)
    }

    func download(_ entry: ModelCatalog.Entry, storage: StorageManager) {
        download(url: entry.url, fileName: entry.fileName, id: entry.id,
                 expectedSizeGB: entry.sizeGB, expectedSHA256: entry.expectedSHA256,
                 storage: storage)
    }

    func verifiedExistingURL(_ entry: ModelCatalog.Entry,
                             storage: StorageManager) async -> URL? {
        guard ModelCatalog.localURL(for: entry, storage: storage) != nil else { return nil }
        guard entry.expectedSHA256 != nil else {
            return ModelCatalog.localURL(for: entry, storage: storage)
        }
        if let running = verificationTasks[entry.id] {
            return await running.task.value
        }

        let token = UUID()
        let task = Task { @MainActor [weak self] () -> URL? in
            guard let self else { return nil }
            return await self.verifyExistingUncoalesced(entry, storage: storage)
        }
        verificationTasks[entry.id] = (token, task)
        let result = await task.value
        if verificationTasks[entry.id]?.token == token {
            verificationTasks.removeValue(forKey: entry.id)
        }
        return result
    }

    private func verifyExistingUncoalesced(_ entry: ModelCatalog.Entry,
                                           storage: StorageManager) async -> URL? {
        guard let existing = ModelCatalog.localURL(for: entry, storage: storage),
              let expectedSHA256 = entry.expectedSHA256 else { return nil }
        let isValid: Bool
        do {
            if let expectedBytes = entry.expectedSizeBytes {
                isValid = try await DownloadIntegrity.verifyExisting(
                    at: existing,
                    expectedBytes: expectedBytes,
                    expectedSHA256: expectedSHA256)
            } else {
                try Task.checkCancellation()
                isValid = try await sha256Digest(existing).lowercased() == expectedSHA256
            }
        } catch {
            guard !Task.isCancelled else { return nil }
            errors[entry.id] = "Could not verify the existing model: \(error.localizedDescription)"
            return nil
        }
        guard !Task.isCancelled else { return nil }
        guard isValid else {
            DownloadIntegrity.removeFileAndMarker(at: existing)
            errors[entry.id] = "The existing model failed its SHA-256 integrity check."
            objectWillChange.send()
            return nil
        }
        errors[entry.id] = nil
        return existing
    }

    func ensureAvailable(_ entry: ModelCatalog.Entry, storage: StorageManager) async throws -> URL {
        if let existing = await verifiedExistingURL(entry, storage: storage) {
            return existing
        }
        try Task.checkCancellation()
        if let refusal = Self.sourceRefusal(for: entry) {
            errors[entry.id] = refusal
            throw PreparationError.unusableSource(refusal)
        }

        download(entry, storage: storage)
        while tasks[entry.id] != nil {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(200))
        }

        if let downloaded = await verifiedExistingURL(entry, storage: storage) {
            return downloaded
        }
        throw PreparationError.failed(
            errors[entry.id] ?? "Could not prepare \(entry.displayName). Check your connection and free disk space.")
    }

    func download(url urlString: String, fileName: String, id: String,
                  expectedSizeGB: Double? = nil, expectedSHA256: String? = nil,
                  storage: StorageManager) {
        guard tasks[id] == nil, let rawURL = URL(string: urlString) else { return }
        verificationTasks.removeValue(forKey: id)?.task.cancel()
        guard Self.isSafeFileName(fileName) else {
            errors[id] = "The model filename is unsafe. Choose the file again."
            return
        }
        let requiredSHA256 = expectedSHA256 ?? Self.embeddedSHA256(in: rawURL)
        if let refusal = Self.sourceRefusal(for: rawURL, requiredSHA256: requiredSHA256) {
            errors[id] = refusal
            return
        }
        guard let url = Self.networkURL(from: rawURL) else { return }
        let folder = storage.rootURL.appendingPathComponent("models", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent(fileName)
        let stashDirectory = folder.appendingPathComponent(".partial", isDirectory: true)
        let stashedBytes = ParallelRangeDownloader.stashedByteCount(
            for: url, stashDirectory: stashDirectory)
        if let advisory = DiskSpacePrecheck.advisory(
            expectedBytes: expectedSizeGB.map { max(0, Int64($0 * 1_000_000_000) - stashedBytes) },
            availableBytes: DiskSpacePrecheck.availableBytes(at: folder)) {
            errors[id] = advisory
            return
        }
        progress[id] = 0
        errors[id] = nil
        let generation = UUID()
        generations[id] = generation
        let session = session
        let progressHandler: @Sendable (ParallelRangeDownloader.Progress) -> Void = { [weak self] update in
            Task { @MainActor [weak self] in
                self?.publishProgress(
                    id: id, generation: generation,
                    fraction: update.fractionCompleted)
            }
        }
        let stagedDownloader = stagedDownloader
        let sha256Digest = sha256Digest
        tasks[id] = Task(priority: .utility) { [weak self] in
            var stagedURL: URL?
            do {
                let stashed = try await stagedDownloader(
                    url, session, stashDirectory, requiredSHA256,
                    ProgressSink(publish: progressHandler))
                stagedURL = stashed
                try Task.checkCancellation()
                if let requiredSHA256 {
                    let digest = try await sha256Digest(stashed)
                    try Task.checkCancellation()
                    guard digest.lowercased() == requiredSHA256.lowercased() else {
                        DownloadFileRescuer.cleanup(stashed)
                        throw PreparationError.failed(
                            "The downloaded model failed its SHA-256 integrity check.")
                    }
                }
                if let self {
                    self.finish(
                        id: id, generation: generation,
                        destination: destination, stashed: stashed,
                        expectedSHA256: requiredSHA256)
                } else {
                    DownloadFileRescuer.cleanup(stashed)
                }
                stagedURL = nil
            } catch {
                if let stagedURL { DownloadFileRescuer.cleanup(stagedURL) }
                self?.fail(id: id, generation: generation, error: error)
            }
        }
    }

    func cancel(_ entry: ModelCatalog.Entry) { cancel(id: entry.id) }

    func cancel(id: String) {
        tasks[id]?.cancel()
        verificationTasks.removeValue(forKey: id)?.task.cancel()
        tasks[id] = nil
        generations[id] = nil
        progress[id] = nil
        lastProgressPublish[id] = nil
    }

    func delete(_ entry: ModelCatalog.Entry, storage: StorageManager) {
        verificationTasks.removeValue(forKey: entry.id)?.task.cancel()
        DownloadIntegrity.removeFileAndMarker(
            at: storage.rootURL.appendingPathComponent("models/\(entry.fileName)"))
        objectWillChange.send()
    }

    private func finish(id: String, generation: UUID, destination: URL, stashed: URL,
                        expectedSHA256: String?) {
        guard generations[id] == generation else {
            DownloadFileRescuer.cleanup(stashed)
            return
        }
        defer {
            tasks[id] = nil
            generations[id] = nil
            progress[id] = nil
            lastProgressPublish[id] = nil
        }

        let looksGGUF = ModelFileValidator.looksLikeGGUF(stashed)
        let outcome = DownloadOutcomeClassifier.classify(
            httpStatus: 200, error: nil, looksLikeGGUF: looksGGUF)
        guard case .success = outcome else {
            DownloadFileRescuer.cleanup(stashed)
            errors[id] = outcome.userMessage
            return
        }

        do {
            try DownloadFileRescuer.install(stashed: stashed, to: destination)
            if let expectedSHA256 {
                try expectedSHA256.lowercased().write(
                    to: destination.appendingPathExtension("sha256"),
                    atomically: true,
                    encoding: .utf8)
            }
        } catch {
            errors[id] = "Could not save model: \(error.localizedDescription)"
        }
    }

    private func fail(id: String, generation: UUID, error: Error) {
        guard generations[id] == generation else { return }
        let outcome = DownloadOutcomeClassifier.classify(
            httpStatus: nil, error: error, looksLikeGGUF: false)
        tasks[id] = nil
        generations[id] = nil
        progress[id] = nil
        lastProgressPublish[id] = nil
        if case .cancelled = outcome { return }
        errors[id] = outcome.userMessage
    }

    private func publishProgress(id: String, generation: UUID,
                                 fraction: Double, force: Bool = false) {
        guard generations[id] == generation else { return }
        let clamped = min(1, max(0, fraction))
        let now = Date().timeIntervalSinceReferenceDate
        if !force, let last = lastProgressPublish[id],
           clamped < 1,
           clamped - last.fraction < 0.0025,
           now - last.time < 0.2 {
            return
        }
        progress[id] = clamped
        lastProgressPublish[id] = (clamped, now)
    }

    nonisolated static func sourceRefusal(for entry: ModelCatalog.Entry) -> String? {
        guard let url = URL(string: entry.url) else { return "The model download URL is invalid." }
        return sourceRefusal(for: url, requiredSHA256: entry.expectedSHA256)
    }

    private nonisolated static func sourceRefusal(for rawURL: URL, requiredSHA256: String?) -> String? {
        guard let url = networkURL(from: rawURL) else { return "The model download URL is invalid." }
        guard url.scheme?.lowercased() == "https" else {
            return "Model downloads must use an https:// URL."
        }
        if isHuggingFaceURL(url), !isPinnedHuggingFaceURL(url) || requiredSHA256 == nil {
            return unpinnedHuggingFaceMessage
        }
        return nil
    }

    private nonisolated static func embeddedSHA256(in url: URL) -> String? {
        guard let fragment = URLComponents(url: url, resolvingAgainstBaseURL: false)?.fragment,
              fragment.hasPrefix("sha256=") else { return nil }
        let digest = String(fragment.dropFirst("sha256=".count)).lowercased()
        guard digest.count == 64, digest.allSatisfy({ $0.isHexDigit }) else { return nil }
        return digest
    }

    private nonisolated static func networkURL(from url: URL) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.fragment = nil
        return components.url
    }

    private nonisolated static func isHuggingFaceURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host?.lowercased() == "huggingface.co"
    }

    private nonisolated static func isPinnedHuggingFaceURL(_ url: URL) -> Bool {
        let components = url.pathComponents
        guard let resolveIndex = components.firstIndex(of: "resolve"),
              components.indices.contains(resolveIndex + 1) else { return false }
        let revision = components[resolveIndex + 1]
        return revision.count == 40 && revision.allSatisfy({ $0.isHexDigit })
    }

    private static func isSafeFileName(_ fileName: String) -> Bool {
        !fileName.isEmpty
            && fileName.utf8.count <= 255
            && fileName == (fileName as NSString).lastPathComponent
            && fileName != "."
            && fileName != ".."
            && !fileName.contains("\0")
    }
}
