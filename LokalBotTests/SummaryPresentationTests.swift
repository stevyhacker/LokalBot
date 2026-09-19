import XCTest
@testable import LokalBot

final class SummaryPresentationTests: XCTestCase {
    func testMergedSummaryHidesSourceBookkeepingAndPreservesMeetingContent() {
        var meeting = Meeting(id: UUID(), title: "Merged: Design review + 1 more",
                              appName: "Merged meetings", startedAt: .now,
                              relativePath: "meetings/design")
        meeting.mergedSourceMeetingIDs = [UUID(), UUID()]
        let markdown = """
        # Merged: Design review + 1 more — September 19
        **Duration:** 30m · **Sources:** 2 · **App:** Merged meetings

        This is a non-destructive merge. Source evidence remains on disk for provenance, while the source rows are folded into this merged meeting.

        ## TL;DR
        The team chose Redis.
        """
        let display = SummaryPresentation.meetingBody(markdown, meeting: meeting)
        let parts = SummaryPresentation.split(display)
        XCTAssertTrue(parts.body.hasPrefix("# Design review — September 19"))
        XCTAssertFalse(parts.body.contains("non-destructive"))
        XCTAssertEqual(parts.metadata.map(\.label), ["Duration"])
        XCTAssertEqual(SummaryPresentation.recap(display), "The team chose Redis.")
        XCTAssertTrue(markdown.contains("Merged: Design review + 1 more"))
    }

    func testSplitsProvenanceLineIntoMetadataAndBody() {
        let markdown = """
            # Standup — August 17, 2026 at 9:00 AM
            **Duration:** 32m · **App:** Zoom · **Words:** 1,204 · **Template:** Meeting notes · **Model:** OpenAI-compatible — x-ai/grok-4.6

            ## Decisions
            Ship the Ask control this week.
            """

        let parts = SummaryPresentation.split(markdown)

        XCTAssertEqual(parts.metadata.map(\.label),
                       ["Duration", "App", "Words", "Template", "Model"])
        XCTAssertEqual(parts.metadata.last?.value, "OpenAI-compatible — x-ai/grok-4.6")
        XCTAssertFalse(parts.body.contains("**Model:**"))
        XCTAssertTrue(parts.body.contains("## Decisions"))
        XCTAssertTrue(parts.body.contains("# Standup"))
    }

    func testLeavesOrdinaryBoldOpenersInTheBody() {
        let markdown = """
            # Notes
            **Next steps:** send the deck.

            The rest of the summary.
            """

        let parts = SummaryPresentation.split(markdown)

        XCTAssertTrue(parts.metadata.isEmpty,
                      "a single bold label is body copy, not provenance")
        XCTAssertTrue(parts.body.contains("**Next steps:**"))
    }

    func testRecapKeepsParagraphImmediatelyBelowHeading() {
        let markdown = "## TL;DR\nA decision and its reason.\n\n## Actions\n- [ ] Follow up."
        XCTAssertEqual(SummaryPresentation.recap(markdown), "A decision and its reason.")
        XCTAssertEqual(SummaryPresentation.split(markdown).body, markdown)
        XCTAssertNil(SummaryPresentation.recap("## Actions\n- [ ] Follow up."))
    }

    func testLeavesSummariesWithoutAProvenanceLineIntact() {
        let markdown = "Just a paragraph with no header metadata."
        let parts = SummaryPresentation.split(markdown)
        XCTAssertTrue(parts.metadata.isEmpty)
        XCTAssertEqual(parts.body, markdown)
    }

    func testRecapRemovesAttributionAndCitationsAndStopsAtTheNextSection() {
        let recap = "- **You:** Send the proposal. — [00:05]\n- **Ana:** The release is on Friday. — [00:10]"
        let markdown = "## TL;DR\n\n\(recap)\n\n## Key points\n\n- Another fact.\n\n## Decisions\n\nNone"
        XCTAssertEqual(SummaryPresentation.recap(markdown), "Send the proposal. The release is on Friday.")
        XCTAssertTrue(SummaryPresentation.split(markdown).body.contains(recap),
                      "Full Summary must retain evidence and attribution")
    }

    func testRecapCleansMergedSpeakerLabelsWithoutLosingContent() {
        let markdown = """
        ## TL;DR
        - **Them 6 · source 1:** Build the investor report. — [00:03:43]
        - **Them 1 · source 2:** Keep the **two-contract** design. — [00:22:20]
        ## Decisions
        A separate decision.
        """
        XCTAssertEqual(SummaryPresentation.recap(markdown),
                       "Build the investor report. Keep the **two-contract** design.")
    }

    func testRecapPreservesOrdinaryColonsAndTimesInContent() {
        let markdown = "## TL;DR\n- **Ana:** Deadline: Friday at 10:30. — [01:02:03]\n- Budget: **$2,000**."
        XCTAssertEqual(SummaryPresentation.recap(markdown),
                       "Deadline: Friday at 10:30. Budget: **$2,000**.")
    }

    func testLongRecapRetainsAllContentForExpansion() throws {
        let points = (1...30).map { "- **Them 1 · source 2:** Decision \($0). — [00:22:20]" }
        let recap = try XCTUnwrap(SummaryPresentation.recap("## TL;DR\n" + points.joined(separator: "\n")))
        XCTAssertTrue(recap.hasPrefix("Decision 1."))
        XCTAssertTrue(recap.hasSuffix("Decision 30."))
        XCTAssertFalse(recap.contains("source"))
        XCTAssertFalse(recap.contains("\n"))
    }

    func testEmptyGeneratedSectionsDoNotBecomeTheRecap() {
        XCTAssertNil(SummaryPresentation.recap("## TL;DR\n\nNone\n\n## Decisions\n\nNone"))
    }
}
