import CryptoKit
import Foundation

/// Downloaded mail under `email/`, every file sealed with AES-GCM under the
/// per-install `email-key`. Mail never goes into the plaintext search
/// database, the embeddings, Dream reports, or exports.
///
///     email/accounts.json.enc                      connected accounts and cursors
///     email/<account-id>/threads/<thread-id>.json.enc
///
/// Writes are atomic and 0600. Tokens live in the Keychain, never here.
struct EmailStore: Sendable {
    enum StoreError: Error, Equatable {
        case unreadable(String)
    }

    static let keyAccount = "email-key"

    let root: URL
    let key: SymmetricKey

    /// The sealing key, created on first use. Callers only ask for it once
    /// an account exists, so an install that never connects mail never adds
    /// a Keychain item.
    @MainActor static func liveKey() throws -> SymmetricKey {
        try KeychainSecrets.symmetricKey(account: keyAccount)
    }

    static func directory(root: URL) -> URL {
        root.appendingPathComponent("email", isDirectory: true)
    }

    static func accountsURL(root: URL) -> URL {
        directory(root: root).appendingPathComponent("accounts.json.enc")
    }

    /// True when anything was ever saved, so the key is worth reading.
    static func hasAccounts(root: URL) -> Bool {
        FileManager.default.fileExists(atPath: accountsURL(root: root).path)
    }

    var directory: URL { Self.directory(root: root) }

    func threadsDirectory(_ accountID: UUID) -> URL {
        directory
            .appendingPathComponent(accountID.uuidString.lowercased(), isDirectory: true)
            .appendingPathComponent("threads", isDirectory: true)
    }

    private func threadURL(accountID: UUID, threadID: String) -> URL {
        threadsDirectory(accountID).appendingPathComponent("\(GmailClient.pathSafe(threadID)).json.enc")
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    // MARK: Accounts

    func loadAccounts() throws -> [EmailAccount] {
        let url = Self.accountsURL(root: root)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try open([EmailAccount].self, at: url)
    }

    func saveAccounts(_ accounts: [EmailAccount]) throws {
        try seal(accounts, to: Self.accountsURL(root: root))
    }

    // MARK: Threads

    func thread(accountID: UUID, threadID: String) throws -> EmailThread? {
        let url = threadURL(accountID: accountID, threadID: threadID)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try open(EmailThread.self, at: url)
    }

    func saveThread(_ thread: EmailThread) throws {
        try seal(thread, to: threadURL(accountID: thread.accountID, threadID: thread.id))
    }

    func deleteThread(accountID: UUID, threadID: String) throws {
        let url = threadURL(accountID: accountID, threadID: threadID)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    func threadIDs(accountID: UUID) -> Set<String> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: threadsDirectory(accountID).path)) ?? []
        return Set(names.compactMap { name in
            name.hasSuffix(".json.enc") ? String(name.dropLast(".json.enc".count)) : nil
        })
    }

    /// Every stored thread of an account. An unreadable file is skipped
    /// rather than failing the rest; the next full scan replaces it.
    func threads(accountID: UUID) -> [EmailThread] {
        threadIDs(accountID: accountID).sorted().compactMap { id in
            try? thread(accountID: accountID, threadID: id)
        }
    }

    /// Removes everything downloaded for one account.
    func deleteAccountData(_ accountID: UUID) throws {
        let folder = directory.appendingPathComponent(accountID.uuidString.lowercased(), isDirectory: true)
        if FileManager.default.fileExists(atPath: folder.path) {
            try FileManager.default.removeItem(at: folder)
        }
    }

    /// Removes every account's mail and the account list.
    func deleteAll() throws {
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    // MARK: Sealing

    private func seal<T: Encodable>(_ value: T, to url: URL) throws {
        let data = try Self.encoder.encode(value)
        guard let combined = try AES.GCM.seal(data, using: key).combined else {
            throw StoreError.unreadable(url.lastPathComponent)
        }
        let fileManager = FileManager.default
        let folder = url.deletingLastPathComponent()
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
        try combined.write(to: url, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func open<T: Decodable>(_ type: T.Type, at url: URL) throws -> T {
        guard let sealed = try? Data(contentsOf: url),
              let box = try? AES.GCM.SealedBox(combined: sealed),
              let data = try? AES.GCM.open(box, using: key),
              let value = try? Self.decoder.decode(type, from: data) else {
            throw StoreError.unreadable(url.lastPathComponent)
        }
        return value
    }
}
