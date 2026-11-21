import Foundation
import XCTest
@testable import LokalBot

final class MeetingRecapExporterTests: XCTestCase {
    private func sampleMeeting() -> Meeting {
        Meeting(
            id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            title: "API Launch & <Review>",
            appName: "Zoom",
            startedAt: Date(timeIntervalSince1970: 1_763_540_000),
            endedAt: Date(timeIntervalSince1970: 1_763_541_800),
            relativePath: "2026-11-19/sample")
    }

    func testSlackOrEmailRecapIncludesDecisionsActionsAndSummary() {
        let meeting = sampleMeeting()
        let action = MeetingOutcomes.ActionItem(
            text: "Ship v2 rate limiter",
            owner: "Maya",
            due: "Friday",
            isForUser: false)
        let outcomes = MeetingOutcomes(
            actionItems: [action],
            decisions: ["Cap retries at 3 attempts"],
            openQuestions: ["Should legacy webhooks warn for 30 days?"])
        let projection = MeetingOutcomeProjection(
            meeting: meeting,
            outcomes: outcomes,
            state: MeetingOutcomeState(),
            followUp: FollowUpDraft.seeded(for: meeting, outcomes: outcomes))

        let recap = MeetingRecapExporter.slackOrEmailRecap(
            meeting: meeting,
            summary: "## Overview\n- Agreed on rollout plan",
            projection: projection)

        XCTAssertTrue(recap.contains("*API Launch & <Review>*"))
        XCTAssertTrue(recap.contains("*Decisions*\n• Cap retries at 3 attempts"))
        XCTAssertTrue(recap.contains("*Action items*\n• [ ] Ship v2 rate limiter (Maya, due Friday)"))
        XCTAssertTrue(recap.contains("*Open questions*\n• Should legacy webhooks warn for 30 days?"))
        XCTAssertTrue(recap.contains("• Agreed on rollout plan"))
        XCTAssertFalse(recap.contains("lokalbot.com"))

        let withAttribution = MeetingRecapExporter.slackOrEmailRecap(
            meeting: meeting,
            summary: nil,
            projection: projection,
            includeAttribution: true)
        XCTAssertTrue(withAttribution.contains("lokalbot.com"))
    }

    func testStaticHTMLIsSelfContainedAndEscapesMarkup() {
        let meeting = sampleMeeting()
        let outcomes = MeetingOutcomes(
            actionItems: [MeetingOutcomes.ActionItem(text: "Audit <script>alert(1)</script>", owner: "Sam", due: "Monday")],
            decisions: ["Use local-only processing"])
        let projection = MeetingOutcomeProjection(
            meeting: meeting,
            outcomes: outcomes,
            state: MeetingOutcomeState(),
            followUp: FollowUpDraft.seeded(for: meeting, outcomes: outcomes))
        let transcript = Transcript(
            segments: [
                Transcript.Segment(start: 12, end: 18, speaker: "Maya", text: "Let's keep it <local>."),
            ],
            engine: "test")

        let html = MeetingRecapExporter.staticHTML(
            meeting: meeting,
            summary: "### Summary\n- Ready to ship",
            projection: projection,
            transcript: transcript)

        XCTAssertTrue(html.hasPrefix("<!doctype html>"))
        XCTAssertTrue(html.contains("API Launch &amp; &lt;Review&gt;"))
        XCTAssertTrue(html.contains("Audit &lt;script&gt;alert(1)&lt;/script&gt;"))
        XCTAssertFalse(html.contains("<script>alert(1)</script>"))
        XCTAssertTrue(html.contains("Full transcript (1 segments)"))
        XCTAssertTrue(html.contains("Let&#39;s keep it &lt;local&gt;."))
        XCTAssertTrue(html.contains("https://www.lokalbot.com/"))
        XCTAssertFalse(html.contains("<script"))
        XCTAssertFalse(html.contains("<link"))
    }
}
