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

    /// Nightly scale check 2026-10-01: the startup sweep blocked the main
    /// thread for 2.3 s on a 180-day library, in part by handing evidence
    /// revocation one date per row (101,521 for 166 days).
    func testScheduledSweepRevokesEachDayOnceRatherThanEachRow() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sweep-days-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = StorageManager(rootURL: root)
        let store = ActivityStore(databaseURL: root.appendingPathComponent("activity.sqlite"))
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let calendar = Calendar.current
        let days = (20..<23).map { calendar.startOfDay(for: now.addingTimeInterval(-Double($0) * 86_400)) }
        var saved: Int64 = 0
        for day in days {
            for minute in 0..<40 {
                let ts = day.addingTimeInterval(Double(9 * 3_600 + minute * 60))
                saved = try store.insertScreenshot(ts: ts, path: "", app: "Notes", windowTitle: "title \(minute)", ocr: "text")
                XCTAssertTrue(store.insert(ActivityBlock(id: 0, app: "Notes", title: "block \(minute)",
                                                         start: ts, end: ts.addingTimeInterval(30))))
            }
        }
        try store.saveMoment(snapshotID: saved)
        var settings = AppSettings()
        settings.retentionDays = 14
        let service = ScreenshotService(store: store, storage: storage,
                                        sampler: ActivitySampler(store: store), now: { now }, settings: { settings })
        var revoked: [Date] = []
        service.mutateEvidence = { dates, mutation in
            revoked = dates
            try mutation()
        }
        XCTAssertTrue(service.runRetentionMaintenanceIfNeeded(force: true))
        XCTAssertEqual(Set(revoked.map { calendar.startOfDay(for: $0) }), Set(days))
        XCTAssertLessThanOrEqual(revoked.count, 2 * days.count, "one date per local and UTC day, not per row")
        XCTAssertNil(service.lastRetentionError)
        XCTAssertEqual(try store.screenshotChecked(id: saved)?.windowTitle, "title 39", "saved moments survive")
        XCTAssertEqual(try store.screenshotChecked(id: saved - 1)?.windowTitle, "")
    }

    func testDistinctEvidenceDaysInvalidateTheSameLocalAndUTCDays() throws {
        let base = Date(timeIntervalSince1970: 1_772_323_200) // 2026-03-01 00:00 UTC
        var stamps: [Date] = []
        for day in 0..<12 {
            for hour in [0.0, 0.5, 4.75, 11.9, 12.1, 19.5, 23.5, 23.99] {
                stamps.append(base.addingTimeInterval(Double(day) * 86_400 + hour * 3_600))
            }
        }
        let candidates = stamps.enumerated().map { index, stamp in
            RetentionReview.Candidate(id: Int64(index + 1), timestamp: stamp, path: "", removeText: true, removeVector: false)
        }
        let titles = stamps.enumerated().map { index, stamp in
            // Every fifth block runs for 30 hours and crosses local midnights.
            RetentionReview.ActivityTitle(id: Int64(index + 1), start: stamp,
                                          end: stamp.addingTimeInterval(index % 5 == 0 ? 30 * 3_600 : 90), title: "t")
        }
        let review = RetentionReview(days: 14, keepTextForever: false, reviewedAt: base, candidates: candidates,
                                     savedCount: 0, bytes: 0, activityTitles: titles,
                                     codingAgentBursts: [.init(id: "burst", start: stamps[7])])
        let extra = [base.addingTimeInterval(-3_600)]
        for identifier in ["America/New_York", "Asia/Kolkata", "Pacific/Kiritimati", "UTC"] {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = try XCTUnwrap(TimeZone(identifier: identifier))
            let full = candidates.map(\.timestamp) + titles.flatMap { $0.evidenceDates(calendar: calendar) }
                + review.codingAgentBursts.map(\.start) + extra
            let reduced = review.distinctEvidenceDays(adding: extra, calendar: calendar)
            XCTAssertLessThan(reduced.count, full.count, identifier)
            XCTAssertTrue(Set(reduced).isSubset(of: Set(full)), identifier)
            XCTAssertEqual(Set(reduced.map { calendar.startOfDay(for: $0) }),
                           Set(full.map { calendar.startOfDay(for: $0) }), identifier)
            XCTAssertEqual(DreamEvidenceInvalidation.sourceDayKeys(for: reduced),
                           DreamEvidenceInvalidation.sourceDayKeys(for: full), identifier)
            XCTAssertEqual(reduced, reduced.sorted(), identifier)
        }
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
