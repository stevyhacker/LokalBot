import AppKit
import SQLite3
import XCTest
import Combine
@testable import LokalBot

@MainActor
final class PerformanceReadPathTests: XCTestCase {
    func testPlaybackTicksDoNotInvalidateTheWorkspacePlayer() {
        let player = MeetingPlayer()
        var workspaceUpdates = 0
        var clockUpdates = 0
        let workspace = player.objectWillChange.sink { workspaceUpdates += 1 }
        let clock = player.clock.$currentTime.dropFirst().sink { _ in clockUpdates += 1 }
        for tick in 1...240 { player.clock.update(to: Double(tick) / 4) }
        player.clock.update(to: 60)
        XCTAssertEqual(player.currentTime, 60)
        XCTAssertEqual(clockUpdates, 240)
        XCTAssertEqual(workspaceUpdates, 0, "Playback time must not rebuild the meeting detail")
        withExtendedLifetime((workspace, clock)) {}
        player.stop()
        XCTAssertEqual(player.currentTime, 0)
    }

    func testLongTranscriptNamePreparationBenchmark() {
        let transcript = Transcript(segments: (0..<5_000).map {
            .init(start: Double($0), end: Double($0 + 1), speaker: "them \($0 % 20)", text: "An update.")
        }, engine: "test")
        let keys = (0..<20).map { "them \($0)" }
        let start = Date()
        // The presentation adds display-only names ("Them 3" → "Speaker 3").
        let previousNames = keys.map { SpeakerDisplayName.label(transcript.displaySpeaker(for: $0)) }
        let previousSeconds = Date().timeIntervalSince(start)
        let cachedStart = Date()
        let presentation = MeetingSpeakerPresentation(transcript: transcript)
        let cachedNames = keys.map { presentation.speaker($0, in: transcript) }
        let cachedSeconds = Date().timeIntervalSince(cachedStart)
        XCTAssertEqual(previousNames, cachedNames)
        print("TRANSCRIPT_BENCHMARK rows=5000 speakers=20 repeatedScans=\(previousSeconds)s singleRoster=\(cachedSeconds)s")
    }

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

    func testRetainedTextCleanupBatchesIndexedRowsAndPreservesSavedEvidence() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("library.sqlite")
        let store = ActivityStore(databaseURL: url)
        var expired: [Int64] = []
        for index in 0..<405 {
            expired.append(try store.insertScreenshot(
                ts: Date(), path: "", app: "Notes",
                windowTitle: "Expired \(index)", ocr: "private text \(index)",
                sourceURL: "https://example.test/\(index)", documentName: "\(index).md"))
        }
        let saved = try store.insertScreenshot(
            ts: Date(), path: "", app: "Notes", windowTitle: "Saved",
            ocr: "saved private text", sourceURL: "https://example.test/saved",
            documentName: "saved.md")
        try store.saveMoment(snapshotID: saved)

        try store.clearRetainedText(ids: expired + [saved, expired[0], 0, -1])

        let database = try XCTUnwrap(SQLiteDatabase(url: url, readOnly: true))
        XCTAssertEqual(database.firstDouble("SELECT COUNT(*) FROM ocr_metadata"), 1)
        XCTAssertEqual(database.firstDouble("SELECT COUNT(*) FROM ocr_fts"), 1)
        XCTAssertNil(store.ocrText(snapshotID: expired[0]))
        XCTAssertEqual(store.ocrText(snapshotID: saved), "saved private text")
        XCTAssertEqual(try store.screenshotChecked(id: expired[404])?.windowTitle, "")
        XCTAssertEqual(try store.screenshotChecked(id: saved)?.windowTitle, "Saved")
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

    /// Meet detection polls every 2 s. A browser window whose complete read
    /// found no Meet document is walked again only when its title changes or
    /// the entry ages out: 2 walks a minute instead of 30.
    func testQuietBrowserWindowIsWalkedAgainOnlyOnTitleChangeOrAge() {
        let cache = BrowserMeetingSession.QuietWindowCache()
        let window = AXUIElementCreateApplication(90_001)
        let other = AXUIElementCreateApplication(90_002)
        let pid: pid_t = 4_242
        var walks: [TimeInterval] = []
        for tick in stride(from: 0.0, to: 60, by: 2) where !cache.isQuiet(window, title: "Inbox", processID: pid, now: tick) {
            walks.append(tick)
            cache.record(window, title: "Inbox", quiet: true, processID: pid, now: tick)
        }
        XCTAssertEqual(walks, [0, BrowserMeetingSession.QuietWindowCache.maximumAge])
        print("MEET_DETECTION_BENCHMARK walksPerWindowMinute before=30 after=\(walks.count)")

        XCTAssertFalse(cache.isQuiet(window, title: "Meet - abc-defg-hij", processID: pid, now: 32))
        XCTAssertFalse(cache.isQuiet(other, title: "Inbox", processID: pid, now: 32))
        XCTAssertFalse(cache.isQuiet(window, title: "Inbox", processID: pid + 1, now: 32))
        // A read that found Meet, or could not finish, is never remembered.
        cache.record(window, title: "Inbox", quiet: false, processID: pid, now: 32)
        XCTAssertFalse(cache.isQuiet(window, title: "Inbox", processID: pid, now: 34))
        // A closed window is forgotten.
        cache.record(other, title: "Docs", quiet: true, processID: pid, now: 34)
        cache.keep(only: [window], processID: pid)
        XCTAssertFalse(cache.isQuiet(other, title: "Docs", processID: pid, now: 36))
        // Microphone changes (a call starting) clear everything.
        cache.record(window, title: "Inbox", quiet: true, processID: pid, now: 36)
        cache.removeAll()
        XCTAssertFalse(cache.isQuiet(window, title: "Inbox", processID: pid, now: 38))
    }

    /// Activity samples (every 5 s) need a page address only to apply site
    /// exclusions; without any, the sampler reads the window, not its pages.
    @MainActor
    func testActivitySamplesWalkPagesOnlyWhenSitesAreExcluded() async throws {
        struct Workspace: WorkspaceSource {
            func frontmostApplication() -> RunningApp? {
                RunningApp(processIdentifier: 77, bundleIdentifier: "com.example.browser", localizedName: "Browser")
            }
            func runningApplications() -> [RunningApp] { [frontmostApplication()!] }
            func isRunning(processID: pid_t) -> Bool { processID == 77 }
            func secondsSinceLastInput() -> TimeInterval { 1 }
        }
        final class Counter: @unchecked Sendable {
            private let lock = NSLock()
            private var counts: [String: Int] = [:]
            func add(_ key: String) { lock.withLock { counts[key, default: 0] += 1 } }
            func count(_ key: String) -> Int { lock.withLock { counts[key, default: 0] } }
        }
        var environment = CaptureEnvironment.live
        environment.workspace = Workspace()
        CaptureEnvironment.install(environment)
        defer { CaptureEnvironment.reset() }
        let counter = Counter()
        func reader(_ name: String, title: String) -> ScreenAccessibilityReader {
            ScreenAccessibilityReader { _ in
                counter.add(name)
                return ScreenAccessibilitySnapshot(text: "", sourceURL: "https://example.com/a", documentName: nil,
                                                   focusedSecureField: false, windowTitle: title, windowFrame: nil)
            }
        }
        let database = FileManager.default.temporaryDirectory.appendingPathComponent("sampler-\(UUID()).sqlite")
        defer { try? FileManager.default.removeItem(at: database) }
        let sampler = ActivitySampler(store: ActivityStore(databaseURL: database), notificationCenter: NotificationCenter(),
                                      accessibilityReader: reader("pages", title: "Page"),
                                      windowReader: reader("window", title: "Window"))
        for _ in 0..<3 { await sampler.sample() }
        XCTAssertEqual(counter.count("window"), 3)
        XCTAssertEqual(counter.count("pages"), 0)
        sampler.excludedDomains = { ["example.com"] }
        await sampler.sample()
        XCTAssertEqual(counter.count("pages"), 1)
        XCTAssertEqual(sampler.currentApp, "Private", "the excluded site still keeps its exclusion")
    }

    /// Daily retention clears one expired capture's path at a time on the main
    /// actor; each clear must use the partial path index, not scan every row.
    func testRetentionPathClearUsesThePathIndex() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("library.sqlite")
        let store = ActivityStore(databaseURL: url)
        let kept = try store.insertScreenshot(ts: Date(), path: "/tmp/kept.heic.enc", app: "Notes", ocr: "")
        let expired = try store.insertScreenshot(ts: Date(), path: "/tmp/expired.heic.enc", app: "Notes", ocr: "")
        try store.clearScreenshotPath("/tmp/expired.heic.enc")
        XCTAssertEqual(store.screenshot(id: expired)?.path, "")
        XCTAssertEqual(store.screenshot(id: kept)?.path, "/tmp/kept.heic.enc")
        let database = try XCTUnwrap(SQLiteDatabase(url: url, readOnly: true))
        let plan = database.query("EXPLAIN QUERY PLAN UPDATE screenshots SET path = '' WHERE path = ?1 AND path != ''",
                                  bind: ["/tmp/kept.heic.enc"]) { sqlite3_column_text($0, 3).map { String(cString: $0) } }
        XCTAssertTrue(plan.contains { $0.contains("idx_screenshot_path") }, "\(plan)")
    }
}
