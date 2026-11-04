import XCTest
@testable import LokalBot

/// Questions from paired devices: citation markers become records.md's `[n]`
/// references, the answer streams as deltas, and the shared classes limit
/// what the agent may read.
@MainActor
final class CompanionAskResponderTests: XCTestCase {
    private let meeting = Meeting(
        id: UUID(uuidString: "3F6C2A10-8A4E-4D2B-9B1E-0A1B2C3D4E01")!,
        title: "Design review — onboarding", appName: "Zoom",
        startedAt: Date().addingTimeInterval(-86_400), endedAt: Date().addingTimeInterval(-84_000),
        relativePath: "meetings/2026/10/30-design-review")

    private var shortID: String { SessionLookup.shortID(meeting.id) }

    // MARK: - Citations

    func testMeetingMarkersBecomeNumberedCitations() throws {
        let answer = "You agreed to cut onboarding to three steps [meeting:\(shortID)@00:12:04]. "
            + "Maya asked for the deck [meeting:\(shortID)@00:12:04] and the notes [meeting:\(shortID)]."
        let mapped = CompanionAskCitations.map(answer, meetings: [meeting])
        XCTAssertEqual(mapped.answer, "You agreed to cut onboarding to three steps [1]. Maya asked for the deck [1] and the notes [2].")
        XCTAssertEqual(mapped.citations.count, 2)
        let first = try XCTUnwrap(mapped.citations.first)
        XCTAssertEqual(first.index, 1)
        XCTAssertEqual(first.meetingId, meeting.id.uuidString.lowercased())
        XCTAssertEqual(first.at, 724)
        XCTAssertEqual(first.label, "Design review — onboarding · 12:04")
        XCTAssertEqual(mapped.citations[1].index, 2)
        XCTAssertNil(mapped.citations[1].at)
        XCTAssertTrue(mapped.citations[1].label.hasPrefix("Design review — onboarding · "))
    }

    func testScreenFileAndUnknownCitationsCarryNoMeeting() {
        let mapped = CompanionAskCitations.map(
            "Seen on screen [screen:42]. In a file [file:7]. Unknown [meeting:deadbeef].", meetings: [meeting])
        XCTAssertEqual(mapped.answer, "Seen on screen [1]. In a file [2]. Unknown [3].")
        XCTAssertEqual(mapped.citations.map(\.label), ["Screen moment", "File", "Meeting"])
        XCTAssertTrue(mapped.citations.allSatisfy { $0.meetingId == nil })
    }

    func testClockLabels() {
        XCTAssertEqual(CompanionAskCitations.clock(724), "12:04")
        XCTAssertEqual(CompanionAskCitations.clock(3723), "1:02:03")
    }

    func testStreamSendsOnlyNewNumberedText() {
        let stream = CompanionAnswerStream()
        XCTAssertEqual(stream.next("You agreed"), "You agreed")
        XCTAssertEqual(stream.next("You agreed to three steps [meeting:\(shortID)@00:12:04]"), " to three steps [1]")
        XCTAssertNil(stream.next("You agreed to three steps [meeting:\(shortID)@00:12:04]"))
        // A restarted answer sends nothing; the final result replaces it.
        XCTAssertNil(stream.next("Different"))
    }

    func testToolsFollowTheSharedClasses() {
        XCTAssertEqual(CompanionAskResponder.scopes(for: .all), [.meetings, .today])
        // Screen memory and Files are never searched for a device, whatever Ask on the Mac allows.
        XCTAssertTrue(CompanionAskResponder.scopes(for: .all).isDisjoint(with: [.screen, .files]))
        var classes = CompanionSharing.DataClasses.all
        classes.windowTitles = false
        XCTAssertEqual(CompanionAskResponder.scopes(for: classes), [.meetings],
                       "the activity summary names windows")
        classes.meetings = false
        XCTAssertEqual(CompanionAskResponder.scopes(for: classes), [])
    }

    // MARK: - Answering

    func testAnswerStreamsAndFinishesWithMappedCitations() async throws {
        let engine = CompanionScriptedEngine([
            #"{"tool": "search_meetings", "arguments": {"query": "onboarding"}}"#,
            "FINAL_ANSWER:\nYou agreed to cut onboarding to three steps [meeting:\(shortID)@00:12:04].",
        ])
        var evidence = ChatEvidence()
        evidence.addMeeting(meeting.id, seconds: 724)
        let runner = CompanionFakeRunner(evidence: evidence)
        var settings = AppSettings()
        settings.companionSharingEnabled = true
        let meeting = meeting
        let responder = CompanionAskResponder(dependencies: .init(
            settings: { settings }, makeEngine: { engine }, tools: { runner }, meetings: { [meeting] }))
        let output = CompanionCollectingOutput()
        responder.answer(try CompanionJSON.encode(CompanionAskRequest(
            requestId: "r1", conversationId: "c1", question: "What did we decide about onboarding?")), output: output)
        await fulfillment(of: [output.finished], timeout: 10)

        XCTAssertNil(output.failure)
        XCTAssertEqual(runner.calls, ["search_meetings"])
        let result = try JSONDecoder().decode(CompanionAskResult.self, from: Data(try XCTUnwrap(output.result).utf8))
        XCTAssertEqual(result.requestId, "r1")
        XCTAssertEqual(result.answer, "You agreed to cut onboarding to three steps [1].")
        XCTAssertEqual(result.citations.first?.meetingId, meeting.id.uuidString.lowercased())
        XCTAssertEqual(result.citations.first?.at, 724)
        XCTAssertEqual(result.location, "mac")
        XCTAssertEqual(result.engineLabel, settings.thinkModelDisplayName)
        XCTAssertEqual(output.deltas.joined(), result.answer)
    }

    /// A question asked from "Ask About Today" on an iPad answered "the
    /// library has only one meeting": the tools saw one day, and nothing told
    /// the model so. The prompt and the meeting list now name the limit.
    func testDayLimitedQuestionTellsTheModelItCannotSeeOtherDays() async throws {
        let engine = CompanionScriptedEngine([
            #"{"tool": "list_meetings", "arguments": {}}"#,
            "FINAL_ANSWER:\nThis question is limited to today.",
        ])
        let runner = CompanionFakeRunner(evidence: ChatEvidence())
        var settings = AppSettings()
        settings.companionSharingEnabled = true
        let responder = CompanionAskResponder(dependencies: .init(
            settings: { settings }, makeEngine: { engine }, tools: { runner }, meetings: { [] }))
        let day = AskDayScope.key(for: Date())
        let phrase = try XCTUnwrap(AskDateScope(storageKey: day)).phrase
        let output = CompanionCollectingOutput()
        responder.answer(try CompanionJSON.encode(CompanionAskRequest(
            requestId: "r4", question: "Do you see other meetings in the library?",
            scope: .init(day: day))), output: output)
        await fulfillment(of: [output.finished], timeout: 10)

        XCTAssertNil(output.failure)
        XCTAssertEqual(runner.calls, ["list_meetings"])
        let system = try XCTUnwrap(engine.systems.first)
        XCTAssertTrue(system.contains("Question scope:\nThis question is limited to what happened \(phrase)."), system)
        XCTAssertTrue(system.contains("Never describe what the tools return as the whole library"), system)
        XCTAssertTrue(system.contains("remove the date limit"), system)
        let observation = try XCTUnwrap(engine.contexts.last?.last)
        XCTAssertTrue(observation.hasPrefix(
            "Observation: Limited to what happened \(phrase) for this question; nothing outside that limit is shown.\n"),
                      observation)
    }

    func testSharedHistoryWindowIsNamedAsTheLimit() async throws {
        let engine = CompanionScriptedEngine(["FINAL_ANSWER:\nOnly the last 30 days are shared."])
        var settings = AppSettings()
        settings.companionSharingEnabled = true
        settings.companionHistory = .days30
        let responder = CompanionAskResponder(dependencies: .init(
            settings: { settings }, makeEngine: { engine },
            tools: { CompanionFakeRunner(evidence: ChatEvidence()) }, meetings: { [] }))
        let output = CompanionCollectingOutput()
        responder.answer(try CompanionJSON.encode(CompanionAskRequest(
            requestId: "r5", question: "How many meetings do I have?")), output: output)
        await fulfillment(of: [output.finished], timeout: 10)

        XCTAssertNil(output.failure)
        let system = try XCTUnwrap(engine.systems.first)
        XCTAssertTrue(system.contains(
            "This question is limited to meetings from the last 30 days, the history the user shares with this device."),
                      system)
        XCTAssertFalse(system.contains("remove the date limit"), "the device cannot widen what the Mac shares")
    }

    func testAnsweringOffFailsWithoutRunningTheModel() async throws {
        var settings = AppSettings()
        settings.companionSharingEnabled = true
        settings.companionAnswersQuestions = false
        var engineMade = false
        let responder = CompanionAskResponder(dependencies: .init(
            settings: { settings },
            makeEngine: { engineMade = true; return CompanionScriptedEngine([]) },
            tools: { CompanionFakeRunner(evidence: ChatEvidence()) }, meetings: { [] }))
        let output = CompanionCollectingOutput()
        responder.answer(try CompanionJSON.encode(CompanionAskRequest(requestId: "r2", question: "Anything?")),
                         output: output)
        await fulfillment(of: [output.finished], timeout: 1)
        XCTAssertEqual(output.failure, "Answering questions from your devices is turned off on your Mac.")
        XCTAssertFalse(engineMade)
    }

    func testOutOfWindowScopeIsRefused() async throws {
        var settings = AppSettings()
        settings.companionSharingEnabled = true
        settings.companionHistory = .days30
        let responder = CompanionAskResponder(dependencies: .init(
            settings: { settings }, makeEngine: { CompanionScriptedEngine([]) },
            tools: { CompanionFakeRunner(evidence: ChatEvidence()) }, meetings: { [] }))
        let output = CompanionCollectingOutput()
        responder.answer(try CompanionJSON.encode(CompanionAskRequest(
            requestId: "r3", question: "What happened?", scope: .init(day: "2020-01-01"))), output: output)
        await fulfillment(of: [output.finished], timeout: 1)
        XCTAssertEqual(output.failure, "That day is not shared with this device.")
    }
}

// MARK: - Test doubles

private final class CompanionScriptedEngine: TextEngine {
    private var outputs: [String]
    private(set) var systems: [String] = []
    private(set) var contexts: [[String]] = []

    init(_ outputs: [String]) { self.outputs = outputs }

    var displayName: String { "Scripted" }

    func generate(system: String, prompt: String, context: [String]) async throws -> String {
        outputs.isEmpty ? "" : outputs.removeFirst()
    }

    func generateStreaming(system: String, prompt: String, context: [String],
                           options: TextGenerationOptions,
                           onPartial: @escaping @MainActor (String) -> Void) async throws -> String {
        systems.append(system)
        contexts.append(context)
        let output = outputs.isEmpty ? "" : outputs.removeFirst()
        // Stream in three growing prefixes, as a server would.
        for fraction in [0.4, 0.7, 1.0] {
            let partial = String(output.prefix(Int(Double(output.count) * fraction)))
            await MainActor.run { onPartial(partial) }
        }
        return output
    }
}

@MainActor
private final class CompanionFakeRunner: ChatToolRunner {
    let evidence: ChatEvidence
    private(set) var calls: [String] = []

    init(evidence: ChatEvidence) { self.evidence = evidence }

    var specs: [ChatToolSpec] {
        ["search_meetings", "list_meetings", "activity_summary", "search_screen"].map {
            ChatToolSpec(name: $0, summary: "test", arguments: [])
        }
    }

    func libraryOverview() -> String { "" }

    func run(_ call: ChatToolCall) async -> ChatToolResult {
        calls.append(call.name)
        return ChatToolResult(text: "Design review: three steps agreed @ 00:12:04", summary: "1 hit", evidence: evidence)
    }
}

private final class CompanionCollectingOutput: CompanionAskOutput, @unchecked Sendable {
    let finished = XCTestExpectation(description: "answer finished")
    private(set) var deltas: [String] = []
    private(set) var result: String?
    private(set) var failure: String?

    func delta(_ text: String) { deltas.append(text) }
    func done(_ resultJSON: String) { result = resultJSON; finished.fulfill() }
    func failed(_ message: String) { failure = message; finished.fulfill() }
}
