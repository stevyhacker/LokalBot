import XCTest
@testable import LokalBot

@MainActor
final class CodingAgentEvidenceTests: XCTestCase {
    private var root: URL!
    private var calendar: Calendar!
    private var day: Date!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodingAgentEvidenceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        day = try date("2026-09-29T00:00:00Z")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Store

    func testStoreKeepsBurstsByStartDayAndAdvancesTheWatermark() throws {
        let store = makeStore()
        let morning = try burst("A", start: "2026-09-29T09:00:00Z", end: "2026-09-29T09:20:00Z")
        let nextDay = try burst("B", start: "2026-09-30T08:00:00Z", end: "2026-09-30T08:30:00Z")
        try store.upsertCodingAgentBursts([morning, nextDay])

        XCTAssertEqual(store.codingAgentBursts(in: dayInterval), [morning])
        XCTAssertEqual(try store.codingAgentBurstStarts().count, 2)

        try store.deleteCodingAgentBursts(ids: [morning.id])
        XCTAssertTrue(store.codingAgentBursts(in: dayInterval).isEmpty)
    }

    func testReadOnlyConnectionToADatabaseWithoutTheTableReadsNothing() throws {
        let url = root.appendingPathComponent("older.sqlite")
        let database = try XCTUnwrap(SQLiteDatabase(url: url, readOnly: false))
        try database.execute("CREATE TABLE unrelated (value INTEGER);")

        XCTAssertTrue(ActivityStore(databaseURL: url, readOnly: true).codingAgentBursts(in: dayInterval).isEmpty)
    }

    // MARK: - Ingestion

    func testApplyStoresOnlySettledWorkAndRevokesRemovalsAndCorrections() throws {
        let store = makeStore()
        var revoked: [[Date]] = []
        var changed: [[Date]] = []
        let configuration = CodingAgentEvidenceIngestor.Configuration(agents: [.claudeCode])
        let ingestor = makeIngestor(store: store, configuration: configuration,
                                    revoked: { revoked.append($0) }, changed: { changed.append($0) })
        let scannedAt = try date("2026-09-29T20:00:00Z")
        let settled = try burst("A", start: "2026-09-29T09:00:00Z", end: "2026-09-29T09:20:00Z")
        let live = try burst("B", start: "2026-09-29T19:52:00Z", end: "2026-09-29T19:55:00Z")

        try ingestor.apply(scan([settled, live]), configuration: configuration, scannedAt: scannedAt)
        XCTAssertEqual(store.codingAgentBursts(in: dayInterval), [settled], "work still in progress waits")
        XCTAssertTrue(revoked.isEmpty, "new work is an addition, not a revocation")
        XCTAssertEqual(changed, [[day]])

        try ingestor.apply(scan([settled, live]), configuration: configuration, scannedAt: scannedAt)
        XCTAssertTrue(revoked.isEmpty)
        XCTAssertEqual(changed, [[day]], "an unchanged scan changes nothing")

        try ingestor.apply(
            scan([], unreadable: ["/x/broken.jsonl"]), configuration: configuration, scannedAt: scannedAt)
        XCTAssertEqual(store.codingAgentBursts(in: dayInterval), [settled], "a read failure is not a deletion")

        var renamed = settled
        renamed.title = "Renamed session"
        try ingestor.apply(scan([renamed]), configuration: configuration, scannedAt: scannedAt)
        XCTAssertEqual(store.codingAgentBursts(in: dayInterval), [renamed])
        XCTAssertEqual(revoked, [[day]], "a correction revokes what used the old record")

        try ingestor.apply(scan([]), configuration: configuration, scannedAt: scannedAt)
        XCTAssertTrue(store.codingAgentBursts(in: dayInterval).isEmpty)
        XCTAssertEqual(revoked, [[day], [day]])
    }

    func testApplyLeavesOtherAgentsAloneAndSkipsExpiredText() throws {
        let store = makeStore()
        let claude = try burst("A", start: "2026-09-29T09:00:00Z", end: "2026-09-29T09:20:00Z")
        try store.upsertCodingAgentBursts([claude])
        let configuration = CodingAgentEvidenceIngestor.Configuration(agents: [.codex], retentionDays: 1)
        let ingestor = makeIngestor(store: store, configuration: configuration)
        let expired = try burst("C", agent: .codex, start: "2026-09-29T08:00:00Z", end: "2026-09-29T08:10:00Z")
        let recent = try burst("D", agent: .codex, start: "2026-09-29T21:00:00Z", end: "2026-09-29T21:10:00Z")

        try ingestor.apply(
            scan([expired, recent]), configuration: configuration, scannedAt: try date("2026-09-30T12:00:00Z"))

        XCTAssertEqual(store.codingAgentBursts(in: dayInterval), [claude, recent],
                       "a disabled agent keeps its saved records; text past retention is never stored")
    }

    func testRefreshScansTheDigestWindowAndAnOlderRequestedDay() async throws {
        let store = makeStore()
        let recorder = ScanRecorder()
        let now = try date("2026-09-29T15:00:00Z")
        var configuration = CodingAgentEvidenceIngestor.Configuration(agents: [])
        let ingestor = CodingAgentEvidenceIngestor(
            store: store,
            configuration: { configuration },
            scan: { _, first, last, _ in
                recorder.record(first, last)
                return CodingAgentDayScan(
                    interval: DateInterval(start: first, end: last.addingTimeInterval(86_400)), bursts: [],
                    sessionCount: 0, filesRead: 0, bytesRead: 0, unreadableFiles: [], excludedSessions: 0)
            },
            mutateEvidence: { _, body in try body() },
            now: { now }, calendar: calendar)

        await ingestor.refresh()
        XCTAssertTrue(recorder.ranges.isEmpty, "nothing is read while the feature is off")

        configuration = .init(agents: [.claudeCode, .codex])
        await ingestor.refresh(including: try date("2026-09-10T12:00:00Z"))
        XCTAssertEqual(recorder.ranges.map { $0.0 }, [try date("2026-09-23T00:00:00Z"), try date("2026-09-10T00:00:00Z")])
        XCTAssertEqual(recorder.ranges.map { $0.1 }, [try date("2026-09-29T00:00:00Z"), try date("2026-09-10T00:00:00Z")])
    }

    func testAScanFinishingAfterTheFeatureIsTurnedOffStoresNothing() async throws {
        let store = makeStore()
        let switchBox = ConfigurationBox(.init(agents: [.claudeCode]))
        let settled = try burst("A", start: "2026-09-29T09:00:00Z", end: "2026-09-29T09:20:00Z")
        let now = try date("2026-09-29T15:00:00Z")
        let ingestor = CodingAgentEvidenceIngestor(
            store: store,
            configuration: { switchBox.value },
            scan: { [dayInterval] _, _, _, _ in
                // The person deletes saved sessions while this scan runs.
                switchBox.value = .init(agents: [])
                return CodingAgentDayScan(
                    interval: dayInterval, bursts: [settled], sessionCount: 1, filesRead: 1,
                    bytesRead: 1, unreadableFiles: [], excludedSessions: 0)
            },
            mutateEvidence: { _, body in try body() },
            now: { now }, calendar: calendar)

        await ingestor.refresh()

        XCTAssertTrue(store.codingAgentBursts(in: dayInterval).isEmpty)
    }

    func testANewInstallReadsNoSessionUntilSetupIsFinished() async throws {
        let store = makeStore()
        let recorder = ScanRecorder()
        let now = try date("2026-09-29T15:00:00Z")
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings()
        let ingestor = CodingAgentEvidenceIngestor(
            store: store,
            configuration: { AppState.codingAgentConfiguration(settings, defaults: defaults) },
            scan: { _, first, last, _ in
                recorder.record(first, last)
                return CodingAgentDayScan(
                    interval: DateInterval(start: first, end: last.addingTimeInterval(86_400)), bursts: [],
                    sessionCount: 0, filesRead: 0, bytesRead: 0, unreadableFiles: [], excludedSessions: 0)
            },
            mutateEvidence: { _, body in try body() },
            now: { now }, calendar: calendar)

        XCTAssertTrue(settings.codingAgentEvidenceEnabled, "reading stays on by default for new installs")
        await ingestor.refresh(including: try date("2026-09-10T12:00:00Z"))
        XCTAssertTrue(recorder.ranges.isEmpty, "a digest's refresh reads nothing before setup is finished")

        defaults.set(true, forKey: AppState.onboardingShownKey)
        await ingestor.refresh()
        XCTAssertEqual(recorder.ranges.map { $0.0 }, [try date("2026-09-23T00:00:00Z")],
                       "finishing setup with the default kept starts reading")
    }

    // MARK: - Retention

    func testRetentionReviewExpiresAgentRecordsWithScreenText() throws {
        let store = makeStore()
        let now = try date("2026-09-29T12:00:00Z")
        let old = try burst("A", start: "2026-09-01T09:00:00Z", end: "2026-09-01T09:20:00Z")
        let recent = try burst("B", start: "2026-09-28T09:00:00Z", end: "2026-09-28T09:20:00Z")
        try store.upsertCodingAgentBursts([old, recent])

        let review = try store.retentionReview(days: 14, keepTextForever: false, now: now)
        XCTAssertEqual(review.codingAgentBursts.map(\.id), [old.id])
        XCTAssertTrue(review.evidenceDates.contains(old.start))
        XCTAssertTrue(try store.retentionReview(days: 14, keepTextForever: true, now: now).codingAgentBursts.isEmpty)

        var expanded = review
        expanded.codingAgentBursts.append(.init(id: "claude-code:new:1", start: now))
        XCTAssertFalse(review.covers(expanded), "more agent records need a fresh review")
        XCTAssertTrue(expanded.covers(review), "a record that disappeared may shrink a review")
    }

    // MARK: - Evidence and journal

    func testSnapshotLoadsStoredBurstsWithDetailedActivityOnly() throws {
        let store = ActivityStore(databaseURL: root.appendingPathComponent("lokalbotv3.sqlite"))
        let saved = try burst("A", start: "2026-09-29T09:00:00Z", end: "2026-09-29T09:20:00Z")
        try store.upsertCodingAgentBursts([saved])
        let source = FileDailyEvidenceSource(root: root, calendar: calendar)

        let detailed = try source.snapshot(for: day, meetings: [], includeScreenSummary: false)
        XCTAssertEqual(detailed.codingAgentBursts, [saved])
        XCTAssertEqual(detailed.digestEvidence(calendar: calendar).codingAgentBursts, [saved])
        XCTAssertEqual(detailed.latestEvidenceAt, saved.end)

        let summaryOnly = try source.snapshot(
            for: day, meetings: [], includeDetailedActivity: false, includeScreenSummary: false)
        XCTAssertTrue(summaryOnly.codingAgentBursts.isEmpty)
    }

    func testJournalListsAgentSessionsFromRecordedFactsOnly() throws {
        let first = try burst(
            "A", start: "2026-09-29T09:00:00Z", end: "2026-09-29T09:20:00Z", active: 15 * 60,
            actions: [.commit(message: "Keep the digest badge fresh"), .pushed],
            pullRequests: ["https://github.com/stevyhacker/LokalBot/pull/118"])
        let second = try burst(
            "A", start: "2026-09-29T11:00:00Z", end: "2026-09-29T11:10:00Z", active: 10 * 60,
            prompts: ["/code-review high"], actions: [.pushed])
        let evidence = DayDigestEvidence.build(
            day: day, blocks: [], screenContexts: [], meetings: [],
            codingAgentBursts: [second, first], calendar: calendar)

        let document = evidence.renderDocument(summary: "### Tasks\n- **Work**", calendar: calendar)

        let meetings = try XCTUnwrap(document.range(of: "## Meetings"))
        let agents = try XCTUnwrap(document.range(of: "## Agent sessions"))
        let time = try XCTUnwrap(document.range(of: "## Time allocation"))
        XCTAssertTrue(meetings.lowerBound < agents.lowerBound && agents.lowerBound < time.lowerBound)
        XCTAssertTrue(document.contains("""
            ### 09:00 — Fix digest freshness (Claude Code)
            - Project: LokalBot (branch claude/fix-badge)
            - Time: 09:00–09:20, 11:00–11:10 (25m active)
            - Requests: Fix the stale digest badge; /code-review high
            - Recorded actions: commit: Keep the digest badge fresh; pushed
            - Pull requests: [stevyhacker/LokalBot#118](https://github.com/stevyhacker/LokalBot/pull/118)
            - Changed files (1): LokalBot/Views/DayDigestCard.swift
            """), document)
        XCTAssertFalse(document.contains("Opened the PR"), "the agent's report is a claim, not a journal fact")
        XCTAssertTrue(document.contains("— **Claude Code** — Fix digest freshness (LokalBot)"))

        let presentation = DayDigestPresentation(markdown: document)
        XCTAssertTrue(presentation.agentSessionsMarkdown?.contains("Fix digest freshness") == true)
        XCTAssertNil(DayDigestPresentation(markdown: "## Meetings\n\n_None._").agentSessionsMarkdown)
    }

    func testDaysWithoutAgentWorkKeepTheirJournalShapeAndSignature() throws {
        let block = ActivityBlock(
            id: 7, app: "Xcode", title: "LokalBot", start: try date("2026-09-29T10:00:00Z"),
            end: try date("2026-09-29T10:30:00Z"))
        let plain = DayDigestEvidence.build(
            day: day, blocks: [block], screenContexts: [], meetings: [], calendar: calendar)
        let explicitlyEmpty = DayDigestEvidence.build(
            day: day, blocks: [block], screenContexts: [], meetings: [], codingAgentBursts: [],
            calendar: calendar)
        let otherDay = DayDigestEvidence.build(
            day: day, blocks: [block], screenContexts: [], meetings: [],
            codingAgentBursts: [try burst("Z", start: "2026-09-30T09:00:00Z", end: "2026-09-30T09:10:00Z")],
            calendar: calendar)
        let withAgent = DayDigestEvidence.build(
            day: day, blocks: [block], screenContexts: [], meetings: [],
            codingAgentBursts: [try burst("A", start: "2026-09-29T09:00:00Z", end: "2026-09-29T09:20:00Z")],
            calendar: calendar)

        XCTAssertEqual(plain.contentSignature, explicitlyEmpty.contentSignature)
        XCTAssertEqual(plain.contentSignature, otherDay.contentSignature, "another day's burst is not evidence")
        XCTAssertNotEqual(plain.contentSignature, withAgent.contentSignature)
        XCTAssertFalse(plain.renderDocument(summary: "", calendar: calendar).contains("Agent sessions"))
        XCTAssertFalse(DayDigestEvidence.build(
            day: day, blocks: [], screenContexts: [], meetings: [],
            codingAgentBursts: withAgent.codingAgentBursts, calendar: calendar).isEmpty,
            "a day with only agent work still has evidence")
    }

    func testFallbackNamesAgentSessionsWithTheirRecordedActions() throws {
        let evidence = DayDigestEvidence.build(
            day: day, blocks: [], screenContexts: [], meetings: [],
            codingAgentBursts: [try burst(
                "A", start: "2026-09-29T09:00:00Z", end: "2026-09-29T09:20:00Z",
                actions: [.commit(message: "Keep the digest badge fresh"), .mergedPullRequest(number: 118)])],
            calendar: calendar)

        let fallback = DayDigestOverviewGenerator.fallback(evidence)

        XCTAssertTrue(fallback.contains("Fix digest freshness"), fallback)
        XCTAssertTrue(fallback.contains(
            "Worked with Claude Code in LokalBot. Recorded actions: commit: Keep the digest badge fresh; merged PR #118."),
            fallback)
    }

    func testPullRequestLinksNameTheRepository() {
        XCTAssertEqual(
            DayDigestEvidence.pullRequestLink("https://github.com/localhostinc/app/pull/186"),
            "[localhostinc/app#186](https://github.com/localhostinc/app/pull/186)")
        XCTAssertEqual(DayDigestEvidence.pullRequestLink("https://example.com/x"), "<https://example.com/x>")
    }

    // MARK: - Lifecycle

    func testGenerationAcceptsNewWorkButRejectsAChangedOriginal() async throws {
        let original = try burst("A", start: "2026-09-29T09:00:00Z", end: "2026-09-29T09:20:00Z")
        let arriving = try burst("B", start: "2026-09-29T19:00:00Z", end: "2026-09-29T19:10:00Z")
        var bursts = [original]
        var preparedDays: [Date] = []
        let lifecycle = DayDigestLifecycle(
            storageRoot: root, calendar: calendar,
            blocks: { _ in [] }, screenContexts: { _ in [] },
            codingAgentBursts: { _ in bursts },
            prepareEvidence: { preparedDays.append($0) },
            meetings: { [] }, latestActivityEvidenceAt: { _ in nil }, settings: { AppSettings() },
            generator: { [root] evidence, _, validateEvidence, _ in
                XCTAssertEqual(evidence.codingAgentBursts, [original])
                bursts.append(arriving)
                XCTAssertNoThrow(try validateEvidence(), "new settled work makes the digest stale, not invalid")
                var renamed = original
                renamed.title = "Renamed session"
                bursts[0] = renamed
                XCTAssertThrowsError(try validateEvidence())
                bursts[0] = original
                return DayDigestGenerationResult(
                    text: "fixture", url: root!.appendingPathComponent("journal.md"), quality: .complete)
            })

        _ = try await lifecycle.generate(for: day)

        XCTAssertEqual(preparedDays, [day], "agent evidence is refreshed before the day is read")
    }

    // MARK: - Settings and scanning

    func testSettingsDefaultOnAndRoundTrip() throws {
        XCTAssertTrue(AppSettings().codingAgentEvidenceEnabled)
        XCTAssertEqual(AppSettings().enabledCodingAgents, [.claudeCode, .codex])
        var off = AppSettings()
        off.codingAgentEvidenceEnabled = false
        XCTAssertTrue(off.enabledCodingAgents.isEmpty)

        var settings = AppSettings()
        settings.codingAgentEvidenceEnabled = true
        settings.codingAgentReadsCodex = false
        settings.codingAgentExcludedFolders = "~/Client, /tmp/private"
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))

        XCTAssertEqual(decoded.enabledCodingAgents, [.claudeCode])
        XCTAssertEqual(decoded.codingAgentExcludedFolderList, ["~/Client", "/tmp/private"])
        let configuration = CodingAgentEvidenceIngestor.Configuration(settings: decoded)
        XCTAssertEqual(configuration.retentionDays, decoded.retentionDays)
        settings.keepOCRTextForever = true
        XCTAssertNil(CodingAgentEvidenceIngestor.Configuration(settings: settings).retentionDays)
    }

    func testFinishedSetupKeepsTheSavedChoicesOfExistingInstalls() throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: AppState.onboardingShownKey)
        let saved = try JSONDecoder().decode(AppSettings.self, from: Data(
            #"{"codingAgentReadsCodex": false, "codingAgentExcludedFolders": "~/Client"}"#.utf8))
        let configuration = AppState.codingAgentConfiguration(saved, defaults: defaults)
        XCTAssertEqual(configuration, CodingAgentEvidenceIngestor.Configuration(settings: saved),
                       "settings alone decide once setup is finished")
        XCTAssertEqual(configuration.agents, [.claudeCode])
        XCTAssertEqual(configuration.excludedFolders, ["~/Client"])

        let legacy = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(AppState.codingAgentConfiguration(legacy, defaults: defaults).agents, [.claudeCode, .codex],
                       "settings saved before setup offered this choice keep reading")
        var off = saved
        off.codingAgentEvidenceEnabled = false
        XCTAssertTrue(AppState.codingAgentConfiguration(off, defaults: defaults).agents.isEmpty)
    }

    func testScannerSplitsASessionAtMidnight() throws {
        let transcript = CodingAgentTranscript(
            agent: .codex, sessionID: "T1", workingDirectory: "/Users/me/Code/App",
            events: [
                CodingAgentEvent(at: try date("2026-09-29T23:58:00Z"), kind: .prompt("Ship it")),
                CodingAgentEvent(at: try date("2026-09-30T00:02:00Z"), kind: .reply("Shipped.")),
            ])
        let scanner = CodingAgentSessionScanner(readers: [FixedReader(transcript: transcript)])

        let result = scanner.scan(from: day, through: try date("2026-09-30T00:00:00Z"), calendar: calendar)

        XCTAssertEqual(result.bursts.map { calendar.component(.day, from: $0.start) }, [29, 30])
        XCTAssertEqual(result.sessionCount, 1)
    }

    // MARK: - Fixtures

    private struct FixedReader: CodingAgentSessionReader {
        var agent: CodingAgentKind { .codex }
        let transcript: CodingAgentTranscript
        func transcripts(in interval: DateInterval) -> CodingAgentReadResult {
            CodingAgentReadResult(transcripts: [transcript])
        }
    }

    private final class ConfigurationBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: CodingAgentEvidenceIngestor.Configuration
        init(_ value: CodingAgentEvidenceIngestor.Configuration) { stored = value }
        var value: CodingAgentEvidenceIngestor.Configuration {
            get { lock.withLock { stored } }
            set { lock.withLock { stored = newValue } }
        }
    }

    private final class ScanRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [(Date, Date)] = []
        var ranges: [(Date, Date)] { lock.withLock { stored } }
        func record(_ first: Date, _ last: Date) { lock.withLock { stored.append((first, last)) } }
    }

    private var dayInterval: DateInterval { DateInterval(start: day, duration: 86_400) }

    /// A defaults suite of its own, so the setup flag never touches the host's.
    private func isolatedDefaults() throws -> (UserDefaults, String) {
        let suite = "CodingAgentEvidenceTests.\(UUID().uuidString)"
        return (try XCTUnwrap(UserDefaults(suiteName: suite)), suite)
    }

    private func makeStore() -> ActivityStore {
        ActivityStore(databaseURL: root.appendingPathComponent("\(UUID().uuidString).sqlite"))
    }

    private func makeIngestor(
        store: ActivityStore,
        configuration: CodingAgentEvidenceIngestor.Configuration,
        revoked: @escaping ([Date]) -> Void = { _ in },
        changed: @escaping ([Date]) -> Void = { _ in }
    ) -> CodingAgentEvidenceIngestor {
        CodingAgentEvidenceIngestor(
            store: store,
            configuration: { configuration },
            scan: { _, _, _, _ in
                preconditionFailure("apply tests pass scans directly")
            },
            mutateEvidence: { days, body in
                revoked(days)
                try body()
            },
            onChange: changed,
            calendar: calendar)
    }

    private func scan(_ bursts: [CodingAgentBurst], unreadable: [String] = []) -> CodingAgentDayScan {
        CodingAgentDayScan(
            interval: dayInterval, bursts: bursts, sessionCount: Set(bursts.map(\.sessionID)).count,
            filesRead: 1, bytesRead: 1, unreadableFiles: unreadable, excludedSessions: 0)
    }

    private func burst(
        _ session: String,
        agent: CodingAgentKind = .claudeCode,
        start: String,
        end: String,
        active: TimeInterval? = nil,
        prompts: [String] = ["Fix the stale digest badge"],
        actions: [CodingAgentAction] = [],
        pullRequests: [String] = []
    ) throws -> CodingAgentBurst {
        let startDate = try date(start)
        let endDate = try date(end)
        return CodingAgentBurst(
            agent: agent, sessionID: session, title: "Fix digest freshness", project: "LokalBot",
            branch: "claude/fix-badge", start: startDate, end: endDate,
            activeDuration: active ?? endDate.timeIntervalSince(startDate),
            prompts: prompts, promptCount: prompts.count, finalReply: "Opened the PR and pushed.",
            changedFiles: ["LokalBot/Views/DayDigestCard.swift"], changedFileCount: 1,
            actions: actions, pullRequests: pullRequests, toolCallCount: 3)
    }

    private func date(_ value: String) throws -> Date {
        try XCTUnwrap(ISO8601DateFormatter().date(from: value), value)
    }
}
