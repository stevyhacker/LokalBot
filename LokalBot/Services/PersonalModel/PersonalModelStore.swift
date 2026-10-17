import CryptoKit
import Foundation

/// Persists the personal model as `memory/personal-model.json.enc`, sealed
/// with AES-GCM under the same per-install `chat-key` as saved conversations:
/// these claims are as sensitive as the questions they came from.
///
/// A plaintext `memory/personal-model.json` (demo seeds, upgrade fixtures) is
/// accepted and re-encrypted on the next save. Writes are atomic and 0600.
/// Only the app writes; headless `--chat` reads. Evidence-backed claims
/// (RFC Phase 3) move this under `DreamStore`'s lock so retraction updates
/// them in the same critical section as Dream memory.
@MainActor
struct PersonalModelStore {
    enum LoadError: Error, Equatable {
        case keyUnavailable
        case unreadable
        case newerVersion(Int)
    }

    static let fileName = "personal-model.json"

    let root: URL
    let encryptionKey: @MainActor () throws -> SymmetricKey

    init(root: URL, encryptionKey: @escaping @MainActor () throws -> SymmetricKey = {
        try KeychainSecrets.symmetricKey(account: "chat-key")
    }) {
        self.root = root
        self.encryptionKey = encryptionKey
    }

    var directory: URL { root.appendingPathComponent("memory", isDirectory: true) }
    var encryptedURL: URL { directory.appendingPathComponent(Self.fileName + ".enc") }
    var plaintextURL: URL { directory.appendingPathComponent(Self.fileName) }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    /// The saved model; empty when nothing was ever saved. An encrypted copy
    /// wins over a leftover plaintext one. Throws instead of returning empty
    /// for anything unreadable, so a caller never saves over it.
    func load() throws -> PersonalModel {
        let fileManager = FileManager.default
        let data: Data
        if fileManager.fileExists(atPath: encryptedURL.path) {
            guard let key = try? encryptionKey() else { throw LoadError.keyUnavailable }
            guard let sealed = try? Data(contentsOf: encryptedURL),
                  let box = try? AES.GCM.SealedBox(combined: sealed),
                  let opened = try? AES.GCM.open(box, using: key) else { throw LoadError.unreadable }
            data = opened
        } else if fileManager.fileExists(atPath: plaintextURL.path) {
            guard let plain = try? Data(contentsOf: plaintextURL) else { throw LoadError.unreadable }
            data = plain
        } else {
            return PersonalModel()
        }
        guard let model = try? Self.decoder.decode(PersonalModel.self, from: data) else {
            throw LoadError.unreadable
        }
        guard model.version <= PersonalModel.currentVersion else {
            throw LoadError.newerVersion(model.version)
        }
        return model
    }

    /// Seal → atomic write → 0600, then drop any plaintext copy.
    func save(_ model: PersonalModel) throws {
        let key = try encryptionKey()
        let data = try Self.encoder.encode(model)
        guard let combined = try AES.GCM.seal(data, using: key).combined else {
            throw LoadError.unreadable
        }
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try combined.write(to: encryptedURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: encryptedURL.path)
        if fileManager.fileExists(atPath: plaintextURL.path) {
            try fileManager.removeItem(at: plaintextURL)
        }
    }

    /// "Forget everything about me": removes both copies.
    func deleteAll() throws {
        let fileManager = FileManager.default
        for url in [encryptedURL, plaintextURL] where fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }
}
