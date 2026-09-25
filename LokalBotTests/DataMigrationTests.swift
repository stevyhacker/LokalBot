import XCTest
import CryptoKit
import SQLite3
@testable import LokalBot

/// Migration from old LokalBot identities. Exercises the data-loss-prone
/// filesystem/settings halves with injected dirs/suites (the Keychain half talks
/// to the real login keychain, so it's verified on install, not here).
final class DataMigrationTests: XCTestCase {
    private final class TestSecretStore {
        enum Failure: Error { case transientRead }

        var values: [String: Data] = [:]
        var remainingReadFailures = 0

        func set(_ data: Data, service: String, account: String) {
            values[key(service, account)] = data
        }

        func get(service: String, account: String) -> Data? {
            values[key(service, account)]
        }

        func operations() -> DataMigration.SecretStore {
            DataMigration.SecretStore(
                read: { [self] service, account in
                    if remainingReadFailures > 0 {
                        remainingReadFailures -= 1
                        throw Failure.transientRead
                    }
                    return get(service: service, account: account)
                },
                write: { [self] data, service, account in
                    let item = key(service, account)
                    if values[item] == nil { values[item] = data }
                })
        }

        private func key(_ service: String, _ account: String) -> String {
            service + "\u{1f}" + account
        }
    }

    private final class ConcurrentCreateFileManager: FileManager, @unchecked Sendable {
        let databaseURL: URL
        private(set) var currentDatabase: SQLiteDatabase?

        init(databaseURL: URL) { self.databaseURL = databaseURL }

        override func createDirectory(at url: URL, withIntermediateDirectories createIntermediates: Bool,
                                      attributes: [FileAttributeKey: Any]? = nil) throws {
            try super.createDirectory(at: url, withIntermediateDirectories: createIntermediates, attributes: attributes)
            if url.path.contains(".migration-backups"), currentDatabase == nil {
                let database = try XCTUnwrap(SQLiteDatabase(url: databaseURL))
                try database.execute("CREATE TABLE activity_blocks(value TEXT); INSERT INTO activity_blocks VALUES ('concurrent current fact');")
                currentDatabase = database
            }
        }
    }

    private var tmp: URL!
    private var suites: [String] = []

    override func setUpWithError() throws {
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("datamig-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
        for name in suites { UserDefaults().removePersistentDomain(forName: name) }
        suites = []
    }

    private func freshSuite() -> UserDefaults {
        let name = "datamig.test.\(UUID().uuidString)"
        suites.append(name)
        return UserDefaults(suiteName: name)!
    }

    private func markIdentityMigrationsComplete(_ defaults: UserDefaults) {
        defaults.set(true, forKey: "lokalbot.migratedFromDotenvV3")
        defaults.set(true, forKey: "lokalbotv3.migratedFromV2")
    }

    private func runRecovery(
        appSupport: URL,
        currentDirectory: URL,
        defaults: UserDefaults,
        secrets: TestSecretStore
    ) -> DataMigration.StartupOutcome {
        DataMigration.runIfNeeded(
            environment: [:],
            defaults: defaults,
            identity: .release,
            arguments: [],
            appSupport: appSupport,
            currentDirectory: currentDirectory,
            secrets: secrets.operations())
    }

    private func sealed(_ plaintext: String, keyData: Data) throws -> Data {
        try XCTUnwrap(try AES.GCM.seal(
            Data(plaintext.utf8), using: SymmetricKey(data: keyData)).combined)
    }

    private func screenshotPath(databaseURL: URL, id: Int64) throws -> String? {
        let database = try XCTUnwrap(SQLiteDatabase(url: databaseURL, readOnly: true))
        return try database.queryChecked(
            "SELECT path FROM screenshots WHERE id = ?1",
            bind: [id],
            row: { statement in
                sqlite3_column_text(statement, 0).map { String(cString: $0) }
            }).first
    }

    private func makeDatabase(at url: URL, rows: Int = 0,
                              activityRows: Int = 0,
                              indexedMeetings: Int = 0,
                              payloadBytes: Int = 0) throws {
        let database = try XCTUnwrap(SQLiteDatabase(url: url))
        database.exec("""
            CREATE TABLE IF NOT EXISTS screenshots (
                id INTEGER PRIMARY KEY, ts REAL NOT NULL, path TEXT NOT NULL, app TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS activity_blocks (
                app TEXT NOT NULL, title TEXT NOT NULL, start REAL NOT NULL, end REAL NOT NULL
            );
            CREATE TABLE IF NOT EXISTS indexed_meetings (
                meeting_id TEXT PRIMARY KEY, source_mtime REAL NOT NULL
            );
            CREATE TABLE IF NOT EXISTS docs (text TEXT NOT NULL);
            """)
        for index in 0..<rows {
            database.run("INSERT INTO screenshots (ts, path, app) VALUES (?1, ?2, ?3)",
                         bind: [Double(index), "shot-\(index).jpg", "Tests"])
        }
        for index in 0..<activityRows {
            database.run("INSERT INTO activity_blocks (app, title, start, end) VALUES (?1, ?2, ?3, ?4)",
                         bind: ["Tests", "Window \(index)", Double(index), Double(index + 1)])
        }
        for index in 0..<indexedMeetings {
            database.run("INSERT INTO indexed_meetings (meeting_id, source_mtime) VALUES (?1, ?2)",
                         bind: [UUID().uuidString, Double(index)])
            database.run("INSERT INTO docs (text) VALUES (?1)", bind: ["Indexed meeting \(index)"])
        }
        if payloadBytes > 0 {
            database.exec("CREATE TABLE IF NOT EXISTS payload (data BLOB NOT NULL);")
            database.run("INSERT INTO payload (data) VALUES (?1)",
                         bind: [Data(repeating: 7, count: payloadBytes)])
        }
    }

    // MARK: - Data directory

    func testMigrateDataDirMovesLibraryAndVersionRenamesDatabase() throws {
        let fm = FileManager.default
        let oldDir = tmp.appendingPathComponent("com.dotenv.LokalBotV2", isDirectory: true)
        let newDir = tmp.appendingPathComponent("me.dotenv.LokalBot", isDirectory: true)
        let meetings = oldDir.appendingPathComponent("meetings/2026/06", isDirectory: true)
        try fm.createDirectory(at: meetings, withIntermediateDirectories: true)
        try Data("meta".utf8).write(to: meetings.appendingPathComponent("meta.json"))
        // DB + its WAL/SHM sidecars carry the old version in the filename.
        for name in ["lokalbotv2.sqlite", "lokalbotv2.sqlite-wal", "lokalbotv2.sqlite-shm"] {
            try Data("db".utf8).write(to: oldDir.appendingPathComponent(name))
        }

        XCTAssertTrue(DataMigration.migrateDataDir(from: oldDir, to: newDir))

        XCTAssertFalse(fm.fileExists(atPath: oldDir.path), "V2 dir should be moved, not left behind")
        // Library content survives the move.
        XCTAssertTrue(fm.fileExists(atPath: newDir.appendingPathComponent("meetings/2026/06/meta.json").path))
        // DB + sidecars are renamed to the V3 filename the app opens.
        for name in ["lokalbotv3.sqlite", "lokalbotv3.sqlite-wal", "lokalbotv3.sqlite-shm"] {
            XCTAssertTrue(fm.fileExists(atPath: newDir.appendingPathComponent(name).path), "\(name) missing")
        }
        // No stale V2-named DB lingers in the migrated dir.
        XCTAssertFalse(fm.fileExists(atPath: newDir.appendingPathComponent("lokalbotv2.sqlite").path))
    }

    func testMigrateDataDirMovesV3LibraryWithoutRenamingDatabase() throws {
        let fm = FileManager.default
        let oldDir = tmp.appendingPathComponent(["com", "dotenv", "LokalBotV3"].joined(separator: "."),
                                                isDirectory: true)
        let newDir = tmp.appendingPathComponent("me.dotenv.LokalBot", isDirectory: true)
        try fm.createDirectory(at: oldDir, withIntermediateDirectories: true)
        try Data("db".utf8).write(to: oldDir.appendingPathComponent("lokalbotv3.sqlite"))

        XCTAssertTrue(DataMigration.migrateDataDir(from: oldDir, to: newDir, renamesDatabase: false))

        XCTAssertFalse(fm.fileExists(atPath: oldDir.path))
        XCTAssertTrue(fm.fileExists(atPath: newDir.appendingPathComponent("lokalbotv3.sqlite").path))
    }

    func testMigrateDataDirCopiesV3LibraryIntoRuntimeDirectoryWithoutDatabase() throws {
        let fm = FileManager.default
        let oldDir = tmp.appendingPathComponent(["com", "dotenv", "LokalBotV3"].joined(separator: "."),
                                                isDirectory: true)
        let newDir = tmp.appendingPathComponent("me.dotenv.LokalBot", isDirectory: true)
        try fm.createDirectory(at: oldDir.appendingPathComponent("models"), withIntermediateDirectories: true)
        try fm.createDirectory(at: newDir.appendingPathComponent("meetings"), withIntermediateDirectories: true)
        try makeDatabase(at: oldDir.appendingPathComponent("lokalbotv3.sqlite"), rows: 1)
        try Data("model".utf8).write(to: oldDir.appendingPathComponent("models/local.gguf"))

        XCTAssertTrue(DataMigration.migrateDataDir(from: oldDir, to: newDir,
                                                   renamesDatabase: false,
                                                   mergeIfDestinationExists: true,
                                                   replacePlaceholderDatabase: true))

        XCTAssertTrue(fm.fileExists(atPath: newDir.appendingPathComponent("models/local.gguf").path))
        XCTAssertTrue(fm.fileExists(atPath: oldDir.appendingPathComponent("models/local.gguf").path),
                      "merging into an existing directory preserves the complete source library")
        XCTAssertEqual(SQLiteDatabase(url: newDir.appendingPathComponent("lokalbotv3.sqlite"))?
            .firstDouble("SELECT COUNT(*) FROM screenshots"), 1)
        XCTAssertEqual(SQLiteDatabase(url: oldDir.appendingPathComponent("lokalbotv3.sqlite"), readOnly: true)?
            .firstDouble("SELECT COUNT(*) FROM screenshots"), 1, "legacy database remains recoverable")
    }

    func testEmptyCurrentDatabaseIsNeverReplacedBehindExistingConnections() throws {
        let oldDir = tmp.appendingPathComponent("legacy", isDirectory: true)
        let newDir = tmp.appendingPathComponent("current", isDirectory: true)
        try FileManager.default.createDirectory(at: oldDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: newDir, withIntermediateDirectories: true)
        try makeDatabase(at: oldDir.appendingPathComponent("lokalbotv3.sqlite"), activityRows: 1)
        let currentURL = newDir.appendingPathComponent("lokalbotv3.sqlite")
        let current = try XCTUnwrap(SQLiteDatabase(url: currentURL))
        try current.execute("CREATE TABLE activity_blocks(value TEXT)")
        let originalInode = try FileManager.default.attributesOfItem(atPath: currentURL.path)[.systemFileNumber] as? NSNumber

        XCTAssertEqual(try DataMigration.migrateDataDirChecked(
            from: oldDir, to: newDir, renamesDatabase: false,
            mergeIfDestinationExists: true, replacePlaceholderDatabase: true), .preservedConflict)
        try current.execute("INSERT INTO activity_blocks VALUES ('current fact')")

        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: currentURL.path)[.systemFileNumber] as? NSNumber,
                       originalInode, "an empty but open database keeps its inode")
        XCTAssertEqual(SQLiteDatabase(url: currentURL, readOnly: true)?
            .firstDouble("SELECT COUNT(*) FROM activity_blocks WHERE value = 'current fact'"), 1)
    }

    func testMigrateDataDirDoesNotReplaceUsefulExistingV3Database() throws {
        let fm = FileManager.default
        let oldDir = tmp.appendingPathComponent(["com", "dotenv", "LokalBotV3"].joined(separator: "."),
                                                isDirectory: true)
        let newDir = tmp.appendingPathComponent("me.dotenv.LokalBot", isDirectory: true)
        try fm.createDirectory(at: oldDir.appendingPathComponent("models"), withIntermediateDirectories: true)
        try fm.createDirectory(at: newDir, withIntermediateDirectories: true)
        try makeDatabase(at: oldDir.appendingPathComponent("lokalbotv3.sqlite"), rows: 2)
        try makeDatabase(at: newDir.appendingPathComponent("lokalbotv3.sqlite"), rows: 1)
        try Data("model".utf8).write(to: oldDir.appendingPathComponent("models/local.gguf"))

        XCTAssertFalse(DataMigration.migrateDataDir(from: oldDir, to: newDir,
                                                   renamesDatabase: false,
                                                   mergeIfDestinationExists: true,
                                                   replacePlaceholderDatabase: true))

        XCTAssertTrue(fm.fileExists(atPath: oldDir.appendingPathComponent("models/local.gguf").path),
                      "the conflicting legacy library must keep its related files")
        XCTAssertEqual(SQLiteDatabase(url: newDir.appendingPathComponent("lokalbotv3.sqlite"))?
            .firstDouble("SELECT COUNT(*) FROM screenshots"), 1)
    }

    func testMigrateDataDirPreservesSmallCurrentActivityAndMeetingHistory() throws {
        let fm = FileManager.default
        let oldDir = tmp.appendingPathComponent(["com", "dotenv", "LokalBotV3"].joined(separator: "."),
                                                isDirectory: true)
        let newDir = tmp.appendingPathComponent("me.dotenv.LokalBot", isDirectory: true)
        try fm.createDirectory(at: oldDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: newDir, withIntermediateDirectories: true)
        try makeDatabase(at: oldDir.appendingPathComponent("lokalbotv3.sqlite"),
                         rows: 2,
                         activityRows: 150,
                         payloadBytes: 600 * 1024)
        try makeDatabase(at: newDir.appendingPathComponent("lokalbotv3.sqlite"),
                         activityRows: 2,
                         indexedMeetings: 5)

        XCTAssertFalse(DataMigration.migrateDataDir(from: oldDir, to: newDir,
                                                   renamesDatabase: false,
                                                   mergeIfDestinationExists: true,
                                                   replacePlaceholderDatabase: true))

        let migratedDB = SQLiteDatabase(url: newDir.appendingPathComponent("lokalbotv3.sqlite"))
        XCTAssertEqual(migratedDB?.firstDouble("SELECT COUNT(*) FROM screenshots"), 0)
        XCTAssertEqual(migratedDB?.firstDouble("SELECT COUNT(*) FROM activity_blocks"), 2)
        XCTAssertEqual(migratedDB?.firstDouble("SELECT COUNT(*) FROM indexed_meetings"), 5)
        XCTAssertEqual(SQLiteDatabase(url: oldDir.appendingPathComponent("lokalbotv3.sqlite"), readOnly: true)?
            .firstDouble("SELECT COUNT(*) FROM activity_blocks"), 150)
    }

    func testLargerLegacyDatabaseCannotReplaceActivityOnlyCurrentLibrary() throws {
        let oldDir = tmp.appendingPathComponent("legacy", isDirectory: true)
        let newDir = tmp.appendingPathComponent("current", isDirectory: true)
        try FileManager.default.createDirectory(at: oldDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: newDir, withIntermediateDirectories: true)
        try makeDatabase(at: oldDir.appendingPathComponent("lokalbotv3.sqlite"),
                         rows: 1, activityRows: 3, payloadBytes: 600 * 1024)
        try makeDatabase(at: newDir.appendingPathComponent("lokalbotv3.sqlite"), activityRows: 500)

        XCTAssertFalse(DataMigration.migrateDataDir(from: oldDir, to: newDir,
                                                    renamesDatabase: false,
                                                    mergeIfDestinationExists: true,
                                                    replacePlaceholderDatabase: true))
        XCTAssertEqual(SQLiteDatabase(url: newDir.appendingPathComponent("lokalbotv3.sqlite"), readOnly: true)?
            .firstDouble("SELECT COUNT(*) FROM activity_blocks"), 500)
        XCTAssertEqual(SQLiteDatabase(url: oldDir.appendingPathComponent("lokalbotv3.sqlite"), readOnly: true)?
            .firstDouble("SELECT COUNT(*) FROM activity_blocks"), 3)
    }

    func testUnknownCurrentTablesArePreservedRatherThanAssumedEmpty() throws {
        let oldDir = tmp.appendingPathComponent("legacy", isDirectory: true)
        let newDir = tmp.appendingPathComponent("current", isDirectory: true)
        try FileManager.default.createDirectory(at: oldDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: newDir, withIntermediateDirectories: true)
        try makeDatabase(at: oldDir.appendingPathComponent("lokalbotv3.sqlite"), rows: 1)
        let database = try XCTUnwrap(SQLiteDatabase(url: newDir.appendingPathComponent("lokalbotv3.sqlite")))
        try database.execute("CREATE TABLE future_user_data (text TEXT); INSERT INTO future_user_data VALUES ('keep');")

        XCTAssertFalse(DataMigration.migrateDataDir(from: oldDir, to: newDir,
                                                    renamesDatabase: false,
                                                    mergeIfDestinationExists: true,
                                                    replacePlaceholderDatabase: true))
        XCTAssertEqual(try database.firstDoubleChecked("SELECT COUNT(*) FROM future_user_data"), 1)
    }

    func testUnreadableCurrentDatabaseIsPreserved() throws {
        let oldDir = tmp.appendingPathComponent("legacy", isDirectory: true)
        let newDir = tmp.appendingPathComponent("current", isDirectory: true)
        try FileManager.default.createDirectory(at: oldDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: newDir, withIntermediateDirectories: true)
        try makeDatabase(at: oldDir.appendingPathComponent("lokalbotv3.sqlite"), rows: 1)
        let damaged = Data("damaged database that needs recovery".utf8)
        let current = newDir.appendingPathComponent("lokalbotv3.sqlite")
        try damaged.write(to: current)

        XCTAssertFalse(DataMigration.migrateDataDir(from: oldDir, to: newDir,
                                                    renamesDatabase: false,
                                                    mergeIfDestinationExists: true,
                                                    replacePlaceholderDatabase: true))
        XCTAssertEqual(try Data(contentsOf: current), damaged)
    }

    func testMigrationSnapshotIncludesCommittedWALAndPreservesLegacyDatabase() throws {
        let oldDir = tmp.appendingPathComponent("legacy", isDirectory: true)
        let newDir = tmp.appendingPathComponent("current", isDirectory: true)
        try FileManager.default.createDirectory(at: oldDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: newDir, withIntermediateDirectories: true)
        let oldDB = oldDir.appendingPathComponent("lokalbotv3.sqlite")
        let legacy = try XCTUnwrap(SQLiteDatabase(url: oldDB))
        try legacy.execute("PRAGMA wal_autocheckpoint=0; CREATE TABLE activity_blocks (value TEXT); INSERT INTO activity_blocks VALUES ('retained WAL row');")
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldDB.path + "-wal"))

        XCTAssertTrue(DataMigration.migrateDataDir(from: oldDir, to: newDir,
                                                   renamesDatabase: false,
                                                   mergeIfDestinationExists: true,
                                                   replacePlaceholderDatabase: true))
        XCTAssertEqual(SQLiteDatabase(url: newDir.appendingPathComponent("lokalbotv3.sqlite"), readOnly: true)?
            .firstDouble("SELECT COUNT(*) FROM activity_blocks"), 1)
        XCTAssertEqual(try legacy.firstDoubleChecked("SELECT COUNT(*) FROM activity_blocks"), 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldDB.path))
    }

    func testConcurrentDatabaseCreationWinsAtomicInstallationAndKeepsRecoverySnapshot() throws {
        let oldDir = tmp.appendingPathComponent("legacy", isDirectory: true)
        let newDir = tmp.appendingPathComponent("current", isDirectory: true)
        try FileManager.default.createDirectory(at: oldDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: newDir, withIntermediateDirectories: true)
        let current = newDir.appendingPathComponent("lokalbotv3.sqlite")
        try makeDatabase(at: oldDir.appendingPathComponent("lokalbotv3.sqlite"), activityRows: 1)
        let fileManager = ConcurrentCreateFileManager(databaseURL: current)

        XCTAssertEqual(try DataMigration.migrateDataDirChecked(
            from: oldDir, to: newDir, renamesDatabase: false,
            mergeIfDestinationExists: true, replacePlaceholderDatabase: true,
            fileManager: fileManager), .preservedConflict)
        XCTAssertNotNil(fileManager.currentDatabase, "the independent writer must run after the initial absence check")
        XCTAssertEqual(SQLiteDatabase(url: current, readOnly: true)?
            .firstDouble("SELECT COUNT(*) FROM activity_blocks WHERE value = 'concurrent current fact'"), 1)
        try fileManager.currentDatabase?.execute("INSERT INTO activity_blocks VALUES ('later current fact')")
        XCTAssertEqual(SQLiteDatabase(url: current, readOnly: true)?
            .firstDouble("SELECT COUNT(*) FROM activity_blocks"), 2,
                       "the writer must remain attached to the active database")
        XCTAssertEqual(SQLiteDatabase(url: oldDir.appendingPathComponent("lokalbotv3.sqlite"), readOnly: true)?
            .firstDouble("SELECT COUNT(*) FROM activity_blocks"), 1)
        let backups = try FileManager.default.contentsOfDirectory(
            at: newDir.appendingPathComponent(".migration-backups"), includingPropertiesForKeys: nil)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: try XCTUnwrap(backups.first).appendingPathComponent("incoming.sqlite").path))
    }

    func testFailedAtomicInstallLeavesRecoverySnapshotUntouched() throws {
        let snapshot = tmp.appendingPathComponent("incoming.sqlite")
        try makeDatabase(at: snapshot, activityRows: 1)
        let original = try Data(contentsOf: snapshot)
        XCTAssertThrowsError(try DataMigration.installDatabaseSnapshot(
            from: snapshot, to: tmp.appendingPathComponent("missing-parent/lokalbotv3.sqlite")))
        XCTAssertEqual(try Data(contentsOf: snapshot), original)
    }

    func testFailedPhaseDoesNotMarkMigrationCompleteAndCanRetry() {
        for failingPhase in 0..<3 {
            let defaults = freshSuite()
            let marker = "migration-completed"
            var dataWasTouched = false
            DataMigration.completeMigration(marker: marker, defaults: defaults) {
                dataWasTouched = true
                if failingPhase == 2 { throw CocoaError(.fileWriteNoPermission) }
                return .migrated
            } migratePreferences: {
                if failingPhase == 0 { throw CocoaError(.fileWriteNoPermission) }
            } migrateSecrets: {
                if failingPhase == 1 { throw CocoaError(.fileWriteNoPermission) }
            }
            XCTAssertFalse(defaults.bool(forKey: marker))
            XCTAssertEqual(dataWasTouched, failingPhase == 2,
                           "failed preferences or Keychain access must leave the library in place")

            DataMigration.completeMigration(marker: marker, defaults: defaults) {
                .unchanged
            } migratePreferences: {} migrateSecrets: {}
            XCTAssertTrue(defaults.bool(forKey: marker))
        }
    }

    func testConflictingLibraryDoesNotMarkMigrationComplete() {
        let defaults = freshSuite()
        DataMigration.completeMigration(marker: "migration-completed", defaults: defaults) {
            .preservedConflict
        } migratePreferences: {} migrateSecrets: {}
        XCTAssertFalse(defaults.bool(forKey: "migration-completed"))
    }

    func testStartupGateRetriesTransientMigrationBeforeLaunchingApplication() throws {
        let appSupport = tmp.appendingPathComponent("Application Support", isDirectory: true)
        let legacy = appSupport.appendingPathComponent("com.dotenv.LokalBotV3", isDirectory: true)
        let current = appSupport.appendingPathComponent("me.dotenv.LokalBot", isDirectory: true)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try Data("legacy".utf8).write(to: legacy.appendingPathComponent("library-marker"))
        let defaults = freshSuite()
        let secrets = TestSecretStore()
        secrets.remainingReadFailures = 1
        var applicationLaunches = 0
        var recoveryOutcomes: [DataMigration.StartupOutcome] = []

        let first = LokalBotMain.routeStartup(
            migrate: {
                self.runRecovery(
                    appSupport: appSupport, currentDirectory: current,
                    defaults: defaults, secrets: secrets)
            },
            launchApplication: { applicationLaunches += 1 },
            launchRecovery: { recoveryOutcomes.append($0) })

        guard case .retryRequired = first else {
            return XCTFail("transient Keychain failure must retain the recovery gate")
        }
        XCTAssertEqual(applicationLaunches, 0)
        XCTAssertEqual(recoveryOutcomes, [first])
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacy.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: current.path),
                       "AppState must not create the destination after a failed migration")

        let second = LokalBotMain.routeStartup(
            migrate: {
                self.runRecovery(
                    appSupport: appSupport, currentDirectory: current,
                    defaults: defaults, secrets: secrets)
            },
            launchApplication: { applicationLaunches += 1 },
            launchRecovery: { recoveryOutcomes.append($0) })

        XCTAssertEqual(second, .ready)
        XCTAssertEqual(applicationLaunches, 1)
        XCTAssertEqual(recoveryOutcomes, [first])
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: current.appendingPathComponent("library-marker").path))
    }

    func testScreenshotRecoveryResealsMixedCiphertextWhenIdentityKeysDiffer() throws {
        let appSupport = tmp.appendingPathComponent("Application Support", isDirectory: true)
        let current = appSupport.appendingPathComponent("me.dotenv.LokalBot", isDirectory: true)
        let shots = current.appendingPathComponent("activity/2026-09-25/shots", isDirectory: true)
        try FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)
        let currentKey = Data(repeating: 0x11, count: 32)
        let legacyKey = Data(repeating: 0x22, count: 32)
        let currentFile = shots.appendingPathComponent("current.heic.enc")
        let legacyFile = shots.appendingPathComponent("legacy.heic.enc")
        let currentEnvelope = try sealed("current", keyData: currentKey)
        try currentEnvelope.write(to: currentFile)
        try sealed("legacy", keyData: legacyKey).write(to: legacyFile)
        let defaults = freshSuite()
        markIdentityMigrationsComplete(defaults)
        let secrets = TestSecretStore()
        secrets.set(currentKey, service: "me.dotenv.LokalBot", account: "screenshot-key")
        secrets.set(legacyKey, service: "com.dotenv.LokalBotV3", account: "screenshot-key")

        XCTAssertEqual(runRecovery(
            appSupport: appSupport, currentDirectory: current,
            defaults: defaults, secrets: secrets), .ready)
        XCTAssertEqual(try Data(contentsOf: currentFile), currentEnvelope)
        let migrated = try AES.GCM.SealedBox(combined: Data(contentsOf: legacyFile))
        XCTAssertEqual(try AES.GCM.open(migrated, using: SymmetricKey(data: currentKey)),
                       Data("legacy".utf8))
        let migratedEnvelope = try Data(contentsOf: legacyFile)

        XCTAssertEqual(runRecovery(
            appSupport: appSupport, currentDirectory: current,
            defaults: defaults, secrets: secrets), .ready)
        XCTAssertEqual(try Data(contentsOf: legacyFile), migratedEnvelope,
                       "completed recovery must be idempotent")
    }

    func testScreenshotRecoveryRebasesAbsoluteLegacyPaths() throws {
        let appSupport = tmp.appendingPathComponent("Application Support", isDirectory: true)
        let legacy = appSupport.appendingPathComponent("com.dotenv.LokalBotV3", isDirectory: true)
        let current = appSupport.appendingPathComponent("me.dotenv.LokalBot", isDirectory: true)
        let relative = "activity/2026-09-25/shots/legacy.heic.enc"
        let migratedFile = current.appendingPathComponent(relative)
        let currentFile = current.appendingPathComponent(
            "activity/2026-09-25/shots/current.heic.enc")
        try FileManager.default.createDirectory(
            at: migratedFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        let key = Data(repeating: 0x33, count: 32)
        try sealed("pixels", keyData: key).write(to: migratedFile)
        try sealed("current", keyData: key).write(to: currentFile)
        let databaseURL = current.appendingPathComponent("lokalbotv3.sqlite")
        try makeDatabase(at: databaseURL)
        let database = try XCTUnwrap(SQLiteDatabase(url: databaseURL))
        try database.runChecked(
            "INSERT INTO screenshots (id, ts, path, app) VALUES (?1, ?2, ?3, ?4)",
            bind: [Int64(41), 0.0, legacy.appendingPathComponent(relative).path, "Tests"])
        try database.runChecked(
            "INSERT INTO screenshots (id, ts, path, app) VALUES (?1, ?2, ?3, ?4)",
            bind: [Int64(42), 0.0, currentFile.path, "Tests"])
        let defaults = freshSuite()
        markIdentityMigrationsComplete(defaults)
        let secrets = TestSecretStore()
        secrets.set(key, service: "me.dotenv.LokalBot", account: "screenshot-key")

        XCTAssertEqual(runRecovery(
            appSupport: appSupport, currentDirectory: current,
            defaults: defaults, secrets: secrets), .ready)
        XCTAssertEqual(try screenshotPath(databaseURL: databaseURL, id: 41), migratedFile.path)
        XCTAssertEqual(try screenshotPath(databaseURL: databaseURL, id: 42), currentFile.path,
                       "paths already under the current root remain valid")
    }

    func testUnknownScreenshotKeyKeepsStartupPendingUntilRetryCanRecover() throws {
        let appSupport = tmp.appendingPathComponent("Application Support", isDirectory: true)
        let current = appSupport.appendingPathComponent("me.dotenv.LokalBot", isDirectory: true)
        let shots = current.appendingPathComponent("activity/2026-09-25/shots", isDirectory: true)
        try FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)
        let currentKey = Data(repeating: 0x44, count: 32)
        let v3Key = Data(repeating: 0x55, count: 32)
        let v2Key = Data(repeating: 0x66, count: 32)
        let recoverable = shots.appendingPathComponent("a.heic.enc")
        let initiallyUnknown = shots.appendingPathComponent("b.heic.enc")
        try sealed("v3", keyData: v3Key).write(to: recoverable)
        try sealed("v2", keyData: v2Key).write(to: initiallyUnknown)
        let originalV3 = try Data(contentsOf: recoverable)
        let originalV2 = try Data(contentsOf: initiallyUnknown)
        let defaults = freshSuite()
        markIdentityMigrationsComplete(defaults)
        let secrets = TestSecretStore()
        secrets.set(currentKey, service: "me.dotenv.LokalBot", account: "screenshot-key")
        secrets.set(v3Key, service: "com.dotenv.LokalBotV3", account: "screenshot-key")

        let first = runRecovery(
            appSupport: appSupport, currentDirectory: current,
            defaults: defaults, secrets: secrets)
        guard case .retryRequired = first else {
            return XCTFail("unknown ciphertext must keep startup non-ready")
        }
        XCTAssertFalse(defaults.bool(forKey: "lokalbot.recoveredLegacyScreenshotKey.v1"))
        XCTAssertEqual(try Data(contentsOf: recoverable), originalV3)
        XCTAssertEqual(try Data(contentsOf: initiallyUnknown), originalV2,
                       "ciphertext preflight must leave every file untouched")

        secrets.set(v2Key, service: "com.dotenv.LokalBotV2", account: "screenshot-key")
        XCTAssertEqual(runRecovery(
            appSupport: appSupport, currentDirectory: current,
            defaults: defaults, secrets: secrets), .ready)
        for (file, plaintext) in [(recoverable, "v3"), (initiallyUnknown, "v2")] {
            let box = try AES.GCM.SealedBox(combined: Data(contentsOf: file))
            XCTAssertEqual(try AES.GCM.open(box, using: SymmetricKey(data: currentKey)),
                           Data(plaintext.utf8))
        }
    }

    func testScreenshotPathPreflightRejectsRelativeExternalAndMissingDestinations() throws {
        enum Fixture { case relative, external, missing }
        for fixture in [Fixture.relative, .external, .missing] {
            let fixtureRoot = tmp.appendingPathComponent(UUID().uuidString, isDirectory: true)
            let appSupport = fixtureRoot.appendingPathComponent("Application Support", isDirectory: true)
            let legacy = appSupport.appendingPathComponent("com.dotenv.LokalBotV3", isDirectory: true)
            let current = appSupport.appendingPathComponent("me.dotenv.LokalBot", isDirectory: true)
            let relative = "activity/2026-09-25/shots/fixture.heic.enc"
            let currentFile = current.appendingPathComponent(relative)
            let externalFile = fixtureRoot.appendingPathComponent("external.heic.enc")
            let key = Data(repeating: 0x71, count: 32)
            var fileToPreserve: URL?
            let storedPath: String
            switch fixture {
            case .relative:
                try FileManager.default.createDirectory(
                    at: currentFile.deletingLastPathComponent(), withIntermediateDirectories: true)
                try sealed("relative", keyData: key).write(to: currentFile)
                fileToPreserve = currentFile
                storedPath = relative
            case .external:
                try FileManager.default.createDirectory(
                    at: externalFile.deletingLastPathComponent(), withIntermediateDirectories: true)
                try sealed("external", keyData: key).write(to: externalFile)
                fileToPreserve = externalFile
                storedPath = externalFile.path
            case .missing:
                try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
                storedPath = legacy.appendingPathComponent(relative).path
            }
            let originalFile = try fileToPreserve.map { try Data(contentsOf: $0) }
            try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
            let databaseURL = current.appendingPathComponent("lokalbotv3.sqlite")
            try makeDatabase(at: databaseURL)
            do {
                let database = try XCTUnwrap(SQLiteDatabase(url: databaseURL))
                try database.runChecked(
                    "INSERT INTO screenshots (id, ts, path, app) VALUES (?1, ?2, ?3, ?4)",
                    bind: [Int64(51), 0.0, storedPath, "Tests"])
            }
            let defaults = freshSuite()
            markIdentityMigrationsComplete(defaults)
            let secrets = TestSecretStore()
            secrets.set(key, service: "me.dotenv.LokalBot", account: "screenshot-key")

            let outcome = runRecovery(
                appSupport: appSupport, currentDirectory: current,
                defaults: defaults, secrets: secrets)
            guard case .retryRequired = outcome else {
                return XCTFail("\(fixture) path must keep startup in recovery")
            }
            XCTAssertEqual(try screenshotPath(databaseURL: databaseURL, id: 51), storedPath)
            if let fileToPreserve, let originalFile {
                XCTAssertEqual(try Data(contentsOf: fileToPreserve), originalFile)
            }
        }
    }

    func testScreenshotPathPreflightRejectsDuplicateDestinationWithoutRewriting() throws {
        let appSupport = tmp.appendingPathComponent("Application Support", isDirectory: true)
        let legacy = appSupport.appendingPathComponent("com.dotenv.LokalBotV3", isDirectory: true)
        let current = appSupport.appendingPathComponent("me.dotenv.LokalBot", isDirectory: true)
        let relative = "activity/2026-09-25/shots/duplicate.heic.enc"
        let currentFile = current.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: currentFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        let key = Data(repeating: 0x72, count: 32)
        try sealed("duplicate", keyData: key).write(to: currentFile)
        let original = try Data(contentsOf: currentFile)
        let legacyPath = legacy.appendingPathComponent(relative).path
        let databaseURL = current.appendingPathComponent("lokalbotv3.sqlite")
        try makeDatabase(at: databaseURL)
        do {
            let database = try XCTUnwrap(SQLiteDatabase(url: databaseURL))
            for id in [Int64(61), 62] {
                try database.runChecked(
                    "INSERT INTO screenshots (id, ts, path, app) VALUES (?1, ?2, ?3, ?4)",
                    bind: [id, 0.0, legacyPath, "Tests"])
            }
        }
        let defaults = freshSuite()
        markIdentityMigrationsComplete(defaults)
        let secrets = TestSecretStore()
        secrets.set(key, service: "me.dotenv.LokalBot", account: "screenshot-key")

        guard case .retryRequired = runRecovery(
            appSupport: appSupport, currentDirectory: current,
            defaults: defaults, secrets: secrets) else {
            return XCTFail("duplicate path destinations must remain recoverable")
        }
        XCTAssertEqual(try screenshotPath(databaseURL: databaseURL, id: 61), legacyPath)
        XCTAssertEqual(try screenshotPath(databaseURL: databaseURL, id: 62), legacyPath)
        XCTAssertEqual(try Data(contentsOf: currentFile), original)
    }

    func testScreenshotPathPreflightRejectsAmbiguousNestedRoots() throws {
        let appSupport = tmp.appendingPathComponent("Application Support", isDirectory: true)
        let legacy = appSupport.appendingPathComponent("com.dotenv.LokalBotV3", isDirectory: true)
        let current = legacy.appendingPathComponent("nested-current", isDirectory: true)
        let file = current.appendingPathComponent(
            "activity/2026-09-25/shots/ambiguous.heic.enc")
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let key = Data(repeating: 0x73, count: 32)
        try sealed("ambiguous", keyData: key).write(to: file)
        let original = try Data(contentsOf: file)
        let databaseURL = current.appendingPathComponent("lokalbotv3.sqlite")
        try makeDatabase(at: databaseURL)
        do {
            let database = try XCTUnwrap(SQLiteDatabase(url: databaseURL))
            try database.runChecked(
                "INSERT INTO screenshots (id, ts, path, app) VALUES (?1, ?2, ?3, ?4)",
                bind: [Int64(71), 0.0, file.path, "Tests"])
        }
        let defaults = freshSuite()
        markIdentityMigrationsComplete(defaults)
        let secrets = TestSecretStore()
        secrets.set(key, service: "me.dotenv.LokalBot", account: "screenshot-key")

        guard case .retryRequired = runRecovery(
            appSupport: appSupport, currentDirectory: current,
            defaults: defaults, secrets: secrets) else {
            return XCTFail("a path matching current and legacy roots must remain recoverable")
        }
        XCTAssertEqual(try screenshotPath(databaseURL: databaseURL, id: 71), file.path)
        XCTAssertEqual(try Data(contentsOf: file), original)
    }

    func testMigrateDataDirIsNoOpWhenV3AlreadyExists() throws {
        let fm = FileManager.default
        let oldDir = tmp.appendingPathComponent("com.dotenv.LokalBotV2", isDirectory: true)
        let newDir = tmp.appendingPathComponent("me.dotenv.LokalBot", isDirectory: true)
        try fm.createDirectory(at: oldDir, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: oldDir.appendingPathComponent("marker"))
        try fm.createDirectory(at: newDir, withIntermediateDirectories: true)
        try Data("new".utf8).write(to: newDir.appendingPathComponent("keep"))

        XCTAssertFalse(DataMigration.migrateDataDir(from: oldDir, to: newDir),
                       "must not clobber an existing V3 library")
        XCTAssertTrue(fm.fileExists(atPath: oldDir.appendingPathComponent("marker").path))
        XCTAssertTrue(fm.fileExists(atPath: newDir.appendingPathComponent("keep").path))
    }

    func testMigrateDataDirIsNoOpWithoutV2Library() {
        let oldDir = tmp.appendingPathComponent("com.dotenv.LokalBotV2", isDirectory: true)
        let newDir = tmp.appendingPathComponent("me.dotenv.LokalBot", isDirectory: true)
        XCTAssertFalse(DataMigration.migrateDataDir(from: oldDir, to: newDir))
        XCTAssertFalse(FileManager.default.fileExists(atPath: newDir.path))
    }

    // MARK: - Settings / UserDefaults

    func testMigrateSettingsCopiesBlobAndOnboardingFlag() throws {
        let old = freshSuite(), new = freshSuite()
        var settings = AppSettings()
        settings.retentionDays = 99          // a clearly non-default value to track
        settings.menuBarOnly = false
        old.set(try JSONEncoder().encode(settings), forKey: "lokalbotv2.settings")
        old.set(true, forKey: "lokalbotv2.onboarding.shown")

        DataMigration.migrateSettings(from: old, to: new)

        let data = try XCTUnwrap(new.data(forKey: AppSettings.key), "settings blob not copied")
        let migrated = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertEqual(migrated.retentionDays, 99)
        XCTAssertFalse(migrated.menuBarOnly)
        XCTAssertTrue(new.bool(forKey: AppState.onboardingShownKey), "onboarding flag not carried over")
    }

    func testMigrateSettingsDoesNotOverwriteExistingV3Settings() throws {
        let old = freshSuite(), new = freshSuite()
        var oldSettings = AppSettings(); oldSettings.retentionDays = 99
        old.set(try JSONEncoder().encode(oldSettings), forKey: "lokalbotv2.settings")
        var newSettings = AppSettings(); newSettings.retentionDays = 7
        new.set(try JSONEncoder().encode(newSettings), forKey: AppSettings.key)

        DataMigration.migrateSettings(from: old, to: new)

        let data = try XCTUnwrap(new.data(forKey: AppSettings.key))
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: data).retentionDays, 7,
                       "existing V3 settings must win over a stale V2 copy")
    }

    func testMigrateSettingsCopiesCurrentIdentityKeys() throws {
        let old = freshSuite(), new = freshSuite()
        var settings = AppSettings()
        settings.retentionDays = 42
        old.set(try JSONEncoder().encode(settings), forKey: AppSettings.key)
        old.set(true, forKey: AppState.onboardingShownKey)

        DataMigration.migrateSettings(from: old, to: new,
                                      settingsKey: AppSettings.key,
                                      onboardingKey: AppState.onboardingShownKey)

        let data = try XCTUnwrap(new.data(forKey: AppSettings.key))
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: data).retentionDays, 42)
        XCTAssertTrue(new.bool(forKey: AppState.onboardingShownKey))
    }

    // MARK: - Legacy chat encryption key recovery

    func testLegacyEncryptedChatsAreAtomicallyResealedWithCurrentKey() throws {
        let chats = tmp.appendingPathComponent("chats", isDirectory: true)
        try FileManager.default.createDirectory(at: chats, withIntermediateDirectories: true)
        let oldKeyData = Data(repeating: 0x11, count: 32)
        let currentKeyData = Data(repeating: 0x22, count: 32)
        let plaintext = Data(#"{"title":"legacy chat"}"#.utf8)
        let file = chats.appendingPathComponent("legacy.json.enc")
        let oldKey = SymmetricKey(data: oldKeyData)
        try XCTUnwrap(try AES.GCM.seal(plaintext, using: oldKey).combined).write(to: file)

        XCTAssertEqual(try DataMigration.migrateEncryptedChats(
            in: chats, currentKeyData: currentKeyData, legacyKeyData: [oldKeyData]), 1)

        let migrated = try AES.GCM.SealedBox(combined: Data(contentsOf: file))
        XCTAssertEqual(try AES.GCM.open(migrated, using: SymmetricKey(data: currentKeyData)), plaintext)
        XCTAssertThrowsError(try AES.GCM.open(migrated, using: oldKey))
    }

    func testChatRecoveryKeepsCurrentKeyFilesAndMigratesMixedLegacyFiles() throws {
        let chats = tmp.appendingPathComponent("chats", isDirectory: true)
        try FileManager.default.createDirectory(at: chats, withIntermediateDirectories: true)
        let oldKeyData = Data(repeating: 0x33, count: 32)
        let currentKeyData = Data(repeating: 0x44, count: 32)
        let currentFile = chats.appendingPathComponent("current.json.enc")
        let legacyFile = chats.appendingPathComponent("legacy.json.enc")
        let currentEnvelope = try XCTUnwrap(try AES.GCM.seal(
            Data("current".utf8), using: SymmetricKey(data: currentKeyData)).combined)
        try currentEnvelope.write(to: currentFile)
        try XCTUnwrap(try AES.GCM.seal(
            Data("legacy".utf8), using: SymmetricKey(data: oldKeyData)).combined).write(to: legacyFile)

        XCTAssertEqual(try DataMigration.migrateEncryptedChats(
            in: chats, currentKeyData: currentKeyData, legacyKeyData: [oldKeyData]), 1)
        XCTAssertEqual(try Data(contentsOf: currentFile), currentEnvelope,
                       "a newer current-key chat must not be rewritten")
        let migrated = try AES.GCM.SealedBox(combined: Data(contentsOf: legacyFile))
        XCTAssertEqual(try AES.GCM.open(migrated, using: SymmetricKey(data: currentKeyData)),
                       Data("legacy".utf8))
    }

    func testUnknownEncryptedChatPreventsEveryRewriteForSafeRetry() throws {
        let chats = tmp.appendingPathComponent("chats", isDirectory: true)
        try FileManager.default.createDirectory(at: chats, withIntermediateDirectories: true)
        let oldKeyData = Data(repeating: 0x55, count: 32)
        let currentKeyData = Data(repeating: 0x66, count: 32)
        let unknownKeyData = Data(repeating: 0x77, count: 32)
        let recoverable = chats.appendingPathComponent("a-recoverable.json.enc")
        let unknown = chats.appendingPathComponent("z-unknown.json.enc")
        try XCTUnwrap(try AES.GCM.seal(Data("recoverable".utf8),
            using: SymmetricKey(data: oldKeyData)).combined).write(to: recoverable)
        try XCTUnwrap(try AES.GCM.seal(Data("unknown".utf8),
            using: SymmetricKey(data: unknownKeyData)).combined).write(to: unknown)
        let original = try Data(contentsOf: recoverable)

        XCTAssertThrowsError(try DataMigration.migrateEncryptedChats(
            in: chats, currentKeyData: currentKeyData, legacyKeyData: [oldKeyData]))
        XCTAssertEqual(try Data(contentsOf: recoverable), original,
                       "preflight must leave recoverable chats untouched when any envelope is unknown")
    }

    // MARK: - Test-host guard (regression: `xcodebuild test` must not move real data)

    func testRunIfNeededIsNoOpUnderXCTestHost() {
        // Running the app as a unit-test host executes main() and thus
        // runIfNeeded; the XCTestConfigurationFilePath guard must make it bail
        // before it marks itself done or touches the real user library.
        let defaults = freshSuite()
        DataMigration.runIfNeeded(
            environment: ["XCTestConfigurationFilePath": "/tmp/x.xctestconfiguration"],
            defaults: defaults)
        XCTAssertFalse(defaults.bool(forKey: "lokalbotv3.migratedFromV2"),
                       "migration must not run (or mark itself done) under an XCTest host")
    }

    func testLegacyMigrationIsReleaseOnlyAndHonorsEveryStorageOverride() {
        let defaults = freshSuite()
        XCTAssertTrue(DataMigration.shouldRun(environment: [:], defaults: defaults,
                                              identity: .release, arguments: []))
        for identity in [AppIdentifiers.Identity.development, .uiTestHost] {
            XCTAssertFalse(DataMigration.shouldRun(environment: [:], defaults: defaults,
                                                   identity: identity, arguments: []))
            DataMigration.runIfNeeded(environment: [:], defaults: defaults,
                                       identity: identity, arguments: [])
        }
        XCTAssertFalse(defaults.bool(forKey: "lokalbot.migratedFromDotenvV3"))
        XCTAssertFalse(defaults.bool(forKey: "lokalbotv3.migratedFromV2"))
        XCTAssertFalse(DataMigration.shouldRun(environment: ["LOKALBOT_STORAGE_ROOT": tmp.path],
                                               defaults: defaults, identity: .release, arguments: []))
        XCTAssertFalse(DataMigration.shouldRun(environment: [:], defaults: defaults, identity: .release,
                                               arguments: ["app", "--lokalbot-storage-root", tmp.path]))
        defaults.set(tmp.path, forKey: UITestRuntime.storageRootKey)
        XCTAssertFalse(DataMigration.shouldRun(environment: [:], defaults: defaults,
                                               identity: .release, arguments: []))
    }
}
