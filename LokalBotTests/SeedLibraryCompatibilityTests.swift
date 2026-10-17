import CryptoKit
import XCTest
@testable import LokalBot

/// The day-in-the-life run seeds its library with `Scripts/seed_demo_library.py`.
/// Reading that seed through the app's own stores keeps the script's schema in
/// step with the app, so a drift fails here instead of in the slower workday job.
final class SeedLibraryCompatibilityTests: XCTestCase {
    func testFullDaySeedIsReadableByTheAppStores() throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let script = repository.appendingPathComponent("Scripts/seed_demo_library.py")
        guard FileManager.default.fileExists(atPath: script.path) else {
            throw XCTSkip("the repository checkout is not available to this test run")
        }
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

    /// The demo seed is also what upgrade fixtures are made from, so its About
    /// you file must decode with every origin the app stores.
    @MainActor
    func testDemoSeedAboutYouIsReadableByThePersonalModel() throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let script = repository.appendingPathComponent("Scripts/seed_demo_library.py")
        guard FileManager.default.fileExists(atPath: script.path) else {
            throw XCTSkip("the repository checkout is not available to this test run")
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("seed-about-you-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let seed = Process()
        seed.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        seed.arguments = ["python3", script.path, root.path]
        seed.standardOutput = FileHandle.nullDevice
        try seed.run()
        seed.waitUntilExit()
        XCTAssertEqual(seed.terminationStatus, 0)

        let store = PersonalModelStore(root: root, encryptionKey: { SymmetricKey(size: .bits256) })
        let model = try store.load()
        XCTAssertEqual(model.claims.count, 6)
        XCTAssertEqual(model.tombstones.count, 1)
        XCTAssertEqual(model.workSightings.count, 1)
        var origins: [String] = []
        for claim in model.claims {
            switch claim.origin {
            case .added: origins.append("added")
            case .said: origins.append("said")
            case .learned: origins.append("learned")
            case .typed(.codingAgent, _): origins.append("typed")
            case .typed(.ask, _): origins.append("typed-ask")
            case .typed(.dictation, _): origins.append("typed-dictation")
            case .workMemory: origins.append("workMemory")
            }
        }
        XCTAssertEqual(origins, ["added", "said", "learned", "typed", "typed-dictation", "workMemory"])

        let controller = PersonalModelController(store: store)
        XCTAssertEqual(controller.usableClaims().count, 3)
        XCTAssertEqual(controller.suggestions.count, 3)
    }
}
