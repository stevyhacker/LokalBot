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

    private func tracking(_ names: [String], hidden: [String] = []) -> ProjectCuration {
        var curation = ProjectCuration()
        curation.tracked = names.map { .init(id: UUID(), name: $0, otherNames: [], createdAt: now) }
        curation.hiddenNames = hidden
        return curation
    }

    private func projection(_ meeting: Meeting, _ actions: [MeetingOutcomes.ActionItem],
                            decisions: [String] = []) -> MeetingOutcomeProjection {
        let outcomes = MeetingOutcomes(actionItems: actions, decisions: decisions)
        return .init(meeting: meeting, outcomes: outcomes, state: MeetingOutcomeState(),
                     followUp: FollowUpDraft.seeded(for: meeting, outcomes: outcomes))
    }

    /// Three meetings that name Vireo mid-sentence, for topic suggestions.
    private func vireoMeetings() -> (meetings: [Meeting], summaries: [UUID: String]) {
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
        return (meetings, summaries)
    }

    func testSignificantTermsDropGenericWords() {
        XCTAssertEqual(ProjectLinks.significantTerms("Orion launch"), ["orion"])
        XCTAssertEqual(ProjectLinks.significantTerms("Postgres migration"), ["postgres"])
        XCTAssertEqual(ProjectLinks.significantTerms("Q3 release"), ["q3", "release"])
        XCTAssertTrue(ProjectLinks.matches(["orion"], in: "Orion: pricing review"))
        XCTAssertFalse(ProjectLinks.matches(["orion"], in: "Orionids meteor notes"))
        XCTAssertTrue(ProjectLinks.matches([["kestrel"], ["orion"]], in: "Orion pricing"))
    }

    func testTrackedProjectLinksMeetingsActionsTimeAndPeople() throws {
        let named = meeting("Orion pricing review", daysAgo: 2)
        let bySummary = meeting("Weekly sync", daysAgo: 1)
        let unrelated = meeting("Hiring loop", daysAgo: 1.5)
        let fromNamedMeeting = MeetingOutcomes.ActionItem(text: "Send the synthetic price sheet", owner: "Me")
        let mentioning = MeetingOutcomes.ActionItem(text: "Draft the Orion synthetic FAQ", owner: "Me")
        let other = MeetingOutcomes.ActionItem(text: "Schedule the synthetic panel interviews", owner: "Me")
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
            curation: tracking(["Orion launch", "Unrelated effort"]),
            meetings: [named, bySummary, unrelated],
            summaries: [bySummary.id: "## TL;DR\nThe Orion beta slips a week."],
            projections: [projection(named, [fromNamedMeeting]),
                          projection(unrelated, [mentioning, other])],
            activity: activity,
            people: [person]), now: now)

        let orion = try XCTUnwrap(projects.first { $0.name == "Orion launch" })
        XCTAssertTrue(orion.isTracked)
        XCTAssertEqual(orion.meetings.map(\.id), [bySummary.id, unrelated.id, named.id])
        XCTAssertEqual(orion.meetings.first?.mention?.text, "The Orion beta slips a week.")
        XCTAssertEqual(Set(orion.myActions.map(\.text)),
                       ["Send the synthetic price sheet", "Draft the Orion synthetic FAQ"])
        XCTAssertEqual(orion.trackedSeconds, 2_400, accuracy: 1)
        XCTAssertEqual(orion.windows.first?.title, "Orion deck.key")
        XCTAssertEqual(orion.people, ["Mila Novak"])
        XCTAssertEqual(orion.lastActive, Calendar.current.startOfDay(for: now))
        let unrelatedProject = try XCTUnwrap(projects.first { $0.name == "Unrelated effort" })
        XCTAssertTrue(unrelatedProject.meetings.isEmpty)
        XCTAssertEqual(unrelatedProject.trackedSeconds, 0)
        XCTAssertNil(unrelatedProject.lastActive)
    }

    func testRecurringTopicsAndReviewProjectsAreSuggestions() throws {
        let (meetings, summaries) = vireoMeetings()
        let outcomes = projection(meetings[0], [.init(text: "Ship the Vireo synthetic oracle", owner: "Me")],
                                  decisions: ["Keep Vireo on the synthetic testnet"])

        let projects = ProjectLinks.build(.init(
            meetings: meetings, summaries: summaries, projections: [outcomes],
            excludedTopicWords: ["mila"]), now: now)

        XCTAssertEqual(projects.map(\.name), ["Vireo"])
        let vireo = try XCTUnwrap(projects.first)
        XCTAssertEqual(vireo.kind, .suggestedTopic)
        XCTAssertEqual(vireo.meetings.count, 3)
        XCTAssertEqual(vireo.meetings.first?.mention?.text,
                       "The Vireo pool migration moved ahead with Mila reviewing it in Chrome.")
        XCTAssertEqual(vireo.myActions.map(\.text), ["Ship the Vireo synthetic oracle"])
        XCTAssertEqual(vireo.decisions.map(\.text), ["Keep Vireo on the synthetic testnet"])

        // A review project covering the same name is offered instead.
        let reviewed = ProjectLinks.build(.init(
            memory: memory(["Vireo pool"]), meetings: meetings, summaries: summaries, projections: [outcomes],
            excludedTopicWords: ["mila"]), now: now)
        XCTAssertEqual(reviewed.map(\.name), ["Vireo pool"])
        XCTAssertEqual(reviewed.first?.kind, .suggestedReview)
        XCTAssertEqual(reviewed.first?.reviewNotes.map(\.status), ["In progress"])
    }

    func testTrackedProjectAbsorbsItsSuggestionAndReviewNotes() throws {
        let (meetings, summaries) = vireoMeetings()
        let projects = ProjectLinks.build(.init(
            curation: tracking(["Vireo"]), memory: memory(["Vireo pool", "Kestrel audit"]),
            meetings: meetings, summaries: summaries, excludedTopicWords: ["mila"]), now: now)

        XCTAssertEqual(projects.map(\.name), ["Vireo", "Kestrel audit"])
        let vireo = try XCTUnwrap(projects.first)
        XCTAssertTrue(vireo.isTracked)
        XCTAssertEqual(vireo.reviewNotes.map(\.name), ["Vireo pool"])
        XCTAssertEqual(vireo.meetings.count, 3)
        XCTAssertEqual(projects.last?.kind, .suggestedReview)
    }

    func testHiddenSuggestionsAreNotOffered() {
        let (meetings, summaries) = vireoMeetings()
        let projects = ProjectLinks.build(.init(
            curation: tracking([], hidden: ["vireo", "kestrel audit"]), memory: memory(["Kestrel audit"]),
            meetings: meetings, summaries: summaries, excludedTopicWords: ["mila"]), now: now)
        XCTAssertTrue(projects.isEmpty)
    }

    /// 2026-10-16: a project's newest standup was missing because its only
    /// mention followed a speaker label and counted as a sentence start.
    func testSpeakerLabelledMentionKeepsTheNewestMeeting() throws {
        let older = (2...4).map { meeting("Product Standup", daysAgo: Double($0)) }
        let newest = meeting("Product Standup", daysAgo: 1)
        var summaries: [UUID: String] = [:]
        for meeting in older {
            summaries[meeting.id] = "## Key Points\n- Work continues on the Larkspur synthetic pilot this week."
        }
        summaries[newest.id] = """
            ## Key Points
            - **Them 4:** Larkspur pilot passed the synthetic review; pricing talks continue. — [00:13:35]
            """

        let topics = ProjectTopicDetector.topics(meetings: older + [newest], summaries: summaries,
                                                 projections: [], excludedWords: [])
        XCTAssertEqual(topics.first?.name, "Larkspur")
        XCTAssertEqual(topics.first?.meetingIDs.count, 4)

        let projects = ProjectLinks.build(.init(meetings: older + [newest], summaries: summaries), now: now)
        let larkspur = try XCTUnwrap(projects.first { $0.name == "Larkspur" })
        XCTAssertEqual(larkspur.meetings.first?.id, newest.id)
        XCTAssertEqual(larkspur.meetings.first?.mention?.text,
                       "Larkspur pilot passed the synthetic review; pricing talks continue.")
        XCTAssertEqual(larkspur.lastActive, newest.startedAt)
    }

    /// Long summaries name a project late, and summary-less meetings only
    /// in the transcript; both still link.
    func testWholeSummariesAndTranscriptsLinkATrackedProject() throws {
        let long = meeting("Demo Day", daysAgo: 3)
        let spoken = meeting("Product Standup", daysAgo: 2)
        let filler = String(repeating: "- The synthetic vault accounting moved ahead with more checks.\n", count: 90)
        let summaries = [long.id: "## Key Points\n" + filler + "- Drafting the Larkspur synthetic rollout plan."]
        XCTAssertGreaterThan(summaries[long.id]?.count ?? 0, 5_000)
        let transcript = ProjectLinks.TranscriptText(markdown: """
            **[00:05:10] Them 2:** Morning everyone.

            **[00:05:13] Them 3:** We finished the synthetic Larkspur checklist.

            **[00:05:16] Them 3:** Next is the risk engine.
            """)

        let projects = ProjectLinks.build(.init(
            curation: tracking(["Larkspur"]), meetings: [long, spoken], summaries: summaries,
            transcripts: [spoken.id: transcript]), now: now)

        let larkspur = try XCTUnwrap(projects.first)
        XCTAssertEqual(larkspur.meetings.map(\.id), [spoken.id, long.id])
        let mention = try XCTUnwrap(larkspur.meetings.first?.mention)
        XCTAssertEqual(mention.seek, 313)
        XCTAssertTrue(mention.text.hasPrefix("We finished the synthetic Larkspur checklist."))
        XCTAssertEqual(larkspur.meetings.last?.mention?.text, "Drafting the Larkspur synthetic rollout plan.")
    }

    func testExcerptKeepsTheNameInView() {
        let line = String(repeating: "The team scoped the synthetic withdrawal gate and pause policy. ", count: 10)
            + "Larkspur collateral lending stays out of scope for now, pending a partner."
        let excerpt = ProjectLinks.excerpt(line, around: [["larkspur"]])
        XCTAssertLessThanOrEqual(excerpt.count, ProjectLinks.maximumMentionCharacters)
        XCTAssertTrue(excerpt.hasPrefix("…"))
        XCTAssertTrue(excerpt.contains("Larkspur collateral lending"))
        XCTAssertFalse(excerpt.dropFirst().hasPrefix(" "))
        XCTAssertEqual(ProjectLinks.excerpt("Short Larkspur line.", around: [["larkspur"]]), "Short Larkspur line.")
    }

    func testOthersActionsAgeOutButTheUsersStay() throws {
        let recent = meeting("Larkspur sync", daysAgo: 3)
        let old = meeting("Larkspur sync", daysAgo: 40)
        let projects = ProjectLinks.build(.init(
            curation: tracking(["Larkspur"]), meetings: [recent, old],
            projections: [
                projection(recent, [.init(text: "Review the synthetic Larkspur spike", owner: "Mila")]),
                projection(old, [
                    .init(text: "Send the synthetic Larkspur guide", owner: "Them 8"),
                    .init(text: "Book the synthetic Larkspur audit", owner: "Ana", due: "2026-06-10"),
                    .init(text: "Write the synthetic Larkspur memo", owner: "Me"),
                ]),
            ]), now: now)

        let larkspur = try XCTUnwrap(projects.first)
        XCTAssertEqual(larkspur.myActions.map(\.text), ["Write the synthetic Larkspur memo"])
        XCTAssertEqual(Set(larkspur.othersActions.map(\.text)),
                       ["Review the synthetic Larkspur spike", "Book the synthetic Larkspur audit"])
        XCTAssertEqual(larkspur.olderOthersActions.map(\.text), ["Send the synthetic Larkspur guide"])
        XCTAssertEqual(larkspur.openActionCount, 3)
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
        XCTAssertEqual(ProjectLinks.mention(of: ["vireo"], in: "- [ ] Mila: Check the Vireo ticket tonight."),
                       "Mila: Check the Vireo ticket tonight.")
        XCTAssertEqual(ProjectLinks.mention(of: ["vireo"], in: "- **Them 4 · source 2:** Vireo strategy is underway."),
                       "Vireo strategy is underway.")
    }

    func testTranscriptLinesKeepTimesAndDropSpeakers() {
        let lines = ProjectLinks.transcriptLines(fromMarkdown: """
            **[00:13:21] Them 3:** yeah. What about Larkspur?

            **[01:02:03] Me:** Passed review.

            not a transcript line
            """)
        XCTAssertEqual(lines, [
            .init(start: 801, text: "yeah. What about Larkspur?"),
            .init(start: 3_723, text: "Passed review."),
        ])
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

    func testNearSpellingsOfPeopleAndCompanySuffixesAreNotTopics() {
        let meetings = (1...4).map { meeting("Weekly sync", daysAgo: Double($0)) }
        var summaries: [UUID: String] = [:]
        for meeting in meetings {
            summaries[meeting.id] = "## Notes\n- The risk model follows what Milana said about Kestrel and Corvid Labs."
        }
        let topics = ProjectTopicDetector.topics(meetings: meetings, summaries: summaries, projections: [],
                                                 excludedWords: ["milena"])
        XCTAssertEqual(topics.map(\.name), ["Corvid", "Kestrel"])
        XCTAssertTrue(ProjectTopicDetector.withinOneEdit("milena", "milana"))
        XCTAssertTrue(ProjectTopicDetector.withinOneEdit("milena", "milenas"))
        XCTAssertFalse(ProjectTopicDetector.withinOneEdit("milena", "malina"))
    }

    func testSentenceStartsAloneNeverMakeATopic() {
        let meetings = (1...4).map { meeting("Weekly sync", daysAgo: Double($0)) }
        var summaries: [UUID: String] = [:]
        for meeting in meetings {
            summaries[meeting.id] = "## Notes\n- Overall the synthetic rollout went fine.\n- Additionally we reviewed costs."
        }
        XCTAssertTrue(ProjectTopicDetector.topics(
            meetings: meetings, summaries: summaries, projections: [], excludedWords: []).isEmpty)
    }
}
