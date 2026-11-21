import SQLite3
import XCTest
@testable import LokalBot

final class CodingAgentSessionTests: XCTestCase {
    private var root: URL!
    private var calendar: Calendar!
    private var day: Date!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodingAgentSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        day = try utc("2026-09-29T12:00:00Z")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Claude Code

    func testClaudeReaderKeepsRequestsRepliesEditsAndActionsButNeverToolOutput() throws {
        try writeClaudeSession("S1", lines: claudeWorkday, created: "2026-09-29T08:00:00Z")

        let bursts = scan().bursts

        XCTAssertEqual(bursts.count, 2, "an idle gap over ten minutes starts a new burst")
        let first = try XCTUnwrap(bursts.first)
        XCTAssertEqual(first.agent, .claudeCode)
        XCTAssertEqual(first.title, "Fix digest freshness")
        XCTAssertEqual(first.project, "LokalBot")
        XCTAssertEqual(first.branch, "claude/fix-badge")
        XCTAssertEqual(first.prompts, ["Fix the stale digest badge. Use [REDACTED_TOKEN]"])
        XCTAssertEqual(first.finalReply, "Opened the PR and pushed.")
        XCTAssertEqual(first.changedFiles, ["LokalBot/Views/DayDigestCard.swift"])
        XCTAssertEqual(first.actions, [
            .commit(message: "Keep the digest badge fresh"),
            .pushed,
            .openedPullRequest(title: "Keep the digest badge fresh"),
        ])
        XCTAssertEqual(first.pullRequests, ["https://github.com/stevyhacker/LokalBot/pull/118"])
        XCTAssertEqual(first.start, try utc("2026-09-29T09:00:00Z"))
        XCTAssertEqual(first.end, try utc("2026-09-29T09:20:00Z"))
        XCTAssertEqual(first.activeDuration, 15 * 60, "the ten-minute wait counts as five")
        XCTAssertEqual(first.toolCallCount, 3)

        let second = try XCTUnwrap(bursts.last)
        XCTAssertEqual(second.prompts, ["/code-review high", "Ran in terminal: git push"])
        XCTAssertEqual(second.actions, [.pushed])
        XCTAssertTrue(second.pullRequests.isEmpty, "a link re-emitted while idle joins no burst")

        let evidence = bursts.map { $0.evidenceText(calendar: calendar) }.joined(separator: "\n")
        for leaked in [
            "FILE CONTENTS", "private plan", "SECRET OUTPUT", "ignore me", "ghp_",
            "meta stuff", "sidechain.swift", "yesterday's request", "Caveat", "/fast",
        ] {
            XCTAssertFalse(evidence.contains(leaked), "leaked \(leaked)")
        }
    }

    func testClaudeForkCreditsCopiedHistoryToTheOriginalSession() throws {
        let original = [
            claudeUser(uuid: "u10", at: "2026-09-29T08:00:00Z", text: "Original request"),
            claudeAssistantText(uuid: "a10", at: "2026-09-29T08:01:00Z", text: "Original reply"),
        ]
        try writeClaudeSession("ORIGINAL", lines: original, created: "2026-09-28T08:00:00Z")
        try writeClaudeSession(
            "FORK",
            lines: original + [
                #"{"type":"custom-title","customTitle":"Original (fork)","sessionId":"FORK"}"#,
                claudeUser(uuid: "u11", at: "2026-09-29T08:30:00Z", text: "Fork-only request"),
            ],
            created: "2026-09-29T08:20:00Z")

        let bursts = scan().bursts

        XCTAssertEqual(bursts.map(\.sessionID), ["ORIGINAL", "FORK"])
        XCTAssertEqual(bursts.first?.prompts, ["Original request"])
        XCTAssertEqual(bursts.last?.prompts, ["Fork-only request"])
        XCTAssertEqual(bursts.last?.title, "Original (fork)")
    }

    func testCacheReparsesOnlyChangedFilesAndStillDropsANewForksCopies() throws {
        let original = [
            claudeUser(uuid: "u10", at: "2026-09-29T08:00:00Z", text: "Original request"),
            claudeAssistantText(uuid: "a10", at: "2026-09-29T08:01:00Z", text: "Original reply"),
        ]
        try writeClaudeSession("ORIGINAL", lines: original, created: "2026-09-28T08:00:00Z")
        let reader = ClaudeCodeSessionReader(root: root.appendingPathComponent("claude"))
        let cache = CodingAgentParseCache()

        let first = reader.transcripts(in: dayInterval, cache: cache)
        let unchanged = reader.transcripts(in: dayInterval, cache: cache)
        XCTAssertEqual(first.filesRead, 1)
        XCTAssertEqual(unchanged.filesRead, 0, "an unchanged file is reused, not parsed")
        XCTAssertEqual(unchanged.transcripts, first.transcripts)

        // The fork arrives after the original was cached; its copied
        // history must still be credited to the original.
        try writeClaudeSession(
            "FORK",
            lines: original + [claudeUser(uuid: "u11", at: "2026-09-29T08:30:00Z", text: "Fork-only request")],
            created: "2026-09-29T08:20:00Z")
        let withFork = reader.transcripts(in: dayInterval, cache: cache)

        XCTAssertEqual(withFork.filesRead, 1, "only the new file is parsed")
        let bursts = withFork.transcripts.flatMap { CodingAgentBurstBuilder.bursts(from: $0) }
        XCTAssertEqual(bursts.map(\.prompts), [["Original request"], ["Fork-only request"]])
    }

    /// 2026-10-31: every refresh re-parsed each transcript still being written
    /// in full, and every new day re-parsed the whole window.
    func testARefreshParsesOnlyAppendedBytesAndMatchesAFullRead() throws {
        let reader = ClaudeCodeSessionReader(root: root.appendingPathComponent("claude"))
        let cache = CodingAgentParseCache()
        let file = root.appendingPathComponent("claude/-Users-me-Code-LokalBot/S1.jsonl")
        var parsed = 0
        for count in [3, 7, claudeWorkday.count] {
            let text = claudeWorkday.prefix(count).joined(separator: "\n") + "\n"
            try writeText(text, to: file, created: "2026-09-29T08:00:00Z", modified: "2026-09-29T20:00:00Z")

            let refreshed = reader.transcripts(in: dayInterval, cache: cache)

            XCTAssertEqual(refreshed.filesRead, 1)
            XCTAssertEqual(refreshed.bytesRead, text.utf8.count - parsed, "only the appended bytes are parsed")
            XCTAssertEqual(refreshed.transcripts, reader.transcripts(in: dayInterval).transcripts)
            parsed = text.utf8.count
        }
        let unchanged = reader.transcripts(in: dayInterval, cache: cache)
        XCTAssertEqual(unchanged.filesRead, 0)
        XCTAssertEqual(unchanged.bytesRead, 0)
        XCTAssertEqual(unchanged.transcripts, reader.transcripts(in: dayInterval).transcripts)
    }

    func testALineStillBeingWrittenIsReadAgainOnceComplete() throws {
        let reader = ClaudeCodeSessionReader(root: root.appendingPathComponent("claude"))
        let cache = CodingAgentParseCache()
        let file = root.appendingPathComponent("claude/-Users-me-Code-LokalBot/S1.jsonl")
        let complete = claudeWorkday.prefix(5).joined(separator: "\n") + "\n"
        let pending = claudeWorkday[5]
        func write(_ text: String) throws {
            try writeText(text, to: file, created: "2026-09-29T08:00:00Z", modified: "2026-09-29T20:00:00Z")
        }

        try write(complete + pending.prefix(60))
        let torn = reader.transcripts(in: dayInterval, cache: cache)
        XCTAssertEqual(torn.transcripts, reader.transcripts(in: dayInterval).transcripts)

        try write(complete + pending)
        let unterminated = reader.transcripts(in: dayInterval, cache: cache)
        XCTAssertEqual(unterminated.bytesRead, pending.utf8.count, "the unfinished line is read again")
        XCTAssertEqual(unterminated.transcripts, reader.transcripts(in: dayInterval).transcripts)

        try write(complete + pending + "\n")
        let terminated = reader.transcripts(in: dayInterval, cache: cache)
        XCTAssertEqual(terminated.bytesRead, pending.utf8.count + 1)
        XCTAssertEqual(terminated.transcripts, unterminated.transcripts, "a final line without its newline still counts")
        let commit = CodingAgentEvent.Kind.action(.commit(message: "Keep the digest badge fresh"))
        XCTAssertEqual(terminated.transcripts.first?.events.contains { $0.kind == commit }, true)
        XCTAssertNotEqual(torn.transcripts, terminated.transcripts)
    }

    func testANewDayReusesTheCacheAndAWiderWindowOrRewrittenFileReparses() throws {
        try write(labeledSession, to: root.appendingPathComponent("claude/-Users-me-Code-LokalBot/S1.jsonl"),
                  created: "2026-09-29T08:00:00Z", modified: "2026-09-30T10:05:00Z")
        let scanner = CodingAgentSessionScanner(
            readers: [ClaudeCodeSessionReader(root: root.appendingPathComponent("claude"))])
        let cache = CodingAgentParseCache()
        let first = try utc("2026-09-29T00:00:00Z"), second = try utc("2026-09-30T00:00:00Z")
        func scan(_ start: Date, _ end: Date, cache: CodingAgentParseCache?) -> CodingAgentDayScan {
            scanner.scan(from: start, through: end, calendar: calendar, cache: cache)
        }

        let window = scan(first, second, cache: cache)
        let nextDay = scan(second, second, cache: cache)
        XCTAssertGreaterThan(window.bytesRead, 0)
        XCTAssertEqual(nextDay.filesRead, 0, "a window moving to the next day parses nothing again")
        XCTAssertEqual(nextDay.bursts, scan(second, second, cache: nil).bursts)

        let reachingBack = scan(first, second, cache: cache)
        XCTAssertEqual(reachingBack.bytesRead, window.bytesRead, "days the cache no longer holds are parsed again")
        XCTAssertEqual(reachingBack.bursts, window.bursts)

        // The agent rewrites the file instead of appending to it.
        try write(Array(labeledSession.suffix(2)) + labeledSession.prefix(4),
                  to: root.appendingPathComponent("claude/-Users-me-Code-LokalBot/S1.jsonl"),
                  created: "2026-09-29T08:00:00Z", modified: "2026-09-30T11:00:00Z")
        let rewritten = scan(first, second, cache: cache)
        XCTAssertEqual(rewritten.bytesRead, window.bytesRead, "a file whose earlier bytes changed is parsed again")
        XCTAssertEqual(rewritten.bursts, scan(first, second, cache: nil).bursts)
    }

    func testRecordsInOneFolderShareOneLabel() throws {
        var summary = ClaudeCodeSessionSummary()
        summary.consume(
            CodingAgentJSONLines(data: Data((claudeWorkday.joined(separator: "\n") + "\n").utf8)),
            retainingFrom: dayInterval.start)

        XCTAssertEqual(summary.labels, [.init(workingDirectory: "/Users/me/Code/LokalBot", branch: "claude/fix-badge")])
        XCTAssertGreaterThan(summary.records.count, 10)
    }

    func testCompactingActivityNeverChangesABurst() throws {
        let start = try utc("2026-09-29T09:00:00Z")
        var events = [CodingAgentEvent(at: start, kind: .prompt("Build it"))]
        // Tool results every 20 s for four minutes, a 7-minute wait, more
        // results, then an idle gap long enough to start a new burst.
        for second in stride(from: 20, through: 240, by: 20) {
            events.append(CodingAgentEvent(at: start.addingTimeInterval(TimeInterval(second)), kind: .activity))
        }
        events.append(CodingAgentEvent(at: start.addingTimeInterval(660), kind: .activity))
        events.append(CodingAgentEvent(at: start.addingTimeInterval(680), kind: .reply("Built.")))
        events.append(CodingAgentEvent(at: start.addingTimeInterval(690), kind: .pullRequest("https://github.com/o/r/pull/1")))
        events.append(CodingAgentEvent(at: start.addingTimeInterval(2_000), kind: .activity))
        events.append(CodingAgentEvent(at: start.addingTimeInterval(2_010), kind: .fileChange("A.swift")))
        let transcript = CodingAgentTranscript(agent: .codex, sessionID: "T", events: events)
        var compacted = transcript
        compacted.events = CodingAgentBurstBuilder.compactingActivity(events)

        XCTAssertLessThan(compacted.events.count, events.count)
        XCTAssertEqual(CodingAgentBurstBuilder.bursts(from: compacted), CodingAgentBurstBuilder.bursts(from: transcript))
    }

    /// A saved burst must not change when the session goes on past midnight.
    func testCompactingKeepsADaysLastEventWhateverFollowsMidnight() throws {
        let request = try utc("2026-09-29T23:57:00Z")
        let events = [
            CodingAgentEvent(at: request, kind: .prompt("Ship it")),
            CodingAgentEvent(at: request.addingTimeInterval(120), kind: .activity),
            CodingAgentEvent(at: request.addingTimeInterval(240), kind: .reply("Shipped.")),
        ]
        func firstDay(_ events: [CodingAgentEvent]) -> [CodingAgentBurst] {
            CodingAgentBurstBuilder.bursts(from: CodingAgentTranscript(
                agent: .codex, sessionID: "T",
                events: events.filter { calendar.isDate($0.at, inSameDayAs: request) }))
        }

        let compacted = CodingAgentBurstBuilder.compactingActivity(events, calendar: calendar)

        XCTAssertEqual(firstDay(compacted), firstDay(events))
        XCTAssertEqual(firstDay(compacted).first?.end, request.addingTimeInterval(120))
    }

    /// 2026-10-20 and 21: a session's folder and branch were read across the
    /// whole scan window, so a session that moved on relabeled the work it
    /// had saved on earlier days, and each relabel rebuilt those days' digests.
    func testClaudeBurstsAreLabeledByTheirOwnRecordsWhateverTheScanWindow() throws {
        try write(labeledSession, to: root.appendingPathComponent("claude/-Users-me-Code-LokalBot/S1.jsonl"),
           created: "2026-09-29T08:00:00Z", modified: "2026-09-30T10:05:00Z")
        let scanner = CodingAgentSessionScanner(
            readers: [ClaudeCodeSessionReader(root: root.appendingPathComponent("claude"))])
        let first = try utc("2026-09-29T00:00:00Z"), second = try utc("2026-09-30T00:00:00Z")

        let window = scanner.scan(from: first, through: second, calendar: calendar).bursts

        XCTAssertEqual(window.map(\.branch), ["claude/fix-badge", "claude/release-notes", "mojo-branding"])
        XCTAssertEqual(window.map(\.project), ["LokalBot", "LokalBot", "Mojo"])
        XCTAssertEqual(window.last?.changedFiles, ["Sources/Theme.swift"])
        XCTAssertEqual(scanner.scan(from: first, through: first, calendar: calendar).bursts, Array(window.prefix(2)),
                       "later work never relabels an earlier day")
        XCTAssertEqual(scanner.scan(from: second, through: second, calendar: calendar).bursts, [window[2]],
                       "a window that starts later labels the same work the same way")
    }

    func testSessionThatReadTheLokalBotLibraryWithholdsReplies() throws {
        try writeClaudeSession("S2", lines: [
            claudeUser(uuid: "u1", at: "2026-09-29T10:00:00Z", text: "What did I promise Ana?"),
            #"{"parentUuid":"u1","isSidechain":false,"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"mcp__lokalbot__search_meetings","input":{"query":"Ana"}}]},"uuid":"a1","timestamp":"2026-09-29T10:00:10.000Z","cwd":"/Users/me/Code/LokalBot","sessionId":"S2"}"#,
            claudeAssistantText(uuid: "a2", at: "2026-09-29T10:01:00Z", text: "You promised Ana the budget by Friday."),
        ], created: "2026-09-29T09:00:00Z")

        let burst = try XCTUnwrap(scan().bursts.first)

        XCTAssertEqual(burst.prompts, ["What did I promise Ana?"])
        XCTAssertNil(burst.finalReply, "a reply may restate library content")
    }

    // MARK: - Codex

    func testCodexReaderFindsResumedRolloutAndSkipsSubagentsAndStaleFiles() throws {
        let codex = root.appendingPathComponent("codex", isDirectory: true)
        try write(
            codexResumedRollout,
            to: codex.appendingPathComponent("sessions/2026/09/03/rollout-2026-09-03T10-00-00-T1.jsonl"),
            created: "2026-09-03T10:00:00Z", modified: "2026-09-29T18:00:00Z")
        try write(
            [
                #"{"timestamp":"2026-09-29T14:10:00.000Z","type":"session_meta","payload":{"id":"G1","cwd":"/Users/me/Code/Mojo","source":{"subagent":{"other":"guardian"}}}}"#,
                #"{"timestamp":"2026-09-29T14:10:01.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Review this approval"}]}}"#,
            ],
            to: codex.appendingPathComponent("sessions/2026/09/29/rollout-2026-09-29T14-10-00-G1.jsonl"),
            created: "2026-09-29T14:10:00Z", modified: "2026-09-29T14:11:00Z")
        try write(
            [#"{"timestamp":"2026-09-20T09:00:00.000Z","type":"session_meta","payload":{"id":"OLD","cwd":"/tmp","source":"cli"}}"#],
            to: codex.appendingPathComponent("sessions/2026/09/20/rollout-2026-09-20T09-00-00-OLD.jsonl"),
            created: "2026-09-20T09:00:00Z", modified: "2026-09-20T09:30:00Z")
        try write(
            [
                #"{"id":"T1","thread_name":"Update app branding","updated_at":"2026-09-03T10:00:00Z"}"#,
                #"{"id":"T1","thread_name":"Update Mojo branding","updated_at":"2026-09-29T14:00:00Z"}"#,
            ],
            to: codex.appendingPathComponent("session_index.jsonl"),
            created: "2026-09-03T10:00:00Z", modified: "2026-09-29T14:00:00Z")

        let result = CodexSessionReader(root: codex).transcripts(in: dayInterval)
        let bursts = result.transcripts.flatMap { CodingAgentBurstBuilder.bursts(from: $0) }

        XCTAssertEqual(result.filesRead, 2, "a rollout untouched since before the day is never opened")
        XCTAssertEqual(bursts.count, 1, "the guardian subagent is not the person's session")
        let burst = try XCTUnwrap(bursts.first)
        XCTAssertEqual(burst.agent, .codex)
        XCTAssertEqual(burst.sessionID, "T1")
        XCTAssertEqual(burst.title, "Update Mojo branding")
        XCTAssertEqual(burst.project, "Mojo")
        XCTAssertEqual(burst.branch, "stevyhacker/mojo-branding")
        XCTAssertEqual(burst.prompts, ["Apply Mojo branding across the app"])
        XCTAssertEqual(
            burst.changedFiles, ["Sources/Theme.swift", "Sources/Logo.swift", "Sources/Colors.swift"])
        XCTAssertEqual(burst.actions, [
            .commit(message: "feat: apply Mojo branding across the app"),
            .pushed,
            .openedPullRequest(title: "feat: apply Mojo branding across the app"),
        ])
        XCTAssertEqual(burst.finalReply, "Opened localhostinc/app PR #186 with the branding.")
        XCTAssertEqual(burst.toolCallCount, 2)

        let evidence = burst.evidenceText(calendar: calendar)
        for leaked in [
            "old request", "developer instructions", "AGENTS.md", "environment_context",
            "Open tabs", "NEVER KEPT", "hidden reasoning",
        ] {
            XCTAssertFalse(evidence.contains(leaked), "leaked \(leaked)")
        }
    }

    func testCodexRefreshParsesOnlyAppendedBytesAndPicksUpRenames() throws {
        let codex = root.appendingPathComponent("codex", isDirectory: true)
        let rollout = codex.appendingPathComponent("sessions/2026/09/03/rollout-2026-09-03T10-00-00-T1.jsonl")
        let index = codex.appendingPathComponent("session_index.jsonl")
        let reader = CodexSessionReader(root: codex)
        let cache = CodingAgentParseCache()
        var parsed = 0
        for (count, names) in [(5, ["Update app branding"]), (codexResumedRollout.count, ["Update app branding", "Update Mojo branding"])] {
            let text = codexResumedRollout.prefix(count).joined(separator: "\n") + "\n"
            try writeText(text, to: rollout, created: "2026-09-03T10:00:00Z", modified: "2026-09-29T18:00:00Z")
            try write(names.map { #"{"id":"T1","thread_name":"\#($0)"}"# }, to: index,
                      created: "2026-09-03T10:00:00Z", modified: "2026-09-29T18:00:00Z")

            let refreshed = reader.transcripts(in: dayInterval, cache: cache)

            XCTAssertEqual(refreshed.bytesRead, text.utf8.count - parsed, "only the appended bytes are parsed")
            XCTAssertEqual(refreshed.transcripts, reader.transcripts(in: dayInterval).transcripts)
            XCTAssertEqual(refreshed.transcripts.map(\.title), [names.last])
            parsed = text.utf8.count
        }
    }

    // MARK: - Codex, compressed

    func testCodexReaderReadsCompressedRolloutsLikePlainOnes() throws {
        let name = "sessions/2026/09/03/rollout-2026-09-03T10-00-00-T1.jsonl"
        let plain = root.appendingPathComponent("plain", isDirectory: true)
        let packed = root.appendingPathComponent("packed", isDirectory: true)
        try write(codexResumedRollout, to: plain.appendingPathComponent(name),
                  created: "2026-09-03T10:00:00Z", modified: "2026-09-29T18:00:00Z")
        let text = codexResumedRollout.joined(separator: "\n") + "\n"
        // Compressing gives the file the creation date of its last write.
        try writeCompressed(text, to: packed.appendingPathComponent(name + ".zst"),
                            created: "2026-09-29T18:00:00Z", modified: "2026-09-29T18:00:00Z")
        let expected = CodexSessionReader(root: plain).transcripts(in: dayInterval).transcripts
        let reader = CodexSessionReader(root: packed)
        let cache = CodingAgentParseCache()

        let first = reader.transcripts(in: dayInterval, cache: cache)
        let again = reader.transcripts(in: dayInterval, cache: cache)

        XCTAssertFalse(expected.isEmpty)
        XCTAssertEqual(first.transcripts, expected)
        XCTAssertEqual(first.filesRead, 1)
        XCTAssertEqual(first.bytesRead, text.utf8.count, "the decompressed size is what was read")
        XCTAssertTrue(first.unreadableFiles.isEmpty)
        XCTAssertEqual(again.transcripts, expected)
        XCTAssertEqual(again.filesRead, 0, "an unchanged compressed rollout is not decompressed again")
    }

    func testCompressedRolloutCountsOnTheDayItBeganThoughCompressedTheNextDay() throws {
        let codex = root.appendingPathComponent("codex", isDirectory: true)
        try writeCompressed(
            [
                #"{"timestamp":"2026-09-29T23:00:00.000Z","type":"session_meta","payload":{"id":"N1","cwd":"/Users/me/Code/Mojo","source":"cli"}}"#,
                #"{"timestamp":"2026-09-29T23:00:01.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Ship the night build"}]}}"#,
                #"{"timestamp":"2026-09-30T01:00:00.000Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Shipped."}]}}"#,
            ].joined(separator: "\n") + "\n",
            to: codex.appendingPathComponent("sessions/2026/09/29/rollout-2026-09-29T23-00-00-N1.jsonl.zst"),
            created: "2026-09-30T01:05:00Z", modified: "2026-09-30T01:05:00Z")

        let result = CodexSessionReader(root: codex).transcripts(in: dayInterval)

        XCTAssertEqual(result.transcripts.map(\.sessionID), ["N1"])
    }

    func testRolloutKeptPlainAndCompressedIsReadOnceFromTheNewerCopy() throws {
        let codex = root.appendingPathComponent("codex", isDirectory: true)
        let rollout = codex.appendingPathComponent("sessions/2026/09/03/rollout-2026-09-03T10-00-00-T1.jsonl")
        try write(codexResumedRollout, to: rollout, created: "2026-09-03T10:00:00Z", modified: "2026-09-29T18:00:00Z")
        try writeCompressed(
            codexResumedRollout.prefix(5).joined(separator: "\n") + "\n",
            to: rollout.appendingPathExtension("zst"),
            created: "2026-09-29T17:00:00Z", modified: "2026-09-29T17:00:00Z")

        let result = CodexSessionReader(root: codex).transcripts(in: dayInterval)

        XCTAssertEqual(result.filesRead, 1)
        XCTAssertEqual(result.transcripts.map(\.sessionID), ["T1"])
        XCTAssertEqual(
            result.bytesRead, (codexResumedRollout.joined(separator: "\n") + "\n").utf8.count,
            "the plain copy, written last, is the one read")
    }

    func testDecompressionHandsOverWholeLinesAcrossFramesAndBuffers() throws {
        // Lines longer than the decoder's 4 MiB output buffer, split over many frames.
        let lines = [
            String(repeating: "a", count: 3 << 20), "{\"short\":1}",
            String(repeating: "b", count: 5 << 20), "", "{\"short\":2}\r",
            String(repeating: "c", count: 3 << 20), "last line without a newline",
        ]
        let text = lines.joined(separator: "\n")
        let file = root.appendingPathComponent("rollout-2026-09-29T10-00-00-X.jsonl.zst")
        try writeCompressed(text, to: file, created: "2026-09-29T10:00:00Z", modified: "2026-09-29T10:00:00Z")

        var read: [String] = []
        var batches = 0
        let total = try CodingAgentCompressedTranscript.forEachBatch(of: file) { batch in
            batches += 1
            batch.forEach { read.append(String(decoding: $0.bytes, as: UTF8.self)) }
        }

        XCTAssertEqual(total, text.utf8.count)
        XCTAssertGreaterThan(batches, 1, "the file is handed over a piece at a time")
        XCTAssertEqual(read, lines.filter { !$0.isEmpty })

        let whole = try Data(contentsOf: file)
        try whole.dropLast(100).write(to: file)
        XCTAssertThrowsError(try CodingAgentCompressedTranscript.forEachBatch(of: file) { _ in },
                             "a file cut off inside a frame is unreadable")
    }

    func testCompressedRolloutStartsNoLaterThanTheDayInItsName() throws {
        let url = URL(fileURLWithPath: "/x/sessions/2026/09/29/rollout-2026-09-29T23-00-00-N1.jsonl.zst")
        XCTAssertTrue(CodingAgentCompressedTranscript.isCompressed(url))
        XCTAssertEqual(CodingAgentCompressedTranscript.plainPath(of: url), "/x/sessions/2026/09/29/rollout-2026-09-29T23-00-00-N1.jsonl")
        XCTAssertEqual(CodingAgentCompressedTranscript.startBound(of: url), try utc("2026-09-28T00:00:00Z"))
        XCTAssertEqual(CodingAgentCompressedTranscript.startBound(of: URL(fileURLWithPath: "/x/other.jsonl.zst")), .distantPast)
        XCTAssertFalse(CodingAgentCompressedTranscript.isCompressed(URL(fileURLWithPath: "/x/notes.zst")))
    }

    // MARK: - Antigravity

    func testAntigravityReaderKeepsWorkSkipsThinkingAndDeduplicatesAcrossRoots() throws {
        let ag = root.appendingPathComponent("antigravity", isDirectory: true)
        let agCLI = root.appendingPathComponent("antigravity-cli", isDirectory: true)
        let transcriptURL = ag.appendingPathComponent("brain/conv-1/.system_generated/logs/transcript.jsonl")
        let lines = [
            #"{"step_index":0,"source":"USER_EXPLICIT","type":"USER_INPUT","created_at":"2026-09-29T09:00:00.000Z","content":"<USER_REQUEST>\nAdd Antigravity support with ghp_abcdefghijklmnopqrstuvwx1234\n</USER_REQUEST>\n<ADDITIONAL_METADATA>\n{\"os\":\"mac\"}\n</ADDITIONAL_METADATA>"}"#,
            #"{"step_index":1,"source":"SYSTEM","type":"USER_INPUT","created_at":"2026-09-29T09:00:30.000Z","content":"System reminder should stay activity"}"#,
            #"{"step_index":2,"source":"MODEL","type":"PLANNER_RESPONSE","created_at":"2026-09-29T09:01:00.000Z","#
                + #""thinking":"PRIVATE REASONING NEVER KEPT","content":"Editing the files now.","tool_calls":["#
                + #"{"name":"run_command","args":{"Cwd":"\"/Users/me/Code/LokalBot\"","#
                + #""CommandLine":"\"swift test && git commit -m 'Add Antigravity' && git push\""}},"#
                + #"{"name":"edit_file","args":{"Path":"\"/Users/me/Code/LokalBot/LokalBot/Reader.swift\""}},"#
                + #"{"name":"write_file","args":{"Path":"\"/Users/me/.gemini/antigravity/brain/conv-1/plan.md\""}},"#
                + #"{"name":"mcp_t3-code_pull_request_create","args":{"title":"\"Add Antigravity reader\""}},"#
                + #"{"name":"mcp_t3-code_link_pull_request","args":{"url":"\"https://github.com/stevyhacker/LokalBot/pull/501\""}}]}"#,
            #"{"step_index":3,"source":"TOOL","type":"TOOL_RESULT","created_at":"2026-09-29T09:02:00.000Z","content":"TOOL OUTPUT NEVER KEPT"}"#,
            #"{"step_index":4,"source":"MODEL","type":"PLANNER_RESPONSE","created_at":"2026-09-29T09:05:00.000Z","thinking":"MORE SECRET THOUGHTS","content":"Added Antigravity support and opened PR #501."}"#,
        ]
        try write(lines, to: transcriptURL, created: "2026-09-29T09:00:00Z", modified: "2026-09-29T09:05:00Z")
        try writeText(
            #"title: "Add Antigravity \"support\"""# + "\n",
            to: ag.appendingPathComponent("annotations/conv-1.pbtxt"),
            created: "2026-09-29T09:00:00Z", modified: "2026-09-29T09:05:00Z")
        // Full transcript must never be read.
        try writeText(
            "FULL TRANSCRIPT SECRET CONTENT\n",
            to: ag.appendingPathComponent("brain/conv-1/.system_generated/logs/transcript_full.jsonl"),
            created: "2026-09-29T09:00:00Z", modified: "2026-09-29T09:05:00Z")
        // Older copy in a second Antigravity root is deduplicated away.
        try write(
            [#"{"step_index":0,"source":"USER_EXPLICIT","type":"USER_INPUT","created_at":"2026-09-29T08:00:00.000Z","content":"<USER_REQUEST>\nOlder duplicate\n</USER_REQUEST>"}"#],
            to: agCLI.appendingPathComponent("brain/conv-1/.system_generated/logs/transcript.jsonl"),
            created: "2026-09-29T08:00:00Z", modified: "2026-09-29T08:05:00Z")

        let reader = AntigravitySessionReader(roots: [ag, agCLI])
        let cache = CodingAgentParseCache()
        let first = reader.transcripts(in: dayInterval, cache: cache)
        let again = reader.transcripts(in: dayInterval, cache: cache)

        XCTAssertEqual(first.filesRead, 1, "older duplicate in another root is not read")
        XCTAssertEqual(again.filesRead, 0, "unchanged file is reused from cache")
        XCTAssertEqual(again.transcripts, first.transcripts)

        let bursts = first.transcripts.flatMap { CodingAgentBurstBuilder.bursts(from: $0) }
        XCTAssertEqual(bursts.count, 1)
        let burst = try XCTUnwrap(bursts.first)
        XCTAssertEqual(burst.agent, .antigravity)
        XCTAssertEqual(burst.sessionID, "conv-1")
        XCTAssertEqual(burst.title, #"Add Antigravity "support""#)
        XCTAssertEqual(burst.project, "LokalBot")
        XCTAssertEqual(burst.prompts, ["Add Antigravity support with [REDACTED_TOKEN]"])
        XCTAssertEqual(burst.changedFiles, ["LokalBot/Reader.swift"])
        XCTAssertEqual(burst.actions, [
            .commit(message: "Add Antigravity"),
            .pushed,
            .ranTests,
            .openedPullRequest(title: "Add Antigravity reader"),
        ])
        XCTAssertEqual(burst.pullRequests, ["https://github.com/stevyhacker/LokalBot/pull/501"])
        XCTAssertEqual(burst.finalReply, "Added Antigravity support and opened PR #501.")
        XCTAssertEqual(burst.toolCallCount, 5)

        let evidence = burst.evidenceText(calendar: calendar)
        for leaked in [
            "PRIVATE REASONING", "MORE SECRET THOUGHTS", "TOOL OUTPUT NEVER KEPT",
            "FULL TRANSCRIPT SECRET", "Older duplicate", "System reminder", "plan.md", "ghp_",
        ] {
            XCTAssertFalse(evidence.contains(leaked), "leaked \(leaked)")
        }

        // Incremental append only reads the newly appended bytes.
        let extra = #"{"step_index":5,"source":"USER_EXPLICIT","type":"USER_INPUT","created_at":"2026-09-29T09:06:00.000Z","content":"<USER_REQUEST>\nFollow up\n</USER_REQUEST>"}"#
        try write(lines + [extra], to: transcriptURL, created: "2026-09-29T09:00:00Z", modified: "2026-09-29T09:06:00Z")
        let appended = reader.transcripts(in: dayInterval, cache: cache)
        XCTAssertEqual(appended.filesRead, 1)
        XCTAssertEqual(appended.bytesRead, extra.utf8.count + 1)
        XCTAssertEqual(appended.transcripts, reader.transcripts(in: dayInterval).transcripts)
    }

    func testAntigravityInfersProjectAndWithholdsRepliesAfterLokalBotAccess() throws {
        let ag = root.appendingPathComponent("antigravity", isDirectory: true)
        try write(
            [
                #"{"step_index":0,"source":"USER_EXPLICIT","type":"USER_INPUT","created_at":"2026-09-29T10:00:00.000Z","content":"<USER_REQUEST>\nCheck what Ana asked and update Theme\n</USER_REQUEST>"}"#,
                #"{"step_index":1,"source":"MODEL","type":"PLANNER_RESPONSE","created_at":"2026-09-29T10:01:00.000Z","tool_calls":[{"name":"read_file","args":{"Path":"\"/Users/me/.gemini/antigravity/brain/conv-2/notes.md\""}},{"name":"edit_file","args":{"Path":"\"/Users/me/Code/Mojo/Sources/Theme.swift\""}},{"name":"run_command","args":{"CommandLine":"\"lokalbot-cli search Ana\""}}]}"#,
                #"{"step_index":2,"source":"MODEL","type":"PLANNER_RESPONSE","created_at":"2026-09-29T10:02:00.000Z","content":"Ana asked for dark mode, updated Theme.swift."}"#,
            ],
            to: ag.appendingPathComponent("brain/conv-2/.system_generated/logs/transcript.jsonl"),
            created: "2026-09-29T10:00:00Z", modified: "2026-09-29T10:02:00Z")

        let bursts = AntigravitySessionReader(root: ag).transcripts(in: dayInterval)
            .transcripts.flatMap { CodingAgentBurstBuilder.bursts(from: $0) }
        let burst = try XCTUnwrap(bursts.first)
        XCTAssertEqual(burst.project, "Mojo")
        XCTAssertEqual(burst.changedFiles, ["Sources/Theme.swift"])
        XCTAssertNil(burst.finalReply, "replies are withheld after LokalBot CLI access")
    }

    // MARK: - T3 Code

    func testT3CodeV2ReaderDeduplicatesNativeSessionsSkipsSubagentsAndRespectsExclusions() throws {
        let t3Root = root.appendingPathComponent("t3-userdata", isDirectory: true)
        let dbURL = t3Root.appendingPathComponent("statev2.sqlite")
        try buildT3V2Database(at: dbURL)
        try FileManager.default.setAttributes(
            [.modificationDate: try utc("2026-09-29T12:00:00Z")], ofItemAtPath: dbURL.path)

        // Native Claude & Codex sessions: one owned by T3 Code and one standalone each.
        try writeClaudeSession("CLAUDE_OWNED", lines: [
            claudeUser(uuid: "co1", at: "2026-09-29T09:00:00Z", text: "Owned by T3 Code"),
            claudeAssistantText(uuid: "co2", at: "2026-09-29T09:01:00Z", text: "Handled via T3."),
        ], created: "2026-09-29T09:00:00Z")
        try writeClaudeSession("CLAUDE_STANDALONE", lines: [
            claudeUser(uuid: "cs1", at: "2026-09-29T11:00:00Z", text: "Standalone Claude work"),
            claudeAssistantText(uuid: "cs2", at: "2026-09-29T11:01:00Z", text: "Done."),
        ], created: "2026-09-29T11:00:00Z")
        let codex = root.appendingPathComponent("codex", isDirectory: true)
        try write(
            [
                #"{"timestamp":"2026-09-29T09:05:00.000Z","type":"session_meta","payload":{"id":"CODEX_SUBAGENT","cwd":"/Users/me/Code/LokalBot","source":"vscode"}}"#,
                #"{"timestamp":"2026-09-29T09:05:01.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Delegated Codex review"}]}}"#,
            ],
            to: codex.appendingPathComponent("sessions/2026/09/29/rollout-2026-09-29T09-05-00-CODEX_SUBAGENT.jsonl"),
            created: "2026-09-29T09:05:00Z", modified: "2026-09-29T09:06:00Z")
        try write(
            [
                #"{"timestamp":"2026-09-29T11:30:00.000Z","type":"session_meta","payload":{"id":"CODEX_STANDALONE","cwd":"/Users/me/Code/Mojo","source":"cli"}}"#,
                #"{"timestamp":"2026-09-29T11:30:01.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Standalone Codex work"}]}}"#,
            ],
            to: codex.appendingPathComponent("sessions/2026/09/29/rollout-2026-09-29T11-30-00-CODEX_STANDALONE.jsonl"),
            created: "2026-09-29T11:30:00Z", modified: "2026-09-29T11:31:00Z")

        let scanner = CodingAgentSessionScanner(
            readers: [
                ClaudeCodeSessionReader(root: root.appendingPathComponent("claude")),
                CodexSessionReader(root: codex),
                T3CodeSessionReader(root: t3Root),
            ],
            excludedFolders: ["/Users/me/Code/SecretClient"])

        let result = scanner.scan(day: day, calendar: calendar)

        XCTAssertEqual(result.excludedSessions, 1, "T3 Code session in excluded workspace_root is dropped")
        XCTAssertEqual(
            Set(result.bursts.map(\.sessionID)),
            ["t-main", "t-lokalbot", "CLAUDE_STANDALONE", "CODEX_STANDALONE"],
            "claimed native Claude and delegated Codex transcripts are deduplicated")

        let main = try XCTUnwrap(result.bursts.first { $0.sessionID == "t-main" })
        XCTAssertEqual(main.agent, .t3Code)
        XCTAssertEqual(main.title, "Wire T3 Code sessions")
        XCTAssertEqual(main.project, "LokalBot")
        XCTAssertEqual(main.branch, "t3/wire-sessions")
        XCTAssertEqual(main.prompts, ["Add T3 Code session support", "Scheduled task: Nightly audit"])
        XCTAssertEqual(main.changedFiles, ["LokalBot/T3Reader.swift"])
        XCTAssertEqual(main.actions, [
            .commit(message: "Add T3 reader"),
            .pushed,
            .openedPullRequest(title: "Add T3 Code reader"),
        ])
        XCTAssertEqual(main.pullRequests, ["https://github.com/stevyhacker/LokalBot/pull/612"])
        XCTAssertEqual(main.finalReply, "Added T3 Code support and opened PR #612.")
        XCTAssertEqual(main.toolCallCount, 3)

        let consulted = try XCTUnwrap(result.bursts.first { $0.sessionID == "t-lokalbot" })
        XCTAssertEqual(consulted.prompts, ["Summarize what we found"])
        XCTAssertNil(consulted.finalReply, "LokalBot access on an earlier day still withholds today's replies")

        let evidence = result.bursts.map { $0.evidenceText(calendar: calendar) }.joined(separator: "\n")
        for leaked in [
            "SECRET COMMAND OUTPUT", "SECRET DIFF", "SECRET REASONING", "SECRET AUTH TOKEN",
            "Delegated task node", "Subagent prompt", "Deleted thread prompt", "Client secret work",
        ] {
            XCTAssertFalse(evidence.contains(leaked), "leaked \(leaked)")
        }

        // Disabling T3 Code lets the native Claude & Codex readers report those sessions normally.
        let withoutT3 = CodingAgentSessionScanner(readers: [
            ClaudeCodeSessionReader(root: root.appendingPathComponent("claude")),
            CodexSessionReader(root: codex),
        ]).scan(day: day, calendar: calendar)
        XCTAssertEqual(
            Set(withoutT3.bursts.map(\.sessionID)),
            ["CLAUDE_OWNED", "CLAUDE_STANDALONE", "CODEX_SUBAGENT", "CODEX_STANDALONE"])
    }

    func testT3CodeV1FallbackAndCorruptDatabaseHandling() throws {
        let t3Root = root.appendingPathComponent("t3-v1", isDirectory: true)
        let v1URL = t3Root.appendingPathComponent("state.sqlite")
        try buildT3V1Database(at: v1URL)
        try FileManager.default.setAttributes(
            [.modificationDate: try utc("2026-09-29T12:00:00Z")], ofItemAtPath: v1URL.path)

        let v1Result = T3CodeSessionReader(root: t3Root).transcripts(in: dayInterval)
        XCTAssertTrue(v1Result.unreadableFiles.isEmpty)
        XCTAssertEqual(v1Result.claimedSessions, [CodingAgentSessionKey(agent: .claudeCode, sessionID: "V1_CLAUDE")])
        let burst = try XCTUnwrap(v1Result.transcripts.flatMap { CodingAgentBurstBuilder.bursts(from: $0) }.first)
        XCTAssertEqual(burst.agent, .t3Code)
        XCTAssertEqual(burst.sessionID, "t-v1")
        XCTAssertEqual(burst.title, "Legacy T3 session")
        XCTAssertEqual(burst.project, "Mojo")
        XCTAssertEqual(burst.prompts, ["Fix legacy layout"])
        XCTAssertEqual(burst.pullRequests, ["https://github.com/stevyhacker/Mojo/pull/9"])
        XCTAssertEqual(burst.finalReply, "Fixed legacy layout.")

        let corruptURL = t3Root.appendingPathComponent("statev2.sqlite")
        try writeText("not a sqlite file", to: corruptURL, created: "2026-09-29T09:00:00Z", modified: "2026-09-29T12:00:00Z")
        let withCorrupt = T3CodeSessionReader(root: t3Root).transcripts(in: dayInterval)
        XCTAssertEqual(withCorrupt.unreadableFiles, [corruptURL.path])
        XCTAssertEqual(withCorrupt.transcripts.map(\.sessionID), ["t-v1"])
    }

    // MARK: - Scanner and bursts

    func testScannerDropsSessionsInsideExcludedFolders() throws {
        try writeClaudeSession("S1", lines: claudeWorkday, created: "2026-09-29T08:00:00Z")
        let scanner = CodingAgentSessionScanner(
            readers: [ClaudeCodeSessionReader(root: root.appendingPathComponent("claude"))],
            excludedFolders: ["/Users/me/Code/"])

        let result = scanner.scan(day: day, calendar: calendar)

        XCTAssertTrue(result.bursts.isEmpty)
        XCTAssertEqual(result.excludedSessions, 1)
        XCTAssertFalse(scanner.isExcluded("/Users/me/CodeReview"), "a sibling folder is not inside it")
    }

    func testBurstWithoutRequestsContinuesEarlierWorkAndPingsAloneAreDropped() throws {
        let transcript = CodingAgentTranscript(
            agent: .codex, sessionID: "T9", workingDirectory: "/Users/me/Code/App",
            events: [
                CodingAgentEvent(at: try utc("2026-09-29T08:00:00Z"), kind: .activity),
                CodingAgentEvent(at: try utc("2026-09-29T09:00:00Z"), kind: .fileChange("App.swift")),
                CodingAgentEvent(at: try utc("2026-09-29T09:01:00Z"), kind: .activity),
            ])

        let bursts = CodingAgentBurstBuilder.bursts(from: transcript)

        XCTAssertEqual(bursts.count, 1)
        XCTAssertEqual(bursts.first?.title, "Untitled session")
        XCTAssertTrue(bursts.first?.evidenceText(calendar: calendar)
            .contains("Requests: continued work from an earlier request") == true)
    }

    func testWorkTitleNamesTheWorkWhenTheTitleIsARequestOrPlaceholder() {
        XCTAssertEqual(workBurst(title: "Fix digest freshness", prompts: ["Fix the stale digest badge"]).workTitle,
                       "Fix digest freshness", "a transcript title names the work")
        let asked = "can you add short video demo recording of the new app platforms in the PR?"
        XCTAssertEqual(
            workBurst(title: asked, prompts: [asked], actions: [
                .commit(message: "Temporary: record a Windows demo"),
                .commit(message: "Demo recordings of the Linux and Windows apps."),
            ]).workTitle,
            "Demo recordings of the Linux and Windows apps")
        XCTAssertEqual(
            workBurst(title: "Untitled session", prompts: [], actions: [
                .commit(message: "feat(onchain): map chain ids"),
                .openedPullRequest(title: "feat(onchain): add spoke deploy scripts"),
            ]).workTitle,
            "Add spoke deploy scripts", "an opened pull request names the deliverable")
        XCTAssertEqual(
            workBurst(title: "Untitled session", prompts: [], actions: [.pushed], pullRequests: [279]).workTitle,
            "Work on PR #279")
        let benchmark = "let's commit the benchmark to the repository."
        XCTAssertEqual(workBurst(title: benchmark, prompts: [benchmark], actions: [.pushed]).workTitle,
                       "Commit the benchmark to the repository")
        XCTAssertEqual(workBurst(title: "Review all open PRs", prompts: ["Review all open PRs"]).workTitle,
                       "Review all open PRs", "a short instruction is a work title")
        let wake = #"<wake reason="mention" current-time="2026-10-19T09:39:51Z"> <project…"#
        XCTAssertEqual(workBurst(title: wake, prompts: [], actions: [.ranTests]).workTitle, "Claude Code session")
        let question = "is it necessary to use this local aligner if i'm using a cloud transcription model?"
        XCTAssertEqual(workBurst(title: question, prompts: [question], actions: [.ranTests]).workTitle,
                       "Claude Code session", "a question names no work")
    }

    func testWorkProjectIsTheRepositoryForScratchCheckoutAndSiblingFolders() {
        XCTAssertEqual(workBurst(project: "scratch-2026-10-19-6f7eb7", pullRequests: [293]).workProject, "LokalBot")
        XCTAssertNil(workBurst(project: "scratch-2026-10-19-6f7eb7").workProject)
        XCTAssertEqual(workBurst(project: "GitHub", pullRequests: [290]).workProject, "LokalBot")
        XCTAssertNil(workBurst(project: "Unknown project").workProject)
        XCTAssertEqual(workBurst(project: "LokalBot-linux-windows", pullRequests: [290]).workProject, "LokalBot")
        XCTAssertEqual(workBurst(project: "LokalBot-linux-windows").workProject, "LokalBot-linux-windows")
        XCTAssertEqual(workBurst(project: "Mojo", pullRequests: [290]).workProject, "Mojo",
                       "a named project keeps its name")
        var twoRepositories = workBurst(project: "GitHub")
        twoRepositories.pullRequests = [
            "https://github.com/stevyhacker/LokalBot/pull/1", "https://github.com/stevyhacker/bizstats/pull/2",
        ]
        XCTAssertNil(twoRepositories.workProject, "pull requests in two repositories name no single project")
    }

    func testEvidenceTextNamesTheRepositoryAndLeavesOutARequestTitle() {
        let asked = "can you add short video demo recording of the new app platforms in the PR?"
        let text = workBurst(title: asked, project: "GitHub", prompts: [asked], pullRequests: [290])
            .evidenceText(calendar: calendar)

        XCTAssertFalse(text.contains("Session:"), text)
        XCTAssertTrue(text.contains("Project: LokalBot (branch master)"), text)
        XCTAssertTrue(text.contains("- \(asked)"), "the request is still a request: \(text)")
    }

    func testEvidenceTextLeadsWithWorkAndLabelsTheReportAsAClaim() throws {
        let burst = CodingAgentBurst(
            agent: .claudeCode, sessionID: "1ac1dcdf-d832", title: "README improvements",
            project: "LokalBot", branch: "master",
            start: try utc("2026-09-29T06:50:00Z"), end: try utc("2026-09-29T07:00:00Z"),
            activeDuration: 540, prompts: ["a", "b", "c", "d", "e"], promptCount: 7,
            finalReply: "Opened PR #107.", changedFiles: ["README.md"], changedFileCount: 3,
            actions: [.mergedPullRequest(number: 110), .mergedPullRequest(number: nil)],
            pullRequests: ["https://github.com/stevyhacker/LokalBot/pull/107"], toolCallCount: 20)

        XCTAssertEqual(burst.evidenceText(calendar: calendar), """
            WORK SOURCE: AGENT SESSION [agent:claude-code:1ac1dcdf]
            Agent: Claude Code
            Session: README improvements
            Project: LokalBot (branch master)
            Requests:
            - a
            - b
            - c
            - d
            - (+3 more)
            Changed files (3): README.md, +2 more
            Recorded actions: merged PR #110; merged PR
            Pull requests: https://github.com/stevyhacker/LokalBot/pull/107
            Agent's final report (a claim; corroborate with actions): Opened PR #107.
            LOW-PRIORITY TRACE METADATA — do not summarize directly:
            06:50–07:00; active=9m; tool_calls=20
            """)
    }

    // MARK: - Text rules

    func testPromptKeepsOnlyWhatThePersonWrote() {
        XCTAssertEqual(
            CodingAgentText.prompt("<system-reminder>ctx</system-reminder>\nShip it"), "Ship it")
        XCTAssertEqual(
            CodingAgentText.prompt("# Context from my IDE setup:\n## Active file: a.swift\n## My request for Codex:\nRename it"),
            "Rename it")
        XCTAssertEqual(
            CodingAgentText.prompt("Summarize <pasted_content id=\"1\">long log</pasted_content id=\"1\"> please"),
            "Summarize [pasted text] please")
        XCTAssertEqual(
            CodingAgentText.prompt("<command-message>code-review</command-message>\n<command-name>/code-review</command-name>\n<command-args>high</command-args>"),
            "/code-review high")
        XCTAssertNil(CodingAgentText.prompt("<command-name>/fast</command-name>\n<command-args>on</command-args>"))
        XCTAssertEqual(
            CodingAgentText.prompt("<scheduled-task name=\"disk-check\" file=\"/x/SKILL.md\">\nAutomated run…"),
            "Scheduled task: disk-check")
        XCTAssertEqual(
            CodingAgentText.prompt("<heartbeat>\n  <automation_id>daily-update</automation_id>\n</heartbeat>"),
            "Scheduled automation: daily-update")
        XCTAssertEqual(
            CodingAgentText.prompt("<bash-input>ls -la</bash-input><bash-stdout>secret.txt</bash-stdout><bash-stderr></bash-stderr>"),
            "Ran in terminal: ls -la")
        XCTAssertEqual(
            CodingAgentText.prompt("<launch-selected-element><text>page</text></launch-selected-element>\nMake this bigger"),
            "Make this bigger")
        XCTAssertEqual(CodingAgentText.prompt("Style the <div> and <span> tags"), "Style the <div> and <span> tags")
        XCTAssertNil(CodingAgentText.prompt("<environment_context>\n  <cwd>/x</cwd>\n</environment_context>"))
        XCTAssertNil(CodingAgentText.prompt("<turn_aborted>"))
        XCTAssertNil(CodingAgentText.prompt("Caveat: The messages below were generated by the user"))
        XCTAssertEqual(
            CodingAgentText.prompt("deploy with password: hunter2hunter2"), "deploy with password: [REDACTED]")
        XCTAssertEqual(
            CodingAgentText.prompt("""
                <USER_REQUEST>
                Add Antigravity reader
                </USER_REQUEST>
                <ADDITIONAL_METADATA>
                {"cwd":"/Users/me/Code/App"}
                </ADDITIONAL_METADATA>
                """),
            "Add Antigravity reader")
        XCTAssertEqual(
            CodingAgentText.prompt("<USER_REQUEST>\n<t3_code_instructions>rules</t3_code_instructions>\n<user_request>\nShip T3 Code\n</user_request>\n</USER_REQUEST>"),
            "Ship T3 Code")
        XCTAssertEqual(
            CodingAgentText.prompt("<USER_REQUEST>\nTruncated prompt without closing tag"),
            "Truncated prompt without closing tag")
    }

    func testActionsAreParsedFromTheCommandsTheAgentRan() {
        XCTAssertEqual(
            CodingAgentText.actions(inCommand: """
                git add -A && git commit -m "$(cat <<'EOF'
                Keep the digest badge fresh

                Longer body.
                EOF
                )" && git push -u origin HEAD
                """),
            [.commit(message: "Keep the digest badge fresh"), .pushed])
        XCTAssertEqual(
            CodingAgentText.actions(inCommand: #"git -C repo commit -am "Fix \"quoted\" title""#),
            [.commit(message: #"Fix "quoted" title"#)])
        XCTAssertEqual(
            CodingAgentText.actions(inCommand: "gh pr create --draft -t 'Add films' --body x"),
            [.openedPullRequest(title: "Add films")])
        XCTAssertEqual(
            CodingAgentText.actions(inCommand: "gh pr merge 110 --squash; gh pr merge https://github.com/o/r/pull/7; gh pr merge --auto"),
            [.mergedPullRequest(number: 110), .mergedPullRequest(number: 7), .mergedPullRequest(number: nil)])
        XCTAssertEqual(CodingAgentText.actions(inCommand: "gh release create v0.9.2 dist/x.dmg"), [.release(tag: "v0.9.2")])
        XCTAssertEqual(
            CodingAgentText.actions(inCommand: "xcodebuild -scheme LokalBot -destination 'platform=macOS' test"),
            [.ranTests])
        XCTAssertEqual(
            CodingAgentText.actions(inCommand: #"["/bin/zsh","-lc","npm run test && git push"]"#),
            [.pushed, .ranTests])
        // The UI-test runner moved to Scripts/test/; older sessions still name the old path.
        XCTAssertEqual(CodingAgentText.actions(inCommand: "Scripts/test/ui-tests.sh --remote"), [.ranTests])
        XCTAssertEqual(CodingAgentText.actions(inCommand: "bash Scripts/ui-tests.sh --remote"), [.ranTests])
        XCTAssertEqual(CodingAgentText.actions(inCommand: "git status && git log --oneline"), [])
        XCTAssertTrue(CodingAgentText.readsLokalBot(command: "lokalbot search 'budget'"))
        XCTAssertTrue(CodingAgentText.readsLokalBot(command: "/Applications/LokalBot.app/Contents/Helpers/lokalbot-cli list"))
        XCTAssertFalse(CodingAgentText.readsLokalBot(command: "cd ~/Code/LokalBot && swift build"))
    }

    func testChangedFilesAreNamedRelativeToTheProject() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        XCTAssertEqual(
            CodingAgentText.displayPath("/Users/me/Code/App/Sources/A.swift", workingDirectory: "/Users/me/Code/App"),
            "Sources/A.swift")
        XCTAssertEqual(
            CodingAgentText.displayPath(
                "/Users/me/Code/App/.claude/worktrees/fix-badge/Sources/A.swift", workingDirectory: "/Users/me/Code/App"),
            "Sources/A.swift")
        XCTAssertEqual(
            CodingAgentText.displayPath("/Users/me/.codex/worktrees/f2bb/Colony/web/page.tsx", workingDirectory: nil),
            "web/page.tsx")
        XCTAssertEqual(
            CodingAgentText.displayPath("/Users/me/.t3/worktrees/LokalBot/t3-abc/Sources/A.swift", workingDirectory: nil),
            "Sources/A.swift")
        XCTAssertEqual(
            CodingAgentText.displayPath(
                "/private/tmp/claude-501/-Users-me-Code-App/1ac1dcdf-d832-4204-904b-f3e4e9a6f33c/scratchpad/x/team.html",
                workingDirectory: "/Users/me/Code/App"),
            "scratchpad/x/team.html")
        XCTAssertEqual(
            CodingAgentText.displayPath(home + "/Notes/plan.md", workingDirectory: "/Users/me/Code/App"),
            "~/Notes/plan.md")
        XCTAssertEqual(
            CodingAgentBurstBuilder.projectName(for: "/Users/me/Code/LokalBot/.claude/worktrees/agent-session-evidence"),
            "LokalBot")
        XCTAssertEqual(
            CodingAgentBurstBuilder.projectName(for: "/Users/me/.t3/worktrees/LokalBot/t3-abc"),
            "LokalBot")
        XCTAssertEqual(CodingAgentBurstBuilder.projectName(for: nil), "Unknown project")
    }

    func testTimestampsParseBothAgentsFormats() throws {
        let reference = try utc("2026-09-29T14:46:12Z")
        XCTAssertEqual(CodingAgentTimestamp.date("2026-09-29T14:46:12Z"), reference)
        XCTAssertEqual(
            try XCTUnwrap(CodingAgentTimestamp.date("2026-09-29T14:46:12.824Z")).timeIntervalSince(reference),
            0.824, accuracy: 0.0001)
        XCTAssertEqual(
            try XCTUnwrap(CodingAgentTimestamp.date("2026-09-29T20:02:50.291977Z")).timeIntervalSince1970,
            try utc("2026-09-29T20:02:50Z").timeIntervalSince1970 + 0.291977, accuracy: 0.0001)
        XCTAssertEqual(CodingAgentTimestamp.date("2026-09-29T16:46:12+02:00"), reference)
        XCTAssertEqual(CodingAgentTimestamp.date("2024-02-29T00:00:00Z"), try utc("2024-02-29T00:00:00Z"))
        XCTAssertNil(CodingAgentTimestamp.date("yesterday"))
    }

    func testHeadlessAgentSessionsFlag() throws {
        XCTAssertEqual(HeadlessCommand.parse(["LokalBot", "--agent-sessions"]), .agentSessions(dayKey: nil))
        XCTAssertEqual(
            HeadlessCommand.parse(["LokalBot", "--agent-sessions", "2026-09-29"]),
            .agentSessions(dayKey: "2026-09-29"))
        XCTAssertEqual(HeadlessCommand.parse(["LokalBot", "--agent", "hi"]), .agent(prompt: "hi"))
        XCTAssertEqual(CodingAgentSessionsCLI.run(dayKey: "2026-02-30"), 2)

        let empty = CodingAgentDayScan(
            interval: dayInterval, bursts: [], sessionCount: 0, filesRead: 3, bytesRead: 2_500_000,
            unreadableFiles: ["/x/broken.jsonl"], excludedSessions: 1)
        XCTAssertEqual(
            CodingAgentSessionsCLI.render(empty, day: day, elapsed: 0.42, calendar: calendar),
            """
            Unreadable transcript: /x/broken.jsonl

            LokalBot --agent-sessions: 2026-09-29 — 0 sessions, 0 bursts, 0 evidence chars from 3 files (2 MB) in 0.4s; 1 excluded
            """)
    }

    // MARK: - Fixtures

    private func workBurst(
        title: String = "Fix digest freshness",
        project: String = "LokalBot",
        prompts: [String] = ["Fix the stale digest badge"],
        actions: [CodingAgentAction] = [.pushed],
        pullRequests: [Int] = []
    ) -> CodingAgentBurst {
        CodingAgentBurst(
            agent: .claudeCode, sessionID: "W1", title: title, project: project, branch: "master",
            start: day, end: day.addingTimeInterval(600), activeDuration: 600,
            prompts: prompts, promptCount: prompts.count, finalReply: nil,
            changedFiles: [], changedFileCount: 0, actions: actions,
            pullRequests: pullRequests.map { "https://github.com/stevyhacker/LokalBot/pull/\($0)" },
            toolCallCount: 1)
    }

    private var dayInterval: DateInterval {
        DateInterval(start: calendar.startOfDay(for: day), duration: 86_400)
    }

    private func scan() -> CodingAgentDayScan {
        CodingAgentSessionScanner(readers: [ClaudeCodeSessionReader(root: root.appendingPathComponent("claude"))])
            .scan(day: day, calendar: calendar)
    }

    private var claudeWorkday: [String] {
        [
            #"{"type":"custom-title","customTitle":"Fix digest freshness","sessionId":"S1"}"#,
            claudeUser(uuid: "u0", at: "2026-09-28T23:59:00Z", text: "yesterday's request"),
            claudeUser(
                uuid: "u1", at: "2026-09-29T09:00:00Z",
                text: "<system-reminder>ignore me</system-reminder>Fix the stale digest badge. Use ghp_abcdefghijklmnopqrstuvwx1234"),
            #"{"parentUuid":"u1","isSidechain":false,"type":"assistant","message":{"role":"assistant","content":[{"type":"thinking","thinking":"private plan"},{"type":"text","text":"Fixing the badge now."},"#
                + #"{"type":"tool_use","id":"t1","name":"Edit","input":{"file_path":"/Users/me/Code/LokalBot/LokalBot/Views/DayDigestCard.swift","old_string":"a","new_string":"b"}}]},"#
                + #""uuid":"a1","timestamp":"2026-09-29T09:01:00.000Z","cwd":"/Users/me/Code/LokalBot","gitBranch":"claude/fix-badge","sessionId":"S1"}"#,
            #"{"parentUuid":"a1","isSidechain":false,"type":"user","message":{"role":"user","content":[{"tool_use_id":"t1","type":"tool_result","content":"FILE CONTENTS SHOULD NEVER APPEAR"}]},"uuid":"r1","timestamp":"2026-09-29T09:02:00.000Z","cwd":"/Users/me/Code/LokalBot","sessionId":"S1"}"#,
            #"{"parentUuid":"r1","isSidechain":false,"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"t2","name":"Bash","#
                + #""input":{"command":"git add -A && git commit -m \"$(cat <<'EOF'\nKeep the digest badge fresh\n\nBody\nEOF\n)\" && git push","description":"Commit"}}]},"#
                + #""uuid":"a2","timestamp":"2026-09-29T09:05:00.000Z","cwd":"/Users/me/Code/LokalBot","gitBranch":"claude/fix-badge","sessionId":"S1"}"#,
            #"{"parentUuid":"a2","isSidechain":false,"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"t3","name":"Bash","input":{"command":"gh pr create --draft --title \"Keep the digest badge fresh\" --body \"x\""}}]},"uuid":"a3","timestamp":"2026-09-29T09:10:00.000Z","cwd":"/Users/me/Code/LokalBot","gitBranch":"claude/fix-badge","sessionId":"S1"}"#,
            claudeAssistantText(uuid: "a4", at: "2026-09-29T09:20:00Z", text: "Opened the PR and pushed."),
            #"{"type":"pr-link","sessionId":"S1","prNumber":118,"prUrl":"https://github.com/stevyhacker/LokalBot/pull/118","prRepository":"stevyhacker/LokalBot","timestamp":"2026-09-29T09:20:30.000Z"}"#,
            claudeUser(
                uuid: "u2", at: "2026-09-29T11:00:00Z",
                text: "<command-message>code-review</command-message>\n<command-name>/code-review</command-name>\n<command-args>high</command-args>"),
            claudeAssistantText(uuid: "a5", at: "2026-09-29T11:01:00Z", text: "No findings."),
            claudeUser(uuid: "u3", at: "2026-09-29T11:05:00Z", text: "<command-name>/fast</command-name>\n<command-args>on</command-args>"),
            #"{"parentUuid":"u3","isSidechain":false,"isMeta":true,"type":"user","message":{"role":"user","content":"meta stuff"},"uuid":"m1","timestamp":"2026-09-29T11:06:00.000Z","cwd":"/Users/me/Code/LokalBot","sessionId":"S1"}"#,
            #"{"parentUuid":"m1","isSidechain":true,"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"t4","name":"Write","input":{"file_path":"/Users/me/Code/LokalBot/sidechain.swift","content":"x"}}]},"uuid":"s1","timestamp":"2026-09-29T11:07:00.000Z","cwd":"/Users/me/Code/LokalBot","sessionId":"S1"}"#,
            claudeUser(uuid: "u4", at: "2026-09-29T11:08:00Z", text: "Caveat: The messages below were generated by the user while running local commands."),
            claudeUser(
                uuid: "u5", at: "2026-09-29T11:10:00Z",
                text: "<bash-input>git push</bash-input><bash-stdout>Everything up-to-date SECRET OUTPUT</bash-stdout><bash-stderr></bash-stderr>"),
            #"{"type":"pr-link","sessionId":"S1","prNumber":118,"prUrl":"https://github.com/stevyhacker/LokalBot/pull/119","prRepository":"stevyhacker/LokalBot","timestamp":"2026-09-29T13:00:00.000Z"}"#,
            "{not json",
            #"{"type":"some-future-record","payload":{"x":1}}"#,
        ]
    }

    private var labeledSession: [String] {
        let app = "/Users/me/Code/LokalBot", mojo = "/Users/me/Code/Mojo"
        return [
            claudeUser(uuid: "u1", at: "2026-09-29T09:00:00Z", text: "Fix the stale digest badge"),
            claudeAssistantText(uuid: "a1", at: "2026-09-29T09:05:00Z", text: "Fixed the badge."),
            claudeUser(uuid: "u2", at: "2026-09-29T15:00:00Z", text: "Draft the release notes",
                       cwd: app, branch: "claude/release-notes"),
            claudeAssistantText(uuid: "a2", at: "2026-09-29T15:05:00Z", text: "Drafted them.",
                                cwd: app, branch: "claude/release-notes"),
            claudeUser(uuid: "u3", at: "2026-09-30T10:00:00Z", text: "Apply the Mojo branding",
                       cwd: mojo, branch: "mojo-branding"),
            #"{"parentUuid":"u3","isSidechain":false,"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Edit","input":{"file_path":"/Users/me/Code/Mojo/Sources/Theme.swift","old_string":"a","new_string":"b"}}]},"#
                + claudeTrailer(uuid: "a3", at: "2026-09-30T10:05:00Z", cwd: mojo, branch: "mojo-branding"),
        ]
    }

    private var codexResumedRollout: [String] {
        [
            #"{"timestamp":"2026-09-03T10:00:00.000Z","type":"session_meta","payload":{"id":"T1","timestamp":"2026-09-03T10:00:00.000Z","cwd":"/Users/me/Code/Mojo","originator":"Codex Desktop","source":"vscode","git":{"branch":"stevyhacker/mojo-branding","commit_hash":"abc"}}}"#,
            #"{"timestamp":"2026-09-03T10:00:05.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"old request from September 3"}]}}"#,
            #"{"timestamp":"2026-09-29T14:00:00.000Z","type":"response_item","payload":{"type":"message","role":"developer","content":[{"type":"input_text","text":"developer instructions"}]}}"#,
            ##"{"timestamp":"2026-09-29T14:00:01.000Z","type":"response_item","payload":{"type":"message","role":"user","content":["##
                + ##"{"type":"input_text","text":"# AGENTS.md instructions for /Users/me/Code/Mojo\n\n<INSTRUCTIONS>rules</INSTRUCTIONS>"},"##
                + ##"{"type":"input_text","text":"<environment_context>\n  <cwd>/Users/me/Code/Mojo</cwd>\n</environment_context>"},"##
                + ##"{"type":"input_text","text":"# Context from my IDE setup:\n\n## Open tabs:\n- a.swift\n\n## My request:\nApply Mojo branding across the app"}]}}"##,
            #"{"timestamp":"2026-09-29T14:00:02.000Z","type":"response_item","payload":{"type":"reasoning","summary":[],"content":null,"encrypted_content":"hidden reasoning"}}"#,
            #"{"timestamp":"2026-09-29T14:02:00.000Z","type":"response_item","payload":{"type":"custom_tool_call","status":"completed","call_id":"c1","name":"apply_patch","input":"*** Begin Patch\n*** Update File: /Users/me/Code/Mojo/Sources/Theme.swift\n@@\n-old\n+new\n*** Add File: /Users/me/Code/Mojo/Sources/Logo.swift\n+new\n*** End Patch"}}"#,
            #"{"timestamp":"2026-09-29T14:02:01.000Z","type":"response_item","payload":{"type":"custom_tool_call_output","call_id":"c1","output":"PATCH OUTPUT NEVER KEPT"}}"#,
            #"{"timestamp":"2026-09-29T14:03:00.000Z","type":"event_msg","payload":{"type":"item_completed","thread_id":"T1","turn_id":"x","item":{"type":"Reasoning","id":"r","summary_text":["hidden reasoning"]}}}"#,
            #"{"timestamp":"2026-09-29T14:05:00.000Z","type":"response_item","payload":{"type":"function_call","name":"exec_command","arguments":"{\"cmd\":\"git commit -am 'feat: apply Mojo branding across the app' && git push -u origin HEAD\"}","call_id":"f1"}}"#,
            #"{"timestamp":"2026-09-29T14:05:02.000Z","type":"response_item","payload":{"type":"function_call_output","call_id":"f1","output":"COMMAND OUTPUT NEVER KEPT"}}"#,
            #"{"timestamp":"2026-09-29T14:06:00.000Z","type":"event_msg","payload":{"type":"item_completed","thread_id":"T1","turn_id":"x","item":{"type":"CommandExecution","id":"e1","command":["/bin/zsh","-lc","gh pr create --title \"feat: apply Mojo branding across the app\" --body x"],"aggregated_output":"OUTPUT NEVER KEPT","exit_code":0}}}"#,
            #"{"timestamp":"2026-09-29T14:07:00.000Z","type":"event_msg","payload":{"type":"item_completed","thread_id":"T1","turn_id":"x","item":{"type":"FileChange","id":"fc1","changes":{"/Users/me/Code/Mojo/Sources/Colors.swift":{"type":"update","unified_diff":"DIFF NEVER KEPT"}},"status":"completed"}}}"#,
            #"{"timestamp":"2026-09-29T14:08:00.000Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Opened localhostinc/app PR #186 with the branding."}]}}"#,
        ]
    }

    /// A user record in Claude Code's key order, which the tool-result
    /// fast path depends on.
    private func claudeUser(
        uuid: String, at timestamp: String, text: String,
        cwd: String = "/Users/me/Code/LokalBot", branch: String = "claude/fix-badge"
    ) -> String {
        let prefix = #"{"parentUuid":null,"isSidechain":false,"type":"user","message":{"role":"user","content":"#
        return prefix + json(text) + "}," + claudeTrailer(uuid: uuid, at: timestamp, cwd: cwd, branch: branch)
    }

    private func claudeAssistantText(
        uuid: String, at timestamp: String, text: String,
        cwd: String = "/Users/me/Code/LokalBot", branch: String = "claude/fix-badge"
    ) -> String {
        let prefix = #"{"parentUuid":null,"isSidechain":false,"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"#
        return prefix + json(text) + "}]}," + claudeTrailer(uuid: uuid, at: timestamp, cwd: cwd, branch: branch)
    }

    private func claudeTrailer(
        uuid: String, at timestamp: String,
        cwd: String = "/Users/me/Code/LokalBot", branch: String = "claude/fix-badge"
    ) -> String {
        let millis = timestamp.replacingOccurrences(of: "Z", with: ".000Z")
        return #""uuid":"# + json(uuid) + #","timestamp":"# + json(millis)
            + #","cwd":"# + json(cwd) + #","gitBranch":"# + json(branch) + #","sessionId":"S"}"#
    }

    /// `value` as a quoted JSON string.
    private func json(_ value: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [value])) ?? Data("[\"\"]".utf8)
        return String((String(data: data, encoding: .utf8) ?? "[\"\"]").dropFirst().dropLast())
    }

    private func writeClaudeSession(_ id: String, lines: [String], created: String) throws {
        try write(
            lines,
            to: root.appendingPathComponent("claude/-Users-me-Code-LokalBot/\(id).jsonl"),
            created: created, modified: "2026-09-29T20:00:00Z")
    }

    private func write(_ lines: [String], to url: URL, created: String, modified: String) throws {
        try writeText(lines.joined(separator: "\n") + "\n", to: url, created: created, modified: modified)
    }

    private func writeText(_ text: String, to url: URL, created: String, modified: String) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.creationDate: try utc(created), .modificationDate: try utc(modified)],
            ofItemAtPath: url.path)
    }

    /// Writes `text` as zstd frames of uncompressed blocks, which is what
    /// zstd writes for bytes it cannot shrink. Decoding real compression is
    /// libzstd's own, tested upstream; these frames test the reader around it.
    private func writeCompressed(_ text: String, to url: URL, created: String, modified: String) throws {
        let data = Data(text.utf8)
        let frameSize = 1 << 20
        let blockSize = 1 << 16
        var out = Data()
        var frameStart = 0
        repeat {
            let frameEnd = min(frameStart + frameSize, data.count)
            out.append(contentsOf: [0x28, 0xB5, 0x2F, 0xFD])  // magic number
            out.append(0x00)  // no content size, checksum or dictionary
            out.append(0x38)  // window: 128 KiB
            var blockStart = frameStart
            repeat {
                let blockEnd = min(blockStart + blockSize, frameEnd)
                // A raw block: size, type 0, and whether it is the frame's last.
                let header = UInt32(blockEnd - blockStart) << 3 | (blockEnd == frameEnd ? 1 : 0)
                out.append(contentsOf: [UInt8(header & 0xFF), UInt8(header >> 8 & 0xFF), UInt8(header >> 16 & 0xFF)])
                out.append(data[blockStart..<blockEnd])
                blockStart = blockEnd
            } while blockStart < frameEnd
            frameStart = frameEnd
        } while frameStart < data.count
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try out.write(to: url)
        try FileManager.default.setAttributes(
            [.creationDate: try utc(created), .modificationDate: try utc(modified)],
            ofItemAtPath: url.path)
    }

    private func execSQL(_ sql: String, in url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        var errMsg: UnsafeMutablePointer<CChar>?
        let status = sqlite3_exec(db, sql, nil, nil, &errMsg)
        if status != SQLITE_OK {
            let message = errMsg.map { String(cString: $0) } ?? "sqlite error \(status)"
            sqlite3_free(errMsg)
            XCTFail(message)
        }
    }

    private func buildT3V2Database(at url: URL) throws {
        try execSQL("""
            PRAGMA journal_mode=WAL;
            CREATE TABLE auth_sessions (token TEXT);
            INSERT INTO auth_sessions VALUES ('SECRET AUTH TOKEN');
            CREATE TABLE projection_projects (project_id TEXT PRIMARY KEY, workspace_root TEXT);
            INSERT INTO projection_projects VALUES ('p1', '/Users/me/Code/LokalBot');
            INSERT INTO projection_projects VALUES ('p2', '/Users/me/Code/SecretClient');

            CREATE TABLE orchestration_v2_projection_threads (
                thread_id TEXT PRIMARY KEY, project_id TEXT, title TEXT,
                created_at TEXT, updated_at TEXT, deleted_at TEXT, payload_json TEXT
            );
            INSERT INTO orchestration_v2_projection_threads VALUES (
                't-main', 'p1', 'Wire T3 Code sessions',
                '2026-09-29T09:00:00.000Z', '2026-09-29T09:10:00.000Z', NULL,
                '{"branch":"t3/wire-sessions","worktreePath":"/Users/me/.t3/worktrees/LokalBot/wt-1","pullRequests":[]}'
            );
            INSERT INTO orchestration_v2_projection_threads VALUES (
                't-deleted', 'p1', 'Deleted thread',
                '2026-09-29T09:00:00.000Z', '2026-09-29T09:05:00.000Z', '2026-09-29T09:06:00.000Z', '{}'
            );
            INSERT INTO orchestration_v2_projection_threads VALUES (
                't-sub', 'p1', 'Subagent thread',
                '2026-09-29T09:05:00.000Z', '2026-09-29T09:06:00.000Z', NULL,
                '{"lineage":{"parentThreadId":"t-main","relationshipToParent":"subagent"}}'
            );
            INSERT INTO orchestration_v2_projection_threads VALUES (
                't-excluded', 'p2', 'Client work',
                '2026-09-29T10:00:00.000Z', '2026-09-29T10:05:00.000Z', NULL, '{}'
            );
            INSERT INTO orchestration_v2_projection_threads VALUES (
                't-lokalbot', 'p1', 'Meeting lookup',
                '2026-09-28T10:00:00.000Z', '2026-09-29T10:05:00.000Z', NULL, '{}'
            );

            CREATE TABLE orchestration_v2_projection_messages (
                message_id TEXT PRIMARY KEY, thread_id TEXT, role TEXT,
                created_at TEXT, updated_at TEXT, payload_json TEXT
            );
            INSERT INTO orchestration_v2_projection_messages VALUES (
                'm1', 't-main', 'user', '2026-09-29T09:00:00.000Z', '2026-09-29T09:00:00.000Z',
                '{"text":"Add T3 Code session support","createdBy":"user"}'
            );
            INSERT INTO orchestration_v2_projection_messages VALUES (
                'm2', 't-main', 'user', '2026-09-29T09:01:00.000Z', '2026-09-29T09:01:00.000Z',
                '{"text":"Delegated task node: child finished","createdBy":"agent","creationSource":"server"}'
            );
            INSERT INTO orchestration_v2_projection_messages VALUES (
                'm3', 't-main', 'user', '2026-09-29T09:02:00.000Z', '2026-09-29T09:02:00.000Z',
                '{"text":"Nightly audit","createdBy":"agent","creationSource":"schedule"}'
            );
            INSERT INTO orchestration_v2_projection_messages VALUES (
                'm4', 't-main', 'assistant', '2026-09-29T09:08:00.000Z', '2026-09-29T09:09:00.000Z',
                '{"text":"Added T3 Code support and opened PR #612."}'
            );
            INSERT INTO orchestration_v2_projection_messages VALUES (
                'm5', 't-deleted', 'user', '2026-09-29T09:00:00.000Z', '2026-09-29T09:00:00.000Z',
                '{"text":"Deleted thread prompt"}'
            );
            INSERT INTO orchestration_v2_projection_messages VALUES (
                'm6', 't-sub', 'user', '2026-09-29T09:05:00.000Z', '2026-09-29T09:05:00.000Z',
                '{"text":"Subagent prompt"}'
            );
            INSERT INTO orchestration_v2_projection_messages VALUES (
                'm7', 't-excluded', 'user', '2026-09-29T10:00:00.000Z', '2026-09-29T10:00:00.000Z',
                '{"text":"Client secret work"}'
            );
            INSERT INTO orchestration_v2_projection_messages VALUES (
                'm8', 't-lokalbot', 'user', '2026-09-29T10:00:00.000Z', '2026-09-29T10:00:00.000Z',
                '{"text":"Summarize what we found"}'
            );
            INSERT INTO orchestration_v2_projection_messages VALUES (
                'm9', 't-lokalbot', 'assistant', '2026-09-29T10:02:00.000Z', '2026-09-29T10:02:00.000Z',
                '{"text":"You promised Ana the report."}'
            );

            CREATE TABLE orchestration_v2_projection_turn_items (
                turn_item_id TEXT PRIMARY KEY, thread_id TEXT, type TEXT,
                ordinal INTEGER, updated_at TEXT, payload_json TEXT
            );
            INSERT INTO orchestration_v2_projection_turn_items VALUES (
                'i1', 't-main', 'command_execution', 1, '2026-09-29T09:03:00.000Z',
                '{"startedAt":"2026-09-29T09:03:00.000Z","input":"git commit -m ''Add T3 reader'' && git push","output":"SECRET COMMAND OUTPUT"}'
            );
            INSERT INTO orchestration_v2_projection_turn_items VALUES (
                'i2', 't-main', 'file_change', 2, '2026-09-29T09:04:00.000Z',
                '{"completedAt":"2026-09-29T09:04:00.000Z","changes":[{"path":"/Users/me/.t3/worktrees/LokalBot/wt-1/LokalBot/T3Reader.swift","diff":"SECRET DIFF"}]}'
            );
            INSERT INTO orchestration_v2_projection_turn_items VALUES (
                'i3', 't-main', 'dynamic_tool', 3, '2026-09-29T09:05:00.000Z',
                '{"startedAt":"2026-09-29T09:05:00.000Z","toolName":"pull_request_create","input":{"title":"Add T3 Code reader"}}'
            );
            INSERT INTO orchestration_v2_projection_turn_items VALUES (
                'i4', 't-main', 'reasoning', 4, '2026-09-29T09:06:00.000Z',
                '{"startedAt":"2026-09-29T09:06:00.000Z","text":"SECRET REASONING"}'
            );
            INSERT INTO orchestration_v2_projection_turn_items VALUES (
                'i5', 't-lokalbot', 'dynamic_tool', 1, '2026-09-28T10:01:00.000Z',
                '{"startedAt":"2026-09-28T10:01:00.000Z","toolName":"mcp__lokalbot__search","input":{"query":"Ana"}}'
            );

            CREATE TABLE orchestration_v2_projection_provider_threads (
                provider_thread_id TEXT PRIMARY KEY, driver TEXT, updated_at TEXT, payload_json TEXT
            );
            INSERT INTO orchestration_v2_projection_provider_threads VALUES (
                'pt1', 'claudeAgent', '2026-09-29T09:09:00.000Z',
                '{"createdAt":"2026-09-29T09:00:00.000Z","nativeThreadRef":{"nativeId":"CLAUDE_OWNED"}}'
            );
            INSERT INTO orchestration_v2_projection_provider_threads VALUES (
                'pt2', 'codex', '2026-09-29T09:06:00.000Z',
                '{"createdAt":"2026-09-29T09:05:00.000Z","nativeThreadRef":{"nativeId":"CODEX_SUBAGENT"}}'
            );

            CREATE TABLE projection_thread_pull_requests (
                thread_id TEXT, url TEXT, linked_at TEXT
            );
            INSERT INTO projection_thread_pull_requests VALUES (
                't-main', 'https://github.com/stevyhacker/LokalBot/pull/612', '2026-09-29T09:07:00.000Z'
            );
            """, in: url)
    }

    private func buildT3V1Database(at url: URL) throws {
        try execSQL("""
            CREATE TABLE projection_projects (project_id TEXT PRIMARY KEY, workspace_root TEXT);
            INSERT INTO projection_projects VALUES ('p1', '/Users/me/Code/Mojo');
            CREATE TABLE projection_threads (
                thread_id TEXT PRIMARY KEY, project_id TEXT, title TEXT, branch TEXT, worktree_path TEXT,
                created_at TEXT, updated_at TEXT, deleted_at TEXT
            );
            INSERT INTO projection_threads VALUES (
                't-v1', 'p1', 'Legacy T3 session', 'main', NULL,
                '2026-09-29T08:00:00.000Z', '2026-09-29T08:10:00.000Z', NULL
            );
            CREATE TABLE projection_thread_messages (
                message_id TEXT PRIMARY KEY, thread_id TEXT, role TEXT, text TEXT, created_at TEXT, updated_at TEXT
            );
            INSERT INTO projection_thread_messages VALUES (
                'vm1', 't-v1', 'user', 'Fix legacy layout', '2026-09-29T08:00:00.000Z', '2026-09-29T08:00:00.000Z'
            );
            INSERT INTO projection_thread_messages VALUES (
                'vm2', 't-v1', 'assistant', 'Fixed legacy layout.', '2026-09-29T08:05:00.000Z', '2026-09-29T08:05:00.000Z'
            );
            CREATE TABLE projection_thread_sessions (
                thread_id TEXT, provider_name TEXT, provider_session_id TEXT, provider_thread_id TEXT, updated_at TEXT
            );
            INSERT INTO projection_thread_sessions VALUES (
                't-v1', 'claudeAgent', 'V1_CLAUDE', NULL, '2026-09-29T08:05:00.000Z'
            );
            CREATE TABLE projection_thread_pull_requests (
                thread_id TEXT, url TEXT, linked_at TEXT
            );
            INSERT INTO projection_thread_pull_requests VALUES (
                't-v1', 'https://github.com/stevyhacker/Mojo/pull/9', '2026-09-29T08:06:00.000Z'
            );
            """, in: url)
    }

    private func utc(_ value: String) throws -> Date {
        try XCTUnwrap(ISO8601DateFormatter().date(from: value), value)
    }
}
