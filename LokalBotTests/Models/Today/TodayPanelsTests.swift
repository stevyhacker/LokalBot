import XCTest
@testable import LokalBot

final class TodayPanelsTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private var standardScale: CGFloat { AppTextSize.standard.scale }

    func testTwoColumnsNeedAReadableLeadingColumnBesideTheTrailingOne() {
        XCTAssertEqual(TodayColumns.trailingWidth(textScale: standardScale), 352)
        XCTAssertEqual(TodayColumns.twoColumnMinimumWidth(textScale: standardScale), 480 + 16 + 352)
        XCTAssertEqual(TodayColumns.count(width: 848, textScale: standardScale), 2)
        XCTAssertEqual(TodayColumns.count(width: 847, textScale: standardScale), 1)
        XCTAssertEqual(TodayColumns.count(width: 0, textScale: standardScale), 1)
        let widest = WorkspaceMetric.todayMaxWidth - 2 * LBTokens.Metric.detailPadding
        XCTAssertEqual(TodayColumns.count(width: widest, textScale: standardScale), 2)
        let reading = WorkspaceMetric.todayReadingMaxWidth - 2 * LBTokens.Metric.detailPadding
        XCTAssertEqual(TodayColumns.count(width: reading, textScale: standardScale), 1)
        XCTAssertEqual(TodayColumns.count(
            width: LBTokens.Metric.contentDetailMinWidth, textScale: AppTextSize.small.scale), 1)
    }

    func testColumnsGrowWithTheTextSize() {
        let small = TodayColumns.twoColumnMinimumWidth(textScale: AppTextSize.small.scale)
        let standard = TodayColumns.twoColumnMinimumWidth(textScale: standardScale)
        let largest = TodayColumns.twoColumnMinimumWidth(textScale: AppTextSize.largest.scale)
        XCTAssertLessThan(small, standard)
        XCTAssertLessThan(standard, largest)
        XCTAssertLessThan(TodayColumns.trailingWidth(textScale: AppTextSize.small.scale), 352)
        XCTAssertGreaterThan(TodayColumns.trailingWidth(textScale: AppTextSize.largest.scale), 352)
        XCTAssertEqual(TodayColumns.count(width: 900, textScale: standardScale), 2)
        XCTAssertEqual(TodayColumns.count(width: 900, textScale: AppTextSize.largest.scale), 1)
    }

    func testASideWithoutPanelsLeavesNoGutter() {
        XCTAssertEqual(TodayColumns.count(width: 1_144, textScale: standardScale, hasLeading: true, hasTrailing: false), 1)
        XCTAssertEqual(TodayColumns.count(width: 1_144, textScale: standardScale, hasLeading: false, hasTrailing: true), 1)
        XCTAssertEqual(TodayColumns.count(width: 1_144, textScale: standardScale, hasLeading: false, hasTrailing: false), 1)
        func maximum(_ leading: Bool, _ trailing: Bool) -> CGFloat {
            TodayColumns.pageMaximumWidth(hasLeading: leading, hasTrailing: trailing, wide: 1_200, reading: 780)
        }
        XCTAssertEqual(maximum(true, true), 1_200)
        XCTAssertEqual(maximum(false, false), 1_200)
        XCTAssertEqual(maximum(true, false), 780)
        XCTAssertEqual(maximum(false, true), 780)
    }

    func testTwoColumnsPlacePanelsBetweenTheCardsThatSpanThePage() {
        let slots: [TodayColumnsLayout.Slot] = [.full, .leading, .leading, .trailing, .full, .full]
        let heights: [CGFloat] = [100, 200, 300, 240, 320, 80]
        let result = TodayColumnsLayout.frames(
            slots: slots, width: 1_144, textScale: standardScale, spacing: 16) { index, _ in heights[index] }
        XCTAssertEqual(result.frames, [
            CGRect(x: 0, y: 0, width: 1_144, height: 100),
            CGRect(x: 0, y: 116, width: 776, height: 200),
            CGRect(x: 0, y: 332, width: 776, height: 300),
            CGRect(x: 792, y: 116, width: 352, height: 240),
            CGRect(x: 0, y: 648, width: 1_144, height: 320),
            CGRect(x: 0, y: 984, width: 1_144, height: 80),
        ])
        XCTAssertEqual(result.height, 1_064)
    }

    func testYesterdayBriefSplitsIntoTwoColumnsOnlyWhenWideEnough() {
        let standard = YesterdayBriefColumns.minimumWidth(textScale: standardScale)
        XCTAssertEqual(standard, 840)
        XCTAssertLessThan(YesterdayBriefColumns.minimumWidth(textScale: AppTextSize.small.scale), standard)
        XCTAssertGreaterThan(YesterdayBriefColumns.minimumWidth(textScale: AppTextSize.largest.scale), standard)
        XCTAssertTrue(YesterdayBriefColumns.isTwoColumn(width: 1_112, textScale: standardScale))
        XCTAssertTrue(YesterdayBriefColumns.isTwoColumn(width: 840, textScale: standardScale))
        XCTAssertFalse(YesterdayBriefColumns.isTwoColumn(width: 839, textScale: standardScale))
        XCTAssertFalse(YesterdayBriefColumns.isTwoColumn(width: 840, textScale: AppTextSize.largest.scale))

        var asked: [CGFloat] = []
        let wide = YesterdayBriefColumnsLayout.frames(
            width: 1_112, textScale: standardScale,
            primaryHeight: { asked.append($0); return 260 },
            secondaryHeight: { asked.append($0); return 340 })
        XCTAssertEqual(asked, [578, 493])
        XCTAssertEqual(wide.frames, [
            CGRect(x: 0, y: 0, width: 578, height: 260),
            CGRect(x: 598, y: 0, width: 1, height: 340),
            CGRect(x: 619, y: 0, width: 493, height: 340),
        ])
        XCTAssertEqual(wide.height, 340)

        var narrowAsked: [CGFloat] = []
        let narrow = YesterdayBriefColumnsLayout.frames(
            width: 692, textScale: standardScale,
            primaryHeight: { narrowAsked.append($0); return 200 },
            secondaryHeight: { narrowAsked.append($0); return 180 })
        XCTAssertEqual(narrowAsked, [692, 692])
        XCTAssertEqual(narrow.frames, [
            CGRect(x: 0, y: 0, width: 692, height: 200),
            CGRect(x: 0, y: 214, width: 692, height: 1),
            CGRect(x: 0, y: 229, width: 692, height: 180),
        ])
        XCTAssertEqual(narrow.height, 409)

        var midAsked: [CGFloat] = []
        let mid = YesterdayBriefColumnsLayout.frames(
            width: 816, textScale: standardScale,
            primaryHeight: { midAsked.append($0); return 200 },
            secondaryHeight: { midAsked.append($0); return 180 })
        XCTAssertEqual(midAsked, [720, 720])
        XCTAssertEqual(mid.frames[1], CGRect(x: 0, y: 214, width: 816, height: 1))
    }

    func testOneColumnStacksPanelsInReadingOrder() {
        let slots: [TodayColumnsLayout.Slot] = [.leading, .leading, .trailing, .trailing]
        var asked: [CGFloat] = []
        let narrow = TodayColumnsLayout.frames(
            slots: slots, width: 700, textScale: standardScale, spacing: 16) { _, width in
                asked.append(width)
                return 100
            }
        XCTAssertEqual(narrow.frames.map(\.minY), [0, 116, 232, 348])
        XCTAssertEqual(Set(narrow.frames.map(\.width)), [700])
        XCTAssertEqual(Set(asked), [700], "each panel is measured at the width it gets")
        XCTAssertEqual(narrow.height, 448)

        let oneSided = TodayColumnsLayout.frames(
            slots: [.full, .trailing, .trailing], width: 1_008, textScale: standardScale, spacing: 16) { _, _ in 100 }
        XCTAssertEqual(oneSided.frames.map(\.minX), [0, 0, 0])
        XCTAssertEqual(Set(oneSided.frames.map(\.width)), [1_008])

        let empty = TodayColumnsLayout.frames(
            slots: [], width: 1_008, textScale: standardScale, spacing: 16) { _, _ in 100 }
        XCTAssertEqual(empty.height, 0)
    }

    func testAppBarsAreSharesOfTheLongestRow() {
        let bars = TodayAppBars.bars(
            perApp: [("Safari", 2_700), ("Xcode", 5_400), ("Slack", 600), ("Notes", 0)], cap: 4)
        XCTAssertEqual(bars.map(\.label), ["Xcode", "Safari", "Slack"])
        XCTAssertEqual(bars.map(\.seconds), [5_400, 2_700, 600])
        XCTAssertEqual(bars[0].fraction, 1)
        XCTAssertEqual(bars[1].fraction, 0.5)
        XCTAssertEqual(bars[2].fraction, 600.0 / 5_400, accuracy: 0.0001)
        XCTAssertTrue(bars.allSatisfy { !$0.isOther })
        XCTAssertTrue(TodayAppBars.bars(perApp: [], cap: 4).isEmpty)
        XCTAssertTrue(TodayAppBars.bars(perApp: [("Idle", 0)], cap: 4).isEmpty)
    }

    func testTheFoldedTailNeverRunsPastTheTrack() {
        let perApp: [(label: String, seconds: TimeInterval)] =
            [("Xcode", 600)] + (0..<6).map { ("App \($0)", 300) }
        let bars = TodayAppBars.bars(perApp: perApp, cap: 2)
        XCTAssertEqual(bars.map(\.label), ["Xcode", "App 0", "Other"])
        let other = try? XCTUnwrap(bars.last)
        XCTAssertEqual(other?.isOther, true)
        XCTAssertEqual(other?.seconds, 1_500)
        XCTAssertEqual(other?.fraction, 1)
        XCTAssertEqual(bars[0].fraction, 0.4, accuracy: 0.0001)
        XCTAssertEqual(Set(bars.map(\.id)).count, bars.count)
        let named = TodayAppBars.bars(perApp: [("Other", 600), ("A", 30), ("B", 30)], cap: 4)
        XCTAssertEqual(Set(named.map(\.id)).count, named.count)
    }

    func testAttentionSummaryCountsOverdueAndWhatActionsStillHolds() throws {
        let tuesday = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 9, day: 22, hour: 10, minute: 30)))
        let lastWeek = try XCTUnwrap(calendar.date(byAdding: .day, value: -7, to: tuesday))
        let meetingID = UUID()
        func reference(_ text: String, due: String?, spoken: Date,
                       status: OutcomeStatus = .open) -> OutcomeActionReference {
            let action = MeetingOutcomes.ActionItem(text: text, owner: "Me", due: due)
            return OutcomeActionReference(
                meetingID: meetingID, meetingTitle: "Sync", meetingStartedAt: spoken,
                action: action, status: status, text: action.text, owner: "Me", due: due,
                stateUpdatedAt: spoken, textWasCorrected: false, ownerWasCorrected: false,
                dueWasCorrected: false)
        }
        let threads = ActionThreadClusterer.cluster([
            reference("Overdue synthetic budget draft", due: "Thursday", spoken: lastWeek),
            reference("Overdue synthetic vendor reply", due: "Friday", spoken: lastWeek),
            reference("Due soon synthetic review work", due: "Friday", spoken: tuesday),
            reference("Undated synthetic follow-up task", due: nil, spoken: tuesday),
            reference("Far future synthetic planning memo", due: "next month", spoken: tuesday),
        ])
        XCTAssertEqual(threads.count, 5)

        let summary = TodayAttentionSummary(threads: threads, limit: 3, now: tuesday, calendar: calendar)
        XCTAssertEqual(summary.open, 5)
        XCTAssertEqual(summary.overdue, 2)
        XCTAssertEqual(summary.shown, 3, "the footer names the real number of rows")
        XCTAssertEqual(summary.remainder, 2)
        XCTAssertEqual(summary.remainder, NeedsAttentionSection.remainder(total: 5, limit: 3))
        XCTAssertTrue(summary.showsFooter)

        let few = TodayAttentionSummary(
            threads: Array(threads.filter { !$0.isOverdue(now: tuesday, calendar: calendar) }.suffix(2)),
            limit: 3, now: tuesday, calendar: calendar)
        XCTAssertEqual([few.open, few.overdue, few.shown, few.remainder], [2, 0, 2, 0])
        XCTAssertFalse(few.showsFooter)

        let earlier = TodayAttentionSummary(threads: threads, limit: 3, now: lastWeek, calendar: calendar)
        XCTAssertEqual(earlier.overdue, 0)

        let none = TodayAttentionSummary(threads: [], limit: 3, now: tuesday, calendar: calendar)
        XCTAssertEqual([none.open, none.overdue, none.shown, none.remainder], [0, 0, 0, 0])
        let noRows = TodayAttentionSummary(threads: threads, limit: -1, now: tuesday, calendar: calendar)
        XCTAssertEqual([noRows.shown, noRows.remainder], [0, 5])
    }

    func testTheNowLineReplacesTheHairlineBeforeIt() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func entry(_ id: String, offset: TimeInterval) -> TodayAgenda.Row {
            let event = CalendarMeetingCandidate(
                provider: "test", externalID: id, title: id, startDate: now.addingTimeInterval(offset),
                endDate: now.addingTimeInterval(offset + 1_800),
                meetingURL: nil, sourceCalendarTitle: "Work", participantNames: [])
            return .entry(.init(id: id, source: .event(event), title: id, start: event.startDate,
                                status: TodayAgenda.status(of: event, now: now), isSoon: false))
        }
        let rows = [entry("a", offset: -7_200), entry("b", offset: -3_600), .now(now),
                    entry("c", offset: 3_600), entry("d", offset: 7_200)]
        XCTAssertTrue(TodayMeetingsSection.hasHairline(after: 0, in: rows))
        XCTAssertFalse(TodayMeetingsSection.hasHairline(after: 1, in: rows), "the now line draws its own rule")
        XCTAssertTrue(TodayMeetingsSection.hasHairline(after: 3, in: rows))
        XCTAssertFalse(TodayMeetingsSection.hasHairline(after: 4, in: rows), "the last row ends at the panel")
    }

    func testPanelsAreOnThePageOnlyInTheSectionsLayout() {
        XCTAssertTrue(TodayPageLayout.sections(gettingStartedBelow: true).showsSections)
        XCTAssertTrue(TodayPageLayout.sections(gettingStartedBelow: false).showsSections)
        XCTAssertFalse(TodayPageLayout.gettingStarted.showsSections)
        XCTAssertFalse(TodayPageLayout.placeholder.showsSections)
    }

    func testEverySectionHasItsOwnSymbol() {
        let sections: [AppState.NavSection] = [.today, .actions, .timeline, .meetings, .people, .projects, .ask, .agent]
        XCTAssertEqual(Set(sections.map(\.symbol)).count, sections.count)
        XCTAssertEqual(AppState.NavSection.actions.symbol, "checkmark.circle")
        XCTAssertEqual(AppState.NavSection.meetings.symbol, "waveform.circle")
        XCTAssertEqual(AppState.NavSection.timeline.symbol, "calendar.day.timeline.left")
    }
}
