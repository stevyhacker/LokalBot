import Foundation
import SQLite3

enum ScreenMemoryReaderError: LocalizedError {
    case databaseUnavailable(path: String, message: String)
    case queryFailed(message: String)

    var errorDescription: String? {
        switch self {
        case .databaseUnavailable(let path, let message):
            "Screen-memory database is unavailable at \(path): \(message)"
        case .queryFailed(let message):
            "Screen-memory query failed: \(message)"
        }
    }
}

struct ScreenMemorySearchRequest: Equatable {
    var query: String
    var start: Date?
    var end: Date?
    var app: String?
    var limit: Int
}

struct ScreenMemorySearchHit: Codable, Equatable {
    var snapshotID: Int64
    var capturedAt: Date
    var app: String
    var windowTitle: String
    var textSource: String
    var snippet: String

    enum CodingKeys: String, CodingKey {
        case snapshotID = "snapshot_id"
        case capturedAt = "captured_at"
        case app
        case windowTitle = "window_title"
        case textSource = "text_source"
        case snippet
    }
}

struct ScreenMemoryActivityBlock: Codable, Equatable, Sendable {
    var id: Int64
    var app: String
    var windowTitle: String
    var startedAt: Date
    var endedAt: Date
    var durationSeconds: TimeInterval

    enum CodingKeys: String, CodingKey {
        case id
        case app
        case windowTitle = "window_title"
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case durationSeconds = "duration_seconds"
    }
}

/// Full retained text for one capture. This lives in CLISupport so the shared
/// read-only database layer does not depend on app-only digest model types.
struct ScreenMemoryTextContext: Equatable, Sendable {
    var snapshotID: Int64
    var capturedAt: Date
    var app: String
    var windowTitle: String
    var text: String
}

struct ScreenMemoryScreenshotSummary: Codable, Equatable {
    var snapshotID: Int64
    var capturedAt: Date
    var app: String
    var windowTitle: String
    var captureTrigger: String
    var hasOCR: Bool
    var isSaved: Bool
    var hasEncryptedPixels: Bool = false
    var sourceURL: String = ""
    var documentName: String = ""
    var meetingID: String = ""
    var privacyRedactionCount: Int = 0

    enum CodingKeys: String, CodingKey {
        case snapshotID = "snapshot_id"
        case capturedAt = "captured_at"
        case app
        case windowTitle = "window_title"
        case captureTrigger = "capture_trigger"
        case hasOCR = "has_ocr"
        case isSaved = "is_saved"
        case hasEncryptedPixels = "has_encrypted_pixels"
        case sourceURL = "source_url"
        case documentName = "document_name"
        case meetingID = "meeting_id"
        case privacyRedactionCount = "privacy_redaction_count"
    }
}

struct ScreenMemoryTimeline: Codable, Equatable {
    var start: Date
    var end: Date
    var activity: [ScreenMemoryActivityBlock]
    var screenshots: [ScreenMemoryScreenshotSummary]
}

struct ScreenMemoryAppUsage: Codable, Equatable, Sendable {
    var app: String
    var durationSeconds: TimeInterval
    var blockCount: Int

    enum CodingKeys: String, CodingKey {
        case app
        case durationSeconds = "duration_seconds"
        case blockCount = "block_count"
    }
}

struct ScreenMemoryScreenshotDetail: Codable, Equatable {
    var snapshotID: Int64
    var capturedAt: Date
    var app: String
    var windowTitle: String
    var captureTrigger: String
    var hasEncryptedPixels: Bool
    var textSources: [String]
    var ocrText: String
    var isSaved: Bool
    var savedNote: String?
    var savedAt: Date?
    var sourceURL: String = ""
    var documentName: String = ""
    var meetingID: String = ""
    var privacyRedactionCount: Int = 0

    enum CodingKeys: String, CodingKey {
        case snapshotID = "snapshot_id"
        case capturedAt = "captured_at"
        case app
        case windowTitle = "window_title"
        case captureTrigger = "capture_trigger"
        case hasEncryptedPixels = "has_encrypted_pixels"
        case textSources = "text_sources"
        case ocrText = "ocr_text"
        case isSaved = "is_saved"
        case savedNote = "saved_note"
        case savedAt = "saved_at"
        case sourceURL = "source_url"
        case documentName = "document_name"
        case meetingID = "meeting_id"
        case privacyRedactionCount = "privacy_redaction_count"
    }
}

struct ScreenMemorySavedMoment: Codable, Equatable, Sendable {
    var snapshotID: Int64
    var capturedAt: Date
    var app: String
    var windowTitle: String
    var captureTrigger: String
    var note: String
    var savedAt: Date
    var ocrExcerpt: String

    enum CodingKeys: String, CodingKey {
        case snapshotID = "snapshot_id"
        case capturedAt = "captured_at"
        case app
        case windowTitle = "window_title"
        case captureTrigger = "capture_trigger"
        case note
        case savedAt = "saved_at"
        case ocrExcerpt = "ocr_excerpt"
    }
}

struct ScreenMemoryDaySummary: Codable, Equatable, Sendable {
    var trackedSeconds: TimeInterval
    var appCount: Int
    var activityBlockCount: Int
    var screenshotCount: Int
    var savedMomentCount: Int

    enum CodingKeys: String, CodingKey {
        case trackedSeconds = "tracked_seconds"
        case appCount = "app_count"
        case activityBlockCount = "activity_block_count"
        case screenshotCount = "screenshot_count"
        case savedMomentCount = "saved_moment_count"
    }
}

/// Read-only query seam shared by MCP and the canonical daily evidence loader.
protocol ScreenMemoryReading {
    func search(_ request: ScreenMemorySearchRequest) throws -> [ScreenMemorySearchHit]
    func timeline(from start: Date, to end: Date, limit: Int) throws -> ScreenMemoryTimeline
    func recentActivity(since: Date, limit: Int) throws -> [ScreenMemoryActivityBlock]
    func appUsage(from start: Date, to end: Date, limit: Int) throws -> [ScreenMemoryAppUsage]
    func screenshotDetail(snapshotID: Int64) throws -> ScreenMemoryScreenshotDetail?
    func savedMoments(from start: Date, to end: Date, limit: Int) throws
        -> [ScreenMemorySavedMoment]
    func daySummary(from start: Date, to end: Date) throws -> ScreenMemoryDaySummary
    func activityBlocks(from start: Date, to end: Date) throws
        -> [ScreenMemoryActivityBlock]
    func screenContexts(from start: Date, to end: Date, maxCharactersPerCapture: Int) throws
        -> [ScreenMemoryTextContext]
    func latestEvidenceAt(from start: Date, to end: Date) throws -> Date?
}

/// Opens LokalBot's SQLite store in `SQLITE_OPEN_READONLY` mode for every
/// request. It never creates or migrates schema and never exposes screenshot
/// file paths or decrypted pixels.
struct SQLiteScreenMemoryReader: ScreenMemoryReading {
    var databaseURL: URL

    init(databaseURL: URL = SessionLookup.storageRootURL
        .appendingPathComponent("lokalbotv3.sqlite")) {
        self.databaseURL = databaseURL
    }

    func search(_ request: ScreenMemorySearchRequest) throws -> [ScreenMemorySearchHit] {
        let terms = request.query
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        guard !terms.isEmpty else { return [] }
        let match = terms
            .map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"" }
            .joined(separator: " OR ")

        return try withConnection { connection in
            var sql = """
                SELECT CAST(snapshot_id AS INTEGER), CAST(ts AS REAL), app,
                       window_title, text_source,
                       snippet(ocr_fts, 0, '«', '»', '…', 14)
                FROM ocr_fts WHERE ocr_fts MATCH ?1
                  AND CAST(snapshot_id AS INTEGER) > 0
                """
            var bindings: [SQLiteReadValue] = [.text(match)]
            if let start = request.start {
                bindings.append(.double(start.timeIntervalSince1970))
                sql += " AND CAST(ts AS REAL) >= ?\(bindings.count)"
            }
            if let end = request.end {
                bindings.append(.double(end.timeIntervalSince1970))
                sql += " AND CAST(ts AS REAL) < ?\(bindings.count)"
            }
            if let app = request.app, !app.isEmpty {
                bindings.append(.text(app))
                sql += " AND instr(lower(app), lower(?\(bindings.count))) > 0"
            }
            bindings.append(.int64(Int64(request.limit)))
            sql += " ORDER BY bm25(ocr_fts), CAST(ts AS REAL) DESC LIMIT ?\(bindings.count)"

            return try connection.query(sql, bindings: bindings) { row in
                ScreenMemorySearchHit(
                    snapshotID: sqlite3_column_int64(row, 0),
                    capturedAt: Date(timeIntervalSince1970: sqlite3_column_double(row, 1)),
                    app: Self.text(row, 2),
                    windowTitle: Self.text(row, 3),
                    textSource: Self.text(row, 4),
                    snippet: Self.text(row, 5))
            }
        }
    }

    func timeline(from start: Date, to end: Date, limit: Int) throws
        -> ScreenMemoryTimeline {
        try withConnection { connection in
            let intervalBindings: [SQLiteReadValue] = [
                .double(start.timeIntervalSince1970),
                .double(end.timeIntervalSince1970),
                .int64(Int64(limit)),
            ]
            let activity = try connection.query("""
                SELECT id, app, title, MAX(start, ?1), MIN(end, ?2) FROM activity_blocks
                WHERE end > ?1 AND start < ?2 ORDER BY start LIMIT ?3
                """, bindings: intervalBindings) { row in
                let blockStart = Date(timeIntervalSince1970: sqlite3_column_double(row, 3))
                let blockEnd = Date(timeIntervalSince1970: sqlite3_column_double(row, 4))
                return ScreenMemoryActivityBlock(
                    id: sqlite3_column_int64(row, 0),
                    app: Self.text(row, 1),
                    windowTitle: Self.text(row, 2),
                    startedAt: blockStart,
                    endedAt: blockEnd,
                    durationSeconds: max(0, blockEnd.timeIntervalSince(blockStart)))
            }

            let hasBookmarks = try connection.tableExists("screen_bookmarks")
            let hasContextMetadata = try [
                "source_url", "document_name", "meeting_id", "privacy_redactions",
            ].allSatisfy { try connection.columnExists($0, in: "screenshots") }
            let savedExpression = hasBookmarks
                ? "EXISTS(SELECT 1 FROM screen_bookmarks b WHERE b.snapshot_id = s.id)"
                : "0"
            let metadataColumns = hasContextMetadata
                ? "s.source_url, s.document_name, s.meeting_id, s.privacy_redactions"
                : "'', '', '', 0"
            let screenshots = try connection.query("""
                SELECT s.id, s.ts, s.app, s.window_title, s.capture_trigger,
                       EXISTS(SELECT 1 FROM ocr_fts o
                              WHERE CAST(o.snapshot_id AS INTEGER) = s.id),
                       \(savedExpression), s.path != '', \(metadataColumns)
                FROM screenshots s WHERE s.ts >= ?1 AND s.ts < ?2
                ORDER BY s.ts LIMIT ?3
                """, bindings: intervalBindings) { row in
                ScreenMemoryScreenshotSummary(
                    snapshotID: sqlite3_column_int64(row, 0),
                    capturedAt: Date(timeIntervalSince1970: sqlite3_column_double(row, 1)),
                    app: Self.text(row, 2),
                    windowTitle: Self.text(row, 3),
                    captureTrigger: Self.text(row, 4),
                    hasOCR: sqlite3_column_int(row, 5) != 0,
                    isSaved: sqlite3_column_int(row, 6) != 0,
                    hasEncryptedPixels: sqlite3_column_int(row, 7) != 0,
                    sourceURL: Self.text(row, 8),
                    documentName: Self.text(row, 9),
                    meetingID: Self.text(row, 10),
                    privacyRedactionCount: Int(sqlite3_column_int64(row, 11)))
            }
            return ScreenMemoryTimeline(
                start: start, end: end, activity: activity, screenshots: screenshots)
        }
    }

    func recentActivity(since: Date, limit: Int) throws -> [ScreenMemoryActivityBlock] {
        try withConnection { connection in
            try connection.query("""
                SELECT id, app, title, MAX(start, ?1), end FROM activity_blocks
                WHERE end > ?1 ORDER BY end DESC LIMIT ?2
                """, bindings: [
                    .double(since.timeIntervalSince1970),
                    .int64(Int64(limit)),
                ]) { row in
                let start = Date(timeIntervalSince1970: sqlite3_column_double(row, 3))
                let end = Date(timeIntervalSince1970: sqlite3_column_double(row, 4))
                return ScreenMemoryActivityBlock(
                    id: sqlite3_column_int64(row, 0),
                    app: Self.text(row, 1),
                    windowTitle: Self.text(row, 2),
                    startedAt: start,
                    endedAt: end,
                    durationSeconds: max(0, end.timeIntervalSince(start)))
            }
        }
    }

    func appUsage(from start: Date, to end: Date, limit: Int) throws
        -> [ScreenMemoryAppUsage] {
        try withConnection { connection in
            guard try connection.tableExists("activity_blocks") else { return [] }
            return try connection.query("""
                SELECT app,
                       SUM(MIN(end, ?2) - MAX(start, ?1)) AS duration,
                       COUNT(*)
                FROM activity_blocks
                WHERE end > ?1 AND start < ?2
                GROUP BY app HAVING duration > 0
                ORDER BY duration DESC, app LIMIT ?3
                """, bindings: [
                    .double(start.timeIntervalSince1970),
                    .double(end.timeIntervalSince1970),
                    .int64(Int64(limit)),
                ]) { row in
                ScreenMemoryAppUsage(
                    app: Self.text(row, 0),
                    durationSeconds: sqlite3_column_double(row, 1),
                    blockCount: Int(sqlite3_column_int64(row, 2)))
            }
        }
    }

    func activityBlocks(from start: Date, to end: Date) throws
        -> [ScreenMemoryActivityBlock] {
        try withConnection { connection in
            guard try connection.tableExists("activity_blocks") else { return [] }
            return try connection.query("""
                SELECT id, app, title, MAX(start, ?1), MIN(end, ?2) FROM activity_blocks
                WHERE end > ?1 AND start < ?2 ORDER BY start, id
                """, bindings: [
                    .double(start.timeIntervalSince1970),
                    .double(end.timeIntervalSince1970),
                ]) { row in
                let blockStart = Date(
                    timeIntervalSince1970: sqlite3_column_double(row, 3))
                let blockEnd = Date(
                    timeIntervalSince1970: sqlite3_column_double(row, 4))
                return ScreenMemoryActivityBlock(
                    id: sqlite3_column_int64(row, 0),
                    app: Self.text(row, 1),
                    windowTitle: Self.text(row, 2),
                    startedAt: blockStart,
                    endedAt: blockEnd,
                    durationSeconds: max(0, blockEnd.timeIntervalSince(blockStart)))
            }
        }
    }

    func screenContexts(
        from start: Date,
        to end: Date,
        maxCharactersPerCapture: Int
    ) throws -> [ScreenMemoryTextContext] {
        guard maxCharactersPerCapture > 0 else { return [] }
        return try withConnection { connection in
            guard try connection.tableExists("ocr_fts") else { return [] }
            return try connection.query("""
                SELECT CAST(snapshot_id AS INTEGER), CAST(ts AS REAL), app,
                       window_title, text
                FROM ocr_fts
                WHERE CAST(ts AS REAL) >= ?1 AND CAST(ts AS REAL) < ?2
                ORDER BY CAST(ts AS REAL), CAST(snapshot_id AS INTEGER), rowid
                """, bindings: [
                    .double(start.timeIntervalSince1970),
                    .double(end.timeIntervalSince1970),
                ]) { row in
                ScreenMemoryTextContext(
                    snapshotID: sqlite3_column_int64(row, 0),
                    capturedAt: Date(
                        timeIntervalSince1970: sqlite3_column_double(row, 1)),
                    app: Self.text(row, 2),
                    windowTitle: Self.text(row, 3),
                    text: String(Self.text(row, 4).prefix(maxCharactersPerCapture)))
            }
        }
    }

    func latestEvidenceAt(from start: Date, to end: Date) throws -> Date? {
        try withConnection { connection in
            let intervalBindings: [SQLiteReadValue] = [
                .double(start.timeIntervalSince1970),
                .double(end.timeIntervalSince1970),
            ]
            var timestamps: [TimeInterval] = []
            if try connection.tableExists("activity_blocks") {
                let value = try connection.query("""
                    SELECT COALESCE(MAX(MIN(end, ?2)), 0)
                    FROM activity_blocks WHERE end > ?1 AND start < ?2
                    """, bindings: intervalBindings) {
                    sqlite3_column_double($0, 0)
                }.first ?? 0
                if value > 0 { timestamps.append(value) }
            }
            if try connection.tableExists("ocr_fts") {
                let value = try connection.query("""
                    SELECT COALESCE(MAX(CAST(ts AS REAL)), 0)
                    FROM ocr_fts WHERE CAST(ts AS REAL) >= ?1
                      AND CAST(ts AS REAL) < ?2
                    """, bindings: intervalBindings) {
                    sqlite3_column_double($0, 0)
                }.first ?? 0
                if value > 0 { timestamps.append(value) }
            }
            if try connection.tableExists("screenshots") {
                let value = try connection.query("""
                    SELECT COALESCE(MAX(ts), 0)
                    FROM screenshots WHERE ts >= ?1 AND ts < ?2
                    """, bindings: intervalBindings) {
                    sqlite3_column_double($0, 0)
                }.first ?? 0
                if value > 0 { timestamps.append(value) }
            }
            if try connection.tableExists("screen_bookmarks"),
               try connection.tableExists("screenshots") {
                let value = try connection.query("""
                    SELECT COALESCE(MAX(b.created_at), 0)
                    FROM screen_bookmarks b
                    JOIN screenshots s ON s.id = b.snapshot_id
                    WHERE s.ts >= ?1 AND s.ts < ?2
                    """, bindings: intervalBindings) {
                    sqlite3_column_double($0, 0)
                }.first ?? 0
                if value > 0 { timestamps.append(value) }
            }
            guard let latest = timestamps.max() else { return nil }
            return Date(timeIntervalSince1970: latest)
        }
    }

    func screenshotDetail(snapshotID: Int64) throws -> ScreenMemoryScreenshotDetail? {
        try withConnection { connection in
            let hasBookmarks = try connection.tableExists("screen_bookmarks")
            let hasContextMetadata = try [
                "source_url", "document_name", "meeting_id", "privacy_redactions",
            ].allSatisfy { try connection.columnExists($0, in: "screenshots") }
            let savedColumns = hasBookmarks
                ? "EXISTS(SELECT 1 FROM screen_bookmarks b WHERE b.snapshot_id = s.id), "
                    + "COALESCE((SELECT b.note FROM screen_bookmarks b WHERE b.snapshot_id = s.id), ''), "
                    + "(SELECT b.created_at FROM screen_bookmarks b WHERE b.snapshot_id = s.id)"
                : "0, '', NULL"
            let metadataColumns = hasContextMetadata
                ? "s.source_url, s.document_name, s.meeting_id, s.privacy_redactions"
                : "'', '', '', 0"
            return try connection.query("""
                SELECT s.id, s.ts, s.app, s.window_title, s.capture_trigger,
                       s.path != '',
                       COALESCE((SELECT GROUP_CONCAT(o.text_source, ',') FROM ocr_fts o
                                 WHERE CAST(o.snapshot_id AS INTEGER) = s.id), ''),
                       COALESCE((SELECT GROUP_CONCAT(o.text, char(10) || char(10))
                                 FROM ocr_fts o
                                 WHERE CAST(o.snapshot_id AS INTEGER) = s.id), ''),
                       \(savedColumns), \(metadataColumns)
                FROM screenshots s WHERE s.id = ?1 LIMIT 1
                """, bindings: [.int64(snapshotID)]) { row in
                let sources = Self.text(row, 6).split(separator: ",")
                    .map(String.init)
                    .reduce(into: [String]()) { result, source in
                        if !result.contains(source) { result.append(source) }
                    }
                let saved = sqlite3_column_int(row, 8) != 0
                let savedTimestamp = sqlite3_column_type(row, 10) == SQLITE_NULL
                    ? nil
                    : Date(timeIntervalSince1970: sqlite3_column_double(row, 10))
                return ScreenMemoryScreenshotDetail(
                    snapshotID: sqlite3_column_int64(row, 0),
                    capturedAt: Date(timeIntervalSince1970: sqlite3_column_double(row, 1)),
                    app: Self.text(row, 2),
                    windowTitle: Self.text(row, 3),
                    captureTrigger: Self.text(row, 4),
                    hasEncryptedPixels: sqlite3_column_int(row, 5) != 0,
                    textSources: sources,
                    ocrText: Self.text(row, 7),
                    isSaved: saved,
                    savedNote: saved ? Self.text(row, 9) : nil,
                    savedAt: savedTimestamp,
                    sourceURL: Self.text(row, 11),
                    documentName: Self.text(row, 12),
                    meetingID: Self.text(row, 13),
                    privacyRedactionCount: Int(sqlite3_column_int64(row, 14)))
            }.first
        }
    }

    func savedMoments(from start: Date, to end: Date, limit: Int) throws
        -> [ScreenMemorySavedMoment] {
        try withConnection { connection in
            guard try connection.tableExists("screen_bookmarks") else { return [] }
            return try connection.query("""
                SELECT b.snapshot_id, s.ts, s.app, s.window_title, s.capture_trigger,
                       b.note, b.created_at,
                       COALESCE((SELECT o.text FROM ocr_fts o
                                 WHERE CAST(o.snapshot_id AS INTEGER) = s.id
                                 ORDER BY o.rowid LIMIT 1), '')
                FROM screen_bookmarks b
                JOIN screenshots s ON s.id = b.snapshot_id
                WHERE s.ts >= ?1 AND s.ts < ?2
                ORDER BY s.ts LIMIT ?3
                """, bindings: [
                    .double(start.timeIntervalSince1970),
                    .double(end.timeIntervalSince1970),
                    .int64(Int64(limit)),
                ]) { row in
                ScreenMemorySavedMoment(
                    snapshotID: sqlite3_column_int64(row, 0),
                    capturedAt: Date(timeIntervalSince1970: sqlite3_column_double(row, 1)),
                    app: Self.text(row, 2),
                    windowTitle: Self.text(row, 3),
                    captureTrigger: Self.text(row, 4),
                    note: Self.text(row, 5),
                    savedAt: Date(timeIntervalSince1970: sqlite3_column_double(row, 6)),
                    ocrExcerpt: String(Self.text(row, 7).prefix(280)))
            }
        }
    }

    func daySummary(from start: Date, to end: Date) throws -> ScreenMemoryDaySummary {
        try withConnection { connection in
            // Tables are created lazily by their writers, so a fresh install's
            // database can legitimately have none of them yet.
            let activity: (Double, Int, Int)
            if try connection.tableExists("activity_blocks") {
                activity = try connection.query("""
                    SELECT COALESCE(SUM(MIN(end, ?2) - MAX(start, ?1)), 0),
                           COUNT(DISTINCT app), COUNT(*)
                    FROM activity_blocks WHERE end > ?1 AND start < ?2
                    """, bindings: [
                        .double(start.timeIntervalSince1970),
                        .double(end.timeIntervalSince1970),
                    ]) { row in
                    (
                        sqlite3_column_double(row, 0),
                        Int(sqlite3_column_int64(row, 1)),
                        Int(sqlite3_column_int64(row, 2))
                    )
                }.first ?? (0, 0, 0)
            } else {
                activity = (0, 0, 0)
            }
            let screenshotCount: Int
            if try connection.tableExists("screenshots") {
                screenshotCount = try connection.scalarInt("""
                    SELECT COUNT(*) FROM screenshots WHERE ts >= ?1 AND ts < ?2
                    """, bindings: [
                        .double(start.timeIntervalSince1970),
                        .double(end.timeIntervalSince1970),
                    ])
            } else {
                screenshotCount = 0
            }
            let savedCount: Int
            if try connection.tableExists("screen_bookmarks") {
                savedCount = try connection.scalarInt("""
                    SELECT COUNT(*) FROM screen_bookmarks b
                    JOIN screenshots s ON s.id = b.snapshot_id
                    WHERE s.ts >= ?1 AND s.ts < ?2
                    """, bindings: [
                        .double(start.timeIntervalSince1970),
                        .double(end.timeIntervalSince1970),
                    ])
            } else {
                savedCount = 0
            }
            return ScreenMemoryDaySummary(
                trackedSeconds: activity.0,
                appCount: activity.1,
                activityBlockCount: activity.2,
                screenshotCount: screenshotCount,
                savedMomentCount: savedCount)
        }
    }

    private func withConnection<T>(_ body: (ReadOnlySQLiteConnection) throws -> T) throws -> T {
        let connection = try ReadOnlySQLiteConnection(url: databaseURL)
        return try body(connection)
    }

    private static func text(_ statement: OpaquePointer, _ column: Int32) -> String {
        guard let value = sqlite3_column_text(statement, column) else { return "" }
        return String(cString: value)
    }
}

private enum SQLiteReadValue {
    case int64(Int64)
    case double(Double)
    case text(String)
}

/// Minimal query-only SQLite wrapper. Keeping it private prevents other CLI
/// code from accidentally growing a write path to the user's screen history.
private final class ReadOnlySQLiteConnection {
    private let handle: OpaquePointer

    init(url: URL) throws {
        var opened: OpaquePointer?
        let result = sqlite3_open_v2(
            url.path,
            &opened,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
            nil)
        guard result == SQLITE_OK, let opened else {
            let message = opened.map { String(cString: sqlite3_errmsg($0)) }
                ?? String(cString: sqlite3_errstr(result))
            if let opened { sqlite3_close(opened) }
            throw ScreenMemoryReaderError.databaseUnavailable(
                path: url.path, message: message)
        }
        handle = opened
        sqlite3_extended_result_codes(handle, 1)
        sqlite3_busy_timeout(handle, 5_000)
    }

    deinit {
        sqlite3_close(handle)
    }

    func query<T>(
        _ sql: String,
        bindings: [SQLiteReadValue] = [],
        row: (OpaquePointer) throws -> T
    ) throws -> [T] {
        var statement: OpaquePointer?
        let prepare = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard prepare == SQLITE_OK, let statement else {
            throw ScreenMemoryReaderError.queryFailed(
                message: String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(statement) }
        try bind(bindings, to: statement)

        var result: [T] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                result.append(try row(statement))
            case SQLITE_DONE:
                return result
            default:
                throw ScreenMemoryReaderError.queryFailed(
                    message: String(cString: sqlite3_errmsg(handle)))
            }
        }
    }

    func scalarInt(_ sql: String, bindings: [SQLiteReadValue] = []) throws -> Int {
        try query(sql, bindings: bindings) { Int(sqlite3_column_int64($0, 0)) }.first ?? 0
    }

    func tableExists(_ name: String) throws -> Bool {
        try scalarInt(
            "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = ?1",
            bindings: [.text(name)]) > 0
    }

    func columnExists(_ column: String, in table: String) throws -> Bool {
        // Table and column names are internal constants at every call site.
        try query("PRAGMA table_info(\(table))") { statement in
            Self.text(statement, 1)
        }.contains(column)
    }

    private static func text(_ statement: OpaquePointer, _ column: Int32) -> String {
        guard let value = sqlite3_column_text(statement, column) else { return "" }
        return String(cString: value)
    }

    private func bind(_ values: [SQLiteReadValue], to statement: OpaquePointer) throws {
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch value {
            case .int64(let integer):
                result = sqlite3_bind_int64(statement, index, integer)
            case .double(let double):
                result = sqlite3_bind_double(statement, index, double)
            case .text(let text):
                result = sqlite3_bind_text(statement, index, text, -1, Self.transient)
            }
            guard result == SQLITE_OK else {
                throw ScreenMemoryReaderError.queryFailed(
                    message: String(cString: sqlite3_errmsg(handle)))
            }
        }
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
}
