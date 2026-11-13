import Foundation
import SQLite3

extension Notification.Name {
    static let retainedScreenTextChanged = Notification.Name("retainedScreenTextChanged")
}

/// FTS indexes words, not its UNINDEXED identity/timestamp columns. Keep an
/// ordinary index of FTS row IDs; historical row IDs are not screenshot IDs.
enum OCRMetadataIndex {
    static func migrate(_ database: SQLiteDatabase) throws {
        guard !database.hasRow("SELECT 1 FROM sqlite_master WHERE name = 'ocr_metadata'") else { return }
        try database.withTransaction {
            try database.execute("""
                CREATE TABLE ocr_metadata (rowid INTEGER PRIMARY KEY, snapshot_id INTEGER NOT NULL, ts REAL NOT NULL);
                CREATE INDEX idx_ocr_metadata_snapshot ON ocr_metadata(snapshot_id, rowid);
                CREATE INDEX idx_ocr_metadata_ts ON ocr_metadata(ts, snapshot_id);
                INSERT INTO ocr_metadata
                    SELECT rowid, CAST(snapshot_id AS INTEGER), CAST(ts AS REAL) FROM ocr_fts;
                """)
        }
    }

    /// Called inside the same transaction as FTS deletion. No text is retained
    /// here, and stale identities must not outlive retention or explicit delete.
    static func removeDeletedRows(_ database: SQLiteDatabase) throws {
        try database.execute("DELETE FROM ocr_metadata WHERE rowid NOT IN (SELECT rowid FROM ocr_fts)")
    }
}

extension ActivityStore {
    /// Bounded batches preserve substring matching and the earliest FTS row
    /// semantics of point lookup, including migrated libraries with duplicate rows.
    func matchingSnapshotIDs(_ ids: [Int64], query: String) -> Set<Int64> {
        guard !query.isEmpty, let database = SQLiteDatabase(url: databaseURL, readOnly: true) else { return [] }
        var matches: Set<Int64> = []
        for start in stride(from: 0, to: ids.count, by: 400) {
            guard !Task.isCancelled else { return [] }
            let batch = Array(ids[start..<min(start + 400, ids.count)])
            let parameters = batch.indices.map { "?\($0 + 1)" }.joined(separator: ",")
            let found: [Int64] = database.query("""
                SELECT meta.snapshot_id, ocr.text FROM ocr_metadata AS meta
                JOIN ocr_fts AS ocr ON ocr.rowid = meta.rowid
                WHERE meta.snapshot_id IN (\(parameters))
                  AND meta.rowid = (SELECT MIN(first.rowid) FROM ocr_metadata AS first
                                   WHERE first.snapshot_id = meta.snapshot_id)
                """, bind: batch) { row in
                guard let text = sqlite3_column_text(row, 1),
                      String(String(cString: text).prefix(100_000)).localizedCaseInsensitiveContains(query) else { return nil }
                return sqlite3_column_int64(row, 0)
            }
            matches.formUnion(found)
        }
        return matches
    }

    static func readInBackground<Value: Sendable>(
        at url: URL,
        _ read: @escaping @Sendable (ActivityStore) -> Value
    ) async -> Value {
        let worker = Task.detached(priority: .userInitiated) {
            let reader = ActivityStore(databaseURL: url, readOnly: true)
            return reader.withReadSnapshot { read(reader) }
        }
        return await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
    }
}
