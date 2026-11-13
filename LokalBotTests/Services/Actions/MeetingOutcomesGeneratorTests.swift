import XCTest
@testable import LokalBot

final class MeetingOutcomesGeneratorTests: XCTestCase {
    func testMergeDeduplicatesOverlapAndDoesNotRepeatActionAsDecision() {
        let citation = OutcomeSourceCitation(
            segmentID: "segment-0001-0000012000-0000018000",
            start: 12,
            end: 18,
            speaker: "me",
            excerpt: "I will share the project repository")
        var first = MeetingOutcomes()
        first.actionItems = [
            .init(
                text: "Share the project repository",
                owner: "Me",
                isForUser: true,
                importance: 2,
                citations: [citation]),
        ]
        first.decisionRecords = [
            .init(text: "Share the project repository with Stevan", citations: [citation]),
        ]
        var second = MeetingOutcomes()
        second.actionItems = [
            .init(
                text: "Share the project repository with Stevan",
                owner: "Me",
                isForUser: true,
                importance: 5,
                citations: [citation]),
            .init(
                text: "Review the repository",
                owner: "Ricky",
                isForUser: false,
                citations: [OutcomeSourceCitation(
                    segmentID: "segment-0002-0000020000-0000024000",
                    start: 20,
                    end: 24,
                    speaker: "them",
                    excerpt: "I will review it")]),
        ]

        let merged = MeetingOutcomesGenerator.merge([first, second])

        XCTAssertEqual(merged.actionItems.count, 2)
        XCTAssertEqual(merged.actionItems.first?.text, "Share the project repository with Stevan")
        XCTAssertEqual(merged.actionItems.first?.owner, "Me")
        XCTAssertEqual(merged.actionItems.first?.importance, 5)
        XCTAssertTrue(merged.decisionRecords.isEmpty)
    }

    /// Asked again about a row, the built-in 4B model returned the row's own
    /// words as a second task beside the one already written from it.
    func testATaskThatOnlyRepeatsItsSourceMergesIntoTheTaskWrittenFromIt() {
        let spoken = "those can be simpler if we update the plan but I'll ping you Mira and Jonas to to get that resolved in chat"
        let citation = OutcomeSourceCitation(segmentID: "segment-0011-0000046300-0000058000", start: 46.3, end: 58,
                                             speaker: "me", excerpt: spoken)
        let other = OutcomeSourceCitation(segmentID: "segment-0005-0000019400-0000024000", start: 19.4, end: 24,
                                          speaker: "me", excerpt: "export change is something I I have to update")
        func mine(_ text: String, _ citation: OutcomeSourceCitation) -> MeetingOutcomes.ActionItem {
            .init(text: text, owner: "Me", isForUser: true, citations: [citation],
                  attribution: .init(resolution: .user, speakerID: "me", basis: .commitment, quote: citation.excerpt))
        }
        var first = MeetingOutcomes()
        first.actionItems = [mine("Ping Mira and Jonas in chat to resolve the plan", citation),
                             mine("Update the export change", other)]
        var repair = MeetingOutcomes()
        repair.actionItems = [mine("I'll ping you Mira and Jonas to to get that resolved in chat", citation)]

        for parts in [[first, repair], [repair, first]] {
            let merged = MeetingOutcomesGenerator.merge(parts)
            XCTAssertEqual(Set(merged.actionItems.map(\.text)),
                           ["Ping Mira and Jonas in chat to resolve the plan", "Update the export change"])
        }
    }

    func testAcceptanceIsNotRepeatedAsADecisionWhenItsParaphraseDiffers() {
        let citation = OutcomeSourceCitation(segmentID: "s2", start: 5, end: 6,
                                             speaker: "me", excerpt: "Yeah, I can do that.")
        var outcomes = MeetingOutcomes()
        outcomes.actionItems = [.init(text: "Stack the storage PR first.", owner: "Me", isForUser: true,
            citations: [citation], attribution: .init(resolution: .user, speakerID: "me", basis: .commitment,
                                                     quote: citation.excerpt))]
        outcomes.decisionRecords = [.init(text: "Confirmed they can proceed with the proposed change.",
            citations: [citation], attribution: .init(speakerID: "me", speakerLabel: "You", identity: .user,
                                                     quote: citation.excerpt))]
        XCTAssertTrue(MeetingOutcomesGenerator.merge([outcomes]).decisionRecords.isEmpty)
        outcomes.decisionRecords[0].attribution?.quote = "We agreed to keep the current storage design."
        XCTAssertEqual(MeetingOutcomesGenerator.merge([outcomes]).decisionRecords.count, 1)
    }

}
