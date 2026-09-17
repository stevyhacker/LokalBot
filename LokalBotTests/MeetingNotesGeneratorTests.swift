import XCTest
@testable import LokalBot

final class MeetingNotesGeneratorTests: XCTestCase {
    private actor Script {
        enum Reply {
            case text(String)
            case truncated(String)
            case error(TextEngineError)
            case wait
        }
        struct Call {
            var prompt: String
            var options: TextGenerationOptions
        }
        var replies: [Reply]
        var calls: [Call] = []
        var cancelled = false
        var tokenizations = 0

        init(_ replies: [Reply]) { self.replies = replies }
        func next(prompt: String, options: TextGenerationOptions) async throws -> String {
            calls.append(Call(prompt: prompt, options: options))
            guard !replies.isEmpty else { throw TextEngineError.badResponse("script exhausted") }
            switch replies.removeFirst() {
            case .text(let text): return text
            case .truncated(let text): throw TruncatedStructuredResponse(content: text)
            case .error(let error): throw error
            case .wait:
                do { try await Task.sleep(for: .seconds(30)); return "" } catch { cancelled = true; throw error }
            }
        }
        func count(_ text: String) -> Int { tokenizations += 1; return max(1, text.utf8.count / 4) }
        func recorded() -> [Call] { calls }
    }

    private struct Engine: TextEngine {
        var script: Script
        var hasTokenizer = true
        var minimumStructuredOutputTokens = 512
        var displayName: String { "Notes fixture" }
        func tokenCount(_ text: String) async throws -> Int? { hasTokenizer ? await script.count(text) : nil }
        func generate(system: String, prompt: String, context: [String]) async throws -> String {
            try await script.next(prompt: prompt, options: .init())
        }
        func generate(system: String, prompt: String, context: [String],
                      schema: [String: Any], options: TextGenerationOptions) async throws -> String {
            try await script.next(prompt: prompt, options: options)
        }
    }

    private var transcript: Transcript {
        var result = Transcript(segments: [
            .init(start: 0, end: 5, speaker: "me", text: "I will ship the update on Friday."),
            .init(start: 5, end: 10, speaker: "them", text: "I will review the documentation. We agreed to keep the release date."),
            .init(start: 10, end: 15, speaker: "them", text: "What happens if the dependency is delayed?"),
        ], engine: "fixture")
        result.confirmSpeaker("me", isUser: true)
        return result
    }

    private func note(_ source: String = "s1", _ text: String = "Will ship the update on Friday.",
                      section: String = "Key points") -> [String: Any] {
        ["section": section, "text": text, "source": source]
    }
    private func action(_ source: String = "s1", owner: String = "p1") -> [String: Any] {
        ["text": "Ship the update", "source": source, "context": [], "owner": owner, "basis": "commitment",
         "due": "Friday", "importance": 5]
    }
    private func response(notes: [[String: Any]] = [], actions: [[String: Any]] = [], more: Bool = false) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: ["notes": notes, "actions": actions, "has_more": more]), as: UTF8.self)
    }
    private func folder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }
    private func generate(_ script: Script, transcript: Transcript? = nil, folder: URL? = nil,
                          contextTokens: Int = 32_768,
                          minimumOutputTokens: Int = 512,
                          budget: MeetingGenerationBudget = MeetingGenerationBudget()) async throws -> MeetingNotesGenerator.Result {
        try await MeetingNotesGenerator.generate(transcript: transcript ?? self.transcript,
            engine: Engine(script: script, minimumStructuredOutputTokens: minimumOutputTokens),
            template: .meeting, language: .matchTranscript, context: [], contextTokens: contextTokens,
            meetingID: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!, folder: try folder ?? self.folder(), budget: budget)
    }

    func testOnePassProducesSummaryActionsDecisionsAndQuestions() async throws {
        let script = Script([.text(try response(notes: [
            note(), note("s2", "Keep the release date.", section: "Decisions"),
            note("s3", "What happens if the dependency is delayed?", section: "Open questions"),
        ], actions: [action()]))])
        let result = try await generate(script)
        let calls = await script.recorded()
        XCTAssertEqual(calls.count, 1, "there must be no second transcript scan or narrative synthesis")
        XCTAssertEqual(calls[0].options.reasoningBudgetTokens, 0)
        XCTAssertEqual(result.outcomes.userActionItems.count, 1)
        XCTAssertEqual(result.outcomes.decisionRecords.count, 1)
        XCTAssertEqual(result.outcomes.openQuestions.count, 1)
        XCTAssertTrue(result.body.contains("**You:**"))
        XCTAssertEqual(result.claims[0].segmentID, transcript.segmentID(at: 0))
        XCTAssertEqual(result.claims[0].speakerID, "me")
        XCTAssertEqual(result.claims[0].quote, transcript.segments[0].displayText)
        XCTAssertEqual(result.outcomes.actionItems[0].citations[0].segmentID, transcript.segmentID(at: 0))
        let observed1 = await script.tokenizations
        XCTAssertGreaterThan(observed1, 0)
    }

    func testRepairKeepsValidRecordsAndOnlySendsRejectedSources() async throws {
        var transcript = transcript
        transcript.segments += (3..<12).map { index in
            .init(start: Double(index * 5), end: Double(index * 5 + 5), speaker: "them",
                  text: "Documentation update \(index).")
        }
        let script = Script([
            .text(try response(notes: [note(), note("s6", "Review docs", section: "Wrong section")], actions: [action()])),
            .text(try response(notes: [note("s6", "Documentation update.")])),
        ])
        let result = try await generate(script, transcript: transcript)
        let calls = await script.recorded()
        XCTAssertEqual(calls.count, 2)
        XCTAssertTrue(calls[1].prompt.contains("s6|"))
        XCTAssertFalse(calls[1].prompt.contains("s1|"))
        XCTAssertFalse(calls[1].prompt.contains("s9|"))
        XCTAssertFalse(calls[1].prompt.contains("Wrong section"))
        XCTAssertLessThan(calls[1].options.maxTokens ?? 0, calls[0].options.maxTokens ?? 0)
        XCTAssertEqual(result.claims.count, 2)
        XCTAssertEqual(result.outcomes.userActionItems.count, 1)
    }

    func testRepairFailureSavesEarlierValidRecordsWithoutReplacingFinalArtifacts() async throws {
        let output = try folder()
        try Data("Previous complete summary".utf8).write(to: output.appendingPathComponent("summary.md"))
        let script = Script([
            .text(try response(notes: [note(), note("s2", "Review docs", section: "Wrong")])),
            .error(.badResponse("repair failed")),
        ])
        do { _ = try await generate(script, folder: output); XCTFail("expected failure") } catch {}
        let artifact = try JSONDecoder().decode(SummaryClaimEvidence.Artifact.self,
            from: Data(contentsOf: output.appendingPathComponent("summary.claims.partial.json")))
        XCTAssertEqual(artifact.claims.count, 1)
        XCTAssertEqual(try String(contentsOf: output.appendingPathComponent("summary.md"), encoding: .utf8), "Previous complete summary")
        XCTAssertTrue(try String(contentsOf: output.appendingPathComponent("summary.partial.md"), encoding: .utf8).contains("Partial notes"))
        let observed2 = await script.recorded().count
        XCTAssertEqual(observed2, 2)
    }

    func testTruncationSalvagesOnlyCompleteRecordsAndCannotReportSuccess() async throws {
        let complete = String(decoding: try JSONSerialization.data(withJSONObject: note()), as: UTF8.self)
        let script = Script([.truncated("{\"notes\":[" + complete + ",{\"text\":\"unfinished"), .truncated("")])
        let output = try folder()
        do { _ = try await generate(script, folder: output); XCTFail("truncated scan must remain partial") } catch is MeetingNotesGenerator.Incomplete {} catch { XCTFail("unexpected error \(error)") }
        let artifact = try JSONDecoder().decode(SummaryClaimEvidence.Artifact.self,
            from: Data(contentsOf: output.appendingPathComponent("summary.claims.partial.json")))
        XCTAssertEqual(artifact.claims.count, 1)
        let observed3 = await script.recorded().count
        XCTAssertEqual(observed3, 2, "continue accepted records once, then stop on a page with no progress")
    }

    func testRepeatedInvalidRecordIsOmittedAfterOneRepairAndValidRecordsSurvive() async throws {
        let invalid = try response(notes: [note(), note("s2", "Bad section", section: "invalid")], actions: [action()])
        let script = Script([.text(invalid), .text(try response(notes: [note("s2", "Still invalid", section: "invalid")]))])
        let result = try await generate(script)
        XCTAssertEqual(result.claims.count, 1)
        XCTAssertEqual(result.outcomes.userActionItems.count, 1)
        let observed4 = await script.recorded().count
        XCTAssertEqual(observed4, 2)
    }

    func testMissingUserCommitmentGetsOneRepairWithoutRescanningTheMeeting() async throws {
        var transcript = longTranscript()
        transcript.segments[20] = .init(start: 100, end: 105, speaker: "me", text: "I will send the draft.", attribution: .init(source: .microphone, identity: .user, method: .confirmation))
        let script = Script([
            .text(try response(notes: [note("s1", "The dependency needs review.")])),
            .text(try response(actions: [action("s21", owner: "source")])),
        ])
        let result = try await generate(script, transcript: transcript)
        let calls = await script.recorded()
        XCTAssertEqual(calls.count, 2)
        XCTAssertTrue(calls[1].prompt.contains("missing_user_commitment"))
        XCTAssertTrue(calls[1].prompt.contains("s21|"))
        XCTAssertFalse(calls[1].prompt.contains("s1|"))
        XCTAssertFalse(calls[1].prompt.contains("s60|"))
        XCTAssertEqual(result.outcomes.userActionItems.count, 1)
    }

    func testEmptySubstantialPartCannotReportComplete() async throws {
        let script = Script([.text(try response())])
        do {
            _ = try await generate(script, transcript: longTranscript())
            XCTFail("empty output cannot certify substantial evidence")
        } catch is MeetingNotesGenerator.Incomplete {} catch { XCTFail("unexpected error \(error)") }
        let calls = await script.recorded()
        XCTAssertEqual(calls.count, 1)
    }

    func testUnknownSourceCannotBeRepairedUsingUnrelatedEvidence() async throws {
        let script = Script([.text(try response(notes: [note("s999", "unsupported")], actions: [action()]))])
        do { _ = try await generate(script); XCTFail("expected partial") } catch {}
        let observed5 = await script.recorded().count
        XCTAssertEqual(observed5, 1)
    }

    func testExplicitOverflowIsPartialEvenWithWellFormedJSON() async throws {
        let page = try response(notes: [note()], actions: [action()], more: true)
        let script = Script([.text(page), .text(page)])
        do { _ = try await generate(script); XCTFail("overflow cannot silently drop coverage") } catch is MeetingNotesGenerator.Incomplete {} catch { XCTFail("unexpected error \(error)") }
    }

    func testOverflowContinuesWithAcceptedRecordsAndKeepsDistinctFactsFromTheSameSource() async throws {
        let script = Script([
            .text(try response(notes: [note("s1", "A first release takeaway.")], actions: [action()], more: true)),
            .text(try response(notes: [note("s1", "Another distinct release takeaway.")])),
        ])
        let result = try await generate(script)
        let calls = await script.recorded()
        XCTAssertEqual(calls.count, 2)
        XCTAssertTrue(calls[1].prompt.contains("Previously accepted records:"))
        XCTAssertTrue(calls[1].prompt.contains("A first release takeaway."))
        XCTAssertTrue(calls[1].prompt.contains("s1|"), "a source can contain another distinct fact")
        XCTAssertEqual(result.claims.count, 2)
        XCTAssertEqual(result.outcomes.userActionItems.count, 1)
    }

    func testContinuationPersistsAcrossRequestLimitWithoutRepeatingTheFirstPage() async throws {
        let output = try folder()
        let first = Script([.text(try response(notes: [note("s1", "Accepted first page.")], actions: [action()], more: true))])
        do {
            _ = try await generate(first, folder: output, budget: MeetingGenerationBudget(limits: .init(requests: 1)))
            XCTFail("continuation must share the request limit")
        } catch is MeetingGenerationBudget.Exhausted {} catch { XCTFail("unexpected error \(error)") }
        let resumed = Script([.text(try response(notes: [note("s2", "Accepted second page.")]))])
        let result = try await generate(resumed, folder: output)
        let calls = await resumed.recorded()
        XCTAssertEqual(calls.count, 1)
        XCTAssertTrue(calls[0].prompt.contains("Previously accepted records:"))
        XCTAssertTrue(calls[0].prompt.contains("Accepted first page."))
        XCTAssertEqual(result.claims.count, 2)
    }

    func testContinuationStopsAfterThreePagesAndResumesItsLedger() async throws {
        let output = try folder()
        let first = Script(try (1...3).map { index in
            .text(try response(notes: [note("s1", "Accepted fact \(index).")], actions: [action()], more: true))
        })
        do { _ = try await generate(first, folder: output); XCTFail("must remain partial")
        } catch is MeetingNotesGenerator.Incomplete {} catch { XCTFail("unexpected error \(error)") }
        let initialCalls = await first.recorded()
        XCTAssertEqual(initialCalls.count, 3)
        let resumed = Script([.text(try response())])
        let result = try await generate(resumed, folder: output)
        let calls = await resumed.recorded()
        XCTAssertEqual(calls.count, 1)
        XCTAssertTrue(calls[0].prompt.contains("Accepted fact 3."))
        XCTAssertEqual(result.claims.count, 3)
        XCTAssertEqual(result.outcomes.userActionItems.count, 1)
    }

    func testReasoningRepairHasHeadroomAndOneLargerRetry() async throws {
        let script = Script([
            .text(try response(notes: [note(), note("s2", "Needs repair", section: "Wrong")], actions: [action()])),
            .truncated(""),
            .text(try response(notes: [note("s2", "Documentation needs review.")])),
        ])
        let result = try await generate(script, minimumOutputTokens: 2_048)
        let calls = await script.recorded()
        XCTAssertEqual(calls.map { $0.options.maxTokens }, [4_096, 2_048, 4_096])
        XCTAssertEqual(result.claims.count, 2)
        XCTAssertEqual(result.outcomes.userActionItems.count, 1)
    }

    func testFailedRepairResumesOnlyTheRepairWithItsLargerAllowance() async throws {
        let output = try folder()
        let first = Script([
            .text(try response(notes: [note(), note("s2", "Needs repair", section: "Wrong")], actions: [action()])),
            .truncated(""), .truncated(""),
        ])
        do { _ = try await generate(first, folder: output, minimumOutputTokens: 2_048); XCTFail("repair must remain partial")
        } catch is MeetingNotesGenerator.Incomplete {} catch { XCTFail("unexpected error \(error)") }
        let resumed = Script([.text(try response(notes: [note("s2", "Documentation needs review.")]))])
        let result = try await generate(resumed, folder: output, minimumOutputTokens: 2_048)
        let calls = await resumed.recorded()
        XCTAssertEqual(calls.count, 1)
        XCTAssertTrue(calls[0].prompt.contains("This is a targeted repair."))
        XCTAssertEqual(calls[0].options.maxTokens, 4_096)
        XCTAssertEqual(result.claims.count, 2)
    }

    func testRepairCannotSpendBeyondSharedRequestOrOutputLimits() async throws {
        let output = try folder()
        let script = Script([
            .text(try response(notes: [note(), note("s2", "Needs repair", section: "Wrong")], actions: [action()])),
            .truncated(""),
        ])
        do {
            _ = try await generate(script, folder: output, minimumOutputTokens: 2_048,
                budget: MeetingGenerationBudget(limits: .init(requests: 2, outputTokens: 6_144)))
            XCTFail("the larger retry must remain inside the shared allowance")
        } catch is MeetingGenerationBudget.Exhausted {} catch { XCTFail("unexpected error \(error)") }
        let calls = await script.recorded()
        XCTAssertEqual(calls.count, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.appendingPathComponent(MeetingNotesPartial.fileName).path))
    }

    func testOnlyKnownAlwaysReasoningProviderRaisesTheStructuredOutputFloor() {
        let url = URL(string: "https://openrouter.ai/api/v1")!
        var engine = OpenAICompatibleEngine(baseURL: url, model: "z-ai/glm-5.3-flash", chatDialect: .openRouter)
        XCTAssertEqual(engine.minimumStructuredOutputTokens, 2_048)
        engine.model += ":nitro"
        XCTAssertEqual(engine.minimumStructuredOutputTokens, 2_048)
        engine.chatDialect = .generic
        XCTAssertEqual(engine.minimumStructuredOutputTokens, 512)
        engine.chatDialect = .openRouter
        engine.model = "unknown/model"
        XCTAssertEqual(engine.minimumStructuredOutputTokens, 512)
    }

    func testWrongOwnerAndNegatedCommitmentRemainUnassigned() throws {
        let evidence = MeetingNotesEvidence(transcript: transcript)
        let wrongOwner = evidence.validate(try response(actions: [action(owner: "p2")]),
            units: evidence.units, template: .meeting, meetingID: UUID(), maximumNotes: 12, maximumActions: 10)
        XCTAssertFalse(wrongOwner.outcomes.actionItems[0].isForUser)
        XCTAssertTrue(wrongOwner.outcomes.actionItems[0].ownershipIsUnclear)
        var negatedTranscript = transcript
        negatedTranscript.segments[0].text = "If approved, I will ship the update on Friday."
        let negated = MeetingNotesEvidence(transcript: negatedTranscript)
        let result = negated.validate(try response(actions: [action()]), units: negated.units,
            template: .meeting, meetingID: UUID(), maximumNotes: 12, maximumActions: 10)
        XCTAssertTrue(result.outcomes.actionItems.isEmpty)
        XCTAssertEqual(result.rejected.first?.reason, "unsupported_commitment")
    }

    func testSpeakerCorrectionOverridesMicrophoneDefaultInUnifiedExtraction() throws {
        var transcript = transcript
        transcript.confirmSpeaker("me", isUser: false)
        let evidence = MeetingNotesEvidence(transcript: transcript)
        let result = evidence.validate(try response(notes: [note()], actions: [action()]),
            units: evidence.units, template: .meeting, meetingID: UUID(), maximumNotes: 12, maximumActions: 10)
        XCTAssertFalse(result.outcomes.actionItems[0].isForUser)
        XCTAssertEqual(result.outcomes.actionItems[0].attribution?.resolution, .other)
    }

    func testSourceMembershipAndVisibleQuoteAreCheckedWithinPart() throws {
        let evidence = MeetingNotesEvidence(transcript: transcript)
        var unit = evidence.units[0]
        unit.text = "the update on Friday."
        let result = evidence.validate(try response(notes: [note("s2", "outside part")], actions: [action()]),
            units: [unit], template: .meeting, meetingID: UUID(), maximumNotes: 12, maximumActions: 10)
        XCTAssertTrue(result.claims.isEmpty)
        XCTAssertEqual(result.rejected.count, 2)
        XCTAssertTrue(result.outcomes.actionItems.isEmpty)
    }

    func testSchemaBoundsArraysTextSectionsSourcesAndOwners() throws {
        let evidence = MeetingNotesEvidence(transcript: transcript)
        let schema = MeetingNotesEvidence.schema(units: [evidence.units[0]], speakers: ["p1"],
                                                template: .meeting, maximumNotes: 8, maximumActions: 5)
        XCTAssertNil(OpenAIStrictSchemaValidator.validationIssue(in: schema))
        let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
        let notes = try XCTUnwrap(properties["notes"] as? [String: Any])
        XCTAssertEqual(notes["maxItems"] as? Int, 8)
        let noteProperties = try XCTUnwrap((notes["items"] as? [String: Any])?["properties"] as? [String: Any])
        XCTAssertEqual((noteProperties["source"] as? [String: Any])?["enum"] as? [String], ["s1"])
        XCTAssertEqual((noteProperties["text"] as? [String: Any])?["maxLength"] as? Int, 280)
    }

    func testProseCannotOverrideDerivedSpeakerWithAModelID() throws {
        let evidence = MeetingNotesEvidence(transcript: transcript)
        let result = evidence.validate(try response(notes: [note("s1", "p2 will ship the update.")]),
            units: evidence.units, template: .meeting, meetingID: UUID(), maximumNotes: 12, maximumActions: 10)
        XCTAssertTrue(result.claims.isEmpty)
        XCTAssertEqual(result.rejected.count, 1)
    }

    func testOnlyAMatchingLeadingSpeakerIDCanBeRemovedFromProse() throws {
        let evidence = MeetingNotesEvidence(transcript: transcript)
        for prefix in ["p1", "Speaker p1", "User p1"] {
            let result = evidence.validate(try response(notes: [note("s1", "\(prefix) will ship the update.")]),
                units: evidence.units, template: .meeting, meetingID: UUID(), maximumNotes: 12, maximumActions: 10)
            XCTAssertEqual(result.claims.first?.text, "Will ship the update.")
            XCTAssertEqual(result.claims.first?.speakerID, "me")
            XCTAssertTrue(result.rejected.isEmpty)
        }
        let wrong = evidence.validate(try response(notes: [note("s1", "Speaker p2 will ship the update.")]),
            units: evidence.units, template: .meeting, meetingID: UUID(), maximumNotes: 12, maximumActions: 10)
        XCTAssertTrue(wrong.claims.isEmpty)
    }

    func testAnUnknownOwnerCanResolveOnlyFromAnExplicitQuotedCommitment() throws {
        var transcript = transcript
        transcript.segments[0].text = "After this, I'm going to create the remaining tickets."
        let evidence = MeetingNotesEvidence(transcript: transcript)
        var raw = action(owner: "unknown")
        raw["basis"] = "unclear"
        let result = evidence.validate(try response(actions: [raw]), units: evidence.units,
            template: .meeting, meetingID: UUID(), maximumNotes: 12, maximumActions: 10)
        XCTAssertTrue(result.outcomes.actionItems[0].isForUser)
        XCTAssertEqual(result.outcomes.actionItems[0].attribution?.basis, .commitment)
        XCTAssertEqual(result.outcomes.actionItems[0].attribution?.speakerID, "me")
    }

    func testSeparateTaskAndAcceptanceKeepBothCitationsAndTheAcceptingSpeaker() throws {
        let transcript = Transcript(segments: [
            .init(start: 0, end: 5, speaker: "them", text: "Could you send the draft?"),
            .init(start: 5, end: 10, speaker: "me", text: "Yes, I can do that.", attribution: .init(source: .microphone, identity: .user, method: .confirmation)),
        ], engine: "fixture")
        let evidence = MeetingNotesEvidence(transcript: transcript)
        var raw = action("s2", owner: "source")
        raw["context"] = ["s1"]
        raw["text"] = "Send the draft"
        let result = evidence.validate(try response(actions: [raw]), units: evidence.units,
            template: .meeting, meetingID: UUID(), maximumNotes: 12, maximumActions: 10)
        XCTAssertTrue(result.outcomes.actionItems[0].isForUser)
        XCTAssertEqual(result.outcomes.actionItems[0].citations.count, 2)
        raw["context"] = [String]()
        let missing = evidence.validate(try response(actions: [raw]), units: evidence.units,
            template: .meeting, meetingID: UUID(), maximumNotes: 12, maximumActions: 10)
        XCTAssertTrue(missing.outcomes.actionItems.isEmpty)
        XCTAssertEqual(missing.rejected.first?.reason, "missing_task_context")
    }

    func testUnknownOwnershipStillRequiresAKnownPrimarySource() throws {
        let evidence = MeetingNotesEvidence(transcript: transcript)
        let result = evidence.validate(try response(actions: [action("s999", owner: "unknown")]),
            units: evidence.units, template: .meeting, meetingID: UUID(), maximumNotes: 12, maximumActions: 10)
        XCTAssertTrue(result.outcomes.actionItems.isEmpty)
        XCTAssertEqual(result.rejected.first?.reason, "unknown_source")
    }

    func testFreeformRetainsBoundedTopicHeadings() throws {
        let evidence = MeetingNotesEvidence(transcript: transcript)
        let result = evidence.validate(try response(notes: [note(section: "Release preparation")]),
            units: evidence.units, template: .freeform, meetingID: UUID(), maximumNotes: 12, maximumActions: 10)
        XCTAssertEqual(result.claims.first?.section, "Release preparation")
        XCTAssertTrue(result.rejected.isEmpty)
    }

    func testNoDecisionPlaceholderDoesNotBecomeACitedDecision() throws {
        let evidence = MeetingNotesEvidence(transcript: transcript)
        let result = evidence.validate(try response(notes: [note("s2", "None explicitly settled in this segment.", section: "Decisions")]),
            units: evidence.units, template: .meeting, meetingID: UUID(), maximumNotes: 12, maximumActions: 10)
        XCTAssertTrue(result.claims.isEmpty)
        XCTAssertTrue(result.outcomes.decisionRecords.isEmpty)
        XCTAssertEqual(result.rejected.first?.reason, "empty_outcome")
    }

    func testConversationManagementCannotBecomeAUserTask() throws {
        var transcript = transcript
        transcript.segments[0].text = "So, I'm going to be a little bit more specific."
        let evidence = MeetingNotesEvidence(transcript: transcript)
        var raw = action()
        raw["basis"] = "unclear"
        let result = evidence.validate(try response(actions: [raw]), units: evidence.units,
            template: .meeting, meetingID: UUID(), maximumNotes: 12, maximumActions: 10)
        XCTAssertTrue(result.outcomes.actionItems.isEmpty)
        XCTAssertEqual(result.rejected.first?.reason, "conversation_management")
        XCTAssertFalse(evidence.units[0].isUserCommitment)
    }

    func testStatusReportCannotBecomeAnUnassignedTask() throws {
        let evidence = MeetingNotesEvidence(transcript: transcript)
        var raw = action()
        raw["basis"] = "unclear"
        raw["text"] = "Reported a planning meeting with no updates."
        let result = evidence.validate(try response(actions: [raw]), units: evidence.units,
            template: .meeting, meetingID: UUID(), maximumNotes: 12, maximumActions: 10)
        XCTAssertTrue(result.outcomes.actionItems.isEmpty)
        XCTAssertEqual(result.rejected.first?.reason, "status_not_task")
    }

    func testAcceptanceCannotBeLinkedToADistantUnrelatedTask() throws {
        let transcript = longTranscript()
        let evidence = MeetingNotesEvidence(transcript: transcript)
        var raw = action("s20")
        raw["context"] = ["s1"]
        let result = evidence.validate(try response(actions: [raw]), units: evidence.units,
            template: .meeting, meetingID: UUID(), maximumNotes: 12, maximumActions: 10)
        XCTAssertTrue(result.outcomes.actionItems.isEmpty)
        XCTAssertEqual(result.rejected.first?.reason, "distant_action_context")
        XCTAssertEqual(result.rejected.first?.sources, ["s20"])
    }

    func testDistantTaskReferenceCannotContaminateTheAcceptanceRepair() async throws {
        var transcript = longTranscript()
        transcript.segments[0].text = "Could you review the older policy?"
        transcript.segments[18].text = "Could you stack the storage PR ahead of this one?"
        transcript.segments[20] = .init(start: 100, end: 105, speaker: "me", text: "Yeah, I can do that.", attribution: .init(source: .microphone, identity: .user, method: .confirmation))
        var rejected = action("s21", owner: "source")
        rejected["context"] = ["s1"]
        var repaired = action("s21", owner: "source")
        repaired["context"] = ["s19"]
        repaired["text"] = "Stack the storage PR ahead of the current PR."
        let script = Script([
            .text(try response(notes: [note("s1", "The older policy needs review.")], actions: [rejected])),
            .text(try response(actions: [repaired])),
        ])
        let result = try await generate(script, transcript: transcript)
        let calls = await script.recorded()
        XCTAssertEqual(calls.count, 2)
        XCTAssertFalse(calls[1].prompt.contains("s1|"))
        XCTAssertFalse(calls[1].prompt.contains("older policy"))
        XCTAssertTrue(calls[1].prompt.contains("s19|"))
        XCTAssertEqual(result.outcomes.userActionItems.first?.text, "Stack the storage PR ahead of the current PR.")
    }

    func testChunkingIncludesEverySourceAndTailUsingTokenizer() async throws {
        let transcript = longTranscript()
        let evidence = MeetingNotesEvidence(transcript: transcript)
        let engine = Engine(script: Script([]))
        let system = MeetingNotesGenerator.systemPrompt(template: .meeting, language: .matchTranscript)
        let chunks = try await MeetingNotesGenerator.makeChunks(evidence: evidence, engine: engine,
            system: system, context: [], contextTokens: 8_192)
        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertEqual(Set(chunks.flatMap { $0.map(\.source) }), Set(evidence.units.map(\.source)))
        XCTAssertEqual(chunks.last?.last?.source, evidence.units.last?.source)
        for chunk in chunks {
            let actual = try await MeetingNotesGenerator.tokenCount(system + "\n\n"
                + MeetingNotesGenerator.prompt(units: chunk, roster: evidence.roster), engine: engine)
            XCTAssertLessThanOrEqual(actual + 4_096 + 1_536, 8_192)
        }
    }

    func testCompletedPartsResumeAndTranscriptChangesInvalidateCheckpoint() async throws {
        let transcript = longTranscript()
        let output = try folder()
        let system = MeetingNotesGenerator.systemPrompt(template: .meeting, language: .matchTranscript)
        let chunks = try await MeetingNotesGenerator.makeChunks(evidence: MeetingNotesEvidence(transcript: transcript),
            engine: Engine(script: Script([])), system: system, context: [], contextTokens: 8_192)
        let first = Script([.text(try response(notes: [note()])), .error(.badResponse("offline"))])
        do { _ = try await generate(first, transcript: transcript, folder: output, contextTokens: 8_192); XCTFail("expected interruption") } catch {}
        let resumed = Script(try chunks.dropFirst().map { .text(try response(notes: [note($0.last!.source)])) })
        let result = try await generate(resumed, transcript: transcript, folder: output, contextTokens: 8_192)
        let observed6 = await resumed.recorded().count
        XCTAssertEqual(observed6, chunks.count - 1)
        XCTAssertEqual(result.claims.first?.segmentID, transcript.segmentID(at: 0))
        var changed = transcript
        changed.segments[0].text = "New evidence invalidates the saved parts."
        let fresh = Script([.error(.badResponse("new request"))])
        do { _ = try await generate(fresh, transcript: changed, folder: output, contextTokens: 8_192); XCTFail("expected new request") } catch {}
        let observed7 = await fresh.recorded().count
        XCTAssertEqual(observed7, 1)
    }

    func testCloudChunkingCoversLongMeetingWithoutTreatingBytesAsTargetTokens() async throws {
        let transcript = Transcript(segments: (0..<800).map { index in
            .init(start: Double(index * 3), end: Double(index * 3 + 3), speaker: "them",
                  text: "The project update \(index) covers the proposed release, documentation, and integration work for this week.")
        }, engine: "fixture")
        let evidence = MeetingNotesEvidence(transcript: transcript)
        let engine = Engine(script: Script([]), hasTokenizer: false)
        let system = MeetingNotesGenerator.systemPrompt(template: .meeting, language: .matchTranscript)
        let chunks = try await MeetingNotesGenerator.makeChunks(evidence: evidence, engine: engine,
            system: system, context: [], contextTokens: 32_768)
        XCTAssertLessThanOrEqual(chunks.count, 8, "leave useful room within the 12-request run allowance")
        XCTAssertEqual(Set(chunks.flatMap { $0.map(\.source) }), Set(evidence.units.map(\.source)))
        XCTAssertEqual(chunks.last?.last?.source, evidence.units.last?.source)
        for chunk in chunks {
            let bound = try await MeetingNotesGenerator.tokenCount(system + "\n\n"
                + MeetingNotesGenerator.prompt(units: chunk, roster: evidence.roster), engine: engine)
            XCTAssertLessThanOrEqual(bound + 4_096 + 1_536, 32_768)
        }
    }

    func testCloudChunkingKeepsHardByteBoundForMultilingualAndPunctuationInput() async throws {
        let transcript = Transcript(segments: (0..<120).map { index in
            .init(start: Double(index), end: Double(index + 1), speaker: "them",
                  text: String(repeating: "计划审查会议 Преглед документације !?123=", count: 8))
        }, engine: "fixture")
        let evidence = MeetingNotesEvidence(transcript: transcript)
        let engine = Engine(script: Script([]), hasTokenizer: false)
        let chunks = try await MeetingNotesGenerator.makeChunks(evidence: evidence, engine: engine,
            system: "Summarize the evidence.", context: [], contextTokens: 8_192)
        XCTAssertEqual(Set(chunks.flatMap { $0.map(\.source) }), Set(evidence.units.map(\.source)))
        for chunk in chunks {
            let text = "Summarize the evidence.\n\n" + MeetingNotesGenerator.prompt(units: chunk, roster: evidence.roster)
            XCTAssertLessThanOrEqual(text.utf8.count + 4_096 + 1_536, 8_192)
        }
    }

    func testVeryLongMeetingAllocatesOutputForWorkThatCanFitThisRun() async throws {
        let budget = MeetingGenerationBudget()
        let first = try await budget.allowance(remainingParts: 38)
        XCTAssertGreaterThanOrEqual(first, 3_000, "unreachable parts must not starve the current extraction")
        let reservation = try await budget.reserve(input: 1_000, output: first)
        await budget.finish(reservation, metric: .init(outcome: "complete", wallSeconds: 1, outputTokens: 2_000))
        let second = try await budget.allowance(remainingParts: 37)
        XCTAssertGreaterThanOrEqual(second, 3_000)
    }

    func testKnownGLMContextPolicyDoesNotRaiseUnknownServerLimits() {
        var config = AppSettings()
        config.summarizerBackend = .openAICompatible
        config.openAIBaseURL = "https://openrouter.ai/api/v1"
        config.openAIModel = "z-ai/glm-5.3-flash"
        XCTAssertEqual(MeetingSummaryGenerator.contextTokenLimit(for: config), 32_768)
        config.openAIBaseURL = "http://localhost:1234/v1"
        XCTAssertEqual(MeetingSummaryGenerator.contextTokenLimit(for: config), 16_384)
        config.openAIBaseURL = "https://openrouter.ai/api/v1"
        config.openAIModel = "unknown/model"
        XCTAssertEqual(MeetingSummaryGenerator.contextTokenLimit(for: config), 16_384)
    }

    func testOverviewPrioritizesLaterCommitmentAndDecisionOverIntroductoryFacts() {
        let claims: [SummaryClaimEvidence.Claim] = (0..<8).map { index in
            .init(section: index == 6 ? "Decisions" : "Key points", text: "Fact \(index)",
                  speakerID: "them", segmentID: "segment-\(index)", quote: "source \(index)")
        }
        var outcomes = MeetingOutcomes()
        outcomes.actionItems = [.init(text: "Ship the update", owner: "Me", isForUser: true,
            citations: [.init(segmentID: "segment-7", start: 7, end: 8, speaker: "me", excerpt: "I will ship.")])]
        let overview = MeetingNotesGenerator.overviewClaims(claims, outcomes: outcomes)
        XCTAssertEqual(overview.map(\.segmentID), ["segment-7", "segment-6", "segment-0"])
        let withoutOutcomes = MeetingNotesGenerator.overviewClaims(Array(claims.prefix(6)), outcomes: MeetingOutcomes())
        XCTAssertEqual(withoutOutcomes.map(\.segmentID), ["segment-0", "segment-3", "segment-5"])
    }

    func testMetricsKeepSeparateAttemptsAndOnlyRefundKnownUnusedOutput() async throws {
        let folder = try folder()
        let first = MeetingGenerationBudget(limits: .init(outputTokens: 4_096))
        let reservation = try await first.reserve(input: 1_000, output: 4_096)
        await first.finish(reservation, metric: .init(outcome: "rejected", wallSeconds: 0.1, outputTokens: 0))
        let allowance = try await first.allowance(remainingParts: 1)
        XCTAssertEqual(allowance, 4_096)
        let unknown = try await first.reserve(input: 1_000, output: allowance)
        await first.finish(unknown, metric: .init(outcome: "failed", wallSeconds: 0.1))
        do { _ = try await first.allowance(remainingParts: 1); XCTFail("unknown usage must retain its reservation")
        } catch is MeetingGenerationBudget.Exhausted {} catch { XCTFail("unexpected error \(error)") }
        await first.saveMetrics(in: folder, outcome: "incomplete")
        let second = MeetingGenerationBudget()
        await second.recordPlan(model: "fixture", transcriptRevision: "revision", parts: 3)
        await second.saveMetrics(in: folder, outcome: "complete")
        let reports = try FileManager.default.contentsOfDirectory(
            at: folder.appendingPathComponent("notes-generation-runs"), includingPropertiesForKeys: nil)
        XCTAssertEqual(reports.count, 2)
        let latest = try XCTUnwrap(JSONSerialization.jsonObject(with:
            Data(contentsOf: folder.appendingPathComponent("notes-generation-metrics.json"))) as? [String: Any])
        XCTAssertEqual(latest["model"] as? String, "fixture")
        XCTAssertEqual(latest["plannedParts"] as? Int, 3)
        XCTAssertNotNil(latest["attemptID"])
    }

    func testDeadlineCancelsInFlightGenerationAndRecordsIncompleteOutcome() async throws {
        let script = Script([.wait])
        let output = try folder()
        let budget = MeetingGenerationBudget(limits: .init(seconds: 0.05))
        do { _ = try await generate(script, folder: output, budget: budget); XCTFail("expected deadline") } catch is MeetingGenerationBudget.Exhausted {} catch { XCTFail("unexpected error \(error)") }
        // A short deadline may run out during planning, before an HTTP request.
        let observed8 = await script.recorded().count
        XCTAssertLessThanOrEqual(observed8, 1)
        let metric = try String(contentsOf: output.appendingPathComponent("notes-generation-metrics.json"), encoding: .utf8)
        XCTAssertTrue(metric.contains("incomplete"))
        XCTAssertFalse(metric.contains("I will ship"))
    }

    func testDeadlineWaitsForCancelledWorkToRelease() async throws {
        let script = Script([.wait])
        let budget = MeetingGenerationBudget(limits: .init(seconds: 0.05))
        do {
            _ = try await budget.run { try await script.next(prompt: "", options: .init()) }
            XCTFail("expected deadline")
        } catch is MeetingGenerationBudget.Exhausted {} catch { XCTFail("unexpected error \(error)") }
        let observed9 = await script.cancelled
        XCTAssertTrue(observed9)
    }

    func testRequestBudgetIncludesRepairAndPreservesProgress() async throws {
        let script = Script([.text(try response(notes: [note(), note("s2", "invalid", section: "wrong")]))])
        let output = try folder()
        do {
            _ = try await generate(script, folder: output, budget: MeetingGenerationBudget(limits: .init(requests: 1)))
            XCTFail("repair must consume the shared request allowance")
        } catch is MeetingGenerationBudget.Exhausted {} catch { XCTFail("unexpected error \(error)") }
        let observed10 = await script.recorded().count
        XCTAssertEqual(observed10, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.appendingPathComponent("summary.claims.partial.json").path))
    }

    func testCompleteRecordParserHandlesEscapesAndDoesNotInventPartialObjects() throws {
        let record = ["text": "literal \" } { \\ value", "source": "s1"]
        let encoded = String(decoding: try JSONSerialization.data(withJSONObject: record), as: UTF8.self)
        let parsed = CompleteJSONRecords.parse("{\"notes\":[" + encoded + ",{\"text\":\"partial", keys: ["notes", "actions"])
        XCTAssertFalse(parsed.complete)
        XCTAssertEqual(parsed.arrays["notes"]?.count, 1)
        XCTAssertEqual(parsed.arrays["notes"]?.first?["text"] as? String, record["text"])
        XCTAssertTrue(CompleteJSONRecords.parse("prose {\"notes\":[{}", keys: ["notes"]).arrays.isEmpty)
    }

    func testMissingUsageIsUnavailableAndTruncationRetainsUsageAndTimings() throws {
        let payload = #"{"choices":[{"finish_reason":"length","message":{"content":"partial"}}],"usage":{"completion_tokens":512},"timings":{"prompt_ms":123,"predicted_ms":456}}"#
        let parsed = try OpenAICompatibleEngine.parseChatCompletion(Data(payload.utf8), allowTruncation: true)
        XCTAssertTrue(parsed.truncated)
        XCTAssertEqual(parsed.content, "partial")
        XCTAssertEqual(parsed.usage?.outputTokens, 512)
        XCTAssertNil(parsed.usage?.inputTokens)
        XCTAssertNil(parsed.usage?.cachedInputTokens)
        XCTAssertNil(parsed.usage?.reasoningOutputTokens)
        XCTAssertEqual(parsed.prefillSeconds, 0.123)
        XCTAssertEqual(parsed.generationSeconds, 0.456)
    }

    func testGenerationBudgetPresetLimits() {
        let standard = GenerationBudgetPreset.standard.limits
        let shipped = MeetingGenerationBudget.Limits()
        XCTAssertEqual(standard.seconds, shipped.seconds)
        XCTAssertEqual(standard.requests, shipped.requests)
        XCTAssertEqual(standard.inputTokens, shipped.inputTokens)
        XCTAssertEqual(standard.outputTokens, shipped.outputTokens)

        let ordered = GenerationBudgetPreset.allCases.map(\.limits)
        for (smaller, larger) in zip(ordered, ordered.dropFirst()) {
            XCTAssertLessThan(smaller.seconds, larger.seconds)
            XCTAssertLessThan(smaller.requests, larger.requests)
            XCTAssertLessThan(smaller.inputTokens, larger.inputTokens)
            XCTAssertLessThan(smaller.outputTokens, larger.outputTokens)
        }

        // run() races a Task.sleep deadline and allowance() converts
        // seconds * 35 to Int — even Unlimited must stay finite and Int-safe.
        let unlimited = GenerationBudgetPreset.unlimited.limits
        XCTAssertTrue(unlimited.seconds.isFinite)
        XCTAssertLessThan(unlimited.seconds * 35, Double(Int.max))
    }

    private func longTranscript() -> Transcript {
        Transcript(segments: (0..<60).map { index in
            .init(start: Double(index * 5), end: Double(index * 5 + 5), speaker: "them",
                  text: "I will finish task \(index). " + String(repeating: "The dependency needs review. ", count: 6))
        }, engine: "fixture")
    }
}
