import XCTest
@testable import LokalBot

/// The day-in-the-life run seeds its library with `Scripts/seed_demo_library.py`.
/// Reading that seed through the app's own stores keeps the script's schema in
/// step with the app, so a drift fails here instead of in the slower workday job.
final class SeedLibraryCompatibilityTests: XCTestCase {
    func testFullDaySeedIsReadableByTheAppStores() throws {
        // A copy of Scripts/seed_demo_library.py; see project.yml.
        let script = try XCTUnwrap(Bundle(for: Self.self).url(
            forResource: "seed_demo_library", withExtension: "py"))
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("seed-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let seed = Process()
        seed.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        seed.arguments = ["python3", script.path, "--profile", "full-day", "--day", "2026-08-04", root.path]
        seed.standardOutput = FileHandle.nullDevice
        try seed.run()
        seed.waitUntilExit()
        XCTAssertEqual(seed.terminationStatus, 0)

        let store = ActivityStore(databaseURL: DiagnosticsPaths.database(root: root))
        XCTAssertTrue(store.searchOCR("connection pool").contains { $0.app == "Terminal" },
                      "seeded screen text must be found by the app's screen search")
        let meetings = try SessionLookup.loadAllMeetings(root: root)
        XCTAssertEqual(Set(meetings.map(\.title)), ["Design review", "Sprint planning"])
    }
}
