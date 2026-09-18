import Foundation
import SQLite3

/// Coalesces expensive embedding-model preparation by destination. Waiters
/// can cancel independently; the shared operation is canceled only after its
/// final waiter leaves, so one abandoned search cannot break active indexing.
actor EmbeddingModelPreparationCoordinator {
    typealias Operation = @Sendable () async throws -> URL

    private struct Flight {
        let id: UUID
        let task: Task<URL, Error>
        var waiters: [UUID: CheckedContinuation<URL, Error>]
    }

    private var flights: [String: Flight] = [:]

    func prepare(key: String, operation: @escaping Operation) async throws -> URL {
        let waiterID = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                enqueue(
                    waiterID: waiterID,
                    key: key,
                    operation: operation,
                    continuation: continuation)
            }
        } onCancel: {
            Task { await self.cancel(waiterID: waiterID, key: key) }
        }
    }

    func waiterCount(for key: String) -> Int {
        flights[key]?.waiters.count ?? 0
    }

    private func enqueue(
        waiterID: UUID,
        key: String,
        operation: @escaping Operation,
        continuation: CheckedContinuation<URL, Error>
    ) {
        if var flight = flights[key] {
            flight.waiters[waiterID] = continuation
            flights[key] = flight
            return
        }
        let flightID = UUID()
        let task = Task { try await operation() }
        flights[key] = Flight(
            id: flightID,
            task: task,
            waiters: [waiterID: continuation])
        Task { [weak self] in
            let result = await task.result
            await self?.finish(key: key, flightID: flightID, result: result)
        }
    }

    private func cancel(waiterID: UUID, key: String) {
        guard var flight = flights[key],
              let continuation = flight.waiters.removeValue(forKey: waiterID) else { return }
        continuation.resume(throwing: CancellationError())
        // Keep the preparation flight alive even when its current waiter set
        // becomes empty. Download/install cancellation is not guaranteed to be
        // instantaneous; retaining the flight lets a later caller rejoin it
        // instead of racing a second install against a still-unwinding first.
        flights[key] = flight
    }

    private func finish(key: String, flightID: UUID, result: Result<URL, Error>) {
        guard let flight = flights[key], flight.id == flightID else { return }
        flights[key] = nil
        for continuation in flight.waiters.values {
            continuation.resume(with: result)
        }
    }
}

/// Deterministic reciprocal-rank fusion for lexical + semantic screen search.
/// It intentionally consumes only stable snapshot IDs: metadata is resolved
/// through `ActivityStore.screenshot(id:)`, avoiding stale duplicated rows.
enum ScreenSearchRanker {
    struct RankedSnapshot: Identifiable, Equatable, Sendable {
        let snapshotID: Int64
        let score: Double
        let keywordRank: Int?
        let semanticRank: Int?

        var id: Int64 { snapshotID }
    }

    static func fuse(
        keyword: [ActivityStore.OCRHit],
        semantic: [EmbeddingIndex.ScreenHit],
        limit: Int = 40,
        rankConstant: Double = 60
    ) -> [RankedSnapshot] {
        guard limit > 0 else { return [] }
        let constant = max(1, rankConstant)
        var keywordRanks: [Int64: Int] = [:]
        var semanticRanks: [Int64: Int] = [:]

        for (offset, hit) in keyword.enumerated() where keywordRanks[hit.snapshotID] == nil {
            keywordRanks[hit.snapshotID] = offset + 1
        }
        for (offset, hit) in semantic.enumerated() where semanticRanks[hit.snapshotID] == nil {
            semanticRanks[hit.snapshotID] = offset + 1
        }

        let snapshotIDs = Set(keywordRanks.keys).union(semanticRanks.keys)
        return snapshotIDs.map { snapshotID in
            let keywordRank = keywordRanks[snapshotID]
            let semanticRank = semanticRanks[snapshotID]
            let score = [keywordRank, semanticRank].compactMap { $0 }.reduce(0.0) {
                $0 + 1.0 / (constant + Double($1))
            }
            return RankedSnapshot(
                snapshotID: snapshotID,
                score: score,
                keywordRank: keywordRank,
                semanticRank: semanticRank)
        }.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            let lhsBest = min(lhs.keywordRank ?? .max, lhs.semanticRank ?? .max)
            let rhsBest = min(rhs.keywordRank ?? .max, rhs.semanticRank ?? .max)
            if lhsBest != rhsBest { return lhsBest < rhsBest }
            return lhs.snapshotID < rhs.snapshotID
        }.prefix(limit).map { $0 }
    }
}

/// M6 semantic layer (design §4.1): transcript/summary chunks embedded with
/// Harrier 0.6B GGUF, served by the second llama-server instance.
/// Vectors live in SQLite; query = brute-force cosine (normalized dot) —
/// instant at personal-library scale, no extra dependency.
@MainActor
final class EmbeddingIndex {

    struct Hit: Identifiable, Sendable {
        let id = UUID()
        let meetingID: UUID
        let start: TimeInterval
        let text: String
        let score: Float
    }

    struct ScreenHit: Identifiable, Equatable, Sendable {
        let snapshotID: Int64
        let ts: Date
        let app: String
        let text: String
        let score: Float

        var id: Int64 { snapshotID }
    }

    private static let modelID = "harrier-oss-v1-0.6b-q8"
    /// Persisted separately from the server-facing model name. Any change to
    /// pooling, prompting, or chunking must advance this value so vectors made
    /// under incompatible contracts are discarded before search resumes.
    nonisolated static let indexVersion = "harrier-oss-v1-0.6b-q8-last-chunks-v1"
    nonisolated private static let modelFile = "harrier-oss-v1-0.6b.Q8_0.gguf"
    nonisolated private static let modelBytes: Int64 = 639_448_320
    nonisolated private static let modelSHA256 = "ba2c9408f82cfdb73aaf70aaea9f125f3fb24c5e76ce0efb469e1530e5ec53e4"
    nonisolated private static let modelURL =
        "https://huggingface.co/mradermacher/harrier-oss-v1-0.6b-GGUF/resolve/d79decec1ab9442e969e79804515b9c31683d30e/harrier-oss-v1-0.6b.Q8_0.gguf"
    private static let documentPrefix = "Document for meeting search: "
    private static let queryPrefix = """
        Instruct: Retrieve relevant meeting transcript and summary chunks for the user's query.
        Query:
        """
    private static let screenDocumentPrefix = "Document from screen memory: "
    private static let screenQueryPrefix = """
        Instruct: Retrieve relevant OCR text captured from the user's screen.
        Query:
        """
    nonisolated static let transcriptChunkTargetCharacters = 500
    /// Preserve the existing chunk shape for normal ASR output while keeping a
    /// single pathological segment safely below the embedder's 2K context.
    nonisolated static let transcriptChunkHardLimitCharacters = 1_800
    private static let modelPreparation = EmbeddingModelPreparationCoordinator()

    private let database: SQLiteDatabase?
    private let storage: StorageManager
    private var locallyDeletedMeetingIDs: Set<UUID> = []
    private var screenReindexFlight: (id: UUID, task: Task<Void, Never>)?

    init(databaseURL: URL, storage: StorageManager) {
        self.storage = storage
        database = SQLiteDatabase(url: databaseURL)
        database?.exec("""
            CREATE TABLE IF NOT EXISTS embeddings (
                meeting_id TEXT NOT NULL, start REAL NOT NULL,
                text TEXT NOT NULL, vec BLOB NOT NULL);
            CREATE TABLE IF NOT EXISTS embedded_meetings (
                meeting_id TEXT PRIMARY KEY, source_mtime REAL NOT NULL,
                model_id TEXT NOT NULL DEFAULT '');
            CREATE INDEX IF NOT EXISTS idx_embeddings_meeting_id
                ON embeddings(meeting_id);
            CREATE TABLE IF NOT EXISTS deleted_meetings (
                meeting_id TEXT PRIMARY KEY,
                deleted_at REAL NOT NULL
            );
            CREATE TABLE IF NOT EXISTS screen_embeddings (
                snapshot_id INTEGER PRIMARY KEY,
                ts REAL NOT NULL,
                app TEXT NOT NULL,
                text TEXT NOT NULL,
                vec BLOB NOT NULL,
                model_id TEXT NOT NULL DEFAULT '',
                FOREIGN KEY(snapshot_id) REFERENCES screenshots(id) ON DELETE CASCADE
            );
            CREATE INDEX IF NOT EXISTS idx_screen_embeddings_ts
                ON screen_embeddings(ts);
            CREATE INDEX IF NOT EXISTS idx_screen_embeddings_app_ts
                ON screen_embeddings(app, ts);
            """)
        if database?.hasRow(
            "SELECT 1 FROM pragma_table_info('embedded_meetings') WHERE name = 'model_id'"
        ) == false {
            database?.exec(
                "ALTER TABLE embedded_meetings ADD COLUMN model_id TEXT NOT NULL DEFAULT '';")
        }
        if let database {
            database.transaction {
                database.run("""
                DELETE FROM embeddings
                WHERE meeting_id IN (
                    SELECT meeting_id FROM embedded_meetings WHERE model_id != ?1
                )
                """, bind: [Self.indexVersion])
                    && database.run(
                    "DELETE FROM embedded_meetings WHERE model_id != ?1",
                    bind: [Self.indexVersion])
            }
            if database.hasRow("""
                SELECT 1 FROM sqlite_master
                WHERE type = 'table' AND name = 'screenshots'
                """) {
                database.run(
                    "DELETE FROM screen_embeddings WHERE model_id != ?1",
                    bind: [Self.indexVersion])
            }
        }
        _ = reconcileDeletedMeetings()
    }

    // MARK: - Indexing

    func reindexAll(_ meetings: [Meeting]) async {
        for meeting in meetings {
            guard !Task.isCancelled else { return }
            try? await index(meeting)
        }
    }

    /// Matches the historical ~500-character transcript chunks for ordinary
    /// segments. A malformed or low-quality ASR segment can contain thousands
    /// of characters, so enforce a separate hard ceiling before it reaches the
    /// embedding server. Split pieces preserve every source character and keep
    /// the segment timestamp for deep-linking.
    nonisolated static func transcriptChunks(
        _ transcript: Transcript
    ) -> [(start: TimeInterval, text: String)] {
        var chunks: [(start: TimeInterval, text: String)] = []
        var current = ""
        var start: TimeInterval = 0

        func flushCurrent() {
            guard !current.isEmpty else { return }
            chunks.append((start, current))
            current = ""
        }

        for segment in transcript.segments {
            let line = "\(transcript.displaySpeaker(for: segment.speaker)): \(segment.text)\n"
            if line.count > transcriptChunkHardLimitCharacters {
                flushCurrent()
                chunks.append(contentsOf: splitEmbeddingText(
                    line,
                    maximumCharacters: transcriptChunkTargetCharacters
                ).map { (start: segment.start, text: $0) })
                continue
            }

            if !current.isEmpty,
               current.count + line.count > transcriptChunkHardLimitCharacters {
                flushCurrent()
            }
            if current.isEmpty { start = segment.start }
            current += line
            if current.count > transcriptChunkTargetCharacters {
                flushCurrent()
            }
        }
        flushCurrent()
        return chunks
    }

    /// Prefer a nearby whitespace boundary but fall back to an exact character
    /// boundary for very long unbroken tokens. Substrings are not trimmed, so
    /// concatenating the pieces reconstructs the original input byte-for-byte.
    nonisolated private static func splitEmbeddingText(
        _ text: String,
        maximumCharacters: Int
    ) -> [String] {
        precondition(maximumCharacters > 0)
        var remaining = text[...]
        var pieces: [String] = []
        while remaining.count > maximumCharacters {
            let hardEnd = remaining.index(
                remaining.startIndex,
                offsetBy: maximumCharacters)
            let softStart = remaining.index(
                remaining.startIndex,
                offsetBy: maximumCharacters / 2)
            let candidate = remaining[..<hardEnd]
            let whitespace = candidate.indices.reversed().first {
                $0 >= softStart && candidate[$0].isWhitespace
            }
            let end = whitespace.map { remaining.index(after: $0) } ?? hardEnd
            pieces.append(String(remaining[..<end]))
            remaining = remaining[end...]
        }
        if !remaining.isEmpty { pieces.append(String(remaining)) }
        return pieces
    }

    func index(_ meeting: Meeting) async throws {
        guard !isDeleted(meeting.id) else { return }
        let folder = meeting.folderURL(in: storage)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return }
        let mtime = ["transcript.json", "summary.md"].compactMap {
            (try? FileManager.default.attributesOfItem(
                atPath: folder.appendingPathComponent($0).path))?[.modificationDate] as? Date
        }.map(\.timeIntervalSince1970).max() ?? 0
        guard mtime > 0, indexedMtime(meeting.id) ?? -1 < mtime else { return }

        var chunks: [(start: TimeInterval, text: String)] = []
        if let data = try? Data(contentsOf: folder.appendingPathComponent("transcript.json")),
           let transcript = try? JSONDecoder().decode(Transcript.self, from: data) {
            chunks.append(contentsOf: Self.transcriptChunks(transcript))
        }
        if let summary = try? String(contentsOf: folder.appendingPathComponent("summary.md"),
                                     encoding: .utf8) {
            for section in summary.components(separatedBy: "\n## ") where section.count > 40 {
                chunks.append((0, String(section.prefix(700))))
            }
        }
        guard !chunks.isEmpty else { return }

        let vectors = try await Self.embed(chunks.map(\.text), prefix: Self.documentPrefix,
                                           storage: storage)
        try Task.checkCancellation()
        guard vectors.count == chunks.count else {
            throw TextEngineError.badResponse(
                "embedding response contained \(vectors.count) vectors for \(chunks.count) chunks")
        }
        let rows = zip(chunks, vectors).map { chunk, vector in
            let vectorData = vector.withUnsafeBufferPointer { buffer -> Data in
                guard let baseAddress = buffer.baseAddress else { return Data() }
                return Data(bytes: baseAddress, count: buffer.count * MemoryLayout<Float>.stride)
            }
            return (start: chunk.start, text: String(chunk.text.prefix(300)), vectorData: vectorData)
        }

        guard let database else { return }
        let meetingID = meeting.id.uuidString
        database.transaction {
            do {
                guard try !database.hasRowChecked(
                    "SELECT 1 FROM deleted_meetings WHERE meeting_id = ?1",
                    bind: [meetingID]),
                      FileManager.default.fileExists(atPath: folder.path) else { return true }
                // Embedding can suspend for minutes. Recheck freshness under
                // BEGIN IMMEDIATE so an older request cannot replace a newer
                // snapshot after it finally receives vectors.
                if let indexed = try database.firstDoubleChecked(
                    """
                    SELECT source_mtime FROM embedded_meetings
                    WHERE meeting_id = ?1 AND model_id = ?2
                    """, bind: [meetingID, Self.indexVersion]), indexed >= mtime {
                    return true
                }
            } catch {
                return false
            }
            guard database.run(
                "DELETE FROM embeddings WHERE meeting_id = ?1",
                bind: [meetingID]) else { return false }
            let inserted = database.withStatement(
                "INSERT INTO embeddings (meeting_id, start, text, vec) VALUES (?1, ?2, ?3, ?4)"
            ) { statement in
                for row in rows {
                    guard database.run(statement, bind: [
                        meetingID, row.start, row.text, row.vectorData,
                    ]) else { return false }
                }
                return true
            } ?? false
            guard inserted else { return false }
            return database.run(
                "INSERT OR REPLACE INTO embedded_meetings (meeting_id, source_mtime, model_id) VALUES (?1, ?2, ?3)",
                bind: [meetingID, mtime, Self.indexVersion])
        }
    }

    @discardableResult
    func remove(_ meetingID: UUID) -> Bool {
        noteDeletion(meetingID)
        guard let database else { return false }
        return Self.remove(meetingID, in: database)
    }

    /// Immediately closes the async rank/delete race without waiting for a
    /// potentially busy SQLite writer. AppState follows this in-memory marker
    /// with durable utility-worker cleanup.
    func noteDeletion(_ meetingID: UUID) {
        locallyDeletedMeetingIDs.insert(meetingID)
    }

    /// Reopens a meeting whose durable deletion marker was created by a
    /// reversible merge fold. The caller reindexes the restored source after
    /// this marker is removed.
    @discardableResult
    func restore(_ meetingID: UUID) -> Bool {
        locallyDeletedMeetingIDs.remove(meetingID)
        guard let database else { return false }
        return Self.restore(meetingID, in: database)
    }

    @discardableResult
    nonisolated static func restore(_ meetingID: UUID, databaseURL: URL) -> Bool {
        guard let database = SQLiteDatabase(url: databaseURL) else { return false }
        return restore(meetingID, in: database)
    }

    /// Utility-worker entry point used by AppState deletion. It deliberately
    /// opens its own FULLMUTEX connection so SQLite's busy timeout can never
    /// stall the main actor.
    @discardableResult
    nonisolated static func remove(_ meetingID: UUID, databaseURL: URL) -> Bool {
        guard let database = SQLiteDatabase(url: databaseURL) else { return false }
        return remove(meetingID, in: database)
    }

    /// Completes cleanup for tombstones whose original deletion was
    /// interrupted. The tombstone remains the source of truth and query paths
    /// exclude it while these reconstructible rows are being removed.
    @discardableResult
    func reconcileDeletedMeetings() -> Bool {
        guard let database else { return false }
        return Self.reconcileDeletedMeetings(in: database)
    }

    @discardableResult
    nonisolated static func reconcileDeletedMeetings(databaseURL: URL) -> Bool {
        guard let database = SQLiteDatabase(url: databaseURL) else { return false }
        return reconcileDeletedMeetings(in: database)
    }

    // MARK: - Query

    var hasEmbeddings: Bool {
        database?.hasRow("""
            SELECT 1 FROM embeddings AS embedded
            WHERE EXISTS (
                SELECT 1 FROM embedded_meetings AS indexed
                WHERE indexed.meeting_id = embedded.meeting_id
                  AND indexed.model_id = ?1
            )
              AND NOT EXISTS (
                SELECT 1 FROM deleted_meetings AS deleted
                WHERE deleted.meeting_id = embedded.meeting_id
            )
            LIMIT 1
            """, bind: [Self.indexVersion]) ?? false
    }

    var hasScreenEmbeddings: Bool {
        guard let database,
              database.hasRow("""
                SELECT 1 FROM sqlite_master
                WHERE type = 'table' AND name = 'screenshots'
                """),
              database.hasRow("""
                SELECT 1 FROM sqlite_master
                WHERE type = 'table' AND name = 'ocr_fts'
                """) else { return false }
        return database.hasRow("""
            SELECT 1 FROM screen_embeddings AS embedded
            JOIN screenshots AS shot ON shot.id = embedded.snapshot_id
            WHERE embedded.model_id = ?1
              AND EXISTS (
                  SELECT 1 FROM ocr_fts AS ocr
                  WHERE CAST(ocr.snapshot_id AS INTEGER) = embedded.snapshot_id
              )
            LIMIT 1
            """, bind: [Self.indexVersion])
    }

    /// Backfills immutable OCR rows that do not yet have a vector. This is
    /// invoked lazily by semantic screen search, so users who never enable that
    /// feature do not download a model or spend background inference time.
    func reindexScreenText() async {
        if let flight = screenReindexFlight {
            await flight.task.value
            return
        }
        let id = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performScreenTextReindex()
        }
        screenReindexFlight = (id, task)
        await task.value
        if screenReindexFlight?.id == id {
            screenReindexFlight = nil
        }
    }

    private func performScreenTextReindex() async {
        guard let database,
              database.hasRow("""
                SELECT 1 FROM sqlite_master
                WHERE type = 'table' AND name = 'ocr_fts'
                """),
              database.hasRow("""
                SELECT 1 FROM sqlite_master
                WHERE type = 'table' AND name = 'screenshots'
                """) else { return }

        while !Task.isCancelled {
            let batch: [ScreenDocument] = database.query("""
                SELECT CAST(ocr.snapshot_id AS INTEGER), CAST(ocr.ts AS REAL),
                       ocr.app, ocr.text
                FROM ocr_fts AS ocr
                JOIN screenshots AS shot
                  ON shot.id = CAST(ocr.snapshot_id AS INTEGER)
                WHERE CAST(ocr.snapshot_id AS INTEGER) > 0
                  AND NOT EXISTS (
                      SELECT 1 FROM screen_embeddings AS embedded
                      WHERE embedded.snapshot_id = CAST(ocr.snapshot_id AS INTEGER)
                        AND embedded.model_id = ?1
                  )
                ORDER BY CAST(ocr.ts AS REAL), CAST(ocr.snapshot_id AS INTEGER)
                LIMIT 32
                """, bind: [Self.indexVersion]) { statement in
                guard let app = sqlite3_column_text(statement, 2),
                      let text = sqlite3_column_text(statement, 3) else { return nil }
                let snapshotID = sqlite3_column_int64(statement, 0)
                guard snapshotID > 0 else { return nil }
                return ScreenDocument(
                    snapshotID: snapshotID,
                    ts: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                    app: String(cString: app),
                    text: String(String(cString: text).prefix(1_500)))
            }
            guard !batch.isEmpty else { return }
            guard !Task.isCancelled else { return }
            do {
                let vectors = try await Self.embed(
                    batch.map(\.text), prefix: Self.screenDocumentPrefix,
                    storage: storage)
                try Task.checkCancellation()
                guard vectors.count == batch.count else {
                    throw TextEngineError.badResponse(
                        "screen embedding response contained \(vectors.count) vectors "
                        + "for \(batch.count) OCR rows")
                }
                try database.withTransaction {
                    for (document, vector) in zip(batch, vectors) {
                        let vectorData = Self.vectorData(vector)
                        // Retention or explicit deletion may remove OCR while
                        // embedding is suspended. Recheck the exact live text
                        // under the write transaction so an in-flight backfill
                        // cannot resurrect expired plaintext in this table.
                        let liveTexts: [String] = try database.queryChecked("""
                            SELECT ocr.text FROM ocr_fts AS ocr
                            JOIN screenshots AS shot
                              ON shot.id = CAST(ocr.snapshot_id AS INTEGER)
                            WHERE CAST(ocr.snapshot_id AS INTEGER) = ?1
                            LIMIT 1
                            """, bind: [document.snapshotID]) { statement in
                            guard let value = sqlite3_column_text(statement, 0) else {
                                return nil
                            }
                            return String(cString: value)
                        }
                        guard let liveText = liveTexts.first,
                              String(liveText.prefix(1_500)) == document.text else { continue }
                        try database.runChecked("""
                            INSERT OR REPLACE INTO screen_embeddings (
                                snapshot_id, ts, app, text, vec, model_id
                            ) VALUES (?1, ?2, ?3, ?4, ?5, ?6)
                            """, bind: [
                                document.snapshotID,
                                document.ts.timeIntervalSince1970,
                                document.app,
                                document.text,
                                vectorData,
                                Self.indexVersion,
                            ])
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                lokalbotLog("screen embedding backfill failed: \(error.localizedDescription)")
                return
            }
        }
    }

    /// Semantic retrieval over screen OCR, with the same date/app filter
    /// contract as lexical FTS. Results retain the snapshot ID needed for an
    /// exact citation, thumbnail, saved moment, or timeline jump.
    func searchScreen(
        _ query: String,
        filter: ScreenSearchFilter = .all,
        limit: Int = 10
    ) async -> [ScreenHit] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard limit > 0, !trimmed.isEmpty, let database else { return [] }
        await reindexScreenText()
        guard !Task.isCancelled, hasScreenEmbeddings,
              let queryVector = try? await Self.embed(
                [trimmed], prefix: Self.screenQueryPrefix, storage: storage).first
        else { return [] }

        var conditions = ["embedded.model_id = ?1"]
        var bindings: [Any] = [Self.indexVersion]
        if let ids = filter.snapshotIDs {
            guard !ids.isEmpty else { return [] }
            let placeholders = ids.sorted().map { id -> String in
                bindings.append(id)
                return "?\(bindings.count)"
            }
            conditions.append("embedded.snapshot_id IN (\(placeholders.joined(separator: ",")))")
        }
        if let interval = filter.interval {
            let startParameter = bindings.count + 1
            bindings.append(interval.start.timeIntervalSince1970)
            let endParameter = bindings.count + 1
            bindings.append(interval.end.timeIntervalSince1970)
            conditions.append(
                "embedded.ts >= ?\(startParameter) AND embedded.ts < ?\(endParameter)")
        }
        if let app = filter.app {
            let parameter = bindings.count + 1
            bindings.append(app)
            conditions.append("embedded.app = ?\(parameter) COLLATE NOCASE")
        }

        let candidates: [ScreenCandidate] = database.query("""
            SELECT embedded.snapshot_id, embedded.ts, embedded.app,
                   embedded.text, embedded.vec
            FROM screen_embeddings AS embedded
            JOIN screenshots AS shot ON shot.id = embedded.snapshot_id
            WHERE \(conditions.joined(separator: " AND "))
              AND EXISTS (
                  SELECT 1 FROM ocr_fts AS ocr
                  WHERE CAST(ocr.snapshot_id AS INTEGER) = embedded.snapshot_id
              )
            ORDER BY embedded.snapshot_id
            """, bind: bindings) { statement in
            guard let app = sqlite3_column_text(statement, 2),
                  let text = sqlite3_column_text(statement, 3),
                  let blob = sqlite3_column_blob(statement, 4) else { return nil }
            let byteCount = Int(sqlite3_column_bytes(statement, 4))
            guard byteCount == queryVector.count * MemoryLayout<Float>.stride else { return nil }
            return ScreenCandidate(
                snapshotID: sqlite3_column_int64(statement, 0),
                ts: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                app: String(cString: app),
                text: String(cString: text),
                vector: Data(bytes: blob, count: byteCount))
        }
        let ranked = await Task.detached(priority: .userInitiated) {
            Self.rankScreen(candidates, against: queryVector, limit: limit)
        }.value
        guard !Task.isCancelled else { return [] }
        return ranked.filter { hit in
            database.hasRow(
                "SELECT 1 FROM screenshots WHERE id = ?1",
                bind: [hit.snapshotID])
        }
    }

    func search(_ query: String, limit: Int = 10,
                meetingIDs: Set<UUID>? = nil) async -> [Hit] {
        guard limit > 0, let database, hasEmbeddings else { return [] }
        if let meetingIDs, meetingIDs.isEmpty { return [] }
        guard let queryVector = try? await Self.embed([query], prefix: Self.queryPrefix,
                                                      storage: storage).first else { return [] }
        let candidates: [Candidate] = database.query(
            """
            SELECT embedded.meeting_id, embedded.start, embedded.text, embedded.vec
            FROM embeddings AS embedded
            WHERE EXISTS (
                SELECT 1 FROM embedded_meetings AS indexed
                WHERE indexed.meeting_id = embedded.meeting_id
                  AND indexed.model_id = ?1
            )
              AND NOT EXISTS (
                SELECT 1 FROM deleted_meetings AS deleted
                WHERE deleted.meeting_id = embedded.meeting_id
            )
            """, bind: [Self.indexVersion]
        ) { statement in
            guard let idText = sqlite3_column_text(statement, 0),
                  let meetingID = UUID(uuidString: String(cString: idText)),
                  let text = sqlite3_column_text(statement, 2),
                  let blob = sqlite3_column_blob(statement, 3) else { return nil }
            let byteCount = Int(sqlite3_column_bytes(statement, 3))
            guard byteCount == queryVector.count * MemoryLayout<Float>.stride else { return nil }
            let candidate = Candidate(
                meetingID: meetingID,
                start: sqlite3_column_double(statement, 1),
                text: String(cString: text),
                vector: Data(bytes: blob, count: byteCount))
            guard meetingIDs?.contains(candidate.meetingID) ?? true else { return nil }
            return candidate
        }
        let ranked = await Task.detached(priority: .userInitiated) {
            Self.rank(candidates, against: queryVector, limit: limit)
        }.value
        guard !Task.isCancelled else { return [] }
        // Ranking yields the main actor. A meeting can be deleted after the
        // candidate snapshot but before ranking completes, so validate again
        // synchronously before publishing any hit.
        return liveHits(from: ranked)
    }

    func liveHits(from hits: [Hit]) -> [Hit] {
        hits.filter { !isDeleted($0.meetingID) }
    }

    private struct Candidate: Sendable {
        let meetingID: UUID
        let start: TimeInterval
        let text: String
        let vector: Data
    }

    private struct ScreenDocument: Sendable {
        let snapshotID: Int64
        let ts: Date
        let app: String
        let text: String
    }

    struct ScreenCandidate: Sendable {
        let snapshotID: Int64
        let ts: Date
        let app: String
        let text: String
        let vector: Data
    }

    /// Cosine scoring is the expensive part of brute-force retrieval. Keep it
    /// off the main actor and retain only the best `limit` rows instead of
    /// allocating and sorting a hit for every embedding in the library.
    nonisolated private static func rank(
        _ candidates: [Candidate],
        against queryVector: [Float],
        limit: Int
    ) -> [Hit] {
        var best: [Hit] = []
        best.reserveCapacity(limit)

        for candidate in candidates {
            let score: Float = candidate.vector.withUnsafeBytes { bytes in
                var total: Float = 0
                for index in queryVector.indices {
                    let value = bytes.loadUnaligned(
                        fromByteOffset: index * MemoryLayout<Float>.stride,
                        as: Float.self)
                    total += queryVector[index] * value
                }
                return total
            }
            guard score > 0.45 else { continue }
            let hit = Hit(meetingID: candidate.meetingID, start: candidate.start,
                          text: candidate.text, score: score)
            if best.count < limit {
                best.append(hit)
            } else if let weakest = best.indices.min(by: { best[$0].score < best[$1].score }),
                      score > best[weakest].score {
                best[weakest] = hit
            }
        }
        return best.sorted { $0.score > $1.score }
    }

    nonisolated static func rankScreen(
        _ candidates: [ScreenCandidate],
        against queryVector: [Float],
        limit: Int
    ) -> [ScreenHit] {
        var best: [ScreenHit] = []
        best.reserveCapacity(limit)
        for candidate in candidates {
            let score = cosine(candidate.vector, queryVector: queryVector)
            guard score > 0.35 else { continue }
            let hit = ScreenHit(
                snapshotID: candidate.snapshotID,
                ts: candidate.ts,
                app: candidate.app,
                text: candidate.text,
                score: score)
            if best.count < limit {
                best.append(hit)
            } else if let weakest = best.indices.min(by: {
                let lhs = best[$0]
                let rhs = best[$1]
                if lhs.score != rhs.score { return lhs.score < rhs.score }
                if lhs.ts != rhs.ts { return lhs.ts < rhs.ts }
                return lhs.snapshotID > rhs.snapshotID
            }), Self.screenHitSort(hit, best[weakest]) {
                best[weakest] = hit
            }
        }
        return best.sorted(by: screenHitSort)
    }

    nonisolated private static func cosine(_ vector: Data, queryVector: [Float]) -> Float {
        vector.withUnsafeBytes { bytes in
            var total: Float = 0
            for index in queryVector.indices {
                let value = bytes.loadUnaligned(
                    fromByteOffset: index * MemoryLayout<Float>.stride,
                    as: Float.self)
                total += queryVector[index] * value
            }
            return total
        }
    }

    nonisolated private static func screenHitSort(_ lhs: ScreenHit, _ rhs: ScreenHit) -> Bool {
        if lhs.score != rhs.score { return lhs.score > rhs.score }
        if lhs.ts != rhs.ts { return lhs.ts > rhs.ts }
        return lhs.snapshotID < rhs.snapshotID
    }

    nonisolated private static func vectorData(_ vector: [Float]) -> Data {
        vector.withUnsafeBufferPointer { buffer -> Data in
            guard let baseAddress = buffer.baseAddress else { return Data() }
            return Data(bytes: baseAddress, count: buffer.count * MemoryLayout<Float>.stride)
        }
    }

    // MARK: - Embedding via llama-server

    private static func embed(_ texts: [String], prefix: String,
                              storage: StorageManager) async throws -> [[Float]] {
        let modelPath = try await ensureModel(storage: storage)
        return try await InferenceBroker.shared.withLease(
            .embedder, model: modelPath, priority: .background,
            purpose: "embeddings") { () async throws -> [[Float]] in
            var request = URLRequest(url: LlamaServer.embedder.baseURL
                .appendingPathComponent("embeddings"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let authenticationToken = await LlamaServer.embedder.authenticationToken()
            request.setValue("Bearer \(authenticationToken)", forHTTPHeaderField: "Authorization")
            request.timeoutInterval = 120
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "input": texts.map { prefix + $0 },
                "model": Self.modelID,
            ])
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let rows = json["data"] as? [[String: Any]] else {
                throw TextEngineError.badResponse("unexpected /v1/embeddings payload")
            }
            return rows.compactMap { row -> [Float]? in
                guard let values = row["embedding"] as? [Double] else { return nil }
                let vector = values.map(Float.init)
                let norm = sqrt(vector.reduce(0) { $0 + $1 * $1 })
                return norm > 0 ? vector.map { $0 / norm } : vector
            }
        }
    }

    private static func ensureModel(storage: StorageManager) async throws -> URL {
        let storageRoot = storage.rootURL
        let key = storageRoot.appendingPathComponent("models/\(modelFile)")
            .standardizedFileURL.resolvingSymlinksInPath().path
        return try await modelPreparation.prepare(key: key) {
            try await prepareModel(storageRoot: storageRoot)
        }
    }

    private nonisolated static func prepareModel(storageRoot: URL) async throws -> URL {
        let folder = storageRoot.appendingPathComponent("models", isDirectory: true)
        let path = folder.appendingPathComponent(modelFile)
        if ModelFileValidator.looksLikeGGUF(path),
           await DownloadIntegrity.verifiedExisting(
               at: path, expectedBytes: modelBytes, expectedSHA256: modelSHA256) {
            return path
        }
        DownloadIntegrity.removeFileAndMarker(at: path)
        let stashed = try await ParallelRangeDownloader.download(
            from: URL(string: modelURL)!, session: .shared) { _ in }
        do {
            guard ModelFileValidator.looksLikeGGUF(stashed) else {
                throw TextEngineError.badResponse("embedding model download was not a GGUF model")
            }
            try await DownloadIntegrity.verifyDownloaded(
                at: stashed, expectedBytes: modelBytes, expectedSHA256: modelSHA256)
        } catch {
            DownloadFileRescuer.cleanup(stashed)
            throw error
        }
        try DownloadFileRescuer.install(stashed: stashed, to: path)
        DownloadIntegrity.removeFileAndMarker(at: stashed)
        try DownloadIntegrity.markInstalled(
            at: path, expectedBytes: modelBytes, expectedSHA256: modelSHA256)
        return path
    }

    // MARK: - Plumbing

    private func indexedMtime(_ id: UUID) -> TimeInterval? {
        database?.firstDouble(
            "SELECT source_mtime FROM embedded_meetings WHERE meeting_id = ?1 AND model_id = ?2",
            bind: [id.uuidString, Self.indexVersion])
    }

    private func isDeleted(_ id: UUID) -> Bool {
        if locallyDeletedMeetingIDs.contains(id) { return true }
        guard let database else { return true }
        return (try? database.hasRowChecked(
            "SELECT 1 FROM deleted_meetings WHERE meeting_id = ?1",
            bind: [id.uuidString])) != false
    }

    nonisolated private static func remove(_ meetingID: UUID,
                                           in database: SQLiteDatabase) -> Bool {
        let id = meetingID.uuidString
        let marked = database.transaction {
            database.run(
                "INSERT OR IGNORE INTO deleted_meetings (meeting_id, deleted_at) VALUES (?1, ?2)",
                bind: [id, Date().timeIntervalSince1970])
        }
        guard marked else { return false }
        guard let tables = cleanupTablePresence(in: database) else { return false }
        return database.transaction {
            (!tables.embeddings
             || database.run("DELETE FROM embeddings WHERE meeting_id = ?1", bind: [id]))
                && (!tables.meetings
                    || database.run(
                        "DELETE FROM embedded_meetings WHERE meeting_id = ?1",
                        bind: [id]))
        }
    }

    nonisolated private static func restore(_ meetingID: UUID,
                                            in database: SQLiteDatabase) -> Bool {
        database.transaction {
            database.run(
                "DELETE FROM deleted_meetings WHERE meeting_id = ?1",
                bind: [meetingID.uuidString])
        }
    }

    nonisolated private static func reconcileDeletedMeetings(
        in database: SQLiteDatabase
    ) -> Bool {
        guard let tables = cleanupTablePresence(in: database) else { return false }
        return database.transaction {
            (!tables.embeddings
             || database.run("""
                 DELETE FROM embeddings
                 WHERE meeting_id IN (SELECT meeting_id FROM deleted_meetings)
                 """))
                && (!tables.meetings
                    || database.run("""
                        DELETE FROM embedded_meetings
                        WHERE meeting_id IN (SELECT meeting_id FROM deleted_meetings)
                        """))
        }
    }

    nonisolated private static func cleanupTablePresence(
        in database: SQLiteDatabase
    ) -> (embeddings: Bool, meetings: Bool)? {
        do {
            return (
                try database.hasRowChecked(
                    "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'embeddings'"),
                try database.hasRowChecked(
                    "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'embedded_meetings'")
            )
        } catch {
            return nil
        }
    }
}
