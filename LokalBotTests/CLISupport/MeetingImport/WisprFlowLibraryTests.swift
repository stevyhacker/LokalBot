import SQLite3
import XCTest
@testable import LokalBot

final class WisprFlowLibraryTests: XCTestCase {
    private let fileManager = FileManager.default

    func testDictionaryOpenedImmutableLeavesNothingBehind() throws {
        let folder = try temporaryFolder("wispr-library")
        sqlite3_close(try makeLibrary(in: folder, keepOpenInWAL: false))
        let database = folder.appendingPathComponent("flow.sqlite")
        let before = listing(folder)
        let bytes = try Data(contentsOf: database)

        let entries = try WisprFlowLibrary.dictionary(at: database)

        assertEntries(entries)
        XCTAssertEqual(listing(folder), before, "no -wal, -shm, or journal is created")
        XCTAssertEqual(try Data(contentsOf: database), bytes)
        XCTAssertEqual(try WisprFlowLibrary.dictionary(at: folder), entries, "picking the folder reads flow.sqlite in it")
    }

    func testDictionaryWithChangesStillInTheWriteAheadLog() throws {
        let folder = try temporaryFolder("wispr-library-wal")
        let writer = try makeLibrary(in: folder, keepOpenInWAL: true)
        defer { sqlite3_close(writer) }
        let database = folder.appendingPathComponent("flow.sqlite")
        let log = URL(fileURLWithPath: database.path + "-wal")
        XCTAssertGreaterThan((try log.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0, 0)
        let mainBytes = try Data(contentsOf: database)
        let logBytes = try Data(contentsOf: log)
        let snapshotsBefore = try snapshotFolders()

        let entries = try WisprFlowLibrary.dictionary(at: database)

        assertEntries(entries)
        XCTAssertEqual(try Data(contentsOf: database), mainBytes)
        XCTAssertEqual(try Data(contentsOf: log), logBytes)
        XCTAssertEqual(try snapshotFolders(), snapshotsBefore, "the private copy is removed")
    }

    func testAnOlderSchemaWithoutSnippetOrStarColumnsStillReads() throws {
        let folder = try temporaryFolder("wispr-library-old")
        let database = folder.appendingPathComponent("flow.sqlite")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(database.path, &db), SQLITE_OK)
        try exec(db, """
            CREATE TABLE SequelizeMeta (name VARCHAR(255) PRIMARY KEY);
            CREATE TABLE Dictionary (id VARCHAR(36) PRIMARY KEY, phrase VARCHAR(255), replacement VARCHAR(255), isDeleted TINYINT(1));
            INSERT INTO Dictionary VALUES ('1', 'Orion Launch', NULL, 0), ('2', 'brb', 'be right back', 0);
            """)
        sqlite3_close(db)

        let entries = try WisprFlowLibrary.dictionary(at: database)

        XCTAssertEqual(entries.map(\.phrase), ["Orion Launch", "brb"])
        XCTAssertEqual(entries.map(\.isSnippet), [nil, nil], "a missing column is unknown, not false")
        XCTAssertEqual(entries.map(\.isStarred), [false, false])
    }

    func testAnotherAppsDatabaseIsRefusedWithoutQuotingIt() throws {
        let folder = try temporaryFolder("wispr-not-library")
        let other = folder.appendingPathComponent("flow.sqlite")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(other.path, &db), SQLITE_OK)
        try exec(db, "CREATE TABLE notes (id INTEGER PRIMARY KEY, body TEXT); INSERT INTO notes (body) VALUES ('secret');")
        sqlite3_close(db)
        XCTAssertThrowsError(try WisprFlowLibrary.dictionary(at: other)) { error in
            guard case .unreadable(_, let reason) = error as? ExternalImportError else {
                return XCTFail("expected unreadable, got \(error)")
            }
            XCTAssertFalse(reason.contains("secret"))
        }
    }

    func testAMissingDatabaseIsNotFound() throws {
        let folder = try temporaryFolder("wispr-empty")
        XCTAssertThrowsError(try WisprFlowLibrary.dictionary(at: folder)) { error in
            guard case .notFound = error as? ExternalImportError else { return XCTFail("expected notFound, got \(error)") }
        }
    }

    func testDefaultLocation() {
        XCTAssertEqual(WisprFlowLibrary.defaultLocation, "~/Library/Application Support/Wispr Flow/flow.sqlite")
    }

    private func assertEntries(_ entries: [WisprFlowLibrary.DictionaryEntry], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(entries, [
            .init(phrase: "Orion Launch", replacement: nil, isSnippet: false, isDeleted: false, isStarred: true,
                  timesUsed: 12, lastUsed: "2026-10-01 09:00:00.000 +00:00"),
            .init(phrase: "mila", replacement: "Mila Novak", isSnippet: false, isDeleted: false, isStarred: false,
                  timesUsed: 3, lastUsed: nil),
            .init(phrase: "addr", replacement: "12 Example Street", isSnippet: true, isDeleted: false, isStarred: false,
                  timesUsed: 0, lastUsed: nil),
            .init(phrase: "Old Term", replacement: nil, isSnippet: false, isDeleted: true, isStarred: false,
                  timesUsed: 1, lastUsed: nil),
        ], file: file, line: line)
    }

    private func makeLibrary(in folder: URL, keepOpenInWAL: Bool) throws -> OpaquePointer? {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(folder.appendingPathComponent("flow.sqlite").path, &db), SQLITE_OK)
        if keepOpenInWAL { try exec(db, "PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0;") }
        try exec(db, """
            CREATE TABLE SequelizeMeta (name VARCHAR(255) PRIMARY KEY);
            INSERT INTO SequelizeMeta VALUES ('20240510212733-create-dictionary.js');
            CREATE TABLE Dictionary (id VARCHAR(36) PRIMARY KEY, phrase VARCHAR(255), replacement VARCHAR(255),
                teamDictionaryId VARCHAR(36), lastUsed DATETIME, frequencyUsed INTEGER, remoteFrequencyUsed INTEGER,
                manualEntry TINYINT(1), createdAt DATETIME, modifiedAt DATETIME, isDeleted TINYINT(1), source VARCHAR(255),
                isSnippet TINYINT(1), observedSource VARCHAR(255), isStarred TINYINT(1), replacementHtml TEXT);
            CREATE TABLE History (transcriptEntityId VARCHAR(36) PRIMARY KEY, asrText TEXT, editedText TEXT);
            INSERT INTO History VALUES ('h1', 'never read', 'never read either');
            """)
        try exec(db, """
            INSERT INTO Dictionary (id, phrase, replacement, lastUsed, frequencyUsed, isDeleted, source, isSnippet, isStarred) VALUES
                ('1', 'Orion Launch', NULL, '2026-10-01 09:00:00.000 +00:00', 12, 0, 'manual', 0, 1),
                ('2', 'mila', 'Mila Novak', NULL, 3, 0, 'user_edits', 0, 0),
                ('3', 'addr', '12 Example Street', NULL, 0, 0, 'manual', 1, 0),
                ('4', 'Old Term', '', NULL, 1, 1, 'user_edits', 0, 0);
            """)
        return db
    }

    private func temporaryFolder(_ name: String) throws -> URL {
        let url = fileManager.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func listing(_ folder: URL) -> [String] {
        (fileManager.enumerator(atPath: folder.path)?.allObjects as? [String] ?? []).sorted()
    }

    private func snapshotFolders() throws -> Set<String> {
        Set(try fileManager.contentsOfDirectory(atPath: fileManager.temporaryDirectory.path)
            .filter { $0.hasPrefix("lokalbot-import-wispr-db-") })
    }

    private func exec(_ db: OpaquePointer?, _ sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        let status = sqlite3_exec(db, sql, nil, nil, &message)
        defer { sqlite3_free(message) }
        XCTAssertEqual(status, SQLITE_OK, message.map { String(cString: $0) } ?? "")
    }
}
