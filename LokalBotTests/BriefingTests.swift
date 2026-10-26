import XCTest
@testable import LokalBot

/// `get_briefing` / `lokalbot-cli brief`: every section appears only under
/// the permission that already covers its data, inside the screen window.
@MainActor
final class BriefingTests: XCTestCase {
    private var root: URL!
    private var calendar: Calendar!
    private var now: Date!
    private var reader: BriefingStubReader!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BriefingTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        now = try date("2026-10-15T12:00:00Z")
        let pullRequest = "https://github.com/example/lokalbot/pull/251"
        reader = BriefingStubReader(sessions: [
            .init(agent: "Claude Code", project: "LokalBot", title: "<wake reason=\"mention\">",
                  start: try date("2026-10-14T16:00:00Z"), sessionID: "c", pullRequests: [], actionCount: 0),
            .init(agent: "Claude Code", project: "LokalBot", title: "Add the agent briefing",
                  start: try date("2026-10-14T15:00:00Z"), sessionID: "a", pullRequests: [pullRequest],
                  actionCount: 2),
            // Two bursts of one session, naming the same pull request.
            .init(agent: "Claude Code", project: "LokalBot", title: "Fix the stdio read",
                  start: try date("2026-10-13T09:00:00Z"), sessionID: "b", pullRequests: [pullRequest],
                  actionCount: 0),
            .init(agent: "Claude Code", project: "LokalBot", title: "Fix the stdio read",
                  start: try date("2026-10-13T08:00:00Z"), sessionID: "b", pullRequests: [], actionCount: 0),
            .init(agent: "Codex", project: "website", title: "Update the privacy page",
                  start: try date("2026-10-15T08:00:00Z"), sessionID: "d", pullRequests: [], actionCount: 1),
        ])
        try seedLibrary()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Gating

    func testWithNoGrantsItListsOnlyWhichPermissionsAreOff() throws {
        let text = render()
        XCTAssertTrue(text.contains("Meetings: off"), text)
        XCTAssertTrue(text.contains("Screen memory: off"), text)
        XCTAssertTrue(text.contains("Personal Context: off"), text)
        for hidden in ["Cache planning", "caching memo", "Meeting project", "Screen project", "Digest goal",
                       "Unattributed project", "Merged the MCP stdio fix", "agent briefing", "Shipped phase two",
                       "staff engineer", "recorded"] {
            XCTAssertFalse(text.contains(hidden), "\(hidden) leaked:\n\(text)")
        }
        XCTAssertTrue(text.contains("unknown, not false"), text)
    }

    func testMeetingAccessAloneShowsMeetingsActionsAndMeetingOnlyWork() throws {
        try AgentAccessGate(root: root).enable()
        let text = render()
        XCTAssertTrue(text.contains("Meetings: on. 1 recorded, newest \"Cache planning\""), text)
        // The due date resolves in the Mac's own time zone, so check only that it is shown.
        XCTAssertTrue(text.contains("Draft the synthetic caching memo (due 2026-10-"), text)
        XCTAssertFalse(text.contains("Benchmark the synthetic cluster"), "someone else's item:\n\(text)")
        XCTAssertTrue(text.contains("Meeting project: waiting on review"), text)
        // Screen and digest evidence need the screen grant; unattributed items never show.
        XCTAssertFalse(text.contains("Screen project"), text)
        XCTAssertFalse(text.contains("Digest goal"), text)
        XCTAssertFalse(text.contains("Unattributed project"), text)
        XCTAssertFalse(text.contains("agent briefing"), text)
        XCTAssertFalse(text.contains("Merged the MCP stdio fix"), text)
        XCTAssertFalse(text.contains("staff engineer"), text)
    }

    func testAllGrantsShowEverySectionAtDecreasingDetail() throws {
        try enableAll(scope: .retainedHistory)
        let text = render()
        XCTAssertTrue(text.contains("[fact, stated] I'm open to remote staff engineer roles"), text)
        XCTAssertTrue(text.contains("Screen project: prototyping"), text)
        XCTAssertTrue(text.contains("Goal: Ship the digest rewrite (this month)"), text)
        XCTAssertFalse(text.contains("Unattributed project"), text)
        XCTAssertTrue(text.contains(
            "LokalBot (Claude Code, 3 sessions, latest Wed Oct 14): Add the agent briefing · 1 pull request"), text)
        XCTAssertFalse(text.contains("<wake"), text)
        XCTAssertTrue(text.contains("website (Codex, 1 session, latest Thu Oct 15): Update the privacy page"), text)

        // Two sentences for yesterday, one for older days, then weeks, then months.
        XCTAssertTrue(text.contains("Wed Oct 14: Merged the MCP stdio fix. Reviewed the briefing design."), text)
        XCTAssertFalse(text.contains("Third sentence"), text)
        XCTAssertTrue(text.contains("Sat Oct 10: Planned the rollup prompt."), text)
        XCTAssertFalse(text.contains("Second sentence"), text)
        XCTAssertTrue(text.contains("Week of Sep 28: Shipped phase two of the personal model."), text)
        XCTAssertTrue(text.contains("August 2026: Built the autocomplete launch film."), text)
        // A line whose reviews changed is stale; a month the shown weeks cover is skipped.
        XCTAssertFalse(text.contains("STALE LINE"), text)
        XCTAssertFalse(text.contains("September line"), text)
        let days = try XCTUnwrap(text.range(of: "Wed Oct 14"))
        let weeks = try XCTUnwrap(text.range(of: "Week of Sep 28"))
        let months = try XCTUnwrap(text.range(of: "August 2026"))
        XCTAssertTrue(days.lowerBound < weeks.lowerBound && weeks.lowerBound < months.lowerBound)
        XCTAssertLessThanOrEqual(text.count, Briefing.maximumCharacters)
    }

    func testTodayOnlyScreenWindowClampsTimelineAgentsAndScreenWork() throws {
        try enableAll(scope: .today)
        try saveReview("2026-10-15", "Today review sentence.")
        let text = render()
        XCTAssertTrue(text.contains("Thu Oct 15: Today review sentence."), text)
        XCTAssertFalse(text.contains("Merged the MCP stdio fix"), text)
        XCTAssertFalse(text.contains("Week of"), text)
        XCTAssertEqual(reader.requestedStart, calendar.startOfDay(for: now))
        // Screen evidence last seen yesterday is outside the window; meeting-only work is not.
        XCTAssertFalse(text.contains("Screen project"), text)
        XCTAssertTrue(text.contains("Meeting project"), text)
    }

    func testPendingRevocationWithholdsWorkMemoryAndTimeline() throws {
        try enableAll(scope: .retainedHistory)
        try Data("[]".utf8).write(to: root.appendingPathComponent(".dream-revocation-pending.json"))
        let text = render()
        XCTAssertTrue(text.contains("still removing deleted material"), text)
        XCTAssertFalse(text.contains("Meeting project"), text)
        XCTAssertFalse(text.contains("Merged the MCP stdio fix"), text)
        XCTAssertFalse(text.contains("Shipped phase two"), text)
        XCTAssertTrue(text.contains("Draft the synthetic caching memo"), text)
    }

    /// `lokalbot-cli brief` runs in a shell, so it names commands, not MCP
    /// tools; everything else matches `get_briefing`.
    func testBriefNamesCLICommandsWhereGetBriefingNamesTools() throws {
        try enableAll(scope: .retainedHistory)
        let tools = render()
        let commands = render(vocabulary: .cli)
        XCTAssertTrue(commands.contains(
            ". Commands: search, get, list, actions, people, and ask while the app runs."), commands)
        XCTAssertTrue(commands.contains(
            "- Screen memory: on, all retained history. No lokalbot-cli command searches it."), commands)
        XCTAssertTrue(commands.contains("1 shared item. Command: personal-context."), commands)
        XCTAssertTrue(commands.contains("For more, run lokalbot-cli: search and get for what was said, "
            + "list --include summary for several meetings' summaries at once,"), commands)
        for tool in ["search_meetings", "get_meeting", "list_meetings", "get_action_items", "get_person",
                     "ask_library", "search_screen", "get_timeline", "get_personal_context"] {
            XCTAssertFalse(commands.contains(tool), "\(tool) in:\n\(commands)")
        }
        XCTAssertTrue(tools.contains(". Tools: search_meetings, get_meeting, list_meetings,"), tools)
        XCTAssertTrue(tools.contains("list_meetings with include \"summary\" for several meetings' summaries"), tools)

        let toolLines = tools.components(separatedBy: "\n")
        let commandLines = commands.components(separatedBy: "\n")
        XCTAssertEqual(toolLines.count, commandLines.count)
        let differing = zip(commandLines, toolLines).filter { $0 != $1 }.map { String($0.0.prefix(16)) }
        XCTAssertEqual(differing, ["- Meetings: on. ", "- Screen memory:", "- Personal Conte", "For more, run lo"])
    }

    func testProviderAdvertisesBriefingFirstAndAnswersWithoutGrants() async throws {
        let fixed: Date = now
        let provider = FileLibraryToolProvider(
            gate: AgentAccessGate(root: root), screenReader: reader, now: { fixed }
        ) { _ in .text("") }
        XCTAssertEqual(provider.tools.first?.name, "get_briefing")
        let result = await provider.call(name: "get_briefing", arguments: nil)
        XCTAssertFalse(result.isError, result.text)
        XCTAssertTrue(result.text.contains("Meetings: off"), result.text)
        XCTAssertTrue(result.text.contains("For more: search_meetings"), result.text)
        XCTAssertTrue(provider.briefing(vocabulary: .cli).contains("For more, run lokalbot-cli:"))
    }

    func testSQLiteReaderReadsCodingAgentSessionsInTheWindow() throws {
        let url = root.appendingPathComponent("lokalbotv3.sqlite")
        let store = ActivityStore(databaseURL: url)
        func burst(_ session: String, _ start: String, project: String,
                   prompts: [String] = ["Do it"]) throws -> CodingAgentBurst {
            let startDate = try date(start)
            return CodingAgentBurst(
                agent: .claudeCode, sessionID: session, title: "Session \(session)", project: project,
                branch: nil, start: startDate, end: startDate.addingTimeInterval(600), activeDuration: 600,
                prompts: prompts, promptCount: prompts.count, finalReply: nil, changedFiles: [], changedFileCount: 0,
                actions: [], pullRequests: ["https://github.com/example/repo/pull/1"], toolCallCount: 1)
        }
        try store.upsertCodingAgentBursts([
            try burst("old", "2026-10-01T09:00:00Z", project: "Old"),
            try burst("new", "2026-10-14T09:00:00Z", project: "LokalBot"),
            try burst("cron", "2026-10-14T06:00:00Z", project: "LokalBot",
                      prompts: ["Scheduled task: summarize yesterday"]),
        ])
        let sessions = try SQLiteScreenMemoryReader(databaseURL: url).agentSessions(
            from: try date("2026-10-08T12:00:00Z"), to: now, limit: 10)
        XCTAssertEqual(sessions, [ScreenMemoryAgentSession(
            agent: "Claude Code", project: "LokalBot", title: "Session new",
            start: try date("2026-10-14T09:00:00Z"), sessionID: "new",
            pullRequests: ["https://github.com/example/repo/pull/1"], actionCount: 0)])
    }

    // MARK: - Fixtures

    private func render(vocabulary: Briefing.Vocabulary = .mcp) -> String {
        Briefing.render(Briefing.Context(
            root: root,
            meetingAccess: AgentAccessGate(root: root).isAuthorized(environment: [:], now: now),
            screenGate: ScreenMemoryAccessGate(root: root),
            personalGate: PersonalContextAccessGate(root: root),
            screenReader: reader, now: now, calendar: calendar, vocabulary: vocabulary))
    }

    private func enableAll(scope: ScreenMemoryAccessProfile.Scope) throws {
        try AgentAccessGate(root: root).enable()
        try ScreenMemoryAccessGate(root: root).enable(profile: ScreenMemoryAccessProfile(scope: scope))
        try PersonalContextAccessGate(root: root).enable()
    }

    private func seedLibrary() throws {
        try MeetingFixture.write([
            .init(title: "Cache planning", startedAt: try date("2026-10-13T10:00:00Z"),
                  summary: "## TL;DR\nWe chose Redis.", transcriptLines: ["Redis it is."]),
        ], under: root)
        let meeting = try XCTUnwrap(try SessionLookup.loadAllMeetings(root: root).first)
        let folder = root.appendingPathComponent(meeting.relativePath, isDirectory: true)
        try MeetingOutcomes(actionItems: [
            .init(text: "Draft the synthetic caching memo", owner: "Me", due: "2026-10-20"),
            .init(text: "Benchmark the synthetic cluster", owner: "Ana"),
        ]).write(to: folder)

        func provenance(_ kinds: DreamEvidenceSource.Kind...) -> DreamEvidenceProvenance {
            DreamEvidenceProvenance(
                sources: kinds.map { DreamEvidenceSource(kind: $0, id: "2026-10-14", dayKey: "2026-10-14") },
                revision: 0)
        }
        try DreamStore(root: root).save(DreamMemory(
            updatedAt: now,
            activeProjects: [
                .init(name: "Meeting project", status: "waiting on review", lastActiveDay: "2026-10-14",
                      provenance: provenance(.meeting)),
                .init(name: "Screen project", status: "prototyping", lastActiveDay: "2026-10-14",
                      provenance: provenance(.screenDay)),
                .init(name: "Unattributed project", status: "legacy", lastActiveDay: "2026-10-14"),
            ],
            workGoals: [
                .init(text: "Ship the digest rewrite", horizon: "this month", lastReinforcedDay: "2026-10-14",
                      provenance: provenance(.meeting, .digest)),
                .init(text: "Digest goal", horizon: "Q4", lastReinforcedDay: "2026-10-14",
                      provenance: provenance(.digest)),
            ]))

        try saveReview("2026-10-14", "Merged the MCP stdio fix. Reviewed the briefing design. Third sentence hidden.")
        try saveReview("2026-10-10", "Planned the rollup prompt. Second sentence hidden.")
        try saveReview("2026-09-29", "Week forty work.")
        try saveReview("2026-09-22", "Week thirty-nine work.")
        try saveReview("2026-08-12", "August work.")
        let reviews = DreamRollupFormat.reviews(root: root)
        func rollup(_ period: DreamRollupFormat.Period, _ line: String, stamp: String? = nil) throws {
            try DreamRollupService.write(DreamRollupFormat.Rollup(
                kind: period.kind, key: period.key, firstDay: period.firstDay, lastDay: period.lastDay, line: line,
                stamp: stamp ?? DreamRollupFormat.stamp(of: DreamRollupFormat.reviews(in: period, from: reviews)),
                generatedAt: now), root: root)
        }
        try rollup(DreamRollupFormat.week(containing: try date("2026-09-29T12:00:00Z"), calendar: calendar),
                   "Shipped phase two of the personal model.")
        try rollup(DreamRollupFormat.week(containing: try date("2026-09-22T12:00:00Z"), calendar: calendar),
                   "STALE LINE", stamp: "stale")
        try rollup(DreamRollupFormat.month(containing: try date("2026-09-15T12:00:00Z"), calendar: calendar),
                   "September line")
        try rollup(DreamRollupFormat.month(containing: try date("2026-08-12T12:00:00Z"), calendar: calendar),
                   "Built the autocomplete launch film.")

        let personal = PersonalContextAccessGate(root: root)
        try personal.enable()
        let claim = PersonalContextProjection.Claim(
            id: UUID(), kind: .fact, text: "I'm open to remote staff engineer roles", alwaysUse: false,
            source: .askedToRemember, createdAt: now, updatedAt: now)
        try personal.writeProjection(PersonalContextProjection(generatedAt: now, claims: [claim]))
        try FileManager.default.removeItem(at: personal.accessMarkerURL)
    }

    private func saveReview(_ day: String, _ narrative: String) throws {
        try DreamStore(root: root).save(DreamReport(
            day: day, generatedAt: try date("\(day)T23:00:00Z"), engineName: "test", narrative: narrative))
    }

    private func date(_ value: String) throws -> Date {
        try XCTUnwrap(ISO8601DateFormatter().date(from: value), value)
    }
}

/// Nightly week and month lines: which periods are due, stamps, staleness.
final class DreamRollupServiceTests: XCTestCase {
    private var root: URL!
    private var calendar: Calendar!
    private var now: Date!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DreamRollupServiceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-15T03:00:00Z"))
        try save("2026-10-14", "This week, not finished.")
        try save("2026-10-06", "Started the briefing work.")
        try save("2026-09-15", "Shipped the September release.")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testDuePeriodsAreFinishedWeeksAndMonthsWithReviewsNewestFirst() {
        let due = DreamRollupService.due(
            reviews: DreamRollupFormat.reviews(root: root), rollups: [], now: now, calendar: calendar)
        XCTAssertEqual(due.map(\.key), ["2026-W41", "2026-09", "2026-W38"])
    }

    func testRunWritesStampedLinesOnceAndOnlyMakesAnEngineWhenSomethingIsDue() async throws {
        let engine = RollupStubEngine("Summary: \"Started the briefing work and shipped a release.\"\nIgnored line")
        var made = 0
        let first = try await DreamRollupService.run(root: root, now: now, calendar: calendar) {
            made += 1
            return engine
        }
        XCTAssertEqual(first.written.map(\.key), ["2026-W41", "2026-09", "2026-W38"])
        XCTAssertEqual(first.written.first?.line, "Started the briefing work and shipped a release.")
        let reviews = DreamRollupFormat.reviews(root: root)
        XCTAssertTrue(DreamRollupFormat.rollups(root: root).allSatisfy { DreamRollupFormat.isValid($0, reviews: reviews) })
        XCTAssertTrue(engine.prompts[0].contains("Started the briefing work."))
        XCTAssertFalse(engine.prompts[0].contains("September release"))

        let second = try await DreamRollupService.run(root: root, now: now, calendar: calendar) {
            made += 1
            return engine
        }
        XCTAssertEqual(second, DreamRollupService.Outcome())
        XCTAssertEqual(made, 1)
    }

    func testRegeneratedReviewMakesItsLinesStaleAndTheyAreRebuilt() async throws {
        let engine = RollupStubEngine("A line.")
        _ = try await DreamRollupService.run(root: root, now: now, calendar: calendar) { engine }
        try save("2026-10-06", "Rewrote the briefing work.", hour: 23)

        let pruned = try await DreamRollupService.run(root: root, now: now, calendar: calendar, limit: 0) {
            XCTFail("no engine without a budget")
            return engine
        }
        XCTAssertEqual(pruned.removed, ["2026-W41"])
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: DreamRollupFormat.rollupURL(root: root, key: "2026-W41").path))

        // The same night writes nothing more; the next night rebuilds it.
        let sameNight = try await DreamRollupService.run(root: root, now: now.addingTimeInterval(3_600),
                                                         calendar: calendar) { engine }
        XCTAssertTrue(sameNight.written.isEmpty)
        let nextNight = now.addingTimeInterval(DreamRollupService.minimumGenerationInterval)
        let rebuilt = try await DreamRollupService.run(root: root, now: nextNight, calendar: calendar) { engine }
        XCTAssertEqual(rebuilt.written.map(\.key), ["2026-W41"])
    }

    func testInvalidatingAReviewRemovesTheLinesDrawnFromIt() async throws {
        _ = try await DreamRollupService.run(root: root, now: now, calendar: calendar) { RollupStubEngine("A line.") }
        try DreamStore(root: root).invalidateReport(forDayKey: "2026-09-15")
        XCTAssertEqual(Set(DreamRollupFormat.rollups(root: root).map(\.key)), ["2026-W41"])
    }

    func testClearWorkMemoryRemovesTheLines() async throws {
        _ = try await DreamRollupService.run(root: root, now: now, calendar: calendar) { RollupStubEngine("A line.") }
        try DreamStore(root: root).clearAll()
        XCTAssertTrue(DreamRollupFormat.rollups(root: root).isEmpty)
    }

    private func save(_ day: String, _ narrative: String, hour: Int = 22) throws {
        let generatedAt = try XCTUnwrap(ISO8601DateFormatter().date(from: "\(day)T\(hour):00:00Z"))
        try DreamStore(root: root).save(DreamReport(
            day: day, generatedAt: generatedAt, engineName: "test", narrative: narrative))
    }
}

private final class BriefingStubReader: ScreenMemoryReading {
    let sessions: [ScreenMemoryAgentSession]
    private(set) var requestedStart: Date?

    init(sessions: [ScreenMemoryAgentSession]) { self.sessions = sessions }

    func agentSessions(from start: Date, to end: Date, limit: Int) throws -> [ScreenMemoryAgentSession] {
        requestedStart = start
        return sessions.filter { $0.start >= start && $0.start < end }
    }

    func search(_ request: ScreenMemorySearchRequest) throws -> [ScreenMemorySearchHit] { [] }
    func timeline(from start: Date, to end: Date, limit: Int) throws -> ScreenMemoryTimeline {
        ScreenMemoryTimeline(start: start, end: end, activity: [], screenshots: [])
    }
    func recentActivity(since: Date, limit: Int) throws -> [ScreenMemoryActivityBlock] { [] }
    func appUsage(from start: Date, to end: Date, limit: Int) throws -> [ScreenMemoryAppUsage] { [] }
    func screenshotDetail(snapshotID: Int64) throws -> ScreenMemoryScreenshotDetail? { nil }
    func savedMoments(from start: Date, to end: Date, limit: Int) throws -> [ScreenMemorySavedMoment] { [] }
    func daySummary(from start: Date, to end: Date) throws -> ScreenMemoryDaySummary {
        ScreenMemoryDaySummary(trackedSeconds: 0, appCount: 0, activityBlockCount: 0,
                               screenshotCount: 0, savedMomentCount: 0)
    }
    func activityBlocks(from start: Date, to end: Date) throws -> [ScreenMemoryActivityBlock] { [] }
    func screenContexts(from start: Date, to end: Date, maxCharactersPerCapture: Int) throws
        -> [ScreenMemoryTextContext] { [] }
    func latestEvidenceAt(from start: Date, to end: Date) throws -> Date? { nil }
}

private final class RollupStubEngine: TextEngine {
    private let output: String
    private(set) var prompts: [String] = []

    init(_ output: String) { self.output = output }

    var displayName: String { "Rollup stub" }

    func generate(system: String, prompt: String, context: [String]) async throws -> String {
        prompts.append(prompt)
        return output
    }
}
