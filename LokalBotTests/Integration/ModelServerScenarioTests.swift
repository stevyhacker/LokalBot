import XCTest
@testable import LokalBot

/// Digest and Ask through the real `OpenAICompatibleEngine` (OpenRouter
/// dialect) against the scenario stub, so request shaping and recovery are
/// exercised end to end.
final class ModelServerScenarioTests: XCTestCase {
    private var server: ModelStubServer!

    override func setUpWithError() throws {
        server = try ModelStubServer()
    }

    override func tearDown() {
        server?.stop()
    }

    private var engine: OpenAICompatibleEngine {
        OpenAICompatibleEngine(baseURL: server.baseURL, model: "stub-model", apiKey: nil,
                               chatDialect: .openRouter)
    }

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func evidence(blocks: Int) -> DayDigestEvidence {
        let day = calendar.date(from: DateComponents(year: 2026, month: 8, day: 4, hour: 12))!
        let hours = [8, 13, 16]
        return DayDigestEvidence.build(
            day: day,
            blocks: (0..<blocks).map { index in
                let start = calendar.date(from: DateComponents(year: 2026, month: 8, day: 4, hour: hours[index]))!
                return ActivityBlock(id: Int64(index + 1), app: "Xcode", title: "Task \(index + 1)",
                                     start: start, end: start.addingTimeInterval(45 * 60))
            },
            screenContexts: [], meetings: [], calendar: calendar)
    }

    private let focusJSON = #"{"substantive":true,"task":"Fix the cache","work_done":"Fixed the cache eviction bug.","status":"completed","outcome":"Tests pass.","next_step":"","source_ids":[]}"#
    private let digestJSON = #"{"tasks":[{"title":"Fix the cache","status":"completed","summary":"Fixed the cache eviction bug.","next_step":"","block_indices":[0,1]}],"decisions":[],"blockers":[]}"#
    private var focus: String { ModelRequestPurpose.digestFocus.systemMarker }
    private var aggregate: String { ModelRequestPurpose.digestAggregate.systemMarker }

    func testPurposeMarkersAreDistinct() {
        let markers = ModelRequestPurpose.allCases.map(\.systemMarker)
        XCTAssertEqual(Set(markers).count, markers.count)
        XCTAssertFalse(markers.contains(""))
    }

    func testPurposeMarkersFileMatchesTheApp() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(
            forResource: "purpose-markers", withExtension: "json", subdirectory: "Fixtures/model-recordings"))
        let file = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: url))
        let expected = Dictionary(uniqueKeysWithValues: ModelRequestPurpose.allCases.map { ($0.rawValue, $0.systemMarker) })
        XCTAssertEqual(file, expected, "regenerate purpose-markers.json from ModelRequestPurpose.systemMarker")
    }

    func testPurposeMarkersAppearInTheRealPrompts() {
        XCTAssertEqual(ModelRequestPurpose.classify(system: PromptTemplates.dayDigestFocusSystem), .digestFocus)
        XCTAssertEqual(ModelRequestPurpose.classify(system: PromptTemplates.dayDigestSystem(custom: "")), .digestAggregate)
        XCTAssertEqual(ModelRequestPurpose.classify(system: PromptTemplates.dayDigestFallbackSystem(custom: "")),
                       .digestAggregate)
        for template in NoteTemplate.allCases {
            XCTAssertEqual(ModelRequestPurpose.classify(
                system: MeetingNotesGenerator.systemPrompt(template: template, language: .matchTranscript)), .notes)
        }
        XCTAssertEqual(ModelRequestPurpose.classify(
            system: PromptTemplates.meetingNotesRepairSystem(language: .matchTranscript)), .notesRepair)
        XCTAssertEqual(ModelRequestPurpose.classify(
            system: ChatPrompt.systemPrompt(tools: [], libraryOverview: "")), .ask)
    }

    func testDigestSegmentSurvivesA503AndReplaysTheSameRequest() async throws {
        try await server.load([
            StubRule.http(503, system: focus, nth: 1),
            StubRule.reply(focusJSON, system: focus),
            StubRule.reply(digestJSON, system: aggregate),
        ])
        let result = try await DayDigestOverviewGenerator.generateResult(
            evidence: evidence(blocks: 2), engine: engine, customPrompt: "", calendar: calendar,
            sleep: { _ in })
        XCTAssertEqual(result.quality, .complete)
        let requests = try await server.requests()
        XCTAssertEqual(requests.count, 4)
        XCTAssertEqual(requests[0].user, requests[1].user)
    }

    /// A model that always reasons rejects `none`; the chosen level must not
    /// fail the request, and the retry must be the only extra call.
    func testRejectedReasoningLevelRetriesOnceAtLow() async throws {
        try await server.load([
            StubRule.http(400, message: "reasoning_effort 'none' is not supported for this model", nth: 1),
            StubRule.reply("Done"),
        ])
        let generic = OpenAICompatibleEngine(baseURL: server.baseURL, model: "stub-model", apiKey: nil,
                                             reasoningLevel: .off)

        let reply = try await generic.generate(system: "system", prompt: "prompt", context: [])

        XCTAssertEqual(reply, "Done")
        let requests = try await server.requests()
        XCTAssertEqual(requests.map { $0.body["reasoning_effort"] as? String }, ["none", "low"])
    }

    func testRetryAfterFromA429IsHonoured() async throws {
        try await server.load([
            StubRule.http(429, retryAfter: 7, system: focus, nth: 1),
            StubRule.reply(focusJSON, system: focus),
            StubRule.reply(digestJSON, system: aggregate),
        ])
        let delays = SleepLog()
        _ = try await DayDigestOverviewGenerator.generateResult(
            evidence: evidence(blocks: 1), engine: engine, customPrompt: "", calendar: calendar,
            sleep: { await delays.record($0) })
        let recorded = await delays.values
        XCTAssertEqual(recorded, [7])
    }

    func testReasoningHeavyModelFitsOnTheLargerRetry() async throws {
        try await server.load([
            StubRule.reasoning(focusJSON, tokens: 2_030, system: focus), // ~40-token answer no longer fits in 2,048
            StubRule.reply(digestJSON, system: aggregate),
        ])
        let result = try await DayDigestOverviewGenerator.generateResult(
            evidence: evidence(blocks: 1), engine: engine, customPrompt: "", calendar: calendar,
            sleep: { _ in })
        XCTAssertEqual(result.quality, .complete)
        let focusRequests = try await server.requests().filter { $0.system.hasPrefix(focus) }
        XCTAssertEqual(focusRequests.map(\.maxTokens),
                       [DayDigestOverviewGenerator.focusTokens, DayDigestOverviewGenerator.focusRetryTokens])
    }

    func testMalformedJSONTakesTheRetryPrompt() async throws {
        try await server.load([
            StubRule.malformed("invalid-json", system: focus, nth: 1),
            StubRule.reply(focusJSON, system: focus),
            StubRule.reply(digestJSON, system: aggregate),
        ])
        let result = try await DayDigestOverviewGenerator.generateResult(
            evidence: evidence(blocks: 1), engine: engine, customPrompt: "", calendar: calendar,
            sleep: { _ in })
        XCTAssertEqual(result.quality, .complete)
        let second = try await server.requests()[1]
        XCTAssertTrue(second.user.contains("failed JSON validation"))
    }

    func testDroppedConnectionStopsWithPartialQuality() async throws {
        try await server.load([
            StubRule.reply(focusJSON, system: focus, nth: 1),
            StubRule.drop(system: focus),
            StubRule.reply(digestJSON, system: aggregate),
        ])
        let result = try await DayDigestOverviewGenerator.generateResult(
            evidence: evidence(blocks: 2), engine: engine, customPrompt: "", calendar: calendar,
            sleep: { _ in })
        XCTAssertEqual(result.quality, .partial)
        XCTAssertEqual(try XCTUnwrap(result.coverage?.ratio), 0.5, accuracy: 0.01)
    }

    @MainActor
    func testAskStreamsAFinalAnswer() async throws {
        try await server.load([StubRule.reply("FINAL_ANSWER:\nRedis was chosen.", chunks: 5)])
        let agent = ChatAgent(engine: engine, runner: EmptyToolRunner())
        let answer = try await agent.respond(history: [], latest: "What did we choose?") { _ in }
        XCTAssertEqual(answer, "Redis was chosen.")
    }

    @MainActor
    func testAskSlowFirstByteStillCompletes() async throws {
        try await server.load([StubRule.slow("FINAL_ANSWER:\nLate but fine.", firstByteMs: 1_500, chunkMs: 100)])
        let agent = ChatAgent(engine: engine, runner: EmptyToolRunner())
        let answer = try await agent.respond(history: [], latest: "Status?") { _ in }
        XCTAssertEqual(answer, "Late but fine.")
    }

    /// A refused streamed request reported "empty error response": the
    /// error was built without reading the body the provider sent.
    func testARefusedStreamKeepsTheProvidersReason() async throws {
        try await server.load([StubRule.http(402, message: "Insufficient credits for this request")])
        do {
            _ = try await engine.generateStreaming(
                system: "Answer briefly.", prompt: "Status?", context: [],
                options: TextGenerationOptions(maxTokens: 64)) { _ in }
            XCTFail("a refused stream must not produce an answer")
        } catch TextEngineError.httpStatus(let code, let detail, _) {
            XCTAssertEqual(code, 402)
            XCTAssertTrue(detail.contains("Insufficient credits"), detail)
        }
    }

    @MainActor
    func testAskDroppedStreamSurfacesAnError() async throws {
        try await server.load([StubRule.drop()])
        let agent = ChatAgent(engine: engine, runner: EmptyToolRunner())
        do {
            _ = try await agent.respond(history: [], latest: "Status?") { _ in }
            XCTFail("a dropped stream must not produce an answer")
        } catch {
            // Expected: the engine reports the lost connection.
        }
    }
}

actor SleepLog {
    private(set) var values: [TimeInterval] = []
    func record(_ value: TimeInterval) { values.append(value) }
}

@MainActor
final class EmptyToolRunner: ChatToolRunner {
    var specs: [ChatToolSpec] { [] }
    func libraryOverview() -> String { "No meetings." }
    func run(_ call: ChatToolCall) async -> ChatToolResult {
        fatalError("no tools in this scenario")
    }
}
