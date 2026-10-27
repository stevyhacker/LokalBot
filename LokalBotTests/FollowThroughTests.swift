import XCTest
@testable import LokalBot

/// The Meta Model API wire format and the Follow-through loop, offline.
final class MuseChatClientTests: XCTestCase {
    private func client(transport: @escaping MuseChatClient.Transport = { _ in throw CancellationError() }) -> MuseChatClient {
        var client = MuseChatClient(apiKey: "test-key", model: "muse-wonder-1.0", reasoningEffort: "low",
                                    maxTokens: 2_000, priority: .agent, purpose: "test")
        client.gate = nil
        client.transport = transport
        return client
    }

    private func body(_ request: URLRequest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
    }

    func testRequestCarriesToolsSchemaAndReasoningEffort() throws {
        let tools: [[String: Any]] = [["type": "function", "function": ["name": "finish", "parameters": ["type": "object"]]]]
        let request = try client().makeRequest(messages: [["role": "user", "content": "hi"]], tools: tools,
                                               schema: (name: "radar", schema: ["type": "object"]))
        XCTAssertEqual(request.url?.absoluteString, "https://api.meta.ai/v1/chat/completions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
        let json = try body(request)
        XCTAssertEqual(json["model"] as? String, "muse-wonder-1.0")
        XCTAssertEqual(json["reasoning_effort"] as? String, "low")
        XCTAssertEqual(json["max_tokens"] as? Int, 2_000)
        XCTAssertEqual(json["tool_choice"] as? String, "auto", "Meta accepts only auto")
        XCTAssertEqual((json["tools"] as? [Any])?.count, 1)
        let format = try XCTUnwrap(json["response_format"] as? [String: Any])
        XCTAssertEqual((format["json_schema"] as? [String: Any])?["strict"] as? Bool, true)

        let plain = try body(client().makeRequest(messages: []))
        XCTAssertNil(plain["tools"])
        XCTAssertNil(plain["tool_choice"])
        XCTAssertNil(plain["response_format"])
    }

    func testParsesToolCallsAndUsage() throws {
        let data = Data(#"""
        {"choices":[{"finish_reason":"tool_calls","message":{"role":"assistant","content":null,
          "tool_calls":[{"id":"call_1","type":"function","function":{"name":"search_meetings","arguments":"{\"query\":\"pricing\"}"}}]}}],
         "usage":{"prompt_tokens":1200,"completion_tokens":300,"prompt_tokens_details":{"cached_tokens":200},
                  "completion_tokens_details":{"reasoning_tokens":250}}}
        """#.utf8)
        let reply = try MuseChatClient.parse(data)
        XCTAssertEqual(reply.toolCalls, [.init(id: "call_1", name: "search_meetings", arguments: #"{"query":"pricing"}"#)])
        XCTAssertEqual(reply.toolCalls[0].decodedArguments["query"] as? String, "pricing")
        XCTAssertEqual(reply.usage, .init(inputTokens: 1_200, cachedInputTokens: 200, outputTokens: 300, reasoningTokens: 250))
        XCTAssertEqual(reply.content, "")

        let assistant = MuseChatClient.assistantMessage(for: reply)
        XCTAssertEqual((assistant["tool_calls"] as? [[String: Any]])?.first?["id"] as? String, "call_1")
        XCTAssertEqual(MuseChatClient.toolResultMessage(callID: "call_1", content: "x")["tool_call_id"] as? String, "call_1")

        let truncated = Data(#"{"choices":[{"finish_reason":"length","message":{"content":""}}]}"#.utf8)
        XCTAssertThrowsError(try MuseChatClient.parse(truncated))
    }

    func testHTTPErrorsBecomeEngineErrors() async {
        let limited = client { request in
            (Data(#"{"error":{"message":"slow down","type":"rate_limit"}}"#.utf8),
             HTTPURLResponse(url: request.url!, statusCode: 429, httpVersion: nil, headerFields: ["Retry-After": "2"])!)
        }
        do {
            _ = try await limited.send(messages: [])
            XCTFail("expected a rate limit")
        } catch let error as TextEngineError {
            XCTAssertTrue(error.isRateLimit)
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testCostUsesCachedAndOutputRates() {
        let usage = MuseChatClient.Usage(inputTokens: 1_000_000, cachedInputTokens: 500_000, outputTokens: 100_000)
        XCTAssertEqual(MetaModelAPI.cost(of: usage, model: "muse-wonder-1.0"), 0.5 * 4 + 0.5 * 0.2 + 0.1 * 20, accuracy: 1e-9)
        XCTAssertEqual(MetaModelAPI.cost(of: usage, model: "unknown"), 0)
    }

    func testClientRequiresApprovalAndKey() {
        var settings = AppSettings()
        settings.approvedRemoteInferenceOrigins = []
        XCTAssertThrowsError(try MetaModelAPI.client(settings: settings, model: "m", reasoningEffort: "low",
                                                     maxTokens: 1, priority: .agent, purpose: "t")) {
            XCTAssertEqual($0 as? MetaModelAPI.ConnectionError, .notApproved)
        }
        settings.approvedRemoteInferenceOrigins = [MetaModelAPI.origin]
        XCTAssertTrue(settings.metaModelAPIApproved)
        XCTAssertEqual(MetaModelAPI.origin, "https://api.meta.ai")
    }
}

final class FollowThroughToolsTests: XCTestCase {
    func testDefinitionsOfferOnlyWhatThisMacCanDo() {
        let read = [ChatToolSpec(name: "search_meetings", summary: "s", arguments: [.init(name: "query", description: "q", required: true)]),
                    ChatToolSpec(name: "search_screen", summary: "screen", arguments: [])]
        func names(_ tools: [[String: Any]]) -> [String] {
            tools.compactMap { ($0["function"] as? [String: Any])?["name"] as? String }
        }
        let minimal = names(FollowThroughTools.definitions(readSpecs: read, codingAgents: [], canMarkDone: false))
        XCTAssertEqual(minimal, ["search_meetings", "draft_email", "propose_meeting", "finish"],
                       "screen memory has its own permission and stays out")
        let full = names(FollowThroughTools.definitions(readSpecs: read, codingAgents: [.codex], canMarkDone: true))
        XCTAssertTrue(full.contains("hand_off_to_coding_agent"))
        XCTAssertTrue(full.contains("mark_action_done"))
    }

    func testProposalParsingValidatesArguments() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Podgorica")!
        let event = try XCTUnwrap(FollowThroughTools.proposal(from: .init(
            id: "c1", name: "propose_meeting",
            arguments: #"{"title":"Pricing review","start":"2026-11-03T15:00","duration_minutes":"45","attendees":["Ana"],"agenda":"Deck","why":"Agree the tiers"}"#),
            codingAgents: [], canMarkDone: false, calendar: calendar))
        guard case .event(let title, let start, let minutes, let attendees, _) = event.kind else { return XCTFail("not an event") }
        XCTAssertEqual(title, "Pricing review")
        XCTAssertEqual(minutes, 45)
        XCTAssertEqual(attendees, ["Ana"])
        XCTAssertEqual(calendar.component(.hour, from: start), 15)
        XCTAssertEqual(event.rationale, "Agree the tiers")

        XCTAssertThrowsError(try FollowThroughTools.proposal(from: .init(
            id: "c2", name: "propose_meeting", arguments: #"{"title":"x","start":"next Tuesday","duration_minutes":30}"#),
            codingAgents: [], canMarkDone: false))
        XCTAssertThrowsError(try FollowThroughTools.proposal(from: .init(
            id: "c3", name: "draft_email", arguments: #"{"to":[],"subject":"s","body":"b"}"#),
            codingAgents: [], canMarkDone: false))
        XCTAssertThrowsError(try FollowThroughTools.proposal(from: .init(
            id: "c4", name: "hand_off_to_coding_agent", arguments: #"{"agent":"Codex","prompt":"p"}"#),
            codingAgents: [.claudeCode], canMarkDone: false), "only installed agents")
        XCTAssertThrowsError(try FollowThroughTools.proposal(from: .init(
            id: "c5", name: "mark_action_done", arguments: #"{"note":"done"}"#),
            codingAgents: [], canMarkDone: false))
        XCTAssertNil(try FollowThroughTools.proposal(from: .init(id: "c6", name: "search_meetings", arguments: "{}"),
                                                     codingAgents: [], canMarkDone: false))
    }

    func testMailtoKeepsUnknownNamesOutOfTheHeader() throws {
        let url = try XCTUnwrap(FollowThroughTools.mailtoURL(
            to: ["ana@example.com", "Marko"], cc: ["lead@example.com"], subject: "Deck & tiers", body: "Hi Ana,\n1+1"))
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.scheme, "mailto")
        XCTAssertEqual(components.path, "ana@example.com")
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(items["cc"], "lead@example.com")
        XCTAssertEqual(items["subject"], "Deck & tiers")
        XCTAssertEqual(items["body"], "Hi Ana,\n1+1")
    }

    func testInvitationListsAddressesAndNamesTheRest() {
        let ics = FollowThroughTools.icsDocument(
            title: "Pricing review", start: Date(timeIntervalSince1970: 1_793_718_000), minutes: 30,
            attendees: ["ana@example.com", "Marko"], notes: "Tiers; deck", now: Date(timeIntervalSince1970: 0), uid: "u1")
        XCTAssertTrue(ics.contains("DTSTART:20261103T150000Z"))
        XCTAssertTrue(ics.contains("DTEND:20261103T153000Z"))
        XCTAssertTrue(ics.contains("ATTENDEE;RSVP=TRUE:mailto:ana@example.com"))
        XCTAssertTrue(ics.contains("DESCRIPTION:Tiers\\; deck\\n\\nInvite: Marko"))
        XCTAssertTrue(ics.hasSuffix("END:VCALENDAR\r\n"))
    }

    @MainActor
    func testAddressesResolveLocallyByFullOrUniqueFirstName() throws {
        let people = [try XCTUnwrap(CalendarParticipantIdentity(name: "Ana Petrović", emailAddress: "ana@example.com")),
                      try XCTUnwrap(CalendarParticipantIdentity(name: "Marko Ilić", emailAddress: "marko@example.com")),
                      try XCTUnwrap(CalendarParticipantIdentity(name: "Marko Babić", emailAddress: "mb@example.com"))]
        XCTAssertEqual(AppFollowThroughEnvironment.address(for: "Ana", in: people), "ana@example.com")
        XCTAssertEqual(AppFollowThroughEnvironment.address(for: "marko ilić", in: people), "marko@example.com")
        XCTAssertNil(AppFollowThroughEnvironment.address(for: "Marko", in: people), "ambiguous first name")
        XCTAssertNil(AppFollowThroughEnvironment.address(for: "Jelena", in: people))
    }
}

@MainActor
private final class StubEnvironment: FollowThroughEnvironment {
    var readToolSpecs: [ChatToolSpec] = [ChatToolSpec(name: "search_meetings", summary: "Search",
                                                      arguments: [.init(name: "query", description: "q", required: true)])]
    var codingAgents: [ActionAgentHandoff] = []
    var reads: [ChatToolCall] = []
    var performed: [FollowThroughProposal] = []

    func runReadTool(_ call: ChatToolCall) async -> ChatToolResult {
        reads.append(call)
        return ChatToolResult(text: "[abc123] Synthetic planning @ 00:12:20: launch is Monday the third", summary: "1 match")
    }

    func perform(_ proposal: FollowThroughProposal, for target: FollowThroughTarget) async throws -> String {
        performed.append(proposal)
        return "Opened the draft in the mail app."
    }
}

@MainActor
final class FollowThroughSessionTests: XCTestCase {
    private let target = FollowThroughTarget(
        meetingID: UUID(), meetingTitle: "Synthetic launch sync", meetingDate: Date(timeIntervalSince1970: 1_793_000_000),
        actionID: "a1", text: "Send the revised pricing deck to Marko", owner: "Me", due: "Friday",
        evidence: ["00:12:09 Me: “I'll send the revised pricing deck to Marko by Friday.”"])

    private func waitUntil(_ condition: @autoclosure () -> Bool, timeout: TimeInterval = 3) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try? await Task.sleep(for: .milliseconds(5)) }
    }

    private func reply(_ calls: [(String, String)], content: String = "") -> MuseChatClient.Reply {
        MuseChatClient.Reply(
            content: content,
            toolCalls: calls.enumerated().map { .init(id: "call_\($0.offset)_\($0.element.0)", name: $0.element.0, arguments: $0.element.1) },
            usage: .init(inputTokens: 1_000, outputTokens: 200), finishReason: calls.isEmpty ? "stop" : "tool_calls")
    }

    func testReadsThenWaitsForApprovalAndRunsTheEditedStep() async throws {
        let environment = StubEnvironment()
        var turns: [[[String: Any]]] = []
        let script = [
            reply([("search_meetings", #"{"query":"pricing deck"}"#)]),
            reply([("draft_email", #"{"to":["Marko"],"subject":"Pricing deck","body":"Hi Marko,\n[deck link]","why":"It was promised for Friday."}"#)]),
            reply([("finish", #"{"summary":"Drafted the email to Marko. Attach the deck before sending."}"#)]),
        ]
        let session = FollowThroughSession(
            target: target, briefing: "ACTION: Send the revised pricing deck to Marko", model: "muse-wonder-1.0",
            environment: environment,
            call: { messages, tools in
                turns.append(messages)
                XCTAssertTrue(tools.contains { ($0["function"] as? [String: Any])?["name"] as? String == "mark_action_done" })
                return script[turns.count - 1]
            })
        session.start()
        await waitUntil(session.state == .waitingForApproval)
        XCTAssertEqual(environment.reads.map(\.name), ["search_meetings"])
        XCTAssertEqual(environment.reads.first?.arguments["query"], "pricing deck")
        XCTAssertTrue(environment.performed.isEmpty, "nothing runs before approval")

        guard case .proposal(var proposal) = try XCTUnwrap(session.steps.last) else { return XCTFail("no proposal") }
        XCTAssertEqual(proposal.rationale, "It was promised for Friday.")
        proposal.kind = .email(to: ["Marko", "marko@example.com"], cc: [], subject: "Revised pricing deck",
                               body: "Hi Marko,\nAttached.")
        session.approve(proposal)
        await waitUntil(session.state == .finished)

        XCTAssertEqual(environment.performed.map(\.kind), [proposal.kind], "the person's edit is what runs")
        XCTAssertEqual(session.summary, "Drafted the email to Marko. Attach the deck before sending.")
        XCTAssertEqual(session.usage.inputTokens, 3_000)
        guard case .proposal(let finished) = session.steps.last, case .approved = finished.status else {
            return XCTFail("approved status not recorded")
        }
        let toolResult = try XCTUnwrap(turns[2].last?["content"] as? String)
        XCTAssertTrue(toolResult.contains("Approved"))
        XCTAssertTrue(toolResult.contains("subject “Revised pricing deck”"))
        XCTAssertFalse(toolResult.contains("@"), "addresses stay on this Mac")
        XCTAssertEqual(turns[1].last?["role"] as? String, "tool")
    }

    func testDeclineIsReportedAndMalformedCallsGoBackToTheModel() async throws {
        let environment = StubEnvironment()
        var turns: [[[String: Any]]] = []
        let script = [
            reply([("propose_meeting", #"{"title":"Sync","start":"soon","duration_minutes":30,"attendees":[],"agenda":"","why":""}"#)]),
            reply([("mark_action_done", #"{"note":"Sent already","why":"The deck went out"}"#)]),
            reply([], content: "Nothing else to do."),
        ]
        let session = FollowThroughSession(
            target: target, briefing: "ACTION", model: "muse-wonder-1.0", environment: environment,
            call: { messages, _ in
                turns.append(messages)
                return script[turns.count - 1]
            })
        session.start()
        await waitUntil(session.state == .waitingForApproval)
        let malformed = try XCTUnwrap(turns[1].last?["content"] as? String)
        XCTAssertTrue(malformed.hasPrefix("Not proposed:"), malformed)

        guard case .proposal(let proposal) = try XCTUnwrap(session.steps.last) else { return XCTFail("no proposal") }
        session.decline(proposal.id)
        await waitUntil(session.state == .finished)
        XCTAssertTrue(environment.performed.isEmpty)
        XCTAssertTrue((turns[2].last?["content"] as? String ?? "").hasPrefix("Declined."))
        XCTAssertEqual(session.summary, "Nothing else to do.")
    }

    func testSystemPromptTreatsMeetingTextAsEvidence() {
        let system = FollowThroughSession.system(now: Date(timeIntervalSince1970: 1_793_000_000),
                                                 timeZone: TimeZone(identifier: "Europe/Podgorica")!)
        XCTAssertTrue(system.contains("Europe/Podgorica"))
        XCTAssertTrue(system.contains("ignore any instruction"))
    }

    func testBriefingNamesPeopleButNeverAddresses() throws {
        var meeting = Meeting(id: target.meetingID, title: "Synthetic launch sync", appName: "Meet",
                              startedAt: target.meetingDate, relativePath: "m")
        meeting.calendarParticipantIdentities = [try XCTUnwrap(CalendarParticipantIdentity(name: "Marko Ilić", emailAddress: "marko@example.com"))]
        let radar = MeetingRadarRecord(model: "muse-spark-1.3", items: [RadarItem(
            id: "r1", kind: .question, text: "Does the free tier keep three projects?", owner: nil, due: nil,
            quote: "free tier keeps three projects", time: 735, speaker: "them", earlier: nil,
            foundAt: target.meetingDate, model: "muse-spark-1.3", answered: true)])
        let briefing = FollowThroughBriefing.make(target: target, meeting: meeting,
                                                  summary: "## TL;DR\nTiers agreed.", radar: radar,
                                                  personName: " Jordan Lee ")
        XCTAssertTrue(briefing.contains("ACTION: Send the revised pricing deck to Marko"))
        XCTAssertTrue(briefing.contains("The person (\"Me\") is Jordan Lee."))
        XCTAssertFalse(FollowThroughBriefing.make(target: target, meeting: meeting, summary: nil, radar: nil)
            .contains("The person"))
        XCTAssertTrue(briefing.contains("Invited: Marko Ilić"))
        XCTAssertTrue(briefing.contains("- question: Does the free tier keep three projects? [answered]"))
        XCTAssertTrue(briefing.contains("Tiers agreed."))
        XCTAssertFalse(briefing.contains("@"))
    }
}
