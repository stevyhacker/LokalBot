import XCTest
import SQLite3
@testable import LokalBot

final class ScreenMemoryReaderTests: XCTestCase {
    private var root: URL!
    private var databaseURL: URL!
    private var database: ScreenReaderFixtureDatabase!
    private var reader: SQLiteScreenMemoryReader!
    private let dayStart = Date(timeIntervalSince1970: 1_784_028_000) // 2026-07-14T06:00Z

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("screen-reader-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        databaseURL = root.appendingPathComponent("lokalbotv3.sqlite")
        database = try ScreenReaderFixtureDatabase(url: databaseURL)
        try database.execute("""
            CREATE TABLE activity_blocks (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                app TEXT NOT NULL, title TEXT NOT NULL,
                start REAL NOT NULL, end REAL NOT NULL);
            CREATE TABLE screenshots (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                ts REAL NOT NULL, path TEXT NOT NULL, app TEXT NOT NULL,
                window_title TEXT NOT NULL DEFAULT '',
                capture_trigger TEXT NOT NULL DEFAULT 'interval');
            CREATE VIRTUAL TABLE ocr_fts USING fts5(
                text, window_title, ts UNINDEXED, app UNINDEXED,
                text_source UNINDEXED, snapshot_id UNINDEXED,
                tokenize='unicode61 remove_diacritics 2');
            CREATE TABLE screen_bookmarks (
                snapshot_id INTEGER PRIMARY KEY,
                note TEXT NOT NULL DEFAULT '',
                created_at REAL NOT NULL);
            """)
        try database.run("""
            INSERT INTO activity_blocks (app, title, start, end)
            VALUES (?1, ?2, ?3, ?4)
            """, bind: ["Safari", "Quarterly report", dayStart.timeIntervalSince1970 + 600,
                          dayStart.timeIntervalSince1970 + 4_200])
        try database.run("""
            INSERT INTO activity_blocks (app, title, start, end)
            VALUES (?1, ?2, ?3, ?4)
            """, bind: ["Xcode", "LokalBot", dayStart.timeIntervalSince1970 + 3_600,
                          dayStart.timeIntervalSince1970 + 7_200])
        try database.run("""
            INSERT INTO screenshots (ts, path, app, window_title, capture_trigger)
            VALUES (?1, ?2, ?3, ?4, ?5)
            """, bind: [dayStart.timeIntervalSince1970 + 1_200,
                          "/private/secret/report.heic.enc", "Safari",
                          "Quarterly report", "window_change"])
        try database.run("""
            INSERT INTO screenshots (ts, path, app, window_title, capture_trigger)
            VALUES (?1, ?2, ?3, ?4, ?5)
            """, bind: [dayStart.timeIntervalSince1970 + 5_000,
                          "/private/secret/code.heic.enc", "Xcode", "LokalBot", "app_switch"])
        try database.run("""
            INSERT INTO ocr_fts (text, window_title, ts, app, text_source, snapshot_id)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6)
            """, bind: ["Q3 revenue grew fourteen percent", "Quarterly report",
                          dayStart.timeIntervalSince1970 + 1_200, "Safari", "ocr", 1])
        try database.run("""
            INSERT INTO screen_bookmarks (snapshot_id, note, created_at)
            VALUES (?1, ?2, ?3)
            """, bind: [1, "Use this chart in the review",
                          dayStart.timeIntervalSince1970 + 1_300])
        reader = SQLiteScreenMemoryReader(databaseURL: databaseURL)
    }

    override func tearDown() {
        reader = nil
        database = nil
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    func testSearchReturnsLinkedSnapshotAndHonorsFilters() throws {
        let hits = try reader.search(ScreenMemorySearchRequest(
            query: "revenue chart",
            start: dayStart,
            end: dayStart.addingTimeInterval(86_400),
            app: "saf",
            limit: 10))

        let hit = try XCTUnwrap(hits.first)
        XCTAssertEqual(hit.snapshotID, 1)
        XCTAssertEqual(hit.app, "Safari")
        XCTAssertEqual(hit.windowTitle, "Quarterly report")
        XCTAssertTrue(hit.snippet.contains("revenue"))

        XCTAssertTrue(try reader.search(ScreenMemorySearchRequest(
            query: "revenue",
            start: dayStart,
            end: dayStart.addingTimeInterval(86_400),
            app: "Xcode",
            limit: 10)).isEmpty)
    }

    func testTimelineRecentActivityAndUsageAreMetadataOnly() throws {
        let end = dayStart.addingTimeInterval(86_400)
        let timeline = try reader.timeline(from: dayStart, to: end, limit: 100)
        XCTAssertEqual(timeline.activity.count, 2)
        XCTAssertEqual(timeline.screenshots.count, 2)
        XCTAssertTrue(timeline.screenshots[0].hasOCR)
        XCTAssertTrue(timeline.screenshots[0].isSaved)
        XCTAssertFalse(timeline.screenshots[1].hasOCR)

        let recent = try reader.recentActivity(
            since: dayStart.addingTimeInterval(3_000), limit: 10)
        XCTAssertEqual(recent.map(\.app), ["Xcode", "Safari"])

        let usage = try reader.appUsage(
            from: dayStart.addingTimeInterval(1_800),
            to: dayStart.addingTimeInterval(5_400),
            limit: 10)
        XCTAssertEqual(usage.map(\.app), ["Safari", "Xcode"])
        XCTAssertEqual(usage[0].durationSeconds, 2_400, accuracy: 0.001)
        XCTAssertEqual(usage[1].durationSeconds, 1_800, accuracy: 0.001)
    }

    func testScreenshotDetailReturnsOCRBookmarkAndNoPath() throws {
        let detail = try XCTUnwrap(reader.screenshotDetail(snapshotID: 1))
        XCTAssertEqual(detail.ocrText, "Q3 revenue grew fourteen percent")
        XCTAssertEqual(detail.textSources, ["ocr"])
        XCTAssertEqual(detail.savedNote, "Use this chart in the review")
        XCTAssertTrue(detail.hasEncryptedPixels)

        let data = try JSONEncoder().encode(detail)
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(json.contains("/private/secret"))
        XCTAssertFalse(json.contains("path"))
    }

    func testOverlappingActivityIsClampedToTheAuthorizedWindow() throws {
        let start = dayStart.addingTimeInterval(1_800)
        let end = dayStart.addingTimeInterval(5_400)
        let timeline = try reader.timeline(from: start, to: end, limit: 100)
        XCTAssertEqual(timeline.activity.map(\.startedAt), [start, dayStart.addingTimeInterval(3_600)])
        XCTAssertEqual(timeline.activity.map(\.endedAt), [dayStart.addingTimeInterval(4_200), end])
        XCTAssertEqual(timeline.activity.map(\.durationSeconds), [2_400, 1_800])
        XCTAssertEqual(try reader.activityBlocks(from: start, to: end), timeline.activity)
        let recent = try reader.recentActivity(since: start, limit: 10)
        XCTAssertEqual(recent.last?.startedAt, start)
        XCTAssertEqual(recent.last?.durationSeconds, 2_400)
    }

    func testSavedMomentsAndDaySummary() throws {
        let end = dayStart.addingTimeInterval(86_400)
        let moments = try reader.savedMoments(from: dayStart, to: end, limit: 50)
        XCTAssertEqual(moments.count, 1)
        XCTAssertEqual(moments[0].snapshotID, 1)
        XCTAssertTrue(moments[0].ocrExcerpt.contains("revenue"))

        let summary = try reader.daySummary(from: dayStart, to: end)
        XCTAssertEqual(summary.trackedSeconds, 7_200, accuracy: 0.001)
        XCTAssertEqual(summary.appCount, 2)
        XCTAssertEqual(summary.activityBlockCount, 2)
        XCTAssertEqual(summary.screenshotCount, 2)
        XCTAssertEqual(summary.savedMomentCount, 1)
    }

    func testDailyEvidenceQueriesShareOneBoundedInterval() throws {
        let end = dayStart.addingTimeInterval(86_400)

        let blocks = try reader.activityBlocks(from: dayStart, to: end)
        let contexts = try reader.screenContexts(
            from: dayStart,
            to: end,
            maxCharactersPerCapture: 12)
        let latest = try reader.latestEvidenceAt(from: dayStart, to: end)

        XCTAssertEqual(blocks.map(\.app), ["Safari", "Xcode"])
        XCTAssertEqual(contexts.count, 1)
        XCTAssertEqual(contexts[0].text, "Q3 revenue g")
        XCTAssertEqual(latest, dayStart.addingTimeInterval(7_200))
    }

    func testMissingDatabaseIsNotCreatedByReadOnlyReader() throws {
        let missing = root.appendingPathComponent("missing.sqlite")
        let missingReader = SQLiteScreenMemoryReader(databaseURL: missing)
        XCTAssertThrowsError(try missingReader.recentActivity(since: .distantPast, limit: 1))
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
    }
}

private final class ScreenReaderFixtureDatabase {
    enum FixtureError: LocalizedError {
        case sqlite(String)

        var errorDescription: String? {
            switch self {
            case .sqlite(let message): message
            }
        }
    }

    private let handle: OpaquePointer

    init(url: URL) throws {
        var opened: OpaquePointer?
        let result = sqlite3_open(url.path, &opened)
        guard result == SQLITE_OK, let opened else {
            let message = opened.map { String(cString: sqlite3_errmsg($0)) }
                ?? String(cString: sqlite3_errstr(result))
            if let opened { sqlite3_close(opened) }
            throw FixtureError.sqlite(message)
        }
        handle = opened
    }

    deinit {
        sqlite3_close(handle)
    }

    func execute(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(handle, sql, nil, nil, &error)
        guard result == SQLITE_OK else {
            let message = error.map { String(cString: $0) }
                ?? String(cString: sqlite3_errmsg(handle))
            if let error { sqlite3_free(error) }
            throw FixtureError.sqlite(message)
        }
    }

    func run(_ sql: String, bind values: [Any]) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw FixtureError.sqlite(String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(statement) }
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch value {
            case let string as String:
                result = sqlite3_bind_text(statement, index, string, -1, Self.transient)
            case let double as Double:
                result = sqlite3_bind_double(statement, index, double)
            case let integer as Int:
                result = sqlite3_bind_int64(statement, index, Int64(integer))
            case let integer as Int64:
                result = sqlite3_bind_int64(statement, index, integer)
            default:
                throw FixtureError.sqlite("Unsupported fixture bind value")
            }
            guard result == SQLITE_OK else {
                throw FixtureError.sqlite(String(cString: sqlite3_errmsg(handle)))
            }
        }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw FixtureError.sqlite(String(cString: sqlite3_errmsg(handle)))
        }
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
}
