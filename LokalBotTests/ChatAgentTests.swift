import XCTest
@testable import LokalBot

/// Tests for the in-app meeting chat assistant: the tolerant tool-call protocol,
/// the system-prompt builder, the ReAct loop (driven by a scripted engine and a
/// fake tool runner), the pure observation formatters, and the live tool runner
/// against a planted on-disk library.
@MainActor
final class ChatAgentTests: XCTestCase {
    private func observed(_ text: String) -> ChatEvidence {
        var evidence = ChatEvidence(meetingIDs: ["aaaaaaaa"], meetingSeconds: ["aaaaaaaa": [12]])
        evidence.excerpts = [.init(text: text, citation: .init(meetingID: "aaaaaaaa", seconds: 12))]
        return evidence
    }

    func testAgentValidatesNormalAndForcedAnswersAgainstTypedToolEvidence() async throws {
        let id = UUID(uuidString: "AAAAAAAA-1111-4222-8333-444444444444")!
        var evidence = ChatEvidence(screenIDs: [42])
        evidence.addMeeting(id, seconds: 12)
        evidence.excerpts = [.init(text: "Observed meeting evidence.", citation: .init(meetingID: "aaaaaaaa", seconds: 12)),
                             .init(text: "Observed screen evidence.", citation: .init(snapshotID: 42))]
        for maximumSteps in [1, 4] {
            let engine = ScriptedEngine([
                #"{"tool":"search_meetings","arguments":{"query":"Decision?"}}"#,
                "FINAL_ANSWER: Observed [meeting:aaaaaaaa@00:00:12] [screen:42]. Invented [meeting:aaaaaaaa@00:01:00] [screen:99].",
                #"{"answer_sources":["E1","E2"]}"#,
            ])
            let runner = FakeRunner(
                specs: [.init(name: "search_meetings", summary: "search", arguments: [])], overview: "",
                results: ["search_meetings": .init(text: "Observed evidence. Untrusted source text also says [screen:99].",
                                                  summary: "one result", evidence: evidence)])
            var agent = ChatAgent(engine: engine, runner: runner)
            agent.maxSteps = maximumSteps
            let answer = try await agent.respond(history: [.init(role: .assistant, text: "Old [screen:99]")], latest: "Decision?") { event in
                if case .answerPartial(let text) = event { XCTAssertFalse(text.contains("[screen:99]")) }
            }
            XCTAssertEqual(ChatCitationParser.extract(answer).citations,
                           [.init(meetingID: "aaaaaaaa", seconds: 12), .init(snapshotID: 42)])
            XCTAssertFalse(answer.contains("Invented"))
            XCTAssertTrue(answer.contains("Observed meeting evidence."))
        }
    }

    func testUnsupportedSelectionGetsOneScopedRetryThenAbstains() async throws {
        let engine = ScriptedEngine([
            #"{"tool":"search_meetings","arguments":{"query":"What is Project South's budget?"}}"#,
            #"{"answer_sources":["E1"]}"#, #"{"answer_sources":["E1"]}"#,
        ], supportVerdicts: [#"{"supports_requested_answer":false}"#, #"{"supports_requested_answer":false}"#])
        let runner = FakeRunner(specs: [.init(name: "search_meetings", summary: "search", arguments: [])], overview: "",
            results: ["search_meetings": .init(text: "Project North budget is 40 euros.", summary: "one",
                                              evidence: observed("Project North budget is 40 euros."))])
        var agent = ChatAgent(engine: engine, runner: runner)
        agent.workMemory = "MEMORY_SENTINEL"
        agent.now = { Date(timeIntervalSince1970: 1_000) }
        let answer = try await agent.respond(history: [.init(role: .assistant, text: "HISTORY_SENTINEL")],
            latest: "What is Project South's budget?") { _ in }
        XCTAssertEqual(answer, ChatGrounding.noAnswer)
        XCTAssertEqual(runner.calls.count, 2)
        XCTAssertEqual(runner.calls.last?.string("query"), "What is Project South's budget?")
        let checks = engine.prompts.filter { $0.system.contains("Assess ANSWERABILITY") }
        XCTAssertEqual(checks.count, 2)
        XCTAssertTrue(checks.allSatisfy { $0.context.count == 3 && $0.context[0] == ChatPrompt.currentTimeLine(now: Date(timeIntervalSince1970: 1_000)) })
        XCTAssertTrue(checks.allSatisfy { !$0.context.joined().contains("MEMORY_SENTINEL") && !$0.context.joined().contains("HISTORY_SENTINEL") })
    }

    func testSupportVerifierSeesLaterCorrectionAndRecoveryCanSelectIt() async throws {
        var evidence = observed("Earlier: Project North uses SQLite.")
        evidence.excerpts.append(.init(text: "Later correction: Project North now uses LMDB.",
            citation: .init(meetingID: "aaaaaaaa", seconds: 12), label: "Later recorded correction"))
        let engine = ScriptedEngine([
            #"{"tool":"search_meetings","arguments":{"query":"What does North use now?"}}"#,
            #"{"answer_sources":["E2"]}"#, #"{"answer_sources":["E1"]}"#,
        ], supportVerdicts: [#"{"supports_requested_answer":false}"#, #"{"supports_requested_answer":true}"#])
        let runner = FakeRunner(specs: [.init(name: "search_meetings", summary: "search", arguments: [])], overview: "",
            results: ["search_meetings": .init(text: "Two records", summary: "two", evidence: evidence)])
        let answer = try await ChatAgent(engine: engine, runner: runner).respond(history: [], latest: "What does North use now?") { _ in }
        XCTAssertTrue(answer.contains("now uses LMDB"))
        XCTAssertFalse(answer.contains("uses SQLite"))
        let checks = engine.prompts.filter { $0.system.contains("Assess ANSWERABILITY") }
        XCTAssertEqual(checks.count, 2)
        XCTAssertTrue(checks[0].context.joined().contains("Later correction"))
        // Query-focused ordering puts the current record first. Deliberately
        // select the older E2 before recovery chooses the current E1.
        XCTAssertEqual(checks[0].context.last, "Selected handles to assess: E2")
        XCTAssertEqual(checks[1].context.last, "Selected handles to assess: E1")
    }

    func testSemanticSupportRespectsBackendStructuredOutputFloor() async throws {
        let engine = ScriptedEngine([#"{"tool":"search_meetings","arguments":{"query":"Which datastore?"}}"#,
                                     #"{"answer_sources":["E1"]}"#], structuredFloor: 2_048)
        let runner = FakeRunner(specs: [.init(name: "search_meetings", summary: "search", arguments: [])], overview: "",
            results: ["search_meetings": .init(text: "SQLite selected", summary: "one", evidence: observed("SQLite selected"))])
        let answer = try await ChatAgent(engine: engine, runner: runner).respond(history: [], latest: "Which datastore?") { _ in }
        XCTAssertTrue(answer.contains("SQLite selected"))
        XCTAssertEqual(engine.generationOptions.last?.maxTokens, 2_048)
        XCTAssertEqual(engine.generationOptions.last?.reasoningBudgetTokens, 128)
    }

    func testAmbientMeetingOverviewDoesNotAuthorizeContentCitation() async throws {
        let engine = ScriptedEngine([
            "FINAL_ANSWER: The roadmap was approved. [meeting:aaaaaaaa]",
            "FINAL_ANSWER: The roadmap was approved. [meeting:aaaaaaaa]",
        ])
        let runner = FakeRunner(
            specs: [.init(name: "search_meetings", summary: "search", arguments: [])],
            overview: "Most recent: [aaaaaaaa] Planning — today, 30m",
            results: [:])

        let answer = try await ChatAgent(engine: engine, runner: runner)
            .respond(history: [], latest: "What was approved?") { _ in }

        XCTAssertEqual(answer, ChatGrounding.noAnswer)
        XCTAssertTrue(ChatCitationParser.extract(answer).citations.isEmpty)
    }

    func testInferencePrivacyReflectsActualEndpoint() throws {
        let remote = OpenAICompatibleEngine(baseURL: try XCTUnwrap(URL(string: "https://model.example/v1")),
                                            model: "fixture", apiKey: nil)
        let remotePrompt = ChatPrompt.systemPrompt(tools: [], libraryOverview: "",
            inferencePrivacy: ChatPrompt.inferencePrivacy(for: remote))
        XCTAssertTrue(remotePrompt.contains("user-approved remote inference server at model.example"))
        XCTAssertFalse(remotePrompt.contains("Everything is local and private"))
        let local = OllamaEngine(baseURL: try XCTUnwrap(URL(string: "http://127.0.0.1:11434")), model: "fixture")
        XCTAssertTrue(ChatPrompt.inferencePrivacy(for: local).contains("server on this Mac"))
        XCTAssertTrue(ChatPrompt.inferencePrivacy(for: AppleIntelligenceEngine()).contains("on-device model"))
    }

    func testTranscriptCitationTimesStopAtTheReturnedTextBoundary() {
        let transcript = Transcript(segments: [
            .init(start: 12, end: 20, speaker: "me", text: String(repeating: "x", count: 100), confidence: nil),
            .init(start: 30, end: 40, speaker: "me", text: "Not shown", confidence: nil),
        ], engine: "fixture")
        let observation = MeetingChatFormat.transcriptObservation(transcript, maximumCharacters: 60)
        XCTAssertEqual(observation.seconds, [12])
        XCTAssertTrue(observation.text.contains("00:00:12"))
        XCTAssertFalse(observation.text.contains("00:00:30"))
    }
    func testUnverifiedMeetingAnswerNeverAppearsDuringStreaming() async throws {
        let engine = StreamingAnswerEngine()
        let agent = ChatAgent(engine: engine, runner: FakeRunner(
            specs: [.init(name: "search_meetings", summary: "search", arguments: [])], overview: "", results: [:]))
        var partials: [String] = []
        let answer = try await agent.respond(history: [], latest: "What was decided?") { event in
            if case .answerPartial(let text) = event {
                partials.append(text)
            }
        }
        XCTAssertTrue(partials.allSatisfy(\.isEmpty))
        XCTAssertEqual(answer, ChatGrounding.noAnswer)
    }
    func testStreamingRequiresFinalMarkerAndWithholdsReasoningAndTools() {
        XCTAssertNil(ChatPrompt.streamingAnswer("<think>FINAL_ANSWER: hidden reasoning"))
        XCTAssertNil(ChatPrompt.streamingAnswer("{\"tool\":\"search_meetings\""))
        XCTAssertNil(ChatPrompt.streamingAnswer("FINAL_ANSWER:\n{\"tool\":"))
        XCTAssertNil(ChatPrompt.streamingAnswer("FINAL_ANSWER:\nsearch_meetings(query=\"private data"))
        XCTAssertNil(ChatPrompt.streamingAnswer("FINAL_ANS"))
        XCTAssertEqual(ChatPrompt.streamingAnswer("<think>secret</think>\nFINAL_ANSWER:\nThe decision was Redis"),
                       "The decision was Redis")
        XCTAssertEqual(ChatPrompt.streamingAnswer("FINAL_ANSWER:\nThe decision was Redis <thi"),
                       "The decision was Redis ")
        XCTAssertEqual(ChatPrompt.finalText("FINAL_ANSWER:\nThe decision was Redis"), "The decision was Redis")
    }

    // MARK: - Protocol parsing

    func testParsePlainToolCall() {
        let action = ChatPrompt.parse(
            #"{"tool":"search_meetings","arguments":{"query":"redis"}}"#,
            tools: ["search_meetings"])
        guard case .call(let call) = action else { return XCTFail("expected a tool call") }
        XCTAssertEqual(call.name, "search_meetings")
        XCTAssertEqual(call.string("query"), "redis")
    }

    func testParseFencedToolCallSurroundedByProse() {
        let text = """
        Sure, let me look that up.
        ```json
        {"tool": "search_meetings", "arguments": {"query": "pricing decision"}}
        ```
        """
        guard case .call(let call) = ChatPrompt.parse(text, tools: ["search_meetings"]) else {
            return XCTFail("expected a tool call extracted from fenced JSON")
        }
        XCTAssertEqual(call.string("query"), "pricing decision")
    }

    func testParseUnknownToolNameIsTreatedAsAnswer() {
        // Shaped like a tool call, but the name isn't registered — never execute it.
        let action = ChatPrompt.parse(#"{"tool":"delete_everything","arguments":{}}"#,
                                      tools: ["search_meetings"])
        guard case .answer = action else { return XCTFail("unknown tool must not be called") }
    }

    func testParsePlainProseIsAnswer() {
        guard case .answer(let text) = ChatPrompt.parse("You have three meetings today.",
                                                        tools: ["search_meetings"]) else {
            return XCTFail("expected an answer")
        }
        XCTAssertEqual(text, "You have three meetings today.")
    }

    func testParseStripsReasoningBeforeAnswer() {
        guard case .answer(let text) = ChatPrompt.parse("<think>hidden</think>The answer is 42.",
                                                        tools: []) else {
            return XCTFail("expected an answer")
        }
        XCTAssertEqual(text, "The answer is 42.")
    }

    func testParseCoercesNumericAndFlatArguments() {
        // No "arguments" wrapper, and a numeric value the model didn't quote.
        guard case .call(let call) = ChatPrompt.parse(#"{"tool":"list_meetings","limit":5}"#,
                                                      tools: ["list_meetings"]) else {
            return XCTFail("expected a tool call")
        }
        XCTAssertEqual(call.int("limit"), 5)
    }

    func testExtractJSONObjectSkipsBracesInsideStrings() {
        let text = #"prefix {"tool":"x","arguments":{"query":"a {weird} value"}} suffix"#
        XCTAssertEqual(ChatPrompt.extractJSONObject(text),
                       #"{"tool":"x","arguments":{"query":"a {weird} value"}}"#)
    }

    func testToolCallJSONRoundTrips() {
        let call = ChatToolCall(name: "get_meeting", arguments: ["id": "abc12345", "include": "summary"])
        guard case .call(let reparsed) = ChatPrompt.parse(call.json, tools: ["get_meeting"]) else {
            return XCTFail("re-parsing canonical JSON should yield a tool call")
        }
        XCTAssertEqual(reparsed.name, "get_meeting")
        XCTAssertEqual(reparsed.string("id"), "abc12345")
        XCTAssertEqual(reparsed.string("include"), "summary")
    }

    func testFinalTextFallsBackWhenStillAToolCall() {
        XCTAssertEqual(ChatPrompt.finalText(#"{"tool":"search_meetings","arguments":{}}"#),
                       ChatPrompt.fallbackAnswer)
        XCTAssertEqual(ChatPrompt.finalText("Here is the summary."), "Here is the summary.")
    }

    func testParseNativeFunctionCallWithTokens() {
        // Some Qwen-compatible local models emit this form instead of JSON.
        let text = "<|tool_call_start|>[get_meeting(id='abc12345', include='summary')]<|tool_call_end|>"
        guard case .call(let call) = ChatPrompt.parse(text, tools: ["get_meeting"]) else {
            return XCTFail("native function-call form should parse as a tool call")
        }
        XCTAssertEqual(call.name, "get_meeting")
        XCTAssertEqual(call.string("id"), "abc12345")
        XCTAssertEqual(call.string("include"), "summary")
    }

    func testParseNativeCallNumericAndDoubleQuotes() {
        guard case .call(let call) = ChatPrompt.parse(#"list_meetings(query="sync", limit=3)"#,
                                                      tools: ["list_meetings"]) else {
            return XCTFail("expected a tool call")
        }
        XCTAssertEqual(call.string("query"), "sync")
        XCTAssertEqual(call.int("limit"), 3)
    }

    func testStripToolTokensLeavesPlainAnswer() {
        let text = "<|tool_call_start|>Here is your answer.<|tool_call_end|>"
        guard case .answer(let answer) = ChatPrompt.parse(text, tools: ["get_meeting"]) else {
            return XCTFail("expected an answer")
        }
        XCTAssertEqual(answer, "Here is your answer.")
    }

    // MARK: - Malformed-attempt detection + constrained retry

    func testLooksLikeToolAttemptDetection() {
        // Balanced JSON with a misspelled tool name.
        XCTAssertTrue(ChatPrompt.looksLikeToolAttempt(#"{"tool":"search_meeting","arguments":{}}"#))
        // Truncated tool-call JSON that never balanced.
        XCTAssertTrue(ChatPrompt.looksLikeToolAttempt(#"{"tool": "get_meeting", "arguments": {"id": "ab"#))
        // Wrapper tokens around nothing usable.
        XCTAssertTrue(ChatPrompt.looksLikeToolAttempt("<|tool_call_start|><|tool_call_end|>"))
        // Bare call form with an unknown name.
        XCTAssertTrue(ChatPrompt.looksLikeToolAttempt("search_meeting(query='x')"))
        // Plain prose stays an answer.
        XCTAssertFalse(ChatPrompt.looksLikeToolAttempt("We decided to adopt Redis."))
        // Tokens around prose stay an answer (models wrap answers in stray tokens).
        XCTAssertFalse(ChatPrompt.looksLikeToolAttempt("<|tool_call_start|>Here you go.<|tool_call_end|>"))
        // JSON quoted inside prose without a tool-name key.
        XCTAssertFalse(ChatPrompt.looksLikeToolAttempt(#"The config is {"retries": 3}."#))
    }

    func testToolCallSchemaEnumeratesToolsAndRequiredArgs() throws {
        let specs = [
            ChatToolSpec(name: "search_meetings", summary: "s",
                         arguments: [.init(name: "query", description: "q", required: true),
                                     .init(name: "limit", description: "l", required: false)]),
            ChatToolSpec(name: "list_meetings", summary: "l", arguments: []),
        ]
        let schema = ChatPrompt.toolCallSchema(specs)
        XCTAssertEqual(schema["type"] as? String, "object")
        XCTAssertEqual(schema["additionalProperties"] as? Bool, false)
        let rootProperties = try XCTUnwrap(schema["properties"] as? [String: Any])
        let call = try XCTUnwrap(rootProperties["call"] as? [String: Any])
        let variants = try XCTUnwrap(call["anyOf"] as? [[String: Any]])
        XCTAssertEqual(variants.count, 2)
        let properties = try XCTUnwrap(variants[0]["properties"] as? [String: Any])
        let tool = try XCTUnwrap(properties["tool"] as? [String: Any])
        XCTAssertEqual(tool["enum"] as? [String], ["search_meetings"])
        let arguments = try XCTUnwrap(properties["arguments"] as? [String: Any])
        XCTAssertEqual(arguments["required"] as? [String], ["query", "limit"])
        XCTAssertEqual(arguments["additionalProperties"] as? Bool, false)
        let argumentProperties = try XCTUnwrap(
            arguments["properties"] as? [String: Any])
        let limit = try XCTUnwrap(argumentProperties["limit"] as? [String: Any])
        XCTAssertEqual(limit["type"] as? [String], ["string", "null"])
        XCTAssertNil(OpenAIStrictSchemaValidator.validationIssue(in: schema))
        // Must serialise — it's sent verbatim as the response_format schema.
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: schema))
    }

    func testMalformedToolAttemptRetriesWithConstrainedDecode() async throws {
        let engine = ScriptedEngine([
            #"{"tool": "search_meetings", "arguments": {"query": "what did we pick?""#,       // truncated
            #"{"call": {"tool": "search_meetings", "arguments": {"query": "what did we pick?"}}}"#, // constrained retry
            #"{"answer_sources":["E1"]}"#,
        ])
        let runner = FakeRunner(
            specs: [ChatToolSpec(name: "search_meetings", summary: "search",
                                 arguments: [.init(name: "query", description: "q", required: true)])],
            overview: "",
            results: ["search_meetings": ChatToolResult(text: "Hit: Redis", summary: "1 match", evidence: observed("We picked Redis."))])
        let agent = ChatAgent(engine: engine, runner: runner)

        let answer = try await agent.respond(history: [], latest: "what did we pick?") { _ in }
        XCTAssertTrue(answer.contains("> We picked Redis."))
        XCTAssertEqual(runner.calls.map(\.name), ["search_meetings"])
        // The tool repair, anchored proposal, and independent final check each use a schema.
        let constrained = engine.schemas.compactMap { $0 }
        XCTAssertEqual(constrained.count, 3)
        XCTAssertEqual(constrained.filter { ($0["properties"] as? [String: Any])?["call"] != nil }.count, 1)
        XCTAssertEqual(constrained.filter { ($0["properties"] as? [String: Any])?["proposal"] != nil }.count, 1)
    }

    // MARK: - System prompt

    func testSystemPromptIncludesCitationInstructions() {
        let prompt = ChatPrompt.systemPrompt(tools: [], libraryOverview: "")
        XCTAssertTrue(prompt.contains("[meeting:ID]"))
        XCTAssertTrue(prompt.contains("[meeting:ID@HH:MM:SS]"))
        XCTAssertTrue(prompt.contains("[screen:ID]"))
    }

    func testSystemPromptListsToolsAndLibrary() {
        let prompt = ChatPrompt.systemPrompt(
            tools: [ChatToolSpec(name: "search_meetings", summary: "Find spoken content.",
                                 arguments: [.init(name: "query", description: "What to find.", required: true)])],
            libraryOverview: "The user has 2 recorded meetings.")
        XCTAssertTrue(prompt.contains("search_meetings"))
        XCTAssertTrue(prompt.contains("Find spoken content."))
        XCTAssertTrue(prompt.contains("The user has 2 recorded meetings."))
        XCTAssertTrue(prompt.contains("JSON"))
    }

    func testSystemPromptIncludesWorkMemoryOnlyWhenProvided() {
        let without = ChatPrompt.systemPrompt(tools: [], libraryOverview: "")
        XCTAssertFalse(without.contains("work memory"))

        let with = ChatPrompt.systemPrompt(
            tools: [],
            libraryOverview: "",
            workMemory: "## Active projects\n- Atlas — in review")
        XCTAssertTrue(with.contains("work memory"))
        XCTAssertTrue(with.contains("Atlas — in review"))
        // Memory is background context, not ground truth the model may cite as fact.
        XCTAssertTrue(with.contains("may lag reality"))
    }

    func testWorkMemoryContextGatesOnSettingAndContent() throws {
        let memory = DreamMemory(
            updatedAt: Date(),
            activeProjects: [.init(name: "Atlas", status: "in review",
                                   lastActiveDay: "2026-07-18", evidence: [])])

        XCTAssertEqual(ChatPrompt.workMemoryContext(memory: memory,
                                                    dreamingEnabled: false), "")
        XCTAssertEqual(ChatPrompt.workMemoryContext(memory: nil,
                                                    dreamingEnabled: true), "")
        XCTAssertEqual(ChatPrompt.workMemoryContext(memory: DreamMemory(updatedAt: Date()),
                                                    dreamingEnabled: true), "")

        let context = ChatPrompt.workMemoryContext(memory: memory, dreamingEnabled: true)
        XCTAssertTrue(context.contains("Atlas"))
        XCTAssertLessThanOrEqual(context.count, 6_100)
    }

    // MARK: - Agent loop

    func testAgentRunsToolThenAnswers() async throws {
        let engine = ScriptedEngine([
            #"{"tool": "search_meetings", "arguments": {"query": "what did we decide?"}}"#,
            #"{"answer_sources":["E1"]}"#,
        ])
        let runner = FakeRunner(
            specs: [ChatToolSpec(name: "search_meetings", summary: "search",
                                 arguments: [.init(name: "query", description: "q", required: true)])],
            overview: "1 meeting",
            results: ["search_meetings": ChatToolResult(text: "Hit: adopt Redis", summary: "1 match",
                                                       evidence: observed("We decided to adopt Redis for caching."))])
        let agent = ChatAgent(engine: engine, runner: runner)

        var events: [String] = []
        let answer = try await agent.respond(history: [], latest: "what did we decide?") { event in
            switch event {
            case .answerPartial: break
            case .toolStarted(let call): events.append("start:\(call.name)")
            case .toolFinished(let name, _): events.append("finish:\(name)")
            }
        }

        XCTAssertTrue(answer.contains("> We decided to adopt Redis for caching."))
        XCTAssertEqual(runner.calls.map(\.name), ["search_meetings"])
        XCTAssertEqual(runner.calls.first?.string("query"), "what did we decide?")
        XCTAssertEqual(events, ["start:search_meetings", "finish:search_meetings"])
        // The observation must have been fed back into the second generate call.
        XCTAssertTrue(engine.prompts[1].context.contains { $0.contains("Observation: Hit: adopt Redis") })
        XCTAssertFalse(engine.prompts.last?.context.contains { $0.contains("Observation: Hit: adopt Redis") } ?? true)
    }

    func testAgentAnswersDirectlyWithoutTools() async throws {
        let engine = ScriptedEngine(["You have no meetings recorded yet."])
        let runner = FakeRunner(specs: [], overview: "no meetings", results: [:])
        let agent = ChatAgent(engine: engine, runner: runner)
        let answer = try await agent.respond(history: [], latest: "anything?") { _ in }
        XCTAssertEqual(answer, "You have no meetings recorded yet.")
        XCTAssertTrue(runner.calls.isEmpty)
    }

    func testAgentForcesAnswerAfterMaxSteps() async throws {
        let loopingCall = #"{"tool":"search_meetings","arguments":{"query":"find x"}}"#
        let engine = ScriptedEngine(Array(repeating: loopingCall, count: 8))
        let runner = FakeRunner(
            specs: [ChatToolSpec(name: "search_meetings", summary: "search", arguments: [])],
            overview: "",
            results: ["search_meetings": ChatToolResult(text: "no matches", summary: "0")])
        var agent = ChatAgent(engine: engine, runner: runner)
        agent.maxSteps = 2

        let answer = try await agent.respond(history: [], latest: "find x") { _ in }
        // Two planner calls plus one bounded recovery search after the forced pass fails.
        XCTAssertEqual(runner.calls.count, 3)
        XCTAssertEqual(answer, ChatGrounding.noAnswer)
    }

    func testCurrentTimeGoesLastSoTheModelCanResolveRelativeDays() throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-02T09:30:00Z"))
        let zone = try XCTUnwrap(TimeZone(identifier: "Europe/Belgrade"))
        let line = ChatPrompt.currentTimeLine(now: now, timeZone: zone)
        XCTAssertTrue(line.hasPrefix("Current local time: Friday, 2 October 2026, 11:30 (Europe/Belgrade)."), line)
        let prompt = ChatPrompt.systemPrompt(tools: [], libraryOverview: "The user has 2 recorded meetings.",
                                             currentTime: line)
        XCTAssertTrue(prompt.hasSuffix(line), "a changing line must not invalidate the cached prompt prefix")
        XCTAssertFalse(ChatPrompt.systemPrompt(tools: [], libraryOverview: "").contains("Current local time"))
    }

    func testHistoryReplayIsBoundedByMessagesAndCharactersAndStartsWithAQuestion() {
        var history: [ChatAgent.Turn] = []
        for index in 0..<20 {
            let role: ChatRole = index.isMultiple(of: 2) ? .user : .assistant
            let turn = ChatAgent.Turn(role: role, text: "message \(index)")
            history.append(turn)
        }
        let expected = (4..<20).map { "message \($0)" }
        XCTAssertEqual(ChatAgent.replayedHistory(history, maxMessages: 16, maxCharacters: 12_000).map(\.text), expected)
        XCTAssertEqual(ChatAgent.replayedHistory(history, maxMessages: 3, maxCharacters: 12_000).map(\.text),
                       ["message 18", "message 19"], "an answer whose question was cut off is dropped")

        let long: [ChatAgent.Turn] = [
            .init(role: .user, text: "first question"),
            .init(role: .assistant, text: String(repeating: "a", count: 11_990)),
            .init(role: .user, text: "second question"),
            .init(role: .assistant, text: "short answer"),
        ]
        XCTAssertEqual(ChatAgent.replayedHistory(long, maxMessages: 16, maxCharacters: 12_000).map(\.text),
                       ["second question", "short answer"])
    }

    func testAppleIntelligenceKeepsTheSmallerAskLoop() {
        var agent = ChatAgent(engine: AppleIntelligenceEngine(), runner: FakeRunner(specs: [], overview: "", results: [:]))
        XCTAssertEqual(agent.maxSteps, 6)
        agent.adaptLimits(to: AppleIntelligenceEngine())
        XCTAssertEqual(agent.maxSteps, 4)
        XCTAssertEqual(agent.historyWindow, 8)
        XCTAssertEqual(agent.historyCharacters, 4_000)
        var local = ChatAgent(engine: AppleIntelligenceEngine(), runner: FakeRunner(specs: [], overview: "", results: [:]))
        local.adaptLimits(to: OllamaEngine(baseURL: URL(fileURLWithPath: "/"), model: "fixture"))
        XCTAssertEqual(local.maxSteps, 6)
    }

    func testLongTranscriptReadsSayWhereTheyContinueAndLoseNoLines() throws {
        var segments: [Transcript.Segment] = []
        let filler = String(repeating: "word ", count: 60)
        for index in 0..<30 {
            let start = Double(index) * 60
            let text = filler + "line \(index)."
            let segment = Transcript.Segment(start: start, end: start + 50, speaker: "them 1", text: text)
            segments.append(segment)
        }
        let transcript = Transcript(segments: segments, engine: "fixture")
        let first = MeetingChatFormat.transcriptObservation(transcript)
        XCTAssertLessThanOrEqual(first.text.count, 6_000)
        let next = try XCTUnwrap(first.nextStart, "a cut transcript must say where it continues")
        XCTAssertFalse(first.text.contains("line 29."))
        XCTAssertTrue(MeetingChatFormat.transcriptContinuation(next: next).contains("from=\(Transcript.stamp(next))"))

        var cursor: TimeInterval? = 0
        var reads = 0
        var combined = ""
        while let start = cursor, reads < 10 {
            let window = MeetingChatFormat.transcriptObservation(transcript, from: start)
            combined += window.text + "\n\n"
            cursor = window.nextStart
            reads += 1
        }
        XCTAssertNil(cursor)
        for index in 0..<30 {
            XCTAssertTrue(combined.contains("line \(index)."), "missing line \(index)")
        }
    }

    // MARK: - Pure formatters

    func testLibraryOverviewEmptyAndPopulated() {
        XCTAssertEqual(MeetingChatFormat.libraryOverview([], limit: 5),
                       "The user has no recorded meetings yet.")
        let text = MeetingChatFormat.libraryOverview([sampleMeeting(title: "Kickoff")], limit: 5)
        XCTAssertTrue(text.contains("1 recorded meeting"))
        XCTAssertTrue(text.contains("Kickoff"))
    }

    func testListFormatsMeetingRows() {
        let meeting = sampleMeeting(title: "Weekly sync")
        let text = MeetingChatFormat.list([meeting])
        XCTAssertTrue(text.contains("Weekly sync"))
        XCTAssertTrue(text.contains(SessionLookup.shortID(meeting.id)))
    }

    func testSearchResultsEmptyAndKeyword() {
        XCTAssertEqual(
            MeetingChatFormat.searchResults(query: "ghost", keyword: [], semantic: [], meetings: []),
            "No matches for “ghost”.")

        let meeting = sampleMeeting(title: "Budget review")
        let hit = SearchIndex.Hit(meetingID: meeting.id, kind: .segment, start: 90,
                                  snippet: "we cut the «budget» by 10%", speaker: "me")
        let text = MeetingChatFormat.searchResults(query: "budget", keyword: [hit],
                                                   semantic: [], meetings: [meeting])
        XCTAssertTrue(text.contains("Budget review"))
        XCTAssertTrue(text.contains("00:01:30"))      // timestamp from start=90
        XCTAssertFalse(text.contains("«"))            // FTS markers stripped
    }

    func testMeetingIncludeSelectsSections() {
        let meeting = sampleMeeting(title: "Retro")
        let summaryOnly = MeetingChatFormat.meeting(meeting, summary: "S", transcript: "T", include: "summary")
        XCTAssertTrue(summaryOnly.contains("## Summary"))
        XCTAssertFalse(summaryOnly.contains("## Transcript"))

        let transcriptOnly = MeetingChatFormat.meeting(meeting, summary: "S", transcript: "T", include: "transcript")
        XCTAssertTrue(transcriptOnly.contains("## Transcript"))
        XCTAssertFalse(transcriptOnly.contains("## Summary"))

        let all = MeetingChatFormat.meeting(meeting, summary: "S", transcript: "T", include: "all")
        XCTAssertTrue(all.contains("## Summary"))
        XCTAssertTrue(all.contains("## Transcript"))
    }

    func testCleanStripsMarkersAndCollapsesWhitespace() {
        XCTAssertEqual(MeetingChatFormat.clean("a «hit»\n   b"), "a hit b")
    }

    // MARK: - Live tool runner (planted library)

    func testToolsListSearchAndGetAgainstPlantedLibrary() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lokalbot-chat-\(UUID().uuidString)", isDirectory: true)
        setenv("LOKALBOT_STORAGE_ROOT", root.path, 1)
        defer {
            unsetenv("LOKALBOT_STORAGE_ROOT")
            try? FileManager.default.removeItem(at: root)
        }

        let storage = StorageManager()      // rooted at our temp dir via the env hook
        let meeting = Meeting(
            id: UUID(uuidString: "11111111-2222-4333-8444-555555555555")!,
            title: "Caching strategy", appName: "Zoom",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            endedAt: Date(timeIntervalSince1970: 1_700_001_800),
            relativePath: "meetings/2026/06/caching", hasSystemTrack: true)
        let folder = meeting.folderURL(in: storage)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let transcript = Transcript(segments: [
            .init(start: 12, end: 18, speaker: "me",
                  text: "Let's adopt Redis for the eviction policy.", confidence: nil),
            .init(start: 20, end: 25, speaker: "them",
                  text: "Agreed, benchmark failover latency first.", confidence: nil),
        ], engine: "test")
        try JSONEncoder().encode(transcript)
            .write(to: folder.appendingPathComponent("transcript.json"))
        try Data(transcript.markdown.utf8)
            .write(to: folder.appendingPathComponent("transcript.md"))
        try Data("## TL;DR\nAdopt Redis.\n## Action items\n- Benchmark failover".utf8)
            .write(to: folder.appendingPathComponent("summary.md"))

        let sqlite = storage.rootURL.appendingPathComponent("lokalbotv3.sqlite")
        let searchIndex = SearchIndex(databaseURL: sqlite)
        searchIndex.reindex(meeting, storage: storage)
        let embeddingIndex = EmbeddingIndex(databaseURL: sqlite, storage: storage)
        let activityStore = ActivityStore(databaseURL: sqlite)

        var settings = AppSettings()
        settings.semanticSearchEnabled = false      // keep the test offline (no embed server)

        let tools = MeetingChatTools(
            meetings: { [meeting] }, storage: storage,
            searchIndex: searchIndex, embeddingIndex: embeddingIndex,
            activityStore: activityStore,
            settings: { settings })

        let list = await tools.run(ChatToolCall(name: "list_meetings", arguments: [:]))
        XCTAssertTrue(list.text.contains("Caching strategy"), "list: \(list.text)")

        let dateMiss = await tools.run(ChatToolCall(
            name: "list_meetings",
            arguments: ["_lokalbot_day_scope": "2020-01-01"]))
        XCTAssertFalse(dateMiss.text.contains("Caching strategy"), "date miss: \(dateMiss.text)")

        let search = await tools.run(ChatToolCall(name: "search_meetings",
                                                  arguments: ["query": "eviction"]))
        XCTAssertTrue(search.text.contains("Caching strategy"), "search: \(search.text)")
        XCTAssertTrue(search.text.lowercased().contains("eviction"), "search: \(search.text)")

        let summary = await tools.run(ChatToolCall(name: "get_meeting",
                                                   arguments: ["id": SessionLookup.shortID(meeting.id)]))
        XCTAssertTrue(summary.text.contains("Adopt Redis"), "get: \(summary.text)")
        XCTAssertTrue(summary.text.contains("## Summary"))
        XCTAssertTrue(summary.evidence.contains(.init(meetingID: SessionLookup.shortID(meeting.id), seconds: nil)))
        XCTAssertFalse(summary.evidence.contains(.init(meetingID: SessionLookup.shortID(meeting.id), seconds: 10)))

        let latestTranscript = await tools.run(ChatToolCall(name: "get_meeting",
                                                            arguments: ["id": "latest", "include": "transcript"]))
        XCTAssertTrue(latestTranscript.text.contains("Redis"), "get transcript: \(latestTranscript.text)")
        XCTAssertTrue(latestTranscript.evidence.contains(.init(meetingID: SessionLookup.shortID(meeting.id), seconds: 12)))
        XCTAssertFalse(latestTranscript.text.contains("transcript continues"))

        let later = await tools.run(ChatToolCall(name: "get_meeting",
                                                 arguments: ["id": "latest", "include": "transcript", "from": "00:00:19"]))
        XCTAssertTrue(later.text.contains("benchmark failover"), "get from: \(later.text)")
        XCTAssertFalse(later.text.contains("eviction policy"), "get from: \(later.text)")
        XCTAssertTrue(later.evidence.contains(.init(meetingID: SessionLookup.shortID(meeting.id), seconds: 20)))
        XCTAssertFalse(later.evidence.contains(.init(meetingID: SessionLookup.shortID(meeting.id), seconds: 12)))

        let miss = await tools.run(ChatToolCall(name: "get_meeting", arguments: ["id": "zzzzzzzz"]))
        XCTAssertTrue(miss.text.contains("No meeting matches"), "miss: \(miss.text)")
    }

    func testMeetingDayFilterIsAppliedBeforeResultLimit() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lokalbot-chat-day-\(UUID().uuidString)", isDirectory: true)
        setenv("LOKALBOT_STORAGE_ROOT", root.path, 1)
        defer {
            unsetenv("LOKALBOT_STORAGE_ROOT")
            try? FileManager.default.removeItem(at: root)
        }
        let storage = StorageManager()
        let calendar = Calendar(identifier: .gregorian)
        let selectedDay = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 7, day: 1, hour: 12)))
        let otherDay = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: selectedDay))
        var meetings: [Meeting] = []

        func addMeeting(title: String, startedAt: Date, path: String, text: String) throws -> Meeting {
            let meeting = Meeting(
                id: UUID(), title: title, appName: "Zoom",
                startedAt: startedAt, endedAt: startedAt.addingTimeInterval(900),
                relativePath: path, hasSystemTrack: true)
            let folder = meeting.folderURL(in: storage)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let transcript = Transcript(segments: [
                .init(start: 10, end: 20, speaker: "me", text: text, confidence: nil),
            ], engine: "test")
            try JSONEncoder().encode(transcript)
                .write(to: folder.appendingPathComponent("transcript.json"))
            return meeting
        }

        let selected = try addMeeting(
            title: "Selected day meeting", startedAt: selectedDay,
            path: "meetings/2026/07/selected", text: "needle")
        meetings.append(selected)
        for index in 0..<20 {
            meetings.append(try addMeeting(
                title: "Needle priority \(index)",
                startedAt: otherDay.addingTimeInterval(TimeInterval(index)),
                path: "meetings/2026/07/outside-\(index)",
                text: "needle needle needle priority"))
        }

        let sqlite = storage.rootURL.appendingPathComponent("lokalbotv3.sqlite")
        let searchIndex = SearchIndex(databaseURL: sqlite)
        for meeting in meetings { searchIndex.reindex(meeting, storage: storage) }
        XCTAssertFalse(searchIndex.search("needle", limit: 8).contains {
            $0.meetingID == selected.id
        }, "fixture must push the selected-day result beyond the global limit")

        var settings = AppSettings()
        settings.semanticSearchEnabled = false
        let tools = MeetingChatTools(
            meetings: { meetings }, storage: storage,
            searchIndex: searchIndex,
            embeddingIndex: EmbeddingIndex(databaseURL: sqlite, storage: storage),
            activityStore: ActivityStore(databaseURL: sqlite),
            settings: { settings })

        let scoped = await tools.run(ChatToolCall(
            name: "search_meetings",
            arguments: ["query": "needle", "_lokalbot_day_scope": "2026-07-01"]))

        XCTAssertTrue(scoped.text.contains("Selected day meeting"), "scoped: \(scoped.text)")
        XCTAssertFalse(scoped.text.contains("Needle priority"), "scoped: \(scoped.text)")
    }

    // MARK: - Screen / activity tools

    func testSearchScreenAndActivitySummaryAgainstPlantedStore() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lokalbot-screen-\(UUID().uuidString)", isDirectory: true)
        setenv("LOKALBOT_STORAGE_ROOT", root.path, 1)
        defer {
            unsetenv("LOKALBOT_STORAGE_ROOT")
            try? FileManager.default.removeItem(at: root)
        }

        let storage = StorageManager()
        let sqlite = storage.rootURL.appendingPathComponent("lokalbotv3.sqlite")
        try FileManager.default.createDirectory(at: storage.rootURL, withIntermediateDirectories: true)
        let activityStore = ActivityStore(databaseURL: sqlite)
        let fixtureTime = try XCTUnwrap(Calendar.current.date(from: DateComponents(
            year: 2026, month: 7, day: 1, hour: 12
        )))
        let fixtureMeeting = Meeting(
            id: UUID(), title: "Private planning meeting", appName: "Zoom",
            startedAt: fixtureTime.addingTimeInterval(-1_800),
            endedAt: fixtureTime.addingTimeInterval(-900),
            relativePath: "meetings/2026/07/private-planning",
            hasSystemTrack: true)

        try activityStore.insertScreenshot(
            ts: fixtureTime, path: "/tmp/x.heic.enc", app: "Safari",
            windowTitle: "Stripe invoicing docs", trigger: "app_switch",
            ocr: "How to issue a refund for an invoice in the Stripe dashboard")
        let nextDay = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: 1, to: fixtureTime))
        try activityStore.insertScreenshot(
            ts: nextDay, path: "/tmp/y.heic.enc", app: "Safari",
            windowTitle: "Other day refund docs", trigger: "app_switch",
            ocr: "How to issue a refund for an invoice in the Stripe dashboard")
        // More than the tool's result limit on another day: date filtering must
        // happen in SQL before LIMIT or the valid selected-day hit disappears.
        for index in 0..<13 {
            try activityStore.insertScreenshot(
                ts: nextDay.addingTimeInterval(TimeInterval(index)),
                path: "/tmp/out-of-day-\(index).heic.enc",
                app: "Browser \(index)",
                windowTitle: "Other day refund \(index)",
                trigger: "app_switch",
                ocr: "How to issue a refund for an invoice in the Stripe dashboard")
        }
        activityStore.insert(ActivityBlock(app: "Xcode", title: "LokalBot.xcodeproj",
                                           start: fixtureTime.addingTimeInterval(-7_200),
                                           end: fixtureTime.addingTimeInterval(-3_600)))
        activityStore.insert(ActivityBlock(app: "Safari", title: "Stripe invoicing docs",
                                           start: fixtureTime.addingTimeInterval(-3_600),
                                           end: fixtureTime.addingTimeInterval(-3_000)))

        var settings = AppSettings()
        settings.semanticSearchEnabled = false
        let tools = MeetingChatTools(
            meetings: { [fixtureMeeting] }, storage: storage,
            searchIndex: SearchIndex(databaseURL: sqlite),
            embeddingIndex: EmbeddingIndex(databaseURL: sqlite, storage: storage),
            activityStore: activityStore,
            settings: { settings })

        let hit = await tools.run(ChatToolCall(name: "search_screen",
                                               arguments: ["query": "refund invoice"]))
        XCTAssertFalse(hit.text.contains("No screen-text matches"), "screen: \(hit.text)")
        XCTAssertTrue(hit.text.contains("[screen:"), "screen citation: \(hit.text)")

        let scopedHit = await tools.run(ChatToolCall(
            name: "search_screen",
            arguments: ["query": "refund invoice", "_lokalbot_day_scope": "2026-07-01"]))
        XCTAssertTrue(scopedHit.text.contains("Stripe invoicing docs"), "scoped: \(scopedHit.text)")
        XCTAssertFalse(scopedHit.text.contains("Other day refund docs"), "scoped: \(scopedHit.text)")

        // Natural-language question rescued by the relaxed OR fallback.
        let rescued = await tools.run(ChatToolCall(name: "search_screen",
                                                   arguments: ["query": "how do I refund that invoice"]))
        XCTAssertFalse(rescued.text.contains("No screen-text matches"), "rescued: \(rescued.text)")

        let miss = await tools.run(ChatToolCall(name: "search_screen",
                                                arguments: ["query": "kubernetes"]))
        XCTAssertTrue(miss.text.contains("No screen-text matches"), "miss: \(miss.text)")

        let summary = await tools.run(ChatToolCall(
            name: "activity_summary",
            arguments: ["day": "2026-07-01"]
        ))
        XCTAssertTrue(summary.text.contains("Xcode: 1h 00m"), "summary: \(summary.text)")
        XCTAssertTrue(summary.text.contains("Safari: 10m"), "summary: \(summary.text)")
        XCTAssertTrue(summary.text.contains("LokalBot.xcodeproj"), "summary: \(summary.text)")

        let activityOnly = await tools.run(ChatToolCall(
            name: "activity_summary",
            arguments: [
                "day": "2026-07-01",
                "_lokalbot_include_meetings": "false",
            ]))
        XCTAssertFalse(activityOnly.text.contains("Private planning meeting"),
                       "activity-only source leaked meeting data: \(activityOnly.text)")

        let activityAndMeetings = await tools.run(ChatToolCall(
            name: "activity_summary",
            arguments: [
                "day": "2026-07-01",
                "_lokalbot_include_meetings": "true",
            ]))
        XCTAssertTrue(activityAndMeetings.text.contains("Private planning meeting"),
                      "meeting-enabled activity omitted the meeting: \(activityAndMeetings.text)")

        let empty = await tools.run(ChatToolCall(name: "activity_summary",
                                                 arguments: ["day": "2020-01-01"]))
        XCTAssertTrue(empty.text.contains("No app activity tracked"), "empty: \(empty.text)")

        let bad = await tools.run(ChatToolCall(name: "activity_summary",
                                               arguments: ["day": "next tuesday"]))
        XCTAssertTrue(bad.text.contains("Could not understand day"), "bad: \(bad.text)")
    }

    func testParseDayHandlesRelativeAndISOForms() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(MeetingChatTools.parseDay("today", now: now), now)
        let yesterday = MeetingChatTools.parseDay("yesterday", now: now)
        XCTAssertEqual(yesterday.map { Calendar.current.dateComponents([.day], from: $0, to: now).day }, 1)
        XCTAssertNotNil(MeetingChatTools.parseDay("2026-07-01"))
        XCTAssertNil(MeetingChatTools.parseDay("garbage"))
    }

    func testActivitySummaryFormatterAggregatesAndListsMeetings() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let blocks = [
            ActivityBlock(app: "Xcode", title: "foo.swift", start: base, end: base.addingTimeInterval(1_800)),
            ActivityBlock(app: "Xcode", title: "bar.swift", start: base, end: base.addingTimeInterval(5_400)),
            ActivityBlock(app: "Slack", title: "#general", start: base, end: base.addingTimeInterval(600)),
        ]
        let text = MeetingChatFormat.activitySummary(
            dayLabel: "Jul 1, 2026", blocks: blocks, meetings: [sampleMeeting(title: "Standup")])
        XCTAssertTrue(text.contains("Xcode: 2h 00m"), text)
        XCTAssertTrue(text.contains("Slack: 10m"), text)
        XCTAssertTrue(text.contains("Standup"), text)
        // Longest-title-first within an app.
        XCTAssertTrue(text.range(of: "bar.swift")!.lowerBound
                      < text.range(of: "foo.swift")!.lowerBound, text)
    }

    func testDurationLabelFormats() {
        XCTAssertEqual(MeetingChatFormat.durationLabel(45), "45s")
        XCTAssertEqual(MeetingChatFormat.durationLabel(600), "10m")
        XCTAssertEqual(MeetingChatFormat.durationLabel(7_500), "2h 05m")
    }

    // MARK: - FTS query relaxation

    func testFtsQueryStrictAndsTermsButRelaxesOnRequest() {
        // Default: quote + AND every term, prefix-match the last (search-as-you-type).
        XCTAssertEqual(SearchIndex.ftsQuery(from: "what did we decide about caching"),
                       #""what" "did" "we" "decide" "about" "caching" *"#)
        // Relaxed: drop stop words, OR the content terms for recall.
        XCTAssertEqual(
            SearchIndex.ftsQuery(from: "what did we decide about caching",
                                 matchAll: false, dropStopWords: true),
            #""decide" OR "caching""#)
        // All terms are stop words → keep them rather than emit an empty query.
        XCTAssertEqual(
            SearchIndex.ftsQuery(from: "what did we", matchAll: false, dropStopWords: true),
            #""what" OR "did" OR "we""#)
        XCTAssertNil(SearchIndex.ftsQuery(from: "   "))
    }

    func testSearchRescuesNaturalLanguageQuery() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lokalbot-nlsearch-\(UUID().uuidString)", isDirectory: true)
        setenv("LOKALBOT_STORAGE_ROOT", root.path, 1)
        defer {
            unsetenv("LOKALBOT_STORAGE_ROOT")
            try? FileManager.default.removeItem(at: root)
        }

        let storage = StorageManager()
        let meeting = Meeting(
            id: UUID(uuidString: "22222222-3333-4444-8555-666666666666")!,
            title: "Caching strategy", appName: "Zoom",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            endedAt: Date(timeIntervalSince1970: 1_700_001_800),
            relativePath: "meetings/2026/06/nlsearch", hasSystemTrack: true)
        let folder = meeting.folderURL(in: storage)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let transcript = Transcript(segments: [
            .init(start: 10, end: 16, speaker: "me",
                  text: "We will use Redis for caching going forward.", confidence: nil),
        ], engine: "test")
        try JSONEncoder().encode(transcript)
            .write(to: folder.appendingPathComponent("transcript.json"))

        let sqlite = storage.rootURL.appendingPathComponent("lokalbotv3.sqlite")
        let searchIndex = SearchIndex(databaseURL: sqlite)
        searchIndex.reindex(meeting, storage: storage)
        let embeddingIndex = EmbeddingIndex(databaseURL: sqlite, storage: storage)
        let activityStore = ActivityStore(databaseURL: sqlite)

        var settings = AppSettings()
        settings.semanticSearchEnabled = false      // no embed server in tests

        let tools = MeetingChatTools(
            meetings: { [meeting] }, storage: storage,
            searchIndex: searchIndex, embeddingIndex: embeddingIndex,
            activityStore: activityStore,
            settings: { settings })

        // Strict FTS ANDs every stop word and finds nothing on the raw question…
        XCTAssertTrue(searchIndex.search("what did we decide about caching").isEmpty)
        // …but the chat tool's keyword fallback rescues the content terms.
        let search = await tools.run(ChatToolCall(name: "search_meetings",
                                                  arguments: ["query": "what did we decide about caching"]))
        XCTAssertFalse(search.text.contains("No matches"), "search: \(search.text)")
        XCTAssertTrue(search.text.contains("Caching strategy"), "search: \(search.text)")
    }

    // MARK: - Helpers

    private func sampleMeeting(title: String) -> Meeting {
        Meeting(id: UUID(), title: title, appName: "Zoom",
                startedAt: Date(timeIntervalSince1970: 1_700_000_000),
                endedAt: Date(timeIntervalSince1970: 1_700_001_800),
                relativePath: "meetings/sample", hasSystemTrack: false)
    }
}

// MARK: - Test doubles

@MainActor
private final class StreamingAnswerEngine: TextEngine {
    nonisolated var displayName: String { "Streaming test" }
    var completed = false
    func generate(system: String, prompt: String, context: [String]) async throws -> String { "" }
    func generateStreaming(system: String, prompt: String, context: [String],
                           options: TextGenerationOptions,
                           onPartial: @escaping @MainActor (String) -> Void) async throws -> String {
        onPartial("<think>private reasoning")
        onPartial("<think>private reasoning</think>FINAL_ANS")
        onPartial("<think>private reasoning</think>FINAL_ANSWER:\nThe decision was Redis")
        completed = true
        return "FINAL_ANSWER:\nThe decision was Redis."
    }
}

/// A `TextEngine` that returns canned outputs in order and records every call,
/// so the agent loop can be exercised deterministically with no model.
private final class ScriptedEngine: TextEngine {
    private var outputs: [String]
    private var supportVerdicts: [String]
    var minimumStructuredOutputTokens: Int
    private(set) var generationOptions: [TextGenerationOptions] = []
    private(set) var prompts: [(system: String, prompt: String, context: [String])] = []
    /// One entry per generate call: the constraining schema, or nil for plain calls.
    private(set) var schemas: [[String: Any]?] = []

    init(_ outputs: [String], supportVerdicts: [String] = [#"{"supports_requested_answer":true}"#], structuredFloor: Int = 512) {
        self.outputs = outputs
        self.supportVerdicts = supportVerdicts
        self.minimumStructuredOutputTokens = structuredFloor
    }

    var displayName: String { "Scripted" }

    func generate(system: String, prompt: String, context: [String]) async throws -> String {
        prompts.append((system, prompt, context))
        schemas.append(nil)
        return outputs.isEmpty ? "" : outputs.removeFirst()
    }

    func generate(system: String, prompt: String, context: [String],
                  schema: [String: Any]) async throws -> String {
        prompts.append((system, prompt, context))
        schemas.append(schema)
        if (schema["properties"] as? [String: Any])?["proposal"] != nil {
            return Self.scriptedAssessment(context: context,
                supported: !supportVerdicts.isEmpty && ChatGrounding.supportsRequestedAnswer(supportVerdicts.removeFirst()))
        }
        if (schema["properties"] as? [String: Any])?["verdict"] != nil {
            return #"{"evidence_check":"Synthetic independent evidence check.","verdict":"supported","issues":[]}"#
        }
        return outputs.isEmpty ? "" : outputs.removeFirst()
    }
    private static func scriptedAssessment(context: [String], supported: Bool) -> String {
        let prefix = "Available recorded source catalog:\n"
        let catalog = context.first(where: { $0.hasPrefix(prefix) }).map { String($0.dropFirst(prefix.count)) } ?? "[]"
        let records = (try? JSONSerialization.jsonObject(with: Data(catalog.utf8))) as? [[String: String]] ?? []
        let chosen = Set((context.last ?? "").replacingOccurrences(of: "Selected handles to assess: ", with: "")
            .components(separatedBy: ", "))
        let parts: [[String: Any]] = records.filter { chosen.contains($0["handle"] ?? "") }.map { record in
            ["question_part": "Synthetic part " + (record["handle"] ?? ""),
             "status": supported ? "supported_value" : "uncertain",
             "evidence": [["source": record["handle"] ?? "", "quote": String((record["text"] ?? "").prefix(600))]]]
        }
        let data = try? JSONSerialization.data(withJSONObject: ["proposal": ["parts": parts]], options: .sortedKeys)
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }
    func generate(system: String, prompt: String, context: [String], schema: [String: Any],
                  options: TextGenerationOptions) async throws -> String {
        generationOptions.append(options)
        return try await generate(system: system, prompt: prompt, context: context, schema: schema)
    }

}

@MainActor
private final class FakeRunner: ChatToolRunner {
    let specs: [ChatToolSpec]
    private let overview: String
    private let results: [String: ChatToolResult]
    private(set) var calls: [ChatToolCall] = []

    init(specs: [ChatToolSpec], overview: String, results: [String: ChatToolResult]) {
        self.specs = specs
        self.overview = overview
        self.results = results
    }

    func libraryOverview() -> String { overview }

    func run(_ call: ChatToolCall) async -> ChatToolResult {
        calls.append(call)
        return results[call.name] ?? ChatToolResult(text: "no result", summary: "none")
    }
}
