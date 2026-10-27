import Combine
import XCTest
@testable import LokalBot

/// Live Radar: what one pass sends, which replies survive the grounding
/// checks, and the pass loop over a scripted live transcript. No network.
final class MeetingRadarAnalyzerTests: XCTestCase {
    private let meetingID = UUID()
    private let earlierID = UUID()
    private let date = Date(timeIntervalSince1970: 1_793_000_000)

    private func line(_ number: Int, _ time: TimeInterval, _ speaker: String, _ text: String) -> MeetingRadarAnalyzer.Line {
        .init(label: "L\(number)", time: time, speaker: speaker, text: text)
    }

    private func request(existing: [RadarItem] = []) -> MeetingRadarAnalyzer.Request {
        var request = MeetingRadarAnalyzer.Request(
            meetingID: meetingID, meetingTitle: "Synthetic launch sync", meetingDate: date,
            attendees: ["Ana", "Marko"], existing: existing,
            earlierLines: [line(1, 600, "them", "The pricing page has to ship before the launch.")],
            newLines: [line(2, 726, "local", "I'll send the revised pricing deck to Marko by Friday."),
                       line(3, 735, "them", "Did we decide whether the free tier keeps three projects?"),
                       line(4, 744, "them", "So the launch is Friday the seventh now, right?")])
        request.excerpts = [.init(label: "E1", evidence: RadarEvidence(
            meetingID: earlierID, meetingTitle: "Synthetic planning", meetingDate: date.addingTimeInterval(-86_400 * 8),
            time: 740, speaker: "Ana", text: "We agreed the launch is Monday the third."))]
        return request
    }

    private func item(_ id: String, _ kind: RadarItem.Kind, _ text: String, quote: String) -> RadarItem {
        RadarItem(id: id, kind: kind, text: text, owner: nil, due: nil, quote: quote, time: 0, speaker: "them",
                  earlier: nil, foundAt: date, model: "muse-spark-1.3")
    }

    private func reply(_ items: [[String: String]], answered: [String] = []) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: ["items": items, "answered": answered]), as: UTF8.self)
    }

    func testPromptSeparatesContextFromNewLinesAndListsEvidence() {
        let prompt = MeetingRadarAnalyzer.prompt(request(existing: [
            item("r1", .decision, "Pricing page ships before launch", quote: "pricing page has to ship")]))
        XCTAssertTrue(prompt.contains("invited: Ana, Marko"))
        XCTAssertTrue(prompt.contains("r1 decision: Pricing page ships before launch"))
        XCTAssertTrue(prompt.contains("E1 · Synthetic planning"))
        XCTAssertTrue(prompt.contains("\"We agreed the launch is Monday the third.\""))
        let context = try? XCTUnwrap(prompt.range(of: "EARLIER IN THIS MEETING:"))
        let fresh = try? XCTUnwrap(prompt.range(of: "NEW LINES:"))
        XCTAssertLessThan(context!.lowerBound, fresh!.lowerBound)
        XCTAssertTrue(prompt.contains("[L2 12:06] Me: I'll send the revised pricing deck"))
        XCTAssertTrue(prompt.contains("[L3 12:15] Others: Did we decide"))
    }

    func testSchemaIsStrict() {
        XCTAssertNil(OpenAIStrictSchemaValidator.validationIssue(in: MeetingRadarAnalyzer.schema))
    }

    func testKeepsGroundedItemsAndAttachesContradictionEvidence() throws {
        var next = 0
        let outcome = MeetingRadarAnalyzer.apply(reply: try reply([
            ["kind": "commitment", "text": "Send the revised pricing deck to Marko", "owner": "me", "due": "by Friday",
             "line": "L2", "quote": "send the revised pricing deck to Marko", "evidence": ""],
            ["kind": "question", "text": "Does the free tier keep three projects?", "owner": "", "due": "",
             "line": "L3", "quote": "whether the free tier keeps three projects", "evidence": ""],
            ["kind": "contradiction", "text": "Launch moved from Monday the 3rd to Friday the 7th", "owner": "", "due": "",
             "line": "L4", "quote": "the launch is Friday the seventh now", "evidence": "e1"],
        ]), to: request(), nextID: &next, model: "muse-spark-1.3", now: date)

        XCTAssertEqual(outcome.rejected, 0)
        XCTAssertEqual(outcome.added.map(\.id), ["r1", "r2", "r3"])
        XCTAssertEqual(next, 3)
        let commitment = outcome.added[0]
        XCTAssertEqual(commitment.owner, "Me")
        XCTAssertEqual(commitment.due, "by Friday")
        XCTAssertEqual(commitment.time, 726)
        XCTAssertEqual(commitment.speaker, "local")
        XCTAssertTrue(commitment.isUserCommitment)
        XCTAssertNil(outcome.added[1].owner, "only commitments carry an owner")
        XCTAssertEqual(outcome.added[2].earlier?.meetingID, earlierID)
        XCTAssertEqual(outcome.added[2].earlier?.isCurrentMeeting, false)
    }

    func testRejectsInventedQuotesAndUnsupportedContradictions() throws {
        var next = 0
        let outcome = MeetingRadarAnalyzer.apply(reply: try reply([
            // Not said in any new line.
            ["kind": "commitment", "text": "Ana books the venue", "owner": "Ana", "due": "",
             "line": "L3", "quote": "Ana will book the venue tomorrow", "evidence": ""],
            // Quoted from context, not from a new line.
            ["kind": "decision", "text": "Pricing page ships first", "owner": "", "due": "",
             "line": "L1", "quote": "pricing page has to ship before the launch", "evidence": ""],
            // A contradiction must cite a passage it was shown.
            ["kind": "contradiction", "text": "Launch date changed", "owner": "", "due": "",
             "line": "L4", "quote": "the launch is Friday the seventh now", "evidence": "E9"],
            ["kind": "summary", "text": "Not a kind", "owner": "", "due": "", "line": "L2",
             "quote": "send the revised pricing deck", "evidence": ""],
        ]), to: request(), nextID: &next, model: "muse-spark-1.3")
        XCTAssertTrue(outcome.added.isEmpty)
        XCTAssertEqual(outcome.rejected, 4)
        XCTAssertEqual(next, 0)
        XCTAssertEqual(MeetingRadarAnalyzer.apply(reply: "not json", to: request(), nextID: &next, model: "m").rejected, 1)
    }

    func testContradictionMayCiteAnEarlierLineOfThisMeeting() throws {
        var next = 0
        let outcome = MeetingRadarAnalyzer.apply(reply: try reply([
            ["kind": "contradiction", "text": "Launch now said to be Friday", "owner": "", "due": "",
             "line": "L4", "quote": "launch is Friday the seventh", "evidence": "L1"],
        ]), to: request(), nextID: &next, model: "muse-spark-1.3")
        XCTAssertEqual(outcome.added.first?.earlier?.isCurrentMeeting, true)
        XCTAssertEqual(outcome.added.first?.earlier?.meetingID, meetingID)
        XCTAssertEqual(outcome.added.first?.earlier?.time, 600)
    }

    func testSkipsDuplicatesAndMarksAnsweredQuestions() throws {
        var next = 5
        let existing = [
            item("r4", .commitment, "Send the revised pricing deck to Marko", quote: "I'll send the revised pricing deck"),
            item("r5", .question, "Who owns the onboarding emails?", quote: "who owns the onboarding emails"),
        ]
        let outcome = MeetingRadarAnalyzer.apply(reply: try reply([
            ["kind": "commitment", "text": "Send revised pricing deck to Marko", "owner": "Me", "due": "Friday",
             "line": "L2", "quote": "I'll send the revised pricing deck to Marko", "evidence": ""],
        ], answered: ["r5", "r4", "r99"]), to: request(existing: existing), nextID: &next, model: "m")
        XCTAssertTrue(outcome.added.isEmpty)
        XCTAssertEqual(outcome.rejected, 1)
        XCTAssertEqual(outcome.answeredIDs, ["r5"], "only open questions can be answered")
        XCTAssertEqual(next, 5)
    }

    func testQuoteMatchingToleratesPunctuationButNotParaphrase() {
        let line = "Okay, so — I'll send the revised pricing deck to Marko by Friday."
        XCTAssertTrue(MeetingRadarAnalyzer.quoteMatches("I'll send the revised pricing deck", line: line))
        XCTAssertTrue(MeetingRadarAnalyzer.quoteMatches("I will send the revised pricing deck to Marko", line: line))
        XCTAssertFalse(MeetingRadarAnalyzer.quoteMatches("Marko gets the slides next week", line: line))
        XCTAssertFalse(MeetingRadarAnalyzer.quoteMatches("pricing deck", line: line), "short quotes must be the whole line")
        XCTAssertTrue(MeetingRadarAnalyzer.quoteMatches("Agreed.", line: "agreed"))
    }

    func testCapsItemsPerPass() throws {
        var next = 0
        let many = (0..<9).map { index in
            ["kind": "question", "text": "Distinct synthetic question number \(index) \(String(repeating: "x", count: index))",
             "owner": "", "due": "", "line": "L3", "quote": "Did we decide whether the free tier", "evidence": ""]
        }
        let outcome = MeetingRadarAnalyzer.apply(reply: try reply(many), to: request(), nextID: &next, model: "m")
        XCTAssertLessThanOrEqual(outcome.added.count, MeetingRadarAnalyzer.maximumItemsPerPass)
    }
}

@MainActor
private final class ScriptedFeed: RadarLineFeed {
    let subject = CurrentValueSubject<[LiveMeetingTranscriber.Line], Never>([])
    var isRunning = false
    var activations = 0
    var linesPublisher: AnyPublisher<[LiveMeetingTranscriber.Line], Never> { subject.eraseToAnyPublisher() }
    var currentLines: [LiveMeetingTranscriber.Line] { subject.value }
    func activatePreview() {
        activations += 1
        isRunning = true
    }
}

@MainActor
private final class StubEvidence: RadarEvidenceSource {
    var queries: [String] = []
    func evidence(for text: String, meeting: Meeting, limit: Int) async -> [RadarEvidence] {
        queries.append(text)
        return []
    }
}

@MainActor
final class MeetingRadarTests: XCTestCase {
    private var folder: URL!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("radar-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func approvedSettings() -> AppSettings {
        var settings = AppSettings()
        settings.approvedRemoteInferenceOrigins = ["https://api.meta.ai"]
        return settings
    }

    private func waitUntil(_ condition: @autoclosure () -> Bool, timeout: TimeInterval = 3) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try? await Task.sleep(for: .milliseconds(10)) }
    }

    func testRadarNeedsApprovalBeforeAnythingIsSent() {
        var settings = AppSettings()
        settings.approvedRemoteInferenceOrigins = []
        XCTAssertEqual(MeetingRadar.unavailableReason(settings), MetaModelAPI.ConnectionError.notApproved.errorDescription)
        let feed = ScriptedFeed()
        var calls = 0
        let radar = MeetingRadar(transcriber: feed, evidenceSource: StubEvidence(), settings: { settings },
                                 call: { _, _, _ in calls += 1; throw CancellationError() })
        let meeting = Meeting(id: UUID(), title: "Synthetic", appName: "Meet", startedAt: Date(), relativePath: "m")
        radar.start(meeting: meeting, folder: folder)
        XCTAssertEqual(feed.activations, 0, "an unapproved radar must not start the preview")
        XCTAssertEqual(calls, 0)
        if case .failed = radar.state {} else { XCTFail("expected a failed state, got \(radar.state)") }
    }

    func testPassesSendOnlyNewLinesAndFinishReadsTheRest() async throws {
        let feed = ScriptedFeed()
        let evidence = StubEvidence()
        var prompts: [String] = []
        let settings = approvedSettings()
        let radar = MeetingRadar(
            transcriber: feed, evidenceSource: evidence,
            settings: { settings },
            call: { messages, _, _ in
                let prompt = messages.last?["content"] as? String ?? ""
                prompts.append(prompt)
                let items: [[String: String]] = prompt.contains("I'll send the synthetic deck")
                    ? [["kind": "commitment", "text": "Send the synthetic deck to Ana", "owner": "Me",
                        "due": "Friday", "line": "L1", "quote": "I'll send the synthetic deck to Ana", "evidence": ""]]
                    : []
                let content = String(decoding: try JSONSerialization.data(
                    withJSONObject: ["items": items, "answered": [String]()]), as: UTF8.self)
                return MuseChatClient.Reply(content: content, toolCalls: [],
                                            usage: .init(inputTokens: 1_000, outputTokens: 100), finishReason: "stop")
            },
            // The stubbed call needs no key; approval is covered above.
            availability: { _ in nil },
            timing: .init(minimumInterval: .seconds(60), burstLines: 100, idlePoll: .milliseconds(5)))
        let meeting = Meeting(id: UUID(), title: "Synthetic sync", appName: "Meet", startedAt: Date(), relativePath: "m")

        radar.start(meeting: meeting, folder: folder)
        XCTAssertEqual(feed.activations, 1, "Start Radar turns the preview on")
        feed.subject.send([.init(time: 4, speaker: "local", text: "I'll send the synthetic deck to Ana by Friday.")])
        await waitUntil(radar.items.count == 1)
        XCTAssertEqual(radar.items.first?.owner, "Me")
        XCTAssertEqual(prompts.count, 1)

        // The interval holds the next line until the recording ends.
        let first = feed.subject.value
        feed.subject.send(first + [.init(time: 9, speaker: "them", text: "Sounds good, thanks.")])
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(prompts.count, 1)
        await radar.finish()
        XCTAssertEqual(prompts.count, 2)
        XCTAssertTrue(prompts[1].contains("[L2 00:09] Others: Sounds good"))
        XCTAssertFalse(prompts[1].components(separatedBy: "NEW LINES:").last?.contains("synthetic deck") ?? true,
                       "a line is sent as new only once")
        XCTAssertEqual(radar.state, .off)

        let saved = try XCTUnwrap(MeetingRadarRecord.load(from: folder))
        XCTAssertEqual(saved.items.map(\.text), ["Send the synthetic deck to Ana"])
        XCTAssertEqual(saved.passes.count, 2)
        XCTAssertEqual(saved.passes[0].cost, MetaModelAPI.cost(of: .init(inputTokens: 1_000, outputTokens: 100),
                                                               model: MetaModelAPI.museSpark.id), accuracy: 1e-12)
    }
}
