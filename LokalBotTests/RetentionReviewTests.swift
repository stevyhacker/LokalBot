import XCTest
@testable import LokalBot

@MainActor
final class RetentionReviewTests: XCTestCase {
    func testRetentionCoversMetadataAndExactActivityTitlesWithIndependentTextException() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("metadata-retention-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = StorageManager(rootURL: root)
        let store = ActivityStore(databaseURL: root.appendingPathComponent("activity.sqlite"))
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let old = now.addingTimeInterval(-20 * 86_400)
        let expired = try store.insertScreenshot(ts: old, path: "", app: "Notes", windowTitle: "private title",
                                                ocr: "private text", sourceURL: "https://example.test/private",
                                                documentName: "private.md")
        let saved = try store.insertScreenshot(ts: old, path: "", app: "Notes", windowTitle: "saved title", ocr: "saved text")
        try store.saveMoment(snapshotID: saved)
        XCTAssertTrue(store.insert(ActivityBlock(id: 0, app: "Notes", title: "old activity", start: old, end: old.addingTimeInterval(60))))
        XCTAssertTrue(store.insert(ActivityBlock(id: 0, app: "Notes", title: "new activity", start: now, end: now.addingTimeInterval(60))))
        let forever = try store.retentionReview(days: 7, keepTextForever: true, now: now)
        XCTAssertEqual(forever.metadataCount, 0)
        XCTAssertEqual(forever.activityTitles.count, 1, "Activity titles always follow the age window")
        let review = try store.retentionReview(days: 7, keepTextForever: false, now: now)
        XCTAssertEqual(review.metadataCount, 1)
        XCTAssertEqual(review.activityTitles.count, 1)
        let service = ScreenshotService(store: store, storage: storage, sampler: ActivitySampler(store: store),
                                        now: { now }, settings: { AppSettings() })
        XCTAssertTrue(try service.applyRetentionReview(review).isEmpty)
        let cleared = try XCTUnwrap(store.screenshotChecked(id: expired))
        XCTAssertEqual(cleared.windowTitle, "")
        XCTAssertEqual(cleared.sourceURL, "")
        XCTAssertEqual(cleared.documentName, "")
        XCTAssertNil(store.ocrText(snapshotID: expired))
        XCTAssertEqual(try store.screenshotChecked(id: saved)?.windowTitle, "saved title")
        XCTAssertEqual(store.blocks(in: DateInterval(start: old, end: now.addingTimeInterval(120))).map(\.title), ["", "new activity"])
    }

    func testFailedReadCannotBePresentedAsAnEmptyDeletionReview() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("invalid-review-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ActivityStore(databaseURL: directory)
        XCTAssertThrowsError(try store.captureDeletionReview(
            in: DateInterval(start: Date(), duration: 60), includesSaved: false))
    }

    func testManualCleanupReportsFailedRowAndPreservesSavedEvidence() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cleanup-partial-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = StorageManager(rootURL: root)
        let url = root.appendingPathComponent("activity.sqlite")
        let store = ActivityStore(databaseURL: url)
        let sampler = ActivitySampler(store: store, notificationCenter: NotificationCenter())
        let service = ScreenshotService(store: store, storage: storage, sampler: sampler, settings: { AppSettings() })
        let now = Date()
        let good = try store.insertScreenshot(ts: now, path: "", app: "Success", ocr: "remove")
        let failed = try store.insertScreenshot(ts: now, path: "", app: "Failed", ocr: "retry")
        let saved = try store.insertScreenshot(ts: now, path: "", app: "Saved", ocr: "keep")
        try store.saveMoment(snapshotID: saved)
        let database = try XCTUnwrap(SQLiteDatabase(url: url))
        XCTAssertTrue(database.exec("""
            CREATE TRIGGER fail_capture_cleanup BEFORE DELETE ON screenshots
            WHEN OLD.id = \(failed) BEGIN SELECT RAISE(ABORT, 'fixture failure'); END;
            """))
        let interval = DateInterval(start: now.addingTimeInterval(-1), duration: 2)
        let review = try store.captureDeletionReview(in: interval, includesSaved: false)
        XCTAssertEqual(try service.applyCaptureDeletionReview(review).count, 1)
        XCTAssertNil(try store.screenshotChecked(id: good))
        XCTAssertEqual(store.ocrText(snapshotID: failed), "retry")
        XCTAssertEqual(store.ocrText(snapshotID: saved), "keep")
        XCTAssertTrue(database.exec("DROP TRIGGER fail_capture_cleanup"))
        XCTAssertTrue(try service.applyCaptureDeletionReview(review).isEmpty)
        XCTAssertNil(try store.screenshotChecked(id: failed))
        XCTAssertEqual(store.ocrText(snapshotID: saved), "keep")
    }

    func testPreviewPreservesSavedMomentsAndDoesNotDeleteUntilApplied() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("retention-\(UUID()).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = ActivityStore(databaseURL: url)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let old = now.addingTimeInterval(-20 * 86_400)
        let expired = try store.insertScreenshot(ts: old, path: "", app: "Editor", ocr: "original text")
        let saved = try store.insertScreenshot(ts: old, path: "", app: "Editor", ocr: "saved text")
        try store.saveMoment(snapshotID: saved)
        let review = try store.retentionReview(days: 7, keepTextForever: false, now: now)
        XCTAssertEqual(review.candidates.map(\.id), [expired])
        XCTAssertEqual(review.textCount, 1)
        XCTAssertEqual(review.savedCount, 1)
        XCTAssertEqual(store.ocrText(snapshotID: expired), "original text")
        try store.clearRetainedText(ids: [expired, saved])
        XCTAssertNil(store.ocrText(snapshotID: expired))
        XCTAssertEqual(store.ocrText(snapshotID: saved), "saved text")
    }

    func testReviewRequiresApprovalWhenScopeExpandsAndAllowsNewBookmarks() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("retention-\(UUID()).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = ActivityStore(databaseURL: url)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let old = now.addingTimeInterval(-20 * 86_400)
        let first = try store.insertScreenshot(ts: old, path: "", app: "Editor", ocr: "first")
        let reviewed = try store.retentionReview(days: 7, keepTextForever: false, now: now)
        try store.saveMoment(snapshotID: first)
        XCTAssertTrue(reviewed.covers(try store.retentionReview(days: 7, keepTextForever: false, now: now)))
        _ = try store.insertScreenshot(ts: old, path: "", app: "Editor", ocr: "newly eligible")
        XCTAssertFalse(reviewed.covers(try store.retentionReview(days: 7, keepTextForever: false, now: now)))
    }
}
