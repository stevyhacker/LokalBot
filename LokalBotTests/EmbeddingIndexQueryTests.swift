import SQLite3
import XCTest
@testable import LokalBot

/// Ask and Quick Recall search meetings and then screens on every debounced
/// keystroke. The typed query is embedded once for both sources, at the
/// caller's priority, while indexing stays background work, sent in small
/// requests so the query waits behind at most one of them.
@MainActor
final class EmbeddingIndexQueryTests: XCTestCase {
    private final class Recorder {
        struct Call: Equatable {
            let texts: [String]
            let prefix: String
            let priority: InferencePriority
        }

        private(set) var calls: [Call] = []
        var failNext = false

        var queries: [Call] { calls.filter { $0.prefix == EmbeddingIndex.queryPrefix } }
        var documents: [Call] { calls.filter { $0.prefix == EmbeddingIndex.documentPrefix } }

        func embed(_ texts: [String], prefix: String, priority: InferencePriority) throws -> [[Float]] {
            calls.append(Call(texts: texts, prefix: prefix, priority: priority))
            if failNext {
                failNext = false
                throw URLError(.cannotConnectToHost)
            }
            return texts.map { _ in [1, 0] }
        }
    }

    /// Holds each request until the test answers it, like a busy server.
    @MainActor
    private final class HeldEmbedder {
        struct Request: Equatable {
            let texts: [String]
            let priority: InferencePriority
        }

        private(set) var posted: [Request] = []
        private var held: [Int: CheckedContinuation<[[Float]], Error>] = [:]
        private var answersImmediately = false

        /// The vector says which text it belongs to, so stored rows can be
        /// checked against their text.
        static func vector(for text: String) -> [Float] { [Float(text.count), 0] }

        func embed(_ texts: [String], priority: InferencePriority) async throws -> [[Float]] {
            posted.append(Request(texts: texts, priority: priority))
            if answersImmediately { return texts.map(Self.vector) }
            let index = posted.count - 1
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { held[index] = $0 }
            } onCancel: {
                Task { @MainActor in self.held.removeValue(forKey: index)?.resume(throwing: CancellationError()) }
            }
        }

        func answer(_ index: Int) {
            held.removeValue(forKey: index)?.resume(returning: posted[index].texts.map(Self.vector))
        }

        /// Answers everything held so far and every later request.
        func answerAll() {
            answersImmediately = true
            for index in held.keys.sorted() { answer(index) }
        }
    }

    private struct Library {
        let root: URL
        let databaseURL: URL
        let store: ActivityStore
        let index: EmbeddingIndex
        let recorder: Recorder
        let meetingID: UUID
        let screenID: Int64
    }

    private var roots: [URL] = []

    override func tearDown() {
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots = []
        super.tearDown()
    }

    private func vectorData(_ values: [Float]) -> Data {
        values.withUnsafeBufferPointer { buffer in
            Data(bytes: buffer.baseAddress!, count: buffer.count * MemoryLayout<Float>.stride)
        }
    }

    /// One embedded meeting chunk and one embedded screen, both matching the
    /// recorder's query vector exactly.
    private func makeLibrary(embedder: EmbeddingIndex.Embedder? = nil) throws -> Library {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("embedding-query-\(UUID().uuidString)", isDirectory: true)
        roots.append(root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let databaseURL = root.appendingPathComponent("lokalbotv3.sqlite")
        let store = ActivityStore(databaseURL: databaseURL)
        let screenID = try store.insertScreenshot(
            ts: Date(), path: "/tmp/synthetic-screen.enc", app: "Editor",
            windowTitle: "Launch", ocr: "Launch budget review")
        let recorder = Recorder()
        let index = EmbeddingIndex(
            databaseURL: databaseURL, storage: StorageManager(rootURL: root),
            embedder: embedder ?? { texts, prefix, priority in
                try recorder.embed(texts, prefix: prefix, priority: priority)
            })
        let database = try XCTUnwrap(SQLiteDatabase(url: databaseURL))
        let meetingID = UUID()
        let vector = vectorData([1, 0])
        XCTAssertTrue(database.run(
            "INSERT INTO embeddings (meeting_id, start, text, vec) VALUES (?1, ?2, ?3, ?4)",
            bind: [meetingID.uuidString, 30.0, "We agreed on the launch budget.", vector]))
        XCTAssertTrue(database.run(
            "INSERT INTO embedded_meetings (meeting_id, source_mtime, model_id) VALUES (?1, ?2, ?3)",
            bind: [meetingID.uuidString, 1.0, EmbeddingIndex.indexVersion]))
        XCTAssertTrue(database.run("""
            INSERT INTO screen_embeddings (snapshot_id, ts, app, text, vec, model_id)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6)
            """, bind: [screenID, Date().timeIntervalSince1970, "Editor",
                         "Launch budget review", vector, EmbeddingIndex.indexVersion]))
        return Library(root: root, databaseURL: databaseURL, store: store, index: index,
                       recorder: recorder, meetingID: meetingID, screenID: screenID)
    }

    /// The database paths score rows in place and read text only for the rows
    /// they keep; they must rank exactly like the in-memory rankers, ties and
    /// floors included.
    func testDatabaseRankingMatchesInMemoryRanking() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("embedding-ranking-\(UUID().uuidString)", isDirectory: true)
        roots.append(root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let databaseURL = root.appendingPathComponent("lokalbotv3.sqlite")
        let store = ActivityStore(databaseURL: databaseURL)
        // Creates the embedding tables.
        let index = EmbeddingIndex(databaseURL: databaseURL, storage: StorageManager(rootURL: root),
                                   embedder: { texts, _, _ in texts.map { _ in [1, 0] } })
        defer { withExtendedLifetime(index) {} }
        let database = try XCTUnwrap(SQLiteDatabase(url: databaseURL))
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let meetingID = UUID()
        XCTAssertTrue(database.run(
            "INSERT INTO embedded_meetings (meeting_id, source_mtime, model_id) VALUES (?1, ?2, ?3)",
            bind: [meetingID.uuidString, 1.0, EmbeddingIndex.indexVersion]))
        // Cosines with [1, 0]: below both floors, ties, between the floors.
        let cosines: [Float] = [0.5, 0.8, 0.8, 0.6, 0.95, 0.8, 0.7, 0.9]
        var screens: [EmbeddingIndex.ScreenCandidate] = []
        var chunks: [EmbeddingIndex.Candidate] = []
        for (index, cosine) in cosines.enumerated() {
            let ts = now.addingTimeInterval(Double(index % 3))
            let text = "Capture \(index)"
            let vector = vectorData([cosine, (1 - cosine * cosine).squareRoot()])
            let id = try store.insertScreenshot(ts: ts, path: "", app: "App \(index)", ocr: text)
            XCTAssertTrue(database.run("""
                INSERT INTO screen_embeddings (snapshot_id, ts, app, text, vec, model_id)
                VALUES (?1, ?2, ?3, ?4, ?5, ?6)
                """, bind: [id, ts.timeIntervalSince1970, "App \(index)", text, vector, EmbeddingIndex.indexVersion]))
            XCTAssertTrue(database.run(
                "INSERT INTO embeddings (meeting_id, start, text, vec) VALUES (?1, ?2, ?3, ?4)",
                bind: [meetingID.uuidString, Double(index), text, vector]))
            screens.append(.init(snapshotID: id, ts: ts, app: "App \(index)", text: text, vector: vector))
            chunks.append(.init(meetingID: meetingID, start: Double(index), text: text, vector: vector))
        }
        let query: [Float] = [1, 0]

        let foundScreens = EmbeddingIndex.screenHits(in: database, filter: .all, queryVector: query, limit: 4)
        XCTAssertEqual(foundScreens, EmbeddingIndex.rankScreen(screens, against: query, limit: 4))
        XCTAssertEqual(foundScreens.map(\.text), ["Capture 4", "Capture 7", "Capture 2", "Capture 5"])

        let foundChunks = EmbeddingIndex.meetingHits(in: database, meetingIDs: [meetingID], queryVector: query, limit: 5)
        let rankedChunks = EmbeddingIndex.rank(chunks, against: query, limit: 5)
        XCTAssertEqual(foundChunks.map(\.text), rankedChunks.map(\.text))
        XCTAssertEqual(foundChunks.map(\.score), rankedChunks.map(\.score))
        XCTAssertEqual(foundChunks.map(\.start), [4, 7, 1, 2, 5])

        // A capture deleted while ranking ran is dropped by the main-actor check.
        try store.deleteScreenshot(id: foundScreens[0].snapshotID)
        XCTAssertEqual(EmbeddingIndex.liveScreenHits(foundScreens, in: database).map(\.snapshotID),
                       foundScreens.dropFirst().map(\.snapshotID))
    }

    func testMeetingAndScreenSearchShareOneQueryEmbedding() async throws {
        let library = try makeLibrary()

        // Typing pauses after a space; the padded query is the same query.
        let meetings = await library.index.search("launch budget ", priority: .interactive)
        let screens = await library.index.searchScreen("launch budget", priority: .interactive)

        XCTAssertEqual(meetings.map(\.meetingID), [library.meetingID])
        XCTAssertEqual(screens.map(\.snapshotID), [library.screenID])
        XCTAssertEqual(library.recorder.queries, [
            .init(texts: ["launch budget"], prefix: EmbeddingIndex.queryPrefix, priority: .interactive),
        ])
    }

    func testChangedQueryEmbedsAgainAndFailedEmbeddingIsRetried() async throws {
        let library = try makeLibrary()
        library.recorder.failNext = true

        let failed = await library.index.search("launch budget", priority: .interactive)
        let retried = await library.index.searchScreen("launch budget", priority: .interactive)
        let changed = await library.index.search("hiring plan")

        XCTAssertTrue(failed.isEmpty)
        XCTAssertEqual(retried.map(\.snapshotID), [library.screenID])
        XCTAssertEqual(changed.map(\.meetingID), [library.meetingID])
        XCTAssertEqual(library.recorder.queries.map(\.texts),
                       [["launch budget"], ["launch budget"], ["hiring plan"]])
        // Callers that pass no priority keep the previous background lease.
        XCTAssertEqual(library.recorder.queries.map(\.priority),
                       [.interactive, .interactive, .background])
    }

    func testIndexingStaysBackgroundWork() async throws {
        let library = try makeLibrary()
        let unembeddedScreen = try library.store.insertScreenshot(
            ts: Date(), path: "/tmp/synthetic-screen-2.enc", app: "Editor",
            windowTitle: "Hiring", ocr: "Hiring plan draft")
        let meetingID = UUID()
        try MeetingFixture.write([
            .init(id: meetingID, title: "Hiring sync", startedAt: Date(),
                  transcriptLines: ["We will open two roles."]),
        ], under: library.root)
        let meeting = try XCTUnwrap(StorageManager(rootURL: library.root).loadMeetings()
            .first { $0.id == meetingID })

        await library.index.reindexScreenText()
        try await library.index.index(meeting)

        XCTAssertEqual(library.recorder.documents.count, 2)
        XCTAssertEqual(library.recorder.documents.first?.texts, ["Hiring plan draft"])
        XCTAssertEqual(library.recorder.documents.map(\.priority), [.background, .background])
        XCTAssertTrue(library.recorder.queries.isEmpty)
        let database = try XCTUnwrap(SQLiteDatabase(url: library.databaseURL))
        XCTAssertTrue(database.hasRow(
            "SELECT 1 FROM screen_embeddings WHERE snapshot_id = ?1", bind: [unembeddedScreen]))
    }

    // MARK: - Background requests and typed queries

    /// Lets queued main-actor work run until `condition` holds.
    private func settle(until condition: () -> Bool,
                        file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<1_000 where !condition() { await Task.yield() }
        XCTAssertTrue(condition(), "condition never held", file: file, line: line)
    }

    /// A meeting whose transcript makes one chunk per line, each line a
    /// different length.
    private func writeMeeting(in library: Library, lines: Int) throws -> Meeting {
        let meetingID = UUID()
        try MeetingFixture.write([
            .init(id: meetingID, title: "Planning", startedAt: Date(),
                  transcriptLines: (0..<lines).map { line in
                      "Line \(line) " + String(repeating: "plan ", count: 110 + 2 * line)
                  }),
        ], under: library.root)
        return try XCTUnwrap(StorageManager(rootURL: library.root).loadMeetings()
            .first { $0.id == meetingID })
    }

    func testBackgroundRequestsStayWithinInputAndCharacterLimits() {
        let screenRows = Array(repeating: String(repeating: "a", count: 1_500), count: 3)
        XCTAssertEqual(EmbeddingIndex.backgroundRequestRanges(screenRows), [0..<1, 1..<2, 2..<3])
        let chunks = Array(repeating: String(repeating: "b", count: 500), count: 10)
        XCTAssertEqual(EmbeddingIndex.backgroundRequestRanges(chunks), [0..<4, 4..<8, 8..<10])
        let shortTexts = Array(repeating: "c", count: 20)
        XCTAssertEqual(EmbeddingIndex.backgroundRequestRanges(shortTexts), [0..<8, 8..<16, 16..<20])
        let oversized = ["d", String(repeating: "e", count: 2_500), "f"]
        XCTAssertEqual(EmbeddingIndex.backgroundRequestRanges(oversized), [0..<1, 1..<2, 2..<3])
        XCTAssertEqual(EmbeddingIndex.backgroundRequestRanges([]), [])
    }

    func testTypedQueryWaitsForAtMostOneBackgroundRequest() async throws {
        let held = HeldEmbedder()
        let library = try makeLibrary { texts, _, priority in
            try await held.embed(texts, priority: priority)
        }
        let meeting = try writeMeeting(in: library, lines: 9)

        let indexing = Task { try await library.index.index(meeting) }
        await settle { held.posted.count == 1 }
        let searching = Task { await library.index.search("launch budget", priority: .interactive) }
        // The query is posted while the background request is on the server.
        await settle { held.posted.count == 2 }
        XCTAssertEqual(held.posted[1], .init(texts: ["launch budget"], priority: .interactive))

        held.answer(0)
        for _ in 0..<100 { await Task.yield() }
        // The next background request is held until the query has its vector.
        XCTAssertEqual(held.posted.count, 2)

        held.answerAll()
        let hits = await searching.value
        try await indexing.value

        XCTAssertTrue(hits.map(\.meetingID).contains(library.meetingID))
        let background = held.posted.filter { $0.priority == .background }
        XCTAssertGreaterThan(background.count, 2)
        var expectedPriorities: [InferencePriority] = [.background, .interactive]
        for _ in background.dropFirst() { expectedPriorities.append(.background) }
        XCTAssertEqual(held.posted.map(\.priority), expectedPriorities)
        for request in background {
            var characters = 0
            for text in request.texts { characters += text.count }
            XCTAssertLessThanOrEqual(request.texts.count, EmbeddingIndex.backgroundRequestMaximumInputs)
            XCTAssertLessThanOrEqual(characters, EmbeddingIndex.backgroundRequestMaximumCharacters)
        }
        // Every chunk is stored once, in order, with its own vector.
        let database = try XCTUnwrap(SQLiteDatabase(url: library.databaseURL))
        let stored: [(text: String, vector: [Float])] = database.query(
            "SELECT text, vec FROM embeddings WHERE meeting_id = ?1 ORDER BY rowid",
            bind: [meeting.id.uuidString]
        ) { statement in
            guard let text = sqlite3_column_text(statement, 0),
                  let blob = sqlite3_column_blob(statement, 1) else { return nil }
            let count = Int(sqlite3_column_bytes(statement, 1)) / MemoryLayout<Float>.stride
            let vector = Array(UnsafeBufferPointer(
                start: blob.assumingMemoryBound(to: Float.self), count: count))
            return (String(cString: text), vector)
        }
        XCTAssertEqual(stored.map(\.text), background.flatMap(\.texts))
        XCTAssertEqual(stored.count, 9)
        for row in stored { XCTAssertEqual(row.vector, HeldEmbedder.vector(for: row.text)) }
    }

    func testCancelledBackgroundWaiterLeavesTheGateUsable() async throws {
        let held = HeldEmbedder()
        let library = try makeLibrary { texts, _, priority in
            try await held.embed(texts, priority: priority)
        }
        let meeting = try writeMeeting(in: library, lines: 2)

        let searching = Task { await library.index.search("launch budget", priority: .interactive) }
        await settle { held.posted.count == 1 }
        let indexing = Task { try await library.index.index(meeting) }
        for _ in 0..<100 { await Task.yield() }
        XCTAssertEqual(held.posted.count, 1)

        indexing.cancel()
        do {
            try await indexing.value
            XCTFail("cancelled indexing finished")
        } catch is CancellationError {}

        held.answerAll()
        _ = await searching.value
        let screenID = try library.store.insertScreenshot(
            ts: Date(), path: "/tmp/synthetic-screen-3.enc", app: "Editor",
            windowTitle: "Roadmap", ocr: "Roadmap draft")
        await library.index.reindexScreenText()

        XCTAssertEqual(held.posted, [
            .init(texts: ["launch budget"], priority: .interactive),
            .init(texts: ["Roadmap draft"], priority: .background),
        ])
        let database = try XCTUnwrap(SQLiteDatabase(url: library.databaseURL))
        XCTAssertTrue(database.hasRow(
            "SELECT 1 FROM screen_embeddings WHERE snapshot_id = ?1", bind: [screenID]))
    }
}
