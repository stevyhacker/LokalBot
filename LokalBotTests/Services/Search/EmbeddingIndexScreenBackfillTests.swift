import XCTest
@testable import LokalBot

/// Screen text reaches semantic search without waiting for a screen search,
/// and a failed backfill pass is retried with backoff. On 2026-10-12 four
/// days of screens had no vectors: only a search started a pass, and the one
/// pass that ran failed once (another embedder held port 17873) and stopped.
@MainActor
final class EmbeddingIndexScreenBackfillTests: XCTestCase {
    /// Fails its first `failures` calls the way a blocked embedder port does.
    private final class FlakyEmbedder {
        var failuresLeft: Int
        private(set) var documentCalls: [[String]] = []

        init(failures: Int = 0) { failuresLeft = failures }

        func embed(_ texts: [String], prefix: String) throws -> [[Float]] {
            guard prefix == EmbeddingIndex.documentPrefix else { return texts.map { _ in [1, 0] } }
            documentCalls.append(texts)
            if failuresLeft > 0 {
                failuresLeft -= 1
                throw LlamaServer.ServerError.failedToStart("port 17873 is already in use")
            }
            return texts.map { _ in [1, 0] }
        }
    }

    private struct Library {
        let root: URL
        let databaseURL: URL
        let store: ActivityStore
        let embedder: FlakyEmbedder
    }

    private static let fastSchedule = EmbeddingIndex.ScreenBackfillSchedule(
        newTextDelay: .milliseconds(20),
        firstRetryDelay: .milliseconds(20),
        maximumRetryDelay: .milliseconds(80))

    private var roots: [URL] = []

    override func tearDown() {
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots = []
        super.tearDown()
    }

    /// `searchedScreens` seeds one embedded screen, the state of a library
    /// that has already searched screens by meaning.
    private func makeLibrary(searchedScreens: Bool, failures: Int = 0) throws -> Library {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("screen-backfill-\(UUID().uuidString)", isDirectory: true)
        roots.append(root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let databaseURL = root.appendingPathComponent("lokalbotv3.sqlite")
        let store = ActivityStore(databaseURL: databaseURL)
        let library = Library(root: root, databaseURL: databaseURL, store: store,
                              embedder: FlakyEmbedder(failures: failures))
        if searchedScreens {
            _ = makeIndex(library)
            let screenID = try store.insertScreenshot(
                ts: Date(timeIntervalSince1970: 1_790_000_000), path: "", app: "Notes",
                windowTitle: "Earlier", ocr: "Earlier screen")
            let database = try XCTUnwrap(SQLiteDatabase(url: databaseURL))
            let vector = [Float(1), 0].withUnsafeBufferPointer { Data(buffer: $0) }
            XCTAssertTrue(database.run("""
                INSERT INTO screen_embeddings (snapshot_id, ts, app, text, vec, model_id)
                VALUES (?1, ?2, ?3, ?4, ?5, ?6)
                """, bind: [screenID, 1_790_000_000.0, "Notes", "Earlier screen", vector,
                             EmbeddingIndex.indexVersion]))
        }
        return library
    }

    private func makeIndex(_ library: Library) -> EmbeddingIndex {
        let embedder = library.embedder
        return EmbeddingIndex(
            databaseURL: library.databaseURL,
            storage: StorageManager(rootURL: library.root),
            embedder: { texts, prefix, _ in try embedder.embed(texts, prefix: prefix) },
            screenBackfillSchedule: Self.fastSchedule)
    }

    private func capture(_ text: String, in library: Library) throws -> Int64 {
        try library.store.insertScreenshot(
            ts: Date(), path: "", app: "Editor", windowTitle: text, ocr: text)
    }

    private func isEmbedded(_ snapshotID: Int64, in library: Library) -> Bool {
        SQLiteDatabase(url: library.databaseURL)?.hasRow(
            "SELECT 1 FROM screen_embeddings WHERE snapshot_id = ?1 AND model_id = ?2",
            bind: [snapshotID, EmbeddingIndex.indexVersion]) ?? false
    }

    private func waitUntil(
        _ description: String,
        file: StaticString = #filePath, line: UInt = #line,
        _ condition: () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition() {
            guard Date() < deadline else {
                return XCTFail("timed out waiting until \(description)", file: file, line: line)
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func testFailedPassIsRetriedWithBackoffUntilTheScreensAreEmbedded() async throws {
        let library = try makeLibrary(searchedScreens: true, failures: 2)
        let index = makeIndex(library)
        let screen = try capture("Quarterly roadmap draft", in: library)

        await index.reindexScreenText()
        XCTAssertEqual(index.screenReindexFailures, 1)
        XCTAssertFalse(isEmbedded(screen, in: library))

        // Nobody searches again: the retries alone must finish the job.
        try await waitUntil("the retried pass embeds the screen") { isEmbedded(screen, in: library) }
        XCTAssertEqual(library.embedder.documentCalls.count, 3)
        XCTAssertEqual(index.screenReindexFailures, 0)
    }

    func testNewScreenTextIsEmbeddedInOneBatchedPassWithoutASearch() async throws {
        let library = try makeLibrary(searchedScreens: true)
        let index = makeIndex(library)
        var screens: [Int64] = []
        for text in ["Launch checklist", "Budget sheet", "Hiring plan"] {
            screens.append(try capture(text, in: library))
            index.screenTextDidArrive()
        }
        XCTAssertTrue(library.embedder.documentCalls.isEmpty, "new text waits for the batched pass")

        try await waitUntil("the new screens are embedded") {
            screens.allSatisfy { isEmbedded($0, in: library) }
        }
        XCTAssertEqual(library.embedder.documentCalls,
                       [["Launch checklist", "Budget sheet", "Hiring plan"]])
    }

    func testLaunchCatchesUpOnScreensLeftBehind() async throws {
        let library = try makeLibrary(searchedScreens: true)
        let screen = try capture("Captured while the embedder was down", in: library)
        let index = makeIndex(library)

        await index.resumeScreenBackfill()

        try await waitUntil("the pending screen is embedded") { isEmbedded(screen, in: library) }
    }

    func testLibraryThatNeverSearchedScreensStaysLazyUntilItsFirstSearch() async throws {
        let library = try makeLibrary(searchedScreens: false)
        let index = makeIndex(library)
        let first = try capture("Design review notes", in: library)
        index.screenTextDidArrive()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(library.embedder.documentCalls.isEmpty)

        _ = await index.searchScreen("design review")
        try await waitUntil("the search's pass embeds the screen") { isEmbedded(first, in: library) }

        let second = try capture("Follow-up from the design review", in: library)
        index.screenTextDidArrive()
        try await waitUntil("later captures are embedded too") { isEmbedded(second, in: library) }
    }

    func testStoppingCancelsTheScheduledRetry() async throws {
        let library = try makeLibrary(searchedScreens: true, failures: 1)
        let index = makeIndex(library)
        let screen = try capture("Draft contract", in: library)

        await index.reindexScreenText()
        index.stopScreenBackfill()
        index.screenTextDidArrive()
        index.stopScreenBackfill()
        try await Task.sleep(for: .milliseconds(150))

        XCTAssertEqual(library.embedder.documentCalls.count, 1)
        XCTAssertFalse(isEmbedded(screen, in: library))
    }

    func testRetryDelayDoublesUpToItsCap() {
        let schedule = EmbeddingIndex.ScreenBackfillSchedule.standard
        XCTAssertEqual(schedule.retryDelay(afterFailures: 1), .seconds(60))
        XCTAssertEqual(schedule.retryDelay(afterFailures: 2), .seconds(120))
        XCTAssertEqual(schedule.retryDelay(afterFailures: 5), .seconds(960))
        XCTAssertEqual(schedule.retryDelay(afterFailures: 6), .seconds(30 * 60))
        XCTAssertEqual(schedule.retryDelay(afterFailures: 1_000), .seconds(30 * 60))
    }
}
