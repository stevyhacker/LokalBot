import XCTest
@testable import LokalBot

final class TimelineProjectAttributionTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_760_000_000)

    private func block(
        _ id: Int64,
        app: String,
        title: String = "",
        start: TimeInterval,
        end: TimeInterval
    ) -> ActivityBlock {
        ActivityBlock(
            id: id,
            app: app,
            title: title,
            start: base.addingTimeInterval(start),
            end: base.addingTimeInterval(end))
    }

    /// Five-minute sampler blocks in one app from `start` to `end`.
    private func blocks(
        from firstID: Int64,
        app: String,
        title: String = "",
        start: TimeInterval,
        end: TimeInterval
    ) -> [ActivityBlock] {
        var result: [ActivityBlock] = []
        var id = firstID
        var cursor = start
        while cursor < end {
            let next: TimeInterval = min(cursor + 300, end)
            result.append(block(id, app: app, title: title, start: cursor, end: next))
            id += 1
            cursor = next
        }
        return result
    }

    private func burst(
        _ project: String,
        agent: CodingAgentKind = .claudeCode,
        title: String = "Parser rewrite",
        start: TimeInterval,
        end: TimeInterval,
        prompts: [String] = ["please rewrite the parser"],
        actions: [CodingAgentAction] = [],
        pullRequests: [String] = []
    ) -> CodingAgentBurst {
        let startDate: Date = base.addingTimeInterval(start)
        let endDate: Date = base.addingTimeInterval(end)
        let active: TimeInterval = end - start
        return CodingAgentBurst(
            agent: agent,
            sessionID: "\(project)-\(Int(start))",
            title: title,
            project: project,
            branch: nil,
            start: startDate,
            end: endDate,
            activeDuration: active,
            prompts: prompts,
            promptCount: prompts.count,
            finalReply: nil,
            changedFiles: [],
            changedFileCount: 0,
            actions: actions,
            pullRequests: pullRequests,
            toolCallCount: 0)
    }

    private func seconds(_ shares: [TimelineProjectAttribution.Share], _ project: String) -> TimeInterval {
        shares.first { $0.project == project }?.seconds ?? 0
    }

    // MARK: - Attribution

    func testAgentAppTimeIsSharedAmongOverlappingBursts() {
        let attribution = TimelineProjectAttribution(bursts: [
            burst("bizstats", start: 0, end: 1_800),
            burst("LokalBot", start: 0, end: 1_800),
        ])
        let shares = attribution.shares(for: block(1, app: "Claude", title: "Claude", start: 0, end: 1_800))

        XCTAssertEqual(seconds(shares, "bizstats"), 900, accuracy: 0.001)
        XCTAssertEqual(seconds(shares, "LokalBot"), 900, accuracy: 0.001)
    }

    func testAgentAppTimeCountsOnlyThePartBurstsCover() {
        let attribution = TimelineProjectAttribution(bursts: [burst("bizstats", start: 0, end: 600)])
        let shares = attribution.shares(for: block(1, app: "Claude", start: 0, end: 3_600))

        // The burst plus the two-minute margin after its last event.
        XCTAssertEqual(seconds(shares, "bizstats"), 720, accuracy: 0.001)
    }

    func testOnlyAppsThatRunTheAgentTakeItsTime() {
        let attribution = TimelineProjectAttribution(bursts: [
            burst("bizstats", agent: .claudeCode, start: 0, end: 1_800),
            burst("LokalBot", agent: .codex, start: 0, end: 1_800),
        ])

        XCTAssertTrue(attribution.shares(for: block(1, app: "Discord", start: 0, end: 600)).isEmpty)
        XCTAssertEqual(attribution.dominantProject(for: block(2, app: "ChatGPT", start: 0, end: 600)), "LokalBot")
        XCTAssertEqual(attribution.dominantProject(for: block(3, app: "Claude", start: 0, end: 600)), "bizstats")
        let terminal = attribution.shares(for: block(4, app: "Ghostty", start: 0, end: 600))
        XCTAssertEqual(Set(terminal.map(\.project)), ["bizstats", "LokalBot"])
        XCTAssertEqual(attribution.dominantProject(for: block(5, app: "T3 Code (Nightly)", start: 0, end: 600)) != nil, true)
    }

    func testWindowNamingAProjectOrItsRepositoryCountsTowardIt() {
        let attribution = TimelineProjectAttribution(bursts: [
            burst("bizstats", start: 0, end: 600),
            burst("alpha", start: 0, end: 600,
                  pullRequests: ["https://github.com/TokenLogic-com-au/logic-onchain/pull/12"]),
        ])

        XCTAssertEqual(attribution.dominantProject(for: block(
            1, app: "Google Chrome", title: "Pull requests · stevyhacker/bizstats - Google Chrome - Stevan",
            start: 5_000, end: 5_300)), "bizstats")
        XCTAssertEqual(attribution.dominantProject(for: block(
            2, app: "Google Chrome",
            title: "feat(onchain): add fee-share extraction · Pull Request #12 · TokenLogic-com-au/logic-onchain",
            start: 5_000, end: 5_300)), "alpha")
        // A page naming no project stays unattributed even while agents work.
        XCTAssertNil(attribution.dominantProject(for: block(
            3, app: "Google Chrome", title: "Home / X - Google Chrome", start: 0, end: 300)))
    }

    func testARepositoryNamedAfterAProjectStaysThatProjects() {
        let attribution = TimelineProjectAttribution(bursts: [
            burst("bizstats", start: 0, end: 3_000,
                  pullRequests: ["https://github.com/stevyhacker/scraping-eprijava/pull/3"]),
            burst("scraping-eprijava", start: 0, end: 600),
        ])

        XCTAssertEqual(attribution.dominantProject(for: block(
            1, app: "Google Chrome", title: "Pull requests · stevyhacker/scraping-eprijava - Google Chrome",
            start: 5_000, end: 5_300)), "scraping-eprijava")
    }

    func testScheduledRunsAndUnnamedFoldersClaimNoTime() {
        let attribution = TimelineProjectAttribution(bursts: [
            burst("bizstats", start: 0, end: 1_800, prompts: ["Scheduled task: nightly audit"]),
            burst("GitHub", start: 0, end: 1_800),
        ])

        XCTAssertTrue(attribution.isEmpty)
        XCTAssertEqual(attribution.bursts.map(\.project), ["GitHub"])
        XCTAssertTrue(attribution.shares(for: block(1, app: "Claude", start: 0, end: 600)).isEmpty)
    }

    func testDaySplitAddsUpToTrackedTime() {
        let attribution = TimelineProjectAttribution(bursts: [burst("bizstats", start: 0, end: 1_200)])
        let day = blocks(from: 1, app: "Claude", start: 0, end: 1_800)
            + [block(100, app: "Discord", start: 1_800, end: 2_400),
               block(101, app: "loginwindow", start: 2_400, end: 9_000)]
        let split = attribution.split(of: day)
        let attributed = split.projects.reduce(0) { $0 + $1.seconds }

        XCTAssertEqual(split.projects.map(\.project), ["bizstats"])
        XCTAssertEqual(attributed, 1_320, accuracy: 0.001)
        XCTAssertEqual(attributed + split.unattributedSeconds, 2_400, accuracy: 0.001)
    }

    // MARK: - Sessions

    func testSessionsEndWhereTheWorkMovesToAnotherProject() {
        let attribution = TimelineProjectAttribution(bursts: [
            burst("bizstats", title: "Rehearse the audit runbook", start: 0, end: 3_300),
            burst("LokalBot", title: "Timeline project rail", start: 3_300, end: 6_000),
        ])
        let sessions = TimelineWorkSession.sessions(
            from: blocks(from: 1, app: "Claude", start: 0, end: 6_000), attribution: attribution)

        XCTAssertEqual(sessions.count, 2)
        // A project session is not cut at the 45-minute limit.
        XCTAssertEqual(sessions[0].activeDuration, 3_300)
        XCTAssertEqual(sessions[0].title, "bizstats · Rehearse the audit runbook")
        XCTAssertEqual(sessions[0].project, "bizstats")
        XCTAssertEqual(sessions[1].title, "LokalBot · Timeline project rail")
    }

    func testABriefLookAtAnotherProjectStaysInTheSession() {
        let attribution = TimelineProjectAttribution(bursts: [
            burst("bizstats", start: 0, end: 1_800),
            burst("LokalBot", start: 1_800, end: 2_100),
            burst("bizstats", start: 2_100, end: 3_600),
        ])
        let sessions = TimelineWorkSession.sessions(
            from: blocks(from: 1, app: "Claude", start: 0, end: 3_600), attribution: attribution)

        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.first?.project, "bizstats")
        XCTAssertEqual(sessions.first?.agentBursts.count, 3)
    }

    func testTimeNoProjectClaimsFallsBackToAppSessions() {
        let attribution = TimelineProjectAttribution(bursts: [burst("bizstats", start: 0, end: 1_200)])
        let day = blocks(from: 1, app: "Claude", start: 0, end: 1_200)
            + blocks(from: 100, app: "Discord", title: "#general", start: 1_200, end: 4_800)
        let sessions = TimelineWorkSession.sessions(from: day, attribution: attribution)

        XCTAssertEqual(sessions.map(\.project), ["bizstats", nil, nil])
        // Sixty minutes of chat is still cut at 45 minutes, like without agents.
        XCTAssertEqual(sessions[1].activeDuration, 2_700)
        XCTAssertEqual(sessions[1].title, "#general")
    }

    func testEachBurstIsListedUnderOneSessionWithItsOutcomes() {
        let attribution = TimelineProjectAttribution(bursts: [
            burst("bizstats", title: "Audit fixes", start: 0, end: 2_400,
                  actions: [.openedPullRequest(title: "Fix the e2e race"), .mergedPullRequest(number: 41),
                            .commit(message: "Retry the click")]),
            burst("LokalBot", title: "Timeline rail", start: 2_400, end: 4_200,
                  actions: [.openedPullRequest(title: "Name sessions by project")]),
        ])
        let sessions = TimelineWorkSession.sessions(
            from: blocks(from: 1, app: "Claude", start: 0, end: 4_200), attribution: attribution)

        XCTAssertEqual(sessions.count, 2)
        XCTAssertEqual(sessions.flatMap(\.agentBursts).count, 2)
        XCTAssertEqual(sessions[0].outcomes.openedPullRequests, ["Fix the e2e race"])
        XCTAssertEqual(sessions[0].outcomes.mergedPullRequests, 1)
        XCTAssertEqual(sessions[0].outcomes.commits, 1)
        XCTAssertEqual(sessions[1].outcomes.openedPullRequests, ["Name sessions by project"])
    }

    func testAgentWorkBetweenSessionsJoinsTheNearestOne() {
        let attribution = TimelineProjectAttribution(bursts: [
            burst("bizstats", start: 0, end: 900),
            burst("bizstats", title: "Overnight import", start: 1_500, end: 1_700),
        ])
        let sessions = TimelineWorkSession.sessions(
            from: blocks(from: 1, app: "Claude", start: 0, end: 900), attribution: attribution)

        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].agentBursts.map(\.title), ["Parser rewrite", "Overnight import"])
    }

    func testASecondProjectWithAFairShareIsNamedToo() {
        let attribution = TimelineProjectAttribution(bursts: [
            burst("bizstats", start: 0, end: 1_200),
            burst("alpha", start: 0, end: 60,
                  pullRequests: ["https://github.com/TokenLogic-com-au/logic-onchain/pull/12"]),
        ])
        let day = blocks(from: 1, app: "Claude", start: 0, end: 1_200)
            + blocks(from: 100, app: "Google Chrome",
                     title: "Fee-share extraction · Pull Request #12 · TokenLogic-com-au/logic-onchain",
                     start: 1_200, end: 1_700)
        let sessions = TimelineWorkSession.sessions(from: day, attribution: attribution)

        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].project, "bizstats")
        XCTAssertEqual(sessions[0].title, "bizstats, alpha · Parser rewrite")
    }

    func testAMinorProjectShareKeepsTheWindowTitle() {
        let attribution = TimelineProjectAttribution(bursts: [burst("bizstats", start: 0, end: 60)])
        let sessions = TimelineWorkSession.sessions(
            from: [block(1, app: "Claude", start: 0, end: 120),
                   block(2, app: "Pages", title: "Quarterly letter", start: 120, end: 1_800)],
            attribution: attribution)

        XCTAssertEqual(sessions.count, 1)
        XCTAssertFalse(sessions[0].titleNamesProject)
        XCTAssertEqual(sessions[0].title, "Quarterly letter")
        XCTAssertEqual(sessions[0].agentBursts.count, 1)
    }

    func testWithoutProjectsSessionsKeepTheAppRules() {
        let day = blocks(from: 1, app: "Claude", start: 0, end: 3_600)
        let plain = TimelineWorkSession.sessions(from: day)
        let unnamed = TimelineWorkSession.sessions(
            from: day, attribution: TimelineProjectAttribution(bursts: [burst("GitHub", start: 0, end: 600)]))

        XCTAssertEqual(plain.map(\.activeDuration), [2_700, 900])
        XCTAssertEqual(unnamed.map(\.activeDuration), plain.map(\.activeDuration))
        XCTAssertEqual(unnamed.map(\.title), plain.map(\.title))
        XCTAssertEqual(unnamed.first?.agentBursts.count, 1)
    }

    func testAgentSessionsThatResumeReadAsOneTask() {
        var first = burst("bizstats", title: "Page audit", start: 0, end: 600,
                          actions: [.openedPullRequest(title: "Fix the race")])
        first.sessionID = "audit"
        var resumed = burst("bizstats", title: "Page UI/UX and data audit", start: 1_200, end: 1_800,
                            prompts: [], actions: [.mergedPullRequest(number: 41)])
        resumed.sessionID = "audit"
        let other = burst("LokalBot", title: "Timeline rail", start: 300, end: 900)
        let tasks = TimelineAgentTask.tasks(from: [first, other, resumed])

        XCTAssertEqual(tasks.count, 2)
        XCTAssertEqual(tasks[0].bursts.count, 2)
        XCTAssertEqual(tasks[0].title, "Page UI/UX and data audit")
        XCTAssertEqual(tasks[0].request, "please rewrite the parser")
        XCTAssertEqual(tasks[0].end, base.addingTimeInterval(1_800))
        XCTAssertEqual(TimelineAgentOutcomes(tasks[0].bursts).mergedPullRequests, 1)
        XCTAssertEqual(tasks[1].project, "LokalBot")
    }

    func testDayProjectionCarriesTheProjectSplit() {
        let day = Date(timeIntervalSince1970: 1_760_000_000)
        let projection = DayActivityProjection(
            blocks: blocks(from: 1, app: "Claude", start: 0, end: 1_200),
            day: day,
            agentBursts: [burst("bizstats", start: 0, end: 1_200)])

        XCTAssertEqual(projection.sessions.first?.project, "bizstats")
        XCTAssertEqual(projection.attribution.split(of: projection.blocks).projects.map(\.project), ["bizstats"])
    }
}
