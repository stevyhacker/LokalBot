import XCTest
@testable import LokalBot

/// Timeline's body: how wide the rail is beside the day's page, and what the
/// rail's Tracked block says.
final class TimelineDayLayoutTests: XCTestCase {
    private let standard = AppTextSize.standard.scale

    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Podgorica")!
        return calendar
    }()

    private var day: Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: 9))!
    }

    private func at(_ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)!
    }

    // MARK: - The rail's width

    func testTheRailIsItsIdealWidthInARoomyWindowAndItsMinimumInTheDefaultOne() {
        // A 1440-point window beside the 216-point sidebar.
        XCTAssertEqual(TimelineRailMetric.width(available: 1_224, textScale: standard), 352)
        // The default 1180-point window: the page keeps 663 points.
        XCTAssertEqual(TimelineRailMetric.width(available: 964, textScale: standard), 300)
        // Between the two the rail takes its share of the width.
        let between = TimelineRailMetric.width(available: 1_100, textScale: standard)
        XCTAssertEqual(between, 330)
        // A very wide window does not widen the rail.
        XCTAssertEqual(TimelineRailMetric.width(available: 2_400, textScale: standard), 352)
    }

    func testTheRailGivesWayBeforeThePageGetsTighterThanItsMinimum() {
        // The smallest captured window, 1000 points: the rail keeps 300 and
        // the page has more than its minimum.
        let captured: CGFloat = 1_000 - LBTokens.Metric.sidebarWidth
        XCTAssertEqual(TimelineRailMetric.width(available: captured, textScale: standard), 300)
        XCTAssertGreaterThan(captured - 301, TimelineRailMetric.pageMinimumWidth)

        // Narrower still, the page stays at its minimum and the rail shrinks
        // to its floor.
        XCTAssertEqual(TimelineRailMetric.width(available: 700, textScale: standard), 279)
        let narrowest = TimelineRailMetric.bodyMinimumWidth
        XCTAssertEqual(narrowest, 681)
        XCTAssertEqual(TimelineRailMetric.width(available: narrowest, textScale: standard),
                       TimelineRailMetric.floorWidth)
        XCTAssertEqual(narrowest - 1 - TimelineRailMetric.floorWidth, TimelineRailMetric.pageMinimumWidth)
        // The rail never goes under its floor, whatever it is offered.
        XCTAssertEqual(TimelineRailMetric.width(available: 400, textScale: standard), TimelineRailMetric.floorWidth)
    }

    func testTheRailGrowsWithLargerTextWhereTheWindowHasRoom() {
        let largest = AppTextSize.largest.scale
        let factor = largest / standard
        let wide = TimelineRailMetric.width(available: 1_800, textScale: largest)
        XCTAssertEqual(wide, (352 * factor).rounded())
        XCTAssertGreaterThan(wide, 352)
        // The default window offers less than larger text asks for: the
        // rail takes its scaled minimum, and the page still has its own.
        let inDefault = TimelineRailMetric.width(available: 964, textScale: largest)
        XCTAssertEqual(inDefault, (300 * factor).rounded())
        XCTAssertGreaterThanOrEqual(964 - 1 - inDefault, TimelineRailMetric.pageMinimumWidth)
        // In the smallest captured window the page's minimum wins.
        let captured: CGFloat = 784
        let squeezed = TimelineRailMetric.width(available: captured, textScale: largest)
        XCTAssertEqual(captured - 1 - squeezed, TimelineRailMetric.pageMinimumWidth)
        // Smaller text does not shrink the rail under its sizes at the default.
        XCTAssertLessThanOrEqual(TimelineRailMetric.width(available: 1_224, textScale: AppTextSize.small.scale), 352)
    }

    // MARK: - Tracked

    private func row(_ id: Int64, from start: Date, to end: Date) -> TimelineDayList.Row {
        TimelineDayList.Row(
            id: TimelineDayList.Row.id(session: id), kind: .work(id), start: start, end: end,
            title: "Session \(id)", detail: "", duration: end.timeIntervalSince(start), colorKey: "Xcode",
            isQuiet: false)
    }

    func testTheLineUnderTheTotalCountsMeetingsThenWhatTheAgentsRecorded() {
        var outcomes = TimelineAgentOutcomes([])
        XCTAssertNil(TimelineTrackedSummary.detail(meetingCount: 0, outcomes: outcomes))
        XCTAssertEqual(TimelineTrackedSummary.detail(meetingCount: 1, outcomes: outcomes), "1 meeting")
        outcomes.openedPullRequests = ["a", "b", "c", "d"]
        outcomes.mergedPullRequests = 1
        XCTAssertEqual(TimelineTrackedSummary.detail(meetingCount: 4, outcomes: outcomes),
                       "4 meetings · 4 PRs opened · 1 merged")
        XCTAssertEqual(TimelineTrackedSummary.detail(meetingCount: 0, outcomes: outcomes),
                       "4 PRs opened · 1 merged")
        // Each count is looked up in the interface language.
        XCTAssertEqual(
            TimelineTrackedSummary.detail(meetingCount: 2, outcomes: TimelineAgentOutcomes([])) { key in
                key == "%lld meetings" ? "Sastanaka: %lld" : key
            },
            "Sastanaka: 2")
    }

    func testTheTrackedBlockTotalsTheDayAndListsMeetingsLast() throws {
        let sessions = TimelineWorkSession.sessions(from: [
            ActivityBlock(id: 1, app: "Xcode", title: "TimelineView.swift", start: at(9), end: at(10, 30)),
            ActivityBlock(id: 2, app: "Safari", title: "Pull request #42", start: at(10, 30), end: at(11, 15)),
        ])
        let meeting = Meeting(id: UUID(), title: "Design review", appName: "Zoom", startedAt: at(11),
                              endedAt: at(11, 25), relativePath: "meetings/design-review")
        let list = TimelineDayList(sessions: sessions, meetings: [meeting], now: at(23), calendar: calendar)
        let summary = try XCTUnwrap(TimelineTrackedSummary(
            perApp: [("Xcode", 5_400), ("Safari", 2_700)], split: .init(), list: list,
            meetingCount: 1, outcomes: TimelineAgentOutcomes([]), day: day, calendar: calendar))

        XCTAssertEqual(summary.tracked, 8_100)
        XCTAssertEqual(summary.detail, "1 meeting")
        XCTAssertEqual(summary.legend.map(\.label), ["Xcode", "Safari"])
        // The meetings' own total, which the legend shows as its last row.
        XCTAssertEqual(summary.meetingSeconds, 25 * 60)
        XCTAssertEqual(summary.strip?.meetings.count, 1)
        XCTAssertEqual(summary.strip?.work.count, list.rows.filter { !$0.isMeeting }.count)
    }

    func testADayWithNothingTrackedAndNoMeetingsHasNoTrackedBlock() {
        let empty = TimelineDayList(sessions: [], meetings: [], now: at(23), calendar: calendar)
        XCTAssertNil(TimelineTrackedSummary(
            perApp: [], split: .init(), list: empty, meetingCount: 0,
            outcomes: TimelineAgentOutcomes([]), day: day, calendar: calendar))
    }

    // MARK: - The page

    func testPanelsFillTheMainAreaUpToTheirWidestLine() {
        XCTAssertEqual(TimelinePageMetric.gutter, 24)
        XCTAssertEqual(TimelinePageMetric.maximumWidth, 1_100)
        // At the default window the panels have the whole main area inside
        // their gutters.
        let main = 964 - 1 - TimelineRailMetric.width(available: 964, textScale: standard)
        XCTAssertLessThan(main - 2 * TimelinePageMetric.gutter, TimelinePageMetric.maximumWidth)
    }
}
