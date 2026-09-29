import XCTest
@testable import LokalBot

final class ProjectLinksTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_780_000_000)

    private func meeting(_ title: String, daysAgo: Double) -> Meeting {
        Meeting(id: UUID(), title: title, appName: "Meet",
                startedAt: now.addingTimeInterval(-daysAgo * 86_400),
                endedAt: now.addingTimeInterval(-daysAgo * 86_400 + 1_800),
                relativePath: "meetings/\(UUID().uuidString)")
    }

    private func memory(_ names: [String]) -> DreamMemory {
        var memory = DreamMemory(updatedAt: now)
        memory.activeProjects = names.map {
            .init(name: $0, status: "In progress", lastActiveDay: "2026-05-27")
        }
        return memory
    }

    func testSignificantTermsDropGenericWords() {
        XCTAssertEqual(ProjectLinks.significantTerms("Orion launch"), ["orion"])
        XCTAssertEqual(ProjectLinks.significantTerms("Postgres migration"), ["postgres"])
        XCTAssertEqual(ProjectLinks.significantTerms("Q3 release"), ["q3", "release"])
        XCTAssertTrue(ProjectLinks.matches(["orion"], in: "Orion: pricing review"))
        XCTAssertFalse(ProjectLinks.matches(["orion"], in: "Orionids meteor notes"))
    }

    func testLinksMeetingsActionsTimeAndPeopleByProjectName() throws {
        let named = meeting("Orion pricing review", daysAgo: 2)
        let bySummary = meeting("Weekly sync", daysAgo: 1)
        let unrelated = meeting("Hiring loop", daysAgo: 1)
        let fromLinkedMeeting = MeetingOutcomes.ActionItem(text: "Send the synthetic price sheet", owner: "Me")
        let mentioning = MeetingOutcomes.ActionItem(text: "Draft the Orion synthetic FAQ", owner: "Me")
        let other = MeetingOutcomes.ActionItem(text: "Schedule the synthetic panel interviews", owner: "Me")
        func projection(_ meeting: Meeting, _ actions: [MeetingOutcomes.ActionItem]) -> MeetingOutcomeProjection {
            let outcomes = MeetingOutcomes(actionItems: actions)
            return .init(meeting: meeting, outcomes: outcomes, state: MeetingOutcomeState(),
                         followUp: FollowUpDraft.seeded(for: meeting, outcomes: outcomes))
        }
        let activity = [
            ActivityBlock(id: 1, app: "Keynote", title: "Orion deck.key",
                          start: now.addingTimeInterval(-3_600), end: now.addingTimeInterval(-1_800)),
            ActivityBlock(id: 2, app: "Safari", title: "Orion roadmap - Google Chrome",
                          start: now.addingTimeInterval(-86_400), end: now.addingTimeInterval(-86_400 + 600)),
            ActivityBlock(id: 3, app: "Mail", title: "Inbox",
                          start: now.addingTimeInterval(-600), end: now),
            ActivityBlock(id: 4, app: "Keynote", title: "Orion deck.key",
                          start: now.addingTimeInterval(-30 * 86_400), end: now.addingTimeInterval(-30 * 86_400 + 600)),
        ]
        let person = PersonProfile(
            id: "p", name: "Mila Novak", otherNames: [],
            meetings: [.init(id: named.id, title: named.title, startedAt: named.startedAt)],
            theirActions: [], myActions: [], decisions: [])

        let projects = ProjectLinks.build(.init(
            memory: memory(["Orion launch", "Unrelated effort"]),
            meetings: [named, bySummary, unrelated],
            summaries: [bySummary.id: "## TL;DR\nThe Orion beta slips a week."],
            projections: [projection(named, [fromLinkedMeeting]),
                          projection(unrelated, [mentioning, other])],
            activity: activity,
            people: [person]), now: now)

        let orion = try XCTUnwrap(projects.first { $0.name == "Orion launch" })
        XCTAssertEqual(orion.meetings.map(\.id), [bySummary.id, named.id])
        XCTAssertEqual(Set(orion.openActions.map(\.text)),
                       ["Send the synthetic price sheet", "Draft the Orion synthetic FAQ"])
        XCTAssertEqual(orion.trackedSeconds, 2_400, accuracy: 1)
        XCTAssertEqual(orion.windows.first?.title, "Orion deck.key")
        XCTAssertEqual(orion.people, ["Mila Novak"])
        let unrelatedProject = try XCTUnwrap(projects.first { $0.name == "Unrelated effort" })
        XCTAssertTrue(unrelatedProject.meetings.isEmpty)
        XCTAssertEqual(unrelatedProject.trackedSeconds, 0)
        XCTAssertEqual(orion.source, .overnightReview)
    }

    func testTopicsRecurringInMeetingsBecomeProjectsWithoutAReview() throws {
        let meetings = (1...3).map { meeting("Google Chrome meeting", daysAgo: Double($0)) }
        var summaries: [UUID: String] = [:]
        for (index, meeting) in meetings.enumerated() {
            summaries[meeting.id] = """
                # Synthetic sync
                **Duration:** 30 min
                ## Key Points
                - The Vireo pool migration moved ahead with Mila reviewing it in Chrome.
                - Mila shared the synthetic dashboard \(index).
                """
        }
        let outcomes = MeetingOutcomes(actionItems: [.init(text: "Ship the Vireo synthetic oracle", owner: "Me")],
                                       decisions: ["Keep Vireo on the synthetic testnet"])
        let projection = MeetingOutcomeProjection(
            meeting: meetings[0], outcomes: outcomes, state: MeetingOutcomeState(),
            followUp: FollowUpDraft.seeded(for: meetings[0], outcomes: outcomes))

        let projects = ProjectLinks.build(.init(
            memory: nil, meetings: meetings, summaries: summaries, projections: [projection],
            excludedTopicWords: ["mila"]), now: now)

        XCTAssertEqual(projects.map(\.name), ["Vireo"])
        let vireo = try XCTUnwrap(projects.first)
        XCTAssertEqual(vireo.source, .recurringTopic)
        XCTAssertFalse(vireo.pinned)
        XCTAssertEqual(vireo.meetings.count, 3)
        XCTAssertEqual(vireo.meetings.first?.mention,
                       "The Vireo pool migration moved ahead with Mila reviewing it in Chrome.")
        XCTAssertEqual(vireo.openActions.map(\.text), ["Ship the Vireo synthetic oracle"])
        XCTAssertEqual(vireo.decisions.map(\.text), ["Keep Vireo on the synthetic testnet"])

        // A reviewed project with the same name replaces the detected topic.
        var reviewed = memory(["Vireo pool"])
        reviewed.activeProjects[0].pinned = true
        let merged = ProjectLinks.build(.init(
            memory: reviewed, meetings: meetings, summaries: summaries, projections: [projection],
            excludedTopicWords: ["mila"]), now: now)
        XCTAssertEqual(merged.map(\.name), ["Vireo pool"])
        XCTAssertEqual(merged.first?.source, .overnightReview)
    }

    func testMentionDropsTranscriptMarkers() {
        let summary = """
            # Vireo sync
            - Them 5: Merged the first **Vireo** pull request, with polish still on top. — [00:06:46]
            """
        XCTAssertEqual(ProjectLinks.mention(of: ["vireo"], in: summary),
                       "Merged the first Vireo pull request, with polish still on top.")
        XCTAssertEqual(ProjectLinks.mention(of: ["vireo"], in: "[00:52:13] Vireo ships to auditors on Friday."),
                       "Vireo ships to auditors on Friday.")
    }

    func testTopicDetectorSkipsCommonWordsAndRareTerms() {
        let meetings = (1...4).map { meeting("Weekly sync", daysAgo: Double($0)) }
        var summaries: [UUID: String] = [:]
        for (index, meeting) in meetings.enumerated() {
            // "Launch" starts sentences but is mostly lowercase; "Kestrel"
            // appears in only two meetings.
            summaries[meeting.id] = "The Launch timing was discussed. We agreed the launch waits for the launch checklist."
                + (index < 2 ? " Then Kestrel came up briefly." : "")
        }
        XCTAssertTrue(ProjectTopicDetector.topics(
            meetings: meetings, summaries: summaries, projections: [], excludedWords: []).isEmpty)
    }
}
