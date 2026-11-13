import XCTest
@testable import LokalBot

/// Matching the coming week's calendar events to people: by the address the
/// directory registered, then by name, and never without Calendar access.
/// Names and addresses are synthetic.
final class PeopleUpcomingMeetingsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_794_312_000) // 2026-11-10 12:00 UTC
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar
    }

    private func pastMeeting(_ title: String, daysAgo: Double,
                             attendees: [(String?, String?)]) -> Meeting {
        let start = now.addingTimeInterval(-daysAgo * 86_400)
        var meeting = Meeting(
            id: UUID(), title: title, appName: "Meet", startedAt: start,
            endedAt: start.addingTimeInterval(1_800), relativePath: "meetings/\(UUID().uuidString)")
        meeting.calendarParticipantIdentities = attendees.enumerated().compactMap { index, attendee in
            CalendarParticipantIdentity(id: "\(title)-\(index)", name: attendee.0, emailAddress: attendee.1)
        }
        return meeting
    }

    private func people(_ meetings: [Meeting], applied: [UUID: MeetingAppliedSpeakerNames] = [:],
                        curation: PeopleCuration = PeopleCuration()) -> [PersonProfile] {
        PeopleDirectory.build(.init(meetings: meetings, projections: [], appliedNames: applied,
                                    selfNames: ["Sam Reed"], curation: curation), now: now)
    }

    private func event(_ title: String, inHours hours: Double, minutes: Double = 30, id: String? = nil,
                       attendees: [(String?, String?)] = [], legacyNames: [String] = []) -> CalendarMeetingCandidate {
        let start = now.addingTimeInterval(hours * 3_600)
        return CalendarMeetingCandidate(
            provider: "test", externalID: id ?? title, title: title, startDate: start,
            endDate: start.addingTimeInterval(minutes * 60), meetingURL: nil, sourceCalendarTitle: nil,
            participantNames: legacyNames,
            participantIdentities: attendees.compactMap { CalendarParticipantIdentity(name: $0.0, emailAddress: $0.1) })
    }

    private func match(_ events: [CalendarMeetingCandidate]?, _ people: [PersonProfile],
                       recorded: Set<String> = []) -> [String: PersonUpcomingMeeting] {
        PeopleUpcomingMeetings.match(events: events, people: people, recordedEventIDs: recorded,
                                     selfNames: ["Sam Reed"], now: now, calendar: calendar)
    }

    private func id(_ name: String, in people: [PersonProfile]) throws -> String {
        try XCTUnwrap(people.first { $0.name == name }?.id, "No person named \(name)")
    }

    // MARK: - The cases the page depends on

    func testAPersonWithAnEventGetsItAndAPersonWithoutGetsNone() throws {
        let people = people([
            pastMeeting("Design review", daysAgo: 1, attendees: [("Ana Petrović", "ana@example.com")]),
            pastMeeting("Vendor check-in", daysAgo: 20, attendees: [("Marko Jovanović", "marko@example.com")]),
        ])
        let result = match([event("Atlas sync", inHours: 50, attendees: [("Ana Petrović", "ana@example.com")])],
                           people)

        let next = try XCTUnwrap(result[try id("Ana Petrović", in: people)])
        XCTAssertEqual(next.title, "Atlas sync")
        XCTAssertEqual(next.start, now.addingTimeInterval(50 * 3_600))
        XCTAssertEqual(next.others, [], "Nobody else is invited")
        XCTAssertNil(result[try id("Marko Jovanović", in: people)])
        XCTAssertEqual(result.count, 1)
    }

    func testTwoPeopleInOneEventEachSeeTheOther() throws {
        let people = people([pastMeeting("Standup", daysAgo: 1, attendees: [
            ("Ana Petrović", "ana@example.com"), ("Marko Jovanović", "marko@example.com"),
        ])])
        let result = match([event("Atlas sync", inHours: 26, attendees: [
            ("Ana Petrović", "ana@example.com"), ("Marko Jovanović", "marko@example.com"),
            ("Sam Reed", "sam@example.com"), ("Lena Novak", "lena@example.com"),
        ])], people)

        XCTAssertEqual(result[try id("Ana Petrović", in: people)]?.others, ["Marko Jovanović", "Lena Novak"])
        XCTAssertEqual(result[try id("Marko Jovanović", in: people)]?.others, ["Ana Petrović", "Lena Novak"],
                       "The user is never listed, and someone People does not know still is")
    }

    func testAnEventWithNoKnownAttendeeMatchesNobody() {
        let people = people([pastMeeting("Standup", daysAgo: 1, attendees: [("Ana Petrović", "ana@example.com")])])
        XCTAssertEqual(match([
            event("Interview", inHours: 5, attendees: [("Petar Lazić", "petar@example.com")]),
            event("Focus", inHours: 8),
        ], people), [:])
    }

    func testWithoutCalendarAccessNothingIsReadAndNobodyHasAMeeting() {
        let people = people([pastMeeting("Standup", daysAgo: 1, attendees: [("Ana Petrović", "ana@example.com")])])
        var fetched = 0
        let fetch: () -> [CalendarMeetingCandidate] = {
            fetched += 1
            return [self.event("Atlas sync", inHours: 5, attendees: [("Ana Petrović", "ana@example.com")])]
        }

        XCTAssertNil(PeopleUpcomingMeetings.events(calendarEnabled: false, authorization: .fullAccess, fetch: fetch))
        for status in [CalendarAuthorizationStatus.notDetermined, .denied, .restricted, .writeOnly] {
            XCTAssertNil(PeopleUpcomingMeetings.events(calendarEnabled: true, authorization: status, fetch: fetch))
        }
        XCTAssertEqual(fetched, 0, "The calendar is not read while Calendar use is off or access is missing")
        XCTAssertEqual(match(nil, people), [:])

        let read = PeopleUpcomingMeetings.events(calendarEnabled: true, authorization: .fullAccess, fetch: fetch)
        XCTAssertEqual(fetched, 1)
        XCTAssertEqual(match(read, people).count, 1)
    }

    // MARK: - Which event

    func testTheSoonestEventWinsAndEndedRecordedOrDistantEventsAreLeftOut() throws {
        let people = people([pastMeeting("Standup", daysAgo: 1, attendees: [("Ana Petrović", "ana@example.com")])])
        let ana: [(String?, String?)] = [("Ana Petrović", "ana@example.com")]
        let ended = event("Ended", inHours: -2, attendees: ana)
        let recorded = event("Recorded", inHours: 1, id: "recorded#1", attendees: ana)
        let later = event("Later this week", inHours: 70, attendees: ana)
        let soonest = event("Tomorrow", inHours: 20, attendees: ana)
        let distant = event("Next month", inHours: 8 * 24, attendees: ana)
        let anaID = try id("Ana Petrović", in: people)

        let result = match([distant, later, ended, soonest, recorded], people, recorded: ["recorded#1"])
        XCTAssertEqual(result[anaID]?.title, "Tomorrow")
        XCTAssertNil(match([ended, distant], people)[anaID], "Only the next seven days count")

        let underWay = event("Under way", inHours: -0.25, attendees: ana)
        let current = try XCTUnwrap(match([underWay, soonest], people)[anaID])
        XCTAssertEqual(current.title, "Under way")
        XCTAssertTrue(current.isInProgress(at: now))
    }

    // MARK: - Who it is

    func testAnAddressFindsThePersonUnderAnyNameAndAfterAMerge() throws {
        let first = pastMeeting("Roadmap", daysAgo: 3, attendees: [("Ana Petrović", "ana@example.com")])
        let second = pastMeeting("Pricing", daysAgo: 2, attendees: [("Anna P.", "anna.p@example.org")])
        let unmerged = people([first, second])
        let source = try XCTUnwrap(unmerged.first { $0.name == "Anna P." })
        let target = try XCTUnwrap(unmerged.first { $0.name == "Ana Petrović" })
        let merged = people([first, second], curation: PeopleCuration(
            merges: [.init(sourceID: source.id, targetID: target.id, sourceName: source.name)]))
        XCTAssertEqual(merged.count, 1)

        let result = match([event("Atlas sync", inHours: 30, attendees: [("A. Petrovic", "anna.p@example.org")])],
                           merged)
        XCTAssertEqual(result[target.id]?.title, "Atlas sync", "The merged-in address still reaches the person")
    }

    func testANameFindsOnlyTheOnePersonWhoCarriesIt() throws {
        // Two people share a full name under different addresses; a third is
        // known only by a name the user gave a speaker.
        let roadmap = pastMeeting("Roadmap", daysAgo: 3, attendees: [("Ana Petrović", "ana@example.com")])
        let pricing = pastMeeting("Pricing", daysAgo: 2, attendees: [("Ana Petrović", "ana@elsewhere.example")])
        let chat = pastMeeting("Chat", daysAgo: 1, attendees: [])
        let people = people([roadmap, pricing, chat], applied: [chat.id: .init(names: ["Dragan Ilić"])])
        XCTAssertEqual(people.filter { $0.name == "Ana Petrović" }.count, 2)
        let dragan = try id("Dragan Ilić", in: people)

        // A new address under a shared name is nobody People knows.
        XCTAssertEqual(match([event("Kickoff", inHours: 4, attendees: [("Ana Petrović", "ana@third.example")])],
                             people), [:])
        // A name-only invitation cannot choose between the two either.
        XCTAssertEqual(match([event("Kickoff", inHours: 4, legacyNames: ["Ana Petrović"])], people), [:])
        // Someone known only by name takes an address, a bare name, or a lone first name.
        XCTAssertEqual(match([event("1:1", inHours: 4, attendees: [("Dragan Ilić", "dragan@example.com")])],
                             people)[dragan]?.title, "1:1")
        XCTAssertEqual(match([event("1:1", inHours: 4, legacyNames: ["dragan ilic"])], people)[dragan]?.title, "1:1")
        XCTAssertEqual(match([event("1:1", inHours: 4, legacyNames: ["Dragan"])], people)[dragan]?.title, "1:1")
    }

    func testAnAddressWithoutANameIsNeverShown() throws {
        let people = people([pastMeeting("Standup", daysAgo: 1, attendees: [("Ana Petrović", "ana@example.com")])])
        let result = match([event("Review", inHours: 3, attendees: [
            ("Ana Petrović", "ana@example.com"), (nil, "kevlee88@gmail.com"), (nil, "maya.chen@gmail.com"),
        ])], people)

        let others = try XCTUnwrap(result[try id("Ana Petrović", in: people)]?.others)
        XCTAssertEqual(others, ["Maya Chen"], "A spelled-out mailbox reads as a name; a handle is left out")
        XCTAssertFalse(others.contains { $0.contains("@") })
    }

    func testTheShownNameIsTheOneThePersonChose() throws {
        let meeting = pastMeeting("Standup", daysAgo: 1, attendees: [
            ("Ana Petrović", "ana@example.com"), ("Marko Jovanović", "marko@example.com"),
        ])
        let marko = try id("Marko Jovanović", in: people([meeting]))
        let renamed = people([meeting], curation: PeopleCuration(names: [marko: "Marko J."]))
        let result = match([event("Atlas sync", inHours: 26, attendees: [
            ("Ana Petrović", "ana@example.com"), ("Marko Jovanović", "marko@example.com"),
        ])], renamed)
        XCTAssertEqual(result[try id("Ana Petrović", in: renamed)]?.others, ["Marko J."])
    }
}
