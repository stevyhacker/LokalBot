import XCTest
@testable import LokalBot

final class MeetingSummaryOutcomeSynchronizerTests: XCTestCase {
    func testMeetingSectionsComeOnlyFromGroundedOutcomes() {
        let userCitation = citation(id: "user", start: 1_313)
        let otherCitation = citation(id: "other", start: 1_222)
        let outcomes = MeetingOutcomes(
            actionItems: [
                .init(
                    text: "Me will follow up on WhatsApp",
                    owner: "Me",
                    isForUser: true,
                    citations: [userCitation]),
                .init(
                    text: "Share a sample project",
                    owner: "Ricky",
                    due: "tomorrow",
                    isForUser: false,
                    citations: [otherCitation]),
            ],
            openQuestions: ["What compensation terms remain unresolved?"])
        let modelSummary = """
            # Stevan - Ricky call

            ## TL;DR

            They discussed working together.

            ## Key points

            - The project is local-first.

            ## Decisions

            - They finalized equity-only terms.

            ## Action items

            ### Me
            - [ ] Invented model task

            ### Others
            None

            ## Open questions

            - An unrelated question.

            ## Appendix

            Narrative detail remains.
            """

        let synchronized = MeetingSummaryOutcomeSynchronizer.synchronize(
            modelSummary,
            outcomes: outcomes,
            template: .meeting)

        XCTAssertTrue(synchronized.contains("## TL;DR\n\nThey discussed working together."))
        XCTAssertTrue(synchronized.contains("## Key points\n\n- The project is local-first."))
        XCTAssertTrue(synchronized.contains("## Decisions\n\nNone"), synchronized)
        XCTAssertTrue(synchronized.contains(
            "- [ ] I will follow up on WhatsApp — [00:21:53]"), synchronized)
        XCTAssertTrue(synchronized.contains(
            "- [ ] Ricky: Share a sample project — due tomorrow — [00:20:22]"),
            synchronized)
        XCTAssertTrue(synchronized.contains(
            "## Open questions\n\n- An unrelated question."), synchronized)
        XCTAssertTrue(synchronized.contains("## Appendix\n\nNarrative detail remains."))
        XCTAssertFalse(synchronized.contains("finalized equity-only"), synchronized)
        XCTAssertFalse(synchronized.contains("Invented model task"), synchronized)
    }

    func testMissingMeetingOutcomeSectionsAreAppendedExactlyOnce() {
        let summary = "## TL;DR\n\nA short recap."

        let synchronized = MeetingSummaryOutcomeSynchronizer.synchronize(
            summary,
            outcomes: MeetingOutcomes(),
            template: .meeting)

        XCTAssertEqual(occurrences(of: "## Decisions", in: synchronized), 1)
        XCTAssertEqual(occurrences(of: "## Action items", in: synchronized), 1)
        XCTAssertEqual(occurrences(of: "## Open questions", in: synchronized), 0)
        XCTAssertTrue(synchronized.contains("### Me\nNone\n\n### Others\nNone"), synchronized)
    }

    func testNonMeetingTemplateOnlyControlsActionItems() {
        let summary = """
            ## Concepts

            - Existing concept

            ## Decisions

            - A lecture-specific note

            ## Action items

            - [ ] Unsupported task
            """

        let synchronized = MeetingSummaryOutcomeSynchronizer.synchronize(
            summary,
            outcomes: MeetingOutcomes(),
            template: .lecture)

        XCTAssertTrue(synchronized.contains("- A lecture-specific note"), synchronized)
        XCTAssertFalse(synchronized.contains("Unsupported task"), synchronized)
        XCTAssertFalse(synchronized.contains("## Open questions"), synchronized)
    }

    func testFailedRegenerationCanRefreshExistingOutcomeSectionsWithoutReplacingTheRecap() throws {
        let folder = makeFolder()
        let url = folder.appendingPathComponent("summary.md")
        let previous = "## TL;DR\n\nEarlier recap.\n\n## Decisions\n\nOld decision\n\n## Action items\n\n- [ ] Old task"
        try Data(previous.utf8).write(to: url)
        let outcomes = MeetingOutcomes(actionItems: [
            .init(text: "Send the report", owner: "Me", isForUser: true, citations: [citation(id: "new", start: 20)]),
        ])
        try MeetingSummaryOutcomeSynchronizer.synchronizeExisting(in: folder, outcomes: outcomes, template: .meeting)
        let updated = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(updated.contains("Earlier recap."))
        XCTAssertTrue(updated.contains("Send the report"))
        XCTAssertFalse(updated.contains("Old task"))
        XCTAssertFalse(updated.contains("Old decision"))
    }

    func testActionCorrectionsRewriteOnlyTheActionListOfAClaimsSummary() throws {
        let folder = makeFolder()
        let url = folder.appendingPathComponent("summary.md")
        let previous = "## TL;DR\n\n- **Ana:** Recap.\n\n## Decisions\n\n- A lecture-specific note\n\n## Action items\n\n- [ ] Old task\n"
        try Data(previous.utf8).write(to: url)
        let outcomes = MeetingOutcomes(actionItems: [.init(text: "Send the report", owner: "Ana")])

        XCTAssertFalse(try MeetingSummaryOutcomeSynchronizer.applyActionCorrections(in: folder, outcomes: outcomes))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), previous,
                       "Free-text prose may still name the old owner")

        try Data("{}".utf8).write(to: folder.appendingPathComponent("summary-claims.json"))
        XCTAssertTrue(try MeetingSummaryOutcomeSynchronizer.applyActionCorrections(in: folder, outcomes: outcomes))
        let updated = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(updated.contains("## TL;DR\n\n- **Ana:** Recap."), updated)
        XCTAssertTrue(updated.contains("## Decisions\n\n- A lecture-specific note"), updated)
        XCTAssertTrue(updated.contains("- [ ] Ana: Send the report"), updated)
        XCTAssertFalse(updated.contains("Old task"), updated)
    }

    func testOutcomesAloneDoNotCreateACompletedSummary() throws {
        let folder = makeFolder()
        try MeetingSummaryOutcomeSynchronizer.synchronizeExisting(in: folder, outcomes: MeetingOutcomes(), template: .meeting)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("summary.md").path))
    }

    private func makeFolder() -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }

    private func citation(id: String, start: TimeInterval) -> OutcomeSourceCitation {
        OutcomeSourceCitation(
            segmentID: id,
            start: start,
            end: start + 4,
            speaker: "me",
            excerpt: "Evidence")
    }

    private func occurrences(of needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }
}
