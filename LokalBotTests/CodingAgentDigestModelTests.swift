import XCTest
@testable import LokalBot

/// How coding-agent sessions reach the digest model: as segment evidence,
/// with reserved room, once per session, ahead of the same work on screen.
final class CodingAgentDigestModelTests: XCTestCase {
    private var calendar: Calendar!
    private var day: Date!

    override func setUpWithError() throws {
        calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        day = try date("2026-09-29T00:00:00Z")
    }

    func testSegmentsCarryAgentSessionsAsWorkEvidence() throws {
        let evidence = build(bursts: [try burst(
            "A", start: "2026-09-29T09:00:00Z", end: "2026-09-29T09:20:00Z",
            actions: [.commit(message: "Keep the digest badge fresh"), .pushed])])

        let segments = evidence.summarySegments()

        XCTAssertEqual(segments.count, 1)
        let text = try XCTUnwrap(segments.first?.evidence)
        XCTAssertTrue(text.contains("WORK SOURCE: AGENT SESSION"), text)
        XCTAssertTrue(text.contains("Session: Fix digest freshness"), text)
        XCTAssertTrue(text.contains("Recorded actions: commit: Keep the digest badge fresh; pushed"), text)
        XCTAssertTrue(text.contains("Claude Code — Fix digest freshness"), "the inventory names the session")
    }

    func testACrowdedSegmentKeepsRoomForSessionsThatRecordedOutcomes() throws {
        // One busy stretch with forty screen activities and seven parallel
        // sessions, followed by seven short, separate stretches, so the busy
        // one stays a single segment with more events than detail slots.
        let morning: Date = day.addingTimeInterval(9 * 3_600)
        var blocks: [ActivityBlock] = []
        for minute in 0..<40 {
            let start: Date = morning.addingTimeInterval(TimeInterval(minute) * 60)
            blocks.append(ActivityBlock(
                id: Int64(minute), app: "Safari", title: "Docs \(minute)",
                start: start, end: start.addingTimeInterval(60)))
        }
        for hour in 11...17 {
            let start: Date = day.addingTimeInterval(TimeInterval(hour) * 3_600)
            blocks.append(ActivityBlock(
                id: Int64(100 + hour), app: "Notes", title: "Note \(hour)",
                start: start, end: start.addingTimeInterval(60)))
        }
        var bursts: [CodingAgentBurst] = []
        for index in 1...7 {
            bursts.append(try burst(
                "S\(index)", start: "2026-09-29T09:05:00Z", end: "2026-09-29T09:30:00Z",
                title: "Session \(index)", actions: [.commit(message: "Change \(index)")]))
        }

        let segments = build(blocks: blocks, bursts: bursts).summarySegments()

        XCTAssertEqual(segments.count, 8)
        let busy = try XCTUnwrap(segments.first?.evidence)
        XCTAssertEqual(busy.components(separatedBy: "WORK SOURCE: AGENT SESSION").count - 1, 6)
        XCTAssertEqual(busy.components(separatedBy: "WORK SOURCE: ACTIVITY").count - 1, 6,
                       "screen activity keeps the other half of the detail budget")
    }

    func testASessionsBurstsInOneSegmentAppearOnceWithAllTheirActions() throws {
        // Seven separate later stretches keep the session to one segment; a
        // quiet day would otherwise be spread across several.
        var later: [ActivityBlock] = []
        for hour in 11...17 {
            let start: Date = day.addingTimeInterval(TimeInterval(hour) * 3_600)
            later.append(ActivityBlock(
                id: Int64(hour), app: "Notes", title: "Note \(hour)",
                start: start, end: start.addingTimeInterval(60)))
        }
        let evidence = build(blocks: later, bursts: [
            try burst("A", start: "2026-09-29T09:00:00Z", end: "2026-09-29T09:10:00Z",
                      prompts: ["Fix the badge"], actions: [.commit(message: "Fix the badge")]),
            try burst("A", start: "2026-09-29T09:15:00Z", end: "2026-09-29T09:25:00Z",
                      prompts: ["Open the PR"], actions: [.openedPullRequest(title: "Fix the badge")]),
        ])

        let text = try XCTUnwrap(evidence.summarySegments().first?.evidence)

        XCTAssertEqual(text.components(separatedBy: "WORK SOURCE: AGENT SESSION").count - 1, 1)
        XCTAssertTrue(text.contains("- Fix the badge\n- Open the PR"), text)
        XCTAssertTrue(text.contains("Recorded actions: commit: Fix the badge; opened PR: Fix the badge"), text)
        XCTAssertTrue(text.contains("active=20m"), "both bursts' active time counts once each")
    }

    func testScreenTextFromAgentAppsYieldsToTheSessionItShows() throws {
        let blocks = [
            ActivityBlock(id: 1, app: "Claude", title: "Claude",
                          start: try date("2026-09-29T09:00:00Z"), end: try date("2026-09-29T09:30:00Z")),
            ActivityBlock(id: 2, app: "Xcode", title: "LokalBot",
                          start: try date("2026-09-29T10:30:00Z"), end: try date("2026-09-29T11:30:00Z")),
            ActivityBlock(id: 3, app: "Claude", title: "Claude",
                          start: try date("2026-09-29T13:00:00Z"), end: try date("2026-09-29T14:00:00Z")),
        ]
        // Plain loops and typed locals: inline arithmetic inside a mapped
        // initializer is too slow to type-check on CI's compiler.
        var contexts: [DayScreenContext] = []
        let samples: [(prefix: String, start: String, block: Int)] = [
            ("CLAUDE-DURING", "09:00", 1), ("XCODE", "10:30", 2), ("CLAUDE-AFTER", "13:00", 3),
        ]
        for sample in samples {
            let base: Date = try date("2026-09-29T\(sample.start):00Z")
            let block: ActivityBlock = blocks[sample.block - 1]
            for index in 0..<5 {
                let capturedAt: Date = base.addingTimeInterval(TimeInterval(index) * 300 + 60)
                let snapshotID = Int64(sample.block * 10 + index)
                contexts.append(DayScreenContext(
                    snapshotID: snapshotID, capturedAt: capturedAt, app: block.app,
                    windowTitle: block.title,
                    text: "\(sample.prefix)-\(index) distinct captured text for sample \(index)"))
            }
        }
        contexts.append(DayScreenContext(
            snapshotID: 99, capturedAt: try date("2026-09-29T09:40:00Z"), app: "Terminal",
            windowTitle: "zsh", text: "TERMINAL-STANDALONE transcript on screen"))
        let evidence = build(
            blocks: blocks, contexts: contexts,
            bursts: [try burst("A", start: "2026-09-29T09:10:00Z", end: "2026-09-29T09:50:00Z")])

        let text = evidence.summarySegments().map(\.evidence).joined(separator: "\n")

        XCTAssertEqual(text.components(separatedBy: "CLAUDE-DURING-").count - 1, 1,
                       "an agent app's screen text during a session keeps one sample")
        XCTAssertTrue(text.contains("A coding-agent session covers this interval"), text)
        XCTAssertGreaterThan(text.components(separatedBy: "XCODE-").count - 1, 1)
        XCTAssertGreaterThan(text.components(separatedBy: "CLAUDE-AFTER-").count - 1, 1,
                             "the same app outside any session is ordinary evidence")
        XCTAssertFalse(text.contains("TERMINAL-STANDALONE"))
        XCTAssertTrue(evidence.renderDocument(summary: "", calendar: calendar).contains("TERMINAL-STANDALONE"),
                      "the lossless journal still keeps it")
    }

    func testFocusPromptExplainsHowToReadAgentSessions() {
        let prompt = PromptTemplates.dayDigestFocusSystem
        XCTAssertTrue(prompt.contains("AGENT SESSION evidence"))
        XCTAssertTrue(prompt.contains("recorded actions"))
        XCTAssertTrue(prompt.contains("the agent's claim"))
    }

    func testTheModelReceivesAgentEvidenceAndItsTaskReachesTheDigest() async throws {
        let recorder = PromptRecorder()
        let evidence = build(bursts: [try burst(
            "A", start: "2026-09-29T09:00:00Z", end: "2026-09-29T09:20:00Z",
            actions: [.openedPullRequest(title: "Keep the digest badge fresh")])])

        let result = try await DayDigestOverviewGenerator.generateResult(
            evidence: evidence, engine: RecordingEngine(recorder: recorder),
            customPrompt: "", calendar: calendar, sleep: { _ in })

        let prompts = await recorder.focusPrompts
        XCTAssertEqual(prompts.count, 1)
        XCTAssertTrue(prompts.first?.contains("opened PR: Keep the digest badge fresh") == true)
        XCTAssertTrue(result.summary.contains("Keep the digest badge fresh"), result.summary)
        XCTAssertEqual(result.quality, .complete)
    }

    func testParallelSessionsEachReachTheTaskListWithoutDuplicatingTheModelsTask() async throws {
        let evidence = build(bursts: [
            try burst("A", start: "2026-09-29T09:00:00Z", end: "2026-09-29T09:20:00Z",
                      actions: [.commit(message: "Fix the badge"), .mergedPullRequest(number: 118)]),
            try burst("B", start: "2026-09-29T09:05:00Z", end: "2026-09-29T09:25:00Z",
                      title: "Update app branding", project: "Mojo",
                      actions: [.openedPullRequest(title: "feat: apply Mojo branding")]),
            // Describes the same work as the model's task, so it merges.
            try burst("C", start: "2026-09-29T09:10:00Z", end: "2026-09-29T09:15:00Z",
                      title: "Keep the digest badge fresh", actions: [.pushed]),
        ])

        let result = try await DayDigestOverviewGenerator.generateResult(
            evidence: evidence, engine: RecordingEngine(recorder: PromptRecorder()),
            customPrompt: "", calendar: calendar, sleep: { _ in })

        let summary = result.summary
        XCTAssertTrue(summary.contains("**Fix digest freshness (LokalBot)** — Completed."), summary)
        XCTAssertTrue(summary.contains("**Update app branding (Mojo)** — In progress."), summary)
        XCTAssertTrue(summary.contains("Recorded actions: opened PR: feat: apply Mojo branding"), summary)
        XCTAssertEqual(summary.components(separatedBy: "- **Keep the digest badge fresh").count - 1, 1,
                       "a session matching the model's task merges into it: \(summary)")
    }

    func testSessionsMergingIntoOneTaskNameEachPullRequestOnce() async throws {
        let evidence = build(bursts: [
            try burst("C", start: "2026-09-29T09:10:00Z", end: "2026-09-29T09:15:00Z",
                      title: "Keep the digest badge fresh", actions: [.pushed],
                      pullRequests: ["https://github.com/o/r/pull/105", "https://github.com/o/r/pull/10"]),
            try burst("D", start: "2026-09-29T09:12:00Z", end: "2026-09-29T09:18:00Z",
                      title: "Keep the digest badge fresh", actions: [.pushed],
                      pullRequests: ["https://github.com/o/r/pull/105", "https://github.com/o/r/pull/11"]),
        ])

        let summary = try await DayDigestOverviewGenerator.generateResult(
            evidence: evidence, engine: RecordingEngine(recorder: PromptRecorder()),
            customPrompt: "", calendar: calendar, sleep: { _ in }).summary

        XCTAssertEqual(summary.components(separatedBy: "o/r#105").count - 1, 1, summary)
        let ten = try NSRegularExpression(pattern: #"o/r#10(?!\d)"#)
        XCTAssertEqual(ten.numberOfMatches(in: summary, range: NSRange(summary.startIndex..., in: summary)), 1,
                       "#10 is its own pull request, not part of #105: \(summary)")
        XCTAssertTrue(summary.contains("o/r#11"), summary)
    }

    /// The 2026-10-19 journal named tasks "can you add short video demo
    /// recording of the new app platforms in the PR? (GitHub)", "Untitled
    /// session (GitHub)", and "… (scratch-2026-10-19-6f7eb7)", and listed two
    /// PR review sessions beside the model's own review task.
    func testSessionTasksAreNamedByTheirWorkAndProjectNotTheRequestOrFolder() async throws {
        let github = "/Users/me/Documents/GitHub"
        let scratch = "/Users/me/Library/Application Support/Claude/scratch-workspaces/bbf0/1b98/scratch-2026-10-19-6f7eb7"
        let bursts = try [
            session("A", folder: github, at: "2026-09-29T08:00:00Z",
                    prompts: ["can you add short video demo recording of the new app platforms in the PR?"],
                    actions: [.commit(message: "Temporary: record a Windows demo of LokalBot for PR #290"), .pushed,
                              .commit(message: "Demo recordings of the Linux and Windows apps")],
                    pullRequests: [290]),
            session("B", folder: github, at: "2026-09-29T09:00:00Z",
                    prompts: ["we should update the https://github.com/stevyhacker/LokalBot/pull/289 pr to make it "
                        + "general not only macOS as we are going to merge in linux and windows"],
                    actions: [.commit(message: "Drop macOS from the context engine tagline"), .pushed],
                    pullRequests: [289]),
            session("C", folder: github, at: "2026-09-29T10:00:00Z",
                    actions: [.commit(message: "Merge master into claude/agent-sessions-disclosure"), .pushed],
                    pullRequests: [279]),
            session("D", title: "Fix macOS Agent Mode '@'-path read-approval bypass", folder: scratch,
                    at: "2026-09-29T11:00:00Z",
                    prompts: ["Background (from the session that started this one): a session found that reads bypass approval"],
                    actions: [.pushed, .openedPullRequest(
                        title: "Agent Mode: check reads against the file pi opens; turn off runtime caches")],
                    pullRequests: [293]),
            session("E", agent: .codex, title: "Review all open PRs", folder: github + "/LokalBot",
                    at: "2026-09-29T12:00:00Z",
                    prompts: ["Review all open PRs", "any high or critical issues"], actions: [.ranTests]),
            session("F", agent: .codex, title: "Review the pull requests", folder: github + "/LokalBot",
                    at: "2026-09-29T13:00:00Z",
                    prompts: ["review these prs", "just submit a pr with that file deleted"],
                    actions: [.commit(message: "Disable Dependabot version update PRs"), .pushed,
                              .openedPullRequest(title: "Disable Dependabot version update PRs")],
                    pullRequests: [262, 261, 300]),
        ].flatMap { $0 }
        let engine = StubEngine(digestTasks: [
            ("LokalBot PR #290 Linux/Windows demos and recording fixes",
             "Committed Linux and Windows demo recordings to PR #290."),
            ("LokalBot open PR review and fixes", "Reviewed the open LokalBot pull requests and fixed the findings."),
        ])

        let summary = try await DayDigestOverviewGenerator.generateResult(
            evidence: build(bursts: bursts), engine: engine,
            customPrompt: "", calendar: calendar, sleep: { _ in }).summary

        let tasks = summary.split(separator: "\n").filter { $0.hasPrefix("- **") }.map(String.init)
        for raw in ["can you add", "we should update", "pull/289", "Untitled session", "scratch-2026", "GitHub"] {
            XCTAssertFalse(tasks.contains { $0.contains(raw) }, "\(raw) is not a name for work: \(summary)")
        }
        XCTAssertTrue(summary.contains("- **Drop macOS from the context engine tagline (LokalBot)** — In progress."), summary)
        XCTAssertTrue(summary.contains(
            "- **Merge master into claude/agent-sessions-disclosure (LokalBot)** — In progress. "
                + "Worked with Claude Code in LokalBot."), summary)
        XCTAssertTrue(summary.contains("- **Fix macOS Agent Mode '@'-path read-approval bypass (LokalBot)**"), summary)
        XCTAssertFalse(summary.contains("Demo recordings of the Linux and Windows apps (LokalBot)**"),
                       "the task naming PR #290 already describes it: \(summary)")
        XCTAssertFalse(summary.contains("**Review"), "both review sessions are the model's review task: \(summary)")
        XCTAssertTrue(summary.contains("stevyhacker/LokalBot#300"), summary)
        XCTAssertEqual(tasks.count, 5, summary)
    }

    func testASessionNamingOtherPullRequestsStaysItsOwnTask() async throws {
        let bursts = try session(
            "F", agent: .codex, title: "Review the pull requests", folder: "/Users/me/Code/LokalBot",
            at: "2026-09-29T13:00:00Z", prompts: ["review these prs"], actions: [.pushed],
            pullRequests: [262, 300])
        let engine = StubEngine(digestTasks: [
            ("LokalBot open PR review and PR #283 merge", "Reviewed the open LokalBot pull requests and merged #283."),
        ])

        let summary = try await DayDigestOverviewGenerator.generateResult(
            evidence: build(bursts: bursts), engine: engine,
            customPrompt: "", calendar: calendar, sleep: { _ in }).summary

        XCTAssertTrue(summary.contains("- **Review the pull requests (LokalBot)** — In progress."),
                      "shared words are not enough when the task names a different pull request: \(summary)")
    }

    func testSessionCandidatesComeFromRecordedFactsAndSkipScheduledRuns() throws {
        let evidence = build(bursts: [
            try burst("A", start: "2026-09-29T09:00:00Z", end: "2026-09-29T09:10:00Z",
                      actions: [.release(tag: "v1.0")]),
            try burst("B", start: "2026-09-29T09:00:00Z", end: "2026-09-29T09:10:00Z",
                      title: "Discuss the roadmap"),
            try burst("C", start: "2026-09-29T09:00:00Z", end: "2026-09-29T09:10:00Z",
                      title: "Write previous day work update",
                      prompts: ["Scheduled automation: daily-update"], actions: [.pushed]),
        ])

        let candidates = DayDigestOverviewGenerator.agentSessionCandidates(evidence)

        XCTAssertEqual(candidates.map(\.task), ["Fix digest freshness (LokalBot)"],
                       "sessions without an outcome, and scheduled runs, are left to the model")
        XCTAssertEqual(candidates.first?.status, "completed", "a recorded release settles the status")
    }

    func testAScheduledRunsReportNeverReachesTheModel() throws {
        var scheduled = try burst(
            "S", start: "2026-09-29T09:00:00Z", end: "2026-09-29T09:05:00Z",
            prompts: ["Scheduled automation: daily-update"])
        scheduled.finalReply = "Sep 28th: integrated fee-share and merged PR #357."

        let text = scheduled.evidenceText(calendar: calendar)

        XCTAssertTrue(scheduled.isScheduledRun)
        XCTAssertFalse(text.contains("Sep 28th"), text)
        XCTAssertTrue(text.contains("Scheduled run: its report is omitted"), text)
    }

    // MARK: - Fixtures

    private actor PromptRecorder {
        private(set) var focusPrompts: [String] = []
        func record(_ prompt: String) { focusPrompts.append(prompt) }
    }

    private struct RecordingEngine: TextEngine {
        let recorder: PromptRecorder
        var displayName: String { "recording-test" }

        func generate(system: String, prompt: String, context: [String]) async throws -> String { "unused" }

        func generate(system: String, prompt: String, context: [String],
                      schema: [String: Any], options: TextGenerationOptions) async throws -> String {
            if system == PromptTemplates.dayDigestFocusSystem {
                await recorder.record(prompt)
                return """
                    {"substantive":true,"task":"Keep the digest badge fresh","work_done":"Opened a pull request that keeps the digest badge fresh.","status":"in_progress","outcome":"A pull request is open.","next_step":"","source_ids":[]}
                    """
            }
            return """
                {"tasks":[{"title":"Keep the digest badge fresh","status":"in_progress","summary":"Opened a pull request that keeps the digest badge fresh.","next_step":"","block_indices":[0]}],"decisions":[],"blockers":[]}
                """
        }
    }

    /// Answers every segment with the first task and the recap with `digestTasks`.
    private struct StubEngine: TextEngine {
        let digestTasks: [(title: String, summary: String)]
        var displayName: String { "stub-test" }

        func generate(system: String, prompt: String, context: [String]) async throws -> String { "unused" }

        func generate(system: String, prompt: String, context: [String],
                      schema: [String: Any], options: TextGenerationOptions) async throws -> String {
            func json(_ object: Any) throws -> String {
                String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
            }
            guard system != PromptTemplates.dayDigestFocusSystem else {
                return try json([
                    "substantive": true, "task": digestTasks[0].title, "work_done": digestTasks[0].summary,
                    "status": "in_progress", "outcome": "", "next_step": "", "source_ids": [Int](),
                ] as [String: Any])
            }
            return try json([
                "tasks": digestTasks.map {
                    ["title": $0.title, "status": "in_progress", "summary": $0.summary,
                     "next_step": "", "block_indices": [0]] as [String: Any]
                },
                "decisions": [String](), "blockers": [String](),
            ] as [String: Any])
        }
    }

    /// Bursts read the way the transcript readers produce them, so an
    /// untitled session is labeled with its first request or the placeholder.
    private func session(
        _ id: String,
        agent: CodingAgentKind = .claudeCode,
        title: String? = nil,
        folder: String,
        at start: String,
        prompts: [String] = [],
        actions: [CodingAgentAction] = [],
        pullRequests: [Int] = []
    ) throws -> [CodingAgentBurst] {
        var at = try date(start)
        var events: [CodingAgentEvent] = []
        for prompt in prompts {
            events.append(CodingAgentEvent(at: at, kind: .prompt(prompt)))
            at = at.addingTimeInterval(60)
        }
        for action in actions {
            events.append(CodingAgentEvent(at: at, kind: .action(action)))
            at = at.addingTimeInterval(60)
        }
        for number in pullRequests {
            events.append(CodingAgentEvent(
                at: at, kind: .pullRequest("https://github.com/stevyhacker/LokalBot/pull/\(number)")))
        }
        return CodingAgentBurstBuilder.bursts(from: CodingAgentTranscript(
            agent: agent, sessionID: id, title: title, workingDirectory: folder, events: events))
    }

    private func build(
        blocks: [ActivityBlock] = [], contexts: [DayScreenContext] = [], bursts: [CodingAgentBurst]
    ) -> DayDigestEvidence {
        DayDigestEvidence.build(
            day: day, blocks: blocks, screenContexts: contexts, meetings: [],
            codingAgentBursts: bursts, calendar: calendar)
    }

    private func burst(
        _ session: String,
        start: String,
        end: String,
        title: String = "Fix digest freshness",
        project: String = "LokalBot",
        prompts: [String] = ["Fix the stale digest badge"],
        actions: [CodingAgentAction] = [],
        pullRequests: [String] = []
    ) throws -> CodingAgentBurst {
        let startDate = try date(start)
        let endDate = try date(end)
        return CodingAgentBurst(
            agent: .claudeCode, sessionID: session, title: title, project: project,
            branch: "claude/fix-badge", start: startDate, end: endDate,
            activeDuration: endDate.timeIntervalSince(startDate),
            prompts: prompts, promptCount: prompts.count, finalReply: "Done.",
            changedFiles: ["LokalBot/Views/DayDigestCard.swift"], changedFileCount: 1,
            actions: actions, pullRequests: pullRequests, toolCallCount: 3)
    }

    private func date(_ value: String) throws -> Date {
        try XCTUnwrap(ISO8601DateFormatter().date(from: value), value)
    }
}
