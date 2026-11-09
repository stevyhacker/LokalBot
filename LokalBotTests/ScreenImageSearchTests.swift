import CoreGraphics
import DigUpKit
import SQLite3
import XCTest
@testable import LokalBot

/// Picture vectors for retained screen captures: what is embedded, that a
/// vector never outlives its pixels, and how text and picture vectors rank
/// together with the keyword hits.
@MainActor
final class ScreenImageSearchTests: XCTestCase {
    private var url: URL!
    private var store: ActivityStore!

    override func setUpWithError() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("ScreenImages-\(UUID().uuidString).sqlite")
        store = ActivityStore(databaseURL: url)
    }

    override func tearDownWithError() throws {
        store = nil
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: url.path + suffix)
        }
    }

    // MARK: - Embedding captures

    func testAPassEmbedsRetainedPicturesNewestFirstAndMarksBrokenOnes() async throws {
        let older = try insert(path: "/shots/older.heic.enc", minutesAgo: 30)
        let newer = try insert(path: "/shots/newer.heic.enc", minutesAgo: 5)
        _ = try insert(path: "", minutesAgo: 10, ocr: "text only, no pixels")
        let broken = try insert(path: "/shots/broken.heic.enc", minutesAgo: 1)
        let recorder = SessionRecorder()
        let images = makeImages(recorder: recorder)

        let outcome = await images.runPass()

        XCTAssertEqual(outcome, .finished(embedded: 2))
        XCTAssertEqual(images.embeddedCount(), 2)
        XCTAssertEqual(recorder.starts, 1)
        XCTAssertEqual(recorder.ends, 1)
        XCTAssertEqual(recorder.loaded, ["/shots/broken.heic.enc", "/shots/newer.heic.enc", "/shots/older.heic.enc"])
        XCTAssertEqual(try vectorBytes(for: broken), 0, "an unreadable capture is marked, not retried every pass")
        XCTAssertEqual(try vectorBytes(for: newer), ScreenImageEmbeddings.vectorBytes)
        XCTAssertEqual(try vectorBytes(for: older), ScreenImageEmbeddings.vectorBytes)

        let again = await images.runPass()
        XCTAssertEqual(again, .finished(embedded: 0))
        XCTAssertEqual(recorder.starts, 1, "nothing new never starts the image model")
    }

    func testOnBatteryAPassReadsTheNewestFewDozenAndLeavesTheRestForACharger() async throws {
        for minute in 0..<(ScreenImageEmbeddings.batteryLimit + 20) {
            try insert(path: "/shots/\(minute).heic.enc", minutesAgo: minute + 1)
        }
        let recorder = SessionRecorder()
        let images = makeImages(recorder: recorder)
        var onBattery = true
        images.isOnBattery = { onBattery }

        let outcome = await images.runPass()

        XCTAssertEqual(outcome, .waitingForPower(embedded: ScreenImageEmbeddings.batteryLimit))
        XCTAssertEqual(recorder.loaded.first, "/shots/0.heic.enc", "the newest captures go first")
        XCTAssertFalse(recorder.loaded.contains("/shots/\(ScreenImageEmbeddings.batteryLimit).heic.enc"))

        onBattery = false
        let plugged = await images.runPass()
        XCTAssertEqual(plugged, .finished(embedded: 20))
        XCTAssertEqual(images.embeddedCount(), ScreenImageEmbeddings.batteryLimit + 20)
    }

    func testAVectorLeavesWithItsPixels() async throws {
        let kept = try insert(path: "/shots/kept.heic.enc", minutesAgo: 3)
        let expiring = try insert(path: "/shots/expiring.heic.enc", minutesAgo: 2)
        let deleted = try insert(path: "/shots/deleted.heic.enc", minutesAgo: 1)
        let images = makeImages(recorder: SessionRecorder())
        _ = await images.runPass()
        XCTAssertEqual(images.embeddedCount(), 3)

        // Retention removes the file and clears the path; the row stays.
        try store.clearScreenshotPath("/shots/expiring.heic.enc")
        XCTAssertEqual(try vectorBytes(for: expiring), nil)
        // Deleting a moment deletes the row and everything made from it.
        try store.deleteScreenshot(id: deleted)
        XCTAssertEqual(try vectorBytes(for: deleted), nil)
        XCTAssertEqual(try vectorBytes(for: kept), ScreenImageEmbeddings.vectorBytes)
        XCTAssertEqual(images.embeddedCount(), 1)

        let again = await images.runPass()
        XCTAssertEqual(again, .finished(embedded: 0), "a capture without pixels is never embedded again")
    }

    func testAPassWaitsForRecordingsAndNeedsTheFeatureOnAndInUse() async throws {
        _ = try insert(path: "/shots/a.heic.enc", minutesAgo: 1)
        let recorder = SessionRecorder()
        let images = makeImages(recorder: recorder)

        images.pauseReason = { .recording }
        let paused = await images.runPass()
        XCTAssertEqual(paused, .paused)

        images.pauseReason = { nil }
        images.isInUse = { false }
        let unused = await images.runPass()
        XCTAssertEqual(unused, .skipped, "no download until screens are searched by meaning")

        images.isInUse = { true }
        images.isEnabled = { false }
        let off = await images.runPass()
        XCTAssertEqual(off, .skipped)
        XCTAssertEqual(recorder.starts, 0)
        XCTAssertEqual(images.embeddedCount(), 0)
    }

    func testAnEmbedderOutageLeavesCapturesPending() async throws {
        let id = try insert(path: "/shots/a.heic.enc", minutesAgo: 1)
        let recorder = SessionRecorder()
        recorder.failure = WorkerError.died("server stopped")
        let images = makeImages(recorder: recorder)

        guard case .failed = await images.runPass() else { return XCTFail("the pass should fail") }
        XCTAssertEqual(try vectorBytes(for: id), nil, "an outage marks nothing")

        recorder.failure = nil
        let retried = await images.runPass()
        XCTAssertEqual(retried, .finished(embedded: 1))
    }

    func testVectorsFromAnotherModelAreDropped() throws {
        let id = try insert(path: "/shots/a.heic.enc", minutesAgo: 1)
        _ = makeImages(recorder: SessionRecorder())
        let database = try XCTUnwrap(SQLiteDatabase(url: url))
        try database.runChecked(
            "INSERT INTO screen_image_embeddings (snapshot_id, vec, model_id) VALUES (?1, ?2, 'old-model')",
            bind: [id, ScreenImageEmbeddings.vectorData(Self.unit(0))])

        _ = makeImages(recorder: SessionRecorder())

        XCTAssertEqual(try vectorBytes(for: id), nil)
    }

    // MARK: - Meaning on one scale

    func testAPictureThatStandsOutWinsAndScopesApply() throws {
        _ = EmbeddingIndex(databaseURL: url, storage: StorageManager(rootURL: url.deletingLastPathComponent()),
                           embedder: EmbeddingIndex.unavailableEmbedder)
        _ = makeImages(recorder: SessionRecorder())
        let database = try XCTUnwrap(SQLiteDatabase(url: url))
        var ids: [Int64] = []
        for index in 0..<30 {
            let id = try insert(path: "/shots/\(index).heic.enc", minutesAgo: 60 - index,
                                app: index.isMultiple(of: 2) ? "Safari" : "Xcode", ocr: "capture \(index) text")
            ids.append(id)
            try database.runChecked("""
                INSERT INTO screen_embeddings (snapshot_id, ts, app, text, vec, model_id)
                VALUES (?1, ?2, 'x', ?3, ?4, ?5)
                """, bind: [id, Date().timeIntervalSince1970, "capture \(index) text",
                            ScreenImageEmbeddings.vectorData(Self.vector(cosine: 0.60 + Float(index % 3) * 0.002, axis: index + 1)),
                            EmbeddingIndex.indexVersion])
            let picture: Float = index == 7 ? 0.72 : 0.55 + Float(index % 3) * 0.002
            try database.runChecked(
                "INSERT INTO screen_image_embeddings (snapshot_id, vec, model_id) VALUES (?1, ?2, ?3)",
                bind: [id, ScreenImageEmbeddings.vectorData(Self.vector(cosine: picture, axis: index + 200)),
                       ScreenImageEmbeddings.modelID])
        }
        let reader = try XCTUnwrap(SQLiteDatabase(url: url, readOnly: true))
        let query = Self.unit(0)

        let all = EmbeddingIndex.screenMeanings(database: reader, queryVector: query, filter: .all)
        let best = try XCTUnwrap(all.max { $0.value.meaning.z < $1.value.meaning.z })
        XCTAssertEqual(best.key, ids[7], "0.72 is ordinary for text but far above the other pictures")
        XCTAssertEqual(best.value.meaning.modality, .image)
        XCTAssertGreaterThanOrEqual(best.value.meaning.z, ScreenSearchRanking.zGate)
        XCTAssertEqual(all.count, 30)
        XCTAssertNotNil(all[ids[0]]?.text)

        let xcode = EmbeddingIndex.screenMeanings(database: reader, queryVector: query,
                                                  filter: ScreenSearchFilter(interval: nil, app: "xcode"))
        XCTAssertEqual(xcode.count, 15)
        XCTAssertEqual(xcode[ids[7]]?.meaning.z, all[ids[7]]?.meaning.z, "a filter never changes the scale")
        var pinned = ScreenSearchFilter.all
        pinned.snapshotIDs = [ids[3]]
        XCTAssertEqual(Array(EmbeddingIndex.screenMeanings(database: reader, queryVector: query, filter: pinned).keys),
                       [ids[3]])

        try store.clearScreenshotPath("/shots/7.heic.enc")
        let afterRetention = EmbeddingIndex.screenMeanings(database: reader, queryVector: query, filter: .all)
        XCTAssertEqual(afterRetention[ids[7]]?.meaning.modality, .text, "the picture vector left with the pixels")
    }

    // MARK: - Ranking with keyword hits

    func testKeywordHitsAndPictureMatchesRankTogether() throws {
        let titled = try insert(path: "/shots/a.heic.enc", minutesAgo: 2, windowTitle: "Checkout — Stripe")
        let worded = try insert(path: "/shots/b.heic.enc", minutesAgo: 1, ocr: "payment declined error on checkout")
        let now = Date()
        let keyword = [
            ActivityStore.OCRHit(snapshotID: worded, ts: now, app: "Safari", snippet: "«payment» «declined» «error»"),
            ActivityStore.OCRHit(snapshotID: 99, ts: now, app: "Mail", snippet: "an «error» digest"),
        ]
        let coverage = ScreenSearch.coverage(query: "payment declined error", hits: keyword, matchedAll: false) { id in
            id == 99 ? "weekly error digest" : "payment declined error on checkout"
        }
        XCTAssertEqual(coverage[worded], 1)
        XCTAssertEqual(coverage[99] ?? 0, 1.0 / 3.0, accuracy: 1e-9)
        XCTAssertEqual(ScreenSearch.coverage(query: "the", hits: keyword, matchedAll: false) { _ in nil }[worded], 0.5)

        let meanings: [Int64: EmbeddingIndex.ScreenMeaningMatch] = [
            titled: .init(meaning: .init(z: 3.1, cosine: 0.7, modality: .image), ts: now, app: "Safari", text: nil),
        ]
        let ranked = ScreenSearch.ranked(query: "payment declined error", keyword: keyword, coverage: coverage,
                                         meanings: meanings, limit: 10) { [store] in store?.screenshot(id: $0) }

        XCTAssertEqual(ranked.map(\.snapshotID), [titled, worded],
                       "the picture match stands out; one word of three no longer qualifies")
        XCTAssertTrue(ranked[0].isSemantic)
        XCTAssertEqual(ranked[0].snippet, "Checkout — Stripe", "a picture match without text shows its window")
        XCTAssertFalse(ranked[1].isSemantic)
    }

    // MARK: - Helpers

    private func makeImages(recorder: SessionRecorder) -> ScreenImageEmbeddings {
        let images = ScreenImageEmbeddings(
            databaseURL: url,
            startSession: {
                recorder.starts += 1
                return .init(embed: { _ in try recorder.embed() }, end: { await MainActor.run { recorder.ends += 1 } })
            },
            makeLoader: {
                { path in
                    recorder.record(path)
                    return path.contains("broken") ? nil : Self.picture()
                }
            })
        images.isEnabled = { true }
        images.isInUse = { true }
        return images
    }

    @discardableResult
    private func insert(path: String, minutesAgo: Int, app: String = "Safari", windowTitle: String = "",
                        ocr: String = "") throws -> Int64 {
        try store.insertScreenshot(ts: Date().addingTimeInterval(TimeInterval(-60 * minutesAgo)), path: path,
                                   app: app, windowTitle: windowTitle, ocr: ocr)
    }

    private func vectorBytes(for id: Int64) throws -> Int? {
        let database = try XCTUnwrap(SQLiteDatabase(url: url, readOnly: true))
        return database.query("SELECT length(vec) FROM screen_image_embeddings WHERE snapshot_id = ?1",
                              bind: [id]) { Int(sqlite3_column_int64($0, 0)) }.first
    }

    nonisolated private static func unit(_ axis: Int) -> [Float] {
        (0..<768).map { $0 == axis ? 1 : 0 }
    }

    /// A unit vector at exactly `cosine` to axis 0.
    nonisolated private static func vector(cosine: Float, axis: Int) -> [Float] {
        var vector = [Float](repeating: 0, count: 768)
        vector[0] = cosine
        vector[axis % 767 + 1] = (1 - cosine * cosine).squareRoot()
        return vector
    }

    nonisolated private static func picture() -> CGImage? {
        let width = 400, height = 300
        let rgb = Data((0..<(width * height * 3)).map { UInt8($0 % 251) })
        guard let provider = CGDataProvider(data: rgb as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 24, bytesPerRow: width * 3,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

/// Counts sessions and what the loader read; can make the embedder fail.
private final class SessionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    var starts = 0
    var ends = 0
    private var paths: [String] = []
    private var storedFailure: Error?

    var failure: Error? {
        get { lock.withLock { storedFailure } }
        set { lock.withLock { storedFailure = newValue } }
    }

    var loaded: [String] { lock.withLock { paths } }

    func record(_ path: String) { lock.withLock { paths.append(path) } }

    func embed() throws -> [Float] {
        if let failure { throw failure }
        return (0..<768).map { $0 == 0 ? 1 : 0 }
    }
}
