import XCTest
@testable import LokalBot

final class RecallPassageTests: XCTestCase {
    func testDropsMalformedSpeechButKeepsSubstantivePassages() {
        for text in [String(repeating: "uh, ", count: 40), String(repeating: "j- ", count: 40),
                     String(repeating: "Sibitoula, ", count: 40), "Okay.", "Yes."] {
            XCTAssertNil(RecallPassage.excerpt(text, query: "redemption"))
        }
        XCTAssertEqual(RecallPassage.excerpt("The redemption queue is ready for review.", query: "redemption"),
                       "The redemption queue is ready for review.")
    }

    func testExcerptFindsQueryBeyondMetadataAndTheOldTruncatedPrefix() throws {
        let text = "# Weekly sync\n**Duration:** 45m · **App:** Meet · **Model:** Local\n## Summary\n"
            + String(repeating: "Other release details. ", count: 40)
            + "\n- [ ] Review the **redemption** queue with [Ana](https://example.invalid)."
        let excerpt = try XCTUnwrap(RecallPassage.excerpt(text, query: "redemption"))
        XCTAssertEqual(excerpt, "Review the redemption queue with Ana.")
        XCTAssertFalse(excerpt.contains("Model"))
        XCTAssertFalse(excerpt.contains("**"))
    }

    func testCodeIdentifiersAndKeywordHighlightSurviveCleaning() {
        XCTAssertEqual(RecallPassage.excerpt("Review `redemption_queue` and the «redemption» status.", query: "redemption"),
                       "Review redemption_queue and the «redemption» status.")
    }

    func testLongLineCentersOnMatchAndRetainsHighlight() throws {
        let text = String(repeating: "Earlier unrelated details. ", count: 30)
            + "Please review the «redemption» queue. " + String(repeating: "Later details. ", count: 30)
        let excerpt = try XCTUnwrap(RecallPassage.excerpt(text, query: "redemption"))
        XCTAssertTrue(excerpt.contains("«redemption»"))
        XCTAssertLessThanOrEqual(excerpt.count, 322)
    }

    func testRestoresOldEmbeddingSummaryAndActualSourceKind() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("passage-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = StorageManager(rootURL: root)
        let id = UUID()
        let summary = "# Review\n**Duration:** 5m · **App:** Meet · **Model:** Local\n## TL;DR\n"
            + String(repeating: "The current release has several milestones. ", count: 12)
            + "\n- Review the redemption queue tomorrow."
        try MeetingFixture.write([.init(id: id, title: "Review", startedAt: Date(),
                                       summary: summary, transcriptLines: ["Okay.", "Please review the redemption queue after this call."])], under: root)
        let index = SearchIndex(databaseURL: root.appendingPathComponent("search.sqlite"))
        index.reindexAll(storage.loadMeetings(), storage: storage)
        let hit = try XCTUnwrap(index.semanticPassage(meetingID: id, start: 0,
                                                     text: String(summary.prefix(300)), query: "redemption"))
        XCTAssertEqual(hit.kind, .summary)
        XCTAssertTrue(hit.snippet.contains("redemption"))
        XCTAssertTrue(hit.isSemantic)
        let transcriptHit = try XCTUnwrap(index.semanticPassage(meetingID: id, start: 0,
            text: "Me: Okay.\nThem: Please review the redemption queue after this call.", query: "redemption"))
        XCTAssertEqual(transcriptHit.kind, .segment)
        XCTAssertEqual(transcriptHit.start, 10)
        XCTAssertTrue(transcriptHit.snippet.contains("redemption"))
        index.remove(id)
        XCTAssertNil(index.semanticPassage(meetingID: id, start: 0, text: summary, query: "redemption"))
    }
}
