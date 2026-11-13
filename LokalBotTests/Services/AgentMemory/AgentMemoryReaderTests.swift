import XCTest
@testable import LokalBot

final class AgentMemoryReaderTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentMemoryReaderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    // MARK: - Claude Code

    func testClaudeNotesCarryTitleDescriptionTypeAndProject() throws {
        try writeClaudeProject("/Users/me/GitHub/app", session: true, notes: [
            "release-gotchas.md": """
                ---
                name: release-gotchas
                description: "Per-release lessons: tag by SHA, retry the \\"501\\" upload"
                metadata:
                  node_type: memory
                  type: project
                ---

                Tag the release by SHA. The upload token is ghp_abcdefghijklmnopqrstuvwxyz0123456789.
                """,
            "MEMORY.md": "- [Release runbook gotchas](release-gotchas.md) — per-release lessons\n",
        ])

        let scan = scanner().scan()

        XCTAssertEqual(scan.notes.count, 1, "the index file is not a note")
        let note = try XCTUnwrap(scan.notes.first)
        XCTAssertEqual(note.agent, .claudeCode)
        XCTAssertEqual(note.title, "Release runbook gotchas", "the index's title wins over the file's slug")
        XCTAssertEqual(note.summary, "Per-release lessons: tag by SHA, retry the \"501\" upload")
        XCTAssertEqual(note.category, "project")
        XCTAssertEqual(note.workingDirectory, "/Users/me/GitHub/app")
        XCTAssertEqual(note.projectName, "app")
        XCTAssertTrue(note.text.hasPrefix("Tag the release by SHA."))
        XCTAssertFalse(note.text.contains("ghp_"), "credentials are redacted before a note is kept")
        XCTAssertFalse(note.text.contains("node_type"), "the header is not part of the text")
        XCTAssertTrue(note.path.hasSuffix("/memory/release-gotchas.md"))
    }

    func testClaudeNoteWithoutHeaderOrIndexFallsBackToHeadingThenFileName() throws {
        try writeClaudeProject("/Users/me/GitHub/app", session: false, notes: [
            "with-heading.md": "# Build recipe\n\nRun the fast build first.\n",
            "plain-note.md": "Just a line the agent kept.\n",
            "empty.md": "---\nname: empty\n---\n",
            "notes.txt": "not markdown",
        ])

        let notes = scanner().scan().notes.sorted { $0.title < $1.title }

        XCTAssertEqual(notes.map(\.title), ["Build recipe", "plain note"])
        XCTAssertNil(notes[0].workingDirectory, "without a session file the folder's real path is unknown")
        XCTAssertNil(notes[0].category)
    }

    func testClaudeNoteIdsAreStableAndDifferPerFile() throws {
        try writeClaudeProject("/Users/me/GitHub/app", session: false, notes: [
            "a.md": "First note.", "b.md": "Second note.",
        ])

        let first = scanner().scan().notes
        let second = scanner().scan().notes

        XCTAssertEqual(first.map(\.id).sorted(), second.map(\.id).sorted())
        XCTAssertEqual(Set(first.map(\.id)).count, 2)
    }

    func testExcludedFolderLeavesOutClaudeNotesEvenWithoutASessionFile() throws {
        try writeClaudeProject("/Users/me/GitHub/secret", session: false, notes: ["a.md": "Secret plan."])
        try writeClaudeProject("/Users/me/GitHub/secret/tools", session: true, notes: ["b.md": "Inside it."])
        try writeClaudeProject("/Users/me/GitHub/open", session: true, notes: ["c.md": "Public plan."])

        let scan = scanner(excluded: ["/Users/me/GitHub/secret"]).scan()

        XCTAssertEqual(scan.notes.map(\.text), ["Public plan."])
        XCTAssertEqual(scan.excludedNotes, 2)
    }

    func testWorkingDirectoryIsTakenOnlyFromASessionThatMatchesTheProjectFolder() throws {
        let project = try writeClaudeProject("/Users/me/GitHub/app", session: false, notes: ["a.md": "Note."])
        // A session that later moved elsewhere still names its start folder first.
        try #"{"type":"user","cwd":"/Users/me/Other"}"#.appending("\n")
            .appending(#"{"type":"user","cwd":"/Users/me/GitHub/app"}"#)
            .write(to: project.appendingPathComponent("S1.jsonl"), atomically: true, encoding: .utf8)

        XCTAssertEqual(ClaudeCodeMemoryReader.workingDirectory(ofProject: project), "/Users/me/GitHub/app")
    }

    // MARK: - Codex

    func testCodexTaskGroupsBecomeNotesWithScopeAndFolder() throws {
        try writeCodex("MEMORY.md", """
            # Task Group: /Users/me/GitHub/app release checks

            scope: Verify a notarized release before publishing.
            applies_to: cwd=/Users/me/GitHub/app; reuse_rule=check the current tag

            ## Task 1: Verify the DMG

            ```sh
            # not a heading
            spctl --assess LokalBot.dmg
            ```

            # Task Group: Expense documents

            scope: Find receipts.
            applies_to: cwd=/Users/me/GitHub/secret; reuse_rule=none

            ## Task 1: Hotel invoice
            """)

        let scan = scanner(excluded: ["/Users/me/GitHub/secret"]).scan()

        XCTAssertEqual(scan.notes.count, 1)
        XCTAssertEqual(scan.excludedNotes, 1)
        let note = try XCTUnwrap(scan.notes.first)
        XCTAssertEqual(note.agent, .codex)
        XCTAssertEqual(note.title, "/Users/me/GitHub/app release checks")
        XCTAssertEqual(note.summary, "Verify a notarized release before publishing.")
        XCTAssertEqual(note.workingDirectory, "/Users/me/GitHub/app")
        XCTAssertTrue(note.text.contains("# not a heading"), "a heading inside fenced code stays text")
        XCTAssertTrue(note.text.contains("## Task 1: Verify the DMG"))
    }

    func testCodexSummarySectionsAndSessionSummaries() throws {
        try writeCodex("memory_summary.md", """
            v1

            ## User preferences

            Prefers short status notes.

            ## What's in Memory

            ### /Users/me/GitHub/app

            Release checks and build recipes.

            ### /Users/me/GitHub/secret / 2026-10-01

            Hidden work.
            """)
        try writeCodex("rollout_summaries/2026-11-10T10-29-23-o6E8-release_checks.md", """
            thread_id: 01a1c501
            updated_at: 2026-11-10T10:38:19+00:00
            rollout_path: /Users/me/.codex/sessions/2026/11/10/rollout.jsonl
            cwd: /Users/me/GitHub/app

            # Verified the notarized release

            Outcome: success.
            """)
        try writeCodex("rollout_summaries/2026-11-09T09-00-00-aaaa-hidden.md", """
            thread_id: 01a1c502
            cwd: /Users/me/GitHub/secret/tools

            # Hidden session

            Outcome: success.
            """)
        try writeCodex("raw_memories.md", "# Raw Memories\n\n## Thread `x`\n\nDuplicate of the summaries.\n")

        let scan = scanner(excluded: ["/Users/me/GitHub/secret"]).scan()
        let titles = Set(scan.notes.map(\.title))

        XCTAssertEqual(titles, ["User preferences", "/Users/me/GitHub/app", "Verified the notarized release"])
        XCTAssertEqual(scan.excludedNotes, 2)
        let session = try XCTUnwrap(scan.notes.first { $0.title == "Verified the notarized release" })
        XCTAssertEqual(session.workingDirectory, "/Users/me/GitHub/app")
        XCTAssertEqual(session.modifiedAt, ISO8601DateFormatter().date(from: "2026-11-10T10:38:19Z"))
        XCTAssertFalse(session.text.contains("thread_id"), "the header lines are not part of the text")
        let project = try XCTUnwrap(scan.notes.first { $0.title == "/Users/me/GitHub/app" })
        XCTAssertEqual(project.summary, "What's in Memory")
        XCTAssertEqual(project.workingDirectory, "/Users/me/GitHub/app")
    }

    func testDisabledAgentIsNotRead() throws {
        try writeClaudeProject("/Users/me/GitHub/app", session: false, notes: ["a.md": "Claude note."])
        try writeCodex("MEMORY.md", "# Task Group: Codex work\n\nscope: Something.\n")

        let scan = AgentMemoryScanner.standard(home: home, agents: [.codex]).scan()

        XCTAssertEqual(scan.notes.map(\.agent), [.codex])
    }

    func testLongNoteIsCutAtALineEnd() {
        let body = AgentMemoryText.body(String(repeating: "one line of the note\n", count: 2_000))

        XCTAssertLessThanOrEqual(body.count, AgentMemoryText.maxNoteCharacters + 2)
        XCTAssertTrue(body.hasSuffix("one line of the note\n…"))
    }

    // MARK: - Exclusions

    func testFolderMentionsMatchTheFolderAndItsContentsButNotSiblings() {
        let exclusions = AgentMemoryExclusions(folders: ["/Users/me/GitHub/app/"])

        XCTAssertTrue(exclusions.mentionsExcludedFolder("Task Group: /Users/me/GitHub/app release"))
        XCTAssertTrue(exclusions.mentionsExcludedFolder("/Users/me/GitHub/app/tools"))
        XCTAssertTrue(exclusions.mentionsExcludedFolder("worked in /Users/me/GitHub/app."))
        XCTAssertFalse(exclusions.mentionsExcludedFolder("/Users/me/GitHub/app-old"))
        XCTAssertFalse(exclusions.mentionsExcludedFolder("/Users/me/GitHub/app.bak"))
        XCTAssertTrue(exclusions.excludes(workingDirectory: "/Users/me/GitHub/app/x"))
        XCTAssertFalse(exclusions.excludes(workingDirectory: "/Users/me/GitHub/application"))
        XCTAssertTrue(AgentMemoryExclusions(folders: ["/", "  "]).folders.isEmpty)
    }

    // MARK: - Fixtures

    private func scanner(excluded: [String] = []) -> AgentMemoryScanner {
        AgentMemoryScanner.standard(home: home, excludedFolders: excluded)
    }

    @discardableResult
    private func writeClaudeProject(_ cwd: String, session: Bool, notes: [String: String]) throws -> URL {
        let project = home.appendingPathComponent(".claude/projects", isDirectory: true)
            .appendingPathComponent(AgentMemoryExclusions.claudeProjectSlug(for: cwd), isDirectory: true)
        let memory = project.appendingPathComponent("memory", isDirectory: true)
        try FileManager.default.createDirectory(at: memory, withIntermediateDirectories: true)
        for (name, contents) in notes {
            try contents.write(to: memory.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        if session {
            let line = try JSONSerialization.data(withJSONObject: ["type": "user", "cwd": cwd])
            try line.write(to: project.appendingPathComponent("S1.jsonl"))
        }
        return project
    }

    private func writeCodex(_ relativePath: String, _ contents: String) throws {
        let file = home.appendingPathComponent(".codex/memories", isDirectory: true)
            .appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: file, atomically: true, encoding: .utf8)
    }
}
