import CryptoKit
import SQLite3
import XCTest
@testable import LokalBot

final class ScreenpipeMeetingReaderTests: XCTestCase {
    private func temporaryDirectory(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name) \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// A Screenpipe data folder holding today's database as `db.sqlite`.
    private func currentDataFolder() throws -> (folder: URL, database: URL) {
        let folder = try temporaryDirectory("Screenpipe Data").appendingPathComponent(".screenpipe", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let database = folder.appendingPathComponent("db.sqlite")
        try ScreenpipeFixtures.writeCurrent(to: database)
        return (folder, database)
    }

    func testMeetingRoundTripCombinesLiveAndBackgroundLines() throws {
        let (folder, database) = try currentDataFolder()

        let scan = try ScreenpipeMeetingReader.read(folder)

        XCTAssertEqual(scan.problems, [])
        XCTAssertEqual(scan.meetings.map(\.title),
                       ["Screenpipe conversation", "Screenpipe conversation", "Pricing review", "Google Meet meeting"],
                       "the open meeting and the empty one are left out")
        let pricing = scan.meetings[2]
        XCTAssertEqual(pricing.source, .screenpipe)
        XCTAssertEqual(pricing.sourceID, "meeting-7-" + ExternalImportText.stableID("2026-03-04T10:15:00.120Z").prefix(12))
        XCTAssertEqual(pricing.startedAt, Date(timeIntervalSince1970: 1_772_619_300))
        XCTAssertEqual(pricing.duration, 1_800)
        XCTAssertEqual(pricing.participants, ["Ana Petrović", "Leo"])
        XCTAssertEqual(pricing.notes, ScreenpipeFixtures.pricingNote)
        XCTAssertEqual(pricing.actionItems, [.init(text: "Send the revised deck", owner: "Leo"),
                                             .init(text: "Ana to confirm annual billing")])
        XCTAssertNil(pricing.audioURL, "Screenpipe's audio chunks are not attached")
        XCTAssertEqual(pricing.origin, database)
        XCTAssertEqual(pricing.lines, [
            .init(start: 32, end: 35.5, speaker: nil, text: "Morning, everyone.", isMe: true),
            .init(start: 61, end: 66, speaker: "Ana Petrović", text: "Let's keep the Team plan at fifteen."),
            .init(start: 67, end: 69, speaker: "Unknown #4", text: "Agreed, fifteen works."),
            .init(start: 120, end: nil, speaker: "Leo", text: "Billed annually, then."),
            .init(start: 125.25, end: nil, speaker: "speaker 1", text: "Yes, annually.", isMe: true),
            .init(start: 180, end: nil, speaker: "Ana Petrović", text: "Space separated timestamps still count."),
        ], "hallucinated, cloud, blank, and duplicated live lines are dropped; nanosecond and space-separated times parse")

        let notesOnly = scan.meetings[3]
        XCTAssertEqual(notesOnly.lines, [])
        XCTAssertEqual(notesOnly.notes, "## Summary\nQuick sync on hiring.")
        XCTAssertEqual(notesOnly.duration, 1_200)
        XCTAssertEqual(notesOnly.participants, [])

        let scanned = ExternalMeetingReaders.scan(.screenpipe, urls: [folder])
        scanned.cleanup()
        XCTAssertEqual(scanned.scan.meetings.map(\.sourceID), scan.meetings.map(\.sourceID))
    }

    func testAudioFromBeforeMeetingsIsSplitIntoConversationsAtSilences() throws {
        let scan = try ScreenpipeMeetingReader.read(try currentDataFolder().database)

        let garden = scan.meetings[0]
        XCTAssertEqual(garden.startedAt, Date(timeIntervalSince1970: 1_768_039_200))
        XCTAssertEqual(garden.duration, 125)
        XCTAssertEqual(garden.lines.map(\.start), [0, 31, 120])
        XCTAssertEqual(garden.lines.map(\.isMe), [true, false, true])
        XCTAssertEqual(garden.participants, ["Ana Petrović"])
        XCTAssertTrue(garden.sourceID.hasPrefix("conversation-11-"))
        let plumber = scan.meetings[1]
        XCTAssertEqual(plumber.startedAt, Date(timeIntervalSince1970: 1_768_041_000), "the one-word fragment between is skipped")
        XCTAssertEqual(plumber.duration, 69)
        XCTAssertEqual(plumber.lines.map(\.speaker), [nil, "Unknown #4"])
        XCTAssertEqual(plumber.participants, [], "an unnamed voice is not a participant")
        XCTAssertFalse(scan.meetings.contains { $0.lines.contains { $0.text.contains("after the call") } },
                       "audio outside meetings once Screenpipe keeps meetings is not imported")
    }

    func testOldDatabaseWithoutMeetingsTellsTheMicrophoneFromChunkNames() throws {
        let file = try temporaryDirectory("old").appendingPathComponent("old.sqlite")
        try ScreenpipeFixtures.writeOld(to: file)

        let scan = try ScreenpipeMeetingReader.read(file)

        XCTAssertEqual(scan.meetings.count, 1)
        let meeting = try XCTUnwrap(scan.meetings.first)
        XCTAssertEqual(meeting.startedAt, Date(timeIntervalSince1970: 1_727_773_200.25))
        XCTAssertEqual(meeting.lines.map(\.start), [0, 29.75, 89.75], "one timestamp is unix seconds")
        XCTAssertEqual(meeting.lines.map(\.isMe), [true, false, true])
        XCTAssertTrue(meeting.lines.allSatisfy { $0.end == nil && $0.speaker == nil })
    }

    func testUpgradedStorageReadsTheIndexAndFillsCompressedMeetingsFromTheOriginal() throws {
        let folder = try temporaryDirectory("upgraded")
        try ScreenpipeFixtures.writeUpgradedFolder(to: folder)
        let index = folder.appendingPathComponent("storage/\(ScreenpipeFixtures.generation)/index.sqlite")

        let scan = try ScreenpipeMeetingReader.read(folder)

        XCTAssertEqual(scan.meetings.map(\.title), ["Design crit", "Roadmap"], "the index's newer title wins")
        XCTAssertEqual(scan.meetings[0].lines.map(\.text), ["The new icons test well."])
        XCTAssertEqual(scan.meetings[0].origin.lastPathComponent, "db.sqlite")
        XCTAssertEqual(scan.meetings[1].origin, index)
        XCTAssertEqual(scan.problems.map(\.path), [index.path])
        XCTAssertTrue(scan.problems[0].reason.hasPrefix("1 meeting keeps its transcript in Screenpipe's compressed storage"))

        let indexOnly = try ScreenpipeMeetingReader.read(index)
        XCTAssertEqual(indexOnly.meetings.map(\.title), ["Roadmap"], "a meeting is never imported without its compressed text")
        XCTAssertTrue(indexOnly.problems.first?.reason.hasPrefix("2 meetings keep their transcript") == true)
    }

    func testRecognizesScreenpipeDatabasesAndDataFolders() throws {
        let (folder, database) = try currentDataFolder()
        let root = folder.deletingLastPathComponent()
        let upgraded = root.appendingPathComponent("upgraded", isDirectory: true)
        try FileManager.default.createDirectory(at: upgraded, withIntermediateDirectories: true)
        try ScreenpipeFixtures.writeUpgradedFolder(to: upgraded)
        let locked = root.appendingPathComponent("locked.sqlite")
        try ScreenpipeFixtures.writeLocked(to: locked)
        let text = root.appendingPathComponent("notes.sqlite")
        try Data("just text".utf8).write(to: text)
        let wal = root.appendingPathComponent("db.sqlite-wal")
        try Data("SQLite format 3\u{0}".utf8).write(to: wal)

        XCTAssertTrue(ScreenpipeMeetingReader.recognizes(database))
        XCTAssertTrue(ScreenpipeMeetingReader.recognizes(folder))
        XCTAssertTrue(ScreenpipeMeetingReader.recognizes(upgraded))
        XCTAssertTrue(ScreenpipeMeetingReader.recognizes(locked), "a locked vault is read to say so")
        XCTAssertFalse(ScreenpipeMeetingReader.recognizes(text))
        XCTAssertFalse(ScreenpipeMeetingReader.recognizes(wal))
        XCTAssertFalse(ScreenpipeMeetingReader.recognizes(root.appendingPathComponent("missing.sqlite")))
        XCTAssertFalse(ScreenpipeMeetingReader.recognizes(
            upgraded.appendingPathComponent("storage/\(ScreenpipeFixtures.generation)/recovered-empty-source-1.sqlite")))
        XCTAssertFalse(ScreenpipeMeetingReader.recognizes(try temporaryDirectory("empty")))
        XCTAssertEqual(ScreenpipeMeetingReader.defaultLocations, ["~/.screenpipe"])
        XCTAssertFalse(ScreenpipeMeetingReader.exportHint.isEmpty)
    }

    func testFolderWithAnUnreadableDatabaseStillReadsTheOthers() throws {
        let folder = try temporaryDirectory("Copies")
        try ScreenpipeFixtures.writeOld(to: folder.appendingPathComponent("a-screenpipe.sqlite"))
        try ScreenpipeFixtures.writeBroken(to: folder.appendingPathComponent("b-broken.sqlite"))
        try ScreenpipeFixtures.writeOtherApp(to: folder.appendingPathComponent("c-other-app.db"))
        try Data("readme".utf8).write(to: folder.appendingPathComponent("readme.txt"))

        let scan = try ScreenpipeMeetingReader.read(folder)

        XCTAssertEqual(scan.meetings.count, 1)
        XCTAssertEqual(scan.problems.map { URL(fileURLWithPath: $0.path).lastPathComponent }, ["b-broken.sqlite"],
                       "another app's database is skipped, not reported")
        XCTAssertTrue(scan.problems[0].reason.hasPrefix("SQLite couldn't read it"))
    }

    func testLockedVaultAndOtherFilesAreReportedWithoutTheirContent() throws {
        let folder = try temporaryDirectory("locked")
        let locked = folder.appendingPathComponent("db.sqlite")
        try ScreenpipeFixtures.writeLocked(to: locked)
        let other = folder.appendingPathComponent("other-app.db")
        try ScreenpipeFixtures.writeOtherApp(to: other)

        let scan = try ScreenpipeMeetingReader.read(folder)
        XCTAssertEqual(scan.meetings, [])
        XCTAssertEqual(scan.problems.count, 1)
        XCTAssertTrue(scan.problems[0].reason.contains("vault is locked"))
        XCTAssertThrowsError(try ScreenpipeMeetingReader.read(locked)) { error in
            guard case .unreadable(let name, let reason) = error as? ExternalImportError else {
                return XCTFail("unexpected \(error)")
            }
            XCTAssertEqual(name, "db.sqlite")
            XCTAssertTrue(reason.contains("vault is locked"))
        }
        XCTAssertThrowsError(try ScreenpipeMeetingReader.read(other)) { error in
            XCTAssertEqual(error as? ExternalImportError, .unrecognized(.screenpipe, "other-app.db"))
        }
    }

    func testSourceIDsAreStableAndTheDatabaseIsNeverTouched() throws {
        let (folder, database) = try currentDataFolder()
        let listing = { (try? FileManager.default.subpathsOfDirectory(atPath: folder.path))?.sorted() ?? [] }
        let fingerprint = { () throws -> (String, Date?) in
            let digest = SHA256.hash(data: try Data(contentsOf: database)).map { String(format: "%02x", $0) }.joined()
            return (digest, try FileManager.default.attributesOfItem(atPath: database.path)[.modificationDate] as? Date)
        }
        let filesBefore = listing()
        let before = try fingerprint()

        let first = try ScreenpipeMeetingReader.read(folder)
        let second = try ScreenpipeMeetingReader.read(database)

        XCTAssertEqual(first.meetings.map(\.sourceID), second.meetings.map(\.sourceID))
        XCTAssertEqual(Set(first.meetings.map(\.sourceID)).count, 4)
        XCTAssertEqual(listing(), filesBefore, "no -wal or -shm file is created")
        let after = try fingerprint()
        XCTAssertEqual(after.0, before.0)
        XCTAssertEqual(after.1, before.1)
    }

    func testARunningScreenpipesWriteAheadLogIsIgnoredAndLeftAlone() throws {
        let (folder, database) = try currentDataFolder()
        var writer: OpaquePointer?
        XCTAssertEqual(sqlite3_open(database.path, &writer), SQLITE_OK)
        defer { sqlite3_close(writer) }
        XCTAssertEqual(sqlite3_exec(writer, """
            PRAGMA wal_autocheckpoint=0;
            INSERT INTO meetings (id, meeting_start, meeting_end, meeting_app, title, note) VALUES
                (11, '2026-03-07T08:00:00.000Z', '2026-03-07T08:30:00.000Z', 'Zoom', 'Written after', 'Fresh note.');
            """, nil, nil, nil), SQLITE_OK)
        let wal = folder.appendingPathComponent("db.sqlite-wal")
        let size = { (try? FileManager.default.attributesOfItem(atPath: wal.path)[.size] as? NSNumber)?.intValue }
        let walBefore = size()
        XCTAssertGreaterThan(walBefore ?? 0, 0)

        let scan = try ScreenpipeMeetingReader.read(folder)

        XCTAssertEqual(scan.meetings.count, 4, "what is only in the write-ahead log isn't read yet")
        XCTAssertEqual(size(), walBefore)
    }

    func testActionItemsUnderTheHeadingsScreenpipeNotesUse() {
        XCTAssertEqual(ScreenpipeMeetingReader.actionItems(inNotes: """
            Next steps:
            1. Book the venue
            2) @Mira draft the agenda

            **Follow-ups**
            * **Ana Petrović** — Share the recording
            - [x] Done already

            ## Action items
            ### Leo
            - Check the contract
            ## Notes
            - Not an action
            """), [
            .init(text: "Book the venue"), .init(text: "draft the agenda", owner: "Mira"),
            .init(text: "Share the recording", owner: "Ana Petrović"), .init(text: "Done already"),
            .init(text: "Check the contract", owner: "Leo"),
        ])
        XCTAssertEqual(ScreenpipeMeetingReader.actionItems(inNotes: """
            ## Action items
            - **Leo**: Send the deck
            ### Decisions
            - Keep the Team plan
            """), [.init(text: "Send the deck", owner: "Leo")], "a deeper section heading ends the list")
        XCTAssertEqual(ScreenpipeMeetingReader.actionItems(inNotes: "## Transactions\n- Paid the invoice"), [])
    }
}

/// Synthetic Screenpipe databases with the columns Screenpipe's migrations
/// create (crates/screenpipe-db/src/migrations). Nothing here is real data.
private enum ScreenpipeFixtures {
    struct Failure: Error, CustomStringConvertible {
        var description: String
    }

    static let migrations = """
        CREATE TABLE _sqlx_migrations (version BIGINT PRIMARY KEY, description TEXT NOT NULL,
            installed_on TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP, success BOOLEAN NOT NULL,
            checksum BLOB NOT NULL, execution_time BIGINT NOT NULL);
        INSERT INTO _sqlx_migrations VALUES (20240703111257, 'screenpipe', '2025-11-02 08:00:00', 1, x'00', 1);
        INSERT INTO _sqlx_migrations VALUES (20260225000000, 'create meetings', '2026-02-25 09:00:00', 1, x'00', 1);
        """

    /// Today's schema; `archived` adds the columns compressed storage adds.
    static func schema(archived: Bool = false) -> String {
        let archive = archived
            ? ", _archive_file INTEGER, _archive_mask INTEGER NOT NULL DEFAULT 1, _archive_generation INTEGER NOT NULL DEFAULT 1"
            : ""
        return migrations + """
            CREATE TABLE audio_chunks (id INTEGER PRIMARY KEY AUTOINCREMENT, file_path TEXT NOT NULL, timestamp TIMESTAMP,
                transcription_status TEXT NOT NULL DEFAULT 'pending');
            CREATE TABLE audio_transcriptions (id INTEGER PRIMARY KEY AUTOINCREMENT, audio_chunk_id INTEGER NOT NULL,
                offset_index INTEGER NOT NULL, timestamp TIMESTAMP NOT NULL, transcription TEXT NOT NULL,
                device TEXT NOT NULL DEFAULT '', is_input_device BOOLEAN NOT NULL DEFAULT TRUE, speaker_id INTEGER,
                transcription_engine TEXT NOT NULL DEFAULT 'Whisper', start_time REAL, end_time REAL,
                text_length INTEGER, redacted_at INTEGER\(archive),
                FOREIGN KEY (audio_chunk_id) REFERENCES audio_chunks(id));
            CREATE VIRTUAL TABLE audio_transcriptions_fts USING fts5(transcription, device, tokenize='unicode61');
            CREATE TABLE speakers (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, metadata JSON,
                hallucination BOOLEAN DEFAULT FALSE, embedding_count INTEGER DEFAULT 0);
            CREATE TABLE meetings (id INTEGER PRIMARY KEY AUTOINCREMENT, meeting_start TEXT NOT NULL, meeting_end TEXT,
                meeting_app TEXT NOT NULL, title TEXT, attendees TEXT, detection_source TEXT NOT NULL DEFAULT 'app',
                created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')), note TEXT, end_reason TEXT,
                calendar_event_id TEXT);
            CREATE UNIQUE INDEX idx_meetings_single_open ON meetings((1)) WHERE meeting_end IS NULL;
            CREATE TABLE meeting_transcript_segments (id INTEGER PRIMARY KEY AUTOINCREMENT, meeting_id INTEGER NOT NULL,
                provider TEXT NOT NULL, model TEXT, item_id TEXT NOT NULL, device_name TEXT NOT NULL DEFAULT '',
                device_type TEXT NOT NULL DEFAULT '', speaker_name TEXT, transcript TEXT NOT NULL, captured_at TEXT NOT NULL,
                created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')), speaker_id INTEGER,
                stream_id TEXT NOT NULL DEFAULT 'legacy', session_speaker_id TEXT\(archive),
                FOREIGN KEY (meeting_id) REFERENCES meetings(id) ON DELETE CASCADE);
            """
    }

    static let pricingNote = """
        Prep: bring the seat numbers.

        ## Summary
        Pricing stays at fifteen per seat.

        ### Action items
        - [ ] **Leo**: Send the revised deck
        - Ana to confirm annual billing

        ### Decisions
        - Keep the Team plan
        """

    /// A current database: four meetings (one still open, one empty), live
    /// captions, background lines, and audio from before meetings existed.
    static func writeCurrent(to url: URL) throws {
        let mic = "MacBook Pro Microphone"
        let system = "System Audio"
        let model = "whisper-large-v3-turbo"
        try execute(url, "PRAGMA journal_mode=WAL;" + schema() + """
            INSERT INTO speakers (id, name, hallucination) VALUES (3, 'Ana Petrović', 0), (4, NULL, 0),
                (5, 'Background TV', 1), (6, 'Leo', 0);
            INSERT INTO audio_chunks (id, file_path, timestamp) VALUES
                (1, '/Users/someone/.screenpipe/data/\(mic) (input)_2026-03-04_10-15-30.mp4', '2026-03-04T10:15:30.000000+00:00'),
                (2, '/Users/someone/.screenpipe/data/\(system) (output)_2026-03-04_10-16-00.mp4', '2026-03-04T10:16:00.000000000+00:00'),
                (3, 'cloud://chunks/remote.mp4', '2026-03-04T10:20:00.000000+00:00'),
                (4, '/Users/someone/.screenpipe/data/\(system) (output)_2026-03-04_10-17-00.mp4', '2026-03-04T10:17:00.000000+00:00'),
                (5, '/Users/someone/.screenpipe/data/\(mic) (input)_2026-01-10_10-00-00.mp4', '2026-01-10T10:00:00.000000+00:00'),
                (6, '/Users/someone/.screenpipe/data/\(system) (output)_2026-01-10_10-00-30.mp4', '2026-01-10T10:00:30.000000+00:00');
            INSERT INTO audio_transcriptions (id, audio_chunk_id, offset_index, timestamp, transcription, device,
                is_input_device, speaker_id, transcription_engine, start_time, end_time) VALUES
                (1, 1, 0, '2026-03-04T10:15:30.000000+00:00', 'Morning, everyone.', '\(mic)', 1, NULL, '\(model)', 2.0, 5.5),
                (2, 2, 0, '2026-03-04T10:16:00.000000000+00:00', 'Let''s keep the Team plan at fifteen.', '\(system)', 0, 3, '\(model)', 1.0, 6.0),
                (3, 2, 1, '2026-03-04T10:16:00.000000000+00:00', 'Agreed, fifteen works.', '\(system)', 0, 4, '\(model)', 7.0, 9.0),
                (4, 2, 2, '2026-03-04T10:16:00.000000000+00:00', 'Breaking news tonight.', '\(system)', 0, 5, '\(model)', 10.0, 12.0),
                (5, 3, 0, '2026-03-04T10:20:00.000000+00:00', 'From another Mac.', 'MacBook Air Microphone', 1, NULL, '\(model)', 0.0, 2.0),
                (6, 4, 0, '2026-03-04T10:17:00+00:00', 'Billed annually, then.', '\(system)', 0, NULL, 'live', 0.0, NULL),
                (7, 4, 1, '2026-03-04 10:18:00', 'Space separated timestamps still count.', '\(system)', 0, 3, '\(model)', NULL, NULL),
                (8, 1, 1, '2026-03-04T11:30:00.000000+00:00', 'Talking to myself after the call.', '\(mic)', 1, NULL, '\(model)', 0.0, 3.0),
                (9, 1, 2, '2026-03-05T09:05:00.000000+00:00', 'This call is still going.', '\(mic)', 1, NULL, '\(model)', 0.0, 2.0),
                (10, 1, 3, '2026-03-04T10:19:00.000000+00:00', '   ', '\(mic)', 1, NULL, '\(model)', 0.0, 1.0),
                (11, 5, 0, '2026-01-10T10:00:00.000000+00:00', 'So the plan for the garden is to start with tomatoes and peppers in the raised beds this spring.', '\(mic)', 1, NULL, '\(model)', 0.0, 6.0),
                (12, 6, 0, '2026-01-10T10:00:30.000000+00:00', 'That works, and we should add basil along the edges because it keeps pests away from the tomatoes.', '\(system)', 0, 3, '\(model)', 1.0, 8.0),
                (13, 5, 1, '2026-01-10T10:02:00.000000+00:00', 'Great, I will order the seeds this week and set up the drip line on Saturday.', '\(mic)', 1, NULL, '\(model)', 0.0, 5.0),
                (14, 5, 2, '2026-01-10T10:15:00.000000+00:00', 'Okay.', '\(mic)', 1, NULL, '\(model)', 0.0, 1.0),
                (15, 5, 3, '2026-01-10T10:30:00.000000+00:00', 'Did you get a chance to look at the plumber quote for the kitchen sink and the dishwasher line?', '\(mic)', 1, NULL, '\(model)', 0.0, 6.0),
                (16, 6, 1, '2026-01-10T10:31:00.000000+00:00', 'Yes, it came in under budget, so I booked them for next Tuesday morning before work.', '\(system)', 0, 4, '\(model)', 2.0, 9.0);
            INSERT INTO meetings (id, meeting_start, meeting_end, meeting_app, title, attendees, detection_source, created_at, note, end_reason) VALUES
                (7, '2026-03-04T10:15:00.000Z', '2026-03-04T10:45:00.000Z', 'Zoom', 'Pricing review', 'Ana Petrović, Leo', 'calendar', '2026-03-04T10:15:00.120Z', '\(quoted(pricingNote))', 'explicit_stop'),
                (8, '2026-03-04T14:00:00.000Z', '2026-03-04T14:20:00.000Z', 'Google Meet', NULL, NULL, 'app', '2026-03-04T14:00:00.050Z', '## Summary
            Quick sync on hiring.', NULL),
                (9, '2026-03-05T09:00:00.000Z', NULL, 'Zoom', 'Still running', NULL, 'app', '2026-03-05T09:00:00.010Z', NULL, NULL),
                (10, '2026-03-06T08:00:00.000Z', '2026-03-06T08:30:00.000Z', 'manual', NULL, NULL, 'manual', '2026-03-06T08:00:00.000Z', NULL, NULL);
            INSERT INTO meeting_transcript_segments (id, meeting_id, provider, model, item_id, device_name, device_type,
                speaker_name, transcript, captured_at, speaker_id) VALUES
                (1, 7, 'deepgram', 'nova-3', 'item-1', '\(system)', 'output', 'speaker 2', 'Billed annually, then.', '2026-03-04T10:17:00+00:00', 6),
                (2, 7, 'deepgram', 'nova-3', 'item-2', '\(mic)', 'input', 'speaker 1', 'Yes, annually.', '2026-03-04T10:17:05.250+00:00', NULL),
                (3, 9, 'deepgram', 'nova-3', 'item-3', '\(system)', 'output', 'speaker 1', 'Still going live.', '2026-03-05T09:01:00+00:00', NULL);
            """)
    }

    /// A 2024 database: no meetings, speakers, or segment times; the device
    /// columns hold their defaults, so only chunk names tell the devices
    /// apart. One timestamp is unix seconds.
    static func writeOld(to url: URL) throws {
        try execute(url, """
            CREATE TABLE audio_chunks (id INTEGER PRIMARY KEY AUTOINCREMENT, file_path TEXT NOT NULL, timestamp TIMESTAMP);
            CREATE TABLE audio_transcriptions (id INTEGER PRIMARY KEY AUTOINCREMENT, audio_chunk_id INTEGER NOT NULL,
                offset_index INTEGER NOT NULL, timestamp TIMESTAMP NOT NULL, transcription TEXT NOT NULL,
                transcription_engine TEXT NOT NULL DEFAULT 'Whisper', device TEXT NOT NULL DEFAULT '',
                is_input_device BOOLEAN NOT NULL DEFAULT TRUE);
            INSERT INTO audio_chunks VALUES (1, 'data/MacBook Pro Microphone (input)_2024-10-01_09-00-00.mp4', '2024-10-01 09:00:00');
            INSERT INTO audio_chunks VALUES (2, 'data/Display Audio (output)_2024-10-01_09-00-30.mp4', '2024-10-01 09:00:30');
            INSERT INTO audio_transcriptions (audio_chunk_id, offset_index, timestamp, transcription) VALUES
                (1, 0, '2024-10-01 09:00:00.250+00:00', 'Can everyone hear me okay before we start going through the quarterly roadmap together?'),
                (2, 0, 1727773230, 'Loud and clear, let us begin with the mobile release and then cover the hiring plan for next quarter.'),
                (1, 1, '2024-10-01T09:01:30Z', 'Sounds good.');
            """)
    }

    static let generation = "9f1c2d3e-4b5a-4c6d-8e7f-0a1b2c3d4e5f"

    /// A data folder after Screenpipe upgraded its storage: `storage.json`,
    /// the index (one meeting's text compressed away, one resident, one
    /// compressed and nowhere else), and the original `db.sqlite` it kept.
    static func writeUpgradedFolder(to folder: URL) throws {
        let storage = folder.appendingPathComponent("storage/\(generation)", isDirectory: true)
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        let descriptor = """
            {"format":1,"mode":"hybrid-parquet-v1","database_id":"5b0c6a2e-1d3f-4e5a-9b8c-7d6e5f4a3b2c",
             "generation":"\(generation)","source_continuity":true,"index":"storage/\(generation)/index.sqlite",
             "payloads":"storage/\(generation)/payloads","capabilities":["parquet-bulk-v1"]}
            """
        try Data(descriptor.utf8).write(to: folder.appendingPathComponent("storage.json"))
        try Data("SQLite format 3\u{0}".utf8).write(to: storage.appendingPathComponent("recovered-empty-source-1.sqlite"))
        let meetings = """
            INSERT INTO audio_chunks (id, file_path, timestamp) VALUES (1, 'data/Mic (input)_2026-04-01.mp4', '2026-04-01T09:00:00+00:00');
            INSERT INTO meetings (id, meeting_start, meeting_end, meeting_app, title, created_at) VALUES
                (21, '2026-04-01T09:00:00.000Z', '2026-04-01T09:30:00.000Z', 'Zoom', 'Design crit', '2026-04-01T09:00:00.001Z');
            """
        try execute(storage.appendingPathComponent("index.sqlite"), schema(archived: true) + meetings + """
            INSERT INTO meetings (id, meeting_start, meeting_end, meeting_app, title, created_at) VALUES
                (22, '2026-04-02T09:00:00.000Z', '2026-04-02T09:30:00.000Z', 'Zoom', 'Roadmap', '2026-04-02T09:00:00.002Z'),
                (23, '2026-04-03T09:00:00.000Z', '2026-04-03T09:30:00.000Z', 'Zoom', 'Hiring loop', '2026-04-03T09:00:00.003Z');
            INSERT INTO audio_transcriptions (audio_chunk_id, offset_index, timestamp, transcription, device, is_input_device, _archive_mask) VALUES
                (1, 0, '2026-04-01T09:05:00+00:00', '', 'Mic', 1, 0),
                (1, 1, '2026-04-02T09:01:00+00:00', 'We ship the beta in May.', 'Mic', 1, 1);
            INSERT INTO meeting_transcript_segments (meeting_id, provider, item_id, device_name, device_type, transcript, captured_at, _archive_mask) VALUES
                (23, 'deepgram', 'item-1', 'System Audio', 'output', '', '2026-04-03T09:02:00+00:00', 0);
            """)
        try execute(folder.appendingPathComponent("db.sqlite"), schema() + meetings + """
            INSERT INTO meetings (id, meeting_start, meeting_end, meeting_app, title, created_at) VALUES
                (22, '2026-04-02T09:00:00.000Z', '2026-04-02T09:30:00.000Z', 'Zoom', 'Old title', '2026-04-02T09:00:00.002Z');
            INSERT INTO audio_transcriptions (audio_chunk_id, offset_index, timestamp, transcription, device, is_input_device) VALUES
                (1, 0, '2026-04-01T09:05:00+00:00', 'The new icons test well.', 'Mic', 1),
                (1, 1, '2026-04-02T09:01:00+00:00', 'We ship the beta in May.', 'Mic', 1);
            """)
    }

    /// Not a Screenpipe database: SQLite without its tables.
    static func writeOtherApp(to url: URL) throws {
        try execute(url, "CREATE TABLE notes (id INTEGER PRIMARY KEY, body TEXT); INSERT INTO notes (body) VALUES ('hello');")
    }

    /// A SQLite header followed by nothing SQLite can use.
    static func writeBroken(to url: URL) throws {
        try (Data("SQLite format 3\u{0}".utf8) + Data(repeating: 0, count: 200)).write(to: url)
    }

    /// What Screenpipe's vault leaves when it locks a database.
    static func writeLocked(to url: URL) throws {
        try (Data("SPVAULT1".utf8) + Data(repeating: 7, count: 64)).write(to: url)
    }

    static func quoted(_ text: String) -> String { text.replacingOccurrences(of: "'", with: "''") }

    static func execute(_ url: URL, _ sql: String) throws {
        var handle: OpaquePointer?
        guard sqlite3_open(url.path, &handle) == SQLITE_OK, let handle else {
            throw Failure(description: "couldn't create \(url.lastPathComponent)")
        }
        defer { sqlite3_close(handle) }
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(handle))
            sqlite3_free(error)
            throw Failure(description: message)
        }
    }
}
