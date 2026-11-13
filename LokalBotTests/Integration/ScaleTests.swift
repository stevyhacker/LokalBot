import XCTest
@testable import LokalBot

/// Nightly only (`LOKALBOT_SCALE_LIBRARY` points at a copy of the `large`
/// seed profile). Budgets reflect what a user notices at launch.
@MainActor
final class ScaleTests: XCTestCase {
    private func library() throws -> URL {
        guard let path = ProcessInfo.processInfo.environment["LOKALBOT_SCALE_LIBRARY"], !path.isEmpty else {
            throw XCTSkip("Set LOKALBOT_SCALE_LIBRARY to a large seeded library")
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    func testLargeLibraryLoadsAndIndexesWithinBudget() throws {
        let root = try library()
        let started = Date()
        let storage = StorageManager(rootURL: root)
        let meetings = storage.loadMeetings()
        SearchIndex(databaseURL: root.appendingPathComponent("lokalbotv3.sqlite")).reindexAll(meetings, storage: storage)
        XCTAssertEqual(meetings.count, 200)
        XCTAssertLessThan(Date().timeIntervalSince(started), 10, "library load and index at launch")
    }

    func testStartupRetentionSweepDoesNotBlockTheMainThread() throws {
        let root = try library()
        let store = ActivityStore(databaseURL: root.appendingPathComponent("lokalbotv3.sqlite"))
        var settings = AppSettings()
        settings.retentionDays = 14
        let service = ScreenshotService(store: store, storage: StorageManager(rootURL: root),
                                        sampler: ActivitySampler(store: store), settings: { settings })
        let started = Date()
        _ = service.runRetentionMaintenanceIfNeeded(force: true)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1,
                          "the startup retention sweep runs on the main thread; over 1 s is a visible hang")
    }
}
