import XCTest
@testable import LokalBot

@MainActor
final class PerformanceReadPathTests: XCTestCase {
    func testOCRIndexMigrationKeepsHistoricalIdentityAndRetention() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("library.sqlite")
        let store = ActivityStore(databaseURL: url)
        _ = try store.insertScreenshot(ts: Date(), path: "", app: "Notes", ocr: "")
        let first = try store.insertScreenshot(ts: Date(), path: "", app: "Notes", ocr: "Substring AlphaBeta")
        let saved = try store.insertScreenshot(ts: Date(), path: "", app: "Notes", ocr: "Saved AlphaBeta")
        let database = try XCTUnwrap(SQLiteDatabase(url: url))
        // Exercise migration of real FTS rows whose row IDs differ from capture IDs.
        try database.execute("DROP TABLE ocr_metadata")
        let migrated = ActivityStore(databaseURL: url)
        XCTAssertEqual(migrated.ocrText(snapshotID: first), "Substring AlphaBeta")
        XCTAssertEqual(migrated.matchingSnapshotIDs([first, saved, 999], query: "HAbE"), [first, saved])
        try migrated.saveMoment(snapshotID: saved)
        try migrated.clearRetainedText(ids: [first, saved])
        XCTAssertNil(migrated.ocrText(snapshotID: first))
        XCTAssertEqual(migrated.matchingSnapshotIDs([first, saved], query: "alpha"), [saved])
        XCTAssertFalse(database.hasRow("SELECT 1 FROM ocr_metadata WHERE snapshot_id = ?1", bind: [first]))
        try migrated.deleteScreenshot(id: saved)
        XCTAssertTrue(migrated.matchingSnapshotIDs([first, saved], query: "alpha").isEmpty)
        XCTAssertEqual(database.firstDouble("SELECT COUNT(*) FROM ocr_metadata"), 0)
        let reopened = ActivityStore(databaseURL: url)
        XCTAssertNil(reopened.ocrText(snapshotID: saved))
    }

    func testWorkerOwnsReadOnlyConnectionOffMainThread() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("library.sqlite")
        let store = ActivityStore(databaseURL: url)
        let id = try store.insertScreenshot(ts: Date(), path: "", app: "Notes", ocr: "Original")
        let result = await ActivityStore.readInBackground(at: url) { reader in
            (Thread.isMainThread, reader.ocrText(snapshotID: id))
        }
        XCTAssertFalse(result.0)
        XCTAssertEqual(result.1, "Original")
        let reader = try XCTUnwrap(SQLiteDatabase(url: url, readOnly: true))
        XCTAssertThrowsError(try reader.execute("DELETE FROM screenshots"))
        XCTAssertNotNil(store.screenshot(id: id))
    }

    func testUngroupedSearchRetainsIndividualCapturesInRelevanceOrder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ActivityStore(databaseURL: root.appendingPathComponent("library.sqlite"))
        let start = Date()
        let first = try store.insertScreenshot(ts: start, path: "", app: "Notes", ocr: "benchmark evidence")
        let second = try store.insertScreenshot(ts: start.addingTimeInterval(1), path: "", app: "Notes", ocr: "benchmark evidence")
        let hits = store.searchOCR("benchmark", groupResults: false)
        XCTAssertEqual(hits.map(\.snapshotID), [second, first])
        XCTAssertTrue(hits.allSatisfy { $0.captureCount == 1 })
        XCTAssertEqual(store.searchOCR("benchmark").count, 1)
    }

    func testBrowserObservationRunsOffMainAndPreservesURLBinding() async throws {
        let url = try XCTUnwrap(URL(string: "https://meet.google.com/abc-defg-hij"))
        let result = await BrowserMeetingSession.observe(processIDs: [42], expectedURL: url) { pid, expected in
            XCTAssertFalse(Thread.isMainThread)
            XCTAssertEqual(pid, 42)
            XCTAssertEqual(expected, url)
            return .init(url: url, state: .ended)
        }
        XCTAssertEqual(result[42]?.state, .ended)
    }
}
