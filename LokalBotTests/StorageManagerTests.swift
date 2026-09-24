import XCTest
@testable import LokalBot

final class StorageManagerTests: XCTestCase {
    func testDeleteMeetingRemovesDurableFolder() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StorageManagerTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = StorageManager(rootURL: root)
        let meeting = try storage.createMeetingFolder(title: "Delete me", appName: "Tests")
        let folder = meeting.folderURL(in: storage)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))

        try storage.deleteMeeting(meeting)

        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    }

    func testDeleteMeetingSurfacesFilesystemFailure() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StorageManagerTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = StorageManager(rootURL: root)
        let missing = Meeting(
            id: UUID(), title: "Already gone", appName: "Tests",
            startedAt: Date(), endedAt: Date(), relativePath: "meetings/missing")

        XCTAssertThrowsError(try storage.deleteMeeting(missing))
    }

    func testDeleteMeetingDoesNotRemoveSourceWhenRevocationIntentCannotBeSaved() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StorageManagerTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = StorageManager(rootURL: root)
        let meeting = try storage.createMeetingFolder(title: "Retain source", appName: "Tests")
        let folder = meeting.folderURL(in: storage)
        let metadata = try Data(contentsOf: folder.appendingPathComponent("meta.json"))
        // A directory at the intent-file path deterministically rejects the
        // write without changing real filesystem permissions or user data.
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".dream-revocation-pending.json"),
            withIntermediateDirectories: true)

        XCTAssertThrowsError(try storage.deleteMeeting(meeting))
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("meta.json")), metadata)
    }

    func testSourceDayRetractionCoversTimezoneChangesAndDayOnlyInputs() throws {
        let date = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-24T10:00:00Z"))
        // This instant can represent a +14 timezone's Sep 25 midnight. Its
        // day's later evidence can belong to Sep 26 after changing timezone.
        let keys = DreamEvidenceInvalidation.sourceDayKeys(for: [date])
        XCTAssertTrue(keys.contains("2026-09-23"))
        XCTAssertTrue(keys.contains("2026-09-25"))
        XCTAssertTrue(keys.contains("2026-09-26"))
    }
}
