import XCTest
@testable import LokalBot

/// The list in Timeline's rail for one day: order, parts of the day, gaps, a
/// call folded into its meeting, each row's two lines, and the arrow keys.
final class TimelineDayListTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Podgorica")!
        return calendar
    }()

    /// Midnight of a fixed day in the test calendar.
    private var day: Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: 9))!
    }

    private func at(_ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)!
    }

    private func block(_ id: Int64, app: String, title: String = "", from start: Date, to end: Date) -> ActivityBlock {
        ActivityBlock(id: id, app: app, title: title, start: start, end: end)
    }

    private func session(_ id: Int64, app: String, title: String = "", from start: Date, to end: Date) -> TimelineWorkSession {
        TimelineWorkSession.sessions(from: [block(id, app: app, title: title, from: start, to: end)])[0]
    }

    private func meeting(_ title: String, app: String = "Zoom", from start: Date, to end: Date?) -> Meeting {
        Meeting(id: UUID(), title: title, appName: app, startedAt: start, endedAt: end,
                relativePath: "meetings/\(title)")
    }

    private func burst(
        _ project: String, title: String, from start: Date, to end: Date,
        actions: [CodingAgentAction] = []
    ) -> CodingAgentBurst {
        CodingAgentBurst(
            agent: .claudeCode, sessionID: "\(project)-\(Int(start.timeIntervalSince1970))", title: title,
            project: project, branch: nil, start: start, end: end,
            activeDuration: end.timeIntervalSince(start), prompts: ["Make the retries back off"],
            promptCount: 1, finalReply: nil, changedFiles: [], changedFileCount: 0, actions: actions,
            pullRequests: [], toolCallCount: 0)
    }

    private func list(
        _ sessions: [TimelineWorkSession], _ meetings: [Meeting] = [], usesProjectColors: Bool = false
    ) -> TimelineDayList {
        TimelineDayList(sessions: sessions, meetings: meetings, now: at(23), usesProjectColors: usesProjectColors,
                        calendar: calendar)
    }

    private func titles(in section: TimelineDayList.Section) -> [String] {
        section.entries.compactMap { entry in
            if case .row(let row) = entry { return row.title }
            return nil
        }
    }

    private func gaps(in day: TimelineDayList) -> [DateInterval] {
        day.sections.flatMap(\.entries).compactMap { entry in
            if case .away(let start, let end) = entry { return DateInterval(start: start, end: end) }
            return nil
        }
    }

    // MARK: - Order and parts of the day

    func testRowsRunInTimeOrderUnderMorningAfternoonAndEvening() {
        let standup = meeting("Standup", app: "Slack", from: at(9, 30), to: at(9, 45))
        let day = list(
            [session(1, app: "Xcode", title: "Sync.swift", from: at(9, 10), to: at(10, 15)),
             session(2, app: "Notes", title: "Migration plan", from: at(15, 5), to: at(15, 40)),
             session(3, app: "Xcode", title: "Upload.swift", from: at(17, 40), to: at(18, 14)),
             session(4, app: "Safari", title: "Docs", from: at(11, 59), to: at(12, 20))],
            [standup])

        XCTAssertEqual(day.sections.map(\.part), [.morning, .afternoon, .evening])
        XCTAssertEqual(day.rows.map(\.title), ["Sync.swift", "Standup", "Docs", "Migration plan", "Upload.swift"])
        // 11:59 belongs to the morning it started in; 17:40 to the evening.
        XCTAssertEqual(titles(in: day.sections[0]), ["Sync.swift", "Standup", "Docs"])
        XCTAssertEqual(titles(in: day.sections[2]), ["Upload.swift"])
        XCTAssertEqual(TimelineDayList.Part.part(of: at(12), calendar: calendar), .afternoon)
        XCTAssertEqual(TimelineDayList.Part.part(of: at(16, 59), calendar: calendar), .afternoon)
        XCTAssertEqual(TimelineDayList.Part.part(of: at(17), calendar: calendar), .evening)
        XCTAssertEqual(TimelineDayList.Part.morning.title, "Morning")
    }

    func testAMeetingLeadsASessionThatStartsWithIt() {
        let review = meeting("Design review", from: at(11), to: at(11, 45))
        let day = list([session(1, app: "Notes", title: "Review notes", from: at(11), to: at(11, 40))], [review])

        XCTAssertEqual(day.rows.map(\.title), ["Design review", "Review notes"])
        XCTAssertEqual(day.rows[0].id, TimelineDayList.Row.id(meeting: review.id))
        XCTAssertEqual(day.rows[1].id, TimelineDayList.Row.id(session: 1))
    }

    func testAnEmptyDayHasNoSections() {
        XCTAssertTrue(list([]).isEmpty)
        XCTAssertTrue(list([]).rows.isEmpty)
    }

    // MARK: - Gaps

    func testALongStretchWithNothingRecordedIsKeptAsAGapInThePartItBegan() {
        let day = list([
            session(1, app: "Slack", title: "#design-crit", from: at(11, 50), to: at(12, 2)),
            session(2, app: "Xcode", title: "Queue.swift", from: at(13), to: at(14, 30)),
            session(3, app: "Safari", title: "Mail", from: at(14, 45), to: at(15)),
        ])

        XCTAssertEqual(day.sections.map(\.part), [.morning, .afternoon])
        guard case .away(let start, let end) = day.sections[0].entries.last else {
            return XCTFail("The 58 minutes away should close the morning")
        }
        XCTAssertEqual(start, at(12, 2))
        XCTAssertEqual(end, at(13))
        // Fifteen minutes is not a gap.
        XCTAssertEqual(day.sections[1].entries.count, 2)
    }

    /// A meeting that runs past the next session must not open a gap that
    /// never happened: a gap starts at the latest end seen so far.
    func testAGapStartsAtTheLatestEndSoFar() {
        let planning = meeting("Planning", from: at(10), to: at(12))
        let day = list(
            [session(1, app: "Xcode", title: "A.swift", from: at(8), to: at(8, 10)),
             session(2, app: "Xcode", title: "B.swift", from: at(9), to: at(9, 5)),
             session(3, app: "Xcode", title: "C.swift", from: at(10, 30), to: at(10, 40)),
             session(4, app: "Xcode", title: "D.swift", from: at(12, 20), to: at(12, 30))],
            [planning])

        // 8:10 → 9:00 is 50 minutes away. 9:05 → 10:00 is 55. The meeting
        // covers C.swift and ends 20 minutes before D.swift.
        XCTAssertEqual(gaps(in: day).map(\.start), [at(8, 10), at(9, 5)])
    }

    // MARK: - A call folds into its meeting

    func testACallAppSessionFoldsIntoTheMeetingThatCoversIt() {
        let review = meeting("Design review", app: "Zoom", from: at(11), to: at(11, 45))
        let day = list(
            [session(1, app: "Xcode", title: "Sync.swift", from: at(9), to: at(10)),
             // Zoom's own name in the activity sampler is "zoom.us".
             session(2, app: "zoom.us", title: "Zoom Meeting", from: at(10, 58), to: at(11, 46))],
            [review])

        XCTAssertEqual(day.rows.map(\.title), ["Sync.swift", "Design review"])
        XCTAssertEqual(day.rows[1].foldedSessionIDs, [2])
        XCTAssertEqual(day.rowID(showing: 2), TimelineDayList.Row.id(meeting: review.id))
        XCTAssertEqual(day.rowID(showing: 1), TimelineDayList.Row.id(session: 1))
        // The gap ends where the call's app came forward, two minutes
        // before the recording began.
        XCTAssertEqual(gaps(in: day), [DateInterval(start: at(10), end: at(10, 58))])
    }

    func testOtherWorkDuringAMeetingStaysListed() {
        let standup = meeting("Standup", app: "Slack", from: at(10), to: at(10, 15))
        let day = list(
            // Another app during the call, and the call's app for a morning
            // of which the call was a small part.
            [session(1, app: "Xcode", title: "Sync.swift", from: at(10), to: at(10, 15)),
             session(2, app: "Slack", title: "#engineering", from: at(10, 20), to: at(12))],
            [standup])

        XCTAssertEqual(day.rows.count, 3)
        XCTAssertTrue(day.rows.allSatisfy { $0.foldedSessionIDs.isEmpty })
    }

    func testAgentWorkInTheCallAppIsNeverFolded() {
        let work = [burst("Atlas", title: "Fix the retry loop", from: at(11), to: at(11, 40))]
        let sessions = TimelineWorkSession.sessions(
            from: [block(1, app: "Claude", from: at(11), to: at(11, 40))],
            attribution: TimelineProjectAttribution(bursts: work))
        let call = meeting("Pairing", app: "Claude", from: at(11), to: at(11, 45))

        XCTAssertNil(TimelineDayList.meeting(covering: sessions[0], in: [(call, at(11, 45))]))
        XCTAssertEqual(list(sessions, [call]).rows.count, 2)
    }

    func testCallAppNamesMatchAcrossTheirTwoSpellings() {
        XCTAssertTrue(TimelineDayList.isSameApp("zoom.us", "Zoom"))
        XCTAssertTrue(TimelineDayList.isSameApp("Microsoft Teams", "Teams"))
        XCTAssertTrue(TimelineDayList.isSameApp("Google Chrome", "Google Chrome"))
        XCTAssertFalse(TimelineDayList.isSameApp("Xcode", "Zoom"))
        // A manual recording names no app; nothing folds into it.
        XCTAssertFalse(TimelineDayList.isSameApp("Zoom", ""))
        XCTAssertFalse(TimelineDayList.isSameApp("QQ", "QQ"))
    }

    // MARK: - Row text

    func testAProjectSessionShowsItsTaskThenProjectAndWhatWasProduced() {
        let work = [burst("Atlas", title: "Fix the sync retry loop", from: at(9, 10), to: at(10),
                          actions: [.openedPullRequest(title: "Back off sync retries"), .commit(message: "Retry")])]
        let sessions = TimelineWorkSession.sessions(
            from: [block(1, app: "Claude", from: at(9, 10), to: at(10, 15))],
            attribution: TimelineProjectAttribution(bursts: work))
        let day = list(sessions, usesProjectColors: true)

        XCTAssertEqual(sessions[0].title, "Atlas · Fix the sync retry loop")
        XCTAssertEqual(sessions[0].projectLabel, "Atlas")
        XCTAssertEqual(sessions[0].taskTitle, "Fix the sync retry loop")
        XCTAssertEqual(day.rows[0].title, "Fix the sync retry loop")
        // Commits are named only when no pull request moved.
        XCTAssertEqual(day.rows[0].detail, "Atlas · 1 PR opened")
        XCTAssertEqual(day.rows[0].colorKey, "Atlas")
        XCTAssertEqual(day.rows[0].duration, 65 * 60)
        XCTAssertFalse(day.rows[0].isQuiet)
    }

    func testASessionsPageNamesItsProjectTimeAndApps() {
        let work = [burst("Atlas", title: "Fix the sync retry loop", from: at(9, 10), to: at(10))]
        let project = TimelineWorkSession.sessions(
            from: [block(1, app: "Claude", from: at(9, 10), to: at(9, 40)),
                   block(2, app: "Terminal", from: at(9, 40), to: at(10))],
            attribution: TimelineProjectAttribution(bursts: work))[0]
        let subtitle = TimelineSessionWording.subtitle(for: project) { $0 == "%@ active" ? "aktivno %@" : $0 }

        XCTAssertTrue(subtitle.hasPrefix("Atlas · "), subtitle)
        XCTAssertTrue(subtitle.contains(" · aktivno 50m · "), subtitle)
        XCTAssertTrue(subtitle.hasSuffix(" · Claude, Terminal"), subtitle)

        // Without a project the line starts with the time range.
        let plain = session(3, app: "Xcode", title: "TimelineView.swift", from: at(9), to: at(10, 30))
        let plainSubtitle = TimelineSessionWording.subtitle(for: plain)
        XCTAssertFalse(plainSubtitle.contains("Atlas"))
        XCTAssertTrue(plainSubtitle.hasSuffix(" · 1h 30m active · Xcode"), plainSubtitle)
    }

    func testAWindowSessionShowsItsTitleThenItsApps() {
        let titled = session(1, app: "Xcode", title: "TimelineView.swift", from: at(9), to: at(10, 30))
        let text = TimelineDayList.workText(for: titled)

        XCTAssertEqual(text.title, "TimelineView.swift")
        XCTAssertEqual(text.detail, "Xcode")
        XCTAssertFalse(text.isQuiet)
        XCTAssertNil(titled.projectLabel)
        XCTAssertNil(titled.taskTitle)
    }

    func testASessionOnlyItsAppsDescribeIsOneQuietLine() {
        let sessions = TimelineWorkSession.sessions(from: [
            block(1, app: "Mail", from: at(8, 52), to: at(9, 3)),
            block(2, app: "Slack", from: at(9, 3), to: at(9, 10)),
        ])
        let text = TimelineDayList.workText(for: sessions[0])

        XCTAssertEqual(text.title, "Mail, Slack")
        XCTAssertEqual(text.detail, "")
        XCTAssertTrue(text.isQuiet)
    }

    func testAMeetingRowNamesItsAppAndWhetherItIsStillRecording() {
        let live = meeting("Planning", app: "Zoom", from: at(16), to: nil)
        let day = TimelineDayList(sessions: [], meetings: [live], now: at(16, 25), calendar: calendar)

        XCTAssertEqual(day.rows[0].detail, "Recording · Zoom")
        XCTAssertEqual(day.rows[0].kind, .meeting(live.id, isLive: true))
        XCTAssertEqual(day.rows[0].duration, 25 * 60)
        XCTAssertEqual(TimelineDayList.meetingDetail(app: "Zoom", isLive: false), "Meeting · Zoom")
        XCTAssertEqual(TimelineDayList.meetingDetail(app: " ", isLive: false), "Meeting")
        XCTAssertNil(day.rows[0].colorKey)
    }

    func testRowTextUsesTheInterfaceLanguage() {
        let translations = ["Meeting": "Sastanak", "%lld PRs opened": "Otvoreno PR-ova: %lld", "%lld merged": "spojeno: %lld"]
        let localize: (String) -> String = { translations[$0] ?? $0 }
        var outcomes = TimelineAgentOutcomes([])
        outcomes.openedPullRequests = ["One", "Two"]
        outcomes.mergedPullRequests = 1
        outcomes.commits = 3

        XCTAssertEqual(TimelineDayList.meetingDetail(app: "Zoom", isLive: false, localize: localize), "Sastanak · Zoom")
        XCTAssertEqual(TimelineOutcomeWording.text(outcomes, localize: localize), "Otvoreno PR-ova: 2 · spojeno: 1")
        XCTAssertEqual(TimelineOutcomeWording.text(TimelineAgentOutcomes([])), nil)
        var commits = TimelineAgentOutcomes([])
        commits.commits = 3
        XCTAssertEqual(TimelineOutcomeWording.text(commits), "3 commits")
    }

    func testOnADaySplitByProjectASessionWithoutOneReadsAsOtherActivity() {
        let chat = session(1, app: "Slack", title: "#engineering", from: at(17, 25), to: at(17, 35))

        XCTAssertNil(list([chat], usesProjectColors: true).rows[0].colorKey)
        XCTAssertEqual(list([chat]).rows[0].colorKey, "Slack")
    }

    // MARK: - Finding rows and moving through the list

    func testAnOlderDigestsTimeRangeFindsTheSessionItCoversMost() {
        let review = meeting("Design review", from: at(9, 30), to: at(10))
        let day = list(
            [session(1, app: "Xcode", title: "TimelineView.swift", from: at(9), to: at(10, 30)),
             session(2, app: "Safari", title: "Pull request #42", from: at(10, 30), to: at(11, 15))],
            [review])

        XCTAssertEqual(day.workRow(inTimeRange: "09:00–10:30", day: self.day, calendar: calendar)?.title,
                       "TimelineView.swift")
        XCTAssertEqual(day.workRow(inTimeRange: "10:20-11:00", day: self.day, calendar: calendar)?.title,
                       "Pull request #42")
        XCTAssertNil(day.workRow(inTimeRange: "14:00–15:00", day: self.day, calendar: calendar))
        XCTAssertNil(day.workRow(inTimeRange: "morning", day: self.day, calendar: calendar))
        XCTAssertNil(TimelineDayList.interval(fromTimeRange: "25:00–26:00", day: self.day, calendar: calendar))
        // A range that ends past midnight is clipped to the day.
        XCTAssertEqual(
            TimelineDayList.interval(fromTimeRange: "23:30–00:15", day: self.day, calendar: calendar)?.duration, 1_800)
    }

    /// The list is under Morning, Afternoon and Evening, so a 12-hour clock
    /// shows "9:10" and "1:05": no AM or PM, and no leading zero (the hosted
    /// runs on macOS 15 and 26 showed "09:10" from `Date.FormatStyle`).
    func testListTimesDropTheDayPeriodAndTheLeadingZeroOnATwelveHourClock() {
        let zone = calendar.timeZone
        func time(_ date: Date, _ locale: String) -> String {
            TimelineListClock.text(date, locale: Locale(identifier: locale), timeZone: zone)
        }
        XCTAssertEqual(time(at(9, 10), "en_US"), "9:10")
        XCTAssertEqual(time(at(13, 5), "en_US"), "1:05")
        XCTAssertEqual(time(at(0, 30), "en_US"), "12:30")
        // The day period goes wherever the language puts it.
        XCTAssertEqual(time(at(13, 5), "ko_KR"), "1:05")
        XCTAssertEqual(time(at(13, 5), "ar_SA@numbers=latn"), "1:05")
        // A 24-hour clock keeps its own form.
        XCTAssertEqual(time(at(9, 10), "de_DE"), "09:10")
        XCTAssertEqual(time(at(13, 5), "de_DE"), "13:05")
        XCTAssertEqual(time(at(9, 10), "fr_FR"), "09:10")
        XCTAssertEqual(time(at(9, 10), "sr_Latn_ME"), "09:10")
    }

    /// The pattern is the locale's own with the day period taken out, so it
    /// does not depend on how a macOS release formats an hour without one.
    func testListTimePatternHasNoDayPeriod() {
        XCTAssertEqual(TimelineListClock.pattern(locale: Locale(identifier: "en_US")), "h:mm")
        XCTAssertEqual(TimelineListClock.pattern(locale: Locale(identifier: "de_DE")), "HH:mm")
        for identifier in ["en_US", "en_GB", "ja_JP", "ko_KR", "zh_Hans_CN", "zh_Hant_TW", "ar_SA", "hi_IN", "ur_PK"] {
            let pattern = TimelineListClock.pattern(locale: Locale(identifier: identifier))
            XCTAssertNil(pattern.rangeOfCharacter(from: CharacterSet(charactersIn: "aAbB ")), identifier)
            XCTAssertFalse(pattern.hasPrefix("hh"), identifier)
        }
    }

    /// The rail lists sessions and meetings, with All captured activity as
    /// its bottom row. The day's page has no row: it is what shows while no
    /// row is chosen, and it stands before the first one for the arrow keys.
    func testArrowKeysWalkTheSessionsBetweenTheDaysPageAndAllCapturedActivity() {
        let day = list([
            session(1, app: "Xcode", title: "A.swift", from: at(9), to: at(9, 30)),
            session(2, app: "Xcode", title: "B.swift", from: at(13), to: at(13, 30)),
        ])
        let first = TimelineListSelection.row(TimelineDayList.Row.id(session: 1))
        let second = TimelineListSelection.row(TimelineDayList.Row.id(session: 2))

        XCTAssertEqual(TimelineListSelection.order(of: day), [.digest, first, second, .raw])
        // Down from the day's page chooses the first session, and goes on
        // through the sessions to All captured activity.
        XCTAssertEqual(TimelineListSelection.digest.moved(by: 1, in: day), first)
        XCTAssertEqual(first.moved(by: 1, in: day), second)
        XCTAssertEqual(second.moved(by: 1, in: day), .raw)
        // Up walks back; from the first session it returns to the day's page.
        XCTAssertEqual(TimelineListSelection.raw.moved(by: -1, in: day), second)
        XCTAssertEqual(second.moved(by: -1, in: day), first)
        XCTAssertEqual(first.moved(by: -1, in: day), .digest)
        // The ends hold, and a moment opened from another page steps onto the day's page.
        XCTAssertEqual(TimelineListSelection.raw.moved(by: 1, in: day), .raw)
        XCTAssertEqual(TimelineListSelection.digest.moved(by: -1, in: day), .digest)
        XCTAssertEqual(TimelineListSelection.none.moved(by: 1, in: day), .digest)
        XCTAssertEqual(TimelineListSelection.none.moved(by: -1, in: day), .digest)
    }

    func testOnADayWithoutSessionsTheArrowKeysStepBetweenTheDaysPageAndAllCapturedActivity() {
        let empty = list([])

        XCTAssertEqual(TimelineListSelection.order(of: empty), [.digest, .raw])
        XCTAssertEqual(TimelineListSelection.digest.moved(by: 1, in: empty), .raw)
        XCTAssertEqual(TimelineListSelection.raw.moved(by: -1, in: empty), .digest)
    }

    func testAMeetingRowIsWalkedLikeASession() {
        let call = meeting("Design review", from: at(11), to: at(11, 25))
        let day = list([session(1, app: "Xcode", title: "A.swift", from: at(9), to: at(9, 30))], [call])
        let work = TimelineListSelection.row(TimelineDayList.Row.id(session: 1))
        let meetingRow = TimelineListSelection.row(TimelineDayList.Row.id(meeting: call.id))

        XCTAssertEqual(work.moved(by: 1, in: day), meetingRow)
        XCTAssertEqual(meetingRow.moved(by: 1, in: day), .raw)
    }
}
