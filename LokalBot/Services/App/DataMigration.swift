import Foundation
import CryptoKit
import Security
import Darwin
import SQLite3

enum DataMigration {

    private static let oldV2BundleID = "com.dotenv.LokalBotV2"
    private static let oldV2SettingsKey = "lokalbotv2.settings"
    private static let oldV2OnboardingKey = "lokalbotv2.onboarding.shown"
    private static let oldV2DBName = "lokalbotv2.sqlite"
    private static let oldV3BundleID = ["com", "dotenv", "LokalBotV3"].joined(separator: ".")

    private static let currentDBName = "lokalbotv3.sqlite"

    private static let keychainAccounts = ["screenshot-key", "chat-key", "openai-compatible-api-key"]

    private static let migratedFromV2Flag = "lokalbotv3.migratedFromV2"
    private static let migratedFromV3Flag = "lokalbot.migratedFromDotenvV3"
    private static let recoveredChatKeyFlag = "lokalbot.recoveredLegacyChatKey.v1"
    private static let recoveredScreenshotKeyFlag = "lokalbot.recoveredLegacyScreenshotKey.v1"

    struct MigrationConflict: Equatable {
        var legacyDirectory: URL
        var currentDirectory: URL
        var identity: String
    }

    enum StartupOutcome: Equatable {
        case ready
        case retryRequired(String)
        case conflict(MigrationConflict)
    }

    enum MigrationAttempt: Equatable {
        case completed
        case retryRequired(String)
        case preservedConflict
    }

    struct SecretStore {
        var read: (_ service: String, _ account: String) throws -> Data?
        var write: (_ data: Data, _ service: String, _ account: String) throws -> Void

        static let live = SecretStore(
            read: { try readData(service: $0, account: $1) },
            write: { try writeData($0, service: $1, account: $2) })
    }

    @discardableResult
    static func runIfNeeded(environment: [String: String] = ProcessInfo.processInfo.environment,
                            defaults: UserDefaults = .standard,
                            identity: AppIdentifiers.Identity = AppIdentifiers.identity,
                            arguments: [String] = ProcessInfo.processInfo.arguments,
                            appSupport: URL = AppDirectories.userApplicationSupport,
                            currentDirectory: URL = AppDirectories.applicationSupport,
                            secrets: SecretStore = .live) -> StartupOutcome {
        guard shouldRun(environment: environment, defaults: defaults,
                        identity: identity, arguments: arguments) else { return .ready }
        return migrate(appSupport: appSupport, currentDirectory: currentDirectory,
                       defaults: defaults, secrets: secrets)
    }

    static func migrate(appSupport: URL, currentDirectory: URL,
                        defaults: UserDefaults, secrets: SecretStore) -> StartupOutcome {
        let currentDir = currentDirectory
        let oldV3Dir = appSupport.appendingPathComponent(oldV3BundleID, isDirectory: true)
        let oldV2Dir = appSupport.appendingPathComponent(oldV2BundleID, isDirectory: true)

        let v3 = migrateFromV3IfNeeded(
            oldDir: oldV3Dir, currentDir: currentDir, defaults: defaults,
            secrets: secrets)
        guard v3 == .ready else { return v3 }
        let v2 = migrateFromV2IfNeeded(
            oldDir: oldV2Dir, currentDir: currentDir, defaults: defaults,
            secrets: secrets)
        guard v2 == .ready else { return v2 }
        let screenshotRecovery = recoverLegacyScreenshotKeyIfNeeded(
            currentDir: currentDir,
            legacyDirectories: [oldV3Dir, oldV2Dir],
            defaults: defaults,
            secrets: secrets)
        guard screenshotRecovery == .ready else { return screenshotRecovery }
        return recoverLegacyChatKeyIfNeeded(
            currentDir: currentDir, defaults: defaults, secrets: secrets)
    }

    static func shouldRun(environment: [String: String], defaults: UserDefaults,
                          identity: AppIdentifiers.Identity, arguments: [String]) -> Bool {
        guard identity == .release else { return false }
        if environment["XCTestConfigurationFilePath"] != nil { return false }
        if let root = environment["LOKALBOT_STORAGE_ROOT"], !root.isEmpty { return false }
        if let root = defaults.string(forKey: UITestRuntime.storageRootKey), !root.isEmpty { return false }
        if arguments.contains("--lokalbot-storage-root") { return false }
        if environment["LOKALBOT_UI_TEST"] == "1"
            || defaults.bool(forKey: UITestRuntime.enabledKey)
            || arguments.contains("--lokalbot-ui-test") {
            return false
        }
        if UITestRuntime.isLocalBuild { return false }
        return true
    }

    private static func migrateFromV3IfNeeded(
        oldDir: URL,
        currentDir: URL,
        defaults: UserDefaults,
        secrets: SecretStore
    ) -> StartupOutcome {
        guard !defaults.bool(forKey: migratedFromV3Flag) else { return .ready }
        let attempt = completeMigration(marker: migratedFromV3Flag, defaults: defaults) {
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
            try migrateKeychain(
                from: oldV3BundleID, to: AppIdentifiers.bundleID,
                secrets: secrets)
        }
        return startupOutcome(
            for: attempt,
            identity: "the previous LokalBot identity",
            oldDir: oldDir,
            currentDir: currentDir)
    }

    private static func migrateFromV2IfNeeded(
        oldDir: URL,
        currentDir: URL,
        defaults: UserDefaults,
        secrets: SecretStore
    ) -> StartupOutcome {
        guard !defaults.bool(forKey: migratedFromV2Flag) else { return .ready }
        let attempt = completeMigration(marker: migratedFromV2Flag, defaults: defaults) {
            try migrateDataDirChecked(from: oldDir, to: currentDir)
        } migratePreferences: {
            if let old = UserDefaults(suiteName: oldV2BundleID) {
                migrateSettings(from: old, to: defaults)
            }
        } migrateSecrets: {
            try migrateKeychain(
                from: oldV2BundleID, to: AppIdentifiers.bundleID,
                secrets: secrets)
        }
        return startupOutcome(
            for: attempt,
            identity: "LokalBot V2",
            oldDir: oldDir,
            currentDir: currentDir)
    }

    private static func startupOutcome(
        for attempt: MigrationAttempt,
        identity: String,
        oldDir: URL,
        currentDir: URL
    ) -> StartupOutcome {
        switch attempt {
        case .completed:
            .ready
        case .retryRequired(let reason):
            .retryRequired(reason)
        case .preservedConflict:
            .conflict(MigrationConflict(
                legacyDirectory: oldDir,
                currentDirectory: currentDir,
                identity: identity))
        }
    }

    enum MigrationResult { case unchanged, migrated, preservedConflict }

    @discardableResult
    static func completeMigration(marker: String, defaults: UserDefaults,
                                  migrateData: () throws -> MigrationResult,
                                  migratePreferences: () throws -> Void,
                                  migrateSecrets: () throws -> Void) -> MigrationAttempt {
        do {
            try migratePreferences()
            try migrateSecrets()
            guard try migrateData() != .preservedConflict else {
                return .preservedConflict
            }
            defaults.set(true, forKey: marker)
            return .completed
        } catch {
            NSLog("DataMigration: incomplete migration; retained data for recovery: %@", error.localizedDescription)
            return .retryRequired(error.localizedDescription)
        }
    }

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
        ["", "-wal", "-shm", "-journal"].contains {
            fm.fileExists(atPath: url.path + $0)
        }
    }

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

    static func migrateKeychain(from oldService: String, to newService: String,
                                secrets: SecretStore = .live) throws {
        for account in keychainAccounts {
            guard try secrets.read(newService, account) == nil,
                  let data = try secrets.read(oldService, account) else { continue }
            if account == "chat-key" || account == "screenshot-key" {
                guard data.count == 32 else {
                    throw EncryptionKeyRecoveryError.invalidKey(
                        account: account, service: oldService)
                }
            }
            try secrets.write(data, newService, account)
        }
    }

    private static func recoverLegacyScreenshotKeyIfNeeded(
        currentDir: URL,
        legacyDirectories: [URL],
        defaults: UserDefaults,
        secrets: SecretStore
    ) -> StartupOutcome {
        let migrationsComplete = defaults.bool(forKey: migratedFromV2Flag)
            && defaults.bool(forKey: migratedFromV3Flag)
        guard !defaults.bool(forKey: recoveredScreenshotKeyFlag) || !migrationsComplete else {
            return .ready
        }

        do {
            let databaseURL = currentDir.appendingPathComponent(currentDBName)
            let pathPlan = try screenshotPathPlan(
                databaseURL: databaseURL,
                currentDirectory: currentDir,
                legacyDirectories: legacyDirectories)
            let discoveredFiles = try encryptedScreenshotFiles(in: currentDir)
            let screenshotFiles = uniqueFiles(pathPlan.files + discoveredFiles)
            var rewritePlan: [(url: URL, data: Data)] = []
            if !screenshotFiles.isEmpty {
                let currentService = AppIdentifiers.bundleID
                var current = try secrets.read(currentService, "screenshot-key")
                if let current, current.count != 32 {
                    throw EncryptionKeyRecoveryError.invalidKey(
                        account: "screenshot-key", service: currentService)
                }
                let legacy = try [oldV3BundleID, oldV2BundleID].compactMap { service -> Data? in
                    guard let data = try secrets.read(service, "screenshot-key") else { return nil }
                    guard data.count == 32 else {
                        NSLog("DataMigration: ignored invalid legacy screenshot key for service %@", service)
                        return nil
                    }
                    return data
                }
                if current == nil, let preferred = legacy.first {
                    try secrets.write(preferred, currentService, "screenshot-key")
                    current = try secrets.read(currentService, "screenshot-key")
                }
                guard let current else {
                    throw EncryptionKeyRecoveryError.missingKey(account: "screenshot-key")
                }
                rewritePlan = try encryptedScreenshotRewritePlan(
                    files: screenshotFiles,
                    currentKeyData: current,
                    legacyKeyData: legacy)
            }

            let pathDatabase = try writableDatabase(
                at: databaseURL, required: !pathPlan.updates.isEmpty)
            try verifyScreenshotPathPlan(pathPlan, database: pathDatabase)
            for rewrite in rewritePlan {
                try rewrite.data.write(to: rewrite.url, options: .atomic)
            }
            try applyScreenshotPathPlan(pathPlan, database: pathDatabase)
            defaults.set(true, forKey: recoveredScreenshotKeyFlag)
            return .ready
        } catch {
            let reason = "Screenshot recovery is incomplete: \(error.localizedDescription)"
            NSLog("DataMigration: %@", reason)
            return .retryRequired(reason)
        }
    }

    private enum EncryptionKeyRecoveryError: LocalizedError {
        case invalidKey(account: String, service: String)
        case missingKey(account: String)
        case unreadableFile(String, account: String)
        case unavailableDatabase(String)
        case relativeScreenshotPath(String)
        case externalScreenshotPath(String)
        case missingScreenshotFile(String)
        case ambiguousScreenshotPath(String)
        case duplicateScreenshotDestination(String)
        case changedScreenshotPath(Int64)

        var errorDescription: String? {
            switch self {
            case .invalidKey(let account, let service):
                "Invalid \(account) encryption key under service \(service)."
            case .missingKey(let account):
                "Encrypted data exists but no current or legacy \(account) is available."
            case .unreadableFile(let name, let account):
                "Encrypted file \(name) cannot be opened with any known \(account)."
            case .unavailableDatabase(let path):
                "The migrated screenshot database cannot be opened at \(path)."
            case .relativeScreenshotPath(let path):
                "Screenshot path is relative and cannot be migrated safely: \(path)"
            case .externalScreenshotPath(let path):
                "Screenshot path is outside the current and legacy libraries: \(path)"
            case .missingScreenshotFile(let path):
                "A screenshot row has no file at its migrated destination: \(path)"
            case .ambiguousScreenshotPath(let path):
                "Screenshot path matches more than one library root: \(path)"
            case .duplicateScreenshotDestination(let path):
                "More than one screenshot row resolves to the same file: \(path)"
            case .changedScreenshotPath(let id):
                "Screenshot path changed during migration for row \(id)."
            }
        }
    }

    private struct ScreenshotPathUpdate {
        var id: Int64
        var original: String
        var destination: String
    }

    private struct ScreenshotPathPlan {
        var files: [URL]
        var updates: [ScreenshotPathUpdate]
    }

    private static func screenshotPathPlan(
        databaseURL: URL,
        currentDirectory: URL,
        legacyDirectories: [URL],
        fileManager fm: FileManager = .default
    ) throws -> ScreenshotPathPlan {
        guard fm.fileExists(atPath: databaseURL.path) else {
            return ScreenshotPathPlan(files: [], updates: [])
        }
        guard let database = SQLiteDatabase(url: databaseURL, readOnly: true) else {
            throw EncryptionKeyRecoveryError.unavailableDatabase(databaseURL.path)
        }
        let hasScreenshots = try database.queryChecked(
            "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'screenshots' LIMIT 1",
            row: { sqlite3_column_int($0, 0) }).first != nil
        guard hasScreenshots else {
            return ScreenshotPathPlan(files: [], updates: [])
        }

        let rows: [(Int64, String)] = try database.queryChecked(
            "SELECT id, path FROM screenshots WHERE path != '' ORDER BY id",
            row: { statement in
                guard let rawPath = sqlite3_column_text(statement, 1) else { return nil }
                return (sqlite3_column_int64(statement, 0), String(cString: rawPath))
            })
        let currentRoot = currentDirectory.standardizedFileURL
        let legacyRoots = legacyDirectories.map(\.standardizedFileURL)
        var files: [URL] = []
        var updates: [ScreenshotPathUpdate] = []
        var destinationOwners: [String: Int64] = [:]

        for (id, storedPath) in rows {
            guard storedPath.hasPrefix("/") else {
                throw EncryptionKeyRecoveryError.relativeScreenshotPath(storedPath)
            }
            let source = URL(fileURLWithPath: storedPath).standardizedFileURL
            let roots = [currentRoot] + legacyRoots
            let matches = roots.enumerated().compactMap { index, root -> (Int, String)? in
                guard let relative = relativePath(of: source, under: root) else { return nil }
                return (index, relative)
            }
            guard !matches.isEmpty else {
                throw EncryptionKeyRecoveryError.externalScreenshotPath(storedPath)
            }
            guard matches.count == 1, let match = matches.first else {
                throw EncryptionKeyRecoveryError.ambiguousScreenshotPath(storedPath)
            }
            let destination = match.0 == 0
                ? source
                : currentRoot.appendingPathComponent(match.1, isDirectory: false).standardizedFileURL
            var isDirectory = ObjCBool(false)
            guard fm.fileExists(atPath: destination.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue else {
                throw EncryptionKeyRecoveryError.missingScreenshotFile(destination.path)
            }
            if destinationOwners[destination.path] != nil {
                throw EncryptionKeyRecoveryError.duplicateScreenshotDestination(destination.path)
            }
            destinationOwners[destination.path] = id
            files.append(destination)
            if destination.path != storedPath {
                updates.append(ScreenshotPathUpdate(
                    id: id, original: storedPath, destination: destination.path))
            }
        }
        return ScreenshotPathPlan(files: files, updates: updates)
    }

    private static func encryptedScreenshotFiles(
        in currentDirectory: URL,
        fileManager fm: FileManager = .default
    ) throws -> [URL] {
        let activity = currentDirectory.appendingPathComponent("activity", isDirectory: true)
        guard fm.fileExists(atPath: activity.path) else { return [] }
        var enumerationError: Error?
        guard let enumerator = fm.enumerator(
            at: activity,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles],
            errorHandler: { _, error in
                enumerationError = error
                return false
            }) else {
            throw CocoaError(.fileReadUnknown)
        }
        var files: [URL] = []
        for case let file as URL in enumerator
        where file.lastPathComponent.hasSuffix(".heic.enc") {
            files.append(file)
        }
        if let enumerationError { throw enumerationError }
        return files.sorted { $0.path < $1.path }
    }

    private static func uniqueFiles(_ files: [URL]) -> [URL] {
        var byPath: [String: URL] = [:]
        for file in files {
            let standardized = file.standardizedFileURL
            byPath[standardized.path] = standardized
        }
        return byPath.values.sorted { $0.path < $1.path }
    }

    private static func encryptedScreenshotRewritePlan(
        files: [URL],
        currentKeyData: Data,
        legacyKeyData: [Data]
    ) throws -> [(url: URL, data: Data)] {
        guard currentKeyData.count == 32 else {
            throw EncryptionKeyRecoveryError.invalidKey(
                account: "screenshot-key", service: AppIdentifiers.bundleID)
        }
        let currentKey = SymmetricKey(data: currentKeyData)
        let legacyKeys = legacyKeyData
            .filter { $0.count == 32 && $0 != currentKeyData }
            .map(SymmetricKey.init(data:))
        var rewrites: [(url: URL, data: Data)] = []
        for file in files.sorted(by: { $0.path < $1.path }) {
            let envelope = try Data(contentsOf: file)
            guard let box = try? AES.GCM.SealedBox(combined: envelope) else {
                throw EncryptionKeyRecoveryError.unreadableFile(
                    file.lastPathComponent, account: "screenshot-key")
            }
            if (try? AES.GCM.open(box, using: currentKey)) != nil { continue }
            guard let plaintext = legacyKeys.lazy.compactMap({
                try? AES.GCM.open(box, using: $0)
            }).first,
            let resealed = try AES.GCM.seal(plaintext, using: currentKey).combined else {
                throw EncryptionKeyRecoveryError.unreadableFile(
                    file.lastPathComponent, account: "screenshot-key")
            }
            rewrites.append((file, resealed))
        }
        return rewrites
    }

    private static func writableDatabase(
        at url: URL,
        required: Bool
    ) throws -> SQLiteDatabase? {
        guard required else { return nil }
        guard let database = SQLiteDatabase(url: url) else {
            throw EncryptionKeyRecoveryError.unavailableDatabase(url.path)
        }
        return database
    }

    private static func verifyScreenshotPathPlan(
        _ plan: ScreenshotPathPlan,
        database: SQLiteDatabase?
    ) throws {
        guard !plan.updates.isEmpty, let database else { return }
        for update in plan.updates {
            let current = try database.queryChecked(
                "SELECT path FROM screenshots WHERE id = ?1 LIMIT 1",
                bind: [update.id],
                row: { statement in
                    sqlite3_column_text(statement, 0).map { String(cString: $0) }
                }).first
            guard current == update.original else {
                throw EncryptionKeyRecoveryError.changedScreenshotPath(update.id)
            }
        }
    }

    private static func applyScreenshotPathPlan(
        _ plan: ScreenshotPathPlan,
        database: SQLiteDatabase?
    ) throws {
        guard !plan.updates.isEmpty, let database else { return }
        try database.withTransaction {
            for update in plan.updates {
                let current = try database.queryChecked(
                    "SELECT path FROM screenshots WHERE id = ?1 LIMIT 1",
                    bind: [update.id],
                    row: { statement in
                        sqlite3_column_text(statement, 0).map { String(cString: $0) }
                    }).first
                guard current == update.original else {
                    throw EncryptionKeyRecoveryError.changedScreenshotPath(update.id)
                }
                try database.runChecked(
                    "UPDATE screenshots SET path = ?1 WHERE id = ?2",
                    bind: [update.destination, update.id])
            }
        }
    }

    private static func relativePath(of child: URL, under parent: URL) -> String? {
        let childPath = child.standardizedFileURL.path
        let parentPath = parent.standardizedFileURL.path
        if childPath == parentPath { return "" }
        let prefix = parentPath.hasSuffix("/") ? parentPath : parentPath + "/"
        guard childPath.hasPrefix(prefix) else { return nil }
        return String(childPath.dropFirst(prefix.count))
    }

    private static func recoverLegacyChatKeyIfNeeded(
        currentDir: URL,
        defaults: UserDefaults,
        secrets: SecretStore
    ) -> StartupOutcome {
        let migrationsComplete = defaults.bool(forKey: migratedFromV2Flag)
            && defaults.bool(forKey: migratedFromV3Flag)
        guard !defaults.bool(forKey: recoveredChatKeyFlag) || !migrationsComplete else {
            return .ready
        }
        do {
            let currentService = AppIdentifiers.bundleID
            var current = try secrets.read(currentService, "chat-key")
            if let current, current.count != 32 {
                throw ChatKeyRecoveryError.invalidKey(service: currentService)
            }
            let legacy = try [oldV3BundleID, oldV2BundleID].compactMap { service -> Data? in
                guard let data = try secrets.read(service, "chat-key") else { return nil }
                guard data.count == 32 else {
                    NSLog("DataMigration: ignored invalid legacy chat key for service %@", service)
                    return nil
                }
                return data
            }
            let chatDir = currentDir.appendingPathComponent("chats", isDirectory: true)
            let hasEncryptedChats = !(try encryptedChatFiles(in: chatDir)).isEmpty
            if current == nil, let preferred = legacy.first {
                try secrets.write(preferred, currentService, "chat-key")
                current = try secrets.read(currentService, "chat-key")
            }
            guard let current else {
                if hasEncryptedChats { throw ChatKeyRecoveryError.missingKey }
                defaults.set(true, forKey: recoveredChatKeyFlag)
                return .ready
            }
            guard current.count == 32 else {
                throw ChatKeyRecoveryError.invalidKey(service: currentService)
            }
            _ = try migrateEncryptedChats(in: chatDir, currentKeyData: current,
                                          legacyKeyData: legacy)
            defaults.set(true, forKey: recoveredChatKeyFlag)
            return .ready
        } catch {
            let reason = "Chat history recovery is incomplete: \(error.localizedDescription)"
            NSLog("DataMigration: %@", reason)
            return .retryRequired(reason)
        }
    }

    private enum ChatKeyRecoveryError: LocalizedError {
        case invalidKey(service: String)
        case missingKey
        case unreadableChat(String)

        var errorDescription: String? {
            switch self {
            case .invalidKey(let service):
                "Invalid chat encryption key under service \(service)."
            case .missingKey:
                "Encrypted chat history exists but no current or legacy key is available."
            case .unreadableChat(let name):
                "Encrypted chat \(name) cannot be opened with any known key."
            }
        }
    }

    private static func encryptedChatFiles(in directory: URL,
                                           fileManager fm: FileManager = .default) throws -> [URL] {
        guard fm.fileExists(atPath: directory.path) else { return [] }
        return try fm.contentsOfDirectory(at: directory,
                                          includingPropertiesForKeys: [.isRegularFileKey],
                                          options: [.skipsHiddenFiles])
            .filter { $0.pathExtension == "enc" && $0.deletingPathExtension().pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    @discardableResult
    static func migrateEncryptedChats(in directory: URL, currentKeyData: Data,
                                      legacyKeyData: [Data],
                                      fileManager fm: FileManager = .default) throws -> Int {
        guard currentKeyData.count == 32 else {
            throw ChatKeyRecoveryError.invalidKey(service: AppIdentifiers.bundleID)
        }
        let currentKey = SymmetricKey(data: currentKeyData)
        let legacyKeys = legacyKeyData
            .filter { $0.count == 32 && $0 != currentKeyData }
            .map(SymmetricKey.init(data:))
        var rewrites: [(url: URL, data: Data)] = []
        for file in try encryptedChatFiles(in: directory, fileManager: fm) {
            let envelope = try Data(contentsOf: file)
            guard let box = try? AES.GCM.SealedBox(combined: envelope) else {
                throw ChatKeyRecoveryError.unreadableChat(file.lastPathComponent)
            }
            if (try? AES.GCM.open(box, using: currentKey)) != nil { continue }
            guard let plaintext = legacyKeys.lazy.compactMap({ try? AES.GCM.open(box, using: $0) }).first,
                  let resealed = try AES.GCM.seal(plaintext, using: currentKey).combined else {
                throw ChatKeyRecoveryError.unreadableChat(file.lastPathComponent)
            }
            rewrites.append((file, resealed))
        }
        for rewrite in rewrites {
            try rewrite.data.write(to: rewrite.url, options: .atomic)
        }
        return rewrites.count
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
        guard try readData(service: service, account: account) != nil else {
            throw KeychainMigrationError(status: errSecItemNotFound)
        }
    }
}
