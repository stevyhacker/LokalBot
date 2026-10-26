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
        var structuredOutputEnumLimit: Int?
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
                          minimumOutputTokens: Int = 512, engine: Engine? = nil,
                          budget: MeetingGenerationBudget = MeetingGenerationBudget()) async throws -> MeetingNotesGenerator.Result {
        try await MeetingNotesGenerator.generate(transcript: transcript ?? self.transcript,
            engine: engine ?? Engine(script: script, minimumStructuredOutputTokens: minimumOutputTokens),
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

    /// The built-in Qwen3.5 4B copied cited source IDs into `due`, and the
    /// notes rendered "due s268" (2026-10-01).
    func testSourceIDInDueIsNotADueDate() async throws {
        var leaked = action()
        leaked["due"] = "s268"
        let script = Script([.text(try response(notes: [note()], actions: [leaked]))])
        let result = try await generate(script)
        XCTAssertEqual(result.outcomes.userActionItems.count, 1)
        XCTAssertNil(result.outcomes.userActionItems[0].due)
        XCTAssertFalse(result.body.contains("s268"))

        XCTAssertEqual(MeetingNotesEvidence.spokenDue(" (s12) ", sourceIDs: []), "")
        XCTAssertEqual(MeetingNotesEvidence.spokenDue("s3", sourceIDs: ["s3"]), "")
        XCTAssertEqual(MeetingNotesEvidence.spokenDue("Saturday", sourceIDs: ["s3"]), "Saturday")
        XCTAssertEqual(MeetingNotesEvidence.spokenDue("sprint 12", sourceIDs: []), "sprint 12")
    }

    func testDueWithAYearNobodySaidIsDroppedButTheActionStays() async throws {
        var invented = action()
        invented["due"] = "2024-01-01"
        let script = Script([.text(try response(notes: [note()], actions: [invented]))])
        let result = try await generate(script)
        XCTAssertEqual(result.outcomes.userActionItems.count, 1)
        XCTAssertNil(result.outcomes.userActionItems[0].due)

        let said = "I will ship the update by March 2027, not on Friday."
        XCTAssertEqual(MeetingNotesEvidence.spokenDue("2024-01-01", sourceIDs: [], citedText: said), "")
        XCTAssertEqual(MeetingNotesEvidence.spokenDue("March 2027", sourceIDs: [], citedText: said), "March 2027")
        XCTAssertEqual(MeetingNotesEvidence.spokenDue("Friday", sourceIDs: [], citedText: said), "Friday")
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

    func testOwnershipRepairReplacesTheUnresolvedTaskAndPersistsTheNewAnchor() async throws {
        let obligation = "I think I still have to review the change."
        var transcript = transcript
        transcript.segments = [
            .init(start: 0, end: 5, speaker: "me", text: "I have been doing reviews."),
            .init(start: 5, end: 10, speaker: "me", text: obligation),
        ]
        // The first answer cites only the status row, which proves nothing.
        var original = action(owner: "unknown")
        original["text"] = "Review the remaining change"
        original["basis"] = "unclear"
        var repaired = original
        repaired["source"] = "s2"
        repaired["context"] = ["s1"]
        repaired["quote"] = obligation
        let script = Script([.text(try response(actions: [original])), .text(try response(actions: [repaired]))])
        let output = try folder()
        let result = try await generate(script, transcript: transcript, folder: output)
        let calls = await script.recorded()
        XCTAssertEqual(calls.count, 2)
        XCTAssertTrue(calls[1].prompt.contains("missing_ownership_evidence"))
        XCTAssertTrue(calls[1].prompt.contains("Review the remaining change"))
        XCTAssertFalse(calls[1].prompt.contains(#""reason":"missing_user_commitment""#))
        XCTAssertEqual(result.outcomes.actionItems.count, 1)
        let action = try XCTUnwrap(result.outcomes.userActionItems.first)
        XCTAssertEqual(action.attribution?.quote, obligation)
        XCTAssertEqual(action.citations.first?.segmentID, transcript.segmentID(at: 1))
        let saved = try JSONDecoder().decode(MeetingOutcomes.self,
            from: Data(contentsOf: output.appendingPathComponent("outcomes.partial.json")))
        XCTAssertEqual(saved.actionItems.count, 1)
        XCTAssertEqual(saved.actionItems[0].citations.first?.segmentID, transcript.segmentID(at: 1))
        XCTAssertTrue(saved.actionItems[0].isForUser)
        let evidence = MeetingNotesEvidence(transcript: transcript)
        let previous = evidence.validate(try response(actions: [original]), units: evidence.units, template: .meeting,
            meetingID: UUID(), maximumNotes: 12, maximumActions: 10).outcomes
        let oldAction = try XCTUnwrap(previous.actionItems.first)
        let edit = MeetingOutcomeState.ActionState(status: .done, ownerOverride: "Reviewed owner", dueOverride: "Monday",
            textCorrection: "Review the release change", userEdited: true)
        let state = MeetingOutcomeState(actions: [oldAction.id: edit])
        let reconciled = MeetingOutcomeStore.reconcileState(state, from: previous, to: result.outcomes)
        XCTAssertEqual(reconciled.actions[action.id], edit)
        XCTAssertNil(reconciled.unmatchedActions, "Changing owner and citation order must preserve manual edits")
    }

    func testMixedActorRepairCanUseTheActualOtherSpeakersCommitment() async throws {
        var transcript = transcript
        transcript.segments[0].text = "I'll prepare the policy, and you will send the measurements."
        transcript.segments[1].text = "I will send the measurements."
        var original = action(owner: "unknown")
        original["text"] = "Send the measurements"
        original["quote"] = "I'll prepare the policy"
        var repaired = original
        repaired["source"] = "s2"
        repaired["quote"] = transcript.segments[1].text
        // The user's own half of that sentence is a commitment no task
        // covers yet, so the model is asked for it once.
        var mine = action(owner: "source")
        mine["text"] = "Prepare the policy"
        mine["quote"] = "I'll prepare the policy"
        let script = Script([.text(try response(actions: [original])), .text(try response(actions: [repaired])),
                             .text(try response(actions: [mine]))])
        let result = try await generate(script, transcript: transcript)
        let calls = await script.recorded()
        XCTAssertEqual(calls.count, 3)
        XCTAssertTrue(calls[2].prompt.contains(#""reason":"missing_user_commitment""#))
        XCTAssertEqual(result.outcomes.userActionItems.map(\.text), ["Prepare the policy"])
        let sent = try XCTUnwrap(result.outcomes.actionItems.first { $0.text == "Send the measurements" })
        XCTAssertEqual(sent.attribution?.resolution, .other)
        XCTAssertEqual(sent.citations.first?.segmentID, transcript.segmentID(at: 1))
    }

    func testOwnershipRepairKeepsItsReplacementIdentityAcrossRepeatedExtractionPages() async throws {
        var transcript = transcript
        transcript.segments[0].text = "I have been doing reviews."
        transcript.segments[1] = .init(start: 5, end: 10, speaker: "me", text: "I still have to review the change.")
        // Cites the status row with words nobody said: unresolved until repaired.
        var original = action(owner: "unknown")
        original["text"] = "Review the change"
        original["basis"] = "unclear"
        original["quote"] = "I will look at it"
        var repeated = original
        repeated["context"] = ["s3"]
        var repaired = original
        repaired["source"] = "s2"
        repaired["context"] = ["s1"]
        repaired["quote"] = transcript.segments[1].text
        let script = Script([
            .text(try response(actions: [original], more: true)),
            .text(try response(actions: [repeated])),
            .text(try response(actions: [repaired])),
        ])
        let result = try await generate(script, transcript: transcript)
        XCTAssertEqual(result.outcomes.actionItems.count, 1)
        XCTAssertEqual(result.outcomes.userActionItems.first?.text, "Review the change")
        let calls = await script.recorded()
        XCTAssertEqual(calls.count, 3)
    }

    func testMissingCommitmentRepairsTheNearbyExistingTaskWithoutExtractingADuplicate() async throws {
        var transcript = longTranscript()
        transcript.segments[0].text = "By the end of the day."
        transcript.segments[2] = .init(start: 10, end: 15, speaker: "me", text: "I still have to review the change.",
            attribution: .init(source: .microphone, identity: .user, method: .confirmation))
        var original = action("s1", owner: "unknown")
        original["text"] = "Review the remaining change today"
        original["context"] = ["s20"]
        var unclear = original
        unclear["context"] = ["s2"]
        unclear["basis"] = "request"
        unclear["quote"] = transcript.segments[0].text
        var repaired = original
        repaired["source"] = "s3"
        repaired["context"] = ["s1"]
        repaired["quote"] = transcript.segments[2].text
        let script = Script([
            .text(try response(notes: [note("s1", "The deadline is the end of the day.")], actions: [original])),
            .text(try response(actions: [unclear])),
            .text(try response(actions: [repaired])),
        ])
        let result = try await generate(script, transcript: transcript)
        XCTAssertEqual(result.outcomes.actionItems.count, 1)
        XCTAssertEqual(result.outcomes.userActionItems.first?.text, "Review the remaining change today")
        let calls = await script.recorded()
        XCTAssertEqual(calls.count, 3)
        XCTAssertFalse(calls[1].prompt.contains(#""reason":"missing_user_commitment""#))
        XCTAssertTrue(calls[2].prompt.contains("missing_ownership_evidence"))
        XCTAssertFalse(calls[2].prompt.contains("Previously accepted records:"), "A repair must be allowed to repeat the task it replaces")
    }

    func testOwnershipRepairsBatchTasksButKeepEachOriginalNeighborhood() async throws {
        var transcript = longTranscript()
        // Two sentences that each hand the task to someone else, each
        // followed by the other speaker taking it on.
        transcript.segments[0].text = "I'll check the logs, and you will review the draft."
        transcript.segments[1] = .init(start: 5, end: 10, speaker: "them 2", text: "I need to review the draft.")
        transcript.segments[19].text = "I'll check the build, and you will send the measurements."
        transcript.segments[20] = .init(start: 100, end: 105, speaker: "them 2", text: "I must send the measurements.")
        var first = action("s1", owner: "source")
        first["text"] = "Review the draft"
        var second = action("s20", owner: "source")
        second["text"] = "Send the measurements"
        var fixedFirst = first
        fixedFirst["source"] = "s2"
        fixedFirst["quote"] = transcript.segments[1].text
        var fixedSecond = second
        fixedSecond["source"] = "s21"
        fixedSecond["quote"] = transcript.segments[20].text
        var outside = fixedFirst
        outside["source"] = "s21"
        outside["quote"] = transcript.segments[20].text
        let script = Script([
            .text(try response(actions: [first, second])),
            .text(try response(actions: [outside, fixedSecond])),
            .text(try response(actions: [fixedFirst])),
        ])
        let result = try await generate(script, transcript: transcript)
        XCTAssertEqual(result.outcomes.actionItems.count, 2)
        let reviewed = try XCTUnwrap(result.outcomes.actionItems.first { $0.text == "Review the draft" })
        XCTAssertEqual(reviewed.citations.first?.segmentID, transcript.segmentID(at: 1))
        XCTAssertEqual(reviewed.attribution?.speakerID, "them 2")
        let calls = await script.recorded()
        XCTAssertEqual(calls.count, 3)
        XCTAssertTrue(calls[1].prompt.contains("Review the draft"))
        XCTAssertTrue(calls[1].prompt.contains("Send the measurements"))
    }

    func testRepeatedOwnershipRepairCannotSubstituteAnotherTaskOrClaimOwnership() async throws {
        var transcript = transcript
        transcript.segments[0].text = "I'll prepare the policy, and you will send the measurements."
        transcript.segments[1].text = "I will prepare the policy."
        var original = action(owner: "unknown")
        original["text"] = "Send the measurements"
        original["quote"] = "I'll prepare the policy"
        var unrelated = action("s2", owner: "source")
        unrelated["text"] = "Prepare the policy"
        unrelated["quote"] = transcript.segments[1].text
        let script = Script([
            .text(try response(actions: [original])),
            .text(try response(actions: [unrelated])),
            .text(try response(actions: [original])),
        ])
        let result = try await generate(script, transcript: transcript)
        let calls = await script.recorded()
        XCTAssertEqual(calls.count, 3, "Only two targeted repairs are allowed per part")
        // Repeated ambiguous evidence leaves the task visible with an unclear
        // owner instead of failing the meeting on every retry.
        XCTAssertEqual(result.outcomes.actionItems.map(\.text), ["Send the measurements"])
        XCTAssertEqual(result.outcomes.actionItems[0].attribution?.rejectionReason, .ambiguousQuote)
        XCTAssertTrue(result.outcomes.actionItems[0].ownershipIsUnclear)
        XCTAssertTrue(result.outcomes.userActionItems.isEmpty)
    }

    /// A task between two other participants whose only evidence names both
    /// actors, so no quote can bind it to one undertaking.
    private func unbindableTask() -> (Transcript, [String: Any]) {
        var transcript = transcript
        transcript.segments[0] = .init(start: 0, end: 5, speaker: "them",
                                       text: "I'll prepare the policy, and you will send the measurements.")
        var task = action(owner: "unknown")
        task["text"] = "Send the measurements"
        task["quote"] = "I'll prepare the policy"
        return (transcript, task)
    }

    func testTruncatedOwnershipRepairStaysPartialUntilAResumeAnswersInFull() async throws {
        let (transcript, task) = unbindableTask()
        let output = try folder()
        let first = Script([.text(try response(actions: [task])), .text(try response(actions: [task])), .truncated("")])
        do {
            _ = try await generate(first, transcript: transcript, folder: output)
            XCTFail("A truncated final repair must remain partial")
        } catch is MeetingNotesGenerator.Incomplete {} catch { XCTFail("unexpected error \(error)") }
        let initialCalls = await first.recorded()
        XCTAssertEqual(initialCalls.count, 3)
        let resumed = Script([.text(try response(actions: [task])), .text(try response(actions: [task]))])
        let result = try await generate(resumed, transcript: transcript, folder: output)
        let calls = await resumed.recorded()
        XCTAssertEqual(calls.count, 2, "Summarize again repairs only the pending task")
        XCTAssertEqual(result.outcomes.actionItems.map(\.text), ["Send the measurements"])
        XCTAssertTrue(result.outcomes.actionItems[0].ownershipIsUnclear)
    }

    func testRecordsQueuedBehindAnUnbindableOwnerStillGetRepaired() async throws {
        let (transcript, task) = unbindableTask()
        let script = Script([
            .text(try response(notes: [note("s2", "Needs repair", section: "Wrong")], actions: [task])),
            .text(try response(actions: [task])),
            .text(try response(actions: [task])),
            .text(try response(notes: [note("s2", "Documentation needs review.")])),
        ])
        let result = try await generate(script, transcript: transcript)
        let calls = await script.recorded()
        XCTAssertEqual(calls.count, 4)
        XCTAssertTrue(calls[3].prompt.contains("s2|"))
        XCTAssertTrue(calls[3].prompt.contains(#""reason":"invalid_note""#))
        XCTAssertFalse(calls[3].prompt.contains(#""reason":"ambiguous_ownership_evidence""#))
        XCTAssertEqual(result.claims.count, 1)
        XCTAssertTrue(result.outcomes.actionItems[0].ownershipIsUnclear)
    }

    func testAMisquotedCommitmentIsStillTheUsersWithoutAnotherRequest() async throws {
        var transcript = transcript
        transcript.segments = [
            .init(start: 0, end: 5, speaker: "them", text: "Can someone look at the pull request?"),
            .init(start: 5, end: 10, speaker: "me", text: "I still have to review the change.",
                  attribution: .init(source: .microphone, identity: .user, method: .confirmation)),
        ]
        var task = action("s2", owner: "source")
        task["text"] = "Review the change"
        task["quote"] = "I will review it"
        let script = Script([.text(try response(actions: [task]))])
        let result = try await generate(script, transcript: transcript)
        let calls = await script.recorded()
        XCTAssertEqual(calls.count, 1, "The cited row says it; the model's wording of it is not evidence")
        let item = try XCTUnwrap(result.outcomes.userActionItems.first)
        XCTAssertEqual(item.attribution?.quote, "I still have to review the change.")
    }

    func testUnprovableOwnershipStaysVisibleAsLikelyTheUsersAndCompletes() async throws {
        var transcript = transcript
        transcript.segments = [
            .init(start: 0, end: 5, speaker: "them", text: "Can someone look at the pull request?"),
            .init(start: 5, end: 10, speaker: "me", text: "We should review the change before Friday.",
                  attribution: .init(source: .microphone, identity: .user, method: .confirmation)),
        ]
        var task = action("s2", owner: "source")
        task["text"] = "Review the change"
        task["quote"] = "I will review it"
        let script = Script([
            .text(try response(actions: [task])), .text(try response(actions: [task])), .text(try response(actions: [task])),
        ])
        let result = try await generate(script, transcript: transcript)
        let calls = await script.recorded()
        XCTAssertEqual(calls.count, 3, "Two targeted repairs, then the task keeps its unclear owner")
        XCTAssertTrue(calls[1].prompt.contains("ownership_quote_not_found"))
        let item = try XCTUnwrap(result.outcomes.actionItems.first)
        XCTAssertTrue(item.ownershipIsUnclear)
        XCTAssertTrue(item.isLikelyUserAction, "Spoken on this Mac's microphone, so likely the user's")
    }

    func testRecordsQueuedBehindASuccessfulOwnershipRepairStillGetRepaired() async throws {
        let obligation = "I think I still have to review the change."
        var transcript = transcript
        transcript.segments = [
            .init(start: 0, end: 5, speaker: "me", text: "I have been doing reviews."),
            .init(start: 5, end: 10, speaker: "me", text: obligation),
            .init(start: 10, end: 15, speaker: "them", text: "The documentation needs another review."),
        ]
        var original = action(owner: "unknown")
        original["text"] = "Review the remaining change"
        original["basis"] = "unclear"
        original["quote"] = "I will look at it"
        var repaired = original
        repaired["source"] = "s2"
        repaired["context"] = ["s1"]
        repaired["quote"] = obligation
        let script = Script([
            .text(try response(notes: [note("s3", "Needs repair", section: "Wrong")], actions: [original])),
            .text(try response(actions: [original])),
            .text(try response(actions: [repaired])),
            .text(try response(notes: [note("s3", "The documentation needs another review.")])),
        ])
        let result = try await generate(script, transcript: transcript)
        let calls = await script.recorded()
        XCTAssertEqual(calls.count, 4, "Two ownership repairs, then the queued note gets its own")
        XCTAssertTrue(calls[3].prompt.contains(#""reason":"invalid_note""#))
        XCTAssertEqual(result.claims.count, 1)
        XCTAssertEqual(result.outcomes.userActionItems.first?.attribution?.quote, obligation)
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
        let script = Script([
            .truncated("{\"notes\":[" + complete + ",{\"text\":\"unfinished"),
            .truncated(""),
            .truncated(""),
            .truncated(""),
        ])
        let output = try folder()
        do { _ = try await generate(script, folder: output); XCTFail("truncated scan must remain partial") } catch is MeetingNotesGenerator.Incomplete {} catch { XCTFail("unexpected error \(error)") }
        let artifact = try JSONDecoder().decode(SummaryClaimEvidence.Artifact.self,
            from: Data(contentsOf: output.appendingPathComponent("summary.claims.partial.json")))
        XCTAssertEqual(artifact.claims.count, 1)
        let observed3 = await script.recorded().count
        XCTAssertEqual(observed3, 4, "the initial and continuation pages each get one bounded expansion retry")
    }

    func testTruncatedStructuredResponseGetsOneExpandedRetry() async throws {
        let script = Script([
            .truncated(""),
            .text(try response(notes: [note()], actions: [action()])),
        ])

        let result = try await generate(script)
        let calls = await script.recorded()

        XCTAssertEqual(calls.map { $0.options.maxTokens }, [4_096, 8_192])
        XCTAssertEqual(result.claims.count, 1)
        XCTAssertTrue(result.body.contains("Will ship the update on Friday."))
    }

    func testExpandedRetryUsesContextHeadroomAndKeepsFirstPartialOnFailure() async throws {
        let partial = #"{"notes":[{"section":"Key points","text":"Usable partial","source":"s1"}]}"#
        let script = Script([.truncated(partial), .error(.badResponse("provider rejected expanded context"))])
        let system = "Summarize."
        let prompt = "Evidence."
        let context = ["Prior context."]
        let joined = ([system] + context + [prompt]).joined(separator: "\n\n")
        let input = max(1, joined.utf8.count / 4) + 1_536
        let result = try await MeetingNotesGenerator.request(
            engine: Engine(script: script), system: system, prompt: prompt, context: context,
            schema: [:], tokens: 4_096, stage: "extract-1", contextTokens: input + 5_000,
            budget: MeetingGenerationBudget())

        XCTAssertEqual(result.content, partial)
        XCTAssertTrue(result.truncated)
        let calls = await script.recorded()
        XCTAssertEqual(calls.map { $0.options.maxTokens }, [4_096, 5_000])
        XCTAssertNil(MeetingNotesGenerator.expandedStructuredOutputTokens(
            from: 4_096, input: input, contextTokens: input + 4_096))
    }

    func testExpandedTruncatedRetryKeepsPrefixWithMoreCompleteRecords() async throws {
        let first = try response(notes: [
            note("s1", "First recoverable note."),
            note("s2", "Second recoverable note."),
        ]) + #"{"unfinished":"record"#
        let expanded = try response(notes: [
            note("s1", "Only one recoverable note."),
        ]) + #"{"unfinished":"record"#
        let script = Script([.truncated(first), .truncated(expanded)])

        let result = try await MeetingNotesGenerator.request(
            engine: Engine(script: script), system: "Summarize.", prompt: "Evidence.",
            context: [], schema: [:], tokens: 4_096, stage: "extract-1",
            contextTokens: 16_384, budget: MeetingGenerationBudget())

        XCTAssertEqual(result.content, first)
        XCTAssertTrue(result.truncated)
        let calls = await script.recorded()
        XCTAssertEqual(calls.map { $0.options.maxTokens }, [4_096, 8_192])
    }

    func testMalformedProviderShapeGetsOneBoundedRecoveryRetry() async throws {
        // A provider can return a successful JSON response with an optional
        // action that has no source (or even omit the notes array). That shape
        // must trigger one focused re-read, not fail the whole meeting.
        let script = Script([
            .text(#"{"actions":[{"text":"Use the plan"}],"has_more":false}"#),
            .text(try response(notes: [note()], actions: [action()])),
        ])

        let result = try await generate(script)
        let calls = await script.recorded()

        XCTAssertEqual(calls.count, 2)
        XCTAssertTrue(calls[1].prompt.contains("did not pass all source-link checks"))
        XCTAssertEqual(result.claims.count, 1)
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

    func testFillerTheRepairFindsNoTaskInDoesNotLeaveNotesPartial() async throws {
        var transcript = longTranscript()
        transcript.segments[20] = .init(start: 100, end: 105, speaker: "me", text: "I'll just flag that the dependency worries me.",
                                        attribution: .init(source: .microphone, identity: .user, method: .confirmation))
        XCTAssertEqual(MeetingNotesEvidence(transcript: transcript).units.filter(\.isUserCommitment).map(\.source), ["s21"])
        let script = Script([
            .text(try response(notes: [note("s1", "The dependency needs review.")])),
            // Asked again at temperature 0, the model gives the same answer.
            .text(try response()), .text(try response()),
        ])

        let result = try await generate(script, transcript: transcript)

        let calls = await script.recorded()
        XCTAssertEqual(calls.count, 2, "a complete answer without a task is final")
        XCTAssertTrue(calls[1].prompt.contains("missing_user_commitment"))
        XCTAssertTrue(result.outcomes.userActionItems.isEmpty)
        XCTAssertEqual(result.claims.count, 1)
    }

    func testACommitmentBesideSeveralOwnerUnclearTasksDoesNotLeaveNotesPartial() async throws {
        var transcript = longTranscript()
        transcript.segments[19] = .init(start: 95, end: 100, speaker: "them", text: "Someone should review the dependency.")
        transcript.segments[20] = .init(start: 100, end: 105, speaker: "me", text: "I will take care of it.",
                                        attribution: .init(source: .microphone, identity: .user, method: .confirmation))
        transcript.segments[21] = .init(start: 105, end: 110, speaker: "them", text: "The migration plan should be updated.")
        var reviewTask = action("s20", owner: "unknown")
        reviewTask["text"] = "Review the dependency"
        reviewTask["basis"] = "unclear"
        var migrationTask = action("s22", owner: "unknown")
        migrationTask["text"] = "Update the migration plan"
        migrationTask["basis"] = "unclear"
        let script = Script([
            .text(try response(notes: [note("s1", "The dependency needs review.")], actions: [reviewTask, migrationTask])),
        ])

        let result = try await generate(script, transcript: transcript)

        let calls = await script.recorded()
        XCTAssertEqual(calls.count, 1, "proximity cannot choose between two tasks, so no repair is asked")
        XCTAssertEqual(result.outcomes.unresolvedActionItems.count, 2)
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

    /// Escaped bug: without a provider tokenizer, parts are packed to a byte
    /// ceiling beside a full output reservation. The continuation ledger then
    /// pushed the page over that reservation, and every retry failed before
    /// sending a request.
    func testContinuationOfAPartPackedToTheContextLimitShrinksItsOutput() async throws {
        let (script, chunks, system, _) = try await packedContinuationScript(noteLength: 120, notes: 10)
        let result = try await generate(script, transcript: longTranscript(segments: 120), contextTokens: 16_384,
                                        engine: Engine(script: script, hasTokenizer: false))
        let calls = await script.recorded()
        XCTAssertEqual(calls.count, chunks.count + 1)
        let page = calls[1].prompt
        XCTAssertTrue(page.contains("Previously accepted records:"))
        XCTAssertFalse(page.contains("omitted for space"), "the whole ledger fits once the output shrinks")
        let input = (system + "\n\n" + page).utf8.count + 1_536
        XCTAssertGreaterThan(input + 4_096, 16_384, "the page must not fit beside the full planned output reservation")
        let output = try XCTUnwrap(calls[1].options.maxTokens)
        XCTAssertLessThan(output, try XCTUnwrap(calls[0].options.maxTokens))
        XCTAssertGreaterThanOrEqual(output, 512)
        XCTAssertLessThanOrEqual(input + output, 16_384)
        XCTAssertEqual(result.claims.count, 10 + chunks.count - 1)
    }

    func testOverlongContinuationLedgerKeepsItsNewestRecords() async throws {
        let (script, chunks, system, texts) = try await packedContinuationScript(noteLength: 260, notes: 12)
        _ = try await generate(script, transcript: longTranscript(segments: 120), contextTokens: 16_384,
                               engine: Engine(script: script, hasTokenizer: false, minimumStructuredOutputTokens: 2_048))
        let calls = await script.recorded()
        XCTAssertEqual(calls.count, chunks.count + 1)
        let page = calls[1].prompt
        XCTAssertTrue(page.contains("omitted for space"))
        XCTAssertTrue(page.contains(try XCTUnwrap(texts.last)))
        XCTAssertFalse(page.contains(try XCTUnwrap(texts.first)))
        let output = try XCTUnwrap(calls[1].options.maxTokens)
        XCTAssertGreaterThanOrEqual(output, 2_048)
        let input = (system + "\n\n" + page).utf8.count + 1_536
        XCTAssertLessThanOrEqual(input + output, 16_384)
    }

    /// First part pages once with `notes` long records; every other part
    /// answers in one page. Chunks use the byte bound of a tokenizer-less
    /// provider at a 16K context, as an unknown OpenRouter model does.
    private func packedContinuationScript(noteLength: Int, notes count: Int) async throws
        -> (Script, [[MeetingNotesEvidence.Unit]], String, [String]) {
        let evidence = MeetingNotesEvidence(transcript: longTranscript(segments: 120))
        let system = MeetingNotesGenerator.systemPrompt(template: .meeting, language: .matchTranscript)
        let chunks = try await MeetingNotesGenerator.makeChunks(evidence: evidence,
            engine: Engine(script: Script([]), hasTokenizer: false), system: system, context: [], contextTokens: 16_384)
        XCTAssertGreaterThan(chunks.count, 1)
        let first = chunks[0]
        let filler = String(repeating: "release planning detail ", count: 20)
        var texts: [String] = []
        var notes: [[String: Any]] = []
        for index in 0..<count {
            let text = String("Accepted fact \(index): \(filler)".prefix(noteLength))
            texts.append(text)
            notes.append(note(first[index % first.count].source, text))
        }
        var replies: [Script.Reply] = [.text(try response(notes: notes, more: true)), .text(try response())]
        for (index, chunk) in chunks.dropFirst().enumerated() {
            let source = try XCTUnwrap(chunk.last).source
            replies.append(.text(try response(notes: [note(source, "Tail fact \(index).")])))
        }
        return (Script(replies), chunks, system, texts)
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

    func testLongMeetingTakeawaysInterleaveSoTheFirstBulletsSpanEveryPart() {
        func claim(_ section: String, _ text: String) -> SummaryClaimEvidence.Claim {
            SummaryClaimEvidence.Claim(section: section, text: text, speakerID: "p1", segmentID: text, quote: text)
        }
        let parts = [
            [claim("TL;DR", "opening 1"), claim("Key points", "early detail"), claim("TL;DR", "opening 2")],
            [claim("TL;DR", "middle 1"), claim("Decisions", "middle decision")],
            [claim("TL;DR", "closing 1"), claim("TL;DR", "closing 2"), claim("TL;DR", "closing 3")],
        ]
        let ordered = MeetingNotesGenerator.interleavingTLDR(parts)
        XCTAssertEqual(ordered.filter { $0.section == "TL;DR" }.map(\.text),
                       ["opening 1", "middle 1", "closing 1", "opening 2", "closing 2", "closing 3"])
        XCTAssertEqual(ordered.filter { $0.section != "TL;DR" }.map(\.text), ["early detail", "middle decision"])
        XCTAssertEqual(ordered.count, 8, "no takeaway or note is dropped")
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

    func testTheCitedVoiceOutranksAWrongOwnerAndANegationIsNotATask() throws {
        // The model named the other participant for words the user said.
        let evidence = MeetingNotesEvidence(transcript: transcript)
        let wrongOwner = evidence.validate(try response(actions: [action(owner: "p2")]),
            units: evidence.units, template: .meeting, meetingID: UUID(), maximumNotes: 12, maximumActions: 10)
        XCTAssertTrue(wrongOwner.outcomes.actionItems[0].isForUser)
        XCTAssertEqual(wrongOwner.outcomes.actionItems[0].attribution?.speakerID, "me")
        var unrelated = action(owner: "p2")
        unrelated["text"] = "Book the venue"
        let conflict = evidence.validate(try response(actions: [unrelated]),
            units: evidence.units, template: .meeting, meetingID: UUID(), maximumNotes: 12, maximumActions: 10)
        XCTAssertTrue(conflict.outcomes.actionItems[0].ownershipIsUnclear, "A named owner stands unless the task is the speaker's own")

        var negatedTranscript = transcript
        negatedTranscript.segments[0].text = "I will not ship the update on Friday."
        let negated = MeetingNotesEvidence(transcript: negatedTranscript)
        let result = negated.validate(try response(actions: [action()]), units: negated.units,
            template: .meeting, meetingID: UUID(), maximumNotes: 12, maximumActions: 10)
        XCTAssertTrue(result.outcomes.actionItems.isEmpty)
        XCTAssertEqual(result.rejected.first?.reason, "unsupported_commitment")

        var conditionalTranscript = transcript
        conditionalTranscript.segments[0].text = "If approved, I will ship the update on Friday."
        let conditional = MeetingNotesEvidence(transcript: conditionalTranscript)
        let kept = conditional.validate(try response(actions: [action()]), units: conditional.units,
            template: .meeting, meetingID: UUID(), maximumNotes: 12, maximumActions: 10)
        XCTAssertTrue(kept.outcomes.actionItems[0].isForUser, "A condition does not change whose task it is")
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
        let actions = try XCTUnwrap(properties["actions"] as? [String: Any])
        let item = try XCTUnwrap(actions["items"] as? [String: Any])
        let actionProperties = try XCTUnwrap(item["properties"] as? [String: Any])
        XCTAssertEqual((actionProperties["quote"] as? [String: Any])?["maxLength"] as? Int, 1_000)
        XCTAssertTrue((item["required"] as? [String] ?? []).contains("quote"))
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

    func testOldOwnershipPolicyCheckpointIsNotReused() async throws {
        let output = try folder()
        _ = try await generate(Script([.text(try response(actions: [action()]))]), folder: output)
        let url = MeetingNotesGenerator.checkpointURL(in: output)
        var checkpoint = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(checkpoint["version"] as? Int, 2)
        checkpoint["version"] = 1
        try JSONSerialization.data(withJSONObject: checkpoint).write(to: url)
        let fresh = Script([.text(try response(actions: [action()]))])
        _ = try await generate(fresh, folder: output)
        let calls = await fresh.recorded()
        XCTAssertEqual(calls.count, 1, "Accepted ownership under the old policy must be extracted again")
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

    func testVerifiedOpenRouterContextPolicyDoesNotRaiseUnknownServerLimits() {
        var config = openRouterConfig("z-ai/glm-5.3-flash")
        XCTAssertEqual(MeetingSummaryGenerator.contextTokenLimit(for: config), 262_144)
        config.openAIModel = "z-ai/glm-5.3"
        XCTAssertEqual(MeetingSummaryGenerator.contextTokenLimit(for: config), 262_144)
        config.openAIModel = "qwen/qwen3.8-flash"
        XCTAssertEqual(MeetingSummaryGenerator.contextTokenLimit(for: config), 1_000_000)
        config.openAIModel = "qwen/qwen3.8-flash:free"
        XCTAssertEqual(MeetingSummaryGenerator.contextTokenLimit(for: config), 16_384,
                       "a variant routes to other endpoints than the verified id")
        config.openAIModel = "unknown/model"
        XCTAssertEqual(MeetingSummaryGenerator.contextTokenLimit(for: config), 16_384)
        config.openAIModel = "qwen/qwen3.8-flash"
        config.openAIBaseURL = "http://localhost:1234/v1"
        XCTAssertEqual(MeetingSummaryGenerator.contextTokenLimit(for: config), 16_384)
        config = openRouterConfig("qwen/qwen3.8-flash")
        config.summarizerBackend = .ollama
        XCTAssertEqual(MeetingSummaryGenerator.contextTokenLimit(for: config), 16_384)

        config = openRouterConfig("qwen-3.8-27b")
        config.openAIBaseURL = "https://api.cerebras.ai/v1"
        XCTAssertEqual(MeetingSummaryGenerator.contextTokenLimit(for: config), 64_000)
        config.openAIModel = "some-new-model"
        XCTAssertEqual(MeetingSummaryGenerator.contextTokenLimit(for: config), 16_384)
        config.openAIModel = "qwen-3.8-27b"
        config.openAIBaseURL = "http://localhost:1234/v1"
        XCTAssertEqual(MeetingSummaryGenerator.contextTokenLimit(for: config), 16_384,
                       "the model name alone does not prove another server's window")

        config.openAIBaseURL = "https://api.openai.com/v1"
        for (model, window) in [("gpt-5.4-mini", 128_000), ("gpt-4.1-mini", 1_000_000), ("gpt-4o", 128_000),
                                ("o4-mini", 128_000), ("gpt-6.1-sol", 922_000), ("gpt-3.5-turbo", 16_384)] {
            config.openAIModel = model
            XCTAssertEqual(MeetingSummaryGenerator.contextTokenLimit(for: config), window, model)
        }
        config.openAIModel = "gpt-5.4-mini"
        config.openAIBaseURL = "https://gateway.example.com/v1"
        XCTAssertEqual(MeetingSummaryGenerator.contextTokenLimit(for: config), 16_384)
    }

    func testVerifiedWindowHalvesAThirtyMinuteMeetingsPartsAndKeepsTheByteBound() async throws {
        let transcript = thirtyMinuteTranscript()
        let evidence = MeetingNotesEvidence(transcript: transcript)
        let engine = Engine(script: Script([]), hasTokenizer: false)
        let system = MeetingNotesGenerator.systemPrompt(template: .meeting, language: .matchTranscript)
        let window = MeetingSummaryGenerator.contextTokenLimit(for: openRouterConfig("qwen/qwen3.8-flash"))
        let conservative = try await MeetingNotesGenerator.makeChunks(evidence: evidence, engine: engine,
            system: system, context: [], contextTokens: 16_384)
        let verified = try await MeetingNotesGenerator.makeChunks(evidence: evidence, engine: engine,
            system: system, context: [], contextTokens: window)
        // Each part carries about twice the evidence; the tail part may be short.
        XCTAssertLessThanOrEqual(verified.count, conservative.count / 2 + 1,
                                 "planned \(verified.count) parts against \(conservative.count) at 16K")
        XCTAssertEqual(Set(verified.flatMap { $0.map(\.source) }), Set(evidence.units.map(\.source)))
        XCTAssertEqual(verified.last?.last?.source, evidence.units.last?.source)
        for chunk in verified {
            let bytes = (system + "\n\n" + MeetingNotesGenerator.prompt(units: chunk, roster: evidence.roster)).utf8.count
            // Even at one token per byte a part stays inside its window with
            // the full output and envelope headroom.
            XCTAssertLessThanOrEqual(bytes + 4_096 + 1_536, window)
        }
    }

    /// Parts follow the model's window in steps: windows within a step plan
    /// identical parts, so a window that drifts between lookups keeps a
    /// meeting's saved parts, and each larger step plans fewer, larger parts.
    func testWindowsInOneStepPlanTheSamePartsAndLargerStepsPlanFewer() async throws {
        let multilingual = Transcript(segments: (0..<240).map { index in
            .init(start: Double(index), end: Double(index + 1), speaker: index.isMultiple(of: 3) ? "me" : "them",
                  text: String(repeating: "计划审查会议 Преглед документације !?123=", count: 8))
        }, engine: "fixture")
        let engine = Engine(script: Script([]), hasTokenizer: false)
        let system = MeetingNotesGenerator.systemPrompt(template: .meeting, language: .matchTranscript)
        let steps = [[32_768, 48_000, 63_999], [64_000, 100_000], [128_000, 262_144, 1_000_000]]
        for transcript in [thirtyMinuteTranscript(), multilingual] {
            let evidence = MeetingNotesEvidence(transcript: transcript)
            var counts: [Int] = []
            for windows in steps {
                var plans: [[[String]]] = []
                for window in windows {
                    let chunks = try await MeetingNotesGenerator.makeChunks(evidence: evidence, engine: engine,
                        system: system, context: [], contextTokens: window)
                    plans.append(chunks.map { $0.map(\.source) })
                    XCTAssertEqual(Set(chunks.flatMap { $0.map(\.source) }), Set(evidence.units.map(\.source)))
                    for chunk in chunks {
                        let text = system + "\n\n" + MeetingNotesGenerator.prompt(units: chunk, roster: evidence.roster)
                        XCTAssertLessThanOrEqual(text.utf8.count + 4_096 + 1_536, windows[0])
                    }
                }
                XCTAssertTrue(plans.allSatisfy { $0 == plans[0] }, "windows \(windows) must plan the same parts")
                counts.append(plans[0].count)
            }
            XCTAssertGreaterThan(counts[0], 1)
            XCTAssertLessThan(counts[1], counts[0])
            XCTAssertLessThanOrEqual(counts[2], counts[1])
        }
    }

    /// On 2026-10-07 a 21-minute standup on Cerebras Qwen (64K window) was
    /// planned as four standard parts. A larger part now gets the output and
    /// record caps of the standard parts it covers.
    func testALargerPartGetsTheOutputAndRecordsOfTheStandardPartsItCovers() async throws {
        let transcript = longTranscript(segments: 200)
        let evidence = MeetingNotesEvidence(transcript: transcript)
        let notes = evidence.units.prefix(20).enumerated().map { index, unit in
            note(unit.source, "Task \(index) waits on the dependency review.")
        }
        let script = Script([.text(try response(notes: notes))])
        let result = try await generate(script, transcript: transcript, contextTokens: 128_000,
                                        engine: Engine(script: script, hasTokenizer: false))
        let calls = await script.recorded()
        XCTAssertEqual(calls.count, 1, "the whole meeting fits one part")
        XCTAssertGreaterThan(try XCTUnwrap(calls.first?.options.maxTokens), 4_096)
        XCTAssertEqual(result.claims.count, 20, "more than one standard part's 12 notes")
    }

    /// On 2026-10-07 reasoning used every output token of a standup's first
    /// part. The next runs asked the model to continue from an empty list of
    /// accepted records, got empty answers, and stopped the part for good.
    func testAPartCutOffBeforeAnyRecordIsScannedAgainNotContinued() async throws {
        let output = try folder()
        let transcript = longTranscript(segments: 3)
        let cutOff = Script([.truncated(""), .truncated("")])
        do {
            _ = try await generate(cutOff, transcript: transcript, folder: output)
            XCTFail("expected incomplete notes")
        } catch {}
        let cutOffCalls = await cutOff.recorded()
        XCTAssertEqual(cutOffCalls.count, 2, "the cut-off page and its expanded retry")

        let script = Script([.text(try response(notes: [note("s1", "Task 0 will be finished.")]))])
        let result = try await generate(script, transcript: transcript, folder: output)
        let calls = await script.recorded()
        XCTAssertEqual(calls.count, 1)
        XCTAssertFalse(try XCTUnwrap(calls.first?.prompt).contains("Continue only the unfinished work"))
        XCTAssertEqual(result.claims.count, 1)
    }

    /// Automatic runs keep a stopped part stopped; asking again scans it.
    func testSummarizeAgainRetriesAPartAnEarlierRunStopped() async throws {
        let output = try folder()
        let transcript = longTranscript(segments: 3)
        func run(_ script: Script, requested: Bool = false) async throws -> MeetingNotesGenerator.Result {
            try await MeetingNotesGenerator.generate(transcript: transcript, engine: Engine(script: script),
                template: .meeting, language: .matchTranscript, context: [], contextTokens: 32_768,
                meetingID: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!, folder: output,
                retryingStoppedParts: requested)
        }
        for _ in 0..<2 {
            do { _ = try await run(Script([.text(try response(more: true))])); XCTFail("expected no progress") } catch {}
        }
        let automatic = Script([])
        do {
            _ = try await run(automatic)
            XCTFail("an automatic run keeps the stop")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("no further source-linked progress"))
        }
        let automaticCalls = await automatic.recorded()
        XCTAssertTrue(automaticCalls.isEmpty)

        let requested = Script([.text(try response(notes: [note("s1", "Task 0 will be finished.")]))])
        let result = try await run(requested, requested: true)
        let calls = await requested.recorded()
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(result.claims.count, 1)
    }

    func testLargerPartsKeepTheBudgetOfTheStandardPartsTheyCover() async throws {
        let larger = MeetingGenerationBudget(limits: .init(scalesWithParts: true))
        await larger.recordPlan(model: "fixture", transcriptRevision: "revision", parts: 1, standardParts: 8)
        let plain = MeetingGenerationBudget(limits: .init(scalesWithParts: true))
        await plain.recordPlan(model: "fixture", transcriptRevision: "revision", parts: 1)
        let largerAllowance = try await larger.allowance(remainingParts: 1, desired: 40_000)
        let plainAllowance = try await plain.allowance(remainingParts: 1, desired: 40_000)
        XCTAssertGreaterThan(largerAllowance, plainAllowance)
    }

    /// Each popular model resolves its provider's window without a network
    /// lookup, and a 20-minute meeting with calendar context (like the
    /// 2026-10-07 standup, planned as four parts) becomes one or two requests
    /// whose schemas fit the provider.
    func testPopularModelsPlanAMeetingFromTheirProvidersWindow() async throws {
        func config(_ baseURL: String, _ model: String) -> AppSettings {
            var config = openRouterConfig(model)
            config.openAIBaseURL = baseURL
            return config
        }
        let models: [(AppSettings, Int)] = [
            (config("https://api.cerebras.ai/v1", "qwen-3.8-27b"), 64_000),
            (config("https://api.openai.com/v1", "gpt-5.6-luna"), 128_000),
            (openRouterConfig("openai/gpt-5.6-luna"), 922_000),
            (openRouterConfig("openai/gpt-5.4-mini"), 128_000),
            (openRouterConfig("z-ai/glm-5.3-flash"), 262_144),
            (openRouterConfig("qwen/qwen3.8-27b"), 65_536),
        ]
        let transcript = Transcript(segments: Array(thirtyMinuteTranscript().segments.prefix(200)), engine: "fixture")
        let evidence = MeetingNotesEvidence(transcript: transcript)
        let system = MeetingNotesGenerator.systemPrompt(template: .meeting, language: .matchTranscript)
        let context = [String(repeating: "Invited: a teammate from the product group. ", count: 100)]
        let unknown = try await MeetingNotesGenerator.makeChunks(evidence: evidence,
            engine: Engine(script: Script([]), hasTokenizer: false, structuredOutputEnumLimit: 500),
            system: system, context: context, contextTokens: 16_384)
        XCTAssertGreaterThan(unknown.count, 2)
        for (config, window) in models {
            XCTAssertEqual(MeetingSummaryGenerator.contextTokenLimit(for: config), window, config.openAIModel)
            let limit = OpenAICompatibleEngine(baseURL: URL(string: config.openAIBaseURL)!, model: config.openAIModel,
                chatDialect: .inferred(from: URL(string: config.openAIBaseURL)!)).structuredOutputEnumLimit
            let chunks = try await MeetingNotesGenerator.makeChunks(evidence: evidence,
                engine: Engine(script: Script([]), hasTokenizer: false, structuredOutputEnumLimit: limit),
                system: system, context: context, contextTokens: window)
            XCTAssertLessThanOrEqual(chunks.count, 2, config.openAIModel)
            for chunk in chunks {
                let schema = MeetingNotesEvidence.schema(units: chunk, speakers: Array(evidence.speakers.keys),
                                                         template: .meeting, maximumNotes: 1, maximumActions: 1)
                XCTAssertLessThanOrEqual(MeetingNotesEvidence.enumValueCount(in: schema), try XCTUnwrap(limit))
            }
        }
    }

    /// On 2026-10-07 the standup's 228 rows became one part whose schema held
    /// 709 enum values, and Cerebras rejected it ("cannot exceed 500").
    func testPartsKeepTheirSchemaWithinTheProvidersEnumLimit() async throws {
        let transcript = Transcript(segments: (0..<228).map { index in
            .init(start: Double(index * 5), end: Double(index * 5 + 5), speaker: index.isMultiple(of: 2) ? "me" : "them",
                  text: "Short update \(index).")
        }, engine: "fixture")
        let evidence = MeetingNotesEvidence(transcript: transcript)
        let system = MeetingNotesGenerator.systemPrompt(template: .meeting, language: .matchTranscript)
        func plan(limit: Int?) async throws -> [[MeetingNotesEvidence.Unit]] {
            try await MeetingNotesGenerator.makeChunks(evidence: evidence,
                engine: Engine(script: Script([]), hasTokenizer: false, structuredOutputEnumLimit: limit),
                system: system, context: [], contextTokens: 64_000)
        }
        let unlimited = try await plan(limit: nil)
        XCTAssertEqual(unlimited.count, 1, "a grammar-backed server takes the whole meeting")
        let limited = try await plan(limit: 500)
        XCTAssertEqual(limited.count, 2)
        XCTAssertEqual(Set(limited.flatMap { $0.map(\.source) }), Set(evidence.units.map(\.source)))
        for chunk in limited {
            let schema = MeetingNotesEvidence.schema(units: chunk, speakers: Array(evidence.speakers.keys),
                                                     template: .meeting, maximumNotes: 1, maximumActions: 1)
            XCTAssertLessThanOrEqual(MeetingNotesEvidence.enumValueCount(in: schema), 500)
        }
    }

    func testVerifiedWindowKeepsTheFullOutputForAContinuationThat16KShrinks() async throws {
        let system = MeetingNotesGenerator.systemPrompt(template: .meeting, language: .matchTranscript)
        // One part that fits 16K, leaving less room than its own ledger needs
        // beside the full output allowance.
        var transcript = Transcript(segments: [], engine: "fixture")
        while true {
            let evidence = MeetingNotesEvidence(transcript: transcript)
            if (system + "\n\n" + MeetingNotesGenerator.prompt(units: evidence.units, roster: evidence.roster))
                .utf8.count >= 8_500 { break }
            let index = transcript.segments.count
            transcript.segments.append(.init(start: Double(index * 5), end: Double(index * 5 + 5), speaker: "them",
                text: "The team reviewed rollout step \(index) and the documentation it needs."))
        }
        let notes = (1...12).map { index in
            note("s\(index)", "Rollout step \(index) was reviewed. " + String(repeating: "The documentation needs an update. ", count: 6))
        }
        func run(contextTokens: Int) async throws -> (MeetingNotesGenerator.Result, [Script.Call]) {
            let script = Script([.text(try response(notes: notes, more: true)), .text(try response())])
            let result = try await MeetingNotesGenerator.generate(transcript: transcript,
                engine: Engine(script: script, hasTokenizer: false), template: .meeting,
                language: .matchTranscript, context: [], contextTokens: contextTokens,
                meetingID: UUID(), folder: try folder())
            return (result, await script.recorded())
        }
        let (tight, tightCalls) = try await run(contextTokens: 16_384)
        XCTAssertEqual(tightCalls.count, 2, "the 16K byte bound shrinks the continuation's output instead of refusing it")
        XCTAssertEqual(tight.claims.count, 12)
        let window = MeetingSummaryGenerator.contextTokenLimit(for: openRouterConfig("qwen/qwen3.8-flash"))
        let (completed, calls) = try await run(contextTokens: window)
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(completed.claims.count, 12)
        let shrunk = try XCTUnwrap(tightCalls[1].options.maxTokens)
        let full = try XCTUnwrap(calls[1].options.maxTokens)
        XCTAssertLessThan(shrunk, full, "the verified window keeps the full output allowance")
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

    func testDefaultBudgetGrowsWithLongMeetingsButConservativeDoesNot() async throws {
        let standard = MeetingGenerationBudget(limits: GenerationBudgetPreset.standard.limits)
        await standard.recordPlan(model: "fixture", transcriptRevision: "revision", parts: 8)
        for _ in 0..<24 { _ = try await standard.reserve(input: 1, output: 1) }
        do {
            _ = try await standard.reserve(input: 1, output: 1)
            XCTFail("Eight parts double the twelve default requests")
        } catch is MeetingGenerationBudget.Exhausted {}
        let conservative = MeetingGenerationBudget(limits: GenerationBudgetPreset.conservative.limits)
        await conservative.recordPlan(model: "fixture", transcriptRevision: "revision", parts: 8)
        for _ in 0..<6 { _ = try await conservative.reserve(input: 1, output: 1) }
        do {
            _ = try await conservative.reserve(input: 1, output: 1)
            XCTFail("Conservative keeps its fixed limit")
        } catch is MeetingGenerationBudget.Exhausted {}
    }

    func testPlanningALongMeetingExtendsTheDeadline() async throws {
        let budget = MeetingGenerationBudget(limits: .init(seconds: 1, scalesWithParts: true))
        let value = try await budget.run {
            await budget.recordPlan(model: "fixture", transcriptRevision: "revision", parts: 16)
            try await Task.sleep(for: .milliseconds(1_500))
            return 1
        }
        XCTAssertEqual(value, 1)
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

    func testMetricsDoNotRecreateADeletedMeetingFolder() async throws {
        let meetingFolder = try folder()
        try FileManager.default.removeItem(at: meetingFolder)
        let budget = MeetingGenerationBudget()

        await budget.saveMetrics(in: meetingFolder, outcome: "incomplete")

        XCTAssertFalse(FileManager.default.fileExists(atPath: meetingFolder.path))
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

    private func openRouterConfig(_ model: String) -> AppSettings {
        var config = AppSettings()
        config.summarizerBackend = .openAICompatible
        config.openAIBaseURL = "https://openrouter.ai/api/v1"
        config.openAIModel = model
        return config
    }

    /// About 6,000 words over 30 minutes from two speakers. Their wording
    /// differs so neither turn reads as the other's echo.
    private func thirtyMinuteTranscript() -> Transcript {
        Transcript(segments: (0..<360).map { index in
            .init(start: Double(index * 5), end: Double(index * 5 + 5), speaker: index.isMultiple(of: 2) ? "me" : "them",
                  text: index.isMultiple(of: 2)
                    ? "I can take the dashboard review for item \(index) and send the notes to the platform team by Thursday."
                    : "Item \(index) still depends on the billing migration, so finance wants a decision before the release.")
        }, engine: "fixture")
    }

    private func longTranscript(segments: Int = 60) -> Transcript {
        Transcript(segments: (0..<segments).map { index in
            .init(start: Double(index * 5), end: Double(index * 5 + 5), speaker: "them",
                  text: "I will finish task \(index). " + String(repeating: "The dependency needs review. ", count: 6))
        }, engine: "fixture")
    }
}
