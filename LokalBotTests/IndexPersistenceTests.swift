import XCTest
import SQLite3
@testable import LokalBot

@MainActor
final class IndexPersistenceTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("index-persistence-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        root = nil
    }

    func testTransactionRollsBackFailedPreparedBatchAndCommitsSuccessfulBatch() throws {
        let database = try XCTUnwrap(SQLiteDatabase(url: root.appendingPathComponent("batch.sqlite")))
        XCTAssertTrue(database.exec("CREATE TABLE values_table (value INTEGER UNIQUE NOT NULL)"))

        let failed = database.transaction {
            database.withStatement("INSERT INTO values_table (value) VALUES (?1)") { statement in
                database.run(statement, bind: [1])
                    && database.run(statement, bind: [1])
            } ?? false
        }

        XCTAssertFalse(failed)
        XCTAssertEqual(database.firstDouble("SELECT COUNT(*) FROM values_table"), 0)

        let committed = database.transaction {
            database.withStatement("INSERT INTO values_table (value) VALUES (?1)") { statement in
                (2...4).allSatisfy { database.run(statement, bind: [$0]) }
            } ?? false
        }

        XCTAssertTrue(committed)
        XCTAssertEqual(database.firstDouble("SELECT COUNT(*) FROM values_table"), 3)
    }

    func testCheckedQueriesDistinguishEmptyResultsFromSQLiteFailures() throws {
        let database = try XCTUnwrap(SQLiteDatabase(
            url: root.appendingPathComponent("checked-errors.sqlite")))
        try database.execute("CREATE TABLE values_table (value INTEGER NOT NULL)")

        let empty: [Int64] = try database.queryChecked(
            "SELECT value FROM values_table") { sqlite3_column_int64($0, 0) }
        XCTAssertEqual(empty, [])

        let failingQuery: () throws -> [Int64] = {
            try database.queryChecked("SELECT value FROM table_that_does_not_exist") {
                sqlite3_column_int64($0, 0)
            }
        }
        XCTAssertThrowsError(try failingQuery())
        XCTAssertNotNil(database.lastError)
    }

    func testDatabaseConnectionsEnableWALAndBusyTimeout() throws {
        let database = try XCTUnwrap(SQLiteDatabase(
            url: root.appendingPathComponent("connection-policy.sqlite")))
        let journalModes: [String] = try database.queryChecked("PRAGMA journal_mode") {
            String(cString: sqlite3_column_text($0, 0))
        }
        let timeout = try database.firstDoubleChecked("PRAGMA busy_timeout")

        XCTAssertEqual(journalModes, ["wal"])
        XCTAssertEqual(timeout, 5_000)
    }

    func testSearchIndexBackfillsLegacyRowMappingAndRemovesOnlyTargetMeeting() throws {
        let url = root.appendingPathComponent("search-migration.sqlite")
        let database = try XCTUnwrap(SQLiteDatabase(url: url))
        XCTAssertTrue(database.exec("""
            CREATE TABLE indexed_meetings (
                meeting_id TEXT PRIMARY KEY,
                source_mtime REAL NOT NULL
            );
            CREATE VIRTUAL TABLE docs USING fts5(
                text,
                meeting_id UNINDEXED,
                kind UNINDEXED,
                start UNINDEXED,
                speaker UNINDEXED
            );
            """))

        let removedID = UUID()
        let retainedID = UUID()
        for id in [removedID, retainedID] {
            XCTAssertTrue(database.run(
                "INSERT INTO indexed_meetings (meeting_id, source_mtime) VALUES (?1, ?2)",
                bind: [id.uuidString, 100.0]))
        }
        XCTAssertTrue(database.run(
            "INSERT INTO docs (text, meeting_id, kind, start, speaker) VALUES (?1, ?2, ?3, ?4, ?5)",
            bind: ["legacyalpha", removedID.uuidString, "segment", 12.0, "Me"]))
        XCTAssertTrue(database.run(
            "INSERT INTO docs (text, meeting_id, kind, start, speaker) VALUES (?1, ?2, ?3, ?4, ?5)",
            bind: ["legacybeta", retainedID.uuidString, "segment", 24.0, "Them"]))

        let index = SearchIndex(databaseURL: url)

        XCTAssertEqual(database.firstDouble("SELECT COUNT(*) FROM search_document_rows"), 2)
        XCTAssertTrue(database.hasRow("""
            SELECT 1 FROM sqlite_master
            WHERE type = 'index' AND name = 'idx_search_document_rows_meeting_id'
            """))
        XCTAssertTrue(database.hasRow(
            "SELECT 1 FROM search_index_migrations WHERE name = ?1",
            bind: ["search-document-rows-v1"]))
        XCTAssertEqual(index.search("legacyalpha").map(\.meetingID), [removedID])
        XCTAssertEqual(index.search("legacybeta").map(\.meetingID), [retainedID])

        index.remove(removedID)

        XCTAssertEqual(database.firstDouble(
            "SELECT COUNT(*) FROM docs WHERE meeting_id = ?1",
            bind: [removedID.uuidString]), 0)
        XCTAssertEqual(database.firstDouble(
            "SELECT COUNT(*) FROM docs WHERE meeting_id = ?1",
            bind: [retainedID.uuidString]), 1)
        XCTAssertEqual(database.firstDouble(
            "SELECT COUNT(*) FROM search_document_rows WHERE meeting_id = ?1",
            bind: [removedID.uuidString]), 0)
        XCTAssertEqual(database.firstDouble(
            "SELECT COUNT(*) FROM search_document_rows WHERE meeting_id = ?1",
            bind: [retainedID.uuidString]), 1)
        XCTAssertFalse(database.hasRow(
            "SELECT 1 FROM indexed_meetings WHERE meeting_id = ?1",
            bind: [removedID.uuidString]))
        XCTAssertTrue(database.hasRow(
            "SELECT 1 FROM indexed_meetings WHERE meeting_id = ?1",
            bind: [retainedID.uuidString]))
        XCTAssertTrue(index.search("legacyalpha").isEmpty)
        XCTAssertEqual(index.search("legacybeta").map(\.meetingID), [retainedID])
    }

    func testSearchReindexRollsBackDocumentsAndMtimeWhenMappingInsertFails() throws {
        let storage = StorageManager(rootURL: root.appendingPathComponent("library", isDirectory: true))
        let meeting = Meeting(
            id: UUID(),
            title: "Atomic indexing",
            appName: "Tests",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            endedAt: Date(timeIntervalSince1970: 1_700_000_100),
            relativePath: "meetings/atomic",
            hasSystemTrack: false)
        let folder = meeting.folderURL(in: storage)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let transcriptURL = folder.appendingPathComponent("transcript.json")
        try writeTranscript(text: "oldneedle remains searchable", to: transcriptURL,
                            modificationDate: Date(timeIntervalSince1970: 1_700_000_200))

        let databaseURL = storage.rootURL.appendingPathComponent("lokalbotv3.sqlite")
        let index = SearchIndex(databaseURL: databaseURL)
        index.reindex(meeting, storage: storage)
        let database = try XCTUnwrap(SQLiteDatabase(url: databaseURL))
        let originalMtime = try XCTUnwrap(database.firstDouble(
            "SELECT source_mtime FROM indexed_meetings WHERE meeting_id = ?1",
            bind: [meeting.id.uuidString]))
        XCTAssertEqual(index.search("oldneedle").map(\.meetingID), [meeting.id])

        XCTAssertTrue(database.exec("""
            CREATE TRIGGER fail_search_mapping
            BEFORE INSERT ON search_document_rows
            BEGIN
                SELECT RAISE(ABORT, 'forced mapping failure');
            END;
            """))
        try writeTranscript(text: "newneedle must not replace the old row", to: transcriptURL,
                            modificationDate: Date(timeIntervalSince1970: 1_700_000_300))

        index.reindex(meeting, storage: storage)

        XCTAssertEqual(index.search("oldneedle").map(\.meetingID), [meeting.id])
        XCTAssertTrue(index.search("newneedle").isEmpty)
        XCTAssertEqual(database.firstDouble(
            "SELECT source_mtime FROM indexed_meetings WHERE meeting_id = ?1",
            bind: [meeting.id.uuidString]), originalMtime)
        XCTAssertEqual(database.firstDouble(
            "SELECT COUNT(*) FROM search_document_rows WHERE meeting_id = ?1",
            bind: [meeting.id.uuidString]), 2)
    }

    func testDeletedMeetingTombstonePreventsLateSearchReindex() throws {
        let storage = StorageManager(
            rootURL: root.appendingPathComponent("deleted-library", isDirectory: true))
        let meeting = Meeting(
            id: UUID(),
            title: "Deleted meeting",
            appName: "Tests",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            endedAt: Date(timeIntervalSince1970: 1_700_000_100),
            relativePath: "meetings/deleted",
            hasSystemTrack: false)
        let folder = meeting.folderURL(in: storage)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let transcriptURL = folder.appendingPathComponent("transcript.json")
        try writeTranscript(text: "originalneedle", to: transcriptURL,
                            modificationDate: Date(timeIntervalSince1970: 1_700_000_200))

        let databaseURL = storage.rootURL.appendingPathComponent("lokalbotv3.sqlite")
        let index = SearchIndex(databaseURL: databaseURL)
        index.reindex(meeting, storage: storage)
        XCTAssertEqual(index.search("originalneedle").map(\.meetingID), [meeting.id])

        XCTAssertTrue(index.remove(meeting.id))
        try writeTranscript(text: "latenotification", to: transcriptURL,
                            modificationDate: Date(timeIntervalSince1970: 1_700_000_300))
        index.reindex(meeting, storage: storage)

        let database = try XCTUnwrap(SQLiteDatabase(url: databaseURL))
        XCTAssertTrue(database.hasRow(
            "SELECT 1 FROM deleted_meetings WHERE meeting_id = ?1",
            bind: [meeting.id.uuidString]))
        XCTAssertTrue(index.search("originalneedle").isEmpty)
        XCTAssertTrue(index.search("latenotification").isEmpty)
        XCTAssertFalse(database.hasRow(
            "SELECT 1 FROM indexed_meetings WHERE meeting_id = ?1",
            bind: [meeting.id.uuidString]))
    }

    func testOlderSearchSnapshotCannotOverwriteNewerIndependentCommit() throws {
        let storage = StorageManager(
            rootURL: root.appendingPathComponent("freshness-library", isDirectory: true))
        let meeting = Meeting(
            id: UUID(),
            title: "Freshness race",
            appName: "Tests",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            endedAt: Date(timeIntervalSince1970: 1_700_000_100),
            relativePath: "meetings/freshness",
            hasSystemTrack: false)
        let folder = meeting.folderURL(in: storage)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let transcriptURL = folder.appendingPathComponent("transcript.json")
        try writeTranscript(text: "stalesnapshotneedle", to: transcriptURL,
                            modificationDate: Date(timeIntervalSince1970: 1_700_000_200))

        let databaseURL = storage.rootURL.appendingPathComponent("lokalbotv3.sqlite")
        let olderWorker = SearchIndex(databaseURL: databaseURL)
        var injectionError: Error?
        olderWorker.reindex(meeting, storage: storage) {
            do {
                try self.writeTranscript(
                    text: "freshsnapshotneedle", to: transcriptURL,
                    modificationDate: Date(timeIntervalSince1970: 1_700_000_300))
                SearchIndex(databaseURL: databaseURL).reindex(meeting, storage: storage)
            } catch {
                injectionError = error
            }
        }

        XCTAssertNil(injectionError)
        XCTAssertTrue(olderWorker.search("stalesnapshotneedle").isEmpty)
        XCTAssertEqual(olderWorker.search("freshsnapshotneedle").map(\.meetingID), [meeting.id])
        let database = try XCTUnwrap(SQLiteDatabase(url: databaseURL))
        XCTAssertEqual(database.firstDouble(
            "SELECT source_mtime FROM indexed_meetings WHERE meeting_id = ?1",
            bind: [meeting.id.uuidString]), 1_700_000_300)
    }

    func testFailedCleanupKeepsTombstoneVisibleAndStartupReconcilesStaleRows() throws {
        let storage = StorageManager(
            rootURL: root.appendingPathComponent("cleanup-library", isDirectory: true))
        let removed = Meeting(
            id: UUID(), title: "Removed", appName: "Tests",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            endedAt: Date(timeIntervalSince1970: 1_700_000_100),
            relativePath: "meetings/removed", hasSystemTrack: false)
        let retained = Meeting(
            id: UUID(), title: "Retained", appName: "Tests",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            endedAt: Date(timeIntervalSince1970: 1_700_000_100),
            relativePath: "meetings/retained", hasSystemTrack: false)
        for (meeting, text) in [(removed, "ghostneedle removed"),
                                (retained, "ghostneedle retained")] {
            let folder = meeting.folderURL(in: storage)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try writeTranscript(
                text: text, to: folder.appendingPathComponent("transcript.json"),
                modificationDate: Date(timeIntervalSince1970: 1_700_000_200))
        }

        let databaseURL = storage.rootURL.appendingPathComponent("lokalbotv3.sqlite")
        let index = SearchIndex(databaseURL: databaseURL)
        index.reindex(removed, storage: storage)
        index.reindex(retained, storage: storage)
        let database = try XCTUnwrap(SQLiteDatabase(url: databaseURL))
        XCTAssertTrue(database.exec("""
            CREATE TRIGGER fail_removed_search_cleanup
            BEFORE DELETE ON search_document_rows
            WHEN OLD.meeting_id = '\(removed.id.uuidString)'
            BEGIN
                SELECT RAISE(ABORT, 'forced cleanup failure');
            END;
            """))

        XCTAssertFalse(index.remove(removed.id))
        XCTAssertTrue(database.hasRow(
            "SELECT 1 FROM deleted_meetings WHERE meeting_id = ?1",
            bind: [removed.id.uuidString]))
        XCTAssertGreaterThan(database.firstDouble(
            "SELECT COUNT(*) FROM docs WHERE meeting_id = ?1",
            bind: [removed.id.uuidString]) ?? 0, 0)
        XCTAssertEqual(index.search("ghostneedle").map(\.meetingID), [retained.id])

        let embedding = EmbeddingIndex(databaseURL: databaseURL, storage: storage)
        XCTAssertTrue(database.run(
            "INSERT INTO embeddings (meeting_id, start, text, vec) VALUES (?1, ?2, ?3, ?4)",
            bind: [removed.id.uuidString, 12.0, "stale semantic row",
                   Data(repeating: 1, count: MemoryLayout<Float>.stride)]))
        XCTAssertTrue(database.run("""
            INSERT INTO embedded_meetings (meeting_id, source_mtime, model_id)
            VALUES (?1, ?2, ?3)
            """, bind: [removed.id.uuidString, 1_700_000_200.0,
                         "qwen3-embedding-0.6b-q8"]))
        XCTAssertFalse(embedding.hasEmbeddings)
        let staleHit = EmbeddingIndex.Hit(
            meetingID: removed.id, start: 12, text: "stale semantic row", score: 0.9)
        XCTAssertTrue(embedding.liveHits(from: [staleHit]).isEmpty)

        XCTAssertTrue(database.exec("DROP TRIGGER fail_removed_search_cleanup"))
        _ = SearchIndex(databaseURL: databaseURL)
        _ = EmbeddingIndex(databaseURL: databaseURL, storage: storage)

        XCTAssertEqual(database.firstDouble(
            "SELECT COUNT(*) FROM docs WHERE meeting_id = ?1",
            bind: [removed.id.uuidString]), 0)
        XCTAssertEqual(database.firstDouble(
            "SELECT COUNT(*) FROM search_document_rows WHERE meeting_id = ?1",
            bind: [removed.id.uuidString]), 0)
        XCTAssertEqual(database.firstDouble(
            "SELECT COUNT(*) FROM embeddings WHERE meeting_id = ?1",
            bind: [removed.id.uuidString]), 0)
        XCTAssertEqual(index.search("ghostneedle").map(\.meetingID), [retained.id])
    }

    func testSearchWorkQueueCoalescesPendingMeetingAndStopRejectsNewWork() async throws {
        let storage = StorageManager(
            rootURL: root.appendingPathComponent("queue-library", isDirectory: true))
        var older = Meeting(
            id: UUID(), title: "oldcoalescedtitle", appName: "Tests",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            endedAt: Date(timeIntervalSince1970: 1_700_000_100),
            relativePath: "meetings/coalesced", hasSystemTrack: false)
        let folder = older.folderURL(in: storage)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try writeTranscript(
            text: "queue transcript", to: folder.appendingPathComponent("transcript.json"),
            modificationDate: Date(timeIntervalSince1970: 1_700_000_200))
        var newer = older
        newer.title = "newcoalescedtitle"

        let databaseURL = storage.rootURL.appendingPathComponent("lokalbotv3.sqlite")
        let queue = SearchIndexWorkQueue(databaseURL: databaseURL, rootURL: storage.rootURL)
        await queue.enqueue([older, newer])
        await queue.waitUntilIdle()

        let index = SearchIndex(databaseURL: databaseURL)
        XCTAssertTrue(index.search("oldcoalescedtitle").isEmpty)
        XCTAssertEqual(index.search("newcoalescedtitle").map(\.meetingID), [newer.id])

        older = Meeting(
            id: UUID(), title: "stoppedqueuetitle", appName: "Tests",
            startedAt: Date(timeIntervalSince1970: 1_700_000_300),
            endedAt: Date(timeIntervalSince1970: 1_700_000_400),
            relativePath: "meetings/stopped", hasSystemTrack: false)
        let stoppedFolder = older.folderURL(in: storage)
        try FileManager.default.createDirectory(
            at: stoppedFolder, withIntermediateDirectories: true)
        try writeTranscript(
            text: "must not be indexed",
            to: stoppedFolder.appendingPathComponent("transcript.json"),
            modificationDate: Date(timeIntervalSince1970: 1_700_000_500))

        await queue.stop()
        await queue.enqueue(older)
        await queue.waitUntilIdle()
        XCTAssertTrue(index.search("stoppedqueuetitle").isEmpty)
    }

    func testEmbeddingIndexAddsMeetingIDIndexWithoutDiscardingCurrentRows() throws {
        let url = root.appendingPathComponent("embedding-migration.sqlite")
        let database = try XCTUnwrap(SQLiteDatabase(url: url))
        XCTAssertTrue(database.exec("""
            CREATE TABLE embeddings (
                meeting_id TEXT NOT NULL,
                start REAL NOT NULL,
                text TEXT NOT NULL,
                vec BLOB NOT NULL
            );
            CREATE TABLE embedded_meetings (
                meeting_id TEXT PRIMARY KEY,
                source_mtime REAL NOT NULL,
                model_id TEXT NOT NULL DEFAULT ''
            );
            """))
        let meetingID = UUID().uuidString
        XCTAssertTrue(database.run(
            "INSERT INTO embeddings (meeting_id, start, text, vec) VALUES (?1, ?2, ?3, ?4)",
            bind: [meetingID, 0.0, "preserved", Data(repeating: 1, count: 8)]))
        XCTAssertTrue(database.run(
            "INSERT INTO embedded_meetings (meeting_id, source_mtime, model_id) VALUES (?1, ?2, ?3)",
            bind: [meetingID, 100.0, EmbeddingIndex.indexVersion]))

        _ = EmbeddingIndex(databaseURL: url, storage: StorageManager(rootURL: root))

        XCTAssertTrue(database.hasRow("""
            SELECT 1 FROM sqlite_master
            WHERE type = 'index' AND name = 'idx_embeddings_meeting_id'
            """))
        XCTAssertEqual(database.firstDouble(
            "SELECT COUNT(*) FROM embeddings WHERE meeting_id = ?1",
            bind: [meetingID]), 1)
    }

    func testEmbeddingIndexInvalidatesPreviousPoolingVersion() throws {
        let url = root.appendingPathComponent("embedding-pooling-migration.sqlite")
        let database = try XCTUnwrap(SQLiteDatabase(url: url))
        XCTAssertTrue(database.exec("""
            CREATE TABLE embeddings (
                meeting_id TEXT NOT NULL,
                start REAL NOT NULL,
                text TEXT NOT NULL,
                vec BLOB NOT NULL
            );
            CREATE TABLE embedded_meetings (
                meeting_id TEXT PRIMARY KEY,
                source_mtime REAL NOT NULL,
                model_id TEXT NOT NULL DEFAULT ''
            );
            """))
        let meetingID = UUID().uuidString
        XCTAssertTrue(database.run(
            "INSERT INTO embeddings (meeting_id, start, text, vec) VALUES (?1, ?2, ?3, ?4)",
            bind: [meetingID, 0.0, "mean-pooled", Data(repeating: 1, count: 8)]))
        XCTAssertTrue(database.run(
            "INSERT INTO embedded_meetings (meeting_id, source_mtime, model_id) VALUES (?1, ?2, ?3)",
            bind: [meetingID, 100.0, "qwen3-embedding-0.6b-q8"]))

        // The current Qwen vectors also have 1,024 dimensions. A model change
        // must invalidate them even though their shape matches Harrier's.
        let lastPooledID = UUID().uuidString
        XCTAssertTrue(database.run(
            "INSERT INTO embeddings (meeting_id, start, text, vec) VALUES (?1, ?2, ?3, ?4)",
            bind: [lastPooledID, 0.0, "last-pooled Qwen", Data(repeating: 1, count: 4_096)]))
        XCTAssertTrue(database.run(
            "INSERT INTO embedded_meetings (meeting_id, source_mtime, model_id) VALUES (?1, ?2, ?3)",
            bind: [lastPooledID, 100.0, "qwen3-embedding-0.6b-q8-last-chunks-v2"]))

        let index = EmbeddingIndex(databaseURL: url, storage: StorageManager(rootURL: root))

        XCTAssertNotEqual(EmbeddingIndex.indexVersion, "qwen3-embedding-0.6b-q8")
        XCTAssertFalse(index.hasEmbeddings)
        XCTAssertEqual(database.firstDouble("SELECT COUNT(*) FROM embeddings"), 0)
        XCTAssertEqual(database.firstDouble("SELECT COUNT(*) FROM embedded_meetings"), 0)
    }

    func testEmbeddingModelMigrationPreservesCurrentScreenVectorsAndSourceRows() throws {
        let url = root.appendingPathComponent("screen-model-migration.sqlite")
        let database = try XCTUnwrap(SQLiteDatabase(url: url))
        XCTAssertTrue(database.exec("""
            CREATE TABLE screenshots (id INTEGER PRIMARY KEY);
            INSERT INTO screenshots (id) VALUES (1), (2);
            """))
        _ = EmbeddingIndex(databaseURL: url, storage: StorageManager(rootURL: root))
        for (id, version) in [(1, "qwen3-embedding-0.6b-q8-last-chunks-v2"), (2, EmbeddingIndex.indexVersion)] {
            XCTAssertTrue(database.run("""
                INSERT INTO screen_embeddings (snapshot_id, ts, app, text, vec, model_id)
                VALUES (?1, ?2, ?3, ?4, ?5, ?6)
                """, bind: [id, 100.0, "Tests", "retained source", Data(repeating: 1, count: 4_096), version]))
        }

        _ = EmbeddingIndex(databaseURL: url, storage: StorageManager(rootURL: root))

        XCTAssertEqual(database.firstDouble("SELECT COUNT(*) FROM screenshots"), 2)
        XCTAssertEqual(database.firstDouble("SELECT COUNT(*) FROM screen_embeddings"), 1)
        XCTAssertTrue(database.hasRow("SELECT 1 FROM screen_embeddings WHERE snapshot_id = 2"))
    }

    func testSearchIndexesUserNotesAndCorrectedOutcomes() throws {
        let storage = StorageManager(rootURL: root.appendingPathComponent("notes-library", isDirectory: true))
        let meeting = Meeting(
            id: UUID(), title: "Synthetic planning", appName: "Tests",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            endedAt: Date(timeIntervalSince1970: 1_700_000_100),
            relativePath: "meetings/notes", hasSystemTrack: false)
        let folder = meeting.folderURL(in: storage)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try writeTranscript(text: "ordinary transcript words",
                            to: folder.appendingPathComponent("transcript.json"),
                            modificationDate: Date(timeIntervalSince1970: 1_700_000_200))
        try MeetingNotes.writeChecked("Remember the zephyrcanary rollout", to: folder)
        let action = MeetingOutcomes.ActionItem(text: "Prepare the synthetic memo", owner: "Me", due: "Friday")
        try MeetingOutcomes(actionItems: [action], decisions: ["Adopt the quokkaplan"]).write(to: folder)
        var state = MeetingOutcomeState()
        state.actions[action.id] = .init(textCorrection: "Prepare the velvetbudget memo", userEdited: true)
        try MeetingOutcomeStore.writeState(state, to: folder)

        let index = SearchIndex(databaseURL: storage.rootURL.appendingPathComponent("lokalbotv3.sqlite"))
        index.reindex(meeting, storage: storage)

        XCTAssertEqual(index.search("zephyrcanary").map(\.kind), [.notes])
        XCTAssertEqual(index.search("quokkaplan").map(\.kind), [.outcome])
        XCTAssertEqual(index.search("velvetbudget").map(\.kind), [.outcome])
        XCTAssertEqual(index.search("velvetbudget", kind: .notes).count, 0)
    }

    func testNotesOutcomesMigrationReindexesMeetingsIndexedBeforeIt() throws {
        let storage = StorageManager(rootURL: root.appendingPathComponent("migration-library", isDirectory: true))
        let meeting = Meeting(
            id: UUID(), title: "Earlier meeting", appName: "Tests",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            endedAt: Date(timeIntervalSince1970: 1_700_000_100),
            relativePath: "meetings/earlier", hasSystemTrack: false)
        let folder = meeting.folderURL(in: storage)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try MeetingNotes.writeChecked("legacy harborlight notes", to: folder)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_700_000_050)],
            ofItemAtPath: folder.appendingPathComponent(MeetingNotes.fileName).path)
        let databaseURL = storage.rootURL.appendingPathComponent("lokalbotv3.sqlite")
        let database = try XCTUnwrap(SQLiteDatabase(url: databaseURL))
        _ = SearchIndex(databaseURL: databaseURL)
        // Simulate a library indexed by a build that ignored notes, with a
        // freshness mark newer than the notes file.
        XCTAssertTrue(database.run("DELETE FROM search_index_migrations WHERE name = 'search-notes-outcomes-v1'"))
        XCTAssertTrue(database.run(
            "INSERT OR REPLACE INTO indexed_meetings (meeting_id, source_mtime) VALUES (?1, ?2)",
            bind: [meeting.id.uuidString, 1_800_000_000.0]))

        let index = SearchIndex(databaseURL: databaseURL)
        index.reindex(meeting, storage: storage)

        XCTAssertEqual(index.search("harborlight").map(\.meetingID), [meeting.id])
    }

    private func writeTranscript(text: String, to url: URL,
                                 modificationDate: Date) throws {
        let transcript = Transcript(
            segments: [.init(start: 12, end: 18, speaker: "me",
                             text: text, confidence: nil)],
            engine: "test")
        try JSONEncoder().encode(transcript).write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: modificationDate],
            ofItemAtPath: url.path)
    }
}
