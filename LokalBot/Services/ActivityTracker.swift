import Foundation
import AppKit
import SQLite3
import ApplicationServices

/// M4 day tracking, layer 1 (design doc §3.1): sample the frontmost app +
/// window title + idle state, collapse contiguous samples into activity
/// blocks, persist them to the shared SQLite database.

struct ActivityBlock: Identifiable, Equatable, Sendable {
    var id: Int64 = 0
    var app: String
    var title: String
    var start: Date
    var end: Date
    var duration: TimeInterval { end.timeIntervalSince(start) }
}

/// Optional constraints shared by keyword and semantic screen-memory search.
/// The interval is half-open (`start <= timestamp < end`) so adjacent day or
/// selection ranges never return the same capture twice.
struct ScreenSearchFilter: Equatable, Sendable {
    var interval: DateInterval?
    var app: String?
    var snapshotIDs: Set<Int64>?

    static let all = ScreenSearchFilter()

    init(interval: DateInterval? = nil, app: String? = nil) {
        self.interval = interval
        let trimmed = app?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.app = trimmed?.isEmpty == false ? trimmed : nil
    }
}

/// One connection per executor. The app owns its writer on the main actor;
/// background reads construct a separate read-only instance and never share it.
final class ActivityStore {
    private let database: SQLiteDatabase?
    let databaseURL: URL

    init(databaseURL: URL, readOnly: Bool = false) {
        self.databaseURL = databaseURL
        database = SQLiteDatabase(url: databaseURL, readOnly: readOnly)
        guard let database else { return }
        guard !readOnly else { return }
        do {
            try database.execute("""
                CREATE TABLE IF NOT EXISTS activity_blocks (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    app TEXT NOT NULL, title TEXT NOT NULL,
                    start REAL NOT NULL, end REAL NOT NULL);
                CREATE INDEX IF NOT EXISTS idx_activity_start ON activity_blocks(start);
                CREATE TABLE IF NOT EXISTS screenshots (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    ts REAL NOT NULL, path TEXT NOT NULL, app TEXT NOT NULL,
                    window_title TEXT NOT NULL DEFAULT '',
                    capture_trigger TEXT NOT NULL DEFAULT 'interval',
                    perceptual_hash TEXT NOT NULL DEFAULT '',
                    similarity_group INTEGER NOT NULL DEFAULT 0,
                    source_url TEXT NOT NULL DEFAULT '',
                    document_name TEXT NOT NULL DEFAULT '',
                    meeting_id TEXT NOT NULL DEFAULT '',
                    privacy_redactions INTEGER NOT NULL DEFAULT 0);
                CREATE TABLE IF NOT EXISTS screen_bookmarks (
                    snapshot_id INTEGER PRIMARY KEY,
                    note TEXT NOT NULL DEFAULT '',
                    created_at REAL NOT NULL,
                    FOREIGN KEY(snapshot_id) REFERENCES screenshots(id) ON DELETE CASCADE);
                CREATE INDEX IF NOT EXISTS idx_screenshot_ts ON screenshots(ts);
                CREATE INDEX IF NOT EXISTS idx_screenshot_app_ts ON screenshots(app, ts);
                CREATE INDEX IF NOT EXISTS idx_screen_bookmarks_created
                    ON screen_bookmarks(created_at);
                """)
            try migrateScreenshotColumns()
            try migrateOCRTable()
            try OCRMetadataIndex.migrate(database)
        } catch {
            lokalbotLog("activity store initialization failed: \(error.localizedDescription)")
        }
    }

    /// Screenshots taken by builds before event-driven capture lack the
    /// `window_title` / `capture_trigger` columns. ALTER is cheap and keeps
    /// existing rows; fresh databases already have the full shape.
    private func migrateScreenshotColumns() throws {
        let database = try requiredDatabase()
        let columns = try columnNames(of: "screenshots")
        if !columns.contains("window_title") {
            try database.execute(
                "ALTER TABLE screenshots ADD COLUMN window_title TEXT NOT NULL DEFAULT ''")
        }
        if !columns.contains("capture_trigger") {
            try database.execute(
                "ALTER TABLE screenshots ADD COLUMN capture_trigger TEXT NOT NULL DEFAULT 'interval'")
        }
        if !columns.contains("perceptual_hash") {
            try database.execute(
                "ALTER TABLE screenshots ADD COLUMN perceptual_hash TEXT NOT NULL DEFAULT ''")
        }
        if !columns.contains("similarity_group") {
            try database.execute(
                "ALTER TABLE screenshots ADD COLUMN similarity_group INTEGER NOT NULL DEFAULT 0")
        }
        if !columns.contains("source_url") {
            try database.execute(
                "ALTER TABLE screenshots ADD COLUMN source_url TEXT NOT NULL DEFAULT ''")
        }
        if !columns.contains("document_name") {
            try database.execute(
                "ALTER TABLE screenshots ADD COLUMN document_name TEXT NOT NULL DEFAULT ''")
        }
        if !columns.contains("meeting_id") {
            try database.execute(
                "ALTER TABLE screenshots ADD COLUMN meeting_id TEXT NOT NULL DEFAULT ''")
        }
        if !columns.contains("privacy_redactions") {
            try database.execute(
                "ALTER TABLE screenshots ADD COLUMN privacy_redactions INTEGER NOT NULL DEFAULT 0")
        }
    }

    /// FTS5 tables cannot ALTER-add columns, so a legacy `ocr_fts`
    /// (text, ts, app) is rebuilt into the new shape with `window_title`
    /// indexed (searchable) plus `text_source` / `snapshot_id` metadata.
    /// `text_source` distinguishes Accessibility, OCR, and hybrid captures.
    private func migrateOCRTable() throws {
        let database = try requiredDatabase()
        let existing = try columnNames(of: "ocr_fts")
        if existing.isEmpty {
            try database.execute(Self.createOCRTableSQL(named: "ocr_fts"))
            return
        }
        if existing.contains("snapshot_id") {
            try backfillUnlinkedOCRRows(database)
            return
        }
        try database.withTransaction {
            try database.execute(Self.createOCRTableSQL(named: "ocr_fts_v2"))
            try database.execute("""
                WITH ranked_candidates AS (
                    SELECT legacy.rowid AS ocr_rowid,
                           shot.id AS snapshot_id,
                           ROW_NUMBER() OVER (
                               PARTITION BY legacy.rowid
                               ORDER BY ABS(shot.ts - CAST(legacy.ts AS REAL)), shot.id
                           ) AS candidate_rank
                    FROM ocr_fts AS legacy
                    JOIN screenshots AS shot
                      ON shot.app = legacy.app COLLATE NOCASE
                     AND ABS(shot.ts - CAST(legacy.ts AS REAL)) <= 1.0
                )
                INSERT INTO ocr_fts_v2 (text, window_title, ts, app, text_source, snapshot_id)
                    SELECT legacy.text, '', legacy.ts, legacy.app, 'ocr',
                           COALESCE(candidate.snapshot_id, 0)
                    FROM ocr_fts AS legacy
                    LEFT JOIN ranked_candidates AS candidate
                      ON candidate.ocr_rowid = legacy.rowid
                     AND candidate.candidate_rank = 1;
                DROP TABLE ocr_fts;
                ALTER TABLE ocr_fts_v2 RENAME TO ocr_fts;
                """)
        }
    }

    /// An earlier migration version could create the six-column FTS table but
    /// leave `snapshot_id = 0`. Repair those rows idempotently by capture time;
    /// FTS row IDs are not screenshot IDs because empty OCR was never inserted.
    private func backfillUnlinkedOCRRows(_ database: SQLiteDatabase) throws {
        let rows: [(rowID: Int64, timestamp: Double, app: String)] = try database
            .queryChecked("""
                SELECT rowid, CAST(ts AS REAL), app FROM ocr_fts
                WHERE CAST(snapshot_id AS INTEGER) <= 0
                ORDER BY rowid
                """) { statement in
                guard let app = sqlite3_column_text(statement, 2) else { return nil }
                return (
                    sqlite3_column_int64(statement, 0),
                    sqlite3_column_double(statement, 1),
                    String(cString: app))
            }
        guard !rows.isEmpty else { return }
        try database.withTransaction {
            for row in rows {
                let snapshotID: Int64? = try database.queryChecked("""
                    SELECT id FROM screenshots
                    WHERE app = ?1 COLLATE NOCASE AND ABS(ts - ?2) <= 1.0
                    ORDER BY ABS(ts - ?2), id
                    LIMIT 1
                    """, bind: [row.app, row.timestamp]) { statement in
                    sqlite3_column_int64(statement, 0)
                }.first
                guard let snapshotID else { continue }
                try database.runChecked(
                    "UPDATE ocr_fts SET snapshot_id = ?1 WHERE rowid = ?2",
                    bind: [snapshotID, row.rowID])
                if database.hasRow("SELECT 1 FROM sqlite_master WHERE name = 'ocr_metadata'") {
                    try database.runChecked("UPDATE ocr_metadata SET snapshot_id = ?1 WHERE rowid = ?2",
                                            bind: [snapshotID, row.rowID])
                }
            }
        }
    }

    private static func createOCRTableSQL(named name: String) -> String {
        """
        CREATE VIRTUAL TABLE IF NOT EXISTS \(name) USING fts5(
            text, window_title, ts UNINDEXED, app UNINDEXED,
            text_source UNINDEXED, snapshot_id UNINDEXED,
            tokenize='unicode61 remove_diacritics 2');
        """
    }

    private func columnNames(of table: String) throws -> Set<String> {
        let database = try requiredDatabase()
        return Set(try database.queryChecked("PRAGMA table_info(\(table))") { statement in
            String(cString: sqlite3_column_text(statement, 1))
        })
    }

    private func requiredDatabase() throws -> SQLiteDatabase {
        guard let database else {
            throw SQLiteDatabase.DatabaseError.unavailable(path: databaseURL.path)
        }
        return database
    }

    /// A day loader's metadata, text, and watermark share one WAL read snapshot.
    /// This is a deferred read transaction, so capture writers remain unblocked.
    func withReadSnapshot<Value>(_ read: () -> Value) -> Value {
        let began = database?.exec("BEGIN DEFERRED TRANSACTION") == true
        defer { if began { database?.exec("ROLLBACK") } }
        return read()
    }

    nonisolated static func dayInterval(containing day: Date, calendar: Calendar = .current) -> DateInterval {
        calendar.dateInterval(of: .day, for: day)
            ?? DateInterval(start: calendar.startOfDay(for: day), duration: 86_400)
    }

    @discardableResult
    func insert(_ block: ActivityBlock) -> Bool {
        do {
            try requiredDatabase().runChecked(
                "INSERT INTO activity_blocks (app, title, start, end) VALUES (?1, ?2, ?3, ?4)",
                bind: [block.app, block.title, block.start.timeIntervalSince1970,
                       block.end.timeIntervalSince1970])
            return true
        } catch {
            lokalbotLog("activity block persistence failed: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: Screenshots / OCR (M5)

    struct Screenshot: Identifiable, Equatable, Sendable {
        var id: Int64
        var ts: Date
        var path: String
        var app: String
        var windowTitle: String = ""
        var trigger: String = "interval"
        var perceptualHash: UInt64?
        var similarityGroupID: Int64?
        var sourceURL: String = ""
        var documentName: String = ""
        var meetingID: String = ""
        var privacyRedactionCount: Int = 0
        var isBookmarked: Bool = false

        var hasPixels: Bool { !path.isEmpty }
    }

    struct OCRHit: Identifiable, Equatable, Sendable {
        var snapshotID: Int64
        var id: Int64 { snapshotID }
        var ts: Date
        var app: String
        var windowTitle: String = ""
        var snippet: String
        var similarityGroupID: Int64?
        var captureCount: Int
        var isSemantic = false

        init(snapshotID: Int64, ts: Date, app: String, windowTitle: String = "",
             snippet: String, similarityGroupID: Int64? = nil, captureCount: Int = 1) {
            self.snapshotID = snapshotID
            self.ts = ts
            self.app = app
            self.windowTitle = windowTitle
            self.snippet = snippet
            self.similarityGroupID = similarityGroupID
            self.captureCount = max(1, captureCount)
        }
    }

    struct SavedMoment: Identifiable, Equatable, Sendable {
        var snapshotID: Int64
        var id: Int64 { snapshotID }
        var ts: Date
        var path: String
        var app: String
        var windowTitle: String
        var trigger: String
        var note: String
        var createdAt: Date
    }

    /// Insert one paired capture row (pixels bookkeeping + searchable text).
    /// Returns the screenshot rowid so the OCR row links back to its pixels.
    @discardableResult
    func insertScreenshot(ts: Date, path: String, app: String,
                          windowTitle: String = "", trigger: String = "interval",
                          textSource: String = "ocr", ocr: String,
                          perceptualHash: UInt64? = nil,
                          sourceURL: String = "", documentName: String = "",
                          meetingID: String = "", privacyRedactions: Int = 0) throws -> Int64 {
        let database = try requiredDatabase()
        return try database.withTransaction {
            try database.runChecked("""
                INSERT INTO screenshots (
                    ts, path, app, window_title, capture_trigger, perceptual_hash,
                    source_url, document_name, meeting_id, privacy_redactions
                ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)
                """, bind: [ts.timeIntervalSince1970, path, app, windowTitle, trigger,
                              perceptualHash.map(Self.encodePerceptualHash) ?? "",
                              sourceURL, documentName, meetingID, max(0, privacyRedactions)])
            let snapshotID = database.lastInsertRowID()
            guard snapshotID > 0 else {
                throw SQLiteDatabase.DatabaseError.step(
                    sql: nil, code: SQLITE_CORRUPT,
                    message: "screenshot insert did not produce a row id")
            }
            if !ocr.isEmpty {
                try database.runChecked("""
                    INSERT INTO ocr_fts (text, window_title, ts, app, text_source, snapshot_id)
                    VALUES (?1, ?2, ?3, ?4, ?5, ?6)
                    """, bind: [ocr, windowTitle, ts.timeIntervalSince1970, app,
                                 textSource, snapshotID])
                try database.runChecked("""
                    INSERT OR REPLACE INTO ocr_metadata (rowid, snapshot_id, ts)
                    VALUES (?1, ?2, ?3)
                    """, bind: [database.lastInsertRowID(), snapshotID, ts.timeIntervalSince1970])
            }
            if let perceptualHash {
                let previous: (id: Int64, hash: UInt64, groupID: Int64)? = try database
                    .queryChecked("""
                        SELECT id, perceptual_hash, similarity_group
                        FROM screenshots
                        WHERE id != ?1 AND ts <= ?2 AND perceptual_hash != ''
                        ORDER BY ts DESC, id DESC LIMIT 1
                        """, bind: [snapshotID, ts.timeIntervalSince1970]) { statement in
                        guard let rawHash = sqlite3_column_text(statement, 1),
                              let hash = Self.decodePerceptualHash(
                                String(cString: rawHash)) else { return nil }
                        return (
                            sqlite3_column_int64(statement, 0), hash,
                            sqlite3_column_int64(statement, 2))
                    }.first
                let groupID: Int64
                if let previous {
                    let candidateGroupID = previous.groupID > 0
                        ? previous.groupID : previous.id
                    let representativeHash: UInt64
                    if candidateGroupID == previous.id {
                        representativeHash = previous.hash
                    } else {
                        representativeHash = try database.queryChecked(
                            "SELECT perceptual_hash FROM screenshots WHERE id = ?1 LIMIT 1",
                            bind: [candidateGroupID]) { statement in
                            guard let rawHash = sqlite3_column_text(statement, 0) else {
                                return nil
                            }
                            return Self.decodePerceptualHash(String(cString: rawHash))
                        }.first ?? previous.hash
                    }
                    groupID = ScreenPerceptualHash.isNearDuplicate(
                        representativeHash, perceptualHash)
                        ? candidateGroupID : snapshotID
                } else {
                    groupID = snapshotID
                }
                try database.runChecked(
                    "UPDATE screenshots SET similarity_group = ?1 WHERE id = ?2",
                    bind: [groupID, snapshotID])
            }
            return snapshotID
        }
    }

    func screenshots(on day: Date, includingTextOnly: Bool = false) -> [Screenshot] {
        screenshots(in: Self.dayInterval(containing: day),
                    includingMissingFiles: includingTextOnly)
    }

    /// Captures available for rewind/citation, oldest first. A nil interval
    /// means all retained captures. App matching is exact but case-insensitive,
    /// which maps cleanly to the app chips built from stored application names.
    func screenshots(in interval: DateInterval? = nil, app: String? = nil,
                     bookmarkedOnly: Bool = false,
                     includingMissingFiles: Bool = false) -> [Screenshot] {
        do {
            return try screenshotsChecked(in: interval, app: app, bookmarkedOnly: bookmarkedOnly,
                                          includingMissingFiles: includingMissingFiles)
        } catch {
            lokalbotLog("screenshot query failed: \(error.localizedDescription)")
            return []
        }
    }

    /// Destructive previews must distinguish a failed read from an empty scope.
    func screenshotsChecked(in interval: DateInterval? = nil, app: String? = nil,
                            bookmarkedOnly: Bool = false,
                            includingMissingFiles: Bool = false) throws -> [Screenshot] {
        let filter = ScreenSearchFilter(interval: interval, app: app)
        var conditions: [String] = []
        if !includingMissingFiles { conditions.append("shot.path != ''") }
        var bindings: [Any] = []
        Self.appendFilter(filter, timestampColumn: "shot.ts", appColumn: "shot.app",
                          conditions: &conditions, bindings: &bindings)
        if bookmarkedOnly { conditions.append("bookmark.snapshot_id IS NOT NULL") }
        return try requiredDatabase().queryChecked("""
                SELECT shot.id, shot.ts, shot.path, shot.app, shot.window_title,
                       shot.capture_trigger, shot.perceptual_hash,
                       shot.similarity_group, shot.source_url, shot.document_name,
                       shot.meeting_id, shot.privacy_redactions,
                       bookmark.snapshot_id IS NOT NULL
                FROM screenshots AS shot
                LEFT JOIN screen_bookmarks AS bookmark ON bookmark.snapshot_id = shot.id
                \(conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND "))
                ORDER BY shot.ts, shot.id
                """, bind: bindings, row: Self.screenshot(from:))
    }

    /// Exact row lookup used by `[screen:ID]` citations and pinned context.
    func screenshot(id: Int64) -> Screenshot? {
        do { return try screenshotChecked(id: id) } catch {
            lokalbotLog("screenshot lookup failed id=\(id): \(error.localizedDescription)")
            return nil
        }
    }

    func screenshotChecked(id: Int64) throws -> Screenshot? {
        guard id > 0 else { return nil }
        return try requiredDatabase().queryChecked("""
                SELECT shot.id, shot.ts, shot.path, shot.app, shot.window_title,
                       shot.capture_trigger, shot.perceptual_hash,
                       shot.similarity_group, shot.source_url, shot.document_name,
                       shot.meeting_id, shot.privacy_redactions,
                       bookmark.snapshot_id IS NOT NULL
                FROM screenshots AS shot
                LEFT JOIN screen_bookmarks AS bookmark ON bookmark.snapshot_id = shot.id
                WHERE shot.id = ?1 LIMIT 1
                """, bind: [id], row: Self.screenshot(from:)).first
    }

    /// FTS search over screen text (and window titles). `matchAll: false`
    /// relaxes a natural-language query to OR'd content keywords — same
    /// rescue the meeting search uses.
    func searchOCR(_ query: String, limit: Int = 40,
                   matchAll: Bool = true, dropStopWords: Bool = false,
                   filter: ScreenSearchFilter = .all, groupResults: Bool = true) -> [OCRHit] {
        guard limit > 0 else { return [] }
        guard let match = SearchIndex.ftsQuery(from: query, matchAll: matchAll,
                                               dropStopWords: dropStopWords) else { return [] }
        var conditions = [
            "ocr_fts MATCH ?1",
            "CAST(ocr_fts.snapshot_id AS INTEGER) > 0",
        ]
        var bindings: [Any] = [match]
        if let ids = filter.snapshotIDs {
            guard !ids.isEmpty else { return [] }
            let parameters = ids.sorted().map { id -> String in
                bindings.append(id)
                return "?\(bindings.count)"
            }.joined(separator: ",")
            conditions.append("CAST(ocr_fts.snapshot_id AS INTEGER) IN (\(parameters))")
        }
        Self.appendFilter(
            filter,
            timestampColumn: "CAST(ocr_fts.ts AS REAL)",
            appColumn: "ocr_fts.app",
            conditions: &conditions,
            bindings: &bindings)
        do {
            if !groupResults {
                return try requiredDatabase().queryChecked("""
                    SELECT CAST(ocr_fts.snapshot_id AS INTEGER), CAST(ocr_fts.ts AS REAL),
                           ocr_fts.app, ocr_fts.window_title, snippet(ocr_fts, 0, '«', '»', '…', 14),
                           shot.similarity_group
                    FROM ocr_fts JOIN screenshots AS shot ON shot.id = CAST(ocr_fts.snapshot_id AS INTEGER)
                    WHERE \(conditions.joined(separator: " AND "))
                    ORDER BY ocr_fts.rank, CAST(ocr_fts.ts AS REAL) DESC, shot.id
                    LIMIT \(limit)
                    """, bind: bindings) { statement in
                    OCRHit(snapshotID: sqlite3_column_int64(statement, 0),
                           ts: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                           app: String(cString: sqlite3_column_text(statement, 2)),
                           windowTitle: String(cString: sqlite3_column_text(statement, 3)),
                           snippet: String(cString: sqlite3_column_text(statement, 4)),
                           similarityGroupID: sqlite3_column_int64(statement, 5) > 0
                               ? sqlite3_column_int64(statement, 5) : nil)
                }
            }
            return try requiredDatabase().queryChecked("""
                WITH candidates AS (
                    SELECT CAST(ocr_fts.snapshot_id AS INTEGER) AS snapshot_id,
                           CAST(ocr_fts.ts AS REAL) AS captured_at,
                           ocr_fts.app AS app,
                           ocr_fts.window_title AS window_title,
                           snippet(ocr_fts, 0, '«', '»', '…', 14) AS snippet_text,
                           ocr_fts.rank AS match_rank,
                           shot.similarity_group AS similarity_group_id,
                           CASE
                               WHEN shot.similarity_group > 0
                                   THEN 'group:' || CAST(shot.similarity_group AS TEXT)
                               ELSE 'fallback:'
                                   || lower(CAST(ocr_fts.app AS TEXT)) || char(31)
                                   || lower(CAST(ocr_fts.window_title AS TEXT)) || char(31)
                                   || strftime(
                                       '%Y-%m-%d', CAST(ocr_fts.ts AS REAL),
                                       'unixepoch', 'localtime')
                           END AS deduplication_key
                    FROM ocr_fts
                    JOIN screenshots AS shot
                      ON shot.id = CAST(ocr_fts.snapshot_id AS INTEGER)
                    WHERE \(conditions.joined(separator: " AND "))
                ), grouped AS (
                    SELECT *,
                           ROW_NUMBER() OVER (
                               PARTITION BY deduplication_key
                               ORDER BY match_rank, captured_at DESC, snapshot_id
                           ) AS evidence_rank,
                           FIRST_VALUE(snapshot_id) OVER (
                               PARTITION BY deduplication_key
                               ORDER BY captured_at DESC, snapshot_id DESC
                           ) AS latest_snapshot_id,
                           FIRST_VALUE(captured_at) OVER (
                               PARTITION BY deduplication_key
                               ORDER BY captured_at DESC, snapshot_id DESC
                           ) AS latest_captured_at,
                           FIRST_VALUE(app) OVER (
                               PARTITION BY deduplication_key
                               ORDER BY captured_at DESC, snapshot_id DESC
                           ) AS latest_app,
                           FIRST_VALUE(window_title) OVER (
                               PARTITION BY deduplication_key
                               ORDER BY captured_at DESC, snapshot_id DESC
                           ) AS latest_window_title,
                           COUNT(*) OVER (
                               PARTITION BY deduplication_key
                           ) AS capture_count
                    FROM candidates
                )
                SELECT \(groupResults ? "latest_snapshot_id, latest_captured_at, latest_app, latest_window_title" : "snapshot_id, captured_at, app, window_title"),
                       snippet_text, similarity_group_id, \(groupResults ? "capture_count" : "1")
                FROM grouped
                WHERE \(groupResults ? "evidence_rank = 1" : "1 = 1")
                ORDER BY match_rank, latest_captured_at DESC, latest_snapshot_id
                LIMIT \(limit)
                """, bind: bindings) { statement in
                OCRHit(snapshotID: sqlite3_column_int64(statement, 0),
                       ts: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                       app: String(cString: sqlite3_column_text(statement, 2)),
                       windowTitle: String(cString: sqlite3_column_text(statement, 3)),
                       snippet: String(cString: sqlite3_column_text(statement, 4)),
                       similarityGroupID: {
                           let groupID = sqlite3_column_int64(statement, 5)
                           return groupID > 0 ? groupID : nil
                       }(),
                       captureCount: Int(sqlite3_column_int64(statement, 6)))
            }
        } catch {
            lokalbotLog("OCR search failed: \(error.localizedDescription)")
            return []
        }
    }

    /// Full captured OCR for a stable citation/pinned Ask attachment. Unlike
    /// FTS snippets this preserves line breaks and never falls through to a
    /// nearby timestamp, so `[screen:ID]` always resolves exact source text.
    func ocrText(snapshotID: Int64, maxChars: Int = 9_000) -> String? {
        guard snapshotID > 0, maxChars > 0 else { return nil }
        do {
            return try requiredDatabase().queryChecked("""
                SELECT text FROM ocr_fts
                WHERE rowid = (SELECT rowid FROM ocr_metadata WHERE snapshot_id = ?1 ORDER BY rowid LIMIT 1)
                """, bind: [snapshotID]) { statement in
                guard let rawText = sqlite3_column_text(statement, 0) else { return nil }
                return String(String(cString: rawText).prefix(maxChars))
            }.first
        } catch {
            lokalbotLog("snapshot OCR lookup failed id=\(snapshotID): \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: Saved moments

    /// Idempotently saves a capture. Saving it again updates the note without
    /// changing its original `createdAt`, keeping daily exports stable.
    func saveMoment(snapshotID: Int64, note: String = "") throws {
        let database = try requiredDatabase()
        guard snapshotID > 0,
              try database.hasRowChecked(
                "SELECT 1 FROM screenshots WHERE id = ?1", bind: [snapshotID]) else {
            throw SQLiteDatabase.DatabaseError.step(
                sql: nil, code: SQLITE_NOTFOUND,
                message: "screenshot \(snapshotID) does not exist")
        }
        try database.runChecked("""
            INSERT INTO screen_bookmarks (snapshot_id, note, created_at)
            VALUES (?1, ?2, ?3)
            ON CONFLICT(snapshot_id) DO UPDATE SET note = excluded.note
            """, bind: [snapshotID, note, Date().timeIntervalSince1970])
    }

    func removeSavedMoment(snapshotID: Int64) throws {
        try requiredDatabase().runChecked(
            "DELETE FROM screen_bookmarks WHERE snapshot_id = ?1", bind: [snapshotID])
    }

    func isBookmarked(snapshotID: Int64) throws -> Bool {
        try requiredDatabase().hasRowChecked(
            "SELECT 1 FROM screen_bookmarks WHERE snapshot_id = ?1", bind: [snapshotID])
    }

    func savedMoments(limit: Int = 200) -> [SavedMoment] {
        guard limit > 0 else { return [] }
        do {
            return try requiredDatabase().queryChecked("""
                SELECT shot.id, shot.ts, shot.path, shot.app, shot.window_title,
                       shot.capture_trigger, bookmark.note, bookmark.created_at
                FROM screen_bookmarks AS bookmark
                JOIN screenshots AS shot ON shot.id = bookmark.snapshot_id
                ORDER BY bookmark.created_at DESC, shot.id DESC LIMIT \(limit)
                """) { statement in
                SavedMoment(
                    snapshotID: sqlite3_column_int64(statement, 0),
                    ts: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                    path: String(cString: sqlite3_column_text(statement, 2)),
                    app: String(cString: sqlite3_column_text(statement, 3)),
                    windowTitle: String(cString: sqlite3_column_text(statement, 4)),
                    trigger: String(cString: sqlite3_column_text(statement, 5)),
                    note: String(cString: sqlite3_column_text(statement, 6)),
                    createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 7)))
            }
        } catch {
            lokalbotLog("saved-moment query failed: \(error.localizedDescription)")
            return []
        }
    }

    /// Removes one capture and every derived/search row in one transaction.
    /// The owning `ScreenshotService` removes encrypted pixels first so a
    /// failed filesystem delete remains retryable from this database row.
    func deleteScreenshot(id: Int64) throws {
        try deleteScreenshots(ids: [id])
    }

    /// Batch counterpart for Timeline range deletion. FTS metadata columns are
    /// unindexed, so deleting chunks in one transaction avoids rescanning the
    /// entire OCR table once per selected frame and prevents partial DB state.
    func deleteScreenshots(ids: [Int64]) throws {
        let snapshotIDs = Array(Set(ids.filter { $0 > 0 })).sorted()
        guard !snapshotIDs.isEmpty else { return }
        let database = try requiredDatabase()
        try database.withTransaction {
            let hasScreenEmbeddings = try database.hasRowChecked("""
                SELECT 1 FROM sqlite_master
                WHERE type = 'table' AND name = 'screen_embeddings'
                """)
            for start in stride(from: 0, to: snapshotIDs.count, by: 400) {
                let chunk = Array(snapshotIDs[start..<min(start + 400, snapshotIDs.count)])
                let placeholders = (1...chunk.count).map { "?\($0)" }.joined(separator: ", ")
                let bindings: [Any] = chunk
                try database.runChecked("""
                    DELETE FROM ocr_fts
                    WHERE rowid IN (SELECT rowid FROM ocr_metadata WHERE snapshot_id IN (\(placeholders)))
                    """, bind: bindings)
                try database.runChecked("""
                    DELETE FROM screen_bookmarks
                    WHERE snapshot_id IN (\(placeholders))
                    """, bind: bindings)
                if hasScreenEmbeddings {
                    try database.runChecked("""
                        DELETE FROM screen_embeddings
                        WHERE snapshot_id IN (\(placeholders))
                        """, bind: bindings)
                }
                try database.runChecked("""
                    DELETE FROM screenshots WHERE id IN (\(placeholders))
                    """, bind: bindings)
            }
            try OCRMetadataIndex.removeDeletedRows(database)
        }
        NotificationCenter.default.post(name: .retainedScreenTextChanged, object: nil)
    }

    /// Every retained screen-text record for one local day, oldest first.
    /// This has no whole-day character ceiling: callers can chunk the complete
    /// evidence without a busy morning crowding out the afternoon. Individual
    /// captures stay bounded to keep one pathological Accessibility tree from
    /// dominating a chunk.
    func screenContexts(on day: Date, maxCharactersPerCapture: Int = 2_000) -> [DayScreenContext] {
        guard maxCharactersPerCapture > 0 else { return [] }
        let interval = Self.dayInterval(containing: day)
        do {
            return try requiredDatabase().queryChecked("""
                SELECT meta.snapshot_id, meta.ts, app,
                       window_title, text
                FROM ocr_metadata AS meta JOIN ocr_fts ON ocr_fts.rowid = meta.rowid
                WHERE meta.ts >= ?1 AND meta.ts < ?2
                ORDER BY meta.ts, meta.snapshot_id, meta.rowid
                """, bind: [interval.start.timeIntervalSince1970,
                             interval.end.timeIntervalSince1970]) { statement in
                DayScreenContext(
                    snapshotID: sqlite3_column_int64(statement, 0),
                    capturedAt: Date(
                        timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                    app: sqlite3_column_text(statement, 2).map(String.init(cString:)) ?? "",
                    windowTitle: sqlite3_column_text(statement, 3)
                        .map(String.init(cString:)) ?? "",
                    text: String((sqlite3_column_text(statement, 4)
                        .map(String.init(cString:)) ?? "").prefix(maxCharactersPerCapture)))
            }
        } catch {
            lokalbotLog("day screen-context query failed: \(error.localizedDescription)")
            return []
        }
    }

    /// OCR text for a precise interval. Used for meeting-local participant
    /// hints, where the current day's whole screen history would be too broad.
    func ocrText(from start: Date, to end: Date, maxChars: Int = 9_000,
                 includeAppNames: Bool = false) -> String {
        guard maxChars > 0 else { return "" }
        do {
            var out = ""
            try requiredDatabase().forEachRowChecked("""
                SELECT app, text FROM ocr_metadata AS meta JOIN ocr_fts ON ocr_fts.rowid = meta.rowid
                WHERE meta.ts >= ?1 AND meta.ts < ?2 ORDER BY meta.ts, meta.rowid
                """, bind: [start.timeIntervalSince1970, end.timeIntervalSince1970]) { statement in
                let app = String(cString: sqlite3_column_text(statement, 0))
                let text = String(cString: sqlite3_column_text(statement, 1))
                let line = includeAppNames
                    ? "[\(app)] \(text.prefix(600))\n"
                    : "\(text.prefix(600))\n"
                out += line.prefix(maxChars - out.count)
                return out.count < maxChars
            }
            return out
        } catch {
            lokalbotLog("OCR context query failed: \(error.localizedDescription)")
            return ""
        }
    }

    func retentionReview(days: Int, keepTextForever: Bool, now: Date = Date()) throws -> RetentionReview {
        let database = try requiredDatabase()
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        let hasVectors = try database.hasRowChecked("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'screen_embeddings'")
        let vectorQuery = hasVectors
            ? "EXISTS(SELECT 1 FROM screen_embeddings WHERE snapshot_id = shot.id)" : "0"
        let candidates = try database.queryChecked("""
            SELECT shot.id, shot.ts, shot.path,
                   EXISTS(SELECT 1 FROM ocr_metadata WHERE snapshot_id = shot.id),
                   \(vectorQuery)
            FROM screenshots AS shot
            WHERE shot.ts < ?1 AND shot.id NOT IN (SELECT snapshot_id FROM screen_bookmarks)
            ORDER BY shot.ts
            """, bind: [cutoff.timeIntervalSince1970]) { statement in
                RetentionReview.Candidate(
                    id: sqlite3_column_int64(statement, 0),
                    timestamp: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                    path: String(cString: sqlite3_column_text(statement, 2)),
                    removeText: !keepTextForever && sqlite3_column_int(statement, 3) != 0,
                    removeVector: !keepTextForever && sqlite3_column_int(statement, 4) != 0)
            }.filter { !$0.path.isEmpty || $0.removeText || $0.removeVector }
        let savedCounts = try database.queryChecked("""
            SELECT COUNT(*) FROM screen_bookmarks JOIN screenshots ON screenshots.id = snapshot_id
            WHERE screenshots.ts < ?1
            """, bind: [cutoff.timeIntervalSince1970]) { Int(sqlite3_column_int($0, 0)) }
        let bytes = candidates.reduce(Int64(0)) { sum, candidate in
            let attributes = try? FileManager.default.attributesOfItem(atPath: candidate.path)
            return sum + ((attributes?[.size] as? NSNumber)?.int64Value ?? 0)
        }
        return RetentionReview(days: days, keepTextForever: keepTextForever, reviewedAt: now,
                               candidates: candidates, savedCount: savedCounts.first ?? 0, bytes: bytes)
    }

    func clearRetainedText(ids: [Int64]) throws {
        let database = try requiredDatabase()
        let hasVectors = try database.hasRowChecked("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'screen_embeddings'")
        try database.withTransaction {
            for id in ids {
                let condition = "CAST(snapshot_id AS INTEGER) = ?1 AND CAST(snapshot_id AS INTEGER) NOT IN (SELECT snapshot_id FROM screen_bookmarks)"
                try database.runChecked("DELETE FROM ocr_fts WHERE \(condition)", bind: [id])
                if hasVectors {
                    try database.runChecked("DELETE FROM screen_embeddings WHERE \(condition)", bind: [id])
                }
            }
            try OCRMetadataIndex.removeDeletedRows(database)
        }
        NotificationCenter.default.post(name: .retainedScreenTextChanged, object: nil)
    }

    func screenshotPaths(olderThan cutoff: Date) -> [String] {
        do {
            return try requiredDatabase().queryChecked("""
                SELECT shot.path FROM screenshots AS shot
                LEFT JOIN screen_bookmarks AS bookmark
                    ON bookmark.snapshot_id = shot.id
                WHERE shot.ts < ?1 AND shot.path != ''
                  AND bookmark.snapshot_id IS NULL
                """,
                bind: [cutoff.timeIntervalSince1970]) { statement in
                String(cString: sqlite3_column_text(statement, 0))
            }
        } catch {
            lokalbotLog("screenshot retention query failed: \(error.localizedDescription)")
            return []
        }
    }

    /// Clear only the row whose file was successfully removed. This avoids
    /// losing the sole reference to an encrypted file when filesystem cleanup
    /// fails (permissions, transient volume error, and so on).
    func clearScreenshotPath(_ path: String) throws {
        try requiredDatabase().runChecked(
            "UPDATE screenshots SET path = '' WHERE path = ?1", bind: [path])
    }

    @discardableResult
    func clearOCRText(olderThan cutoff: Date) -> Bool {
        do {
            let database = try requiredDatabase()
            try database.withTransaction {
                if try database.hasRowChecked("""
                    SELECT 1 FROM sqlite_master
                    WHERE type = 'table' AND name = 'screen_embeddings'
                    """) {
                    try database.runChecked(
                        """
                        DELETE FROM screen_embeddings
                        WHERE ts < ?1 AND snapshot_id NOT IN (
                            SELECT snapshot_id FROM screen_bookmarks
                        )
                        """,
                        bind: [cutoff.timeIntervalSince1970])
                }
                try database.runChecked("""
                    DELETE FROM ocr_fts
                    WHERE ts < ?1 AND CAST(snapshot_id AS INTEGER) NOT IN (
                        SELECT snapshot_id FROM screen_bookmarks
                    )
                    """, bind: [cutoff.timeIntervalSince1970])
                try OCRMetadataIndex.removeDeletedRows(database)
            }
            NotificationCenter.default.post(name: .retainedScreenTextChanged, object: nil)
            return true
        } catch {
            lokalbotLog("OCR retention cleanup failed: \(error.localizedDescription)")
            return false
        }
    }

    /// All blocks overlapping the given day, oldest first.
    func blocks(on day: Date) -> [ActivityBlock] {
        blocks(in: Self.dayInterval(containing: day))
    }

    func blocks(in interval: DateInterval) -> [ActivityBlock] {
        do {
            return try requiredDatabase().queryChecked("""
                SELECT id, app, title, start, end FROM activity_blocks
                WHERE end > ?1 AND start < ?2 ORDER BY start
                """, bind: [interval.start.timeIntervalSince1970,
                             interval.end.timeIntervalSince1970]) { statement in
                ActivityBlock(
                    id: sqlite3_column_int64(statement, 0),
                    app: String(cString: sqlite3_column_text(statement, 1)),
                    title: String(cString: sqlite3_column_text(statement, 2)),
                    start: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3)),
                    end: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4)))
            }
        } catch {
            lokalbotLog("activity block query failed: \(error.localizedDescription)")
            return []
        }
    }

    func latestActivityEnd() -> Date? {
        do {
            return try requiredDatabase().queryChecked(
                "SELECT MAX(end) FROM activity_blocks"
            ) { statement -> Date? in
                guard sqlite3_column_type(statement, 0) != SQLITE_NULL else { return nil }
                return Date(timeIntervalSince1970: sqlite3_column_double(statement, 0))
            }.first ?? nil
        } catch {
            lokalbotLog("latest activity lookup failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Latest activity or screen-text timestamp inside one local day. Used to
    /// tell whether a saved digest predates evidence that arrived afterwards.
    func latestEvidenceAt(on day: Date) -> Date? {
        let interval = Self.dayInterval(containing: day)
        do {
            let timestamps: [Date?] = try requiredDatabase().queryChecked("""
                SELECT MAX(value) FROM (
                    SELECT MIN(end, ?2) AS value FROM activity_blocks
                    WHERE end > ?1 AND start < ?2
                    UNION ALL
                    SELECT ts AS value FROM ocr_metadata
                    WHERE ts >= ?1 AND ts < ?2
                )
                """, bind: [interval.start.timeIntervalSince1970,
                             interval.end.timeIntervalSince1970]) { statement in
                guard sqlite3_column_type(statement, 0) != SQLITE_NULL else { return nil }
                return Date(timeIntervalSince1970: sqlite3_column_double(statement, 0))
            }
            return timestamps.first ?? nil
        } catch {
            lokalbotLog("day latest-evidence lookup failed: \(error.localizedDescription)")
            return nil
        }
    }

    private nonisolated static func appendFilter(
        _ filter: ScreenSearchFilter,
        timestampColumn: String,
        appColumn: String,
        conditions: inout [String],
        bindings: inout [Any]
    ) {
        if let interval = filter.interval {
            let startParameter = bindings.count + 1
            bindings.append(interval.start.timeIntervalSince1970)
            let endParameter = bindings.count + 1
            bindings.append(interval.end.timeIntervalSince1970)
            conditions.append(
                "\(timestampColumn) >= ?\(startParameter) AND \(timestampColumn) < ?\(endParameter)")
        }
        if let app = filter.app {
            let parameter = bindings.count + 1
            bindings.append(app)
            conditions.append("\(appColumn) = ?\(parameter) COLLATE NOCASE")
        }
    }

    private nonisolated static func screenshot(from statement: OpaquePointer) -> Screenshot? {
        let rawHash = sqlite3_column_text(statement, 6).map { String(cString: $0) } ?? ""
        let rawGroup = sqlite3_column_int64(statement, 7)
        return Screenshot(
            id: sqlite3_column_int64(statement, 0),
            ts: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
            path: String(cString: sqlite3_column_text(statement, 2)),
            app: String(cString: sqlite3_column_text(statement, 3)),
            windowTitle: String(cString: sqlite3_column_text(statement, 4)),
            trigger: String(cString: sqlite3_column_text(statement, 5)),
            perceptualHash: decodePerceptualHash(rawHash),
            similarityGroupID: rawGroup > 0 ? rawGroup : nil,
            sourceURL: sqlite3_column_text(statement, 8).map { String(cString: $0) } ?? "",
            documentName: sqlite3_column_text(statement, 9).map { String(cString: $0) } ?? "",
            meetingID: sqlite3_column_text(statement, 10).map { String(cString: $0) } ?? "",
            privacyRedactionCount: Int(sqlite3_column_int64(statement, 11)),
            isBookmarked: sqlite3_column_int(statement, 12) != 0)
    }

    private nonisolated static func encodePerceptualHash(_ hash: UInt64) -> String {
        String(format: "%016llx", hash)
    }

    private nonisolated static func decodePerceptualHash(_ value: String) -> UInt64? {
        UInt64(value, radix: 16)
    }
}

struct FocusedWindowTitleLookupResult: Equatable, Sendable {
    let title: String?
    let timedOut: Bool

    static let timeout = Self(title: nil, timedOut: true)
}

/// Keeps cross-process Accessibility title reads off the main actor and bounds
/// both queue growth and caller latency. One resolver may be active at a time;
/// same-PID callers share it, while a different PID fails closed instead of
/// accumulating behind a wedged target process.
final class FocusedWindowTitleLookup: @unchecked Sendable {
    typealias Resolver = @Sendable (pid_t) -> String?

    static let shared = FocusedWindowTitleLookup()
    static let defaultDeadlineMilliseconds = 120
    static let perElementMessagingTimeout: Float = 0.04

    private struct Waiter {
        let id: UInt64
        let continuation: CheckedContinuation<FocusedWindowTitleLookupResult, Never>
    }

    private struct Work {
        let id: UInt64
        let processID: pid_t
        var waiters: [UInt64: Waiter]
    }

    private let stateQueue = DispatchQueue(label: "me.dotenv.LokalBot.ax-window-title-state")
    private let workerQueue = DispatchQueue(
        label: "me.dotenv.LokalBot.ax-window-title-worker",
        qos: .utility)
    private let deadlineMilliseconds: Int
    private let resolver: Resolver
    private var nextIdentifier: UInt64 = 0
    private var active: Work?

    init(
        deadlineMilliseconds: Int = defaultDeadlineMilliseconds,
        resolver: @escaping Resolver = { processID in
            FocusedWindowTitleLookup.resolveTitle(processID: processID)
        }
    ) {
        self.deadlineMilliseconds = max(1, deadlineMilliseconds)
        self.resolver = resolver
    }

    func title(for processID: pid_t) async -> FocusedWindowTitleLookupResult {
        guard processID > 0 else { return .init(title: nil, timedOut: false) }
        return await withCheckedContinuation { continuation in
            stateQueue.async { [self] in
                nextIdentifier &+= 1
                let waiter = Waiter(id: nextIdentifier, continuation: continuation)
                enqueue(waiter: waiter, processID: processID)
            }
        }
    }

    private func enqueue(waiter: Waiter, processID: pid_t) {
        if var active {
            guard active.processID == processID else {
                waiter.continuation.resume(returning: .timeout)
                return
            }
            active.waiters[waiter.id] = waiter
            self.active = active
            scheduleExpiration(for: waiter.id)
            return
        }

        nextIdentifier &+= 1
        let work = Work(
            id: nextIdentifier,
            processID: processID,
            waiters: [waiter.id: waiter])
        active = work
        scheduleExpiration(for: waiter.id)
        workerQueue.async { [weak self] in
            guard let self else { return }
            let title = resolver(processID)
            stateQueue.async { [weak self] in
                self?.finish(workID: work.id, title: title)
            }
        }
    }

    private func scheduleExpiration(for waiterID: UInt64) {
        stateQueue.asyncAfter(deadline: .now() + .milliseconds(deadlineMilliseconds)) { [weak self] in
            self?.expire(waiterID: waiterID)
        }
    }

    private func expire(waiterID: UInt64) {
        guard var active, let waiter = active.waiters.removeValue(forKey: waiterID) else { return }
        self.active = active
        waiter.continuation.resume(returning: .timeout)
    }

    private func finish(workID: UInt64, title: String?) {
        guard let completed = active, completed.id == workID else { return }
        active = nil
        let result = FocusedWindowTitleLookupResult(title: title, timedOut: false)
        for waiter in completed.waiters.values {
            waiter.continuation.resume(returning: result)
        }
    }

    static func resolveTitle(processID: pid_t) -> String? {
        guard AXIsProcessTrusted(), processID > 0 else { return nil }
        let appElement = AXUIElementCreateApplication(processID)
        AXUIElementSetMessagingTimeout(appElement, perElementMessagingTimeout)
        var rawWindow: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedWindowAttribute as CFString,
            &rawWindow) == .success,
              let rawWindow,
              CFGetTypeID(rawWindow) == AXUIElementGetTypeID() else { return nil }
        let window = rawWindow as! AXUIElement
        AXUIElementSetMessagingTimeout(window, perElementMessagingTimeout)
        var rawTitle: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            window,
            kAXTitleAttribute as CFString,
            &rawTitle) == .success else { return nil }
        return rawTitle as? String
    }
}

/// The sampler: 5 s poll (cheap), block boundaries on app/title change,
/// idle > 3 min, pause, or app quit. No screenshots here — that's M5.
@MainActor
final class ActivitySampler: ObservableObject {

    @Published var isPaused = false {
        didSet { if isPaused { closeCurrentBlock() } }
    }
    @Published private(set) var currentApp: String?
    @Published private(set) var lastSampleAt: Date?

    private let store: ActivityStore
    private let windowTitleLookup: FocusedWindowTitleLookup
    /// Injected by AppState; apps matching these are logged as "Private".
    var excludedApps: () -> [String] = { [] }
    /// Event-driven capture hook: fired when the sampled (app, title) pair
    /// changes — i.e. at the same boundaries that close activity blocks.
    /// `appChanged` distinguishes an app switch from a window/tab change
    /// inside the same app. Excluded apps arrive as ("Private", "").
    var onActivityBoundary: ((_ app: String, _ title: String, _ appChanged: Bool) -> Void)?
    private var timer: Timer?
    private let notificationCenter: NotificationCenter
    private var terminationObserver: NSObjectProtocol?
    private var current: (app: String, title: String, start: Date)?
    private var lastSeen = Date()
    private static let idleLimit: TimeInterval = 180
    private static let minBlock: TimeInterval = 5

    init(
        store: ActivityStore,
        notificationCenter: NotificationCenter = .default,
        windowTitleLookup: FocusedWindowTitleLookup = .shared
    ) {
        self.store = store
        self.notificationCenter = notificationCenter
        self.windowTitleLookup = windowTitleLookup
    }

    var hasTerminationObserver: Bool { terminationObserver != nil }

    func start() {
        guard timer == nil else { return }
        lokalbotLog("sampler start — AX trusted: \(Self.hasAccessibility ? "yes" : "no")")
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.sample() }
        }
        terminationObserver = notificationCenter.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            Task { @MainActor [weak self] in self?.closeCurrentBlock() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let terminationObserver {
            notificationCenter.removeObserver(terminationObserver)
            self.terminationObserver = nil
        }
        closeCurrentBlock()
    }

    deinit {
        if let terminationObserver {
            notificationCenter.removeObserver(terminationObserver)
        }
    }

    /// Window titles need Accessibility; we degrade to app-name-only.
    nonisolated static var hasAccessibility: Bool { AXIsProcessTrusted() }

    private func sample() async {
        guard !isPaused else { return }

        // Idle: any input event type, session-wide.
        let idle = CGEventSource.secondsSinceLastEventType(
            .combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        if idle > Self.idleLimit {
            closeCurrentBlock(at: lastSeen)
            return
        }
        lastSeen = Date()

        guard let frontmost = NSWorkspace.shared.frontmostApplication,
              var appName = frontmost.localizedName else { return }
        let processID = frontmost.processIdentifier
        let isExcluded = ScreenshotCaptureLayout.isExcluded(
            appName: appName, excludedApps: excludedApps())
        let titleResult = isExcluded
            ? FocusedWindowTitleLookupResult(title: nil, timedOut: false)
            : await windowTitleLookup.title(for: processID)
        guard !titleResult.timedOut,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == processID else { return }
        lastSampleAt = Date()
        currentApp = appName
        var title = titleResult.title ?? ""
        // Exclusion list (design §3.4): time still counts, content doesn't.
        if isExcluded {
            appName = "Private"
            title = ""
        } else {
            // Window titles are part of screen-memory metadata and external
            // timeline reads. Scrub recognizable credentials before the block
            // ever reaches SQLite, even when richer context capture is off.
            title = ScreenContextPrivacy.redact(title).text
        }

        if let current {
            if current.app == appName && current.title == title { return }
            let appChanged = current.app != appName
            closeCurrentBlock()
            onActivityBoundary?(appName, title, appChanged)
        }
        current = (appName, title, Date())
    }

    private func closeCurrentBlock(at end: Date = Date()) {
        guard let block = current else { return }
        current = nil
        guard end.timeIntervalSince(block.start) >= Self.minBlock else { return }
        store.insert(ActivityBlock(app: block.app, title: block.title,
                                   start: block.start, end: end))
    }

    nonisolated static func focusedWindowTitle(pid: pid_t) -> String? {
        FocusedWindowTitleLookup.resolveTitle(processID: pid)
    }
}
