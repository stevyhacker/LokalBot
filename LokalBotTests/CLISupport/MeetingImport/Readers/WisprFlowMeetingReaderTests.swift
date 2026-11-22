import SQLite3
import XCTest
@testable import LokalBot

final class WisprFlowMeetingReaderTests: XCTestCase {
    private let fileManager = FileManager.default

    func testFolderRoundTrip() throws {
        let folder = try makeWisprFolder("wispr-meetings")

        let scan = try WisprFlowMeetingReader.read(folder)

        XCTAssertEqual(scan.problems, [])
        XCTAssertEqual(scan.meetings.map(\.sourceID), ["m1", "m4"], "deleted and tour meetings are skipped")
        let call = try XCTUnwrap(scan.meetings.first)
        XCTAssertEqual(call.source, .wisprFlow)
        XCTAssertEqual(call.title, "Pricing review")
        XCTAssertEqual(call.startedAt, ISO8601DateFormatter().date(from: "2026-10-01T14:00:00Z"))
        XCTAssertEqual(call.duration, 1_800)
        XCTAssertEqual(call.participants, ["Mila Novak", "Orion Team"])
        XCTAssertEqual(call.notes, "## Summary\n- Prices stay as they are.")
        XCTAssertEqual(call.lines, [
            .init(start: 5, end: 9, speaker: "Ana Example", text: "Hello there.", isMe: true),
            .init(start: 9, end: 3_723, speaker: "Mila Novak", text: "Hi Ana."),
            .init(start: 3_723, speaker: "Speaker 3", text: "One more thing."),
        ], "a malformed line and an empty turn are skipped; ends come from the next turn")
        let notesOnly = scan.meetings[1]
        XCTAssertEqual(notesOnly.lines, [])
        XCTAssertEqual(notesOnly.notes, "Short sync.")
        XCTAssertEqual(notesOnly.duration, 600, "without a recorded length, the end time minus the start")
    }

    func testPickingTheDatabaseFileReadsTheSameMeetings() throws {
        let folder = try makeWisprFolder("wispr-meetings-file")
        let fromFile = try WisprFlowMeetingReader.read(folder.appendingPathComponent("flow.sqlite"))
        XCTAssertEqual(fromFile.meetings, try WisprFlowMeetingReader.read(folder).meetings)
        XCTAssertTrue(WisprFlowMeetingReader.recognizes(folder))
        XCTAssertTrue(WisprFlowMeetingReader.recognizes(folder.appendingPathComponent("flow.sqlite")))
        XCTAssertFalse(WisprFlowMeetingReader.recognizes(try temporaryFolder("wispr-elsewhere")))
    }

    func testPickingTheMeetingsFolderInsideWisprsFolderReadsTheSameMeetings() throws {
        let folder = try makeWisprFolder("wispr-meetings-inner")
        let inner = folder.appendingPathComponent("meetings", isDirectory: true)
        XCTAssertTrue(fileManager.fileExists(atPath: inner.path))
        XCTAssertTrue(WisprFlowMeetingReader.recognizes(inner))
        XCTAssertEqual(try WisprFlowMeetingReader.read(inner).meetings, try WisprFlowMeetingReader.read(folder).meetings)
    }

    func testReadingLeavesWisprsFilesUnchanged() throws {
        let folder = try makeWisprFolder("wispr-meetings-untouched")
        let before = listing(folder)
        let bytes = try Data(contentsOf: folder.appendingPathComponent("flow.sqlite"))

        _ = try WisprFlowMeetingReader.read(folder)

        XCTAssertEqual(listing(folder), before, "no -wal, -shm, or journal is created")
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("flow.sqlite")), bytes)
    }

    func testAnotherAppsDatabaseIsRefusedWithoutQuotingIt() throws {
        let folder = try temporaryFolder("wispr-not-meetings")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(folder.appendingPathComponent("flow.sqlite").path, &db), SQLITE_OK)
        try exec(db, "CREATE TABLE notes (id INTEGER PRIMARY KEY, body TEXT); INSERT INTO notes (body) VALUES ('secret');")
        sqlite3_close(db)
        XCTAssertThrowsError(try WisprFlowMeetingReader.read(folder)) { error in
            guard case .unreadable(_, let reason) = error as? ExternalImportError else {
                return XCTFail("expected unreadable, got \(error)")
            }
            XCTAssertFalse(reason.contains("secret"))
        }
    }

    func testAnUnrelatedFileIsNotTakenForWisprsDatabase() throws {
        let folder = try temporaryFolder("wispr-other-file")
        let other = folder.appendingPathComponent("notes.txt")
        try Data("hello".utf8).write(to: other)
        XCTAssertThrowsError(try WisprFlowMeetingReader.read(other)) { error in
            XCTAssertEqual(error as? ExternalImportError, .unrecognized(.wisprFlow, other.path))
        }
    }

    func testScanThroughTheSourceList() throws {
        let folder = try makeWisprFolder("wispr-meetings-scan")
        let result = ExternalMeetingReaders.scan(.wisprFlow, urls: [folder])
        defer { result.cleanup() }
        XCTAssertEqual(result.scan.meetings.map(\.importKey), ["wispr-flow/m1", "wispr-flow/m4"])
        XCTAssertEqual(ObjectIdentifier(ExternalMeetingReaders.reader(for: .wisprFlow)),
                       ObjectIdentifier(WisprFlowMeetingReader.self))
        XCTAssertEqual(ExternalMeetingSource.wisprFlow.title, "Wispr Flow")
        XCTAssertEqual(WisprFlowMeetingReader.defaultLocations, ["~/Library/Application Support/Wispr Flow"])
    }

    func testTimestamps() {
        XCTAssertEqual(WisprFlowMeetingReader.seconds("05:07"), 307)
        XCTAssertEqual(WisprFlowMeetingReader.seconds("1:02:03"), 3_723)
        XCTAssertEqual(WisprFlowMeetingReader.seconds("125:00"), 7_500)
        XCTAssertNil(WisprFlowMeetingReader.seconds("soon"))
        XCTAssertNil(WisprFlowMeetingReader.seconds("12"))
    }

    private func makeWisprFolder(_ name: String) throws -> URL {
        let folder = try temporaryFolder(name)
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(folder.appendingPathComponent("flow.sqlite").path, &db), SQLITE_OK)
        try exec(db, """
            CREATE TABLE SequelizeMeta (name VARCHAR(255) PRIMARY KEY);
            CREATE TABLE Meetings (id VARCHAR(36) PRIMARY KEY, title VARCHAR(255), createdAt DATETIME, modifiedAt DATETIME,
                isDeleted TINYINT(1), endedAt INTEGER, participantNames TEXT, summary TEXT, speakerMap TEXT,
                isTourDemo TINYINT(1), recordedMs INTEGER);
            CREATE TABLE History (transcriptEntityId VARCHAR(36) PRIMARY KEY, asrText TEXT);
            INSERT INTO History VALUES ('h1', 'never read');
            """)
        let speakerMap = #"{"people":{"p-self":{"name":"Ana Example","origin":"self"},"p-2":{"name":"Mila Novak","origin":"platform"}},"assignments":{"1":{"consensus":"p-self"},"2":{"consensus":"p-2"},"3":{"consensus":""}}}"#
        try exec(db, """
            INSERT INTO Meetings (id, title, createdAt, isDeleted, endedAt, participantNames, summary, speakerMap, isTourDemo, recordedMs) VALUES
                ('m1', ' Pricing review ', '2026-10-01 14:00:00.000 +00:00', 0, 1790866800000, '["Mila Novak","Orion Team"]',
                 '## Summary
            - Prices stay as they are.', '\(speakerMap)', 0, 1800000),
                ('m2', 'Deleted call', '2026-10-02 10:00:00.000 +00:00', 1, 1790935200000, NULL, 'gone', NULL, 0, NULL),
                ('m3', 'Welcome tour', '2026-10-03 10:00:00.000 +00:00', 0, 1791021600000, NULL, 'tour', NULL, 1, NULL),
                ('m4', 'Sync', '2026-10-04 10:00:00.000 +00:00', 0, 1791108600000, NULL, 'Short sync.', NULL, 0, NULL);
            """)
        sqlite3_close(db)
        let transcript = folder.appendingPathComponent("meetings/m1", isDirectory: true)
        try fileManager.createDirectory(at: transcript, withIntermediateDirectories: true)
        try """
            {"id":"a","timestamp":"00:05","text":"Hello there.","speaker":{"id":1,"source":"refined","name":null}}
            not json
            {"id":"b","timestamp":"00:09","text":"Hi Ana.","speaker":{"id":2,"source":"refined","name":null}}
            {"id":"c","timestamp":"00:20","text":"   ","speaker":{"id":2,"source":"refined","name":null}}
            {"id":"d","timestamp":"1:02:03","text":"One more thing.","speaker":{"id":3,"source":"refined","name":null}}
            """.write(to: transcript.appendingPathComponent("refined.ndjson"), atomically: true, encoding: .utf8)
        try #"{"meta":{"v":1,"clock":"x"}}"#.write(to: transcript.appendingPathComponent("live.ndjson"),
                                                  atomically: true, encoding: .utf8)
        return folder
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

    private func exec(_ db: OpaquePointer?, _ sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        let status = sqlite3_exec(db, sql, nil, nil, &message)
        defer { sqlite3_free(message) }
        XCTAssertEqual(status, SQLITE_OK, message.map { String(cString: $0) } ?? "")
    }
}
