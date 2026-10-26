import XCTest
@testable import LokalBot

final class ActionAgentHandoffTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!
    private let meetingID = UUID(uuidString: "1A2B3C4D-0000-4000-8000-000000000001")!
    /// Monday 2026-10-26 14:00 UTC.
    private let startedAt = Date(timeIntervalSince1970: 1_793_023_200)
    private let folder = URL(fileURLWithPath: "/Users/ana/Library/Application Support/LokalBot/meetings/2026/10/26/design-review")

    // MARK: Detection

    func testClaudeCodePrefersItsTerminalLinkThenTheClaudeApp() {
        let both = handlers(["claude-cli", "claude"])
        XCTAssertEqual(ActionAgentHandoff.claudeCode.route(handler: both), .claudeCodeTerminal)
        XCTAssertEqual(ActionAgentHandoff.claudeCode.route(handler: handlers(["claude"])), .claudeDesktop)
        XCTAssertNil(ActionAgentHandoff.claudeCode.route(handler: handlers(["codex"])))
    }

    func testCodexNeedsTheCodexApp() {
        XCTAssertEqual(ActionAgentHandoff.codex.route(handler: handlers(["codex"])), .codexApp)
        XCTAssertNil(ActionAgentHandoff.codex.route(handler: handlers(["claude-cli", "claude"])))
    }

    func testLinksUseEachAgentsDocumentedRoute() throws {
        let prompt = "Hi"
        XCTAssertEqual(ActionAgentHandoff.Route.claudeCodeTerminal.url(prompt: prompt)?.absoluteString,
                       "claude-cli://open?q=Hi")
        XCTAssertEqual(ActionAgentHandoff.Route.claudeDesktop.url(prompt: prompt)?.absoluteString,
                       "claude://code/new?q=Hi")
        XCTAssertEqual(ActionAgentHandoff.Route.codexApp.url(prompt: prompt)?.absoluteString,
                       "codex://new?prompt=Hi")
    }

    /// Paths with spaces, line breaks, `&` and `+` must survive query parsing.
    func testPromptSurvivesQueryParsing() throws {
        let prompt = ActionAgentHandoff.prompt(brief(text: "Ship C++ fix & Q&A = 100%"), timeZone: utc)
        for route in [ActionAgentHandoff.Route.claudeCodeTerminal, .claudeDesktop, .codexApp] {
            let url = try XCTUnwrap(route.url(prompt: prompt))
            let query = try XCTUnwrap(url.query(percentEncoded: true))
            let value = try XCTUnwrap(query.split(separator: "=", maxSplits: 1).last)
            XCTAssertFalse(value.contains { "+&=# \n".contains($0) }, "\(route): \(value)")
            XCTAssertEqual(String(value).removingPercentEncoding, prompt)
        }
    }

    // MARK: Prompt

    func testPromptCarriesTheActionMeetingAndFiles() {
        let prompt = ActionAgentHandoff.prompt(brief(), timeZone: utc)
        XCTAssertEqual(prompt, """
            Help me with this action item from a meeting I recorded in LokalBot.

            Action: Send Ana the revised budget
            Owner: me
            Due: 2026-10-30 (said “Friday”)
            Status: Open

            Meeting: Design review, Mon 2026-10-26 14:00 (LokalBot meeting ID 1a2b3c4d). It comes up at [00:12:34] in the transcript.
            - Summary: `\(folder.path)/summary.md`
            - My notes: `\(folder.path)/notes.md`
            - Transcript: `\(folder.path)/transcript.md`

            These files are LokalBot's records of the meeting. Read them for the full context, but don't edit them.
            """)
        XCTAssertLessThan(prompt.count, 1_000, "Claude Code asks the user to scroll through longer link prompts")
    }

    func testPromptNamesOtherOwnersAndUnresolvedDuePhrases() {
        var brief = brief()
        brief.owner = "Marko"
        brief.ownerIsUser = false
        brief.due = "next sprint"
        brief.dueDate = nil
        brief.status = "Deferred"
        let prompt = ActionAgentHandoff.prompt(brief, timeZone: utc)
        XCTAssertTrue(prompt.contains("\nOwner: Marko\n"))
        XCTAssertTrue(prompt.contains("\nDue: “next sprint” (said on 2026-10-26)\n"))
        XCTAssertTrue(prompt.contains("\nStatus: Deferred"))

        brief.owner = nil
        brief.due = nil
        let unclear = ActionAgentHandoff.prompt(brief, timeZone: utc)
        XCTAssertTrue(unclear.contains("\nOwner: not clear\n"))
        XCTAssertFalse(unclear.contains("Due:"))
    }

    func testExplicitDueDateIsNotRepeated() {
        var brief = brief()
        brief.due = "2026-10-30"
        XCTAssertTrue(ActionAgentHandoff.prompt(brief, timeZone: utc).contains("\nDue: 2026-10-30\n"))
    }

    func testMeetingWithoutFilesPointsAtItsFolderAndSkipsTheTimestamp() {
        var brief = brief()
        brief.sources[0].files = []
        let prompt = ActionAgentHandoff.prompt(brief, timeZone: utc)
        XCTAssertTrue(prompt.contains("- Folder: `\(folder.path)`"))
        XCTAssertFalse(prompt.contains("comes up at"), "No transcript to look in")
    }

    func testThreadListsItsMeetingsNewestFirstAndDropsOldOnesToFit() {
        var brief = brief()
        brief.sources = []
        var meetingStart = startedAt
        for index in 0..<7 {
            brief.sources.append(source(title: "Weekly sync \(index)", startedAt: meetingStart))
            meetingStart = meetingStart.addingTimeInterval(-604_800)
        }
        let prompt = ActionAgentHandoff.prompt(brief, timeZone: utc)
        XCTAssertTrue(prompt.contains("It came up in 7 meetings. Here are the latest 5:"))
        XCTAssertTrue(prompt.contains("Weekly sync 4"))
        XCTAssertFalse(prompt.contains("Weekly sync 5"))
        XCTAssertLessThan(try XCTUnwrap(prompt.range(of: "Weekly sync 0")).lowerBound,
                          try XCTUnwrap(prompt.range(of: "Weekly sync 1")).lowerBound)

        let tight = ActionAgentHandoff.prompt(brief, limit: 1_200, timeZone: utc)
        XCTAssertLessThanOrEqual(tight.count, 1_200)
        XCTAssertTrue(tight.contains("Weekly sync 0"))
        XCTAssertFalse(tight.contains("[Cut short to fit.]"))
    }

    func testLongActionTextIsCappedAndThePromptStaysUnderTheLinkLimit() {
        let long = ActionAgentHandoff.prompt(brief(text: String(repeating: "word ", count: 2_000)), timeZone: utc)
        XCTAssertLessThanOrEqual(long.count, ActionAgentHandoff.promptCharacterLimit)
        XCTAssertTrue(long.contains("…\nOwner: me"))
        XCTAssertTrue(long.contains("summary.md"))

        let cut = ActionAgentHandoff.prompt(brief(), limit: 300, timeZone: utc)
        XCTAssertEqual(cut.count, 300)
        XCTAssertTrue(cut.hasSuffix("[Cut short to fit.]"))
    }

    // MARK: Sources

    func testSourcesListOnlyFilesThatExistOncePerMeeting() {
        let older = UUID()
        let references = [
            reference(meetingID: older, title: "Kickoff", startedAt: startedAt.addingTimeInterval(-86_400)),
            reference(meetingID: meetingID, title: "Design review", startedAt: startedAt),
            reference(meetingID: meetingID, title: "Design review", startedAt: startedAt),
        ]
        let folders = [meetingID: folder, older: URL(fileURLWithPath: "/tmp/kickoff")]
        let existing: Set<String> = ["\(folder.path)/summary.md", "\(folder.path)/transcript.md"]
        let sources = ActionHandoffBrief.sources(for: references, folder: { folders[$0] },
                                                 fileExists: { existing.contains($0.path) })
        XCTAssertEqual(sources.map(\.title), ["Design review", "Kickoff"])
        XCTAssertEqual(sources[0].meetingID, "1a2b3c4d")
        XCTAssertEqual(sources[0].files.map(\.label), ["Summary", "Transcript"])
        XCTAssertEqual(sources[0].evidenceAt, 754)
        XCTAssertEqual(sources[1].files, [])
    }

    func testSourcesSkipMeetingsThatAreNoLongerInTheLibrary() {
        let sources = ActionHandoffBrief.sources(
            for: [reference(meetingID: meetingID, title: "Gone", startedAt: startedAt)],
            folder: { _ in nil }, fileExists: { _ in true })
        XCTAssertEqual(sources, [])
    }

    // MARK: Helpers

    private func handlers(_ schemes: Set<String>) -> (URL) -> URL? {
        { url in schemes.contains(url.scheme ?? "") ? URL(fileURLWithPath: "/Applications/Handler.app") : nil }
    }

    private func brief(text: String = "Send Ana the revised budget") -> ActionHandoffBrief {
        ActionHandoffBrief(
            text: text, owner: "You", ownerIsUser: true, due: "Friday",
            dueDate: startedAt.addingTimeInterval(4 * 86_400), dueSaidOn: startedAt, status: "Open",
            sources: [source(title: "Design review", startedAt: startedAt)])
    }

    private func source(title: String, startedAt: Date) -> ActionHandoffBrief.Source {
        .init(title: title, startedAt: startedAt, meetingID: "1a2b3c4d", evidenceAt: 754, folder: folder,
              files: ActionHandoffBrief.meetingFiles.map { .init(label: $0.0, url: folder.appendingPathComponent($0.1)) })
    }

    private func reference(meetingID: UUID, title: String, startedAt: Date) -> OutcomeActionReference {
        let action = MeetingOutcomes.ActionItem(
            text: "Send Ana the revised budget", owner: "Me", due: "Friday",
            citations: [.init(meetingID: meetingID, segmentID: "segment-1", start: 754, end: 760,
                              speaker: "Me", excerpt: "I'll send Ana the budget")])
        return OutcomeActionReference(
            meetingID: meetingID, meetingTitle: title, meetingStartedAt: startedAt, action: action,
            status: .open, text: action.displayText, owner: "Me", due: "Friday",
            stateUpdatedAt: startedAt, textWasCorrected: false, ownerWasCorrected: false, dueWasCorrected: false)
    }
}
