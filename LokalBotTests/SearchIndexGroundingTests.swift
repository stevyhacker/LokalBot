import XCTest
@testable import LokalBot

final class SearchIndexGroundingTests: XCTestCase {
    func testSemanticChunkHydratesEveryWholeSourceAcrossTimeGapsOnlyWhenPresent() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("search-grounding-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = StorageManager(rootURL: root)
        let meeting = Meeting(id: UUID(), title: "Synthetic multilingual review", appName: "Synthetic",
            startedAt: Date(timeIntervalSince1970: 1_000), endedAt: Date(timeIntervalSince1970: 2_000), relativePath: "meeting")
        let folder = meeting.folderURL(in: storage)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let first = "Први договор је забележен."
        let second = "За проверу је одговорна Нада, до 6. децембра."
        let omitted = "This separate source must not appear just because it belongs to the meeting."
        let transcript = Transcript(segments: [
            .init(start: 10, end: 20, speaker: "person", text: first, confidence: nil),
            .init(start: 400, end: 410, speaker: "person", text: second, confidence: nil),
            .init(start: 440, end: 450, speaker: "person", text: omitted, confidence: nil),
        ], engine: "synthetic")
        try JSONEncoder().encode(transcript).write(to: folder.appendingPathComponent("transcript.json"))
        let index = SearchIndex(databaseURL: root.appendingPathComponent("search.sqlite"))
        index.reindexAll([meeting], storage: storage)
        let hits = index.semanticSourcePassages(meetingID: meeting.id, start: 10,
                                                text: "Person: \(first)\nPerson: \(second)")
        XCTAssertEqual(hits.map(\.start), [10, 400])
        XCTAssertEqual(hits.compactMap(\.sourceText), [first, second])
        XCTAssertFalse(hits.contains { $0.sourceText == omitted })
    }
    func testSharedPrefixesAndDuplicateBodiesPreserveEverySpeakerAndCorrection() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("search-provenance-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = StorageManager(rootURL: root)
        let meeting = Meeting(id: UUID(), title: "Synthetic provenance", appName: "Synthetic",
            startedAt: Date(timeIntervalSince1970: 1_000), endedAt: Date(timeIntervalSince1970: 2_000), relativePath: "meeting")
        let folder = meeting.folderURL(in: storage)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let prefix = "This source repeats a sufficiently long opening phrase for an exact provenance regression. "
        let rows: [(Double, String, String)] = [
            (10, "ana", prefix + "Migration completed."),
            (30, "jelena", prefix + "Migration has not completed."),
            (50, "ana", "I own the review."), (70, "jelena", "I own the review."),
            (90, "ana", prefix + "First ending."), (90, "jelena", prefix + "Another ending.")]
        let transcript = Transcript(segments: rows.map {
            .init(start: $0.0, end: $0.0 + 5, speaker: $0.1, text: $0.2, confidence: nil)
        }, engine: "synthetic")
        try JSONEncoder().encode(transcript).write(to: folder.appendingPathComponent("transcript.json"))
        let index = SearchIndex(databaseURL: root.appendingPathComponent("search.sqlite"))
        index.reindexAll([meeting], storage: storage)
        let text = rows.prefix(4).map { "\(transcript.displaySpeaker(for: $0.1)): \($0.2)" }.joined(separator: "\n")
        let hits = index.semanticSourcePassages(meetingID: meeting.id, start: 10, text: text)
        XCTAssertEqual(hits.map(\.start), [10, 30, 50, 70])
        XCTAssertEqual(hits.compactMap(\.sourceText), rows.prefix(4).map { $0.2 })
        XCTAssertEqual(hits.map(\.speaker), rows.prefix(4).map { transcript.displaySpeaker(for: $0.1) })
        XCTAssertTrue(index.semanticSourcePassages(meetingID: meeting.id, start: 90, text: prefix).isEmpty)
        let truncated = "\(transcript.displaySpeaker(for: rows[0].1)): \(rows[0].2)\n"
            + "\(transcript.displaySpeaker(for: rows[1].1)): \(prefix)"
        XCTAssertTrue(index.semanticSourcePassages(meetingID: meeting.id, start: 10, text: truncated).isEmpty)
        XCTAssertEqual(index.semanticSourcePassages(meetingID: meeting.id, start: 30,
            text: "Migration has not completed.").map(\.start), [30])
    }

}
