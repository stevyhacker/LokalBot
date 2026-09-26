import XCTest
@testable import LokalBot

/// The user's own follow-ups lead every meeting: commitments spoken on this
/// Mac's microphone and requests the user answered, ahead of other people's work.
final class PersonalActionItemsTests: XCTestCase {
    private actor Script {
        var replies: [String]
        var prompts: [String] = []
        init(_ replies: [String]) { self.replies = replies }
        func next(_ prompt: String) throws -> String {
            prompts.append(prompt)
            guard !replies.isEmpty else { throw TextEngineError.badResponse("script exhausted") }
            return replies.removeFirst()
        }
        func recorded() -> [String] { prompts }
    }

    private struct Engine: TextEngine {
        var script: Script
        var displayName: String { "Personal actions fixture" }
        func tokenCount(_ text: String) async throws -> Int? { max(1, text.utf8.count / 4) }
        func generate(system: String, prompt: String, context: [String]) async throws -> String {
            try await script.next(prompt)
        }
        func generate(system: String, prompt: String, context: [String],
                      schema: [String: Any], options: TextGenerationOptions) async throws -> String {
            try await script.next(prompt)
        }
    }

    private func microphone(_ start: Double, _ text: String, speaker: String = "local 1") -> Transcript.Segment {
        // Persisted exactly as transcripts were while the microphone default was off.
        .init(start: start, end: start + 4, speaker: speaker, text: text,
              attribution: .init(source: .microphone, identity: .unresolved, method: .diarization))
    }

    private func remote(_ start: Double, _ speaker: String, _ text: String) -> Transcript.Segment {
        .init(start: start, end: start + 4, speaker: speaker, text: text,
              attribution: .init(source: .system, identity: .other, method: .diarization))
    }

    private func action(_ source: String, text: String, owner: String = "source", basis: String = "commitment",
                        context: [String] = [], importance: Int = 3) -> [String: Any] {
        ["text": text, "source": source, "context": context, "owner": owner, "basis": basis,
         "due": "", "importance": importance]
    }

    private func response(notes: [[String: Any]] = [], actions: [[String: Any]]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: [
            "notes": notes, "actions": actions, "has_more": false]), as: UTF8.self)
    }

    private func validate(_ transcript: Transcript, _ actions: [[String: Any]]) throws -> MeetingNotesEvidence.Validated {
        let evidence = MeetingNotesEvidence(transcript: transcript)
        return evidence.validate(try response(actions: actions), units: evidence.units, template: .meeting,
                                 meetingID: UUID(), maximumNotes: 12, maximumActions: 10)
    }

    // MARK: - Requests directed to the user

    func testRemoteRequestAnsweredByTheUserBelongsToTheUser() throws {
        let transcript = Transcript(segments: [
            remote(0, "them 1", "Could you send me the product doc after the call?"),
            microphone(5, "Sure, sounds good."),
        ], engine: "fixture")
        for owner in ["unknown", "p1"] {
            let result = try validate(transcript, [action("s1", text: "Send the product doc after the call",
                                                          owner: owner, basis: "request", context: ["s2"])])
            let item = try XCTUnwrap(result.outcomes.actionItems.first, owner)
            XCTAssertTrue(item.isForUser, owner)
            XCTAssertEqual(item.owner, "Me")
            XCTAssertEqual(item.attribution?.basis, .request)
            XCTAssertEqual(item.attribution?.speakerID, "local 1")
            XCTAssertEqual(item.displayText, "Requested: Send the product doc after the call")
            XCTAssertEqual(item.citations.count, 2)
        }
    }

    func testUnnamedRequestNotAnsweredByTheUserStaysUnassigned() throws {
        let otherReply = Transcript(segments: [
            remote(0, "them 1", "Could you send me the product doc after the call?"),
            remote(5, "them 2", "Yes, I'll look for it."),
            microphone(10, "Great."),
        ], engine: "fixture")
        let group = Transcript(segments: [
            remote(0, "them 1", "Can you all review the doc before Friday?"),
            microphone(5, "Sure."),
        ], engine: "fixture")
        let pause = Transcript(segments: [
            remote(0, "them 1", "Could you send me the product doc?"),
            microphone(40, "Anyway, back to the roadmap."),
        ], engine: "fixture")
        for transcript in [otherReply, group, pause] {
            let userID = try XCTUnwrap(MeetingNotesEvidence(transcript: transcript).speakers.first { $0.value.identity == .user }?.key)
            for owner in ["unknown", userID] {
                let result = try validate(transcript, [action("s1", text: "Send the product doc",
                                                              owner: owner, basis: "request")])
                XCTAssertFalse(result.outcomes.actionItems.first?.isForUser ?? true, transcript.segments[0].text)
            }
        }
    }

    func testSecondPersonRequestRecognitionExcludesGroupsHypotheticalsAndNegation() {
        for request in ["Could you send me the deck?", "Can you please review the PR today?",
                        "If you could share the doc, that would be great.", "You need to update the budget.",
                        "I'd like you to own the migration.", "Please send the invoice.", "Make sure you file the ticket."] {
            XCTAssertTrue(OutcomeEvidencePolicy.isSecondPersonRequest(request), request)
        }
        for statement in ["Can you all review the doc?", "Could someone check the logs?", "If it breaks, you might fix it.",
                          "You should not deploy on Friday.", "Can you not merge it yet?", "Please note the deadline.",
                          "I will send the deck."] {
            XCTAssertFalse(OutcomeEvidencePolicy.isSecondPersonRequest(statement), statement)
        }
    }

    // MARK: - Speaker echo

    func testNearDuplicateEchoCannotBecomeMyEvidenceWhileMyOwnSpeechStaysMine() throws {
        var echo = microphone(3, "I will take a holiday before Patagonia.")
        echo.end = 9
        var request = remote(3.4, "them 1", "Yes, I will take a holiday before Patagonia.")
        request.end = 9.3
        let transcript = Transcript(segments: [
            echo, request,
            remote(12, "them 1", "Can you send the deck tomorrow?"),
            microphone(16, "I will send the deck tomorrow."),
        ], engine: "fixture", speakerAliases: ["them 1": "Nikola"])
        XCTAssertEqual(SpeakerBleedFilter.nearDuplicateEchoIndices(in: transcript), [0],
                       "A reply that shares some words with a request is not echo")
        let evidence = MeetingNotesEvidence(transcript: transcript)
        XCTAssertEqual(evidence.units.map(\.source), ["s2", "s3", "s4"], "Echo is withheld from the model")
        XCTAssertEqual(evidence.units.filter(\.isUserCommitment).map(\.source), ["s4"])
        XCTAssertTrue(evidence.roster.contains(#""identity":"user""#), "Echo cannot outvote the user's own voice")
        let result = evidence.validate(try response(actions: [
            action("s1", text: "Take a holiday before Patagonia"),
            action("s4", text: "Send the deck tomorrow"),
        ]), units: evidence.units, template: .meeting, meetingID: UUID(), maximumNotes: 12, maximumActions: 10)
        XCTAssertEqual(result.outcomes.userActionItems.map(\.text), ["Send the deck tomorrow"])
        XCTAssertEqual(result.rejected.map(\.reason), ["unknown_source"])
    }

    // MARK: - Keep tasks whose wording escaped the commitment check

    func testWeeklyMeetingCommitmentsKeepUserOwnershipAcrossSplitTranscriptRows() throws {
        let shipping = "Yeah, so on my side, I'll try to keep up the the shipping cadence and review all the things as they come."
        let plan = "I do plan to take on a bit more."
        let transcript = Transcript(segments: [
            microphone(0, shipping),
            microphone(10, plan),
            microphone(15, "work myself and more tasks, so."),
            microphone(20, "Part of the rebrand next week."),
        ], engine: "fixture")
        let evidence = MeetingNotesEvidence(transcript: transcript)
        XCTAssertEqual(evidence.units.filter(\.isUserCommitment).map(\.source), ["s1", "s2"],
                       "Both commitments must also participate in omitted-action repair")
        for owner in ["source", "unknown"] {
            for basis in ["commitment", "unclear"] {
                let result = try validate(transcript, [
                    action("s1", text: "Keep up the shipping cadence and review incoming items", owner: owner, basis: basis),
                    action("s2", text: "Take on more tasks including the rebrand next week", owner: owner,
                           basis: basis, context: ["s3", "s4"]),
                ])
                XCTAssertTrue(result.rejected.isEmpty)
                XCTAssertEqual(result.outcomes.actionItems.count, 2)
                XCTAssertEqual(result.outcomes.userActionItems.count, 2, "owner=\(owner), basis=\(basis)")
                for item in result.outcomes.actionItems {
                    XCTAssertEqual(item.owner, "Me")
                    XCTAssertEqual(item.attribution?.speakerID, "local 1")
                    XCTAssertEqual(item.attribution?.basis, .commitment)
                    XCTAssertNil(item.attribution?.rejectionReason)
                }
                XCTAssertEqual(result.outcomes.actionItems.map { $0.attribution?.quote }, [shipping, plan])
                XCTAssertEqual(result.outcomes.actionItems.last?.citations.count, 3)
            }
        }
    }

    func testPersonalPlanRecognitionDoesNotOverrideSpeakerIdentity() throws {
        let text = "On my side, I do plan to send the draft."
        var confirmedOther = microphone(10, text, speaker: "local 2")
        confirmedOther.attribution = .init(source: .microphone, identity: .other, method: .confirmation)
        var unconfirmed = microphone(20, text, speaker: "local 3")
        unconfirmed.attribution = .init(source: .microphone, identity: .unresolved, method: .confirmation)
        let transcript = Transcript(segments: [remote(0, "them 1", text), confirmedOther, unconfirmed], engine: "fixture")
        let result = try validate(transcript, (1...3).map { action("s\($0)", text: "Send the draft") })
        XCTAssertTrue(result.outcomes.userActionItems.isEmpty)
        XCTAssertEqual(result.outcomes.actionItems.map { $0.attribution?.resolution }, [.other, .other, .unresolved])
        XCTAssertEqual(result.outcomes.actionItems.last?.attribution?.rejectionReason, .unconfirmedIdentity)
    }

    func testPrefacedAcceptanceStillNeedsTaskContextAndConversationManagementIsRejected() throws {
        let transcript = Transcript(segments: [
            microphone(0, "On my side, I can do that."),
            microphone(10, "On my side, I'll be brief."),
        ], engine: "fixture")
        let result = try validate(transcript, [
            action("s1", text: "Perform the requested task"),
            action("s2", text: "Be brief"),
        ])
        XCTAssertTrue(result.outcomes.actionItems.isEmpty)
        XCTAssertEqual(result.rejected.map(\.reason), ["missing_task_context", "conversation_management"])
    }

    func testUnrecognizedCommitmentWordingKeepsTheTaskWithUnclearOwner() throws {
        let transcript = Transcript(segments: [
            microphone(0, "We should get the OpenRouter key over to the team this week."),
            microphone(5, "I won't send the invoice."),
            microphone(10, "I'm gonna set up the staging server."),
        ], engine: "fixture")
        let result = try validate(transcript, [
            action("s1", text: "Get the OpenRouter key to the team this week"),
            action("s2", text: "Send the invoice"),
            action("s3", text: "Set up the staging server"),
        ])
        XCTAssertEqual(result.outcomes.actionItems.map(\.text), ["Get the OpenRouter key to the team this week",
                                                                 "Set up the staging server"])
        let kept = result.outcomes.actionItems[0]
        XCTAssertTrue(kept.ownershipIsUnclear)
        XCTAssertTrue(kept.isLikelyUserAction)
        XCTAssertTrue(result.outcomes.actionItems[1].isForUser, "\"I'm gonna\" is an explicit undertaking")
        XCTAssertEqual(result.rejected.map(\.reason), ["unsupported_commitment"], "Negated undertakings stay rejected")
    }

    // MARK: - Ranking

    func testLikelyUserActionsRankAheadOfOtherParticipantsAndSurviveTheCap() {
        func citation(_ speaker: String, _ start: Double) -> OutcomeSourceCitation {
            .init(meetingID: nil, segmentID: "segment-\(start)", start: start, end: start + 1, speaker: speaker, excerpt: "")
        }
        let remote = (0..<6).map { index in
            MeetingOutcomes.ActionItem(text: "Remote task \(index)", owner: "Them 1", isForUser: false, importance: 5,
                citations: [citation("them 1", Double(index))],
                attribution: .init(resolution: .other, speakerID: "them 1", basis: .commitment))
        }
        let unclearRemote = MeetingOutcomes.ActionItem(text: "Unclear remote task", importance: 5,
            citations: [citation("them 2", 20)],
            attribution: .init(resolution: .unresolved, speakerID: "them 2", basis: .unclear, rejectionReason: .missingBasis))
        let likely = ["local 1", "source2:local 2"].enumerated().map { index, speaker in
            MeetingOutcomes.ActionItem(text: "Likely mine \(index)", importance: 1, citations: [citation(speaker, 30)],
                attribution: .init(resolution: .unresolved, speakerID: speaker, basis: .unclear, rejectionReason: .missingBasis))
        }
        let mine = MeetingOutcomes.ActionItem(text: "Send the deck", owner: "Me", isForUser: true, importance: 1,
            citations: [citation("local 1", 40)], attribution: .init(resolution: .user, speakerID: "local 1", basis: .commitment))
        let ranked = MeetingOutcomes(actionItems: remote + [unclearRemote] + likely + [mine]).prioritizingActionItems()
        XCTAssertEqual(ranked.actionItems.map(\.text).prefix(3), ["Send the deck", "Likely mine 0", "Likely mine 1"])
        XCTAssertEqual(ranked.actionItems.count, 8, "Five other or unclear actions fill the remaining room")
        XCTAssertFalse(unclearRemote.isLikelyUserAction)
        XCTAssertFalse(remote[0].isLikelyUserAction)
    }

    // MARK: - End to end

    func testTirthStyleMeetingListsMyCommitmentsAndRequestsFirst() async throws {
        let transcript = Transcript(segments: [
            remote(0, "them 1", "We are building a consumer chatbot on the QVAC stack."),
            microphone(5, "I will send a deck so you can introduce us to crypto VCs."),
            remote(10, "them 2", "Could you send me the product doc after the call?"),
            microphone(15, "Yes, will do."),
            remote(20, "them 3", "I will send a demo of the chatbot product."),
        ], engine: "fixture")
        let script = Script([try response(
            notes: [["section": "Key points", "text": "Building a consumer chatbot on the QVAC stack.", "source": "s1"]],
            actions: [
                action("s5", text: "Send a demo of the chatbot product", importance: 5),
                action("s3", text: "Send the product doc after the call", owner: "unknown", basis: "request", context: ["s4"]),
                action("s2", text: "Send a deck for crypto VC introductions"),
            ])])
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }

        let result = try await MeetingNotesGenerator.generate(transcript: transcript, engine: Engine(script: script),
            template: .meeting, language: .matchTranscript, context: [], contextTokens: 32_768,
            meetingID: UUID(), folder: folder)

        XCTAssertEqual(result.outcomes.actionItems.map(\.displayText), [
            "Send a deck for crypto VC introductions",
            "Requested: Send the product doc after the call",
            "Send a demo of the chatbot product",
        ], "The user's actions lead, in meeting order, even when the model ranks another's higher")
        XCTAssertEqual(result.outcomes.actionItems.map(\.isForUser), [true, true, false])
        XCTAssertEqual(result.outcomes.actionItems.last?.owner, "Them 3")
        let prompts = await script.recorded()
        let prompt = try XCTUnwrap(prompts.first)
        XCTAssertTrue(prompt.contains(#""identity":"user""#), "The model must see who the user is")
        XCTAssertTrue(prompt.contains("Explicit user commitments: s2."))
        XCTAssertTrue(result.body.contains("### Me"))
    }

    func testNotesPromptAsksForEveryUserActionIncludingRequests() {
        let prompt = PromptTemplates.meetingNotesSystem(template: .meeting, language: .matchTranscript)
        XCTAssertTrue(prompt.contains("requests or assignments directed to the user"))
        XCTAssertTrue(prompt.contains("List those actions first"))
        XCTAssertTrue(prompt.contains("Actions are not minor details"))
        XCTAssertTrue(prompt.contains("the user answers in the next row"))
    }

    // MARK: - Setting

    @MainActor
    func testMicrophoneSettingDefaultsOnRoundTripsAndReachesTranscripts() throws {
        XCTAssertTrue(AppSettings().microphoneIsUser)
        var settings = AppSettings()
        settings.microphoneIsUser = false
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertFalse(decoded.microphoneIsUser)
        addTeardownBlock { SpeakerAttribution.microphoneIsUser = true }

        let store = SettingsStore(initialSettings: decoded)
        XCTAssertFalse(SpeakerAttribution.microphoneIsUser)
        let segment = microphone(0, "I will send the deck.")
        XCTAssertEqual(segment.resolvedAttribution.identity, .unresolved)
        store.current.microphoneIsUser = true
        XCTAssertTrue(SpeakerAttribution.microphoneIsUser)
        XCTAssertEqual(segment.resolvedAttribution.identity, .user)
    }
}
