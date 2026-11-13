import XCTest
@testable import LokalBot

/// The Projects list as drawn (tracked by last activity, then suggestions
/// with their source) and the wording, time and suggestion rules of a
/// project's page. Names are synthetic.
final class ProjectsListPresentationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_794_312_000) // Tuesday 2026-11-10 12:00 UTC
    private let locale = Locale(identifier: "en_US")
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        calendar.locale = locale
        return calendar
    }

    private func daysAgo(_ days: Double) -> Date { now.addingTimeInterval(-days * 86_400) }

    private func profile(
        _ name: String, kind: ProjectProfile.Kind? = nil, otherNames: [String] = [],
        meetings: [ProjectProfile.MeetingRef] = [], reviewNotes: [ProjectProfile.ReviewNote] = [],
        days: [ProjectProfile.DayTime] = [], windows: [ProjectProfile.WindowTime] = [], people: [String] = [],
        lastActive: Date? = nil, windowCount: Int = 0
    ) -> ProjectProfile {
        let kind = kind ?? .tracked(UUID())
        let prefix: String
        switch kind {
        case .tracked(let id): prefix = "tracked:" + id.uuidString
        case .suggestedTopic: prefix = "topic:" + name.lowercased()
        case .suggestedReview: prefix = "review:" + name.lowercased()
        }
        return ProjectProfile(
            id: prefix, name: name, kind: kind, otherNames: otherNames, meetings: meetings, myActions: [],
            othersActions: [], olderOthersActions: [], decisions: [], reviewNotes: reviewNotes, days: days,
            windows: windows, people: people, lastActive: lastActive, windowCount: windowCount)
    }

    private func meetings(_ count: Int, newestDaysAgo: Double = 0) -> [ProjectProfile.MeetingRef] {
        (0..<count).map { index in
            .init(id: UUID(), title: "Synthetic sync \(index)", startedAt: daysAgo(newestDaysAgo + Double(index)),
                  mentions: [])
        }
    }

    private func build(_ projects: [ProjectProfile], query: String = "") -> ProjectsListContent {
        ProjectsListContent.build(projects: projects, query: query, now: now, calendar: calendar, locale: locale)
    }

    // MARK: - List

    func testTrackedRowsRunFromMostRecentlyActiveAndSayWhen() {
        let content = build([
            profile("Borealis", lastActive: daysAgo(19)),
            profile("Cinder"),
            profile("Ember", lastActive: daysAgo(5)),
            profile("Atlas", lastActive: now.addingTimeInterval(-7_200)),
            profile("Dune", lastActive: daysAgo(1)),
        ])
        XCTAssertEqual(content.tracked.map(\.name), ["Atlas", "Dune", "Ember", "Borealis", "Cinder"])
        XCTAssertEqual(content.tracked.map(\.detail), [
            "Active today", "Active yesterday", "Last active Thu, Nov 5", "Quiet since Oct 22", "Nothing linked yet",
        ])
        XCTAssertEqual(content.tracked.map(\.isQuiet), [false, false, false, true, false],
                       "only a project nothing has named for weeks is drawn fainter")
        XCTAssertTrue(content.suggested.isEmpty)
        XCTAssertTrue(content.tracked.allSatisfy { !$0.isSuggestion })
    }

    func testProjectsWithTheSameActivityAreListedByName() {
        let content = build([profile("Zephyr"), profile("atlas"), profile("Borealis")])
        XCTAssertEqual(content.tracked.map(\.name), ["atlas", "Borealis", "Zephyr"])
    }

    func testQuietBeginsWhereOthersWorkStopsBeingRecent() {
        XCTAssertEqual(ProjectsListContent.quietAfterDays, ProjectLinks.recentOthersActionDays)
        let lastRecentDay = daysAgo(Double(ProjectsListContent.quietAfterDays - 1))
        let firstQuietDay = daysAgo(Double(ProjectsListContent.quietAfterDays))
        XCTAssertEqual(ProjectsListContent.activity(lastActive: lastRecentDay, now: now, calendar: calendar),
                       .recent(lastRecentDay))
        XCTAssertEqual(ProjectsListContent.activity(lastActive: firstQuietDay, now: now, calendar: calendar),
                       .quiet(since: firstQuietDay))
        XCTAssertEqual(ProjectsListContent.activity(lastActive: nil, now: now, calendar: calendar), .nothingLinked)
        // Days are calendar days: late yesterday is yesterday, not "today".
        let lateYesterday = calendar.startOfDay(for: now).addingTimeInterval(-60)
        XCTAssertEqual(ProjectsListContent.activity(lastActive: lateYesterday, now: now, calendar: calendar),
                       .yesterday)
        XCTAssertEqual(ProjectsListContent.activity(lastActive: now.addingTimeInterval(3_600), now: now,
                                                    calendar: calendar), .today)
    }

    func testRowCountsTheUsersOpenActionsOnly() throws {
        let sync = Meeting(id: UUID(), title: "Orion sync", appName: "Meet", startedAt: daysAgo(1),
                           endedAt: daysAgo(1).addingTimeInterval(1_800), relativePath: "meetings/\(UUID().uuidString)")
        let outcomes = MeetingOutcomes(actionItems: [
            .init(text: "Draft the synthetic Orion policy", owner: "Me"),
            .init(text: "Send the synthetic Orion plan", owner: "Me"),
            .init(text: "Benchmark the synthetic Orion failover", owner: "Mila"),
        ])
        var curation = ProjectCuration()
        curation.tracked = [.init(id: UUID(), name: "Orion", otherNames: [], createdAt: now)]
        let projects = ProjectLinks.build(.init(
            curation: curation, meetings: [sync],
            projections: [.init(meeting: sync, outcomes: outcomes, state: MeetingOutcomeState(),
                                followUp: FollowUpDraft.seeded(for: sync, outcomes: outcomes))]),
            now: now, calendar: calendar)
        let orion = try XCTUnwrap(projects.first)
        XCTAssertEqual(orion.myActions.count, 2)
        XCTAssertEqual(orion.othersActions.count, 1)
        XCTAssertEqual(build(projects).tracked.first?.openActions, 2)
        XCTAssertEqual(ProjectsWording.openActions(2), "2 open actions for you")
        XCTAssertEqual(ProjectsWording.openActions(1), "1 open action for you")
        XCTAssertFalse(ProjectPagePresentation.isEmpty(orion))
        XCTAssertEqual(ProjectPagePresentation.othersActions(orion).map(\.text),
                       ["Benchmark the synthetic Orion failover"])
    }

    func testSuggestionsSayWhereTheyCameFromAndKeepTheirOrder() {
        let content = build([
            profile("Atlas", lastActive: now),
            profile("Redis", kind: .suggestedTopic, meetings: meetings(4), lastActive: now),
            profile("Vireo", kind: .suggestedTopic, meetings: meetings(1), lastActive: daysAgo(30)),
            profile("Index rebuild", kind: .suggestedReview,
                    reviewNotes: [.init(name: "Index rebuild", status: "Blocked.", lastActiveDay: "2026-11-09")]),
        ])
        XCTAssertEqual(content.tracked.map(\.name), ["Atlas"])
        XCTAssertEqual(content.suggested.map(\.name), ["Redis", "Vireo", "Index rebuild"])
        XCTAssertEqual(content.suggested.map(\.detail), ["In 4 meetings", "In 1 meeting", "From overnight review"])
        XCTAssertTrue(content.suggested.allSatisfy { $0.isSuggestion && !$0.isQuiet && $0.openActions == 0 })
        XCTAssertEqual(content.projectIDs.count, 4)
        XCTAssertEqual(content.projectIDs.first, content.tracked.first?.id, "tracked projects come first")
    }

    func testSearchMatchesANameOrAnotherName() {
        let projects = [
            profile("Atlas", otherNames: ["Larkspur"]),
            profile("Borealis"),
            profile("Redis", kind: .suggestedTopic, meetings: meetings(3)),
        ]
        XCTAssertEqual(build(projects, query: " lark ").projectIDs, [projects[0].id])
        XCTAssertEqual(build(projects, query: "RED").suggested.map(\.name), ["Redis"])
        XCTAssertTrue(build(projects, query: "nothing like it").isEmpty)
        XCTAssertEqual(build(projects, query: "  ").projectIDs.count, 3)
    }

    func testHidingASuggestionOpensTheNextOne() {
        let content = build([
            profile("Atlas"),
            profile("Redis", kind: .suggestedTopic, meetings: meetings(4)),
            profile("Vireo", kind: .suggestedTopic, meetings: meetings(3)),
            profile("Index rebuild", kind: .suggestedReview),
        ])
        XCTAssertEqual(content.selection(afterRemoving: "topic:redis"), "topic:vireo")
        XCTAssertEqual(content.selection(afterRemoving: "review:index rebuild"), "topic:redis",
                       "after the last suggestion the first one left opens")
        let single = build([profile("Atlas"), profile("Redis", kind: .suggestedTopic, meetings: meetings(4))])
        XCTAssertNil(single.selection(afterRemoving: "topic:redis"),
                     "with no suggestion left the page falls back to the first tracked project")
    }

    func testAJustTrackedSuggestionIsListedAsTrackedAtOnce() throws {
        let trackedID = UUID()
        let selection = ProjectsWorkspaceView.trackedSelectionID(trackedID)
        var curation = ProjectCuration()
        curation.tracked = [.init(id: trackedID, name: "Redis", otherNames: [], createdAt: now)]
        let atlas = profile("Atlas")
        let suggestions = [
            profile("Redis", kind: .suggestedTopic, meetings: meetings(4), lastActive: now),
            profile("Vireo", kind: .suggestedTopic, meetings: meetings(3)),
        ]
        let settling = try XCTUnwrap(ProjectsWorkspaceView.settlingProfile(
            selection: selection, curation: curation, projects: [atlas] + suggestions))
        let listed = ProjectsWorkspaceView.listProjects([atlas] + suggestions, settling: settling)
        let content = build(listed)
        XCTAssertEqual(content.tracked.map(\.name), ["Redis", "Atlas"])
        XCTAssertEqual(content.tracked.first?.id, selection, "the row is the one the page has selected")
        XCTAssertEqual(content.suggested.map(\.name), ["Vireo"], "and it has left Suggested")
        XCTAssertEqual(ProjectsWorkspaceView.listProjects([atlas] + suggestions, settling: nil), [atlas] + suggestions)
    }

    // MARK: - A suggestion's first answer

    func testASuggestionBelongsWhereAtLeastHalfOfItsMeetingsAre() {
        let ids = (0..<6).map { _ in UUID() }
        let suggestion = Set(ids[0..<4])
        XCTAssertEqual(ProjectSuggestionHome.sharedMeetings(suggestion: suggestion, project: Set(ids[1..<6])), 3)
        XCTAssertEqual(ProjectSuggestionHome.sharedMeetings(suggestion: suggestion, project: Set(ids[2..<6])), 2,
                       "exactly half is enough")
        XCTAssertNil(ProjectSuggestionHome.sharedMeetings(suggestion: suggestion, project: Set(ids[3..<6])))
        XCTAssertNil(ProjectSuggestionHome.sharedMeetings(suggestion: suggestion, project: []))
        XCTAssertNil(ProjectSuggestionHome.sharedMeetings(suggestion: [], project: Set(ids)),
                     "a suggestion no meeting names belongs nowhere")
        XCTAssertEqual(ProjectSuggestionHome.sharedMeetings(suggestion: [ids[0]], project: [ids[0]]), 1)
    }

    func testTheProjectSharingTheMostMeetingsIsOffered() throws {
        let shared = meetings(4)
        let atlasID = UUID(), borealisID = UUID()
        let atlas = profile("Atlas", kind: .tracked(atlasID), meetings: Array(shared[0..<3]))
        let borealis = profile("Borealis", kind: .tracked(borealisID), meetings: Array(shared[0..<2]))
        let redis = profile("Redis", kind: .suggestedTopic, meetings: shared)
        let other = profile("Vireo", kind: .suggestedTopic, meetings: shared)

        let match = try XCTUnwrap(ProjectSuggestionHome.match(for: redis, among: [borealis, atlas, other, redis]))
        XCTAssertEqual(match, .init(trackedID: atlasID, name: "Atlas", sharedMeetings: 3))
        XCTAssertEqual(ProjectSuggestionHome.match(for: redis, among: [borealis, other])?.trackedID, borealisID,
                       "another suggestion is never the answer")
        let tie = profile("Cinder", kind: .tracked(UUID()), meetings: Array(shared[0..<2]))
        XCTAssertEqual(ProjectSuggestionHome.match(for: redis, among: [borealis, tie])?.name, "Borealis",
                       "the first listed wins a tie")
        XCTAssertNil(ProjectSuggestionHome.match(for: redis, among: [profile("Dune", meetings: [shared[0]])]),
                     "one of four meetings is not enough")
        XCTAssertNil(ProjectSuggestionHome.match(for: atlas, among: [borealis]), "tracked projects are not asked")
        XCTAssertNil(ProjectSuggestionHome.match(
            for: profile("Index rebuild", kind: .suggestedReview), among: [atlas, borealis]))
    }

    func testSuggestionWordingNamesTheMeetingsAndTheReason() {
        let redis = profile("Redis", kind: .suggestedTopic, meetings: meetings(4, newestDaysAgo: 0))
        XCTAssertEqual(
            ProjectsWording.suggestionTitle(for: redis, now: now, calendar: calendar, locale: locale),
            "Redis came up in 4 meetings since Nov 7")
        let once = profile("Vireo", kind: .suggestedTopic, meetings: meetings(1, newestDaysAgo: 12))
        XCTAssertEqual(
            ProjectsWording.suggestionTitle(for: once, now: now, calendar: calendar, locale: locale),
            "Vireo came up in 1 meeting since Oct 29")
        let review = profile("Index rebuild", kind: .suggestedReview)
        XCTAssertEqual(ProjectsWording.suggestionTitle(for: review, now: now, calendar: calendar, locale: locale),
                       "The overnight review found work on Index rebuild")
        XCTAssertEqual(
            ProjectsWording.suggestionReason(home: .init(trackedID: UUID(), name: "Atlas", sharedMeetings: 3)),
            "3 of its meetings are already linked to Atlas, so it may be part of that project rather than a project of its own.")
        XCTAssertEqual(
            ProjectsWording.suggestionReason(home: .init(trackedID: UUID(), name: "Atlas", sharedMeetings: 1)),
            "1 of its meetings is already linked to Atlas, so it may be part of that project rather than a project of its own.")
        XCTAssertEqual(ProjectsWording.suggestionReason(home: nil), "No tracked project covers it.")
        XCTAssertEqual(
            ProjectsWording.reviewCitation(dayKey: "2026-11-09", now: now, calendar: calendar, locale: locale),
            "Overnight review · Nov 9")
        XCTAssertEqual(ProjectsWording.reviewCitation(dayKey: "soon", now: now, calendar: calendar, locale: locale),
                       "Overnight review")
    }

    // MARK: - Time

    func testTheLastSevenDaysShowDaysWithoutTimeAsZero() {
        let days = ProjectTimePresentation.days(
            [.init(dayKey: "2026-11-10", seconds: 3_000), .init(dayKey: "2026-11-08", seconds: 600),
             .init(dayKey: "2026-10-01", seconds: 9_000)],
            now: now, calendar: calendar)
        XCTAssertEqual(days.count, ProjectLinks.reviewDays)
        XCTAssertEqual(days.map(\.dayKey), [
            "2026-11-04", "2026-11-05", "2026-11-06", "2026-11-07", "2026-11-08", "2026-11-09", "2026-11-10",
        ])
        XCTAssertEqual(days.map(\.seconds), [0, 0, 0, 0, 600, 0, 3_000],
                       "a day outside the measured week is not drawn")
        XCTAssertEqual(days.map(\.isToday), [false, false, false, false, false, false, true])
        XCTAssertEqual(ProjectTimePresentation.fraction(days[6], in: days), 1)
        XCTAssertEqual(ProjectTimePresentation.fraction(days[4], in: days), 0.2, accuracy: 0.001)
        XCTAssertEqual(ProjectTimePresentation.fraction(days[0], in: days), 0)
        let empty = ProjectTimePresentation.days([], now: now, calendar: calendar)
        XCTAssertEqual(empty.count, 7)
        XCTAssertEqual(ProjectTimePresentation.fraction(empty[0], in: empty), 0)
        XCTAssertEqual(ProjectsWording.weekdayLetter(days[0].date, calendar: calendar, locale: locale), "W")
        XCTAssertEqual(ProjectsWording.dayTime(days[4], calendar: calendar, locale: locale), "Sun, Nov 8: 10m")
        XCTAssertEqual(ProjectsWording.dayTime(days[0], calendar: calendar, locale: locale), "Wed, Nov 4: 0m")
    }

    func testTheDayKeysAreTheOnesProjectLinksWrites() throws {
        var curation = ProjectCuration()
        curation.tracked = [.init(id: UUID(), name: "Orion", otherNames: [], createdAt: now)]
        let activity = [
            ActivityBlock(id: 1, app: "Keynote", title: "Orion deck.key",
                          start: now.addingTimeInterval(-3_600), end: now.addingTimeInterval(-1_800)),
            ActivityBlock(id: 2, app: "Safari", title: "Orion roadmap",
                          start: daysAgo(2), end: daysAgo(2).addingTimeInterval(600)),
        ]
        let orion = try XCTUnwrap(ProjectLinks.build(
            .init(curation: curation, meetings: [], activity: activity), now: now, calendar: calendar).first)
        let days = ProjectTimePresentation.days(orion.days, now: now, calendar: calendar)
        XCTAssertEqual(days.map(\.seconds), [0, 0, 0, 0, 600, 0, 1_800])
        XCTAssertEqual(days.reduce(0) { $0 + $1.seconds }, orion.trackedSeconds, "the bars add up to the total")
        XCTAssertEqual(orion.windowCount, 2)
    }

    func testWindowsBeyondTheFirstThreeAreSummedInOneLine() {
        let windows: [ProjectProfile.WindowTime] = [
            .init(app: "Xcode", title: "atlas-cache", seconds: 58_800),
            .init(app: "Safari", title: "Atlas design doc", seconds: 32_700),
            .init(app: "Terminal", title: "atlas-staging", seconds: 24_000),
            .init(app: "Notes", title: "Atlas notes", seconds: 12_000),
        ]
        let atlas = profile("Atlas", days: [.init(dayKey: "2026-11-10", seconds: 144_600)],
                            windows: windows, windowCount: 6)
        let rest = ProjectTimePresentation.rest(of: atlas)
        XCTAssertEqual(rest?.count, 3, "every window is counted, not only the listed ones")
        XCTAssertEqual(rest?.seconds ?? 0, 29_100, accuracy: 0.5)
        XCTAssertEqual(ProjectsWording.moreWindows(3), "3 more windows")
        XCTAssertEqual(ProjectsWording.moreWindows(1), "1 more window")
        let few = profile("Borealis", days: [.init(dayKey: "2026-11-10", seconds: 115_500)],
                          windows: Array(windows.prefix(3)), windowCount: 3)
        XCTAssertNil(ProjectTimePresentation.rest(of: few))
        // A profile built without the count still sums what it lists.
        let uncounted = profile("Cinder", days: [.init(dayKey: "2026-11-10", seconds: 127_500)], windows: windows)
        XCTAssertEqual(ProjectTimePresentation.rest(of: uncounted)?.count, 1)
    }

    func testDurationsReadAsHoursAndMinutes() {
        XCTAssertEqual(ProjectsWording.duration(144_600, locale: locale), "40h 10m")
        XCTAssertEqual(ProjectsWording.duration(2_100, locale: locale), "35m")
        XCTAssertEqual(ProjectsWording.duration(7_200, locale: locale), "2h")
        XCTAssertEqual(ProjectsWording.duration(20, locale: locale), "1m", "under a minute still reads as one")
        let atlas = profile("Atlas", otherNames: ["Larkspur"])
        XCTAssertEqual(ProjectsWording.timeSource(for: atlas), "Time in windows whose titles name Atlas, Larkspur")
    }

    // MARK: - Where it stands

    private func summary(writtenAt: Date, engine: String = "Qwen3.5 4B",
                         location: String = ProjectStatusSummary.localLocation) -> ProjectStatusSummary {
        ProjectStatusSummary(projectID: UUID(), overview: "Synthetic overview.", points: [], openQuestions: [],
                             meetingIDs: [], evidenceFingerprint: "x", generatedAt: writtenAt, engineName: engine,
                             location: location)
    }

    func testProvenanceSaysWhenWhichModelAndWhere() {
        let style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
        let morning = calendar.startOfDay(for: now).addingTimeInterval(9 * 3_600 + 12 * 60)
        let time = morning.formatted(style.hour().minute())
        XCTAssertTrue(time.hasPrefix("9:12"))
        XCTAssertEqual(
            ProjectsWording.provenance(summary(writtenAt: morning), now: now, calendar: calendar, locale: locale),
            "Written today, \(time), by Qwen3.5 4B on this Mac")
        XCTAssertEqual(
            ProjectsWording.provenance(summary(writtenAt: daysAgo(18)), now: now, calendar: calendar, locale: locale),
            "Written Oct 23 by Qwen3.5 4B on this Mac")
        // A model that ran elsewhere is named with its server, never as local.
        let remote = summary(writtenAt: morning, engine: "Muse Spark 1.1", location: "api.example.com")
        XCTAssertEqual(ProjectsWording.provenance(remote, now: now, calendar: calendar, locale: locale),
                       "Written today, \(time), by Muse Spark 1.1 on api.example.com")
        let olderRemote = summary(writtenAt: daysAgo(18), engine: "Muse Spark 1.1", location: "api.example.com")
        XCTAssertEqual(ProjectsWording.provenance(olderRemote, now: now, calendar: calendar, locale: locale),
                       "Written Oct 23 by Muse Spark 1.1 on api.example.com")
    }

    func testWritingLineNamesWhatTheModelIsGiven() {
        XCTAssertEqual(ProjectsWording.writing(meetings: 4, hasReviewNotes: false),
                       "Writing where it stands from 4 meetings…")
        XCTAssertEqual(ProjectsWording.writing(meetings: 1, hasReviewNotes: false),
                       "Writing where it stands from 1 meeting…")
        XCTAssertEqual(ProjectsWording.writing(meetings: 1, hasReviewNotes: true),
                       "Writing where it stands from 1 meeting and the overnight review…")
        XCTAssertEqual(ProjectsWording.writing(meetings: 3, hasReviewNotes: true),
                       "Writing where it stands from 3 meetings and the overnight review…")
        XCTAssertEqual(ProjectsWording.writing(meetings: 0, hasReviewNotes: true),
                       "Writing where it stands from the overnight review…")
    }

    func testACitedPointLinksToItsMeeting() throws {
        let meetingID = UUID()
        let url = try XCTUnwrap(ProjectNoteLink.url(meetingID: meetingID))
        XCTAssertEqual(ProjectNoteLink.meetingID(from: url), meetingID)
        XCTAssertNil(ProjectNoteLink.meetingID(from: try XCTUnwrap(URL(string: "https://example.com/meeting/x"))))
        XCTAssertNil(ProjectNoteLink.meetingID(
            from: try XCTUnwrap(URL(string: ProjectNoteLink.scheme + "://meeting/not-an-id"))))
    }

    // MARK: - Page

    func testToolbarSubtitleSaysActivityOrSinceWhenItIsTracked() {
        let active = profile("Atlas", lastActive: now)
        XCTAssertEqual(ProjectsWording.subtitle(for: active, trackedSince: daysAgo(40), now: now,
                                                calendar: calendar, locale: locale), "Active today")
        let quiet = profile("Borealis", lastActive: daysAgo(19))
        XCTAssertEqual(ProjectsWording.subtitle(for: quiet, trackedSince: daysAgo(40), now: now,
                                                calendar: calendar, locale: locale), "Quiet since Oct 22")
        let unlinked = profile("Cinder")
        XCTAssertEqual(ProjectsWording.subtitle(for: unlinked, trackedSince: daysAgo(9), now: now,
                                                calendar: calendar, locale: locale), "Tracked since Nov 1")
        XCTAssertEqual(ProjectsWording.subtitle(for: unlinked, trackedSince: nil, now: now,
                                                calendar: calendar, locale: locale), "Nothing linked yet")
        let suggestion = profile("Redis", kind: .suggestedTopic, meetings: meetings(4))
        XCTAssertEqual(ProjectsWording.subtitle(for: suggestion, trackedSince: nil, now: now, calendar: calendar,
                                                locale: locale, localize: AppLanguage.english.catalog),
                       "Suggested", "one project's word has its own catalog key")
        XCTAssertEqual(ProjectsWording.showHidden(2), "Show 2 hidden suggestions")
        XCTAssertEqual(ProjectsWording.showHidden(1), "Show 1 hidden suggestion")
    }

    func testAProjectIsEmptyOnlyWhenNothingNamesIt() {
        XCTAssertTrue(ProjectPagePresentation.isEmpty(profile("Cinder")))
        XCTAssertTrue(ProjectPagePresentation.isEmpty(
            profile("Cinder", days: [.init(dayKey: "2026-11-10", seconds: 40)])),
            "window time under a minute is not shown, so it does not fill the page")
        XCTAssertFalse(ProjectPagePresentation.isEmpty(profile("Atlas", meetings: meetings(1))))
        XCTAssertFalse(ProjectPagePresentation.isEmpty(
            profile("Atlas", days: [.init(dayKey: "2026-11-10", seconds: 600)])))
        XCTAssertFalse(ProjectPagePresentation.isEmpty(profile("Atlas", people: ["Mila Novak"])))
        XCTAssertFalse(ProjectPagePresentation.isEmpty(profile(
            "Atlas", reviewNotes: [.init(name: "Atlas", status: "Moving.", lastActiveDay: "2026-11-09")])))
    }
}
