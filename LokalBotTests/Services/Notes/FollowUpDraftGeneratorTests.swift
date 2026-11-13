import XCTest
@testable import LokalBot

private struct StubEngine: TextEngine {
    var reply: String
    var displayName: String { "Stub" }
    func generate(system: String, prompt: String, context: [String]) async throws -> String { reply }
}

final class FollowUpDraftGeneratorTests: XCTestCase {
    private func projection() throws -> MeetingOutcomeProjection {
        var meeting = Meeting(id: UUID(), title: "Pricing review", appName: "Meet",
                              startedAt: Date(timeIntervalSince1970: 1_780_000_000),
                              endedAt: Date(timeIntervalSince1970: 1_780_001_800),
                              relativePath: "meetings/pricing")
        meeting.calendarParticipantIdentities = [
            try XCTUnwrap(CalendarParticipantIdentity(name: "Ana Petrović", emailAddress: "ana@example.com")),
        ]
        let outcomes = MeetingOutcomes(
            actionItems: [.init(text: "Send the synthetic price table", owner: "Me", due: "2026-06-01"),
                          .init(text: "Benchmark the synthetic tier", owner: "Ana")],
            decisions: ["Keep three synthetic tiers"],
            openQuestions: ["Do we grandfather legacy synthetic plans?"])
        return MeetingOutcomeProjection(meeting: meeting, outcomes: outcomes, state: MeetingOutcomeState(),
                                        followUp: FollowUpDraft.seeded(for: meeting, outcomes: outcomes))
    }

    func testEvidenceUsesOutcomesAndNamesButNeverAddresses() throws {
        let evidence = FollowUpDraftGenerator.evidence(for: try projection(), summary: "## TL;DR\nWe agreed on tiers.")
        XCTAssertEqual(evidence.participantNames, ["Ana Petrović"])
        XCTAssertEqual(evidence.decisions, ["Keep three synthetic tiers"])
        XCTAssertEqual(evidence.actions.map(\.owner), ["Me", "Ana"])
        let context = FollowUpDraftGenerator.promptContext(evidence)
        XCTAssertTrue(context.contains("owner: the sender"))
        XCTAssertTrue(context.contains("Do we grandfather legacy synthetic plans?"))
        XCTAssertFalse(context.contains("@"))
    }

    func testGenerateParsesDraftAndRejectsUnreadableReplies() async throws {
        let evidence = FollowUpDraftGenerator.evidence(for: try projection(), summary: nil)
        let draft = try await FollowUpDraftGenerator.generate(
            evidence: evidence,
            engine: StubEngine(reply: #"{"subject": "Pricing follow-up", "body": "Hi Ana,\n- I will send the table"}"#))
        XCTAssertEqual(draft.subject, "Pricing follow-up")
        XCTAssertTrue(draft.body.hasPrefix("Hi Ana"))

        do {
            _ = try await FollowUpDraftGenerator.generate(evidence: evidence, engine: StubEngine(reply: "not json"))
            XCTFail("An unreadable reply must not replace the outline")
        } catch FollowUpDraftGenerator.GenerationError.unreadableResponse {}
    }
}
