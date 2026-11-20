import Accelerate
import Foundation
import SQLite3

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

    struct ScreenBackfillSchedule: Sendable {
        var newTextDelay: Duration
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
    nonisolated static let indexVersion = "embeddinggemma-2-q8-mean-768-v1"
    nonisolated static let modelFile = "embeddinggemma-2-Q8_0.gguf"
    nonisolated private static let modelBytes: Int64 = 309_855_456
    nonisolated private static let modelSHA256 = "2188ac1deca4b77dffefd603c2776a9d76d9d74ec01841392982ebb840b09135"
    nonisolated private static let modelURL =
        "https://huggingface.co/ggml-org/embeddinggemma-2-GGUF/resolve/bfcd298762cc34d0357ece5ebdd31791a3a374d8/embeddinggemma-2-Q8_0.gguf"
    nonisolated static let obsoleteModelFiles = [
        "harrier-oss-v1-0.6b.Q8_0.gguf",
        "Qwen3-Embedding-0.6B-Q8_0.gguf",
        "nomic-embed-text-v1.5.Q8_0.gguf",
    ]
    nonisolated static let documentPrefix = "title: none | text: "
    nonisolated static let queryPrefix = "task: search result | query: "
    private static let screenDocumentPrefix = documentPrefix
    private static let screenQueryPrefix = queryPrefix
    nonisolated static let meetingSimilarityFloor: Float = 0.61
    nonisolated static let screenSimilarityFloor: Float = 0.58
    nonisolated static let transcriptChunkTargetCharacters = 500
    nonisolated static let transcriptChunkHardLimitCharacters = 1_800
    nonisolated static let backgroundRequestMaximumInputs = 8
    nonisolated static let backgroundRequestMaximumCharacters = 2_000
    private static let modelPreparation = EmbeddingModelPreparationCoordinator()

    private let database: SQLiteDatabase?
    private let storage: StorageManager
    private var locallyDeletedMeetingIDs: Set<UUID> = []
    private var screenReindexFlight: (id: UUID, task: Task<Void, Never>)?
    private var scheduledScreenReindex: (id: UUID, task: Task<Void, Never>)?
    private let screenBackfillSchedule: ScreenBackfillSchedule
    private(set) var screenReindexFailures = 0
    private var screenSearchInUse = false
    private(set) var screenVectorsNeedRebuild = false
    private var lastQueryEmbedding: (input: String, vector: [Float])?
    var screenSearchByMeaningDidStart: (() -> Void)?

    typealias Embedder = @MainActor (
        _ texts: [String], _ prefix: String, _ priority: InferencePriority
    ) async throws -> [[Float]]
    private let embedder: Embedder
    private let requestGate = EmbeddingRequestGate()

    static let unavailableEmbedder: Embedder = { _, _, _ in
        throw TextEngineError.unavailable("The embedding model is not available.")
    }

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
            CREATE INDEX IF NOT EXISTS idx_screen_embeddings_model
                ON screen_embeddings(model_id);
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
                    "SELECT 1 FROM screen_embeddings WHERE model_id < ?1 OR model_id > ?1 LIMIT 1",
                    bind: [Self.indexVersion])
                if screenVectorsNeedRebuild {
                    database.run(
                        "DELETE FROM screen_embeddings WHERE model_id < ?1 OR model_id > ?1",
                        bind: [Self.indexVersion])
                }
            }
        }
        _ = reconcileDeletedMeetings()
    }

    func reindexAll(
        _ meetings: [Meeting],
        progress: ((_ done: Int, _ total: Int) -> Void)? = nil
    ) async {
        let pending = await meetingsNeedingVectors(meetings)
        guard !pending.isEmpty else { return }
        progress?(0, pending.count)
        for (offset, meeting) in pending.enumerated() {
            guard !Task.isCancelled else { return }
            try? await index(meeting)
            progress?(offset + 1, pending.count)
        }
    }

    nonisolated static let notesChunkMarker = "My meeting notes: "

    nonisolated static func notesChunks(_ notes: String) -> [(start: TimeInterval, text: String)] {
        splitEmbeddingText(notes, maximumCharacters: 700).map { (start: 0, text: notesChunkMarker + $0) }
    }

    private func hasNotesChunks(_ meetingID: UUID) -> Bool {
        database?.hasRow(
            "SELECT 1 FROM embeddings WHERE meeting_id = ?1 AND substr(text, 1, ?2) = ?3 LIMIT 1",
            bind: [meetingID.uuidString, Self.notesChunkMarker.count, Self.notesChunkMarker]) ?? false
    }

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

    private func pendingIndexState(
        for meeting: Meeting
    ) -> (folder: URL, mtime: TimeInterval, notes: String?, hasNotesVectors: Bool)? {
        guard !isDeleted(meeting.id) else { return nil }
        let folder = meeting.folderURL(in: storage)
        guard Self.isFolder(folder) else { return nil }
        let mtime = Self.sourceMtime(in: folder)
        let notes = MeetingNotes.load(from: folder)
        let hasNotesVectors = hasNotesChunks(meeting.id)
        guard Self.needsVectors(mtime: mtime, indexedMtime: indexedMtime(meeting.id),
                                hasNotes: notes != nil, hasNotesVectors: hasNotesVectors) else { return nil }
        return (folder, mtime, notes, hasNotesVectors)
    }

    private func meetingsNeedingVectors(_ meetings: [Meeting]) async -> [Meeting] {
        guard database != nil, !meetings.isEmpty else { return [] }
        let sources = meetings.map { MeetingSource(id: $0.id, folder: $0.folderURL(in: storage)) }
        let url = databaseURL
        let worker = Task.detached(priority: .utility) { () -> Set<UUID>? in
            guard !Task.isCancelled, let database = SQLiteDatabase(url: url, readOnly: true) else { return nil }
            return Self.meetingIDsNeedingVectors(sources, in: database)
        }
        let candidates = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
        guard !Task.isCancelled else { return [] }
        return meetings.filter {
            (candidates?.contains($0.id) ?? true) && pendingIndexState(for: $0) != nil
        }
    }

    struct MeetingSource: Sendable {
        let id: UUID
        let folder: URL
    }

    nonisolated static func meetingIDsNeedingVectors(
        _ sources: [MeetingSource], in database: SQLiteDatabase
    ) -> Set<UUID> {
        let deleted = Set(database.query("SELECT meeting_id FROM deleted_meetings") { statement in
            sqlite3_column_text(statement, 0).map { String(cString: $0) }
        })
        let indexedRows: [(String, TimeInterval)] = database.query(
            "SELECT meeting_id, source_mtime FROM embedded_meetings WHERE model_id = ?1",
            bind: [indexVersion]
        ) { statement in
            sqlite3_column_text(statement, 0).map { (String(cString: $0), sqlite3_column_double(statement, 1)) }
        }
        let indexed = Dictionary(indexedRows, uniquingKeysWith: { first, _ in first })
        let withNotesVectors = Set(database.query(
            "SELECT DISTINCT meeting_id FROM embeddings WHERE substr(text, 1, ?1) = ?2",
            bind: [notesChunkMarker.count, notesChunkMarker]
        ) { statement in
            sqlite3_column_text(statement, 0).map { String(cString: $0) }
        })
        var needed = Set<UUID>()
        for source in sources {
            guard !Task.isCancelled else { break }
            let id = source.id.uuidString
            guard !deleted.contains(id), isFolder(source.folder) else { continue }
            if needsVectors(mtime: sourceMtime(in: source.folder), indexedMtime: indexed[id],
                            hasNotes: MeetingNotes.load(from: source.folder) != nil,
                            hasNotesVectors: withNotesVectors.contains(id)) {
                needed.insert(source.id)
            }
        }
        return needed
    }

    nonisolated private static func isFolder(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    nonisolated private static func sourceMtime(in folder: URL) -> TimeInterval {
        ["transcript.json", "summary.md", MeetingNotes.fileName].compactMap {
            (try? FileManager.default.attributesOfItem(
                atPath: folder.appendingPathComponent($0).path))?[.modificationDate] as? Date
        }.map(\.timeIntervalSince1970).max() ?? 0
    }

    nonisolated private static func needsVectors(
        mtime: TimeInterval, indexedMtime: TimeInterval?, hasNotes: Bool, hasNotesVectors: Bool
    ) -> Bool {
        let notesChanged = hasNotes != hasNotesVectors
        return (mtime > 0 || hasNotesVectors) && ((indexedMtime ?? -1) < mtime || notesChanged)
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

    func noteDeletion(_ meetingID: UUID) {
        locallyDeletedMeetingIDs.insert(meetingID)
    }

    func noteRestoration(_ meetingID: UUID) {
        locallyDeletedMeetingIDs.remove(meetingID)
    }

    @discardableResult
    func clearVectors(for meetingID: UUID) -> Bool {
        guard let database else { return false }
        let id = meetingID.uuidString
        return database.transaction {
            database.run("DELETE FROM embeddings WHERE meeting_id = ?1", bind: [id])
                && database.run("DELETE FROM embedded_meetings WHERE meeting_id = ?1", bind: [id])
        }
    }

    @discardableResult
    nonisolated static func remove(_ meetingID: UUID, databaseURL: URL) -> Bool {
        guard let database = SQLiteDatabase(url: databaseURL) else { return false }
        return remove(meetingID, in: database)
    }

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

    func resumeScreenBackfill() async {
        if screenVectorsNeedRebuild {
            screenVectorsNeedRebuild = false
            screenSearchInUse = true
            await reindexScreenText()
        } else {
            screenTextDidArrive()
        }
    }

    func screenTextDidArrive() {
        guard scheduledScreenReindex == nil else { return }
        if !screenSearchInUse { screenSearchInUse = hasScreenEmbeddings }
        guard screenSearchInUse else { return }
        scheduleScreenTextReindex(after: screenBackfillSchedule.newTextDelay)
    }

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

    func reindexScreenText() async {
        if let flight = screenReindexFlight {
            await flight.task.value
            return
        }
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
                return Task.isCancelled ? .cancelled : .failed(error)
            }
        }
        return .cancelled
    }

    func searchScreen(
        _ query: String,
        filter: ScreenSearchFilter = .all,
        limit: Int = 10,
        priority: InferencePriority = .background
    ) async -> [ScreenHit] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard limit > 0, !trimmed.isEmpty, let database else { return [] }
        screenSearchInUse = true
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
            return Self.screenHits(in: database, filter: filter, queryVector: queryVector, limit: limit)
        }
        let ranked = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
        guard !Task.isCancelled else { return [] }
        return Self.liveScreenHits(ranked, in: database)
    }

    nonisolated static func liveScreenHits(_ hits: [ScreenHit], in database: SQLiteDatabase) -> [ScreenHit] {
        guard !hits.isEmpty else { return [] }
        let placeholders = hits.indices.map { "?\($0 + 1)" }.joined(separator: ",")
        let live = Set(database.query(
            """
            SELECT shot.id FROM screenshots AS shot JOIN ocr_metadata AS meta ON meta.snapshot_id = shot.id
            JOIN ocr_fts AS ocr ON ocr.rowid = meta.rowid
            WHERE shot.id IN (\(placeholders))
            """,
            bind: hits.map(\.snapshotID)) { sqlite3_column_int64($0, 0) })
        return hits.filter { live.contains($0.snapshotID) }
    }

    struct ScreenMeaningMatch: Sendable {
        let meaning: ScreenSearchRanking.Meaning
        let ts: Date
        let app: String
    }

    var isScreenSearchInUse: Bool { screenSearchInUse || hasScreenEmbeddings }

    func screenMeanings(
        _ query: String,
        filter: ScreenSearchFilter = .all,
        priority: InferencePriority = .background
    ) async -> [Int64: ScreenMeaningMatch] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, database != nil else { return [:] }
        if let ids = filter.snapshotIDs, ids.isEmpty { return [:] }
        screenSearchInUse = true
        if screenReindexFlight == nil {
            Task { [weak self] in await self?.reindexScreenText() }
        }
        screenSearchByMeaningDidStart?()
        guard !Task.isCancelled,
              let queryVector = await embedQuery(trimmed, prefix: Self.screenQueryPrefix, priority: priority)
        else { return [:] }
        let url = databaseURL
        let worker = Task.detached(priority: .userInitiated) { () -> [Int64: ScreenMeaningMatch] in
            guard !Task.isCancelled, let database = SQLiteDatabase(url: url, readOnly: true) else { return [:] }
            return Self.screenMeanings(database: database, queryVector: queryVector, filter: filter)
        }
        return await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
    }

    nonisolated static func screenMeanings(
        database: SQLiteDatabase, queryVector: [Float], filter: ScreenSearchFilter
    ) -> [Int64: ScreenMeaningMatch] {
        struct Row {
            let snapshotID: Int64
            let ts: Date
            let app: String
            let modality: ScreenSearchRanking.Modality
            let cosine: Float
        }
        var scorer = VectorScorer(queryVector)
        let byteCount = scorer.byteCount
        func read(_ statement: OpaquePointer, modality: ScreenSearchRanking.Modality) -> Row? {
            guard let app = sqlite3_column_text(statement, 2),
                  let blob = sqlite3_column_blob(statement, 3),
                  Int(sqlite3_column_bytes(statement, 3)) == byteCount else { return nil }
            return Row(snapshotID: sqlite3_column_int64(statement, 0),
                       ts: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                       app: String(cString: app), modality: modality,
                       cosine: scorer.score(blob))
        }
        var rows: [Row] = database.query("""
            SELECT embedded.snapshot_id, shot.ts, shot.app, embedded.vec
            FROM screen_embeddings AS embedded
            JOIN screenshots AS shot ON shot.id = embedded.snapshot_id
            WHERE embedded.model_id = ?1
              AND EXISTS (SELECT 1 FROM ocr_metadata AS ocr WHERE ocr.snapshot_id = embedded.snapshot_id)
            """, bind: [indexVersion]) { read($0, modality: .text) }
        if database.hasRow("""
            SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'screen_image_embeddings'
            """) {
            rows += database.query("""
                SELECT embedded.snapshot_id, shot.ts, shot.app, embedded.vec
                FROM screen_image_embeddings AS embedded
                JOIN screenshots AS shot ON shot.id = embedded.snapshot_id
                WHERE embedded.model_id = ?1 AND shot.path != ''
                """, bind: [ScreenImageEmbeddings.modelID]) { read($0, modality: .image) }
        }
        let meanings = ScreenSearchRanking.meaning(rows.map {
            ScreenSearchRanking.Score(snapshotID: $0.snapshotID, modality: $0.modality, cosine: $0.cosine)
        })
        var places: [Int64: (ts: Date, app: String)] = [:]
        for row in rows {
            places[row.snapshotID] = (row.ts, row.app)
        }
        var matches: [Int64: ScreenMeaningMatch] = [:]
        for (id, meaning) in meanings {
            guard let place = places[id] else { continue }
            if let ids = filter.snapshotIDs, !ids.contains(id) { continue }
            if let interval = filter.interval, !(place.ts >= interval.start && place.ts < interval.end) { continue }
            if let app = filter.app, app.caseInsensitiveCompare(place.app) != .orderedSame { continue }
            matches[id] = ScreenMeaningMatch(meaning: meaning, ts: place.ts, app: place.app)
        }
        return matches
    }

    nonisolated static func screenTexts(_ ids: [Int64], in database: SQLiteDatabase) -> [Int64: String] {
        let wanted = Array(Set(ids))
        var texts: [Int64: String] = [:]
        for start in stride(from: 0, to: wanted.count, by: 400) {
            let chunk = Array(wanted[start..<min(start + 400, wanted.count)])
            let placeholders = (2...(chunk.count + 1)).map { "?\($0)" }.joined(separator: ", ")
            var bindings: [Any] = [indexVersion]
            bindings += chunk.map { $0 as Any }
            let rows: [(Int64, String)] = database.query("""
                SELECT embedded.snapshot_id, embedded.text
                FROM screen_embeddings AS embedded
                WHERE embedded.model_id = ?1 AND embedded.snapshot_id IN (\(placeholders))
                  AND EXISTS (SELECT 1 FROM ocr_metadata AS ocr WHERE ocr.snapshot_id = embedded.snapshot_id)
                """, bind: bindings) { statement in
                sqlite3_column_text(statement, 1).map { (sqlite3_column_int64(statement, 0), String(cString: $0)) }
            }
            for (id, text) in rows { texts[id] = text }
        }
        return texts
    }

    func screenTexts(ids: [Int64]) -> [Int64: String] {
        guard let database else { return [:] }
        return Self.screenTexts(ids, in: database)
    }

    func search(_ query: String, limit: Int = 10,
                meetingIDs: Set<UUID>? = nil,
                priority: InferencePriority = .background) async -> [Hit] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard limit > 0, !trimmed.isEmpty, database != nil, hasEmbeddings else { return [] }
        if let meetingIDs, meetingIDs.isEmpty { return [] }
        guard let queryVector = await embedQuery(
            trimmed, prefix: Self.queryPrefix, priority: priority) else { return [] }
        let url = databaseURL
        let worker = Task.detached(priority: .userInitiated) {
            guard !Task.isCancelled, let database = SQLiteDatabase(url: url, readOnly: true) else { return [Hit]() }
            return Self.meetingHits(in: database, meetingIDs: meetingIDs, queryVector: queryVector, limit: limit)
        }
        let ranked = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
        guard !Task.isCancelled else { return [] }
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

    nonisolated static func meetingHits(
        in database: SQLiteDatabase,
        meetingIDs: Set<UUID>?,
        queryVector: [Float],
        limit: Int
    ) -> [Hit] {
        var bindings: [Any] = [Self.indexVersion]
        let scope: String
        if let meetingIDs {
            let parameters = meetingIDs.sorted { $0.uuidString < $1.uuidString }.map { id -> String in
                bindings.append(id.uuidString)
                return "?\(bindings.count)"
            }
            scope = "embedded.meeting_id IN (\(parameters.joined(separator: ",")))"
        } else { scope = "1 = 1" }
        var scorer = VectorScorer(queryVector)
        var scored: [(score: Float, order: Int, rowID: Int64, meetingID: UUID, start: TimeInterval)] = []
        database.withStatement(
            """
            SELECT embedded.rowid, embedded.meeting_id, embedded.start, embedded.vec
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
            var order = 0
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let blob = sqlite3_column_blob(statement, 3),
                      Int(sqlite3_column_bytes(statement, 3)) == scorer.byteCount,
                      let meetingID = uuid(column: 1, of: statement),
                      meetingIDs?.contains(meetingID) ?? true else { continue }
                let score = scorer.score(blob)
                order += 1
                guard score > meetingSimilarityFloor else { continue }
                scored.append((score, order, sqlite3_column_int64(statement, 0), meetingID,
                               sqlite3_column_double(statement, 2)))
            }
        }
        let kept = scored.sorted { meetingRanksFirst(($0.score, $0.order), ($1.score, $1.order)) }.prefix(limit)
        let texts = Dictionary(uniqueKeysWithValues: rowTexts(
            in: database, table: "embeddings", key: "rowid", ids: kept.map(\.rowID)))
        return kept.compactMap { row in
            texts[row.rowID].map { Hit(meetingID: row.meetingID, start: row.start, text: $0, score: row.score) }
        }
    }

    nonisolated static func screenHits(
        in database: SQLiteDatabase,
        filter: ScreenSearchFilter,
        queryVector: [Float],
        limit: Int
    ) -> [ScreenHit] {
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

        var scorer = VectorScorer(queryVector)
        var scored: [(score: Float, snapshotID: Int64, ts: TimeInterval)] = []
        database.withStatement("""
            SELECT embedded.snapshot_id, embedded.ts, embedded.vec
            FROM screen_embeddings AS embedded
            JOIN screenshots AS shot ON shot.id = embedded.snapshot_id
            WHERE \(conditions.joined(separator: " AND "))
              AND EXISTS (
                  SELECT 1 FROM ocr_metadata AS ocr
                  WHERE ocr.snapshot_id = embedded.snapshot_id
              )
            ORDER BY embedded.snapshot_id
            """, bind: bindings) { statement in
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let blob = sqlite3_column_blob(statement, 2),
                      Int(sqlite3_column_bytes(statement, 2)) == scorer.byteCount else { continue }
                let score = scorer.score(blob)
                guard score > screenSimilarityFloor else { continue }
                scored.append((score, sqlite3_column_int64(statement, 0), sqlite3_column_double(statement, 1)))
            }
        }
        let kept = scored.sorted {
            screenRanksFirst(($0.score, $0.ts, $0.snapshotID), ($1.score, $1.ts, $1.snapshotID))
        }.prefix(limit)
        var details: [Int64: (app: String, text: String)] = [:]
        if !kept.isEmpty {
            let placeholders = (1...kept.count).map { "?\($0)" }.joined(separator: ",")
            database.withStatement(
                "SELECT snapshot_id, app, text FROM screen_embeddings WHERE snapshot_id IN (\(placeholders))",
                bind: kept.map(\.snapshotID)
            ) { statement in
                while sqlite3_step(statement) == SQLITE_ROW {
                    guard let app = sqlite3_column_text(statement, 1),
                          let text = sqlite3_column_text(statement, 2) else { continue }
                    details[sqlite3_column_int64(statement, 0)] = (String(cString: app), String(cString: text))
                }
            }
        }
        return kept.compactMap { row in
            details[row.snapshotID].map {
                ScreenHit(snapshotID: row.snapshotID, ts: Date(timeIntervalSince1970: row.ts),
                          app: $0.app, text: $0.text, score: row.score)
            }
        }
    }

    struct VectorScorer {
        let queryVector: [Float]
        let byteCount: Int
        private var scratch: [Float]

        init(_ queryVector: [Float]) {
            self.queryVector = queryVector
            byteCount = queryVector.count * MemoryLayout<Float>.stride
            scratch = Array(repeating: 0, count: queryVector.count)
        }

        mutating func score(_ bytes: UnsafeRawPointer) -> Float {
            var total: Float = 0
            scratch.withUnsafeMutableBytes { $0.copyMemory(from: UnsafeRawBufferPointer(start: bytes, count: byteCount)) }
            vDSP_dotpr(scratch, 1, queryVector, 1, &total, vDSP_Length(queryVector.count))
            return total
        }

        mutating func score(_ vector: Data) -> Float? {
            guard byteCount > 0, vector.count == byteCount else { return nil }
            return vector.withUnsafeBytes { score($0.baseAddress!) }
        }
    }

    nonisolated private static func uuid(column: Int32, of statement: OpaquePointer) -> UUID? {
        guard let text = sqlite3_column_text(statement, column) else { return nil }
        var bytes: uuid_t = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        let parsed = text.withMemoryRebound(to: CChar.self, capacity: 37) { uuid_parse($0, &bytes) }
        return parsed == 0 ? UUID(uuid: bytes) : nil
    }

    nonisolated private static func rowTexts(
        in database: SQLiteDatabase, table: String, key: String, ids: [Int64]
    ) -> [(Int64, String)] {
        guard !ids.isEmpty else { return [] }
        let placeholders = ids.indices.map { "?\($0 + 1)" }.joined(separator: ",")
        return database.query("SELECT \(key), text FROM \(table) WHERE \(key) IN (\(placeholders))",
                              bind: ids) { statement in
            sqlite3_column_text(statement, 1).map { (sqlite3_column_int64(statement, 0), String(cString: $0)) }
        }
    }

    nonisolated static func rank(
        _ candidates: [Candidate],
        against queryVector: [Float],
        limit: Int
    ) -> [Hit] {
        var scorer = VectorScorer(queryVector)
        let scored = candidates.indices.compactMap { index -> (score: Float, order: Int)? in
            let candidate = candidates[index]
            guard let score = scorer.score(candidate.vector), score > meetingSimilarityFloor else { return nil }
            return (score, index)
        }
        return scored.sorted(by: meetingRanksFirst).prefix(limit).map { row in
            let candidate = candidates[row.order]
            return Hit(meetingID: candidate.meetingID, start: candidate.start, text: candidate.text, score: row.score)
        }
    }

    nonisolated static func rankScreen(
        _ candidates: [ScreenCandidate],
        against queryVector: [Float],
        limit: Int
    ) -> [ScreenHit] {
        var scorer = VectorScorer(queryVector)
        let scored = candidates.compactMap { candidate -> ScreenHit? in
            guard let score = scorer.score(candidate.vector), score > screenSimilarityFloor else { return nil }
            return ScreenHit(snapshotID: candidate.snapshotID, ts: candidate.ts, app: candidate.app,
                             text: candidate.text, score: score)
        }
        return Array(scored.sorted {
            screenRanksFirst(($0.score, $0.ts.timeIntervalSince1970, $0.snapshotID),
                             ($1.score, $1.ts.timeIntervalSince1970, $1.snapshotID))
        }.prefix(limit))
    }

    nonisolated private static func meetingRanksFirst(_ lhs: (score: Float, order: Int),
                                                      _ rhs: (score: Float, order: Int)) -> Bool {
        lhs.score != rhs.score ? lhs.score > rhs.score : lhs.order < rhs.order
    }

    nonisolated private static func screenRanksFirst(_ lhs: (score: Float, ts: TimeInterval, id: Int64),
                                                     _ rhs: (score: Float, ts: TimeInterval, id: Int64)) -> Bool {
        if lhs.score != rhs.score { return lhs.score > rhs.score }
        if lhs.ts != rhs.ts { return lhs.ts > rhs.ts }
        return lhs.id < rhs.id
    }

    nonisolated private static func vectorData(_ vector: [Float]) -> Data {
        vector.withUnsafeBufferPointer { buffer -> Data in
            guard let baseAddress = buffer.baseAddress else { return Data() }
            return Data(bytes: baseAddress, count: buffer.count * MemoryLayout<Float>.stride)
        }
    }

    nonisolated static let similarityPrefix = "task: sentence similarity | query: "

    func similarityVectors(_ texts: [String]) async -> [[Float]]? {
        guard !texts.isEmpty else { return [] }
        let model = storage.rootURL.appendingPathComponent("models/\(Self.modelFile)")
        guard FileManager.default.fileExists(atPath: model.path),
              let vectors = try? await embedThroughGate(texts, prefix: Self.similarityPrefix, priority: .background),
              vectors.count == texts.count else { return nil }
        return vectors
    }

    func queryVector(_ query: String, priority: InferencePriority = .interactive) async -> [Float]? {
        await embedQuery(query, prefix: Self.queryPrefix, priority: priority)
    }

    private func embedQuery(_ query: String, prefix: String,
                            priority: InferencePriority) async -> [Float]? {
        let input = prefix + query
        if let last = lastQueryEmbedding, last.input == input { return last.vector }
        guard let vector = try? await embedThroughGate([query], prefix: prefix, priority: priority).first
        else { return nil }
        lastQueryEmbedding = (input, vector)
        return vector
    }

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

    private func embedThroughGate(_ texts: [String], prefix: String,
                                  priority: InferencePriority) async throws -> [[Float]] {
        if priority == .background {
            return try await requestGate.background { try await embedder(texts, prefix, priority) }
        }
        return try await requestGate.foreground { try await embedder(texts, prefix, priority) }
    }

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

    nonisolated static func embeddingRequestBody(_ texts: [String], prefix: String) -> [String: Any] {
        [
            "input": texts.map { prefix + $0 },
            "model": modelID,
            "cache_prompt": false,
        ]
    }

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

    static func preparedModel(storage: StorageManager) async throws -> URL {
        try await ensureModel(storage: storage)
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
        try UITestRuntime.refuseDownloadInUnitTests(of: "the embedding model")
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

    nonisolated static func removeObsoleteModels(in folder: URL) {
        for name in obsoleteModelFiles where name != modelFile {
            DownloadIntegrity.removeFileAndMarker(at: folder.appendingPathComponent(name))
        }
    }

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
