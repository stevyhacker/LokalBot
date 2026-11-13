import XCTest
@testable import LokalBot

/// Today's one list of meetings, the next-meeting rule, the recap line and
/// the small states the page is built from.
final class TodayAgendaTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    /// 10:48 on a day far from midnight in UTC.
    private var now: Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: 10, hour: 10, minute: 48))!
    }

    private func at(_ hour: Int, _ minute: Int = 0, dayOffset: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: 10 + dayOffset, hour: hour, minute: minute))!
    }

    private func recording(_ title: String, start: Date, minutes: Double? = 15,
                           eventID: String? = nil) -> Meeting {
        var meeting = Meeting(
            id: UUID(), title: title, appName: "Zoom", startedAt: start,
            endedAt: minutes.map { start.addingTimeInterval($0 * 60) },
            relativePath: "meetings/\(title)")
        meeting.calendarEventID = eventID
        return meeting
    }

    private func event(_ id: String, start: Date, minutes: Double = 30) -> CalendarMeetingCandidate {
        CalendarMeetingCandidate(
            provider: "test", externalID: id, title: id, startDate: start,
            endDate: start.addingTimeInterval(minutes * 60),
            meetingURL: URL(string: "https://meet.google.com/abc-defg-hij"),
            sourceCalendarTitle: "Work", participantNames: ["Ana"])
    }

    // MARK: The list

    func testRecordingsAndEventsMergeInTimeOrder() {
        let standup = recording("Standup", start: at(9))
        let review = event("review", start: at(11))
        let planning = event("planning", start: at(14))
        let early = event("early", start: at(8), minutes: 30)

        let entries = TodayAgenda.entries(
            recordings: [standup], events: [planning, review, early],
            liveMeetingID: nil, now: now, calendar: calendar)

        XCTAssertEqual(entries.map(\.title), ["early", "Standup", "review", "planning"])
        XCTAssertEqual(entries.map(\.status), [.ended, .recorded, .upcoming(minutes: 12), .upcoming(minutes: 192)])
        XCTAssertEqual(entries.map(\.isSoon), [false, false, true, false],
                       "Only the meeting within the hour reads as soon")
    }

    func testRecordingMatchedToItsEventAppearsOnce() {
        let review = event("review", start: at(10, 30), minutes: 60)
        let recorded = recording("Design review", start: at(10, 31), eventID: "review")

        let entries = TodayAgenda.entries(
            recordings: [recorded], events: [review, event("later", start: at(15))],
            liveMeetingID: nil, now: now, calendar: calendar)

        XCTAssertEqual(entries.map(\.title), ["Design review", "later"])
        XCTAssertEqual(entries.first?.meeting?.id, recorded.id)
    }

    func testLiveRecordingLeadsOnceAndOtherDaysAndSamplesStayOut() {
        let live = recording("Atlas sync", start: at(10, 15), minutes: nil)
        let yesterday = recording("Yesterday", start: at(15, dayOffset: -1))
        var sample = recording("Sample", start: at(9))
        sample.sampleID = "orders-api/en"
        var mergedSource = recording("Source", start: at(9, 30), eventID: "merged-event")
        mergedSource.mergedIntoMeetingID = UUID()

        let entries = TodayAgenda.entries(
            // The live meeting can be both the current recording and in the library.
            recordings: [live, live, yesterday, sample, mergedSource],
            events: [event("merged-event", start: at(9, 30))],
            liveMeetingID: live.id, now: now, calendar: calendar)

        XCTAssertEqual(entries.map(\.title), ["Atlas sync"])
        XCTAssertEqual(entries.first?.status, .recording)
    }

    func testSameMinutePutsTheRecordingBeforeTheEvent() {
        let entries = TodayAgenda.entries(
            recordings: [recording("Recorded", start: at(9))], events: [event("event", start: at(9))],
            liveMeetingID: nil, now: now, calendar: calendar)
        XCTAssertEqual(entries.map(\.title), ["Recorded", "event"])
    }

    // MARK: The now line

    func testNowLineSitsBeforeTheFirstEntryStillAhead() {
        let entries = TodayAgenda.entries(
            recordings: [recording("Standup", start: at(9))],
            events: [event("review", start: at(11)), event("planning", start: at(14))],
            liveMeetingID: nil, now: now, calendar: calendar)

        let rows = TodayAgenda.rows(entries, now: now)

        XCTAssertEqual(rows.map(\.id), [entries[0].id, "now", entries[1].id, entries[2].id])
        XCTAssertEqual(rows[1], .now(now))
    }

    func testDayWithNothingAheadHasNoNowLineAndAMorningStartsWithIt() {
        let past = TodayAgenda.entries(
            recordings: [recording("Standup", start: at(9))], events: [event("early", start: at(8))],
            liveMeetingID: nil, now: now, calendar: calendar)
        XCTAssertFalse(TodayAgenda.rows(past, now: now).contains(.now(now)))
        XCTAssertTrue(TodayAgenda.rows([], now: now).isEmpty)

        let ahead = TodayAgenda.entries(
            recordings: [], events: [event("review", start: at(11))],
            liveMeetingID: nil, now: now, calendar: calendar)
        XCTAssertEqual(TodayAgenda.rows(ahead, now: now).first, .now(now))
    }

    // MARK: The next-meeting card

    func testNextMeetingAppearsWithinTheHourOnly() {
        XCTAssertEqual(TodayAgenda.nextMeetingWindow, 3_600)
        let inAnHour = event("edge", start: now.addingTimeInterval(TodayAgenda.nextMeetingWindow))
        let justOver = event("over", start: now.addingTimeInterval(TodayAgenda.nextMeetingWindow + 60))

        XCTAssertEqual(TodayAgenda.nextMeeting(in: [justOver, inAnHour], now: now)?.externalID, "edge")
        XCTAssertNil(TodayAgenda.nextMeeting(in: [justOver], now: now))
        XCTAssertNil(TodayAgenda.nextMeeting(in: [], now: now))
    }

    func testNextMeetingKeepsOneUnderWayAndSkipsEndedAndRecordedOnes() {
        let underWay = event("underway", start: now.addingTimeInterval(-600), minutes: 30)
        let soon = event("soon", start: now.addingTimeInterval(600))
        let ended = event("ended", start: now.addingTimeInterval(-7_200), minutes: 30)

        XCTAssertEqual(TodayAgenda.nextMeeting(in: [ended, underWay, soon], now: now)?.externalID, "underway")
        // The one being recorded, or already recorded, is not coming up again.
        XCTAssertEqual(
            TodayAgenda.nextMeeting(in: [ended, underWay, soon], now: now,
                                    recordedEventIDs: ["underway"])?.externalID, "soon")
        XCTAssertNil(TodayAgenda.nextMeeting(in: [ended], now: now))
        XCTAssertEqual(
            TodayAgenda.recordedEventIDs(in: [recording("A", start: at(9), eventID: "underway"),
                                              recording("B", start: at(9))]), ["underway"])
    }

    func testEventStatusFollowsTheClock() {
        let start = now.addingTimeInterval(90 * 60)
        XCTAssertEqual(TodayAgenda.status(of: event("e", start: start), now: now), .upcoming(minutes: 90))
        XCTAssertEqual(TodayAgenda.status(of: event("e", start: now.addingTimeInterval(30)), now: now), .startingNow)
        XCTAssertEqual(TodayAgenda.status(of: event("e", start: now.addingTimeInterval(-60)), now: now), .inProgress)
        XCTAssertEqual(TodayAgenda.status(of: event("e", start: now.addingTimeInterval(-7_200)), now: now), .ended)
    }

    // MARK: Recap line

    func testRecapIsTheFirstLineOfTheSummaryOverview() {
        let prose = """
            ## TL;DR
            The team picked Redis for the caching layer and deferred cluster mode.

            ## Decisions
            - Adopt Redis for caching.
            """
        XCTAssertEqual(TodayMeetingRecap.line(fromSummary: prose),
                       "The team picked Redis for the caching layer and deferred cluster mode.")

        let bullets = """
            # Notes

            ## TL;DR

            - **You:** Redis was selected for the **caching** layer. — [00:01:54]
            - Second point.
            """
        XCTAssertEqual(TodayMeetingRecap.line(fromSummary: bullets), "Redis was selected for the caching layer.")
    }

    func testRecapIsLeftOutWithoutAnOverviewOrWithOnlyActions() {
        XCTAssertNil(TodayMeetingRecap.line(fromSummary: "## Decisions\n- Adopt Redis for caching.\n"))
        XCTAssertNil(TodayMeetingRecap.line(fromSummary: "## TL;DR\n\n- [ ] Draft the document\n\n_None._\n"))
        XCTAssertNil(TodayMeetingRecap.line(fromSummary: ""))

        let long = "## Summary\n" + String(repeating: "word ", count: 120)
        let line = TodayMeetingRecap.line(fromSummary: long)
        XCTAssertEqual(line?.hasSuffix("…"), true)
        XCTAssertLessThanOrEqual(line?.count ?? .max, TodayMeetingRecap.maximumCharacters + 1)
    }

    func testRecapsReadEachMeetingsSavedSummary() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TodayAgendaTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let summarized = recording("summarized", start: at(9))
        let bare = recording("bare", start: at(10))
        for meeting in [summarized, bare] {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(meeting.relativePath), withIntermediateDirectories: true)
        }
        try "## TL;DR\nIndex rebuild is blocked on the data team.\n".write(
            to: root.appendingPathComponent(summarized.relativePath).appendingPathComponent("summary.md"),
            atomically: true, encoding: .utf8)

        XCTAssertEqual(TodayMeetingRecap.lines(for: [summarized, bare], root: root),
                       [summarized.id: "Index rebuild is blocked on the data team."])
    }

    // MARK: Digest

    func testHighlightsAreTheDigestsAtAGlanceLines() {
        let digest = """
            ## Day summary

            ### At a glance
            - Shipped the Timeline fix.
            - Reviewed the migration plan.

            ### Focus blocks
            - **09:00–10:30 · Fixture implementation** — User updated the Timeline UI. [screen:4242]
            """
        let highlights = TodayDigestHighlights.markdown(for: digest)
        XCTAssertTrue(highlights.contains("Shipped the Timeline fix."))
        XCTAssertTrue(highlights.contains("Reviewed the migration plan."))
        XCTAssertFalse(highlights.contains("Fixture implementation"), "Tasks stay on Timeline")
        XCTAssertEqual(TodayDigestHighlights.markdown(for: nil), "")
    }

    func testHighlightsFallBackToTaskTitlesWithoutAnOverview() {
        let digest = """
            ## Day summary

            ### Focus blocks
            - **09:00–10:30 · Fixture implementation** — User updated the Timeline UI.
            - **10:30–11:00 · Review** — Read the pull request.
            """
        XCTAssertEqual(TodayDigestHighlights.markdown(for: digest), "- Fixture implementation\n- Review")
    }

    func testDigestLineStates() {
        let written = at(9, 58)
        XCTAssertEqual(TodayDigestLine.state(hasDigest: false, writtenAt: nil, isStale: false, isWriting: false),
                       .missing)
        XCTAssertEqual(TodayDigestLine.state(hasDigest: true, writtenAt: written, isStale: false, isWriting: false),
                       .current(writtenAt: written))
        XCTAssertEqual(TodayDigestLine.state(hasDigest: true, writtenAt: written, isStale: true, isWriting: false),
                       .stale(writtenAt: written))
        XCTAssertEqual(TodayDigestLine.state(hasDigest: true, writtenAt: written, isStale: true, isWriting: true),
                       .writing, "A run in progress hides Update, so a second one cannot start")
    }

    // MARK: Page

    func testGettingStartedIsThePageOnlyWhileThereIsNothingElse() {
        XCTAssertEqual(TodayPageLayout.layout(hasContent: false, gettingStartedDismissed: false), .gettingStarted)
        XCTAssertEqual(TodayPageLayout.layout(hasContent: false, gettingStartedDismissed: true), .placeholder)
        XCTAssertEqual(TodayPageLayout.layout(hasContent: true, gettingStartedDismissed: false),
                       .sections(gettingStartedBelow: true))
        XCTAssertEqual(TodayPageLayout.layout(hasContent: true, gettingStartedDismissed: true),
                       .sections(gettingStartedBelow: false))
    }

    // MARK: Before you join

    func testPreparationRowsTakeOneOfEachKindAndCountTheRest() {
        let prior = recording("Design review", start: at(11, dayOffset: -7))
        let decisions = (0..<2).map {
            UpcomingMeetingReference(kind: .decision, text: "Decision \($0)", meeting: prior, index: $0)
        }
        let commitment = UpcomingMeetingReference(
            kind: .commitment, text: "Benchmark failover", meeting: prior, index: 0, owner: "Daniel Ortiz")
        let thread = UpcomingMeetingEmailThread(
            id: "account:thread", accountAddress: "me@example.com", threadID: "18f3a9",
            subject: "Failover benchmark numbers", lastMessageAt: now.addingTimeInterval(-86_400),
            lastSender: "Daniel Ortiz", lastFromMe: false, awaitingReply: true,
            excerpt: "Numbers attached.", promptText: "")
        var evidence = UpcomingMeetingEvidence(
            event: event("review", start: at(11)),
            relatedMeetings: [.init(meeting: prior, summary: "", participantMatches: 1, relevanceScore: 1)],
            decisions: decisions, commitments: [commitment], projects: [])
        evidence.emailThreads = [thread]

        let rows = TodayPreparation.primaryRows(evidence)
        XCTAssertEqual(rows.map(\.kind), [.decision, .commitment, .email])
        XCTAssertEqual(rows.map(\.text), ["Decision 0", "Benchmark failover", "Failover benchmark numbers"])
        XCTAssertEqual(rows.map(\.source), ["Design review", "Daniel Ortiz", "Daniel Ortiz"])
        XCTAssertEqual(rows[0].target, .meeting(prior.id))
        XCTAssertEqual(rows[2].target, .link(thread.gmailURL))
        XCTAssertTrue(rows[2].awaitingReply)
        XCTAssertEqual(TodayPreparation.moreRows(evidence).map(\.text), ["Decision 1"])
        XCTAssertEqual(TodayPreparation.count(evidence), 4)
    }

    func testPreparationFallsBackToTheClosestMeetingAndShowsTheTemplateBriefOnlyWithoutRows() {
        let prior = recording("Atlas review", start: at(11, dayOffset: -7))
        let evidence = UpcomingMeetingEvidence(
            event: event("review", start: at(11)),
            relatedMeetings: [.init(meeting: prior, summary: "", participantMatches: 1, relevanceScore: 1)],
            decisions: [], commitments: [], projects: [])

        let rows = TodayPreparation.primaryRows(evidence)
        XCTAssertEqual(rows.map(\.kind), [.recentMeeting])
        XCTAssertEqual(rows.first?.target, .meeting(prior.id))

        XCTAssertTrue(TodayPreparation.showsBrief(generatedByModel: true, rowCount: 3))
        XCTAssertFalse(TodayPreparation.showsBrief(generatedByModel: false, rowCount: 3),
                       "The template brief only restates the rows")
        XCTAssertTrue(TodayPreparation.showsBrief(generatedByModel: false, rowCount: 0))
    }
}
