import XCTest
@testable import LokalBot

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

    func testReasoningHeavyModelFitsInTheRoomLeftForThinking() async throws {
        try await server.load([
            StubRule.reasoning(focusJSON, tokens: 2_030, system: focus),
            StubRule.reply(digestJSON, system: aggregate),
        ])
        let result = try await DayDigestOverviewGenerator.generateResult(
            evidence: evidence(blocks: 1), engine: engine, customPrompt: "", calendar: calendar,
            sleep: { _ in })
        XCTAssertEqual(result.quality, .complete)
        let focusRequests = try await server.requests().filter { $0.system.hasPrefix(focus) }
        XCTAssertEqual(focusRequests.map(\.maxTokens), [DayDigestOverviewGenerator.focusTokens * 2])
    }

    func testReplyThatSpendsItsWholeOutputThinkingIsRetriedOnceWithoutReasoning() async throws {
        try await server.load([
            StubRule.reasoning("Done", tokens: 50_000, nth: 1),
            StubRule.reply("Done"),
        ])

        let reply = try await engine.generate(system: "system", prompt: "prompt", context: [],
                                              options: .init(maxTokens: 512))

        XCTAssertEqual(reply, "Done")
        let requests = try await server.requests()
        XCTAssertEqual(requests.map(\.maxTokens), [1_024, 512])
        XCTAssertNil(requests[0].body["reasoning"], "the first request keeps the model's default")
        XCTAssertEqual((requests[1].body["reasoning"] as? [String: Any])?["effort"] as? String, "none")
    }

    func testAllReasoningReplyWithKeepsTruncatedReplyStillRetriesOnceWithoutReasoning() async throws {
        try await server.load([
            StubRule.reasoning(#"{"notes":[],"actions":[]}"#, tokens: 1_100, nth: 1),
            StubRule.reply(#"{"notes":[],"actions":[]}"#),
        ])
        let budget = MeetingGenerationBudget()

        let result = try await budget.run {
            try await MeetingNotesGenerator.request(
                engine: self.engine,
                system: "system",
                prompt: "prompt",
                context: [],
                schema: ["type": "object", "properties": [:], "required": [], "additionalProperties": false],
                tokens: 512,
                stage: "repair-1",
                contextTokens: 32_768,
                budget: budget,
                reasoning: .modelDefault)
        }

        XCTAssertEqual(result.content, #"{"notes":[],"actions":[]}"#)
        XCTAssertFalse(result.truncated)
        let requests = try await server.requests()
        XCTAssertEqual(requests.map(\.maxTokens), [1_024, 512])
        XCTAssertNil(requests[0].body["reasoning"])
        XCTAssertEqual((requests[1].body["reasoning"] as? [String: Any])?["effort"] as? String, "none")
    }

    func testRecordingTextEngineLogsWireMaxTokensAndRetriesAllReasoningReplies() async throws {
        try await server.load([
            StubRule.reasoning("Done", tokens: 50_000, nth: 1),
            StubRule.reply("Done"),
        ])
        let recorder = RecordingTextEngine(base: engine, requestLimit: 5)

        let reply = try await recorder.generate(
            system: "system",
            prompt: "prompt",
            context: [],
            options: .init(maxTokens: 512, keepsTruncatedReply: true))

        XCTAssertEqual(reply, "Done")
        XCTAssertEqual(recorder.calls.map(\.maxTokens), [1_024, 512])
        XCTAssertEqual(recorder.calls.map(\.reasoning), ["modelDefault", "off"])
        XCTAssertEqual(recorder.calls.map(\.finishReason), ["length", "stop"])
    }

    func testAnOffRequestThatRunsOutIsNotRetried() async throws {
        try await server.load([StubRule.reasoning("Done", tokens: 50_000)])

        do {
            _ = try await engine.generate(system: "system", prompt: "prompt", context: [],
                                          options: .init(maxTokens: 512, reasoning: .off))
            XCTFail("expected a truncated reply")
        } catch TextEngineError.outputTruncated {}

        let requests = try await server.requests()
        XCTAssertEqual(requests.count, 1)
    }

    func testReasoningFallbackInsideANotesBudgetIsChargedAsASecondRequest() async throws {
        try await server.load([
            StubRule.reasoning("Done", tokens: 1_100, nth: 1),
            StubRule.reply("Done"),
        ])
        let budget = MeetingGenerationBudget()
        let engine = engine

        let reply = try await budget.run {
            try await engine.generate(system: "system", prompt: "prompt", context: [],
                                      options: .init(maxTokens: 512))
        }

        XCTAssertEqual(reply, "Done")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        await budget.saveMetrics(in: folder, outcome: "test")
        let report = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: folder.appendingPathComponent("notes-generation-metrics.json"))) as? [String: Any])
        XCTAssertEqual(report["requests"] as? Int, 2)
        let calls = try XCTUnwrap(report["calls"] as? [[String: Any]])
        XCTAssertEqual(calls.map { $0["outcome"] as? String }, ["truncated", "complete"])
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
