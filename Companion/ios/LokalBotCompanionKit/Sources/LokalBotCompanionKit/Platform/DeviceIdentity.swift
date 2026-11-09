import Foundation
import Security

/// This device's long-term X25519 private key and its device id, kept in the
/// Keychain for this device only: available after first unlock (so background
/// refresh can sync) and never synchronized to other devices.
public enum DeviceIdentity {
    static let service = "me.dotenv.LokalBot.companion"
    static let keyAccount = "device-static-key"
    static let idAccount = "device-id"

    public enum KeychainError: Error, LocalizedError {
        case status(OSStatus)

        public var errorDescription: String? {
            switch self {
            case .status(let status):
                (SecCopyErrorMessageString(status, nil) as String?) ?? "Keychain error \(status)"
            }
        }
    }

    /// The stored private key, or a new one from `generate` (the sync core's
    /// `generateStaticKey()`), saved before it is returned.
    public static func privateKey(generate: () throws -> Data) throws -> Data {
        if let existing = try read(keyAccount) { return existing }
        let key = try generate()
        try write(key, account: keyAccount)
        return key
    }

    public static func deviceID() throws -> String {
        if let data = try read(idAccount), let id = String(data: data, encoding: .utf8) { return id }
        let id = UUID().uuidString.lowercased()
        try write(Data(id.utf8), account: idAccount)
        return id
    }

    private static func baseQuery(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account,
         kSecAttrSynchronizable as String: false,
         kSecUseDataProtectionKeychain as String: true]
    }

    private static func read(_ account: String) throws -> Data? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess: return item as? Data
        case errSecItemNotFound: return nil
        default: throw KeychainError.status(status)
        }
    }

    private static func write(_ data: Data, account: String) throws {
        var query = baseQuery(account)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.status(status) }
    }
}

/// Where the phone keeps its copy: Application Support, protected until the
/// first unlock after a restart, and left out of device backups because the
/// Mac can always send it again.
public enum CompanionStorage {
    public static func directory() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                               appropriateFor: nil, create: true)
        var directory = base.appendingPathComponent("LokalBot", isDirectory: true)
        if !FileManager.default.fileExists(atPath: directory.path) {
            var attributes: [FileAttributeKey: Any] = [:]
            #if os(iOS)
            attributes[.protectionKey] = FileProtectionType.completeUntilFirstUserAuthentication
            #endif
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: attributes)
        }
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
        return directory
    }

    public static func databaseURL() throws -> URL {
        try directory().appendingPathComponent("companion.sqlite")
    }

    /// Bytes used by the local copy, for Settings.
    public static func usedBytes() -> Int64 {
        guard let directory = try? directory(),
              let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in files {
            total += Int64((try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
        }
        return total
    }
}
