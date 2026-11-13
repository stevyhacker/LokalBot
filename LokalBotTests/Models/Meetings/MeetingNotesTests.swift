import XCTest
@testable import LokalBot

final class MeetingNotesTests: XCTestCase {

    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-notes-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func testRoundTrip() {
        MeetingNotes.write("- ship the beta\n- ping Ana", to: folder)
        XCTAssertEqual(MeetingNotes.load(from: folder), "- ship the beta\n- ping Ana")
    }

    func testMissingFileLoadsNil() {
        XCTAssertNil(MeetingNotes.load(from: folder))
    }

    func testBlankTextRemovesTheFile() {
        MeetingNotes.write("something", to: folder)
        MeetingNotes.write("   \n\t ", to: folder)
        XCTAssertNil(MeetingNotes.load(from: folder))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: folder.appendingPathComponent(MeetingNotes.fileName).path))
    }

    func testPromptContextEmptyWithoutNotes() {
        XCTAssertEqual(MeetingNotes.promptContext(in: folder), [])
    }

    func testPromptContextCarriesTheNotes() {
        MeetingNotes.write("decision: go with plan B", to: folder)
        let context = MeetingNotes.promptContext(in: folder)
        XCTAssertEqual(context.count, 1)
        XCTAssertTrue(context[0].contains("decision: go with plan B"))
        XCTAssertTrue(context[0].contains("Notes the user typed"))
    }
}
