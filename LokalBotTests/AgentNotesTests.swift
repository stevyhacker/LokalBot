import XCTest
@testable import LokalBot

/// Coding-agent notes as a searchable source: the saved copy, its search, the
/// background reader, the external-agent grant, and the Ask tool and citations.
@MainActor
final class AgentNotesTests: XCTestCase {
    private var root: URL!
    private var store: AgentMemoryStore!
    private var index: AgentNotesIndex!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("agent-notes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = AgentMemoryStore(root: root)
        index = AgentNotesIndex(root: root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Saved copy

    func testApplyAddsUpdatesAndRemovesNotesToMatchTheScan() throws {
        let first = try store.apply(scan(release, build), agents: [.claudeCode, .codex])
        XCTAssertEqual(first, .init(added: 2))
        XCTAssertEqual(try index.counts(), ["claude-code": 1, "codex": 1])

        XCTAssertTrue(try store.apply(scan(release, build), agents: [.claudeCode, .codex]).isEmpty,
                      "an unchanged scan writes nothing")

        var edited = release
        edited.text = "Tag the release by SHA, then wait for the notarization email."
        let second = try store.apply(scan(edited), agents: [.claudeCode, .codex])
        XCTAssertEqual(second, .init(updated: 1, removed: 1))
        XCTAssertEqual(try index.search("notarization", limit: 5).map(\.id), [release.id])
        XCTAssertTrue(try index.search("xcodebuild", limit: 5).isEmpty, "a removed note leaves the word index too")
    }

    func testAnUnreadableFileIsNotADeletion() throws {
        try store.apply(scan(release, build), agents: [.claudeCode, .codex])
        var partial = scan(release)
        partial.unreadableFiles = ["/Users/me/.codex/memories/MEMORY.md"]

        XCTAssertTrue(try store.apply(partial, agents: [.claudeCode, .codex]).isEmpty)
        XCTAssertEqual(try index.counts()["codex"], 1)
    }

    func testAnAgentTurnedOffLosesItsNotesEvenWhenAFileWasUnreadable() throws {
        try store.apply(scan(release, build), agents: [.claudeCode, .codex])
        var onlyClaude = scan(release, build)
        onlyClaude.unreadableFiles = ["/somewhere"]

        let change = try store.apply(onlyClaude, agents: [.claudeCode])

        XCTAssertEqual(change, .init(removed: 1))
        XCTAssertEqual(try index.counts(), ["claude-code": 1])
    }

    func testDeleteAllRemovesTheSavedCopy() throws {
        try store.apply(scan(release), agents: [.claudeCode])
        XCTAssertTrue(index.exists)
        let attributes = try FileManager.default.attributesOfItem(atPath: index.databaseURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)

        store.deleteAll()

        XCTAssertFalse(index.exists)
        XCTAssertTrue(try index.search("release", limit: 5).isEmpty, "searching never recreates it")
        XCTAssertFalse(index.exists)
    }

    // MARK: - Search

    func testSearchPrefersEveryWordThenFallsBackToAnyAndRanksTitlesFirst() throws {
        var mention = build
        mention.id = "c0ffee000003"
        mention.title = "Unrelated chores"
        mention.text = "Remember the release checklist lives in the wiki."
        try store.apply(scan(release, build, mention), agents: [.claudeCode, .codex])

        let hits = try index.search("release", limit: 5)
        XCTAssertEqual(hits.map(\.id), [release.id, mention.id], "a title match outranks a mention in the text")
        XCTAssertEqual(hits.first?.agentName, "Claude Code")
        XCTAssertEqual(hits.first?.sourceLabel, "Claude Code · app")
        XCTAssertTrue(hits.last?.snippet.contains("«release»") == true)

        XCTAssertEqual(try index.search("release SHA", limit: 5).map(\.id), [release.id])
        XCTAssertEqual(Set(try index.search("xcodebuild gardening", limit: 5).map(\.id)), [build.id],
                       "no note has both words, so any word matches")
        XCTAssertEqual(try index.search("notar", limit: 5).count, 0)
        XCTAssertEqual(try index.search("rele", limit: 5).count, 2, "the word being typed matches as a prefix")
        XCTAssertEqual(try index.search("release", agent: "codex", limit: 5).map(\.id), [mention.id])
        XCTAssertTrue(try index.search("  ", limit: 5).isEmpty)
        XCTAssertTrue(try index.search("\"); DROP TABLE notes; --", limit: 5).isEmpty)
        XCTAssertEqual(try index.counts().values.reduce(0, +), 3)
    }

    func testSearchFindsWordsInsideChineseText() throws {
        var chinese = release
        chinese.id = "c0ffee000004"
        chinese.title = "发布流程"
        chinese.text = "发布前先运行全部单元测试，然后打标签。"
        try store.apply(scan(chinese), agents: [.claudeCode])

        XCTAssertEqual(try index.search("单元测试", limit: 5).map(\.id), [chinese.id])
    }

    func testHitAndTextLookUpOneNote() throws {
        try store.apply(scan(release), agents: [.claudeCode])

        XCTAssertEqual(try index.hit(id: release.id)?.title, "Release runbook")
        XCTAssertEqual(try index.text(of: release.id), release.text)
        XCTAssertNil(try index.hit(id: "000000000000"))
    }

    // MARK: - Background reader

    func testIngestorReadsOnlyWhileOnAndDeletesWhenTurnedOff() async throws {
        var configuration = AgentMemoryIngestor.Configuration(enabled: false, agents: [.claudeCode])
        let scans = Counter()
        let notes = [release]
        let ingestor = AgentMemoryIngestor(
            store: store, configuration: { configuration },
            scan: { _ in
                scans.increment()
                return AgentMemoryScan(notes: notes)
            })

        ingestor.start()
        await ingestor.refresh()
        XCTAssertEqual(scans.value, 0, "nothing is read before the person turns it on")
        XCTAssertFalse(index.exists)

        configuration.enabled = true
        await ingestor.refresh()
        XCTAssertEqual(scans.value, 1)
        XCTAssertEqual(ingestor.counts, [.claudeCode: 1])
        XCTAssertEqual(ingestor.total, 1)

        configuration.enabled = false
        ingestor.start()
        try await waitUntil { !self.index.exists }
        XCTAssertTrue(ingestor.counts.isEmpty)
    }

    func testSettingsChooseTheAgentsAndFoldersForNotes() {
        var settings = AppSettings()
        XCTAssertFalse(settings.codingAgentNotesEnabled, "notes are off until turned on")
        XCTAssertFalse(AgentMemoryIngestor.Configuration(settings: settings).reads)

        settings.codingAgentNotesEnabled = true
        settings.codingAgentEvidenceEnabled = false
        settings.codingAgentReadsCodex = false
        settings.codingAgentExcludedFolders = "~/Secret, /tmp/x"
        let configuration = AgentMemoryIngestor.Configuration(settings: settings)
        XCTAssertTrue(configuration.reads, "notes do not depend on reading sessions")
        XCTAssertEqual(configuration.agents, [.claudeCode])
        XCTAssertEqual(configuration.excludedFolders, ["~/Secret", "/tmp/x"])

        settings.codingAgentReadsClaudeCode = false
        XCTAssertFalse(AgentMemoryIngestor.Configuration(settings: settings).reads)
    }

    // MARK: - External agents

    func testSearchForAgentsNeedsItsOwnGrantThenSavedNotes() throws {
        let gate = AgentNotesAccessGate(root: root)
        XCTAssertEqual(report("release", gate: gate).failure, .disabled)

        try gate.enable()
        let marker = try FileManager.default.attributesOfItem(atPath: gate.accessMarkerURL.path)
        XCTAssertEqual((marker[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual(report("release", gate: gate).failure, .unavailable, "nothing saved: the feature is off")
        XCTAssertFalse(index.exists, "searching never creates the saved copy")

        try store.apply(scan(release, build), agents: [.claudeCode, .codex])
        let found = try XCTUnwrap(report("release", gate: gate).success)
        XCTAssertEqual(found.results.map(\.id), [release.id])
        XCTAssertEqual(found.results.first?.agent, "claude-code")
        XCTAssertEqual(found.results.first?.project, "/Users/me/GitHub/app")
        XCTAssertEqual(found.results.first?.type, "project")
        XCTAssertEqual(found.results.first?.text, release.text)
        XCTAssertTrue(AgentNotesSearchTool.json(found).contains("\"matched_by\" : \"words\""))
        XCTAssertTrue(AgentNotesSearchTool.table(found).contains("Release runbook · /Users/me/GitHub/app"))

        XCTAssertEqual(report("release", agent: "cursor", gate: gate).failure,
                       .invalid("\"agent\" must be one of claude-code, codex."))
        XCTAssertEqual(report("release", limit: 0, gate: gate).failure,
                       .invalid("\"limit\" must be an integer between 1 and 30."))
        XCTAssertEqual(report(" ", gate: gate).failure?.commandError, nil)

        gate.disable()
        XCTAssertEqual(report("release", gate: gate).failure?.commandError?.code, .agentNotesAccessDisabled)
    }

    func testTheMCPToolIsRefusedWithoutItsGrantWhateverElseIsGranted() async throws {
        let meetings = AgentAccessGate(root: root)
        try meetings.enable()
        try FilesAccessGate(root: root).enable()
        try store.apply(scan(release), agents: [.claudeCode])
        let provider = FileLibraryToolProvider(gate: meetings, ask: { _ in .text("") })
        XCTAssertEqual(provider.tools.last?.name, "search_agent_notes")

        let refused = await provider.call(name: "search_agent_notes", arguments: ["query": "release"])
        XCTAssertTrue(refused.isError)
        XCTAssertTrue(refused.text.hasPrefix("[agent_notes_access_disabled]"), refused.text)

        try AgentNotesAccessGate(root: root).enable()
        let found = await provider.call(name: "search_agent_notes", arguments: ["query": "release"])
        XCTAssertFalse(found.isError, found.text)
        XCTAssertTrue(found.text.contains("Release runbook"))
        let invalid = await provider.call(name: "search_agent_notes", arguments: ["query": "release", "agent": 3])
        XCTAssertTrue(invalid.text.hasPrefix("[invalid_arguments]"), invalid.text)
    }

    func testTheGrantIsItsOwnBoxAndStaysOffOnUpgrade() throws {
        setenv("LOKALBOT_STORAGE_ROOT", root.path, 1)
        defer { unsetenv("LOKALBOT_STORAGE_ROOT") }
        let access = AgentReadAccess(
            meetings: AgentAccessManager(storage: StorageManager(), settings: { AppSettings() },
                                         gate: AgentAccessGate(root: root), startEngine: { _, _ in nil }),
            screenMemory: ScreenMemoryAccessManager(gate: ScreenMemoryAccessGate(root: root)),
            personalContext: PersonalContextAccessManager(gate: PersonalContextAccessGate(root: root), claims: { [] }),
            files: FilesAccessManager(gate: FilesAccessGate(root: root), folders: { nil }),
            root: root)
        access.setEnabled(true)
        XCTAssertFalse(access.isGranted(.agentNotes), "turning the switch on grants only the remembered boxes")
        XCTAssertFalse(AgentNotesAccessGate(root: root).isEnabled)

        access.setTicked(.agentNotes, true)
        XCTAssertTrue(AgentNotesAccessGate(root: root).isEnabled)
        access.setEnabled(false)
        XCTAssertFalse(AgentNotesAccessGate(root: root).isEnabled)
        access.setEnabled(true)
        XCTAssertTrue(access.isGranted(.agentNotes), "the box is remembered across the switch")
    }

    func testTheBriefingSaysWhetherNotesCanBeSearched() throws {
        let provider = FileLibraryToolProvider(gate: AgentAccessGate(root: root), ask: { _ in .text("") })
        XCTAssertTrue(provider.briefing().contains("- Agent notes: off."))

        try AgentNotesAccessGate(root: root).enable()
        XCTAssertTrue(provider.briefing().contains("- Agent notes: on, but Read coding agent notes is off"))

        try store.apply(scan(release, build), agents: [.claudeCode, .codex])
        XCTAssertTrue(provider.briefing().contains("- Agent notes: on, 2 notes"))
        XCTAssertTrue(provider.briefing().contains("Tool: search_agent_notes."))
        XCTAssertTrue(provider.briefing(vocabulary: .cli).contains("Command: search-notes."))
    }

    // MARK: - Ask

    func testAgentNotesIsPartOfAllSourcesButOfferedOnlyWhileOn() {
        XCTAssertTrue(AskSourceScope.defaults.contains(.agentNotes))
        XCTAssertEqual(AskSourceScope.available(filesEnabled: false, agentNotesEnabled: true),
                       [.meetings, .today, .screen, .agentNotes])
        XCTAssertFalse(AskSourceScope.available(filesEnabled: true).contains(.agentNotes))
        XCTAssertEqual(AskSourceScope.scopes(fromStorageValue: "Meetings|Agent notes"), [.meetings, .agentNotes])
        XCTAssertNil(AskFacet.agentNotes.kind)
        XCTAssertTrue(CompanionAskResponder.scopes(for: .init()).isDisjoint(with: [.agentNotes]))
    }

    func testSearchAgentNotesNeedsItsSource() async {
        let base = NotesRecordingRunner()
        let without = ScopedChatToolRunner(base: base, scopes: [.meetings, .files])
        XCTAssertFalse(without.specs.map(\.name).contains("search_agent_notes"))
        let denied = await without.run(ChatToolCall(name: "search_agent_notes", arguments: ["query": "release"]))
        XCTAssertEqual(denied.summary, "source not enabled")
        XCTAssertNil(base.lastCall)

        let with = ScopedChatToolRunner(base: base, scopes: [.agentNotes])
        XCTAssertEqual(with.specs.map(\.name), ["search_agent_notes"])
    }

    func testMeetingToolsOfferSearchAgentNotesOnlyWhileNotesAreSaved() async throws {
        let storage = StorageManager(rootURL: root)
        let sqlite = root.appendingPathComponent("lokalbotv3.sqlite")
        var notes: AgentNotesIndex?
        let tools = MeetingChatTools(
            meetings: { [] }, storage: storage, searchIndex: SearchIndex(databaseURL: sqlite),
            embeddingIndex: EmbeddingIndex(databaseURL: sqlite, storage: storage, embedder: EmbeddingIndex.unavailableEmbedder),
            activityStore: ActivityStore(databaseURL: sqlite), settings: { AppSettings() }, agentNotes: { notes })
        XCTAssertFalse(tools.specs.map(\.name).contains("search_agent_notes"))
        let off = await tools.run(ChatToolCall(name: "search_agent_notes", arguments: ["query": "release"]))
        XCTAssertEqual(off.summary, "agent notes off")

        try store.apply(scan(release, build), agents: [.claudeCode, .codex])
        notes = index
        XCTAssertTrue(tools.specs.map(\.name).contains("search_agent_notes"))
        let result = await tools.run(ChatToolCall(name: "search_agent_notes", arguments: ["query": "release SHA"]))
        XCTAssertEqual(result.evidence.noteIDs, [release.id])
        XCTAssertTrue(result.text.contains("[note:\(release.id)] Release runbook (Claude Code · app"), result.text)
        XCTAssertTrue(result.text.contains("Tag the release by SHA"), result.text)
        XCTAssertTrue(result.text.contains("not a verified fact"), result.text)
        XCTAssertEqual(result.summary, "“release SHA” — 1 note")
    }

    func testNoteCitationsNeedEvidenceFromThisTurn() {
        let answer = "Releases are tagged by SHA [note:c0ffee000001]. Builds use Bazel [note:c0ffee0000ff]."
        let parsed = ChatCitationParser.extract(answer)
        XCTAssertEqual(parsed.citations.map(\.noteID), ["c0ffee000001", "c0ffee0000ff"])
        XCTAssertEqual(parsed.display, "Releases are tagged by SHA [1]. Builds use Bazel [2].")

        let verified = ChatCitationParser.verified(answer, evidence: ChatEvidence(noteIDs: ["c0ffee000001"]))
        XCTAssertTrue(verified.contains("[note:c0ffee000001]"))
        XCTAssertFalse(verified.contains("[note:c0ffee0000ff]"))
        XCTAssertTrue(verified.contains("(source not verified)"))
        XCTAssertTrue(ChatCitationParser.extract("[note:xyz] [note:12] [note:C0FFEE000001@00:10]").citations.isEmpty)
        XCTAssertEqual(ChatCitationParser.verified("Sure [note:c0ffee", evidence: ChatEvidence(), streaming: true), "Sure ")

        var evidence = ChatEvidence(fileIDs: [1])
        evidence.merge(ChatEvidence(noteIDs: ["c0ffee000001"]))
        XCTAssertTrue(evidence.contains(ChatCitation(noteID: "C0FFEE000001")))
        XCTAssertFalse(evidence.contains(ChatCitation(fileID: 2)))
    }

    func testThePromptMentionsAgentNotesOnlyWhenTheToolIsOffered() {
        let without = ChatPrompt.systemPrompt(tools: [], libraryOverview: "")
        XCTAssertFalse(without.contains("search_agent_notes"))
        XCTAssertFalse(without.contains("[note:ID]"))
        let with = ChatPrompt.systemPrompt(tools: [MeetingChatTools.searchAgentNotesSpec], libraryOverview: "")
        XCTAssertTrue(with.contains("Use search_agent_notes"))
        XCTAssertTrue(with.contains("not a verified fact"))
        XCTAssertTrue(with.contains("[note:ID]"))
    }

    func testAskingAboutResultsKeepsAgentNotesWhenNoteRowsWereShown() {
        var state = RecallWorkspaceState()
        state.selectResultEvidence(meetingIDs: [UUID()], screenIDs: [], hadAgentNotes: true)
        XCTAssertTrue(state.sources.contains(.agentNotes))

        var none = RecallWorkspaceState()
        none.selectResultEvidence(meetingIDs: [UUID()], screenIDs: [])
        XCTAssertFalse(none.sources.contains(.agentNotes))
    }

    func testANoteRowDescribesItselfInQuickRecall() throws {
        try store.apply(scan(release), agents: [.claudeCode])
        let hit = try XCTUnwrap(try index.search("release", limit: 1).first)
        let row = QuickRecallRowModel.agentNote(hit)

        XCTAssertEqual(row.id, "agentNote.\(release.id)")
        XCTAssertEqual(row.title, "Release runbook")
        XCTAssertEqual(row.subtitle, "Claude Code · app")
        XCTAssertEqual(row.timestamp, release.modifiedAt)
        if case .agentNote(let destination) = row.destination {
            XCTAssertEqual(destination.path, release.path)
        } else {
            XCTFail("a note row opens the note")
        }
    }

    // MARK: - Fixtures

    private var release: AgentMemoryNote {
        AgentMemoryNote(
            id: "c0ffee000001", agent: .claudeCode, title: "Release runbook",
            summary: "Per-release lessons", category: "project", workingDirectory: "/Users/me/GitHub/app",
            path: "/Users/me/.claude/projects/-Users-me-GitHub-app/memory/release.md",
            modifiedAt: Date(timeIntervalSince1970: 1_800_000_000),
            text: "Tag the release by SHA, never by branch name.")
    }

    private var build: AgentMemoryNote {
        AgentMemoryNote(
            id: "c0ffee000002", agent: .codex, title: "Build recipe", summary: nil, category: nil,
            workingDirectory: nil, path: "/Users/me/.codex/memories/MEMORY.md",
            modifiedAt: Date(timeIntervalSince1970: 1_800_000_100),
            text: "Run xcodebuild with a derived data path outside Documents.")
    }

    private func scan(_ notes: AgentMemoryNote...) -> AgentMemoryScan {
        AgentMemoryScan(notes: notes)
    }

    private func report(_ query: String, agent: String? = nil, limit: Int? = nil,
                        gate: AgentNotesAccessGate) -> Result<AgentNotesSearchTool.Report, AgentNotesSearchTool.Failure> {
        AgentNotesSearchTool.report(query: query, agent: agent, limit: limit, gate: gate)
    }

    private func waitUntil(_ condition: @escaping () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("the condition never held")
    }
}

private extension Result {
    var success: Success? { try? get() }
    var failure: Failure? {
        if case .failure(let failure) = self { return failure }
        return nil
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

private final class NotesRecordingRunner: ChatToolRunner {
    let specs = [MeetingChatTools.searchAgentNotesSpec,
                 ChatToolSpec(name: "search_meetings", summary: "meetings", arguments: [])]
    var lastCall: ChatToolCall?

    func libraryOverview() -> String { "" }
    func run(_ call: ChatToolCall) async -> ChatToolResult {
        lastCall = call
        return ChatToolResult(text: "ok", summary: "ok")
    }
}
