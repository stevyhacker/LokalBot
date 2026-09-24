import Foundation
import Security
import Darwin
import SQLite3

/// One-shot migrations from previous LokalBot identities to the current app id.
///
/// Bundle-id renames re-key every identity-scoped store at once:
///   • the Application Support data dir   (`~/Library/Application Support/<bundle id>/`)
///   • the login Keychain                 (service == bundle id)
///   • UserDefaults                       (the per-bundle-id preference domain)
///
/// Without migration a rename would look like total data loss: an empty library,
/// reset settings, and — worst — screenshots that can no longer be decrypted
/// because the AES key lived under the old service. This copies all three forward
/// on first launch after a rename.
///
/// MUST run at the very top of process `main()` — before `AppSettings.load()`,
/// `StorageManager()`, or any Keychain read — so the current stores observe
/// migrated values and `StorageManager` doesn't create an empty dir first.
///
/// The embedded `lokalbot-cli` is a separate binary and does NOT run this; it
/// reads whatever the app has already migrated. The normal flow launches the app
/// (which migrates) before the CLI is used.
enum DataMigration {

    // MARK: Old identities. Keep these frozen; changing them would strand data.
    private static let oldV2BundleID = "com.dotenv.LokalBotV2"
    private static let oldV2SettingsKey = "lokalbotv2.settings"
    private static let oldV2OnboardingKey = "lokalbotv2.onboarding.shown"
    private static let oldV2DBName = "lokalbotv2.sqlite"
    private static let oldV3BundleID = ["com", "dotenv", "LokalBotV3"].joined(separator: ".")

    /// New DB filename — mirrors the `databaseURL` built in `AppState`.
    private static let currentDBName = "lokalbotv3.sqlite"

    /// Generic-password accounts to carry over (service is the bundle id).
    /// `screenshot-key` is the AES-GCM key that decrypts the screenshot filmstrip
    /// — losing it makes existing shots unreadable, so it matters most.
    private static let keychainAccounts = ["screenshot-key", "openai-compatible-api-key"]

    /// Set only after every migration phase succeeds. Retained conflicting
    /// libraries and failed operations remain recoverable on later launches.
    private static let migratedFromV2Flag = "lokalbotv3.migratedFromV2"
    private static let migratedFromV3Flag = "lokalbot.migratedFromDotenvV3"

    /// Migrate old libraries/settings/secrets into the current identity exactly once.
    static func runIfNeeded(environment: [String: String] = ProcessInfo.processInfo.environment,
                            defaults: UserDefaults = .standard,
                            identity: AppIdentifiers.Identity = AppIdentifiers.identity,
                            arguments: [String] = ProcessInfo.processInfo.arguments) {
        guard shouldRun(environment: environment, defaults: defaults,
                        identity: identity, arguments: arguments) else { return }

        let appSupport = AppDirectories.userApplicationSupport
        let currentDir = AppDirectories.applicationSupport

        migrateFromV3IfNeeded(appSupport: appSupport, currentDir: currentDir, defaults: defaults)
        migrateFromV2IfNeeded(appSupport: appSupport, currentDir: currentDir, defaults: defaults)
    }

    static func shouldRun(environment: [String: String], defaults: UserDefaults,
                          identity: AppIdentifiers.Identity, arguments: [String]) -> Bool {
        // Legacy identities belong to the release app. A fresh Dev launch must
        // never acquire or move the release library and its retention authority.
        guard identity == .release else { return false }
        // A unit-test run launches the app as its XCTest host, which still
        // executes main() — never let `xcodebuild test` move the real user
        // library. XCTest sets XCTestConfigurationFilePath in that process.
        if environment["XCTestConfigurationFilePath"] != nil { return false }
        // Never migrate under a UI-test / storage-isolation launch either: those
        // point storage at a throwaway dir, so there's no real library to move.
        if let root = environment["LOKALBOT_STORAGE_ROOT"], !root.isEmpty { return false }
        if let root = defaults.string(forKey: UITestRuntime.storageRootKey), !root.isEmpty { return false }
        if arguments.contains("--lokalbot-storage-root") { return false }
        if environment["LOKALBOT_UI_TEST"] == "1"
            || defaults.bool(forKey: UITestRuntime.enabledKey)
            || arguments.contains("--lokalbot-ui-test") {
            return false
        }
        return true
    }

    private static func migrateFromV3IfNeeded(appSupport: URL, currentDir: URL, defaults: UserDefaults) {
        guard !defaults.bool(forKey: migratedFromV3Flag) else { return }
        let oldDir = appSupport.appendingPathComponent(oldV3BundleID, isDirectory: true)
        guard !hasDatabaseConflict(from: oldDir, to: currentDir, fileManager: .default) else { return }
        completeMigration(marker: migratedFromV3Flag, defaults: defaults) {
            try migrateDataDirChecked(
                from: oldDir,
                to: currentDir, renamesDatabase: false,
                mergeIfDestinationExists: true, replacePlaceholderDatabase: true)
        } migratePreferences: {
            if let old = UserDefaults(suiteName: oldV3BundleID) {
                migrateSettings(from: old, to: defaults,
                                settingsKey: AppSettings.key,
                                onboardingKey: AppState.onboardingShownKey)
            }
        } migrateSecrets: {
            try migrateKeychain(from: oldV3BundleID, to: AppIdentifiers.bundleID)
        }
    }

    private static func migrateFromV2IfNeeded(appSupport: URL, currentDir: URL, defaults: UserDefaults) {
        guard !defaults.bool(forKey: migratedFromV2Flag) else { return }
        let oldDir = appSupport.appendingPathComponent(oldV2BundleID, isDirectory: true)
        if FileManager.default.fileExists(atPath: oldDir.path),
           FileManager.default.fileExists(atPath: currentDir.path) { return }
        completeMigration(marker: migratedFromV2Flag, defaults: defaults) {
            try migrateDataDirChecked(from: oldDir, to: currentDir)
        } migratePreferences: {
            if let old = UserDefaults(suiteName: oldV2BundleID) {
                migrateSettings(from: old, to: defaults)
            }
        } migrateSecrets: {
            try migrateKeychain(from: oldV2BundleID, to: AppIdentifiers.bundleID)
        }
    }

    enum MigrationResult { case unchanged, migrated, preservedConflict }

    /// Separate phase completion from whether any files happened to move.
    /// Injection keeps failure tests away from the user's library and Keychain.
    static func completeMigration(marker: String, defaults: UserDefaults,
                                  migrateData: () throws -> MigrationResult,
                                  migratePreferences: () throws -> Void,
                                  migrateSecrets: () throws -> Void) {
        do {
            // Prepare identity-scoped keys before exposing migrated encrypted
            // files. A denied Keychain read must leave the old library in place.
            try migratePreferences()
            try migrateSecrets()
            guard try migrateData() != .preservedConflict else { return }
            defaults.set(true, forKey: marker)
        } catch {
            NSLog("DataMigration: incomplete migration; retained data for recovery: %@", error.localizedDescription)
        }
    }

    // MARK: - Data directory

    /// Move the whole V2 library to the V3 location and version-rename the DB.
    /// A move (atomic rename on the same volume) — not a copy — so the multi-GB
    /// model cache isn't duplicated; the V2 keychain secrets are left intact as a
    /// fallback. No-op if there's no V2 library or a V3 one already exists.
    @discardableResult
    static func migrateDataDir(from oldDir: URL, to newDir: URL,
                               renamesDatabase: Bool = true,
                               mergeIfDestinationExists: Bool = false,
                               replacePlaceholderDatabase: Bool = false,
                               fileManager fm: FileManager = .default) -> Bool {
        do {
            return try migrateDataDirChecked(
                from: oldDir, to: newDir, renamesDatabase: renamesDatabase,
                mergeIfDestinationExists: mergeIfDestinationExists,
                replacePlaceholderDatabase: replacePlaceholderDatabase, fileManager: fm) == .migrated
        } catch {
            NSLog("DataMigration: retained library after migration failed: %@", error.localizedDescription)
            return false
        }
    }

    /// `replacePlaceholderDatabase` is a legacy option name. It now permits
    /// import only when no destination database exists; an empty live database
    /// is still owned by its current connections and is never replaced.
    static func migrateDataDirChecked(from oldDir: URL, to newDir: URL,
                                      renamesDatabase: Bool = true,
                                      mergeIfDestinationExists: Bool = false,
                                      replacePlaceholderDatabase: Bool = false,
                                      fileManager fm: FileManager = .default) throws -> MigrationResult {
        guard fm.fileExists(atPath: oldDir.path) else { return .unchanged }
        if fm.fileExists(atPath: newDir.path) {
            guard mergeIfDestinationExists else { return .preservedConflict }
            return try mergeDataDir(from: oldDir, to: newDir,
                                    replacePlaceholderDatabase: replacePlaceholderDatabase,
                                    fileManager: fm)
        }
        try fm.moveItem(at: oldDir, to: newDir)
        guard renamesDatabase else { return .migrated }
        // The DB filename embeds the version; rename the file and its WAL/SHM
        // sidecars so the current app opens the existing index instead of a fresh one.
        let renames = [(oldV2DBName, currentDBName)] + ["-wal", "-shm"].map { (oldV2DBName + $0, currentDBName + $0) }
        var renamed: [(URL, URL)] = []
        do {
            for (old, new) in renames {
                let src = newDir.appendingPathComponent(old)
                guard fm.fileExists(atPath: src.path) else { continue }
                let destination = newDir.appendingPathComponent(new)
                try fm.moveItem(at: src, to: destination)
                renamed.append((src, destination))
            }
        } catch {
            // Restore the old names before putting the whole library back. If
            // recovery itself fails the files still remain in the new directory.
            for (source, destination) in renamed.reversed() {
                try? fm.moveItem(at: destination, to: source)
            }
            try? fm.moveItem(at: newDir, to: oldDir)
            throw error
        }
        return .migrated
    }

    @discardableResult
    private static func mergeDataDir(from oldDir: URL, to newDir: URL,
                                     replacePlaceholderDatabase: Bool,
                                     fileManager fm: FileManager) throws -> MigrationResult {
        var migrated = false
        if replacePlaceholderDatabase && hasDatabaseConflict(from: oldDir, to: newDir, fileManager: fm) {
            // Preserve its assets alongside a conflicting legacy database. A
            // partial merge would make that retained library hard to recover.
            return .preservedConflict
        }
        let items = try fm.contentsOfDirectory(at: oldDir,
                                               includingPropertiesForKeys: [.isDirectoryKey],
                                               options: [.skipsHiddenFiles])
        let databaseNames = [currentDBName, currentDBName + "-wal", currentDBName + "-shm", currentDBName + "-journal"]
        for item in items {
            if replacePlaceholderDatabase && databaseNames.contains(item.lastPathComponent) { continue }
            let destination = newDir.appendingPathComponent(item.lastPathComponent)
            migrated = try copyMissingItem(from: item, to: destination, fileManager: fm) || migrated
        }
        if replacePlaceholderDatabase {
            // Install the database last. The source stays intact throughout a
            // merge, including when a concurrent writer creates the destination.
            let result = try importDatabaseIfMissing(from: oldDir, to: newDir, fileManager: fm)
            guard result != .preservedConflict else { return result }
            migrated = result == .migrated || migrated
        }
        return migrated ? .migrated : .unchanged
    }

    @discardableResult
    private static func copyMissingItem(from source: URL, to destination: URL, fileManager fm: FileManager) throws -> Bool {
        var sourceIsDirectory = ObjCBool(false)
        guard fm.fileExists(atPath: source.path, isDirectory: &sourceIsDirectory) else { return false }

        var destinationIsDirectory = ObjCBool(false)
        guard fm.fileExists(atPath: destination.path, isDirectory: &destinationIsDirectory) else {
            try fm.copyItem(at: source, to: destination)
            return true
        }

        guard sourceIsDirectory.boolValue && destinationIsDirectory.boolValue else { return false }
        let children = try fm.contentsOfDirectory(at: source,
                                                  includingPropertiesForKeys: [.isDirectoryKey],
                                                  options: [.skipsHiddenFiles])
        var migrated = false
        for child in children {
            migrated = try copyMissingItem(from: child,
                                           to: destination.appendingPathComponent(child.lastPathComponent),
                                           fileManager: fm) || migrated
        }
        return migrated
    }

    @discardableResult
    private static func importDatabaseIfMissing(from oldDir: URL, to newDir: URL,
                                                fileManager fm: FileManager) throws -> MigrationResult {
        let oldDB = oldDir.appendingPathComponent(currentDBName)
        let newDB = newDir.appendingPathComponent(currentDBName)
        guard fm.fileExists(atPath: oldDB.path) else { return .unchanged }
        guard !databaseFilesExist(at: newDB, fileManager: fm) else {
            return .preservedConflict
        }
        let backupDirectory = newDir.appendingPathComponent(".migration-backups", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: backupDirectory, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        let incoming = backupDirectory.appendingPathComponent("incoming.sqlite")
        guard let legacy = SQLiteDatabase(url: oldDB, readOnly: true) else {
            throw SQLiteDatabase.DatabaseError.unavailable(path: oldDB.path)
        }
        // SQLite's backup API includes committed WAL content and does not move
        // or checkpoint the old database. If installation fails, both the
        // source library and this recovery snapshot remain available.
        try legacy.backup(to: incoming)
        guard let snapshot = SQLiteDatabase(url: incoming, readOnly: true),
              try snapshot.queryChecked("PRAGMA quick_check", row: {
                  sqlite3_column_text($0, 0).map { String(cString: $0) }
              }) == ["ok"] else {
            throw SQLiteDatabase.DatabaseError.backup(code: SQLITE_CORRUPT,
                                                      message: "legacy snapshot failed its integrity check")
        }
        return try installDatabaseSnapshot(from: incoming, to: newDB) ? .migrated : .preservedConflict
    }

    /// Do not replace even an apparently empty current database. An independent
    /// SQLite connection can commit immediately after an emptiness check, and
    /// replacing its inode separates that writer from the active library path.
    /// RENAME_EXCL makes creation atomic: a concurrent creator wins unchanged.
    static func installDatabaseSnapshot(from source: URL, to destination: URL) throws -> Bool {
        if renamex_np(source.path, destination.path, UInt32(RENAME_EXCL)) == 0 { return true }
        let errorCode = errno
        if errorCode == EEXIST { return false }
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errorCode),
                      userInfo: [NSFilePathErrorKey: destination.path])
    }

    private static func hasDatabaseConflict(from oldDir: URL, to newDir: URL,
                                            fileManager fm: FileManager) -> Bool {
        let oldDB = oldDir.appendingPathComponent(currentDBName)
        guard fm.fileExists(atPath: oldDB.path), fm.fileExists(atPath: newDir.path) else { return false }
        return databaseFilesExist(at: newDir.appendingPathComponent(currentDBName), fileManager: fm)
    }

    private static func databaseFilesExist(at url: URL, fileManager fm: FileManager) -> Bool {
        // Orphaned sidecars also require recovery rather than a new main file.
        ["", "-wal", "-shm", "-journal"].contains {
            fm.fileExists(atPath: url.path + $0)
        }
    }

    // MARK: - UserDefaults

    /// Copy the encoded settings blob (raw — the Codable shape is unchanged by the
    /// rename) and the "onboarding shown" flag so a migrated user keeps their
    /// preferences and isn't re-onboarded.
    static func migrateSettings(from old: UserDefaults, to new: UserDefaults,
                                settingsKey: String = oldV2SettingsKey,
                                onboardingKey: String = oldV2OnboardingKey) {
        if new.data(forKey: AppSettings.key) == nil,
           let data = old.data(forKey: settingsKey) {
            new.set(data, forKey: AppSettings.key)
        }
        if old.bool(forKey: onboardingKey) {
            new.set(true, forKey: AppState.onboardingShownKey)
        }
    }

    // MARK: - Keychain

    /// Re-home each generic-password secret under the new service. The cross-app
    /// read of a V2-created item triggers a one-time macOS "allow access" dialog;
    /// once copied, the V3 app owns its own item and reads it silently. Reads are
    /// non-destructive — the V2 items survive as a fallback.
    static func migrateKeychain(from oldService: String, to newService: String) throws {
        for account in keychainAccounts {
            guard try readData(service: newService, account: account) == nil,
                  let data = try readData(service: oldService, account: account) else { continue }
            try writeData(data, service: newService, account: account)
        }
    }

    private struct KeychainMigrationError: LocalizedError {
        let status: OSStatus
        var errorDescription: String? { "Keychain migration failed (status \(status))." }
    }

    private static func baseQuery(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private static func readData(service: String, account: String) throws -> Data? {
        var query = baseQuery(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainMigrationError(status: status) }
        guard let data = out as? Data else { throw KeychainMigrationError(status: errSecDecode) }
        return data
    }

    private static func writeData(_ data: Data, service: String, account: String) throws {
        var query = baseQuery(service: service, account: account)
        query[kSecValueData as String] = data
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess || status == errSecDuplicateItem else {
            throw KeychainMigrationError(status: status)
        }
        // A concurrently created current item wins; never replace an existing
        // encryption key after a transient read error or a create race.
        guard try readData(service: service, account: account) != nil else {
            throw KeychainMigrationError(status: errSecItemNotFound)
        }
    }
}
