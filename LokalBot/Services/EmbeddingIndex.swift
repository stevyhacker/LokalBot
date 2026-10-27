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

/// Orders requests to the embedder llama-server. It runs `--parallel 1` and
/// encodes inputs first in, first out, so a typed query waits for every input
/// posted before it. Background requests go one at a time and are held while
/// a foreground request is in flight: a query waits for at most the one
/// background request already on the server.
@MainActor
final class EmbeddingRequestGate {
    private var foregroundCount = 0
    private var backgroundRunning = false
    private var backgroundWaiters: [(id: UUID, continuation: CheckedContinuation<Void, Error>)] = []

    func foreground<T>(_ body: () async throws -> T) async rethrows -> T {
        foregroundCount += 1
        defer {
            foregroundCount -= 1
            resumeNextBackground()
        }
        return try await body()
    }

    func background<T>(_ body: () async throws -> T) async throws -> T {
        try await waitForBackgroundTurn()
        defer {
            backgroundRunning = false
            resumeNextBackground()
        }
        return try await body()
    }

    private func waitForBackgroundTurn() async throws {
        if foregroundCount == 0, !backgroundRunning, backgroundWaiters.isEmpty {
            backgroundRunning = true
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                backgroundWaiters.append((id, continuation))
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelBackgroundWaiter(id) }
        }
    }

    private func cancelBackgroundWaiter(_ id: UUID) {
        guard let index = backgroundWaiters.firstIndex(where: { $0.id == id }) else { return }
        backgroundWaiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    private func resumeNextBackground() {
        guard foregroundCount == 0, !backgroundRunning, !backgroundWaiters.isEmpty else { return }
        backgroundRunning = true
        backgroundWaiters.removeFirst().continuation.resume()
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
            // Prefer lexical evidence only for equal fused relevance, never
            // ahead of a higher-ranked semantic-only capture.
            let lhsLexical = lhs.keywordRank != nil
            let rhsLexical = rhs.keywordRank != nil
            if lhsLexical != rhsLexical { return lhsLexical }
            let lhsBest = min(lhs.keywordRank ?? .max, lhs.semanticRank ?? .max)
            let rhsBest = min(rhs.keywordRank ?? .max, rhs.semanticRank ?? .max)
            if lhsBest != rhsBest { return lhsBest < rhsBest }
            return lhs.snapshotID < rhs.snapshotID
        }.prefix(limit).map { $0 }
    }
}

/// M6 semantic layer (design §4.1): transcript/summary chunks embedded with
/// EmbeddingGemma 2 GGUF, served by the second llama-server instance.
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

    /// When background passes over screen text run. Tests shorten these.
    struct ScreenBackfillSchedule: Sendable {
        /// New captures wait this long, so one pass embeds a batch of them
        /// instead of waking the embedder for every capture.
        var newTextDelay: Duration
        /// The wait after the first failed pass. Each further failure doubles
        /// it, up to `maximumRetryDelay`; a successful pass resets it.
        var firstRetryDelay: Duration
        var maximumRetryDelay: Duration

        static let standard = ScreenBackfillSchedule(
            newTextDelay: .seconds(15 * 60),
            firstRetryDelay: .seconds(60),
            maximumRetryDelay: .seconds(30 * 60))

        func retryDelay(afterFailures failures: Int) -> Duration {
            var delay = firstRetryDelay
            for _ in 1..<max(1, failures) {
                delay = delay * 2
                if delay >= maximumRetryDelay { return maximumRetryDelay }
            }
            return min(delay, maximumRetryDelay)
        }
    }

    nonisolated static let modelID = "embeddinggemma-2-q8"
    /// Persisted separately from the server-facing model name. Any change to
    /// pooling, prompting, or chunking must advance this value so vectors made
    /// under incompatible contracts are discarded before search resumes.
    nonisolated static let indexVersion = "embeddinggemma-2-q8-mean-768-v1"
    nonisolated static let modelFile = "embeddinggemma-2-Q8_0.gguf"
    nonisolated private static let modelBytes: Int64 = 309_855_456
    nonisolated private static let modelSHA256 = "2188ac1deca4b77dffefd603c2776a9d76d9d74ec01841392982ebb840b09135"
    nonisolated private static let modelURL =
        "https://huggingface.co/ggml-org/embeddinggemma-2-GGUF/resolve/bfcd298762cc34d0357ece5ebdd31791a3a374d8/embeddinggemma-2-Q8_0.gguf"
    /// Embedders this app shipped before. Their files are deleted, by exact
    /// name, once the current model has been verified.
    nonisolated static let obsoleteModelFiles = [
        "harrier-oss-v1-0.6b.Q8_0.gguf",
        "Qwen3-Embedding-0.6B-Q8_0.gguf",
        "nomic-embed-text-v1.5.Q8_0.gguf",
    ]
    /// The checkpoint's own retrieval prompts (`SearchQuery` and `Document`).
    /// Meetings and screens share them; the stored text says which it is.
    nonisolated static let documentPrefix = "title: none | text: "
    nonisolated static let queryPrefix = "task: search result | query: "
    private static let screenDocumentPrefix = documentPrefix
    private static let screenQueryPrefix = queryPrefix
    /// EmbeddingGemma 2 scores unrelated text higher than Harrier did: on a
    /// real library, unrelated meeting chunks had a median of 0.59 and
    /// unrelated screens 0.61. These floors pass the same share of unrelated
    /// pairs as Harrier's 0.45 (32% of meeting chunks, 76% of screens) while
    /// keeping 99.7% and 100% of the passages the queries were written from.
    /// Recalibrate whenever the embedding model changes.
    nonisolated static let meetingSimilarityFloor: Float = 0.61
    nonisolated static let screenSimilarityFloor: Float = 0.58
    nonisolated static let transcriptChunkTargetCharacters = 500
    /// Preserve the existing chunk shape for normal ASR output while keeping a
    /// single pathological segment safely below the embedder's 2K context.
    nonisolated static let transcriptChunkHardLimitCharacters = 1_800
    /// Limits for one background embedding request, so a typed query waits
    /// for at most about 100 ms (M4 Max): a 1,500-character OCR row is about
    /// 900 tokens and 50 ms, a 500-character transcript chunk about 11 ms.
    /// Splitting costs almost nothing (each input is encoded on its own) and
    /// does not change the vectors.
    nonisolated static let backgroundRequestMaximumInputs = 8
    nonisolated static let backgroundRequestMaximumCharacters = 2_000
    private static let modelPreparation = EmbeddingModelPreparationCoordinator()

    private let database: SQLiteDatabase?
    private let storage: StorageManager
    private var locallyDeletedMeetingIDs: Set<UUID> = []
    private var screenReindexFlight: (id: UUID, task: Task<Void, Never>)?
    /// The next automatic pass, set by new screen text or a failed pass.
    private var scheduledScreenReindex: (id: UUID, task: Task<Void, Never>)?
    private let screenBackfillSchedule: ScreenBackfillSchedule
    /// Failed passes since the last one that finished; sets the retry delay.
    private(set) var screenReindexFailures = 0
    /// Set once this library has searched screens by meaning. Until then new
    /// captures are not embedded, so people who never use the feature do not
    /// download a model or spend background inference time on it.
    private var screenSearchInUse = false
    /// Startup discarded screen vectors an earlier model made. This library
    /// already used semantic screen search, so they are rebuilt after the
    /// meetings instead of waiting for a search.
    private(set) var screenVectorsNeedRebuild = false
    /// Ask and Quick Recall search meetings and then screens with the same
    /// query, and search again when only a filter or a trailing space changes.
    /// The model is fixed for an index version, so the last vector stays valid.
    private var lastQueryEmbedding: (input: String, vector: [Float])?

    /// Turns texts into vectors. The app sends them to the embedder
    /// llama-server; tests pass a recorder instead.
    typealias Embedder = @MainActor (
        _ texts: [String], _ prefix: String, _ priority: InferencePriority
    ) async throws -> [[Float]]
    private let embedder: Embedder
    private let requestGate = EmbeddingRequestGate()

    private let databaseURL: URL

    init(databaseURL: URL, storage: StorageManager, embedder: Embedder? = nil,
         screenBackfillSchedule: ScreenBackfillSchedule = .standard) {
        self.databaseURL = databaseURL
        self.storage = storage
        self.screenBackfillSchedule = screenBackfillSchedule
        self.embedder = embedder ?? { texts, prefix, priority in
            try await Self.embed(texts, prefix: prefix, priority: priority, storage: storage)
        }
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
                screenVectorsNeedRebuild = database.hasRow(
                    "SELECT 1 FROM screen_embeddings WHERE model_id != ?1 LIMIT 1",
                    bind: [Self.indexVersion])
                database.run(
                    "DELETE FROM screen_embeddings WHERE model_id != ?1",
                    bind: [Self.indexVersion])
            }
        }
        _ = reconcileDeletedMeetings()
    }

    // MARK: - Indexing

    /// Re-embeds meetings whose sources changed. `progress` receives
    /// `(done, total)` over only the meetings that need work, starting at
    /// `(0, total)` when any do, so an up-to-date library reports nothing.
    func reindexAll(
        _ meetings: [Meeting],
        progress: ((_ done: Int, _ total: Int) -> Void)? = nil
    ) async {
        let pending = meetings.filter { pendingIndexState(for: $0) != nil }
        guard !pending.isEmpty else { return }
        progress?(0, pending.count)
        for (offset, meeting) in pending.enumerated() {
            guard !Task.isCancelled else { return }
            try? await index(meeting)
            progress?(offset + 1, pending.count)
        }
    }

    /// Prefix that identifies a semantic chunk taken from the user's own
    /// meeting notes, so a hit can be mapped back to its notes passage.
    nonisolated static let notesChunkMarker = "My meeting notes: "

    nonisolated static func notesChunks(_ notes: String) -> [(start: TimeInterval, text: String)] {
        splitEmbeddingText(notes, maximumCharacters: 700).map { (start: 0, text: notesChunkMarker + $0) }
    }

    private func hasNotesChunks(_ meetingID: UUID) -> Bool {
        database?.hasRow(
            "SELECT 1 FROM embeddings WHERE meeting_id = ?1 AND substr(text, 1, ?2) = ?3 LIMIT 1",
            bind: [meetingID.uuidString, Self.notesChunkMarker.count, Self.notesChunkMarker]) ?? false
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

    /// Sources of a meeting whose vectors are missing or stale; nil when
    /// `index(_:)` has nothing to do.
    private func pendingIndexState(
        for meeting: Meeting
    ) -> (folder: URL, mtime: TimeInterval, notes: String?, hasNotesVectors: Bool)? {
        guard !isDeleted(meeting.id) else { return nil }
        let folder = meeting.folderURL(in: storage)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        let mtime = ["transcript.json", "summary.md", MeetingNotes.fileName].compactMap {
            (try? FileManager.default.attributesOfItem(
                atPath: folder.appendingPathComponent($0).path))?[.modificationDate] as? Date
        }.map(\.timeIntervalSince1970).max() ?? 0
        let notes = MeetingNotes.load(from: folder)
        // Notes joined the semantic corpus after libraries were embedded, and
        // clearing notes deletes the file without raising the newest mtime.
        // Either way, notes present on only one side force a fresh embedding.
        let hasNotesVectors = hasNotesChunks(meeting.id)
        let notesChanged = (notes != nil) != hasNotesVectors
        guard mtime > 0 || hasNotesVectors,
              (indexedMtime(meeting.id) ?? -1 < mtime) || notesChanged else { return nil }
        return (folder, mtime, notes, hasNotesVectors)
    }

    func index(_ meeting: Meeting) async throws {
        guard let state = pendingIndexState(for: meeting) else { return }
        let (folder, mtime, notes, hasNotesVectors) = state

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
        if let notes { chunks.append(contentsOf: Self.notesChunks(notes)) }
        guard !chunks.isEmpty else {
            // Nothing left to embed; drop vectors of the removed notes.
            if hasNotesVectors, let database {
                _ = database.transaction {
                    database.run("DELETE FROM embeddings WHERE meeting_id = ?1", bind: [meeting.id.uuidString])
                        && database.run("DELETE FROM embedded_meetings WHERE meeting_id = ?1",
                                        bind: [meeting.id.uuidString])
                }
            }
            return
        }

        let vectors = try await embedInBackground(chunks.map(\.text), prefix: Self.documentPrefix)
        try Task.checkCancellation()
        let rows = zip(chunks, vectors).map { chunk, vector in
            let vectorData = vector.withUnsafeBufferPointer { buffer -> Data in
                guard let baseAddress = buffer.baseAddress else { return Data() }
                return Data(bytes: baseAddress, count: buffer.count * MemoryLayout<Float>.stride)
            }
            return (start: chunk.start, text: chunk.text, vectorData: vectorData)
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
                    """, bind: [meetingID, Self.indexVersion]), indexed >= mtime,
                   (notes != nil) == hasNotesChunks(meeting.id) {
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

    func noteRestoration(_ meetingID: UUID) {
        locallyDeletedMeetingIDs.remove(meetingID)
    }

    /// Drops a live meeting's vectors so the next pass re-embeds its changed
    /// sources. Unlike `remove`, it writes no deletion tombstone: tombstones
    /// are shared with keyword search and would hide the meeting from both.
    @discardableResult
    func clearVectors(for meetingID: UUID) -> Bool {
        guard let database else { return false }
        let id = meetingID.uuidString
        return database.transaction {
            database.run("DELETE FROM embeddings WHERE meeting_id = ?1", bind: [id])
                && database.run("DELETE FROM embedded_meetings WHERE meeting_id = ?1", bind: [id])
        }
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
                  SELECT 1 FROM ocr_metadata AS ocr
                  WHERE ocr.snapshot_id = embedded.snapshot_id
              )
            LIMIT 1
            """, bind: [Self.indexVersion])
    }

    /// Called once the meetings are indexed at launch. Rebuilds screen vectors
    /// a model change discarded; otherwise schedules a pass for captures made
    /// before launch or left behind by passes that failed.
    func resumeScreenBackfill() async {
        if screenVectorsNeedRebuild {
            screenVectorsNeedRebuild = false
            screenSearchInUse = true
            await reindexScreenText()
        } else {
            screenTextDidArrive()
        }
    }

    /// New screen text was stored. Libraries that search screens by meaning
    /// get it embedded by a batched background pass instead of waiting for
    /// the next search; a pass already scheduled covers it too.
    func screenTextDidArrive() {
        guard scheduledScreenReindex == nil else { return }
        if !screenSearchInUse { screenSearchInUse = hasScreenEmbeddings }
        guard screenSearchInUse else { return }
        scheduleScreenTextReindex(after: screenBackfillSchedule.newTextDelay)
    }

    /// Cancels the scheduled and running passes, for example when semantic
    /// search is turned off. Rows already embedded stay.
    func stopScreenBackfill() {
        scheduledScreenReindex?.task.cancel()
        scheduledScreenReindex = nil
        screenReindexFlight?.task.cancel()
        screenReindexFailures = 0
    }

    private func scheduleScreenTextReindex(after delay: Duration) {
        scheduledScreenReindex?.task.cancel()
        let id = UUID()
        let task = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self,
                  self.scheduledScreenReindex?.id == id else { return }
            self.scheduledScreenReindex = nil
            await self.reindexScreenText()
        }
        scheduledScreenReindex = (id, task)
    }

    /// Backfills immutable OCR rows that do not yet have a vector. Semantic
    /// screen search starts a pass, new captures schedule one
    /// (`screenTextDidArrive`), and a failed pass schedules a retry with
    /// exponential backoff, so a temporary embedder failure never leaves new
    /// screens out of semantic search until someone happens to search again.
    func reindexScreenText() async {
        if let flight = screenReindexFlight {
            await flight.task.value
            return
        }
        // This pass covers every pending row, so it replaces a scheduled one.
        scheduledScreenReindex?.task.cancel()
        scheduledScreenReindex = nil
        let id = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            let outcome = await self.performScreenTextReindex()
            self.screenTextReindexDidFinish(outcome)
        }
        screenReindexFlight = (id, task)
        await task.value
        if screenReindexFlight?.id == id {
            screenReindexFlight = nil
        }
    }

    private enum ScreenReindexOutcome {
        case finished
        case cancelled
        case failed(Error)
    }

    private func screenTextReindexDidFinish(_ outcome: ScreenReindexOutcome) {
        switch outcome {
        case .finished:
            if screenReindexFailures > 0 {
                lokalbotLog("screen embedding backfill recovered after \(screenReindexFailures) failed passes")
            }
            screenReindexFailures = 0
        case .cancelled:
            break
        case .failed(let error):
            screenReindexFailures += 1
            let delay = screenBackfillSchedule.retryDelay(afterFailures: screenReindexFailures)
            lokalbotLog("screen embedding backfill failed: \(error.localizedDescription); "
                        + "retrying in \(Int(delay.components.seconds)) s")
            scheduleScreenTextReindex(after: delay)
        }
    }

    private func performScreenTextReindex() async -> ScreenReindexOutcome {
        guard let database,
              database.hasRow("""
                SELECT 1 FROM sqlite_master
                WHERE type = 'table' AND name = 'ocr_fts'
                """),
              database.hasRow("""
                SELECT 1 FROM sqlite_master
                WHERE type = 'table' AND name = 'screenshots'
                """) else { return .finished }

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
            guard !batch.isEmpty else { return .finished }
            guard !Task.isCancelled else { return .cancelled }
            do {
                let vectors = try await embedInBackground(
                    batch.map(\.text), prefix: Self.screenDocumentPrefix)
                try Task.checkCancellation()
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
            } catch {
                // Only this pass's own cancellation ends it quietly; anything
                // else, including a stray CancellationError, is retried.
                return Task.isCancelled ? .cancelled : .failed(error)
            }
        }
        return .cancelled
    }

    /// Semantic retrieval over screen OCR, with the same date/app filter
    /// contract as lexical FTS. Results retain the snapshot ID needed for an
    /// exact citation, thumbnail, saved moment, or timeline jump.
    func searchScreen(
        _ query: String,
        filter: ScreenSearchFilter = .all,
        limit: Int = 10,
        priority: InferencePriority = .background
    ) async -> [ScreenHit] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard limit > 0, !trimmed.isEmpty, let database else { return [] }
        screenSearchInUse = true
        // Backfill is single-flight and independent of this interactive query.
        if screenReindexFlight == nil {
            Task { [weak self] in await self?.reindexScreenText() }
        }
        guard !Task.isCancelled, hasScreenEmbeddings,
              let queryVector = await embedQuery(
                trimmed, prefix: Self.screenQueryPrefix, priority: priority)
        else { return [] }

        let url = databaseURL
        let worker = Task.detached(priority: .userInitiated) {
            guard !Task.isCancelled, let database = SQLiteDatabase(url: url, readOnly: true) else { return [ScreenHit]() }
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
                      SELECT 1 FROM ocr_metadata AS ocr
                      WHERE ocr.snapshot_id = embedded.snapshot_id
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
            return Self.rankScreen(candidates, against: queryVector, limit: limit)
        }
        let ranked = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
        guard !Task.isCancelled else { return [] }
        return ranked.filter { hit in
            database.hasRow(
                """
                SELECT 1 FROM screenshots AS shot JOIN ocr_metadata AS meta ON meta.snapshot_id = shot.id
                JOIN ocr_fts AS ocr ON ocr.rowid = meta.rowid
                WHERE shot.id = ?1
                """,
                bind: [hit.snapshotID])
        }
    }

    func search(_ query: String, limit: Int = 10,
                meetingIDs: Set<UUID>? = nil,
                priority: InferencePriority = .background) async -> [Hit] {
        // Trimmed like screen search, so both sources share one query vector.
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard limit > 0, !trimmed.isEmpty, database != nil, hasEmbeddings else { return [] }
        if let meetingIDs, meetingIDs.isEmpty { return [] }
        guard let queryVector = await embedQuery(
            trimmed, prefix: Self.queryPrefix, priority: priority) else { return [] }
        let url = databaseURL
        let worker = Task.detached(priority: .userInitiated) {
            guard !Task.isCancelled, let database = SQLiteDatabase(url: url, readOnly: true) else { return [Hit]() }
            var bindings: [Any] = [Self.indexVersion]
            let scope: String
            if let meetingIDs {
                let parameters = meetingIDs.sorted { $0.uuidString < $1.uuidString }.map { id -> String in
                    bindings.append(id.uuidString)
                    return "?\(bindings.count)"
                }
                scope = "embedded.meeting_id IN (\(parameters.joined(separator: ",")))"
            } else { scope = "1 = 1" }
            let candidates: [Candidate] = database.query(
                """
                SELECT embedded.meeting_id, embedded.start, embedded.text, embedded.vec
                FROM embeddings AS embedded
                WHERE \(scope) AND EXISTS (
                    SELECT 1 FROM embedded_meetings AS indexed
                    WHERE indexed.meeting_id = embedded.meeting_id
                      AND indexed.model_id = ?1
                )
                  AND NOT EXISTS (
                    SELECT 1 FROM deleted_meetings AS deleted
                    WHERE deleted.meeting_id = embedded.meeting_id
                )
                """, bind: bindings
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
            return Self.rank(candidates, against: queryVector, limit: limit)
        }
        let ranked = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
        guard !Task.isCancelled else { return [] }
        // Ranking yields the main actor. A meeting can be deleted after the
        // candidate snapshot but before ranking completes, so validate again
        // synchronously before publishing any hit.
        return liveHits(from: ranked)
    }

    func liveHits(from hits: [Hit]) -> [Hit] {
        hits.filter { !isDeleted($0.meetingID) }
    }

    struct Candidate: Sendable {
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
    nonisolated static func rank(
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
            guard score > meetingSimilarityFloor else { continue }
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
            guard score > screenSimilarityFloor else { continue }
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

    /// The checkpoint's symmetric prompt, for comparing two statements
    /// rather than ranking documents against a query.
    nonisolated static let similarityPrefix = "task: sentence similarity | query: "

    /// L2-normalized vectors for a one-off comparison, such as checking that
    /// a learned item means what the person's line says. Waits behind typed
    /// searches. Nil when the embedding model isn't on this Mac (this never
    /// starts a download) or the request fails.
    func similarityVectors(_ texts: [String]) async -> [[Float]]? {
        guard !texts.isEmpty else { return [] }
        let model = storage.rootURL.appendingPathComponent("models/\(Self.modelFile)")
        guard FileManager.default.fileExists(atPath: model.path),
              let vectors = try? await embedThroughGate(texts, prefix: Self.similarityPrefix, priority: .background),
              vectors.count == texts.count else { return nil }
        return vectors
    }

    /// A failed or cancelled embedding is not kept, so the next search retries.
    private func embedQuery(_ query: String, prefix: String,
                            priority: InferencePriority) async -> [Float]? {
        let input = prefix + query
        if let last = lastQueryEmbedding, last.input == input { return last.vector }
        guard let vector = try? await embedThroughGate([query], prefix: prefix, priority: priority).first
        else { return nil }
        lastQueryEmbedding = (input, vector)
        return vector
    }

    /// Embeds documents for indexing in small requests, returning one vector
    /// per text in input order.
    private func embedInBackground(_ texts: [String], prefix: String) async throws -> [[Float]] {
        var vectors: [[Float]] = []
        vectors.reserveCapacity(texts.count)
        for range in Self.backgroundRequestRanges(texts) {
            try Task.checkCancellation()
            let part = Array(texts[range])
            let partVectors = try await embedThroughGate(part, prefix: prefix, priority: .background)
            guard partVectors.count == part.count else {
                throw TextEngineError.badResponse(
                    "embedding response contained \(partVectors.count) vectors for \(part.count) texts")
            }
            vectors += partVectors
        }
        return vectors
    }

    /// Background work waits its turn; anything a person or an agent waits
    /// for goes straight to the server and holds background work back.
    private func embedThroughGate(_ texts: [String], prefix: String,
                                  priority: InferencePriority) async throws -> [[Float]] {
        if priority == .background {
            return try await requestGate.background { try await embedder(texts, prefix, priority) }
        }
        return try await requestGate.foreground { try await embedder(texts, prefix, priority) }
    }

    /// Consecutive runs of texts within the background request limits. A text
    /// longer than the character limit goes alone.
    nonisolated static func backgroundRequestRanges(_ texts: [String]) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var start = 0
        var characters = 0
        for (index, text) in texts.enumerated() {
            let count = text.count
            if index > start,
               index - start == backgroundRequestMaximumInputs
                || characters + count > backgroundRequestMaximumCharacters {
                ranges.append(start..<index)
                start = index
                characters = 0
            }
            characters += count
        }
        if start < texts.count { ranges.append(start..<texts.count) }
        return ranges
    }

    private static func embed(_ texts: [String], prefix: String, priority: InferencePriority,
                              storage: StorageManager) async throws -> [[Float]] {
        let modelPath = try await ensureModel(storage: storage)
        return try await InferenceBroker.shared.withLease(
            .embedder, model: modelPath, priority: priority,
            purpose: "embeddings") { () async throws -> [[Float]] in
            var request = URLRequest(url: LlamaServer.embedder.baseURL
                .appendingPathComponent("embeddings"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let authenticationToken = await LlamaServer.embedder.authenticationToken()
            request.setValue("Bearer \(authenticationToken)", forHTTPHeaderField: "Authorization")
            request.timeoutInterval = 120
            request.httpBody = try JSONSerialization.data(
                withJSONObject: embeddingRequestBody(texts, prefix: prefix))
            let (data, _) = try await URLSession.shared.data(for: request)
            return try embeddingVectors(fromResponse: data)
        }
    }

    /// EmbeddingGemma is a bidirectional encoder: every token attends to the
    /// whole input, so reusing another input's cached prompt prefix would be
    /// wrong. The bundled llama.cpp already re-encodes each input (vectors were
    /// identical with caching on); turning it off keeps that independent of
    /// server defaults.
    nonisolated static func embeddingRequestBody(_ texts: [String], prefix: String) -> [String: Any] {
        [
            "input": texts.map { prefix + $0 },
            "model": modelID,
            "cache_prompt": false,
        ]
    }

    /// Returns one L2-normalized vector per input, in input order. Rows are
    /// ordered by their `index` rather than trusting the response order.
    nonisolated static func embeddingVectors(fromResponse data: Data) throws -> [[Float]] {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = json["data"] as? [[String: Any]] else {
            throw TextEngineError.badResponse("unexpected /v1/embeddings payload")
        }
        var ordered: [(index: Int, row: [String: Any])] = []
        for (offset, row) in rows.enumerated() {
            let index = row["index"] as? Int ?? offset
            ordered.append((index, row))
        }
        ordered.sort { $0.index < $1.index }
        return ordered.compactMap { entry -> [Float]? in
            guard let values = entry.row["embedding"] as? [Double] else { return nil }
            let vector = values.map(Float.init)
            let norm = sqrt(vector.reduce(0) { $0 + $1 * $1 })
            return norm > 0 ? vector.map { $0 / norm } : vector
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
            removeObsoleteModels(in: folder)
            return path
        }
        DownloadIntegrity.removeFileAndMarker(at: path)
        let stashed = try await ModelDownloadRouting.download(
            from: URL(string: modelURL)!, session: .shared,
            expectedSHA256: modelSHA256, expectedBytes: modelBytes) { _ in }
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
        removeObsoleteModels(in: folder)
        return path
    }

    /// Previous embedders are never loaded again, and nothing else references
    /// their files. Delete only those exact names, and only after the current
    /// model verified, so a failed download never leaves search without one.
    nonisolated static func removeObsoleteModels(in folder: URL) {
        for name in obsoleteModelFiles where name != modelFile {
            DownloadIntegrity.removeFileAndMarker(at: folder.appendingPathComponent(name))
        }
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
