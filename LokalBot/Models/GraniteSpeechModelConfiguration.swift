import CryptoKit
import Foundation

/// One llama.cpp-compatible Granite Speech model plus its multimodal projector.
/// Both artifacts are pinned to immutable Hugging Face metadata so a mutable
/// repository cannot silently replace the files LokalBot runs.
struct GraniteSpeechModelConfiguration: Codable, Equatable, Hashable, Sendable {
    struct Artifact: Codable, Equatable, Hashable, Sendable {
        let path: String
        let sizeBytes: Int64
        let sha256: String
    }

    enum ValidationError: LocalizedError, Equatable {
        case invalidRepository
        case invalidRevision
        case invalidModel
        case invalidProjector
        case invalidIntegrityMetadata

        var errorDescription: String? {
            switch self {
            case .invalidRepository:
                "Enter a public Hugging Face repository as owner/name."
            case .invalidRevision:
                "Hugging Face did not return an immutable commit revision."
            case .invalidModel:
                "Choose a Granite Speech model GGUF, not a projector file."
            case .invalidProjector:
                "Choose the matching mmproj projector GGUF from the same repository."
            case .invalidIntegrityMetadata:
                "Both files need a byte size and SHA-256 digest before LokalBot can run them."
            }
        }
    }

    static let defaultModel = GraniteSpeechModelConfiguration(
        uncheckedRepository: "ibm-granite/granite-speech-4.1-2b-GGUF",
        revision: "8267dad2adc84209b0efd2702ec68a98356125eb",
        model: Artifact(
            path: "granite-speech-4.1-2b-Q4_K_M.gguf",
            sizeBytes: 1_139_247_200,
            sha256: "d18e3e79826c4f0fa6734eb05d2db3f06baccbcd5791a83653f946b3178b35d8"),
        projector: Artifact(
            path: "mmproj-model-f16.gguf",
            sizeBytes: 1_159_354_752,
            sha256: "0d3615076cbe1d35c3f60c43a60a4047b3e2eeee1b2c233580be60186faab5c5"))

    /// IBM recommends Q8 for 5.0 accuracy; keep the existing 4.1 selection
    /// and its Q4 cache unchanged.
    static let speech5 = GraniteSpeechModelConfiguration(
        uncheckedRepository: "ibm-granite/granite-speech-5.0-2b-GGUF",
        revision: "df3833f5e22e7d51c3f5dfedd4726260f7ec7cb5",
        model: Artifact(
            path: "granite-speech-5.0-2b-Q8_0.gguf",
            sizeBytes: 1_956_155_104,
            sha256: "4972786fa455b71ee1f020e8ae1b147ca6cd2b1e5b0818048011d7f1da242790"),
        projector: Artifact(
            path: "mmproj-model-f16.gguf",
            sizeBytes: 1_159_354_752,
            sha256: "c0d108e1a3cf345b22c411245fc2762319f1c6b6e56bb15bdffe748c9342ca7d"))

    let repository: String
    let revision: String
    let model: Artifact
    let projector: Artifact

    init(repository: String, revision: String,
         model: Artifact, projector: Artifact) throws {
        let repository = repository.trimmingCharacters(in: .whitespacesAndNewlines)
        let revision = revision.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidRepository(repository) else {
            throw ValidationError.invalidRepository
        }
        guard Self.isValidRevision(revision) else {
            throw ValidationError.invalidRevision
        }
        guard Self.isValidArtifactPath(model.path),
              !model.path.localizedCaseInsensitiveContains("mmproj") else {
            throw ValidationError.invalidModel
        }
        guard Self.isValidArtifactPath(projector.path),
              projector.path.localizedCaseInsensitiveContains("mmproj") else {
            throw ValidationError.invalidProjector
        }
        guard Self.hasValidIntegrity(model), Self.hasValidIntegrity(projector) else {
            throw ValidationError.invalidIntegrityMetadata
        }
        self.init(
            uncheckedRepository: repository,
            revision: revision,
            model: Self.normalized(model),
            projector: Self.normalized(projector))
    }

    private init(uncheckedRepository: String, revision: String,
                 model: Artifact, projector: Artifact) {
        repository = uncheckedRepository
        self.revision = revision
        self.model = model
        self.projector = projector
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            repository: container.decode(String.self, forKey: .repository),
            revision: container.decode(String.self, forKey: .revision),
            model: container.decode(Artifact.self, forKey: .model),
            projector: container.decode(Artifact.self, forKey: .projector))
    }

    var isDefault: Bool { self == Self.defaultModel }

    var supportsVocabularyPrompt: Bool { repository == Self.speech5.repository }

    /// The picker choice this configuration runs under, so language errors
    /// name the selected Granite model.
    var transcriptionChoice: TranscriptionModelChoice {
        repository == Self.speech5.repository ? .graniteSpeech5 : .graniteSpeech
    }

    var quantization: String {
        let leaf = (model.path as NSString).lastPathComponent
        let stem = (leaf as NSString).deletingPathExtension
        return stem.split(separator: "-").last.map(String.init) ?? leaf
    }

    var displayName: String {
        let modelName: String
        switch repository {
        case Self.defaultModel.repository: modelName = "Granite Speech 4.1 2B"
        case Self.speech5.repository: modelName = "Granite Speech 5.0 2B"
        default: modelName = repository
        }
        return "\(modelName) · \(quantization)"
    }

    var downloadDescription: String {
        let total = model.sizeBytes.addingReportingOverflow(projector.sizeBytes)
        let bytes = total.overflow ? Int64.max : total.partialValue
        return "\(bytes.formatted(.byteCount(style: .file))) download · "
            + "\(quantization) GGUF + multimodal projector"
    }

    /// Official Granite quantizations at the pinned built-in revision share
    /// the legacy folder and projector. Other repositories get a stable,
    /// revision-scoped directory so identically named files cannot collide.
    var cacheDirectoryName: String? {
        guard repository != Self.defaultModel.repository
                || revision != Self.defaultModel.revision else { return nil }
        let digest = SHA256.hash(data: Data("\(repository)@\(revision)".utf8))
        return digest.prefix(10).map { String(format: "%02x", $0) }.joined()
    }

    var localModelFileName: String { Self.safeLeafName(model.path) }
    var localProjectorFileName: String { Self.safeLeafName(projector.path) }

    func downloadURL(for artifact: Artifact) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "huggingface.co"
        components.path = "/\(repository)/resolve/\(revision)/\(artifact.path)"
        return components.url
    }

    private enum CodingKeys: String, CodingKey {
        case repository, revision, model, projector
    }

    private static func isValidRepository(_ repository: String) -> Bool {
        let parts = repository.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        return parts.allSatisfy { part in
            !part.isEmpty && part != "." && part != ".."
                && part.allSatisfy { $0.isLetter || $0.isNumber || "-_.".contains($0) }
        }
    }

    private static func isValidRevision(_ revision: String) -> Bool {
        // The model API returns a 40-character Git commit SHA. Branches and
        // tags are mutable, so accepting one here would make the persisted
        // checksums describe a different artifact if the ref later moved.
        revision.count == 40 && revision.allSatisfy(\.isHexDigit)
    }

    private static func isValidArtifactPath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"),
              path.lowercased().hasSuffix(".gguf") else { return false }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        return !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
    }

    private static func hasValidIntegrity(_ artifact: Artifact) -> Bool {
        let digest = artifact.sha256.lowercased()
        return artifact.sizeBytes > 4
            && digest.count == 64
            && digest.allSatisfy(\.isHexDigit)
    }

    private static func normalized(_ artifact: Artifact) -> Artifact {
        Artifact(path: artifact.path, sizeBytes: artifact.sizeBytes,
                 sha256: artifact.sha256.lowercased())
    }

    private static func safeLeafName(_ path: String) -> String {
        let leaf = (path as NSString).lastPathComponent
        return String(leaf.map { character in
            character.isLetter || character.isNumber || "-_.".contains(character)
                ? character : "_"
        })
    }
}
