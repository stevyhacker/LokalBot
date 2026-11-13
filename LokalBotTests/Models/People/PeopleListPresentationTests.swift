import XCTest
@testable import LokalBot

/// The People list as drawn (grouped by time only, with one badge per row),
/// and the wording on a person's page. Names are synthetic.
final class PeopleListPresentationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_794_312_000) // Tuesday 2026-11-10 12:00 UTC
    private let locale = Locale(identifier: "en_US")
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        calendar.locale = locale
        return calendar
    }

    private let ana = ("Ana Petrović", "ana@example.com")
    private let marko = ("Marko Jovanović", "marko@example.com")
    private let ivana = ("Ivana Ilić", "ivana@example.com")
    private let petar = ("Petar Lazić", "petar@example.com")
    private let lena = ("Lena Novak", "lena@example.com")

    private func meeting(_ title: String, hoursAgo: Double, attendees: [(String, String)]) -> Meeting {
        let start = now.addingTimeInterval(-hoursAgo * 3_600)
        var meeting = Meeting(
            id: UUID(), title: title, appName: "Meet", startedAt: start,
            endedAt: start.addingTimeInterval(1_800), relativePath: "meetings/\(UUID().uuidString)")
        meeting.calendarParticipantIdentities = attendees.enumerated().compactMap { index, attendee in
            CalendarParticipantIdentity(id: "\(title)-\(hoursAgo)-\(index)", name: attendee.0, emailAddress: attendee.1)
        }
        return meeting
    }

    private func projection(_ meeting: Meeting, actions: [MeetingOutcomes.ActionItem]) -> MeetingOutcomeProjection {
        let outcomes = MeetingOutcomes(actionItems: actions)
        return MeetingOutcomeProjection(
            meeting: meeting, outcomes: outcomes, state: MeetingOutcomeState(),
            followUp: FollowUpDraft.seeded(for: meeting, outcomes: outcomes))
    }

    private func upcoming(_ title: String, inHours hours: Double, others: [String] = []) -> PersonUpcomingMeeting {
        let start = now.addingTimeInterval(hours * 3_600)
        return PersonUpcomingMeeting(eventID: title, title: title, start: start,
                                     end: start.addingTimeInterval(1_800), others: others)
    }

    /// Ana: met yesterday, work open both ways. Marko: three days ago, owes
    /// one. Petar: an hour ago. Ivana: 20 days ago. Lena: 40 days ago.
    private func library() -> [PersonProfile] {
        let review = meeting("Design review", hoursAgo: 24, attendees: [ana])
        let standup = meeting("Standup", hoursAgo: 72, attendees: [marko])
        let kickoff = meeting("Kickoff", hoursAgo: 1, attendees: [petar])
        let vendor = meeting("Vendor check-in", hoursAgo: 20 * 24, attendees: [ivana])
        let roadmap = meeting("Roadmap planning", hoursAgo: 40 * 24, attendees: [lena])
        return PeopleDirectory.build(.init(
            meetings: [review, standup, kickoff, vendor, roadmap],
            projections: [
                projection(review, actions: [
                    .init(text: "Draft the synthetic eviction policy", owner: "Me"),
                    .init(text: "Benchmark the synthetic failover", owner: "Ana"),
                ]),
                projection(standup, actions: [.init(text: "Send the synthetic rebuild estimate", owner: "Marko")]),
            ],
            selfNames: ["Sam Reed"]), now: now)
    }

    private func build(_ people: [PersonProfile], upcoming: [String: PersonUpcomingMeeting] = [:],
                       query: String = "") -> PeopleListContent {
        PeopleListContent.build(people: people, upcoming: upcoming, query: query, now: now,
                                calendar: calendar, locale: locale)
    }

    private func id(_ name: String, in people: [PersonProfile]) throws -> String {
        try XCTUnwrap(people.first { $0.name == name }?.id, "No person named \(name)")
    }

    /// Times come with narrow and thin spaces; compare the words.
    private func plain(_ text: String) -> String {
        String(text.map { $0.isWhitespace ? " " : $0 })
    }

    // MARK: - Grouping and order

    func testWithoutCalendarPeopleGroupByWhenYouLastMet() {
        let content = build(library())

        XCTAssertEqual(content.sections.map(\.group), [.recent, .earlier])
        XCTAssertEqual(content.sections.map { $0.rows.map(\.name) },
                       [["Petar Lazić", "Ana Petrović", "Marko Jovanović"], ["Ivana Ilić", "Lena Novak"]],
                       "Newest first; open work no longer moves anyone up")
        XCTAssertEqual(content.sections.map(\.group.title), ["Last 2 weeks", "Earlier"])
    }

    func testComingUpLeadsInMeetingOrderThenRecency() throws {
        let people = library()
        let next = [
            try id("Marko Jovanović", in: people): upcoming("Atlas sync", inHours: 50),
            try id("Lena Novak", in: people): upcoming("Borealis review", inHours: 20),
            try id("Ana Petrović", in: people): upcoming("Atlas sync", inHours: 50),
        ]
        let content = build(people, upcoming: next)

        XCTAssertEqual(content.sections.map(\.group), [.comingUp, .recent, .earlier])
        XCTAssertEqual(content.sections.map { $0.rows.map(\.name) }, [
            ["Lena Novak", "Ana Petrović", "Marko Jovanović"], ["Petar Lazić"], ["Ivana Ilić"],
        ], "The sooner meeting first; two people in one meeting by who you met last")
        XCTAssertEqual(content.personIDs.first, try id("Lena Novak", in: people))
    }

    func testRowsShowTheNextOrLatestMeetingAndWhen() throws {
        let people = library()
        let content = build(people, upcoming: [
            try id("Marko Jovanović", in: people): upcoming("Atlas sync", inHours: 50),
            try id("Lena Novak", in: people): upcoming("Borealis review", inHours: 2),
        ])
        let rows = Dictionary(uniqueKeysWithValues: content.sections.flatMap(\.rows).map { ($0.name, $0) })

        XCTAssertEqual(rows["Marko Jovanović"]?.detail, "Atlas sync")
        XCTAssertEqual(rows["Marko Jovanović"].map { plain($0.when) }, "Thu 2:00 PM")
        XCTAssertEqual(rows["Lena Novak"].map { plain($0.when) }, "2:00 PM", "A meeting today shows its time alone")
        XCTAssertEqual(rows["Petar Lazić"]?.detail, "Kickoff")
        XCTAssertEqual(rows["Petar Lazić"]?.when, "Today")
        XCTAssertEqual(rows["Ana Petrović"]?.when, "Yesterday")
        XCTAssertEqual(rows["Ana Petrović"]?.detail, "Design review")
        XCTAssertEqual(rows["Ivana Ilić"]?.when, "Oct 21")
    }

    func testSearchMatchesAnyNameAndAnUnmatchedSearchIsEmpty() throws {
        var people = library()
        let index = try XCTUnwrap(people.firstIndex { $0.name == "Ivana Ilić" })
        people[index].otherNames = ["Ivy"]

        XCTAssertEqual(build(people, query: " ivy ").sections.flatMap(\.rows).map(\.name), ["Ivana Ilić"])
        XCTAssertEqual(build(people, query: "PETROV").sections.flatMap(\.rows).map(\.name), ["Ana Petrović"])
        XCTAssertTrue(build(people, query: "nobody").isEmpty)
    }

    func testTheListIsRebuiltWhenTheSearchOrTheDayChanges() throws {
        let cache = PeopleListCache()
        let people = library()
        func content(_ query: String, at date: Date) -> PeopleListContent {
            cache.content(people: people, upcoming: [:], query: query, now: date, language: .english,
                          calendar: calendar)
        }

        XCTAssertEqual(content("", at: now).personIDs.count, 5)
        XCTAssertEqual(content("", at: now.addingTimeInterval(60)), content("", at: now))
        XCTAssertEqual(content("petrov", at: now).personIDs, [try id("Ana Petrović", in: people)])
        let nextDay = content("", at: now.addingTimeInterval(86_400)).sections.flatMap(\.rows)
        XCTAssertEqual(nextDay.first { $0.name == "Petar Lazić" }?.when, "Yesterday")
    }

    // MARK: - Badge

    func testTheBadgeSaysWhichWayOpenWorkRunsAndTheUsersOwnShowsFirst() throws {
        XCTAssertNil(PeopleListContent.Badge(youOwe: 0, owesYou: 0))
        XCTAssertEqual(PeopleListContent.Badge(youOwe: 2, owesYou: 0), .youOwe(2))
        XCTAssertEqual(PeopleListContent.Badge(youOwe: 0, owesYou: 3), .owesYou(3))
        XCTAssertEqual(PeopleListContent.Badge(youOwe: 1, owesYou: 4), .youOwe(1), "Both directions: the user's shows")
        XCTAssertEqual(PeopleListContent.Badge.youOwe(2).text(), "You owe 2")
        XCTAssertEqual(PeopleListContent.Badge.owesYou(1).text(), "Owes you 1")
        XCTAssertTrue(PeopleListContent.Badge.youOwe(1).needsAttention)
        XCTAssertFalse(PeopleListContent.Badge.owesYou(1).needsAttention)

        let rows = Dictionary(uniqueKeysWithValues: build(library()).sections.flatMap(\.rows).map { ($0.name, $0) })
        XCTAssertEqual(rows["Ana Petrović"]?.badge, .youOwe(1))
        XCTAssertEqual(rows["Marko Jovanović"]?.badge, .owesYou(1))
        XCTAssertNil(rows["Petar Lazić"]?.badge)
    }

    // MARK: - A person's page

    func testSubtitleCountsMeetingsSinceTheFirst() throws {
        let people = PeopleDirectory.build(.init(
            meetings: [
                meeting("Standup", hoursAgo: 2, attendees: [ana, marko]),
                meeting("Standup", hoursAgo: 13 * 24, attendees: [ana]),
                meeting("Design review", hoursAgo: 24, attendees: [ana]),
            ],
            projections: [], selfNames: ["Sam Reed"]), now: now)
        func subtitle(_ person: PersonProfile) -> String {
            PeopleWording.subtitle(for: person, now: now, calendar: calendar, locale: locale)
        }

        XCTAssertEqual(subtitle(try XCTUnwrap(people.first { $0.name == "Ana Petrović" })), "3 meetings since Oct 28")
        XCTAssertEqual(subtitle(try XCTUnwrap(people.first { $0.name == "Marko Jovanović" })), "Met once, Nov 10")
        let ownerOnly = PersonProfile(id: "person-test", name: "Nikola", otherNames: [], meetings: [],
                                      theirActions: [], myActions: [], decisions: [])
        XCTAssertEqual(subtitle(ownerOnly), "Named in actions")
    }

    func testNextMeetingLineSaysHowFarAwayThenTheDayAndTime() {
        func line(_ hours: Double) -> String {
            plain(PeopleWording.nextMeetingLine(upcoming("Atlas sync", inHours: hours), now: now,
                                                calendar: calendar, locale: locale))
        }
        XCTAssertEqual(line(50), "Next meeting in 2 days · Thu, Nov 12, 2:00 – 2:30 PM")
        XCTAssertEqual(line(20), "Next meeting tomorrow · Wed, Nov 11, 8:00 – 8:30 AM")
        XCTAssertEqual(line(2), "Next meeting today · Tue, Nov 10, 2:00 – 2:30 PM")
        XCTAssertEqual(line(-0.25), "In progress · Tue, Nov 10, 11:45 AM – 12:15 PM")
    }

    func testTimesKeepTheReadersClockUnderAnyInterfaceLanguage() {
        var reader = Locale.Components(identifier: "sr_ME")
        reader.hourCycle = .zeroToTwentyThree
        let mixed = PeopleWording.formattingLocale(Locale(identifier: "en"), reader: Locale(components: reader))

        XCTAssertEqual(plain(PeopleWording.upcomingTime(upcoming("Atlas sync", inHours: 50), now: now,
                                                        calendar: calendar, locale: mixed)), "Thu 14:00")
        let line = PeopleWording.nextMeetingLine(upcoming("Atlas sync", inHours: 50), now: now,
                                                 calendar: calendar, locale: mixed)
        XCTAssertTrue(line.hasPrefix("Next meeting in 2 days · Thu, Nov 12, 14:00"), line)
        XCTAssertFalse(line.contains("PM"), line)
    }

    func testInvitedNamesTheOthersOrSaysItIsJustTheTwoOfYou() {
        XCTAssertEqual(PeopleWording.invited([]), "Just the two of you")
        XCTAssertEqual(PeopleWording.invited(["Marko Jovanović"]), "Also invited: Marko Jovanović")
        XCTAssertEqual(PeopleWording.invited(["A", "B", "C", "D", "E"]), "Also invited: A, B, C +2")
    }

    func testSeriesDetailCountsASeriesAndDatesASingleMeeting() throws {
        let people = PeopleDirectory.build(.init(
            meetings: [
                meeting("Standup", hoursAgo: 26, attendees: [ana]),
                meeting("Standup", hoursAgo: 8 * 24, attendees: [ana]),
                meeting("Standup", hoursAgo: 15 * 24, attendees: [ana]),
                meeting("Offsite", hoursAgo: 400 * 24, attendees: [ana]),
            ],
            projections: [], selfNames: ["Sam Reed"]), now: now)
        let series = try XCTUnwrap(people.first).series
        let details = series.map { PeopleWording.seriesDetail($0, now: now, calendar: calendar, locale: locale) }

        XCTAssertEqual(series.map(\.title), ["Standup", "Offsite"])
        XCTAssertEqual(details, ["3 meetings · Nov 9", "Oct 6, 2025"])
        XCTAssertEqual(PeopleWording.meetingLink(title: "Standup", date: now, now: now, calendar: calendar,
                                                 locale: locale), "Standup · Nov 10")
    }

    func testShowMoreCountsAndRestoreWording() {
        XCTAssertEqual(PeopleWording.hiddenCount(total: 6, visible: PeopleWording.visibleDecisions), 3)
        XCTAssertEqual(PeopleWording.hiddenCount(total: 3, visible: PeopleWording.visibleDecisions), 0)
        XCTAssertEqual(PeopleWording.restoreHidden(1), "Restore 1 hidden entry")
        XCTAssertEqual(PeopleWording.restoreHidden(2), "Restore 2 hidden entries")
    }

    func testWordingIsLookedUpInTheInterfaceLanguage() throws {
        let people = library()
        let marked: (String) -> String = { "«" + $0 + "»" }
        let content = PeopleListContent.build(
            people: people, upcoming: [:], now: now, calendar: calendar, locale: locale, localize: marked)
        let rows = Dictionary(uniqueKeysWithValues: content.sections.flatMap(\.rows).map { ($0.name, $0) })
        XCTAssertEqual(rows["Petar Lazić"]?.when, "«Today»")
        XCTAssertEqual(PeopleListContent.Badge.youOwe(2).text(localize: marked), "«You owe 2»")
        XCTAssertEqual(PeopleWording.invited([], localize: marked), "«Just the two of you»")

        // Every key this wording uses is in the shipped catalogs.
        let keys = PeopleListContent.Group.allCases.map(\.title) + [
            "You owe %lld", "Owes you %lld", "You owe %@", "%@ owes you", "Named in actions", "Met once, %@",
            "%lld meetings since %@", "Next meeting %@", "In progress", "Also invited: %@", "Just the two of you",
            "%lld meetings", "Restore %lld hidden entry", "Restore %lld hidden entries", "Ask about %@",
            "Draft follow-up for %@…", "Merge into…", "Not a person", "Separate", "Open between you",
            "Last time", "Last mentioned", "Decided together", "Names", "Also appears as %@", "Prepare",
        ]
        for key in keys {
            XCTAssertNotEqual(AppLanguage.german.localized(key), key, "Missing from the catalogs: \(key)")
        }
    }

    // MARK: - Layout

    func testTheSideColumnSitsBesideThePageOnlyWhileBothFit() {
        XCTAssertTrue(PageSideColumnLayout.placesSideBeside(paneWidth: 692, textScale: 1),
                      "The default window keeps the column beside the page")
        XCTAssertFalse(PageSideColumnLayout.placesSideBeside(paneWidth: 600, textScale: 1))
        XCTAssertFalse(PageSideColumnLayout.placesSideBeside(paneWidth: 692, textScale: 1.3),
                       "Larger text needs more room for both")
        XCTAssertEqual(PageSideColumnLayout.sideWidth(textScale: 1), 252)
        XCTAssertGreaterThan(PageSideColumnLayout.sideWidth(textScale: 1.3), 252)
    }

    // MARK: - Prepare

    func testPrepareHandsAgentThePersonsNotesAndOpenWorkAndNothingFromTheCalendar() throws {
        let person = try XCTUnwrap(library().first { $0.name == "Ana Petrović" })
        let context = PersonPreparation.launchContext(for: person)

        XCTAssertEqual(context.title, "Prepare for Ana Petrović")
        XCTAssertEqual(context.meetingID, person.meetings.first?.id)
        XCTAssertEqual(context.prompt, """
        Help me prepare for my next conversation with Ana Petrović.
        What I owe them:
        - Draft the synthetic eviction policy
        What they owe me:
        - Benchmark the synthetic failover
        """)
    }
}
