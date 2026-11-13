import XCTest
@testable import LokalBot

/// The day strip's geometry and click areas, its legend, the day's actions
/// panel, and the menu's digest item.
final class TimelineDayStripTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Podgorica")!
        return calendar
    }()

    private var day: Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: 9))!
    }

    private func at(_ hour: Int, _ minute: Int = 0, dayOffset: Int = 0) -> Date {
        let base = calendar.date(byAdding: .day, value: dayOffset, to: day)!
        return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: base)!
    }

    private func work(_ id: Int64, from start: Date, to end: Date, color: String? = "Atlas") -> TimelineDayList.Row {
        TimelineDayList.Row(
            id: TimelineDayList.Row.id(session: id), kind: .work(id), start: start, end: end,
            title: "Session \(id)", detail: "", duration: end.timeIntervalSince(start), colorKey: color,
            isQuiet: false)
    }

    private func meeting(from start: Date, to end: Date) -> TimelineDayList.Row {
        let id = UUID()
        return TimelineDayList.Row(
            id: TimelineDayList.Row.id(meeting: id), kind: .meeting(id, isLive: false), start: start, end: end,
            title: "Meeting", detail: "Meeting · Zoom", duration: end.timeIntervalSince(start), colorKey: nil,
            isQuiet: false)
    }

    // MARK: - Bars and hours

    func testTheStripSpansWholeHoursAroundTheDaysRows() throws {
        let strip = try XCTUnwrap(TimelineDayStrip(
            rows: [work(1, from: at(9), to: at(10, 30)),
                   meeting(from: at(10), to: at(10, 15)),
                   work(2, from: at(11, 15), to: at(11, 25), color: nil)],
            day: day, calendar: calendar))

        XCTAssertEqual(strip.span, DateInterval(start: at(9), end: at(12)))
        XCTAssertEqual(strip.ticks.map(\.date), [at(9), at(10), at(11)])
        XCTAssertEqual(strip.ticks.map(\.position), [0, 1.0 / 3, 2.0 / 3])
        // Meetings sit in their own lane above work.
        XCTAssertEqual(strip.meetings.count, 1)
        XCTAssertEqual(strip.work.map(\.id), [TimelineDayList.Row.id(session: 1), TimelineDayList.Row.id(session: 2)])
        XCTAssertEqual(strip.work[0].start, 0)
        XCTAssertEqual(strip.work[0].end, 0.5)
        XCTAssertEqual(strip.meetings[0].start, 1.0 / 3, accuracy: 0.0001)
        XCTAssertEqual(strip.meetings[0].end, 1.25 / 3, accuracy: 0.0001)
        XCTAssertEqual(strip.work[0].colorKey, "Atlas")
        XCTAssertNil(strip.work[1].colorKey)
    }

    func testAnEndOnTheHourAddsNoEmptyHour() throws {
        let strip = try XCTUnwrap(TimelineDayStrip(
            rows: [work(1, from: at(8, 52), to: at(18))], day: day, calendar: calendar))

        XCTAssertEqual(strip.span, DateInterval(start: at(8), end: at(18)))
        XCTAssertEqual(strip.ticks.count, 10)
        // The first hour and noon say AM or PM.
        XCTAssertEqual(strip.ticks.filter(\.namesDayPeriod).map(\.date), [at(8), at(12)])
    }

    func testBarsAreClippedToTheDay() throws {
        let strip = try XCTUnwrap(TimelineDayStrip(
            rows: [work(1, from: at(23, 10, dayOffset: -1), to: at(0, 40)),
                   work(2, from: at(22, 30), to: at(1, 15, dayOffset: 1)),
                   // Wholly on another day: no bar.
                   work(3, from: at(9, dayOffset: 1), to: at(10, dayOffset: 1))],
            day: day, calendar: calendar))

        XCTAssertEqual(strip.span, DateInterval(start: at(0), end: at(0, dayOffset: 1)))
        XCTAssertEqual(strip.work.count, 2)
        XCTAssertEqual(strip.work[0].start, 0)
        XCTAssertEqual(strip.work[0].end, 40.0 / (24 * 60), accuracy: 0.0001)
        XCTAssertEqual(strip.work[1].end, 1)
        XCTAssertTrue(strip.work.allSatisfy { $0.start >= 0 && $0.end <= 1 && $0.start < $0.end })
    }

    func testADayWithoutRowsHasNoStrip() {
        XCTAssertNil(TimelineDayStrip(rows: [], day: day, calendar: calendar))
        XCTAssertNil(TimelineDayStrip(
            rows: [work(1, from: at(9, dayOffset: 2), to: at(10, dayOffset: 2))], day: day, calendar: calendar))
    }

    func testAShortSessionStillGetsAFullHour() throws {
        let strip = try XCTUnwrap(TimelineDayStrip(
            rows: [work(1, from: at(14, 5), to: at(14, 9))], day: day, calendar: calendar))

        XCTAssertEqual(strip.span, DateInterval(start: at(14), end: at(15)))
    }

    func testABarKeepsAMinimumWidthAndStaysInItsLane() throws {
        let strip = try XCTUnwrap(TimelineDayStrip(
            rows: [work(1, from: at(8), to: at(12)), work(2, from: at(17, 59), to: at(18))],
            day: day, calendar: calendar))

        let long = TimelineDayStrip.frame(of: strip.work[0], in: 600)
        XCTAssertEqual(long.x, 0)
        XCTAssertEqual(long.width, 240)
        // One minute of ten hours is a point wide; it shows as three, moved
        // left so it does not leave the lane.
        let short = TimelineDayStrip.frame(of: strip.work[1], in: 600)
        XCTAssertEqual(short.width, 3)
        XCTAssertEqual(short.x, 597)
        XCTAssertEqual(TimelineDayStrip.frame(of: strip.work[0], in: 0).width, 0)
    }

    /// In the rail a ten-minute session is a few points wide. It is drawn at
    /// its own width and answers a click a little to either side.
    func testAThinBarIsClickedOverAWiderAreaThanItIsDrawn() throws {
        let strip = try XCTUnwrap(TimelineDayStrip(
            rows: [work(1, from: at(8), to: at(12)), work(2, from: at(13), to: at(13, 10)),
                   work(3, from: at(17, 59), to: at(18)), work(4, from: at(8), to: at(8, 1))],
            day: day, calendar: calendar))

        // A bar wider than the minimum is clicked where it is drawn.
        let long = TimelineDayStrip.hitFrame(of: strip.work[0], in: 320)
        XCTAssertEqual(long.x, TimelineDayStrip.frame(of: strip.work[0], in: 320).x)
        XCTAssertEqual(long.width, TimelineDayStrip.frame(of: strip.work[0], in: 320).width)

        // Ten minutes of ten hours in a 320-point strip: 5.3 points drawn,
        // 12 to click, centred on the bar.
        let drawn = TimelineDayStrip.frame(of: strip.work[1], in: 320)
        let hit = TimelineDayStrip.hitFrame(of: strip.work[1], in: 320)
        XCTAssertEqual(drawn.width, 320.0 / 60, accuracy: 0.01)
        XCTAssertEqual(hit.width, 12)
        XCTAssertEqual(hit.x + hit.width / 2, drawn.x + drawn.width / 2, accuracy: 0.01)

        // At either end the click area stays inside the lane and still covers the bar.
        for bar in [strip.work[2], strip.work[3]] {
            let drawn = TimelineDayStrip.frame(of: bar, in: 320)
            let hit = TimelineDayStrip.hitFrame(of: bar, in: 320)
            XCTAssertGreaterThanOrEqual(hit.x, 0)
            XCTAssertLessThanOrEqual(hit.x + hit.width, 320)
            XCTAssertLessThanOrEqual(hit.x, drawn.x)
            XCTAssertGreaterThanOrEqual(hit.x + hit.width, drawn.x + drawn.width)
        }
        XCTAssertEqual(TimelineDayStrip.hitFrame(of: strip.work[0], in: 0).width, 0)
    }

    func testShortBarsAreDrawnLastSoTheirClickAreaWins() throws {
        let strip = try XCTUnwrap(TimelineDayStrip(
            rows: [work(1, from: at(9), to: at(9, 10)), work(2, from: at(9, 10), to: at(12)),
                   work(3, from: at(12), to: at(12, 10))],
            day: day, calendar: calendar))

        XCTAssertEqual(TimelineDayStrip.hitOrder(strip.work).map(\.id),
                       [2, 1, 3].map { TimelineDayList.Row.id(session: $0) })
    }

    func testHourLabelsThinOutWhenTheyWouldCollide() throws {
        let strip = try XCTUnwrap(TimelineDayStrip(
            rows: [work(1, from: at(8), to: at(19))], day: day, calendar: calendar))

        XCTAssertEqual(strip.ticks.count, 11)
        XCTAssertEqual(strip.labelledTicks(fitting: 16).count, 11)
        XCTAssertEqual(strip.labelledTicks(fitting: 6).map(\.date), [at(8), at(10), at(12), at(14), at(16), at(18)])
        XCTAssertEqual(strip.labelledTicks(fitting: 4).map(\.date), [at(8), at(11), at(14), at(17)])
        XCTAssertTrue(strip.labelledTicks(fitting: 0).isEmpty)
    }

    // MARK: - Legend

    func testTheLegendListsProjectsWhenTheDayHasThemAndAppsOtherwise() {
        let perApp: [(label: String, seconds: TimeInterval)] = [("Xcode", 5_400), ("Safari", 2_700), ("Slack", 600)]
        let apps = TimelineDayLegend.entries(perApp: perApp, split: .init())

        XCTAssertEqual(apps.map(\.label), ["Xcode", "Safari", "Slack"])
        XCTAssertEqual(apps.map(\.colorKey), ["Xcode", "Safari", "Slack"])

        var split = TimelineProjectAttribution.DaySplit()
        split.projects = [.init(project: "Atlas", seconds: 14_340), .init(project: "Borealis", seconds: 4_500),
                          .init(project: "Tiny", seconds: 30)]
        split.unattributedSeconds = 9_600
        let projects = TimelineDayLegend.entries(perApp: perApp, split: split)

        XCTAssertEqual(projects.map(\.label), ["Atlas", "Borealis", "Other activity"])
        XCTAssertEqual(projects.map(\.kind), [.project, .project, .otherActivity])
        // Other activity is neutral, like the sessions it stands for.
        XCTAssertEqual(projects.map(\.colorKey), ["Atlas", "Borealis", nil])
    }

    // MARK: - The day's actions

    private func thread(_ text: String, on date: Date, status: OutcomeStatus = .open) -> ActionThread {
        let action = MeetingOutcomes.ActionItem(text: text, owner: "Me")
        let reference = OutcomeActionReference(
            meetingID: UUID(), meetingTitle: "Design review", meetingStartedAt: date, action: action,
            status: status, text: action.text, owner: "Me", due: nil, stateUpdatedAt: date,
            textWasCorrected: false, ownerWasCorrected: false, dueWasCorrected: false)
        return ActionThreadClusterer.cluster([reference])[0]
    }

    func testTheDaysActionsAreThoseItsMeetingsMentionedDoneOnesIncluded() {
        let done = thread("Share the benchmark plan", on: at(11), status: .done)
        let open = thread("Draft the eviction policy", on: at(11, 20))
        let deferred = thread("Book a room for the kickoff", on: at(16), status: .deferred)
        let otherDay = thread("Send the invoice", on: at(11, dayOffset: -1))
        let threads = TimelineDayActions.threads([done, otherDay, open, deferred], on: day, calendar: calendar)

        // Open work first; the rest keeps the index's order.
        XCTAssertEqual(threads.map(\.text),
                       ["Draft the eviction policy", "Share the benchmark plan", "Book a room for the kickoff"])
        XCTAssertEqual(TimelineDayActions.summary(of: threads), .open(1))
        XCTAssertEqual(TimelineDayActions.summary(of: [done]), .allDone(1))
        XCTAssertEqual(TimelineDayActions.summary(of: [done, deferred]), .noneOpen(2))
    }

    func testTheActionsPanelCountsOpenWorkOrSaysAllDone() {
        XCTAssertNil(TimelineDayActions.summary(of: []))
        XCTAssertEqual(TimelineDayActions.pill(for: .open(2)), .open(2))
        XCTAssertEqual(TimelineDayActions.pill(for: .allDone(3)), .allDone)
        // Deferred work is not done: the day has nothing open, and says so.
        XCTAssertEqual(TimelineDayActions.pill(for: .noneOpen(2)), .open(0))
    }

    func testTheActionsPanelListsItsRowsWhileOneIsOpenAndKeepsThemOnceShown() {
        XCTAssertTrue(TimelineDayActions.showsRows(.open(1), hadOpen: false))
        // A day whose actions were all done before it was opened is a header alone.
        XCTAssertFalse(TimelineDayActions.showsRows(.allDone(3), hadOpen: false))
        XCTAssertFalse(TimelineDayActions.showsRows(.noneOpen(2), hadOpen: false))
        // Ticking the last open action leaves the rows where they were.
        XCTAssertTrue(TimelineDayActions.showsRows(.allDone(2), hadOpen: true))
    }

    // MARK: - The menu's digest item

    func testTheMenusDigestItemNamesWhatItWillDo() {
        XCTAssertEqual(TimelineDigestPreview.menuTitle(isWriting: false, hasDigest: false, isStale: false),
                       "Write digest")
        XCTAssertEqual(TimelineDigestPreview.menuTitle(isWriting: false, hasDigest: true, isStale: true),
                       "Update digest")
        XCTAssertEqual(TimelineDigestPreview.menuTitle(isWriting: false, hasDigest: true, isStale: false),
                       "Rewrite digest")
        // While a digest is written the item says so, whatever was there before.
        XCTAssertEqual(TimelineDigestPreview.menuTitle(isWriting: true, hasDigest: true, isStale: true),
                       "Writing digest…")
    }
}
