import CryptoKit
import Foundation

/// Prepare the reviewed snapshot ourselves before local dependency loaders
/// can open it. Both cached bytes and fresh downloads must match the manifest.
struct PinnedModelSnapshot: Sendable, Decodable {
    struct File: Sendable, Decodable {
        let path: String
        let bytes: Int64
        let digest: String
        let isGitBlob: Bool
        var remotePath: String?
    }

    let repository: String
    let revision: String
    let files: [File]
    var remotePrefix: String?

    static func catalog(_ name: String, bundle: Bundle = .main) throws -> Self {
        struct Entry: Decodable {
            let name: String
            let repository: String
            let revision: String
            let files: [File]
            let remotePrefix: String?
        }
        guard let source = bundle.url(forResource: "pinned-speech-models", withExtension: "json", subdirectory: "ModelAssets"),
              let entry = try JSONDecoder().decode([Entry].self, from: Data(contentsOf: source)).first(where: { $0.name == name }) else {
            throw SnapshotError.manifestMissing
        }
        return Self(repository: entry.repository, revision: entry.revision, files: entry.files, remotePrefix: entry.remotePrefix)
    }

    typealias Downloader = @Sendable (URL) async throws -> URL

    func prepare(in directory: URL,
                 progress: ModelPreparationProgressHandler? = nil,
                 download: Downloader? = nil) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let total = files.reduce(Int64(0)) { $0 + $1.bytes }
        var completed: Int64 = 0
        for file in files {
            try Task.checkCancellation()
            let destination = try Self.destination(for: file.path, in: directory)
            if !(try Self.verified(file, at: destination)) {
                try Task.checkCancellation()
                await progress?(.init(fractionCompleted: Double(completed) / Double(max(1, total)),
                                      status: "Downloading verified model files…"))
                let remotePath = file.remotePath ?? "\(remotePrefix ?? "")\(file.path)"
                guard Self.safePath(remotePath),
                      let source = URL(string: "https://huggingface.co/\(repository)/resolve/\(revision)/\(remotePath)") else {
                    throw SnapshotError.invalidPath
                }
                let temporary: URL
                if let download {
                    temporary = try await download(source)
                } else {
                    let priorBytes = completed
                    temporary = try await ParallelRangeDownloader.download(from: source, session: .shared) { update in
                        let fraction = (Double(priorBytes) + update.fractionCompleted * Double(file.bytes)) / Double(max(1, total))
                        Task { @MainActor in progress?(.init(fractionCompleted: fraction, status: "Downloading verified model files…")) }
                    }
                }
                defer { DownloadFileRescuer.cleanup(temporary) }
                guard try Self.verified(file, at: temporary) else { throw SnapshotError.integrityFailure(file.path) }
                try Task.checkCancellation()
                let checkedDestination = try Self.destination(for: file.path, in: directory)
                try FileManager.default.createDirectory(at: checkedDestination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try DownloadFileRescuer.install(stashed: temporary, to: checkedDestination)
            }
            completed += file.bytes
        }
        try validateDiscoveredFiles(in: directory)
        try Task.checkCancellation()
    }

    private func validateDiscoveredFiles(in directory: URL) throws {
        // The MLX loader discovers safetensors by extension. Do not let an
        // unreviewed leftover shard silently join the pinned weights.
        let expectedWeights = Set(files.filter { $0.path.hasSuffix(".safetensors") }.map(\.path))
        if !expectedWeights.isEmpty {
            let actualWeights = Set(try FileManager.default.contentsOfDirectory(atPath: directory.path)
                .filter { $0.hasSuffix(".safetensors") })
            guard actualWeights == expectedWeights else { throw SnapshotError.unexpectedWeights }
        }
        // CoreML consumes whole compiled directories, including any files not
        // named in the manifest. Reject leftovers inside those components.
        let components = Set(files.compactMap { file in
            file.path.split(separator: "/").first.map(String.init)
        }.filter { $0.hasSuffix(".mlmodelc") })
        for component in components {
            let root = try Self.destination(for: component, in: directory)
            let expected = Set(files.filter { $0.path.hasPrefix(component + "/") }.map(\.path))
            var actual: Set<String> = []
            let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
            var enumerationError: Error?
            guard let entries = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys), errorHandler: { _, error in
                enumerationError = error
                return false
            }) else { throw SnapshotError.unexpectedWeights }
            for case let entry as URL in entries {
                let attributes = try entry.resourceValues(forKeys: keys)
                guard attributes.isSymbolicLink != true else { throw SnapshotError.invalidPath }
                if attributes.isDirectory == true { continue }
                guard attributes.isRegularFile == true else { throw SnapshotError.unexpectedWeights }
                let relative = String(entry.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count + 1))
                actual.insert(component + "/" + relative)
            }
            if let enumerationError { throw enumerationError }
            guard actual == expected else { throw SnapshotError.unexpectedWeights }
        }
    }

    func verify(in directory: URL) throws {
        for file in files {
            try Task.checkCancellation()
            guard try Self.verified(file, at: Self.destination(for: file.path, in: directory)) else {
                throw SnapshotError.integrityFailure(file.path)
            }
        }
        try validateDiscoveredFiles(in: directory)
    }

    static func verified(_ file: File, at url: URL) throws -> Bool {
        guard let attributes = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              attributes.isRegularFile == true, attributes.isSymbolicLink != true,
              Int64(attributes.fileSize ?? -1) == file.bytes else { return false }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var sha256 = SHA256()
        var gitSHA1 = Insecure.SHA1()
        if file.isGitBlob { gitSHA1.update(data: Data("blob \(file.bytes)\0".utf8)) }
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            try Task.checkCancellation()
            if file.isGitBlob { gitSHA1.update(data: data) } else { sha256.update(data: data) }
        }
        let actual = file.isGitBlob
            ? gitSHA1.finalize().map { String(format: "%02x", $0) }.joined()
            : sha256.finalize().map { String(format: "%02x", $0) }.joined()
        return actual == file.digest
    }

    private static func safePath(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.split(separator: "/").contains { $0 == ".." || $0 == "." }
    }

    private static func destination(for path: String, in directory: URL) throws -> URL {
        guard safePath(path) else { throw SnapshotError.invalidPath }
        // The storage root may itself be relocated by the user. Once resolved,
        // no model-owned child may redirect a read or write through a symlink.
        var destination = directory.standardizedFileURL.resolvingSymlinksInPath()
        for component in path.split(separator: "/") {
            destination.appendPathComponent(String(component))
            let attributes = try? FileManager.default.attributesOfItem(atPath: destination.path)
            guard attributes?[.type] as? FileAttributeType != .typeSymbolicLink else {
                throw SnapshotError.invalidPath
            }
        }
        return destination
    }

    enum SnapshotError: LocalizedError {
        case invalidPath
        case integrityFailure(String)
        case unexpectedWeights
        case manifestMissing
        var errorDescription: String? {
            switch self {
            case .invalidPath: "The model manifest contains an invalid file path."
            case .integrityFailure(let file): "The downloaded model file failed verification: \(file)."
            case .unexpectedWeights: "The model cache contains unexpected weights. Delete this model in Settings and download it again."
            case .manifestMissing: "The pinned model manifest is missing from the app."
            }
        }
    }
}

// Source: Hugging Face model metadata, including immutable commit and LFS/Git digests.
extension PinnedModelSnapshot {
    static let qwenAccuracy = Self(repository: "aufklarer/Qwen3-ASR-1.7B-MLX-8bit", revision: "e5450a26d1fd417c45fc9c405651ddc3180a27a6", files: [
        .init(path: "config.json", bytes: 7188,
              digest: "888cc7fae19ea9ede543b1ae82e9c78aa06104ca", isGitBlob: true),
        .init(path: "merges.txt", bytes: 1671853,
              digest: "31349551d90c7606f325fe0f11bbb8bd5fa0d7c7", isGitBlob: true),
        .init(path: "model.safetensors", bytes: 2463307541,
              digest: "bf304b009cc7eca79283056f787b44c952d24ac22cec787b39732bba3c23c13c", isGitBlob: false),
        .init(path: "model.safetensors.index.json", bytes: 78968,
              digest: "f0191caac2794d5b6fba0ab3eeb70f8eff90319e", isGitBlob: true),
        .init(path: "tokenizer_config.json", bytes: 12487,
              digest: "b93109843922a40c6654c5449d3bf95372267c66", isGitBlob: true),
        .init(path: "vocab.json", bytes: 2776833,
              digest: "4783fe10ac3adce15ac8f358ef5462739852c569", isGitBlob: true),
    ])
    static let qwenCompact = Self(repository: "aufklarer/Qwen3-ASR-0.6B-MLX-4bit", revision: "bc441bd1e4295c1f42d9879f056049a925b6e013", files: [
        .init(path: "config.json", bytes: 7187,
              digest: "049989ad1e19719b99c2f374eb7067040aa4c830", isGitBlob: true),
        .init(path: "merges.txt", bytes: 1671853,
              digest: "31349551d90c7606f325fe0f11bbb8bd5fa0d7c7", isGitBlob: true),
        .init(path: "model.safetensors", bytes: 708236945,
              digest: "70c7e67e588062adce4f10796e47ad42ead51c6671eda61a0987eae38ca95ddf", isGitBlob: false),
        .init(path: "model.safetensors.index.json", bytes: 71814,
              digest: "b507ef4ee5b57e6147c4bda5d9db05992477030d", isGitBlob: true),
        .init(path: "tokenizer_config.json", bytes: 12487,
              digest: "b93109843922a40c6654c5449d3bf95372267c66", isGitBlob: true),
        .init(path: "vocab.json", bytes: 2776833,
              digest: "4783fe10ac3adce15ac8f358ef5462739852c569", isGitBlob: true),
    ])
}
