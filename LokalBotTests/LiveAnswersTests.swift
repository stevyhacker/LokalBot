import Combine
import XCTest
@testable import LokalBot

@MainActor
private final class StubAnswerEnvironment: LiveAnswerEnvironment {
    var contextItems: [LiveAnswerContext] = []
    var placeList: [LiveAnswerPlace] = []
    func context(for question: String, meeting: LiveAnswerMeeting) async -> [LiveAnswerContext] { contextItems }
    func places() async -> [LiveAnswerPlace] { placeList }
    var libraryToolSpecs: [ChatToolSpec] { [] }
    func runLibraryTool(_ call: ChatToolCall) async -> LiveAnswerToolOutput { .message("none") }
}

@MainActor
private final class StillFeed: RadarLineFeed {
    let subject = CurrentValueSubject<[LiveMeetingTranscriber.Line], Never>([])
    var isRunning = false
    var deliversTurns = true
    var linesPublisher: AnyPublisher<[LiveMeetingTranscriber.Line], Never> { subject.eraseToAnyPublisher() }
    var currentLines: [LiveMeetingTranscriber.Line] { subject.value }
    func activatePreview() { isRunning = true }
}

@MainActor
private final class NoEvidence: RadarEvidenceSource {
    func evidence(for text: String, meeting: Meeting, limit: Int) async -> [RadarEvidence] { [] }
}

private func toolReply(_ name: String, _ arguments: [String: Any], id: String = "call_1") -> MuseChatClient.Reply {
    let json = (try? JSONSerialization.data(withJSONObject: arguments)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    return MuseChatClient.Reply(content: "", toolCalls: [.init(id: id, name: name, arguments: json)],
                                usage: .init(inputTokens: 900, outputTokens: 80), finishReason: "tool_calls")
}

private let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

final class LiveAnswersTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("live-answers-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    /// A git repository with one tracked file and one untracked file.
    private func makeRepository() async throws -> LiveAnswerPlace {
        let repo = folder.appendingPathComponent("Widget", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try "struct Panel {\n    let hiddenFromSharing = true\n}\n".write(to: repo.appendingPathComponent("Panel.swift"),
                                                                           atomically: true, encoding: .utf8)
        try "let secretPlan = 1\n".write(to: repo.appendingPathComponent("Scratch.swift"), atomically: true, encoding: .utf8)
        _ = try await LiveAnswerTools.git(["init", "-q"], in: repo)
        _ = try await LiveAnswerTools.git(["add", "Panel.swift"], in: repo)
        _ = try await LiveAnswerTools.git(["-c", "user.name=Test", "-c", "user.email=test@example.com",
                                           "commit", "-q", "-m", "Hide the panel from sharing"], in: repo)
        let places = await LiveAnswerPlace.load([repo.path])
        return try XCTUnwrap(places.first)
    }

    // MARK: - Documents

    func testSpreadsheetXMLReadsSharedAndInlineStrings() {
        let strings = XLSX.sharedStrings(#"<sst><si><t>Plan</t></si><si><t>Team &amp; Co</t></si></sst>"#)
        XCTAssertEqual(strings, ["Plan", "Team & Co"])
        let rows = XLSX.rows(#"<sheetData><row r="1"><c r="A1" t="s"><v>0</v></c><c r="B1"><v>12</v></c></row><row r="2"><c r="A2" t="s"><v>1</v></c><c r="B2" t="inlineStr"><is><t>per seat</t></is></c></row></sheetData>"#,
                             strings: strings)
        XCTAssertEqual(rows, ["Plan | 12", "Team & Co | per seat"])
    }

    func testDemoSheetAndBriefAreReadable() async throws {
        let files = repoRoot.appendingPathComponent("Docs/meta-hackathon/demo-files")
        let sheet = try await LiveAnswerTools.documentText(files.appendingPathComponent("Northwind pricing v2.xlsx"))
        XCTAssertTrue(sheet.contains("Team | $12 per seat"), sheet)
        let brief = try await LiveAnswerTools.documentText(files.appendingPathComponent("Northwind launch brief.pdf"))
        XCTAssertTrue(brief.contains("400 paying teams"), brief)
    }

    func testExcerptKeepsTheLinesAroundTheQuery() {
        let text = (1...200).map { "line \($0) filler" }.joined(separator: "\n") + "\nTeam plan costs twelve dollars\n"
        let excerpt = LiveAnswerTools.excerpt(of: text, query: "Team plan price")
        XCTAssertTrue(excerpt.contains("Team plan costs twelve dollars"))
        XCTAssertFalse(excerpt.contains("line 1 filler\n"))
    }

    func testDocumentNamesRankByTheQuerysWords() async throws {
        let docs = folder.appendingPathComponent("Northwind", isDirectory: true)
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        for name in ["Northwind pricing v2.xlsx", "Northwind launch brief.pdf", "notes.md"] {
            try "x".write(to: docs.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        let words = PersonalContextSelection.contentWords("Team plan price")
        XCTAssertEqual(LiveAnswerTools.nameScore("Northwind pricing v2", words: words), 1, "price finds pricing")
        XCTAssertEqual(LiveAnswerTools.nameScore("notes", words: words), 0)
        // Outside Spotlight's index (the temporary folder), names are ranked.
        let place = LiveAnswerPlace(name: "Northwind", url: docs, isRepository: false)
        let result = await LiveAnswerTools.searchDocuments("Q1 target in the launch brief", places: [place])
        XCTAssertTrue(result.text.hasPrefix("Northwind/Northwind launch brief.pdf"), result.text)
    }

    func testOnlyReadableFilesInsideApprovedFolders() throws {
        let docs = folder.appendingPathComponent("Docs", isDirectory: true)
        try FileManager.default.createDirectory(at: docs.appendingPathComponent(".private"), withIntermediateDirectories: true)
        let place = LiveAnswerPlace(name: "Docs", url: docs, isRepository: false)
        for name in ["notes.md", ".private/notes.md", ".env", "keys.pem"] {
            try "x".write(to: docs.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        XCTAssertTrue(LiveAnswerTools.isReadable(docs.appendingPathComponent("notes.md"), places: [place]))
        XCTAssertFalse(LiveAnswerTools.isReadable(docs.appendingPathComponent(".private/notes.md"), places: [place]))
        XCTAssertFalse(LiveAnswerTools.isReadable(docs.appendingPathComponent(".env"), places: [place]))
        XCTAssertFalse(LiveAnswerTools.isReadable(docs.appendingPathComponent("keys.pem"), places: [place]))
        XCTAssertFalse(LiveAnswerTools.isReadable(folder.appendingPathComponent("outside.md"), places: [place]))
        XCTAssertFalse(LiveAnswerTools.isReadable(docs.appendingPathComponent("../outside.md"), places: [place]))
        XCTAssertEqual(LiveAnswerTools.resolve("Docs/notes.md", places: [place])?.lastPathComponent, "notes.md")
    }

    func testGitHubRemotesAreRecognized() {
        XCTAssertEqual(LiveAnswerPlace.gitHubRepository(fromRemote: "https://github.com/stevyhacker/LokalBot.git"), "stevyhacker/LokalBot")
        XCTAssertEqual(LiveAnswerPlace.gitHubRepository(fromRemote: "git@github.com:stevyhacker/LokalBot.git"), "stevyhacker/LokalBot")
        XCTAssertNil(LiveAnswerPlace.gitHubRepository(fromRemote: "https://gitlab.com/a/b.git"))
    }

    // MARK: - Code

    func testCodeToolsReadOnlyTrackedFiles() async throws {
        let place = try await makeRepository()
        XCTAssertTrue(place.isRepository)
        let search = try await LiveAnswerTools.searchCode("hiddenFromSharing", in: place)
        XCTAssertEqual(search.lines.first?.title, "Panel.swift:2")
        let tracked = try await LiveAnswerTools.readFile("Panel.swift", from: 1, to: 3, in: place)
        XCTAssertTrue(tracked.text.contains("let hiddenFromSharing = true"))
        let untracked = try await LiveAnswerTools.readFile("Scratch.swift", from: 1, to: 3, in: place)
        XCTAssertNil(untracked.kind, "an untracked file is never read")
        XCTAssertFalse(untracked.text.contains("secretPlan"))
        let commits = try await LiveAnswerTools.recentCommits(query: "", path: "", in: place)
        XCTAssertTrue(commits.text.contains("Hide the panel from sharing"))
    }

    // MARK: - Grounding

    func testAnswersKeepOnlySourcesThatContainTheirQuote() {
        let output = LiveAnswerToolOutput(
            text: "Panel.swift:2:    let hiddenFromSharing = true", kind: .code, title: "Widget",
            lines: [LiveAnswerLine(text: "Panel.swift:2:    let hiddenFromSharing = true", title: "Panel.swift:2", link: "https://x/L2")])
        let answer = LiveAnswerSession.ground(
            ["text": "Yes, it's hidden.",
             "sources": [["id": "R1", "quote": "let hiddenFromSharing = true"],
                         ["id": "R1", "quote": "let hiddenFromSharing = false"],
                         ["id": "R9", "quote": "anything"]]],
            references: ["R1": output], model: "m", steps: [])
        XCTAssertEqual(answer?.sources.count, 1)
        XCTAssertEqual(answer?.sources.first?.title, "Panel.swift:2", "a quote found on one line cites that line")
        XCTAssertEqual(answer?.sources.first?.link, "https://x/L2")
        XCTAssertNil(LiveAnswerSession.ground(["text": "Yes.", "sources": [["id": "R1", "quote": "invented"]]],
                                              references: ["R1": output], model: "m", steps: []),
                     "an answer without one grounded source is dropped")
    }

    // MARK: - The loop

    @MainActor
    func testMemoryCanAnswerWithoutAnyLookup() async throws {
        let environment = StubAnswerEnvironment()
        environment.contextItems = [LiveAnswerContext(kind: .action, title: "Open actions",
                                                      text: "- Review the onboarding emails. Owner: Marko.")]
        var calls = 0
        let outcome = try await LiveAnswerSession.run(
            question: "Who reviews the onboarding emails?", quote: "", meeting: .init(title: "Sync", date: Date(), recentLines: []),
            environment: environment, model: "m",
            call: { messages, _, _ in
                calls += 1
                XCTAssertTrue((messages[1]["content"] as? String ?? "").contains("[C1] Open actions"))
                return toolReply("answer", ["text": "Marko.", "sources": [["id": "C1", "quote": "Owner: Marko"]]])
            },
            progress: { _ in })
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(outcome.answer?.text, "Marko.")
        XCTAssertEqual(outcome.answer?.sources.first?.kind, .action)
    }

    @MainActor
    func testLookupsThenAGroundedAnswer() async throws {
        let place = try await makeRepository()
        let environment = StubAnswerEnvironment()
        environment.placeList = [place]
        var steps: [String] = []
        var turn = 0
        let outcome = try await LiveAnswerSession.run(
            question: "Is the panel hidden when sharing?", quote: "", meeting: .init(title: "Sync", date: Date(), recentLines: []),
            environment: environment, model: "m",
            call: { messages, tools, _ in
                turn += 1
                if turn == 1 {
                    XCTAssertTrue(tools.contains { ($0["function"] as? [String: Any])?["name"] as? String == "search_code" })
                    return toolReply("search_code", ["repository": "Widget", "query": "hiddenFromSharing"])
                }
                let result = messages.last?["content"] as? String ?? ""
                XCTAssertTrue(result.hasPrefix("[R1]"), result)
                return toolReply("answer", ["text": "Yes, it's hidden from sharing.",
                                            "sources": [["id": "R1", "quote": "let hiddenFromSharing = true"]]], id: "call_2")
            },
            progress: { steps.append($0) })
        XCTAssertEqual(outcome.answer?.sources.first?.title, "Panel.swift:2")
        XCTAssertEqual(outcome.turns, 2)
        XCTAssertTrue(steps.contains { $0.contains("hiddenFromSharing") })
    }

    @MainActor
    func testNoAnswerIsAcceptedWithoutGuessing() async throws {
        let outcome = try await LiveAnswerSession.run(
            question: "What should we name it?", quote: "", meeting: .init(title: "Sync", date: Date(), recentLines: []),
            environment: StubAnswerEnvironment(), model: "m",
            call: { _, _, _ in toolReply("no_answer", ["reason": "an opinion"]) }, progress: { _ in })
        XCTAssertNil(outcome.answer)
        XCTAssertEqual(outcome.reason, "an opinion")
    }

    // MARK: - The radar

    @MainActor
    func testRadarAttachesALiveAnswerToACaughtQuestion() async throws {
        var settings = AppSettings()
        settings.approvedRemoteInferenceOrigins = ["https://api.meta.ai"]
        settings.liveAnswersEnabled = true
        let environment = StubAnswerEnvironment()
        environment.contextItems = [LiveAnswerContext(kind: .project, title: "Project Launch",
                                                      text: "The launch is Monday, November 3.")]
        let feed = StillFeed()
        let radar = MeetingRadar(
            transcriber: feed, evidenceSource: NoEvidence(), answerEnvironment: environment,
            answerCall: { _, _, _ in
                toolReply("answer", ["text": "Monday, November 3.",
                                     "sources": [["id": "C1", "quote": "The launch is Monday, November 3."]]])
            },
            settings: { settings },
            call: { _, _, _ in
                let items: [[String: String]] = [["kind": "question", "text": "When is the launch?", "owner": "", "due": "",
                                                  "line": "L1", "quote": "When is the launch again?", "evidence": ""]]
                let content = (try? JSONSerialization.data(withJSONObject: ["items": items, "answered": [String]()]))
                    .map { String(decoding: $0, as: UTF8.self) } ?? ""
                return MuseChatClient.Reply(content: content, toolCalls: [], usage: .init(), finishReason: "stop")
            },
            availability: { _ in nil },
            timing: .init(minimumInterval: .seconds(60), turnInterval: .milliseconds(1), idlePoll: .milliseconds(5)))
        radar.start(meeting: Meeting(id: UUID(), title: "Sync", appName: "Meet", startedAt: Date(), relativePath: "m"),
                    folder: folder)
        feed.subject.send([.init(time: 4, speaker: "them", text: "When is the launch again?")])
        let deadline = Date().addingTimeInterval(5)
        while radar.items.first?.answer == nil, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(radar.items.first?.answer?.text, "Monday, November 3.")
        XCTAssertEqual(radar.spotlightID, radar.items.first?.id)
        XCTAssertTrue(radar.answerSteps.isEmpty)
        await radar.finish()
        XCTAssertEqual(MeetingRadarRecord.load(from: folder)?.answerRequests?.count, 1)
    }
}
