import XCTest
@testable import LokalBot

/// The People page's read model: meetings recorded in parts, series,
/// decisions in larger meetings, the person's corrections, notes about the
/// person, and the projects named around them. Names are synthetic.
final class PeoplePageTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_780_000_000)
    private let ana = ("Ana Petrović", "ana@example.com")
    private let marko = ("Marko Jovanović", "marko@example.com")

    private func meeting(_ title: String, day: Double, minutes: Double = 30, offsetMinutes: Double = 0,
                         eventID: String? = nil,
                         attendees: [(String, String)] = []) -> Meeting {
        let start = base.addingTimeInterval(day * 86_400 + offsetMinutes * 60)
        var meeting = Meeting(
            id: UUID(), title: title, appName: "Meet", startedAt: start,
            endedAt: start.addingTimeInterval(minutes * 60), relativePath: "meetings/\(UUID().uuidString)")
        meeting.calendarEventID = eventID
        var identities: [CalendarParticipantIdentity] = []
        for (index, attendee) in attendees.enumerated() {
            if let identity = CalendarParticipantIdentity(id: "\(title)-\(day)-\(index)", name: attendee.0,
                                                          emailAddress: attendee.1) {
                identities.append(identity)
            }
        }
        meeting.calendarParticipantIdentities = identities
        return meeting
    }

    private func projection(_ meeting: Meeting, actions: [MeetingOutcomes.ActionItem] = [],
                            decisions: [MeetingOutcomes.Decision] = []) -> MeetingOutcomeProjection {
        var outcomes = MeetingOutcomes(actionItems: actions)
        outcomes.decisionRecords = decisions
        return MeetingOutcomeProjection(
            meeting: meeting, outcomes: outcomes, state: MeetingOutcomeState(),
            followUp: FollowUpDraft.seeded(for: meeting, outcomes: outcomes))
    }

    private func build(_ meetings: [Meeting], projections: [MeetingOutcomeProjection] = [],
                       applied: [UUID: MeetingAppliedSpeakerNames] = [:],
                       curation: PeopleCuration = PeopleCuration()) -> [PersonProfile] {
        PeopleDirectory.build(.init(meetings: meetings, projections: projections, appliedNames: applied,
                                    selfNames: ["Sam Reed"], curation: curation), now: base)
    }

    // MARK: - Meetings recorded in parts

    func testRecordingsOfOneCalendarEventCountAsOneMeeting() throws {
        let first = meeting("Demo Day", day: -2, minutes: 8, eventID: "demo#2", attendees: [ana])
        let second = meeting("Demo Day", day: -2, minutes: 50, offsetMinutes: 9, eventID: "demo#2", attendees: [ana])
        let lastWeek = meeting("Demo Day", day: -9, eventID: "demo#1", attendees: [ana])
        let person = try XCTUnwrap(build([first, second, lastWeek]).first)

        XCTAssertEqual(person.meetings.count, 3)
        XCTAssertEqual(person.meetingCount, 2)
        let latest = try XCTUnwrap(person.occasions.first)
        XCTAssertEqual(Set(latest.recordings.map(\.id)), [first.id, second.id])
        XCTAssertEqual(latest.primary.id, second.id, "The longest recording is the one to open")
    }

    func testWithoutAnEventOnlyBackToBackRecordingsWithOneTitleJoin() {
        let morning = meeting("Pricing sync", day: -1, minutes: 20, attendees: [ana])
        let resumed = meeting("Pricing sync", day: -1, minutes: 20, offsetMinutes: 30, attendees: [ana])
        let afternoon = meeting("Pricing sync", day: -1, minutes: 20, offsetMinutes: 300, attendees: [ana])
        let other = meeting("Hiring", day: -1, minutes: 20, offsetMinutes: 25, attendees: [ana])
        let person = build([morning, resumed, afternoon, other]).first

        XCTAssertEqual(person?.meetingCount, 3)
        XCTAssertEqual(person?.occasions.map(\.recordings.count).sorted(), [1, 1, 2])
    }

    func testSeriesGroupMeetingsByTitleNewestSeriesFirst() throws {
        let meetings = [
            meeting("Product Standup", day: -1, attendees: [ana]),
            meeting("Product Standup", day: -3, attendees: [ana]),
            meeting("Roadmap review", day: -2, attendees: [ana]),
            meeting("product standup", day: -5, attendees: [ana]),
        ]
        let person = try XCTUnwrap(build(meetings).first)
        XCTAssertEqual(person.series.map(\.title), ["Product Standup", "Roadmap review"])
        XCTAssertEqual(person.series.map(\.occasions.count), [3, 1])
    }

    // MARK: - Decisions in larger meetings

    func testLargerMeetingDecisionsGoOnlyToWhoSaidThemOrIsNamed() throws {
        let attendees = [ana, marko, ("Ivana Ilić", "ivana@example.com"), ("Petar Lazić", "petar@example.com"),
                         ("Mila Novak", "mila@example.com")]
        let allHands = meeting("All hands", day: -1, attendees: attendees)
        let named = MeetingOutcomes.Decision(text: "Ana Petrović owns the synthetic rollout")
        let spoken = MeetingOutcomes.Decision(
            text: "Keep the synthetic beta closed until review",
            attribution: StatementAttribution(speakerID: "s2", speakerLabel: "Them 2", identity: .other,
                                              quote: "Let's keep it closed"))
        let general = MeetingOutcomes.Decision(text: "Move the synthetic offsite to spring")
        let applied: [UUID: MeetingAppliedSpeakerNames] = [
            allHands.id: .init(names: ["Marko"], namesBySpeakerKey: ["them 2": "Marko"]),
        ]
        let people = build([allHands], projections: [projection(allHands, decisions: [named, spoken, general])],
                           applied: applied)
        let byName = Dictionary(uniqueKeysWithValues: people.map { ($0.name, $0) })

        XCTAssertEqual(byName["Ana Petrović"]?.decisions.map(\.text), ["Ana Petrović owns the synthetic rollout"])
        XCTAssertEqual(byName["Marko Jovanović"]?.decisions.map(\.text), ["Keep the synthetic beta closed until review"])
        XCTAssertEqual(byName["Ivana Ilić"]?.decisions.count, 0)
    }

    func testNamesNeedACapitalAndCommonWordsDoNotCountAtASentenceStart() {
        XCTAssertTrue(PeopleDirectory.isNamed("Ana Petrović", in: "Coordinate with ana petrović? No: with Ana Petrović."))
        XCTAssertTrue(PeopleDirectory.isNamed("Alex", in: "Alex will review the synthetic spec."))
        XCTAssertTrue(PeopleDirectory.isNamed("Ana Petrovic", in: "Sync with Ana about it"))
        XCTAssertFalse(PeopleDirectory.isNamed("Alex", in: "alex is lowercase here"))
        XCTAssertFalse(PeopleDirectory.isNamed("Will Moss", in: "Will the synthetic build pass?"))
        XCTAssertTrue(PeopleDirectory.isNamed("Will Moss", in: "Ask Will about the build."))
        XCTAssertTrue(PeopleDirectory.isNamed("Will Moss", in: "Will Moss shipped the build."))
        XCTAssertFalse(PeopleDirectory.isNamed("Ana", in: "Banana bread"))
    }

    // MARK: - Corrections

    func testChosenNameKeepsTheIdAndRecognizesTheNewNameInOwners() throws {
        let call = meeting("Vendor call", day: -2, attendees: [("Radmirkaz Ca", "rk@example.com")])
        let later = meeting("Follow-up", day: -1)
        let original = try XCTUnwrap(build([call]).first)
        let curation = PeopleCuration(names: [original.id: "Radmir Kazan"])
        let owned = MeetingOutcomes.ActionItem(text: "Send the synthetic invoice", owner: "Radmir Kazan")
        let people = build([call, later], projections: [projection(later, actions: [owned])], curation: curation)

        XCTAssertEqual(people.count, 1)
        let renamed = try XCTUnwrap(people.first)
        XCTAssertEqual(renamed.id, original.id)
        XCTAssertEqual(renamed.name, "Radmir Kazan")
        XCTAssertEqual(renamed.otherNames, ["Radmirkaz Ca"])
        XCTAssertEqual(renamed.theirActions.map(\.text), ["Send the synthetic invoice"])
    }

    func testMergeFoldsOnePersonIntoAnotherAndHiddenPeopleDisappear() throws {
        let first = meeting("Design crit", day: -3, attendees: [("Mila N", "mila.personal@example.com")])
        let second = meeting("Design crit", day: -1, attendees: [("Mila Novak", "mila@example.com"), marko])
        let owned = MeetingOutcomes.ActionItem(text: "Share the synthetic mockups", owner: "Mila N")
        let projections = [projection(first, actions: [owned])]
        let before = build([first, second], projections: projections)
        let source = try XCTUnwrap(before.first { $0.name == "Mila N" })
        let target = try XCTUnwrap(before.first { $0.name == "Mila Novak" })
        let markoID = try XCTUnwrap(before.first { $0.name == "Marko Jovanović" }).id

        let curation = PeopleCuration(
            merges: [.init(sourceID: source.id, targetID: target.id, sourceName: source.name)],
            hidden: [.init(id: markoID, name: "Marko Jovanović")])
        let after = build([first, second], projections: projections, curation: curation)

        XCTAssertEqual(after.map(\.name), ["Mila Novak"])
        let mila = try XCTUnwrap(after.first)
        XCTAssertEqual(mila.id, target.id)
        XCTAssertEqual(mila.otherNames, ["Mila N"])
        XCTAssertTrue(mila.memberIDs.contains(source.id))
        XCTAssertEqual(mila.meetingCount, 2)
        XCTAssertEqual(mila.theirActions.map(\.text), ["Share the synthetic mockups"])
    }

    func testMergeOfAPersonFirstSeenAsAnOwnerApplies() throws {
        let call = meeting("Launch review", day: -1, attendees: [ana, marko, ("Ivana Ilić", "ivana@example.com")])
        let owned = MeetingOutcomes.ActionItem(text: "Book the synthetic venue", owner: "Anica")
        let projections = [projection(call, actions: [owned])]
        let before = build([call], projections: projections)
        let anica = try XCTUnwrap(before.first { $0.name == "Anica" })
        let anaID = try XCTUnwrap(before.first { $0.name == "Ana Petrović" }).id

        let after = build([call], projections: projections, curation: PeopleCuration(
            merges: [.init(sourceID: anica.id, targetID: anaID, sourceName: "Anica")]))
        XCTAssertNil(after.first { $0.name == "Anica" })
        XCTAssertEqual(after.first { $0.id == anaID }?.theirActions.map(\.text), ["Book the synthetic venue"])
    }

    // MARK: - Stale open work

    func testOpenWorkNobodyMentionedForWeeksIsStaleUnlessDueAhead() throws {
        let call = meeting("Pricing sync", day: -30, attendees: [ana])
        let quiet = MeetingOutcomes.ActionItem(text: "Send the synthetic price table", owner: "Ana")
        let dueLater = MeetingOutcomes.ActionItem(text: "Draft the synthetic renewal", owner: "Ana", due: "2027-01-15")
        let person = try XCTUnwrap(build([call], projections: [projection(call, actions: [quiet, dueLater])]).first)
        let byText = Dictionary(uniqueKeysWithValues: person.theirActions.map { ($0.text, $0) })

        XCTAssertEqual(byText["Send the synthetic price table"]?.daysSinceLastMention(now: base), 30)
        XCTAssertEqual(byText["Send the synthetic price table"]?.isStale(now: base), true)
        XCTAssertEqual(byText["Send the synthetic price table"]?.isStale(now: base.addingTimeInterval(-15 * 86_400)), false)
        XCTAssertEqual(byText["Draft the synthetic renewal"]?.isStale(now: base), false)
    }

    // MARK: - Notes about the person

    private let standupSummary = """
    # Product Standup — synthetic
    **Duration:** 17 min

    ## TL;DR

    - **Them 4:** The synthetic optimizer review went out yesterday. — [00:01:54]
    - **Them 1:** Larkspur contracts need a rename before the audit. — [00:09:02]

    ## Key points

    - **Them 4:** The synthetic optimizer review went out yesterday. — [00:01:54]
    - **You:** Checking the Larkspur spec with Nikola and Alex this week. — [00:08:41]
    - Them 2: Coordination with Alex is needed on the alert triggers. — [00:17:35]
    - **Them 6:** The deployment pipelines now share one library. — [00:09:36]

    ## Decisions

    - Alex owns the synthetic alert rewrite. — [00:12:00]

    ## Action items

    ### Others
    - [ ] Them 7: Review the synthetic optimizer spec with Alex. — [00:10:33]

    ## Open questions

    None
    """

    func testOwnerListsAreNotOnePerson() {
        XCTAssertFalse(PeopleDirectory.isPersonName("Matt, John, Emil"))
        XCTAssertFalse(PeopleDirectory.isPersonName("Ana and Marko"))
        XCTAssertFalse(PeopleDirectory.isPersonName("Ana & Marko"))
        XCTAssertTrue(PeopleDirectory.isPersonName("Andrea Anderson"))
    }

    func testOlderStampFormatsBecomeTheMomentAndLeaveTheText() {
        let summary = """
        ## Key points

        - Tony will share a tangible build so others can test it. ([00:40:44]–[00:44:40])
        - Participants: Eric runs research [00:04:22]; Jonathan joined later [00:05:10]
        """
        let lines = PersonNotes.lines(fromSummary: summary)
        XCTAssertEqual(lines.map(\.text), ["Tony will share a tangible build so others can test it.",
                                           "Participants: Eric runs research; Jonathan joined later"])
        XCTAssertEqual(lines.map(\.seek), [2_444, 262])
    }

    func testSummaryLinesKeepSpeakerAndMomentAndSkipActionsAndDecisions() {
        let lines = PersonNotes.lines(fromSummary: standupSummary)
        XCTAssertEqual(lines.count, 6)
        XCTAssertEqual(lines.first?.speaker, "Them 4")
        XCTAssertEqual(lines.first?.text, "The synthetic optimizer review went out yesterday.")
        XCTAssertEqual(lines.first?.seek, 114)
        XCTAssertEqual(lines.first?.section, "tl dr")
        XCTAssertTrue(lines.contains { $0.speaker == "Them 2" && $0.text.hasPrefix("Coordination") })
        XCTAssertFalse(lines.contains { $0.text.contains("alert rewrite") || $0.text.contains("Review the synthetic") })
    }

    func testRecentNotesTakeTheNewestMeetingWithLinesByOrAboutThePerson() throws {
        let alex = ("Alex Moretti", "alex@example.com")
        let attendees = [alex, ana, marko, ("Nikola Ilić", "nikola@example.com")]
        let older = meeting("Product Standup", day: -3, attendees: attendees)
        let newest = meeting("Product Standup", day: -1, attendees: attendees)
        let person = try XCTUnwrap(build([older, newest]).first { $0.name == "Alex Moretti" })
        let lines: [UUID: [PersonNotes.SummaryLine]] = [
            older.id: PersonNotes.lines(fromSummary: standupSummary),
            newest.id: PersonNotes.lines(fromSummary: "## Key points\n\n- **Them 3:** Nothing about the people here today. — [00:00:10]"),
        ]
        let applied: [UUID: MeetingAppliedSpeakerNames] = [older.id: .init(namesBySpeakerKey: ["them 4": "Alex"])]

        let notes = try XCTUnwrap(PersonNotes.recentNotes(for: person, lines: lines, appliedNames: applied))
        XCTAssertEqual(notes.meetingID, older.id)
        XCTAssertFalse(notes.isLatestMeeting)
        XCTAssertEqual(notes.points.map(\.text), [
            "The synthetic optimizer review went out yesterday.",
            "Checking the Larkspur spec with Nikola and Alex this week.",
            "Coordination with Alex is needed on the alert triggers.",
        ])
        XCTAssertEqual(notes.points.map(\.speaker), [nil, "You", nil])
        XCTAssertEqual(notes.points.first?.seek, 114)
    }

    func testAMeetingOnlyWithThePersonOffersItsOverview() throws {
        let oneOnOne = meeting("Ana / Sam", day: -1, attendees: [ana])
        let person = try XCTUnwrap(build([oneOnOne]).first)
        let summary = "## TL;DR\n\n- **Them 1:** The synthetic hiring plan is ready for review. — [00:02:00]\n\n## Key points\n\n- **Them 1:** The synthetic hiring plan is ready for review. — [00:02:00]"
        let notes = PersonNotes.recentNotes(for: person, lines: [oneOnOne.id: PersonNotes.lines(fromSummary: summary)],
                                            appliedNames: [:])
        XCTAssertEqual(notes?.points.map(\.text), ["The synthetic hiring plan is ready for review."])
        XCTAssertEqual(notes?.isLatestMeeting, true)
    }

    func testProjectsNamedAroundThePersonTrackedFirst() throws {
        let alex = ("Alex Moretti", "alex@example.com")
        let standup = meeting("Product Standup", day: -1, attendees: [alex, ana, marko, ("Nikola Ilić", "n@example.com")])
        let owned = MeetingOutcomes.ActionItem(text: "Write the Vireo test plan", owner: "Alex")
        let people = build([standup], projections: [projection(standup, actions: [owned])])
        let person = try XCTUnwrap(people.first { $0.name == "Alex Moretti" })
        let lines = [standup.id: PersonNotes.lines(fromSummary: standupSummary)]
        func project(_ name: String, tracked: Bool) -> ProjectProfile {
            ProjectProfile(id: (tracked ? "tracked:" : "topic:") + name, name: name,
                           kind: tracked ? .tracked(UUID()) : .suggestedTopic, otherNames: [], meetings: [],
                           myActions: [], othersActions: [], olderOthersActions: [], decisions: [], reviewNotes: [],
                           days: [], windows: [], people: [], lastActive: nil)
        }
        let links = PersonNotes.projects(
            for: person, lines: lines, appliedNames: [:],
            projects: [project("Vireo", tracked: false), project("Larkspur", tracked: true), project("Heron", tracked: true)])

        XCTAssertEqual(links.map(\.name), ["Larkspur", "Vireo"])
        XCTAssertEqual(links.first?.isTracked, true)
    }
}
