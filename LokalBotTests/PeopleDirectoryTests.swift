import XCTest
@testable import LokalBot

final class PeopleDirectoryTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_780_000_000)

    private func meeting(_ title: String, day: Double,
                         attendees: [(String?, String?, String)] = []) -> Meeting {
        var meeting = Meeting(
            id: UUID(), title: title, appName: "Meet",
            startedAt: base.addingTimeInterval(day * 86_400),
            endedAt: base.addingTimeInterval(day * 86_400 + 1_800),
            relativePath: "meetings/\(UUID().uuidString)")
        meeting.calendarParticipantIdentities = attendees.compactMap {
            CalendarParticipantIdentity(id: $0.2, name: $0.0, emailAddress: $0.1)
        }
        return meeting
    }

    private func projection(_ meeting: Meeting, actions: [MeetingOutcomes.ActionItem] = [],
                            decisions: [String] = []) -> MeetingOutcomeProjection {
        let outcomes = MeetingOutcomes(actionItems: actions, decisions: decisions)
        return MeetingOutcomeProjection(
            meeting: meeting, outcomes: outcomes, state: MeetingOutcomeState(),
            followUp: FollowUpDraft.seeded(for: meeting, outcomes: outcomes))
    }

    func testJoinsCalendarAttendeesAppliedNamesAndOwnersIntoOnePerson() throws {
        let first = meeting("Pricing sync", day: -7, attendees: [("Ana Petrović", "ana@example.com", "a1")])
        let second = meeting("Pricing sync", day: -1, attendees: [(nil, "ana@example.com", "a2")])
        let ownerAction = MeetingOutcomes.ActionItem(text: "Send the updated synthetic price table", owner: "Ana")
        let input = PeopleDirectory.Input(
            meetings: [first, second],
            projections: [projection(first), projection(second, actions: [ownerAction],
                                                         decisions: ["Keep the synthetic tier"])],
            appliedNames: [second.id: .init(names: ["Ana"], namesByCalendarIdentityID: ["a2": "Ana"])])

        let people = PeopleDirectory.build(input, now: base)

        XCTAssertEqual(people.count, 1)
        let ana = try XCTUnwrap(people.first)
        XCTAssertEqual(ana.name, "Ana Petrović")
        XCTAssertEqual(ana.meetings.map(\.id), [second.id, first.id])
        XCTAssertEqual(ana.theirActions.map(\.text), ["Send the updated synthetic price table"])
        XCTAssertEqual(ana.decisions.map(\.text), ["Keep the synthetic tier"])
        XCTAssertFalse(ana.id.contains("@"))
        XCTAssertFalse(([ana.name] + ana.otherNames).contains { $0.contains("@") })
    }

    func testMyActionsNameThePersonOrComeFromASmallMeeting() {
        let allHands = meeting("All hands", day: -2, attendees: [
            ("Ana Petrović", "ana@example.com", "a"), ("Marko Jovanović", "marko@example.com", "m"),
            ("Ivana Ilić", "ivana@example.com", "i"),
        ])
        let oneOnOne = meeting("Marko 1:1", day: -1, attendees: [("Marko Jovanović", "marko@example.com", "m2")])
        let mentionsAna = MeetingOutcomes.ActionItem(text: "Share the synthetic roadmap with Ana", owner: "Me")
        let unnamed = MeetingOutcomes.ActionItem(text: "Review the synthetic hiring plan draft", owner: "Me")
        let unrelated = MeetingOutcomes.ActionItem(text: "Book the synthetic offsite venue", owner: "Me")
        let people = PeopleDirectory.build(.init(
            meetings: [allHands, oneOnOne],
            projections: [projection(allHands, actions: [mentionsAna, unrelated]),
                          projection(oneOnOne, actions: [unnamed])]), now: base)

        let byName = Dictionary(uniqueKeysWithValues: people.map { ($0.name, $0) })
        XCTAssertEqual(byName["Ana Petrović"]?.myActions.map(\.text), ["Share the synthetic roadmap with Ana"])
        XCTAssertEqual(byName["Marko Jovanović"]?.myActions.map(\.text), ["Review the synthetic hiring plan draft"])
        XCTAssertEqual(byName["Ivana Ilić"]?.myActions.count, 0)
        // All-hands decisions are not attributed to every attendee.
        XCTAssertEqual(people.first?.name, "Marko Jovanović")
    }

    func testMergedPeopleKeepTheirMeetingActionsAndDecisionsInEitherInputOrder() throws {
        // A 1:1 recorded without a calendar event, where the user applied the
        // speaker name, and a later calendar meeting with the same person.
        let oneOnOne = meeting("Roadmap chat", day: -3)
        let calendarMeeting = meeting("Planning", day: -1,
                                      attendees: [("Ana Petrović", "ana@example.com", "a")])
        let action = MeetingOutcomes.ActionItem(text: "Send the synthetic roadmap draft", owner: "Me")
        let projections = [projection(oneOnOne, actions: [action], decisions: ["Ship the synthetic beta"]),
                           projection(calendarMeeting)]
        let applied: [UUID: MeetingAppliedSpeakerNames] = [oneOnOne.id: .init(names: ["Ana Petrović"])]

        for order in [[oneOnOne, calendarMeeting], [calendarMeeting, oneOnOne]] {
            let people = PeopleDirectory.build(
                .init(meetings: order, projections: projections, appliedNames: applied), now: base)
            XCTAssertEqual(people.count, 1, "\(order.map(\.title))")
            let ana = try XCTUnwrap(people.first)
            XCTAssertEqual(ana.myActions.map(\.text), ["Send the synthetic roadmap draft"])
            XCTAssertEqual(ana.decisions.map(\.text), ["Ship the synthetic beta"])
            XCTAssertEqual(Set(ana.meetings.map(\.id)), [oneOnOne.id, calendarMeeting.id])
        }
    }

    func testEmailOnlyAttendeesWithoutANameAreNotListed() {
        let call = meeting("Vendor call", day: -1, attendees: [(nil, "vendor.contact@example.com", "v")])
        XCTAssertTrue(PeopleDirectory.build(.init(meetings: [call], projections: []), now: base).isEmpty)
    }

    func testUnmatchedOwnerBecomesANamedPersonAndMergesByFullName() {
        let early = meeting("Kickoff", day: -5)
        let later = meeting("Follow-up", day: -1, attendees: [("Dragan Ilić", "dragan@example.com", "d")])
        let action = MeetingOutcomes.ActionItem(text: "Draft the synthetic integration contract", owner: "Dragan Ilić")
        let people = PeopleDirectory.build(.init(
            meetings: [early, later], projections: [projection(early, actions: [action])]), now: base)
        XCTAssertEqual(people.map(\.name), ["Dragan Ilić"])
        XCTAssertEqual(people.first?.theirActions.count, 1)
        XCTAssertEqual(Set(people.first?.meetings.map(\.id) ?? []), [early.id, later.id])
    }

    func testOwnerResolutionPrefersTheMeetingRoster() {
        let one = meeting("One", day: -2, attendees: [("Ana Petrović", "ana@example.com", "a")])
        let two = meeting("Two", day: -1, attendees: [("Ana Kovač", "kovac@example.com", "k")])
        let people = PeopleDirectory.build(.init(meetings: [one, two], projections: []), now: base)
        XCTAssertEqual(PeopleDirectory.person(forOwner: "Ana", meetingID: one.id, in: people)?.name, "Ana Petrović")
        XCTAssertEqual(PeopleDirectory.person(forOwner: "Ana", meetingID: two.id, in: people)?.name, "Ana Kovač")
        XCTAssertNil(PeopleDirectory.person(forOwner: "Ana", meetingID: UUID(), in: people))
        XCTAssertEqual(PeopleDirectory.person(forOwner: "ana kovac", meetingID: UUID(), in: people)?.name, "Ana Kovač")
    }

    func testAppliedNamesIgnoreTheUsersOwnMicrophoneLabel() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("people-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let transcript = Transcript(segments: [], engine: "fixture",
                                    speakerAliases: ["me": "Stevan", "them 2": "Mila Novak"])
        try JSONEncoder().encode(transcript).write(to: folder.appendingPathComponent("transcript.json"))
        XCTAssertEqual(MeetingAppliedSpeakerNames.load(from: folder).names, ["Mila Novak"])
    }
}
