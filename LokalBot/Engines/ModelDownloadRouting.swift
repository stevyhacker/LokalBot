import Foundation
import os

/// Routes pinned Hugging Face file downloads through the source chosen in
/// Settings → Models (see `ModelDownloadSource`).
///
/// Only `https://huggingface.co/<owner>/<repo>/resolve/<revision>/<path>` URLs
/// are rerouted. The Hugging Face API, GitHub archives and every other host are
/// untouched, and stored URLs keep their Hugging Face host, so
/// `ModelDownloadManager`'s pinning policy still applies to them. The chosen
/// mirror is tried first and each later source is a fallback. A file a mirror
/// served is accepted only when it matches the caller's pinned size and
/// SHA-256; otherwise the next source is tried. Callers verify every file again,
/// exactly as with Hugging Face, which stays a single direct download.
enum ModelDownloadRouting {
    /// The source chosen in settings. `SettingsStore` is the one place it
    /// enters the process, as with `SpeakerAttribution.microphoneIsUser`.
    static var source: ModelDownloadSource {
        get { preference.withLock { $0 } }
        set { preference.withLock { $0 = newValue } }
    }
    private static let preference = OSAllocatedUnfairLock(initialState: ModelDownloadSource.huggingFace)

    static let hfMirrorHost = "hf-mirror.com"
    static let modelScopeOrigin = "https://www.modelscope.cn"

    /// A Hugging Face `resolve` URL split into its parts. `path` stays
    /// percent-encoded, as it appears in the URL.
    struct ResolvedFile: Equatable, Sendable {
        let repository: String
        let revision: String
        let path: String
    }

    static func resolvedFile(_ url: URL) -> ResolvedFile? {
        guard url.scheme?.lowercased() == "https", url.host?.lowercased() == "huggingface.co" else { return nil }
        let parts = url.path(percentEncoded: true).split(separator: "/")
        guard parts.count >= 5, parts[2] == "resolve" else { return nil }
        return ResolvedFile(repository: "\(parts[0])/\(parts[1])", revision: String(parts[3]),
                            path: parts[4...].joined(separator: "/"))
    }

    enum Candidate: Equatable, Sendable {
        case original(URL)
        case hfMirror(URL)
        case modelScope(URL, file: ResolvedFile)

        var url: URL {
            switch self {
            case .original(let url), .hfMirror(let url), .modelScope(let url, _): url
            }
        }

        var label: String {
            switch self {
            case .original: "Hugging Face"
            case .hfMirror: "HF-Mirror"
            case .modelScope: "ModelScope"
            }
        }
    }

    /// The sources to try for `url`, in order.
    static func candidates(for url: URL, source: ModelDownloadSource) -> [Candidate] {
        guard source != .huggingFace, let file = resolvedFile(url) else { return [.original(url)] }
        var result: [Candidate] = []
        // ModelScope follows branches, not Hugging Face revisions; the listing
        // check in `modelScopeServes` keeps it to files that match the pin.
        if source == .modelScope,
           let modelScope = URL(string: "\(modelScopeOrigin)/models/\(file.repository)/resolve/master/\(file.path)") {
            result.append(.modelScope(modelScope, file: file))
        }
        var mirror = URLComponents(url: url, resolvingAgainstBaseURL: false)
        mirror?.host = hfMirrorHost
        mirror?.fragment = nil
        if let mirrorURL = mirror?.url { result.append(.hfMirror(mirrorURL)) }
        result.append(.original(url))
        return result
    }

    /// One file in a ModelScope repository listing.
    struct ModelScopeFile: Decodable, Equatable, Sendable {
        let path: String
        let size: Int64?
        let sha256: String?

        enum CodingKeys: String, CodingKey {
            case path = "Path"
            case size = "Size"
            case sha256 = "Sha256"
        }
    }

    /// Whether ModelScope serves exactly the pinned file: its listing has the
    /// same path with the pinned SHA-256 (and size, when both are known).
    /// Files pinned only by a Git blob SHA-1 never qualify; HF-Mirror serves them.
    static func modelScopeServes(_ file: ResolvedFile, expectedSHA256: String?, expectedBytes: Int64?,
                                 listing: [String: ModelScopeFile]?) -> Bool {
        guard let expectedSHA256, expectedSHA256.count == 64,
              let entry = listing?[file.path.removingPercentEncoding ?? file.path],
              let listed = entry.sha256 else { return false }
        if let expectedBytes, let size = entry.size, size != expectedBytes { return false }
        return listed.lowercased() == expectedSHA256.lowercased()
    }

    /// Downloads `url` to a temp file through the chosen source. Pass the
    /// caller's pinned size and SHA-256 (a 64-hex digest) when it has them:
    /// ModelScope needs the digest, and a mirror's file is checked against both
    /// before it is accepted.
    static func download(
        from url: URL,
        session: URLSession,
        expectedSHA256: String? = nil,
        expectedBytes: Int64? = nil,
        stashDirectory: URL? = nil,
        progress: @escaping @Sendable (ParallelRangeDownloader.Progress) -> Void
    ) async throws -> URL {
        try await download(
            from: url, source: source, expectedSHA256: expectedSHA256, expectedBytes: expectedBytes,
            listing: { await ModelScopeListings.shared.files(in: $0) },
            attempt: { candidate in
                try await ParallelRangeDownloader.download(
                    from: candidate, session: session, stashDirectory: stashDirectory, progress: progress)
            })
    }

    /// Testable core: `attempt` downloads one candidate URL to a temp file and
    /// `listing` returns a ModelScope repository's files by path.
    static func download(
        from url: URL,
        source: ModelDownloadSource,
        expectedSHA256: String?,
        expectedBytes: Int64?,
        listing: (String) async -> [String: ModelScopeFile]?,
        attempt: (URL) async throws -> URL
    ) async throws -> URL {
        var firstError: Error?
        for candidate in candidates(for: url, source: source) {
            try Task.checkCancellation()
            if case .modelScope(_, let file) = candidate {
                let files = await listing(file.repository)
                guard modelScopeServes(file, expectedSHA256: expectedSHA256, expectedBytes: expectedBytes,
                                       listing: files) else { continue }
            }
            do {
                let temporary = try await attempt(candidate.url)
                if case .original = candidate { return temporary }
                guard try await matchesPin(temporary, expectedSHA256: expectedSHA256,
                                           expectedBytes: expectedBytes) else {
                    DownloadFileRescuer.cleanup(temporary)
                    throw DownloadIntegrity.IntegrityError.mismatch(candidate.url.lastPathComponent)
                }
                lokalbotLog("model download from \(candidate.label) matched its pin: \(candidate.url.lastPathComponent)")
                return temporary
            } catch {
                if error is CancellationError || (error as? URLError)?.code == .cancelled { throw error }
                lokalbotLog("model download from \(candidate.label) failed: \(error.localizedDescription)")
                firstError = firstError ?? error
            }
        }
        throw firstError ?? URLError(.resourceUnavailable)
    }

    private static func matchesPin(_ file: URL, expectedSHA256: String?, expectedBytes: Int64?) async throws -> Bool {
        if let expectedBytes {
            let size = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value
            guard size == expectedBytes else { return false }
        }
        guard let expectedSHA256, expectedSHA256.count == 64 else { return true }
        let digest = try await Task.detached(priority: .utility) {
            try SHA256Verifier.hexDigest(of: file)
        }.value
        return digest.lowercased() == expectedSHA256.lowercased()
    }
}

/// ModelScope repository listings, fetched once per repository per launch.
/// A failed fetch is not cached, so a later download can try again.
actor ModelScopeListings {
    static let shared = ModelScopeListings()

    private var cache: [String: [String: ModelDownloadRouting.ModelScopeFile]] = [:]

    func files(in repository: String,
               session: URLSession = .shared) async -> [String: ModelDownloadRouting.ModelScopeFile]? {
        if let cached = cache[repository] { return cached }
        guard let url = URL(string: "\(ModelDownloadRouting.modelScopeOrigin)/api/v1/models/\(repository)"
                            + "/repo/files?Revision=master&Recursive=true") else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue(AppIdentifiers.bundleID, forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let listing = try? JSONDecoder().decode(Listing.self, from: data) else { return nil }
        let files = Dictionary(listing.data.files.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        cache[repository] = files
        return files
    }

    private struct Listing: Decodable {
        struct Payload: Decodable {
            let files: [ModelDownloadRouting.ModelScopeFile]
            enum CodingKeys: String, CodingKey { case files = "Files" }
        }
        let data: Payload
        enum CodingKeys: String, CodingKey { case data = "Data" }
    }
}
