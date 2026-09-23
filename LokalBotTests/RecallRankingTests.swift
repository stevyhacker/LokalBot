import XCTest
@testable import LokalBot

final class RecallRankingTests: XCTestCase {
    func testAgreementOutranksOneSidedMatchesAndKeepsSemanticOnlySources() {
        let first = UUID(), shared = UUID(), semanticOnly = UUID()
        let ranked = RecallSearch.fusedMeetings(
            keyword: [hit(first, "Exact"), hit(shared, "Shared")],
            semantic: [hit(shared, "Shared"), hit(semanticOnly, "Related")])
        XCTAssertEqual(ranked.first?.id, shared)
        XCTAssertEqual(Set(ranked.map(\.id)), [first, shared, semanticOnly])
        XCTAssertEqual(ranked.first?.matches.count, 1)
    }

    func testDuplicatePassagesDoNotInflateScoreOrHideOtherMeetings() {
        let repeated = UUID(), shared = UUID()
        let ranked = RecallSearch.fusedMeetings(
            keyword: Array(repeating: hit(repeated, "Repeated"), count: 100) + [hit(shared, "«Shared»")],
            semantic: [hit(shared, "Shared")], limit: 1)
        XCTAssertEqual(ranked.map(\.id), [shared])
        XCTAssertEqual(ranked[0].primary.snippet, "«Shared»", "Keep the highlighted lexical excerpt")
        XCTAssertEqual(ranked[0].matches.count, 1)
    }

    func testStableTiesAndEmptySemanticFallback() {
        let first = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let second = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        XCTAssertEqual(RecallSearch.fusedMeetings(keyword: [hit(second, "B")], semantic: [hit(first, "A")]).map(\.id), [second, first])
        XCTAssertEqual(RecallSearch.fusedMeetings(keyword: [hit(second, "B"), hit(first, "A")], semantic: []).map(\.id), [second, first])
        XCTAssertTrue(RecallSearch.fusedMeetings(keyword: [hit(first, "A")], semantic: [], limit: 0).isEmpty)
    }

    func testOneSummaryDestinationForOverviewAndFullNotesSearch() {
        XCTAssertEqual(MeetingWorkspaceTab.allCases.map(\.rawValue), ["Summary", "Transcript", "Notes", "Review"])
        XCTAssertEqual(MeetingWorkspaceTab.containing(.sectionHeader(.summary)), .summary)
        XCTAssertEqual(MeetingWorkspaceTab.containing(.sectionHeader(.actionItems)), .summary)
        XCTAssertEqual(MeetingWorkspaceTab.containing(.sectionHeader(.transcript)), .transcript)
    }

    private func hit(_ id: UUID, _ text: String) -> SearchIndex.Hit {
        .init(meetingID: id, kind: .segment, start: 12, snippet: text, speaker: "Me")
    }
}
