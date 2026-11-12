import XCTest
@testable import LokalBot

/// The words and grouping the Agent screen shows: step labels, how a turn
/// folds, a task's status, the task list's groups, changed files, and the
/// approval card.
final class AgentPresentationTests: XCTestCase {
    private var root: URL!
    private var workspace: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("agent-presentation-\(UUID())")
        workspace = root.appendingPathComponent("Agent Workspace")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var context: AgentStepWording.Context {
        .init(workspace: workspace, workspaceName: "Agent Workspace") { id in
            id == "eb749eed" ? "Design review meeting" : nil
        }
    }

    private func json(_ object: [String: Any]) -> String {
        String(decoding: (try? JSONSerialization.data(withJSONObject: object)) ?? Data(), as: UTF8.self)
    }

    private func label(_ tool: String, _ arguments: [String: Any]) -> AgentStepLabel {
        AgentStepWording.label(tool: tool, argsJSON: json(arguments), context: context) { $0 }
    }

    private func step(_ id: String, _ tool: String, _ arguments: [String: Any] = [:],
                      _ status: AgentToolStatus = .succeeded) -> AgentTranscriptItem {
        .tool(id: id, name: tool, argsJSON: json(arguments), output: "", status: status)
    }

    // MARK: - Step labels

    func testFileStepsNameTheFileAndItsFolder() {
        let read = label("read", ["path": "notes/plan.md"])
        XCTAssertEqual(read.done, "Read plan.md")
        XCTAssertEqual(read.doing, "Reading plan.md")
        XCTAssertEqual(read.detail, "Agent Workspace/notes")
        XCTAssertFalse(read.beginsWithName)
        XCTAssertEqual(label("write", ["path": "reviewed-note.md", "content": "a"]).done, "Wrote reviewed-note.md")
        XCTAssertEqual(label("write", ["path": "reviewed-note.md"]).detail, "Agent Workspace")
        XCTAssertEqual(label("Edit", ["file_path": workspace.appendingPathComponent("a.swift").path]).done, "Edited a.swift")
        let outside = label("read", ["path": "/etc/hosts"])
        XCTAssertEqual(outside.done, "Read hosts")
        XCTAssertEqual(outside.detail?.hasSuffix("/etc"), true, "a file outside the folder shows where it is")
    }

    func testLibraryLookupsSayWhatTheyLookedUp() {
        let search = label("bash", ["command": "lokalbot-cli search \"design review\" --limit 20"])
        XCTAssertEqual(search.done, "Searched meeting library")
        XCTAssertEqual(search.doing, "Searching meeting library")
        XCTAssertEqual(search.detail, "design review")
        let get = label("bash", ["command": "lokalbot-cli get eb749eed --include metadata,summary"])
        XCTAssertEqual(get.done, "Read meeting notes")
        XCTAssertEqual(get.detail, "Design review meeting")
        XCTAssertNil(label("bash", ["command": "lokalbot-cli get latest"]).detail)
        XCTAssertEqual(label("bash", ["command": "lokalbot-cli list --limit 10 --query=atlas"]).done, "Listed meetings")
        XCTAssertEqual(label("bash", ["command": "lokalbot-cli list --limit 10 --query=atlas"]).detail, "atlas")
        XCTAssertEqual(label("bash", ["command": "lokalbot-cli brief"]).done, "Read your briefing")
        XCTAssertEqual(label("bash", ["command": "lokalbot-cli actions --owner me --table"]).done, "Read action items")
        XCTAssertEqual(label("bash", ["command": "lokalbot-cli search --limit 5 release"]).detail, "release")
        // A command without a name of its own shows its text.
        let people = label("bash", ["command": "lokalbot-cli people \"Ana Petrović\""])
        XCTAssertEqual(people.done, "Ran a command")
        XCTAssertEqual(people.detail, "lokalbot-cli people \"Ana Petrović\"")
    }

    /// A label never hides what ran: anything a shell could chain or redirect
    /// is a command, shown with its text.
    func testOtherCommandsShowTheirText() {
        for command in ["ls -la", "lokalbot-cli list > notes.md", "lokalbot-cli brief && rm -rf build",
                        "mkdir -p exports && lokalbot-cli list --table > exports/open-actions.md",
                        "lokalbot-cli config set autoSummarize false", "lokalbot-cli"] {
            let label = label("bash", ["command": command])
            XCTAssertEqual(label.done, "Ran a command", command)
            XCTAssertEqual(label.doing, "Running a command", command)
            XCTAssertEqual(label.detail, command)
        }
        XCTAssertEqual(label("bash", ["command": "echo one\necho two"]).detail, "echo one")
        XCTAssertEqual(label("bash", ["command": String(repeating: "a", count: 300)]).detail?.count, 120)
        XCTAssertNil(label("bash", [:]).detail)
    }

    func testOtherToolsAreNamed() {
        let tool = label("mcp_search", ["q": "x"])
        XCTAssertEqual(tool.done, "Used mcp_search")
        XCTAssertEqual(tool.doing, "Using mcp_search")
        // A file tool without a path has nothing to name.
        XCTAssertEqual(label("read", [:]).done, "Used read")
    }

    func testStepTextFollowsItsState() {
        let label = label("write", ["path": "note.md"])
        XCTAssertEqual(label.text(.succeeded, taskIsWorking: true) { $0 }, "Wrote note.md")
        XCTAssertEqual(label.text(.running, taskIsWorking: true) { $0 }, "Writing note.md…")
        XCTAssertEqual(label.text(.failed, taskIsWorking: false) { $0 }, "Writing note.md · failed")
        // Still running when its task stopped: it never finished.
        XCTAssertEqual(label.text(.running, taskIsWorking: false) { $0 }, "Writing note.md · not finished")
    }

    func testSummaryNamesEachDifferentStepOnce() {
        let labels: [(text: String, beginsWithName: Bool)] = [
            ("Searched meeting library", false), ("Read meeting notes", false), ("Read meeting notes", false),
            ("Wrote README.md", false),
        ]
        XCTAssertEqual(AgentStepWording.summary(labels, lowercaseFollowing: true),
                       "Searched meeting library, read meeting notes, wrote README.md")
        XCTAssertEqual(AgentStepWording.summary(labels, lowercaseFollowing: false),
                       "Searched meeting library, Read meeting notes, Wrote README.md")
        // Where a translation puts the file name first, its capitals stay.
        XCTAssertEqual(AgentStepWording.summary([("Gelesen", false), ("README.md geschrieben", true)],
                                                lowercaseFollowing: true), "Gelesen, README.md geschrieben")
        XCTAssertEqual(AgentStepWording.summary([], lowercaseFollowing: true), "")
        XCTAssertEqual(AgentStepWording.count(1) { $0 }, "1 step")
        XCTAssertEqual(AgentStepWording.count(4) { $0 }, "4 steps")
    }

    func testTranslatedFileLabelKnowsWhenTheNameLeads() {
        let german = AgentStepWording.label(tool: "write", argsJSON: json(["path": "README.md"]), context: context) {
            $0 == "Wrote %@" ? "%@ geschrieben" : $0
        }
        XCTAssertEqual(german.done, "README.md geschrieben")
        XCTAssertTrue(german.beginsWithName)
    }

    // MARK: - Layout

    private let question = AgentTranscriptItem.user(id: "u1", text: "Draft a follow-up")

    func testWorkingTurnShowsWordsInFullAndFoldsEachRunOfSteps() {
        let items: [AgentTranscriptItem] = [
            question,
            step("t1", "bash", ["command": "lokalbot-cli search design"]),
            step("t2", "bash", ["command": "lokalbot-cli get eb749eed"]),
            .assistant(id: "a1", text: "Found it.", isStreaming: false),
            step("t3", "bash", ["command": "lokalbot-cli actions"], .running),
        ]
        let blocks = AgentTranscriptLayout.make(items, isWorking: true)
        XCTAssertEqual(blocks.map(\.id), ["u1", "steps.t1", "a1", "t3"])
        guard case .steps(let run) = blocks[1], case .said = blocks[2], case .live(let live) = blocks[3] else {
            return XCTFail("\(blocks)")
        }
        XCTAssertEqual(run.steps.map(\.id), ["t1", "t2"])
        XCTAssertFalse(run.isTurnSummary)
        XCTAssertEqual(live.id, "t3")
    }

    func testStepInProgressLeavesItsRunAndRejoinsWhenDone() {
        let running = AgentTranscriptLayout.make(
            [question, step("t1", "read", ["path": "a"]), step("t2", "read", ["path": "b"], .running)], isWorking: true)
        XCTAssertEqual(running.map(\.id), ["u1", "steps.t1", "t2"])
        let finished = AgentTranscriptLayout.make(
            [question, step("t1", "read", ["path": "a"]), step("t2", "read", ["path": "b"])], isWorking: true)
        XCTAssertEqual(finished.map(\.id), ["u1", "steps.t1"])
        // The only step of a run shows live with no folded line above it.
        let alone = AgentTranscriptLayout.make([question, step("t1", "read", ["path": "a"], .running)], isWorking: true)
        XCTAssertEqual(alone.map(\.id), ["u1", "t1"])
    }

    func testFinishedTurnFoldsItsWorkIntoOneLineAboveTheAnswer() {
        let items: [AgentTranscriptItem] = [
            question,
            step("t1", "bash", ["command": "lokalbot-cli search design"]),
            .assistant(id: "a1", text: "Found it.", isStreaming: false),
            step("t2", "bash", ["command": "lokalbot-cli actions"]),
            step("t3", "write", ["path": "reviewed-note.md", "content": "x"]),
            .assistant(id: "a2", text: "Here's the follow-up.", isStreaming: false),
        ]
        let blocks = AgentTranscriptLayout.make(items, isWorking: false)
        XCTAssertEqual(blocks.map(\.id), ["u1", "steps.t1", "a2"])
        guard case .steps(let work) = blocks[1], case .answer(let answer, let steps) = blocks[2] else {
            return XCTFail("\(blocks)")
        }
        XCTAssertTrue(work.isTurnSummary)
        XCTAssertEqual(work.steps.map(\.id), ["t1", "t2", "t3"])
        // What the agent said between steps stays inside the fold, in order.
        XCTAssertEqual(work.entries.map(\.id), ["t1", "a1", "t2", "t3"])
        XCTAssertEqual(answer.id, "a2")
        XCTAssertEqual(steps.map(\.id), ["t1", "t2", "t3"])
        // Nothing is dropped: every message is in exactly one block.
        XCTAssertTrue(blocks.contains { $0.searchableText.contains("Found it.") })
    }

    func testEarlierTurnsFoldWhileTheLastOneWorks() {
        let items: [AgentTranscriptItem] = [
            question, step("t1", "read", ["path": "a"]), .assistant(id: "a1", text: "Done.", isStreaming: false),
            .user(id: "u2", text: "Shorter"), step("t2", "read", ["path": "b"]),
            .assistant(id: "a2", text: "Working on it", isStreaming: true),
        ]
        let blocks = AgentTranscriptLayout.make(items, isWorking: true)
        XCTAssertEqual(blocks.map(\.id), ["u1", "steps.t1", "a1", "u2", "steps.t2", "a2"])
        guard case .answer = blocks[2], case .said = blocks[5] else { return XCTFail("\(blocks)") }
    }

    func testAnswerWithoutStepsHasNoFoldedLine() {
        let blocks = AgentTranscriptLayout.make(
            [question, .assistant(id: "a1", text: "Hello.", isStreaming: false)], isWorking: false)
        XCTAssertEqual(blocks.map(\.id), ["u1", "a1"])
        guard case .answer(_, let steps) = blocks[1] else { return XCTFail("\(blocks)") }
        XCTAssertTrue(steps.isEmpty)
    }

    func testNoticesAreNeverFoldedAway() {
        let items: [AgentTranscriptItem] = [
            question, step("t1", "read", ["path": "a"]),
            .notice(id: "n1", text: "You denied this write request. Nothing changed.", isError: false),
            step("t2", "read", ["path": "b"]),
            .assistant(id: "a1", text: "I left the file alone.", isStreaming: false),
            .notice(id: "n2", text: "401", isError: true),
        ]
        let blocks = AgentTranscriptLayout.make(items, isWorking: false)
        XCTAssertEqual(blocks.map(\.id), ["u1", "steps.t1", "n1", "steps.t2", "a1", "n2"])
    }

    func testStoppedTurnWithoutAnAnswerKeepsItsWordsAndShowsNoLiveStep() {
        let items: [AgentTranscriptItem] = [
            question, .assistant(id: "a1", text: "Looking.", isStreaming: false),
            step("t1", "read", ["path": "a"]), step("t2", "read", ["path": "b"], .running),
        ]
        let blocks = AgentTranscriptLayout.make(items, isWorking: false)
        XCTAssertEqual(blocks.map(\.id), ["u1", "a1", "steps.t1"])
        guard case .said = blocks[1], case .steps(let run) = blocks[2] else { return XCTFail("\(blocks)") }
        XCTAssertEqual(run.steps.count, 2)
        XCTAssertFalse(run.isTurnSummary)
    }

    func testRestoredHistoryWithoutALeadingQuestionStillLaysOut() {
        let blocks = AgentTranscriptLayout.make(
            [.notice(id: "n1", text: "Resumed", isError: false), .assistant(id: "a1", text: "Hi", isStreaming: false)],
            isWorking: false)
        XCTAssertEqual(blocks.map(\.id), ["n1", "a1"])
        XCTAssertTrue(AgentTranscriptLayout.make([], isWorking: true).isEmpty)
    }

    func testFailedStepMarksItsRun() {
        let blocks = AgentTranscriptLayout.make(
            [question, step("t1", "read", ["path": "a"], .failed)], isWorking: true)
        guard case .steps(let run) = blocks[1] else { return XCTFail("\(blocks)") }
        XCTAssertTrue(run.hasFailure)
    }

    // MARK: - Status

    private func status(_ state: AgentSessionController.SessionState, approvals: Int = 0, error: Bool = false,
                        stopped: Bool = false, items: [AgentTranscriptItem] = [], saved: Bool = false,
                        changed: Int = 0) -> AgentTaskStatus {
        .resolve(state: state, pendingApprovals: approvals, hasTurnError: error, wasStopped: stopped, items: items,
                 hasSavedConversation: saved, changedFiles: changed)
    }

    func testStatusFollowsWhatTheTaskIsDoing() {
        let answered: [AgentTranscriptItem] = [question, .assistant(id: "a", text: "Done.", isStreaming: false)]
        XCTAssertEqual(status(.idle), .notStarted)
        XCTAssertEqual(status(.ready), .notStarted)
        XCTAssertEqual(status(.idle, saved: true), .saved)
        XCTAssertEqual(status(.starting), .starting)
        XCTAssertEqual(status(.running, items: [question]), .working)
        XCTAssertEqual(status(.running, approvals: 2, items: [question]), .needsApproval(2))
        XCTAssertEqual(status(.ready, error: true, items: answered), .needsAttention)
        XCTAssertEqual(status(.failed("x"), items: answered), .needsAttention)
        XCTAssertEqual(status(.ready, stopped: true, items: answered), .stopped)
        XCTAssertEqual(status(.ready, items: answered, changed: 1), .done(changedFiles: 1))
        // A notice after the answer does not undo it.
        XCTAssertEqual(status(.ready, items: answered + [.notice(id: "n", text: "Resumed", isError: false)]),
                       .done(changedFiles: 0))
        // A saved conversation that is only being read is not "done" again.
        XCTAssertEqual(status(.idle, items: answered, saved: true), .saved)
        XCTAssertEqual(status(.ready, items: [question, step("t", "read")]), .saved)
    }

    func testStatusWordsAndTones() {
        XCTAssertEqual(AgentTaskStatus.notStarted.title { $0 }, "Not started")
        XCTAssertNil(AgentTaskStatus.saved.title { $0 })
        XCTAssertEqual(AgentTaskStatus.working.title { $0 }, "Working…")
        XCTAssertEqual(AgentTaskStatus.needsApproval(1).title { $0 }, "Needs approval")
        XCTAssertEqual(AgentTaskStatus.stopped.line { $0 }, "Stopped")
        XCTAssertEqual(AgentTaskStatus.done(changedFiles: 0).line { $0 }, "Done")
        XCTAssertEqual(AgentTaskStatus.done(changedFiles: 1).line { $0 }, "Done · 1 file changed")
        XCTAssertEqual(AgentTaskStatus.done(changedFiles: 3).line { $0 }, "Done · 3 files changed")
        XCTAssertEqual(AgentTaskStatus.done(changedFiles: 3).title { $0 }, "Done")
        XCTAssertEqual(AgentTaskStatus.needsApproval(1).tone, .attention)
        XCTAssertEqual(AgentTaskStatus.needsAttention.tone, .attention)
        XCTAssertEqual(AgentTaskStatus.working.tone, .working)
        XCTAssertEqual(AgentTaskStatus.starting.tone, .working)
        XCTAssertEqual(AgentTaskStatus.done(changedFiles: 0).tone, .done)
        XCTAssertEqual(AgentTaskStatus.stopped.tone, .quiet)
    }

    // MARK: - Task list

    func testTasksGroupByDayWithPinnedFirst() throws {
        // Day titles are formatted in the current time zone, so group in it too.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        func date(_ day: Int, _ hour: Int) throws -> Date {
            try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour)))
        }
        let now = try date(11, 12)
        let ids = (0..<7).map { _ in UUID() }
        let entries: [AgentTaskListSection.Entry] = [
            .init(id: ids[0], modifiedAt: try date(11, 9), isPinned: false),
            .init(id: ids[1], modifiedAt: try date(10, 16), isPinned: false),
            .init(id: ids[2], modifiedAt: try date(11, 10), isPinned: false),
            .init(id: ids[3], modifiedAt: try date(3, 8), isPinned: true),
            .init(id: ids[4], modifiedAt: try date(7, 8), isPinned: false),
            .init(id: ids[5], modifiedAt: .distantPast, isPinned: false),
            .init(id: ids[6], modifiedAt: try date(10, 23), isPinned: false),
        ]
        let sections = AgentTaskListSection.make(entries, now: now, calendar: calendar)
        XCTAssertEqual(sections.map(\.kind), [.pinned, .today, .yesterday, .day(try date(7, 0)), .earlier])
        XCTAssertEqual(sections[0].ids, [ids[3]])
        XCTAssertEqual(sections[1].ids, [ids[2], ids[0]], "newest first within a day")
        XCTAssertEqual(sections[2].ids, [ids[6], ids[1]])
        XCTAssertEqual(sections[3].ids, [ids[4]])
        XCTAssertEqual(sections[4].ids, [ids[5]])
        XCTAssertEqual(Set(sections.map(\.id)).count, sections.count)
        XCTAssertEqual(sections[1].title(locale: Locale(identifier: "en_US")) { $0 }, "Today")
        XCTAssertEqual(sections[3].title(locale: Locale(identifier: "en_US")) { $0 }, "Nov 7, 2026")
        XCTAssertTrue(AgentTaskListSection.make([], now: now, calendar: calendar).isEmpty)
    }

    // MARK: - Changed files

    func testChangedFilesComeFromSucceededWritesAndEdits() throws {
        let outside = root.appendingPathComponent("elsewhere.txt")
        let items: [AgentTranscriptItem] = [
            step("r", "read", ["path": "reviewed-note.md"]),
            step("w1", "write", ["path": "reviewed-note.md", "content": "one\ntwo\nthree\n"]),
            step("w2", "write", ["path": "old.md", "content": "x"]),
            step("e1", "edit", ["path": "old.md", "oldText": "x", "newText": "y"]),
            step("w3", "write", ["path": "failed.md", "content": "x"], .failed),
            step("w4", "write", ["path": "pending.md", "content": "x"], .running),
            step("e2", "edit", ["path": outside.path]),
            step("b", "bash", ["command": "touch made-by-command.md"]),
            step("w5", "write", ["path": "history.md", "content": "a\nb"]),
            step("e3", "edit", ["path": "reviewed-note.md"]),
        ]
        let files = AgentChangedFile.list(in: items, workspace: workspace, workspaceName: "Agent Workspace",
                                          existedBefore: ["w1": false, "w2": true])
        XCTAssertEqual(files.map(\.target.name), ["reviewed-note.md", "old.md", "elsewhere.txt", "history.md"])
        XCTAssertEqual(files[0].change, .created, "a file the agent made stays new after it edits it")
        XCTAssertEqual(files[0].lineCount, 3)
        XCTAssertEqual(files[0].stepID, "e3")
        XCTAssertEqual(files[0].detail { $0 }, "New file · 3 lines · Agent Workspace")
        XCTAssertEqual(files[1].change, .edited)
        XCTAssertEqual(files[1].detail { $0 }, "Edited · 1 line · Agent Workspace")
        XCTAssertEqual(files[2].target.place, .outside)
        XCTAssertEqual(files[2].detail { $0 }, "Edited · \(files[2].target.folder)")
        // History does not say whether a written file was there before.
        XCTAssertEqual(files[3].change, .written)
        XCTAssertEqual(files[3].detail { $0 }, "2 lines · Agent Workspace")
        XCTAssertEqual(AgentChangedFile.lineCount(""), 0)
        XCTAssertEqual(AgentChangedFile.lineCount("a"), 1)
        XCTAssertEqual(AgentChangedFile.lineCount("a\nb\n"), 2)
    }

    func testFileTargetFollowsALinkOutOfTheWorkingFolder() throws {
        let outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: workspace.appendingPathComponent("escape"),
                                                   withDestinationURL: outside)
        let linked = AgentFileTarget.resolve("escape/secret.txt", workspace: workspace, workspaceName: "Agent Workspace")
        XCTAssertEqual(linked.place, .outside)
        XCTAssertEqual(linked.name, "secret.txt")
        let inside = AgentFileTarget.resolve("@drafts/a.md", workspace: workspace, workspaceName: "Agent Workspace")
        XCTAssertEqual(inside.place, .workingFolder)
        XCTAssertEqual(inside.folder, "Agent Workspace/drafts")
        XCTAssertEqual(AgentFileTarget.resolve("../up.md", workspace: workspace, workspaceName: "W").place, .outside)
        XCTAssertEqual(AgentFileTarget.resolve("~/x.md", workspace: workspace, workspaceName: "W").place, .outside)
    }

    // MARK: - Approval card

    private func request(_ tool: String, path: String? = nil, command: String? = nil, content: String? = nil,
                         edits: [AgentApprovalRequest.Edit] = [], arguments: String? = nil) -> AgentApprovalRequest {
        var request = AgentApprovalRequest(id: "r", tool: tool, workspace: workspace.path, path: path, command: command,
                                           content: content, edits: edits, summary: nil, isTruncated: false)
        request.arguments = arguments
        return request
    }

    private func card(_ request: AgentApprovalRequest, place: AgentApprovalPresentation.Place = .workingFolder,
                      exists: Bool = false, remote: String? = nil, task: Bool = false) -> AgentApprovalPresentation {
        .init(request: request, place: place, targetExists: exists, workspaceName: "Agent Workspace",
              remoteHost: remote, canAllowForTask: task) { $0 }
    }

    func testWriteAsksToCreateOrReplaceAndNamesTheFile() {
        let write = request("write", path: workspace.appendingPathComponent("reviewed-note.md").path,
                            content: "one\ntwo\nthree\nfour\nfive")
        let create = card(write, task: true)
        XCTAssertEqual(create.title, "Create reviewed-note.md?")
        XCTAssertEqual(create.effect, "Adds a new file to Agent Workspace.")
        XCTAssertNil(create.caution)
        XCTAssertNil(create.destination)
        XCTAssertEqual(create.previewLines.count, 5)
        XCTAssertEqual(create.taskAnswer, "Allow writes for this task")
        let replace = card(write, exists: true)
        XCTAssertEqual(replace.title, "Replace reviewed-note.md?")
        XCTAssertEqual(replace.effect, "Replaces the file in Agent Workspace.")
        XCTAssertNil(replace.taskAnswer, "only offered when the policy allows it for this request")
        XCTAssertEqual(card(request("write", content: "x")).title, "Use write?", "a write that names no file")
        XCTAssertEqual(AgentApprovalPresentation.showAll(12) { $0 }, "Show all 12 lines")
    }

    func testFileOutsideTheWorkingFolderShowsItsFullPathAsACaution() {
        let write = request("write", path: "/Users/someone/Desktop/note.md", content: "x")
        let outside = card(write, place: .outside)
        XCTAssertEqual(outside.title, "Create note.md?")
        XCTAssertEqual(outside.effect, "This file is outside Agent Workspace.")
        XCTAssertEqual(outside.caution, "/Users/someone/Desktop/note.md")
        XCTAssertEqual(card(write, place: .outside, exists: true).title, "Replace note.md?")
        let data = card(request("edit", path: "/Library/LokalBot/meta.json"), place: .lokalbotData)
        XCTAssertEqual(data.title, "Edit meta.json?")
        XCTAssertEqual(data.effect, "This file is part of LokalBot’s own data.")
        XCTAssertEqual(data.caution, "/Library/LokalBot/meta.json")
        let read = card(request("read", path: "/etc/hosts"), place: .outside, remote: "api.example.com")
        XCTAssertEqual(read.title, "Read hosts?")
        XCTAssertEqual(read.effect, "This file is outside Agent Workspace.")
        XCTAssertEqual(read.destination, "The result goes to the model at api.example.com.")
    }

    func testEditShowsWhatLeavesAndWhatArrives() {
        let edit = card(request("edit", path: workspace.appendingPathComponent("a.md").path,
                                edits: [.init(oldText: "old\nline", newText: "new")]), task: true)
        XCTAssertEqual(edit.title, "Edit a.md?")
        XCTAssertEqual(edit.effect, "Changes the file in Agent Workspace.")
        XCTAssertEqual(edit.preview, "- old\n- line\n+ new")
        XCTAssertEqual(edit.taskAnswer, "Allow edits for this task")
    }

    func testCommandAndOtherToolsShowExactlyWhatWillRun() {
        let command = card(request("bash", command: "mkdir -p exports && lokalbot-cli list > exports/a.md"))
        XCTAssertEqual(command.title, "Run a command?")
        XCTAssertEqual(command.symbol, "terminal")
        XCTAssertEqual(command.effect,
                       "Runs in Agent Workspace with your Mac account’s access, so it can change files or use the network.")
        XCTAssertEqual(command.preview, "mkdir -p exports && lokalbot-cli list > exports/a.md")
        XCTAssertNil(command.taskAnswer)
        XCTAssertNil(command.destination, "nothing leaves this Mac with a model on this Mac")
        XCTAssertEqual(card(request("bash", command: "ls"), remote: "ChatGPT plan").destination,
                       "The result goes to the model at ChatGPT plan.")
        let tool = card(request("mcp_search", arguments: "{\"q\":\"x\"}"))
        XCTAssertEqual(tool.title, "Use mcp_search?")
        XCTAssertEqual(tool.preview, "{\"q\":\"x\"}")
        // A write's text stays on this Mac until the agent reads something back.
        XCTAssertNil(card(request("write", path: "/a/b.md", content: "x"), remote: "api.example.com").destination)
    }

    // MARK: - Access levels

    func testEachLevelSaysWhatRunsOnItsOwnAndWhatStillAsks() {
        let asks = AgentApprovalMode.askBeforeChanges.levelDetail(workspaceName: "Agent Workspace") { $0 }
        XCTAssertEqual(asks, "Reads files in Agent Workspace without asking, and looks things up in your LokalBot library when the model runs on this Mac. Asks before anything else.")
        XCTAssertEqual(AgentApprovalMode.allCases.map(\.chipTitle),
                       ["Asks first", "Reads any file", "Edits any file", "Full access"])
        XCTAssertEqual(AgentApprovalMode.allCases.map(\.levelTitle),
                       ["Ask first", "Read any file", "Edit any file", "Full access"])
        XCTAssertEqual(AgentApprovalMode.allCases.filter(\.needsCaution), [.fullAccess])
        XCTAssertTrue(AgentApprovalMode.fullAccess.levelDetail(workspaceName: "W") { $0 }.contains("without asking"))
    }

    // MARK: - Catalog

    /// Every sentence these types put together has an entry in the catalog.
    func testEverySentenceIsInTheCatalog() throws {
        let url = try XCTUnwrap(Bundle.main.url(
            forResource: "Localizable", withExtension: "strings", subdirectory: nil, localization: "en"))
        let catalog = try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String])
        var keys = Set<String>()
        let record: AgentLocalize = { keys.insert($0); return $0 }

        for (tool, arguments) in [
            ("read", ["path": "a"]), ("write", ["path": "a"]), ("edit", ["path": "a"]), ("mcp", [:]),
            ("bash", ["command": "ls"]), ("bash", ["command": "lokalbot-cli search x"]),
            ("bash", ["command": "lokalbot-cli get x"]), ("bash", ["command": "lokalbot-cli list"]),
            ("bash", ["command": "lokalbot-cli brief"]), ("bash", ["command": "lokalbot-cli actions"]),
        ] as [(String, [String: Any])] {
            let label = AgentStepWording.label(tool: tool, argsJSON: json(arguments), context: context, localize: record)
            for status in [AgentToolStatus.running, .failed, .succeeded] {
                _ = label.text(status, taskIsWorking: false, localize: record)
            }
        }
        _ = AgentStepWording.count(1, localize: record)
        _ = AgentStepWording.count(2, localize: record)
        for status in [AgentTaskStatus.notStarted, .saved, .starting, .working, .needsApproval(1), .needsAttention,
                       .stopped, .done(changedFiles: 0), .done(changedFiles: 1), .done(changedFiles: 2)] {
            _ = status.line(localize: record)
        }
        for kind in [AgentTaskListSection.Kind.pinned, .today, .yesterday, .earlier] {
            _ = AgentTaskListSection(kind: kind, ids: []).title(locale: Locale(identifier: "en"), localize: record)
        }
        for mode in AgentApprovalMode.allCases {
            keys.formUnion([mode.chipTitle, mode.levelTitle])
            _ = mode.levelDetail(workspaceName: "W", localize: record)
            _ = mode.capability(localize: record)
        }
        for change in [AgentChangedFile.Change.created, .replaced, .edited, .written] {
            let target = AgentFileTarget.resolve("a.md", workspace: workspace, workspaceName: "W")
            for lines in [1, 2] {
                _ = AgentChangedFile(target: target, change: change, lineCount: lines, stepID: "s").detail(localize: record)
            }
        }
        for tool in ["write", "edit", "read", "bash", "mcp"] {
            for place in [AgentApprovalPresentation.Place.workingFolder, .outside, .lokalbotData, .none] {
                for exists in [true, false] {
                    for path in ["/a/b.md", nil] {
                        _ = AgentApprovalPresentation(
                            request: request(tool, path: path), place: place, targetExists: exists, workspaceName: "W",
                            remoteHost: "host", canAllowForTask: true, localize: record)
                    }
                }
            }
        }
        _ = AgentApprovalPresentation.showAll(5, localize: record)
        let missing = keys.filter { catalog[$0] == nil }.sorted()
        XCTAssertEqual(missing, [], "Add these to every Localizable.strings")
    }
}
