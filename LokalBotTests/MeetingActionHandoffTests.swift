import XCTest
@testable import LokalBot

final class MeetingActionHandoffTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!

    private func meeting() -> Meeting {
        Meeting(id: UUID(), title: "Pricing review", appName: "Meet",
                startedAt: Date(timeIntervalSince1970: 1_780_000_000),
                endedAt: Date(timeIntervalSince1970: 1_780_001_800),
                relativePath: "meetings/pricing")
    }

    private func projection(_ actions: [MeetingOutcomes.ActionItem], meeting: Meeting? = nil,
                            state: MeetingOutcomeState = MeetingOutcomeState()) -> MeetingOutcomeProjection {
        let meeting = meeting ?? self.meeting()
        let outcomes = MeetingOutcomes(actionItems: actions, decisions: [], openQuestions: [])
        return MeetingOutcomeProjection(meeting: meeting, outcomes: outcomes, state: state,
                                        followUp: FollowUpDraft.seeded(for: meeting, outcomes: outcomes))
    }

    func testHandsOffOnlyOpenActionsThatAreTheUsers() {
        let mine = MeetingOutcomes.ActionItem(text: "Send the synthetic price table", owner: "Me")
        let theirs = MeetingOutcomes.ActionItem(text: "Benchmark the synthetic tier", owner: "Ana")
        let done = MeetingOutcomes.ActionItem(text: "Book the synthetic venue", owner: "Me")
        let deferred = MeetingOutcomes.ActionItem(text: "Rename the synthetic plan", owner: "Me")
        var state = MeetingOutcomeState()
        state.actions[done.id] = .init(status: .done, userEdited: true)
        state.actions[deferred.id] = .init(status: .deferred, userEdited: true)

        let actions = MeetingActionHandoff.actions(in: projection([mine, theirs, done, deferred], state: state))

        XCTAssertEqual(actions.map(\.action.id), [mine.id])
    }

    func testCapsActionsAndSkipsArchivedSampleAndMergedMeetings() {
        let actions = (1...10).map { MeetingOutcomes.ActionItem(text: "Draft synthetic note \($0)", owner: "Me") }
        XCTAssertEqual(MeetingActionHandoff.actions(in: projection(actions)).count, MeetingActionHandoff.maximumActions)

        var archived = projection(actions)
        archived.isArchived = true
        XCTAssertTrue(MeetingActionHandoff.actions(in: archived).isEmpty)

        var sample = meeting()
        sample.sampleID = "synthetic-sample"
        XCTAssertTrue(MeetingActionHandoff.actions(in: projection(actions, meeting: sample)).isEmpty)

        var merged = meeting()
        merged.mergedIntoMeetingID = UUID()
        XCTAssertTrue(MeetingActionHandoff.actions(in: projection(actions, meeting: merged)).isEmpty)
    }

    func testHandoffsAttachTheMeetingAndNumberTheirFolders() throws {
        let first = MeetingOutcomes.ActionItem(text: "Send the synthetic price table", owner: "Me")
        let second = MeetingOutcomes.ActionItem(text: "Book the synthetic venue", owner: "Me")
        let projection = projection([first, second])

        let handoffs = MeetingActionHandoff.handoffs(for: projection, timeZone: utc)

        XCTAssertEqual(handoffs.map(\.source), [
            AgentHandoffSource(meetingID: projection.meeting.id, actionID: first.id),
            AgentHandoffSource(meetingID: projection.meeting.id, actionID: second.id),
        ])
        XCTAssertEqual(handoffs.map(\.title), projection.actionReferences.map(\.text))
        for handoff in handoffs {
            let attachment = try XCTUnwrap(handoff.attachments.first)
            XCTAssertEqual(handoff.attachments.count, 1)
            XCTAssertEqual(attachment.kind, .meeting)
            XCTAssertEqual(attachment.reference, projection.meeting.id.uuidString)
            XCTAssertEqual(attachment.title, "Pricing review")
        }
        XCTAssertEqual(handoffs.map(\.folder), [
            "handoffs/2026-05-28-pricing-review/1-send-the-synthetic-price-table",
            "handoffs/2026-05-28-pricing-review/2-book-the-synthetic-venue",
        ])
    }

    func testPromptNamesTheMeetingActionEvidenceAndLimits() throws {
        let citation = OutcomeSourceCitation(segmentID: "s1", start: 754, end: 760,
                                             speaker: "Me", excerpt: "I'll send the table.")
        let action = MeetingOutcomes.ActionItem(text: "Send the synthetic price table", owner: "Me",
                                                citations: [citation])
        let projection = projection([action])
        let reference = try XCTUnwrap(projection.actionReferences.first)
        let folder = "handoffs/2026-05-28-pricing-review/1-send-the-synthetic-price-table"

        let lines = MeetingActionHandoff.prompt(for: reference, folder: folder, timeZone: utc)
            .components(separatedBy: "\n")

        XCTAssertEqual(lines.first, "Work on this action item from my meeting “Pricing review”, Thu 2026-05-28 20:26 "
            + "(LokalBot meeting ID \(SessionLookup.shortID(projection.meeting.id))).")
        XCTAssertTrue(lines.contains("Action: \(reference.text)"))
        XCTAssertTrue(lines.contains("It comes up at [00:12:34] in the meeting."))
        XCTAssertTrue(lines.contains { $0.contains("Save what you make in `\(folder)/` in this workspace.") })
        XCTAssertTrue(lines.contains("Don't send, post, publish, buy, or delete anything. Draft it for me instead."))
        XCTAssertEqual(lines.last, "The meeting's notes are attached.")
        XCTAssertFalse(lines.contains { $0.hasPrefix("Due:") })
    }

    func testPromptShowsTheResolvedDueDateAndWhatWasSaid() throws {
        let exact = MeetingOutcomes.ActionItem(text: "Send the synthetic price table", owner: "Me", due: "2026-06-01")
        let spoken = MeetingOutcomes.ActionItem(text: "Book the synthetic venue", owner: "Me", due: "tomorrow")
        let references = projection([exact, spoken]).actionReferences

        let exactLines = MeetingActionHandoff.prompt(for: references[0], folder: "a").components(separatedBy: "\n")
        let spokenLines = MeetingActionHandoff.prompt(for: references[1], folder: "b").components(separatedBy: "\n")

        XCTAssertTrue(exactLines.contains("Due: 2026-06-01"))
        let due = try XCTUnwrap(spokenLines.first { $0.hasPrefix("Due: ") })
        XCTAssertTrue(due.hasSuffix(" (said “tomorrow”)"), due)
    }

    func testSlugKeepsLettersAndDigitsWithinTheLimit() {
        XCTAssertEqual(MeetingActionHandoff.slug("Send the Q3 price table — v2!", limit: 48), "send-the-q3-price-table-v2")
        XCTAssertEqual(MeetingActionHandoff.slug("alpha beta gamma", limit: 10), "alpha-beta")
        XCTAssertEqual(MeetingActionHandoff.slug("alpha beta", limit: 6), "alpha")
        XCTAssertEqual(MeetingActionHandoff.slug("Pregled cena: Ćevapi", limit: 40), "pregled-cena-ćevapi")
        XCTAssertEqual(MeetingActionHandoff.slug("!!!", limit: 10), "")
    }

    func testFolderLeavesOutEmptySlugs() throws {
        var untitled = meeting()
        untitled.title = "!!!"
        let reference = try XCTUnwrap(projection([.init(text: "…", owner: "Me")], meeting: untitled)
            .actionReferences.first)
        let folder = MeetingActionHandoff.folder(for: reference, number: 3, timeZone: utc)
        XCTAssertTrue(folder.hasPrefix("handoffs/2026-05-28"), folder)
        XCTAssertFalse(folder.contains("--"), folder)
    }
}
