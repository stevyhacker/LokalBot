import AppKit
import XCTest
@testable import LokalBot

// MARK: - Recommended cotyping model preparation

final class CotypingModelPreparationTests: XCTestCase {
    func testStatusPrefersDownloadProgressOverMissing() throws {
        let entry = ModelCatalog.entry(id: ModelCatalog.recommendedCotypingID)
        let status = CotypingModelPreparer.status(
            for: entry,
            localURL: nil,
            progress: 0.42,
            error: nil)

        XCTAssertEqual(status, .downloading(try XCTUnwrap(entry), 0.42))
        XCTAssertTrue(status.isDownloading)
    }

    func testReadyWhenLocalURLExists() throws {
        let entry = try XCTUnwrap(ModelCatalog.entry(id: ModelCatalog.recommendedCotypingID))
        let status = CotypingModelPreparer.status(
            for: entry,
            localURL: URL(fileURLWithPath: "/tmp/model.gguf"),
            progress: nil,
            error: nil)

        XCTAssertEqual(status, .ready(entry))
    }

    func testRecommendedActiveTracksModelID() {
        var settings = AppSettings()
        // Cotyping always runs its own model; the recommended model id is the default.
        XCTAssertTrue(CotypingModelPreparer.recommendedIsActive(settings: settings))
        settings.cotypingBuiltInModelID = ModelCatalog.compactFallbackID
        XCTAssertFalse(CotypingModelPreparer.recommendedIsActive(settings: settings))
    }

    func testPrepareActionDownloadsBeforeActivatingMissingModel() {
        XCTAssertEqual(CotypingModelPreparer.action(localURL: nil, isDownloading: false), .download)
        XCTAssertEqual(CotypingModelPreparer.action(localURL: nil, isDownloading: true), .wait)
        XCTAssertEqual(
            CotypingModelPreparer.action(localURL: URL(fileURLWithPath: "/tmp/model.gguf"), isDownloading: false),
            .activate)
    }
}
