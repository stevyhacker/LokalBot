import DigUpKit
import XCTest
@testable import LokalBot

/// Files in Ask: the source, the agent's `search_files` tool, `[file:]`
/// citations and the result-evidence boundary.
@MainActor
final class FileSearchAskTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("files-ask-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testFilesIsPartOfAllSourcesButOfferedOnlyWhileOn() {
        XCTAssertTrue(AskSourceScope.defaults.contains(.files))
        XCTAssertEqual(Set(AskSourceScope.allCases), AskSourceScope.defaults)
        XCTAssertEqual(AskSourceScope.available(filesEnabled: false), [.meetings, .today, .screen])
        XCTAssertEqual(AskSourceScope.available(filesEnabled: true), [.meetings, .today, .screen, .files])
        XCTAssertEqual(AskSourceScope.files.rawValue, "Files")
        XCTAssertEqual(AskSourceScope.scopes(fromStorageValue: "Meetings|Files"), [.meetings, .files])
        XCTAssertNil(AskFacet.files.kind)
    }

    func testSearchFilesNeedsTheFilesSourceAndKeepsTheQuestionsDates() async {
        let base = FilesRecordingRunner()
        let without = ScopedChatToolRunner(base: base, scopes: [.meetings, .screen])
        XCTAssertFalse(without.specs.map(\.name).contains("search_files"))
        let denied = await without.run(ChatToolCall(name: "search_files", arguments: ["query": "lease"]))
        XCTAssertEqual(denied.summary, "source not enabled")
        XCTAssertNil(base.lastCall)

        let with = ScopedChatToolRunner(base: base, scopes: [.files], dayScopeKey: "2026-10-30")
        XCTAssertEqual(with.specs.map(\.name), ["search_files"])
        _ = await with.run(ChatToolCall(name: "search_files",
                                        arguments: ["query": "lease", "_lokalbot_day_scope": "2020-01-01"]))
        XCTAssertEqual(base.lastCall?.arguments["_lokalbot_day_scope"], "2026-10-30",
                       "a model cannot widen the question's dates")
    }

    func testFileCitationsNeedEvidenceFromThisTurn() {
        let answer = "The lease allows cats [file:42]. Dogs need consent [file:7]."
        let parsed = ChatCitationParser.extract(answer)
        XCTAssertEqual(parsed.citations.map(\.fileID), [42, 7])
        XCTAssertEqual(parsed.display, "The lease allows cats [1]. Dogs need consent [2].")

        let verified = ChatCitationParser.verified(answer, evidence: ChatEvidence(fileIDs: [42]))
        XCTAssertTrue(verified.contains("[file:42]"))
        XCTAssertFalse(verified.contains("[file:7]"))
        XCTAssertTrue(verified.contains("(source not verified)"))
        XCTAssertTrue(ChatCitationParser.extract("[file:0] [file:x]").citations.isEmpty)

        var evidence = ChatEvidence(screenIDs: [1])
        evidence.merge(ChatEvidence(fileIDs: [9]))
        XCTAssertTrue(evidence.contains(ChatCitation(fileID: 9)))
        XCTAssertFalse(evidence.contains(ChatCitation(snapshotID: 9)))
    }

    func testThePromptMentionsFilesOnlyWhenTheToolIsOffered() {
        let without = ChatPrompt.systemPrompt(tools: [], libraryOverview: "")
        XCTAssertFalse(without.contains("search_files"))
        XCTAssertFalse(without.contains("[file:ID]"))
        let with = ChatPrompt.systemPrompt(tools: [MeetingChatTools.searchFilesSpec], libraryOverview: "")
        XCTAssertTrue(with.contains("Use search_files"))
        XCTAssertTrue(with.contains("[file:ID]"))
    }

    func testMeetingToolsOfferSearchFilesOnlyWhileFilesIsAvailable() async throws {
        let storage = StorageManager(rootURL: root)
        let sqlite = root.appendingPathComponent("lokalbotv3.sqlite")
        var settings = AppSettings()
        settings.semanticSearchEnabled = false
        var files: FileSearchService?
        let tools = MeetingChatTools(
            meetings: { [] }, storage: storage, searchIndex: SearchIndex(databaseURL: sqlite),
            embeddingIndex: EmbeddingIndex(databaseURL: sqlite, storage: storage, embedder: EmbeddingIndex.unavailableEmbedder),
            activityStore: ActivityStore(databaseURL: sqlite), settings: { settings }, files: { files })
        XCTAssertFalse(tools.specs.map(\.name).contains("search_files"))
        let off = await tools.run(ChatToolCall(name: "search_files", arguments: ["query": "lease"]))
        XCTAssertEqual(off.summary, "files off")

        let folder = root.appendingPathComponent("Docs", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try String(repeating: "The apartment lease lets tenants keep one cat with written consent. ", count: 6)
            .write(to: folder.appendingPathComponent("lease.txt"), atomically: true, encoding: .utf8)
        let service = FileSearchService(
            indexFolder: root.appendingPathComponent(FileSearchService.indexFolderName, isDirectory: true),
            startEmbedder: { _ in
                .init(source: WordsEmbedder.workerInfo.vectorSource, makeEmbedder: { WordsEmbedder() }, end: {})
            })
        service.apply(.init(enabled: true, folders: [folder.path]))
        await service.waitUntilIdle()
        files = service

        XCTAssertTrue(tools.specs.map(\.name).contains("search_files"))
        let result = await tools.run(ChatToolCall(name: "search_files", arguments: ["query": "lease cat"]))
        let id = try XCTUnwrap(result.evidence.fileIDs.first)
        XCTAssertTrue(result.text.contains("[file:\(id)] lease.txt"), result.text)
        XCTAssertTrue(result.text.contains("one cat with written consent"), result.text)
        XCTAssertEqual(result.summary, "“lease cat” — 1 file")
    }

    func testAskingAboutResultsKeepsFilesWhenFileRowsWereShown() {
        var state = RecallWorkspaceState()
        state.selectResultEvidence(meetingIDs: [UUID()], screenIDs: [], hadFiles: true)
        XCTAssertTrue(state.sources.contains(.files))

        var noFiles = RecallWorkspaceState()
        noFiles.selectResultEvidence(meetingIDs: [UUID()], screenIDs: [], hadFiles: false)
        XCTAssertFalse(noFiles.sources.contains(.files))

        var deselected = RecallWorkspaceState()
        deselected.chooseSources([.meetings])
        deselected.selectResultEvidence(meetingIDs: [UUID()], screenIDs: [], hadFiles: true)
        XCTAssertFalse(deselected.sources.contains(.files), "a source the person turned off stays off")
    }

    func testFileHitsDescribeThemselves() {
        let pdf = FileSearchHit(id: 3, path: "/Users/me/Documents/Lease.pdf", kind: .pdf, page: 4,
                                excerpt: "«pets» are allowed", modified: Date(timeIntervalSince1970: 0),
                                isSemantic: false)
        XCTAssertEqual(pdf.name, "Lease.pdf")
        XCTAssertEqual(pdf.kindLabel, "PDF · page 4")
        let row = QuickRecallRowModel.file(pdf)
        XCTAssertEqual(row.id, "file.3")
        XCTAssertEqual(row.title, "Lease.pdf")
        XCTAssertNotNil(FileSearchHit.exifDate("2026:05:14 18:02:11"))
        XCTAssertNil(FileSearchHit.exifDate("not a date"))
    }
}

private final class FilesRecordingRunner: ChatToolRunner {
    let specs = [MeetingChatTools.searchFilesSpec,
                 ChatToolSpec(name: "search_meetings", summary: "meetings", arguments: [])]
    var lastCall: ChatToolCall?

    func libraryOverview() -> String { "" }
    func run(_ call: ChatToolCall) async -> ChatToolResult {
        lastCall = call
        return ChatToolResult(text: "ok", summary: "ok")
    }
}

/// Every text points the same way, so search here is by words.
private final class WordsEmbedder: Embedder {
    static let workerInfo = WorkerInfo(model: "test/words", revision: "0000000", runtime: "words", dtype: "f32",
                                       dim: 768, textOnly: false, loadSeconds: nil)
    let info = WordsEmbedder.workerInfo
    private static let unit: [Float] = (0..<768).map { $0 == 0 ? 1 : 0 }
    func embedTexts(_ texts: [String]) throws -> [[Float]] { texts.map { _ in Self.unit } }
    func embedImages(_ paths: [String], budget: Int) throws -> [Embedding] {
        paths.map { _ in Embedding(vector: Self.unit, error: nil) }
    }
    func embedAudio(_ paths: [String]) throws -> [Embedding] {
        paths.map { _ in Embedding(vector: Self.unit, error: nil) }
    }
    func close() {}
}
