import Foundation
import Security
import CryptoKit

enum AppIdentifiers {
    /// The release identity is frozen for existing libraries and Keychain items.
    static let appBundleID = "me.dotenv.LokalBot"

    enum Identity: String {
        case release = "me.dotenv.LokalBot"
        case development = "me.dotenv.LokalBot.dev"
        case uiTestHost = "me.dotenv.LokalBot.uitesthost"

        var bundleID: String { rawValue }
    }

    static var identity: Identity {
#if LOKALBOT_UI_TEST_HOST
        .uiTestHost
#elseif LOKALBOT_DEV
        .development
#else
        // The shared CLI target is embedded in both app variants. Resolve its
        // enclosing app even when invoked through the installed command symlink.
        identity(forExecutable: Bundle.main.executableURL,
                 bundleIdentifier: Bundle.main.bundleIdentifier)
#endif
    }

    static var bundleID: String { identity.bundleID }

    static func identity(forExecutable executable: URL?, bundleIdentifier: String?) -> Identity {
        if let bundleIdentifier, let identity = Identity(rawValue: bundleIdentifier) {
            return identity
        }
        var directory = executable?.resolvingSymlinksInPath().deletingLastPathComponent()
        while let candidate = directory, candidate.path != "/" {
            if candidate.pathExtension == "app",
               let identifier = Bundle(url: candidate)?.bundleIdentifier,
               let identity = Identity(rawValue: identifier) {
                return identity
            }
            directory = candidate.deletingLastPathComponent()
        }
        return .release
    }
}

enum UITestRuntime {
    static let enabledKey = "lokalbot.uiTest.enabled"
    static let storageRootKey = "lokalbot.uiTest.storageRoot"
    static let defaultsSuiteKey = "lokalbot.uiTest.defaultsSuite"
    private static let enabledArgument = "--lokalbot-ui-test"
    private static let storageRootArgument = "--lokalbot-storage-root"
    private static let defaultsSuiteArgument = "--lokalbot-defaults-suite"

    /// XCTest loads the production app as its host, so `LokalBotMain.main()` and
    /// `AppState` still run before the first test method. Keep that launch
    /// hermetic even when the caller did not provide the UI-test overrides.
    static var isUnitTesting: Bool {
        !isEnabled
            && ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    static var isEnabled: Bool {
#if LOKALBOT_UI_TEST_HOST
        true
#else
        ProcessInfo.processInfo.environment["LOKALBOT_UI_TEST"] == "1"
            || ProcessInfo.processInfo.arguments.contains(enabledArgument)
            || UserDefaults.standard.bool(forKey: enabledKey)
#endif
    }

    static var storageRoot: String? {
        nonEmpty(ProcessInfo.processInfo.environment["LOKALBOT_STORAGE_ROOT"])
            ?? argumentValue(after: storageRootArgument)
            ?? nonEmpty(UserDefaults.standard.string(forKey: storageRootKey))
            ?? unitTestStorageRoot
    }

    static var defaultsSuiteName: String? {
        nonEmpty(ProcessInfo.processInfo.environment["LOKALBOT_DEFAULTS_SUITE"])
            ?? argumentValue(after: defaultsSuiteArgument)
            ?? nonEmpty(UserDefaults.standard.string(forKey: defaultsSuiteKey))
            ?? unitTestDefaultsSuite
    }

    private static var unitTestStorageRoot: String? {
        guard isUnitTesting else { return nil }
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("lokalbot-unit-tests-\(ProcessInfo.processInfo.processIdentifier)",
                                    isDirectory: true)
            .path
    }

    private static var unitTestDefaultsSuite: String? {
        guard isUnitTesting else { return nil }
        return "me.dotenv.LokalBot.unit-tests.\(ProcessInfo.processInfo.processIdentifier)"
    }

    private static func argumentValue(after option: String) -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: option),
              arguments.indices.contains(arguments.index(after: index)) else {
            return nil
        }
        return nonEmpty(arguments[arguments.index(after: index)])
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}

enum KeychainSecrets {
    struct EncryptionKeyOperations {
        let read: (_ service: String, _ account: String) -> (status: OSStatus, data: Data?)
        let add: (_ service: String, _ account: String, _ data: Data) -> OSStatus
    }

    enum EncryptionKeyFailure: LocalizedError, Equatable {
        case operation(String, account: String, status: OSStatus)
        case invalidData(account: String)
        case verification(account: String)

        var errorDescription: String? {
            switch self {
            case .operation(let operation, let account, let status):
                let detail = SecCopyErrorMessageString(status, nil) as String?
                    ?? "status \(status)"
                return "Could not \(operation) the \(account) Keychain item (\(detail))."
            case .invalidData(let account):
                return "The \(account) Keychain item does not contain a valid AES-256 key."
            case .verification(let account):
                return "The \(account) Keychain item could not be verified after saving."
            }
        }
    }

    private static let liveEncryptionKeyOperations = EncryptionKeyOperations(
        read: { service, account in
            var query = baseQuery(service: service, account: account)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var existing: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &existing)
            return (status, existing as? Data)
        },
        add: { service, account, data in
            var query = baseQuery(service: service, account: account)
            query[kSecValueData as String] = data
            return SecItemAdd(query as CFDictionary, nil)
        })

    static func string(account: String) -> String? {
        guard let data = data(account: account) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func data(account: String) -> Data? {
        data(service: AppIdentifiers.bundleID, account: account)
    }

    static func setString(_ value: String, account: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            delete(account: account)
        } else {
            set(Data(trimmed.utf8), account: account)
        }
    }

    static func set(_ data: Data, account: String) {
        let query = baseQuery(service: AppIdentifiers.bundleID, account: account)
        let update = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    static func delete(account: String) {
        SecItemDelete(baseQuery(service: AppIdentifiers.bundleID, account: account) as CFDictionary)
    }

    private static func data(service: String, account: String) -> Data? {
        var query = baseQuery(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var existing: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &existing) == errSecSuccess else {
            return nil
        }
        return existing as? Data
    }

    private static func baseQuery(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    /// A per-install AES-256 key for `account`, generated on first use and
    /// stored in the Keychain (design §3.4). Used to seal at-rest data —
    /// screenshots (`screenshot-key`) and chat history (`chat-key`) — with
    /// `AES.GCM`. Cached in-process per account; `@MainActor` because the cache
    /// is shared mutable state and every caller already runs on the main actor.
    @MainActor private static var symmetricKeyCache: [String: SymmetricKey] = [:]
    @MainActor static func symmetricKey(account: String) throws -> SymmetricKey {
        if let cached = symmetricKeyCache[account] { return cached }
#if LOKALBOT_UI_TEST_HOST
        if UITestRuntime.isEnabled {
            let digest = SHA256.hash(data: Data("lokalbot-ui-test-\(account)".utf8))
            let key = SymmetricKey(data: Data(digest))
            symmetricKeyCache[account] = key
            return key
        }
#endif
        let key = try resolveSymmetricKey(
            account: account,
            operations: liveEncryptionKeyOperations)
        symmetricKeyCache[account] = key
        return key
    }

    /// Loads the existing AES-256 key or atomically creates it on first use.
    /// Existing items are never updated: a temporary read failure must not be
    /// mistaken for absence, and a concurrent creator wins without replacement.
    static func resolveSymmetricKey(
        account: String,
        operations: EncryptionKeyOperations
    ) throws -> SymmetricKey {
        if let existing = try encryptionKeyData(account: account, operations: operations) {
            return SymmetricKey(data: existing)
        }

        let proposedKey = SymmetricKey(size: .bits256)
        let proposedData = proposedKey.withUnsafeBytes { Data($0) }
        let addStatus = operations.add(AppIdentifiers.bundleID, account, proposedData)
        if addStatus == errSecDuplicateItem {
            guard let existing = try encryptionKeyData(
                account: account,
                operations: operations
            ) else {
                throw EncryptionKeyFailure.verification(account: account)
            }
            return SymmetricKey(data: existing)
        }
        guard addStatus == errSecSuccess else {
            throw EncryptionKeyFailure.operation("save", account: account, status: addStatus)
        }
        guard try encryptionKeyData(account: account, operations: operations) == proposedData else {
            throw EncryptionKeyFailure.verification(account: account)
        }
        return proposedKey
    }

    private static func encryptionKeyData(
        account: String,
        operations: EncryptionKeyOperations
    ) throws -> Data? {
        let result = operations.read(AppIdentifiers.bundleID, account)
        if result.status == errSecItemNotFound { return nil }
        guard result.status == errSecSuccess else {
            throw EncryptionKeyFailure.operation(
                "read", account: account, status: result.status)
        }
        guard let data = result.data, data.count == 32 else {
            throw EncryptionKeyFailure.invalidData(account: account)
        }
        return data
    }
}
