import XCTest
@testable import LokalBot

/// Structured-outcomes extraction: the tolerant parse of the model's reply,
/// the schema fed to grammar-constrained backends, the on-disk round trip,
/// the chat observation formatter, and the `get_action_items` tool against a
/// planted library.
@MainActor
final class MeetingOutcomesTests: XCTestCase {

    // MARK: - Parsing

    func testParseCleanJSON() throws {
        let outcomes = try XCTUnwrap(OutcomesExtractor.parse("""
            {"action_items": [{"text": "Benchmark failover", "owner": "Ana", "due": "Friday", "for_user": false, "importance": 4}],
             "decisions": ["Adopt Redis"],
             "open_questions": ["Who owns the migration?"]}
            """))
        XCTAssertEqual(outcomes.actionItems,
                       [.init(
                        text: "Benchmark failover",
                        owner: "Ana",
                        due: "Friday",
                        importance: 4)])
        XCTAssertEqual(outcomes.decisions, ["Adopt Redis"])
        XCTAssertEqual(outcomes.openQuestions, ["Who owns the migration?"])
    }

    func testParseToleratesReasoningFencesAndProse() throws {
        let raw = """
            <think>Let me look for tasks.</think>Here are the outcomes:
            ```json
            {"action_items": [{"text": "Ship the fix", "owner": "", "due": ""}],
             "decisions": [], "open_questions": []}
            ```
            """
        let outcomes = try XCTUnwrap(OutcomesExtractor.parse(raw))
        XCTAssertEqual(outcomes.actionItems.count, 1)
        XCTAssertEqual(outcomes.actionItems.first?.text, "Ship the fix")
        // Empty owner/due (the schema's "not stated" convention) collapse to nil.
        XCTAssertNil(outcomes.actionItems.first?.owner)
        XCTAssertNil(outcomes.actionItems.first?.due)
        XCTAssertTrue(outcomes.decisions.isEmpty)
    }

    func testParseSkipsMalformedEntriesAndBlankStrings() throws {
        let outcomes = try XCTUnwrap(OutcomesExtractor.parse("""
            {"action_items": [{"owner": "Ana"}, {"text": "  "}, {"text": "Real task"}],
             "decisions": ["", "  ", "Keep it"], "open_questions": []}
            """))
        XCTAssertEqual(outcomes.actionItems.map(\.text), ["Real task"])
        XCTAssertEqual(outcomes.decisions, ["Keep it"])
    }

    func testParseGarbageReturnsNil() {
        XCTAssertNil(OutcomesExtractor.parse("No outcomes worth mentioning."))
        XCTAssertNil(OutcomesExtractor.parse(""))
    }

    func testEmptyArraysParseAsEmptyOutcomes() throws {
        let outcomes = try XCTUnwrap(OutcomesExtractor.parse(
            #"{"action_items": [], "decisions": [], "open_questions": []}"#))
        XCTAssertTrue(outcomes.isEmpty)
    }

    func testParseMarksNormalizesAndPrioritizesActionsForTheUser() throws {
        let outcomes = try XCTUnwrap(OutcomesExtractor.parse("""
            {"action_items": [
                {"text": "Review the rollout", "owner": "Ana", "due": "", "for_user": false},
                {"text": "Send the draft", "owner": "Stevan", "due": "Friday", "for_user": true},
                {"text": "Book the room", "owner": "Stevan", "due": "", "for_user": false}
             ], "decisions": [], "open_questions": []}
            """, userSpeakerLabel: "Stevan"))

        XCTAssertEqual(outcomes.actionItems.map(\.text),
                       ["Send the draft", "Review the rollout", "Book the room"])
        XCTAssertEqual(outcomes.userActionItems.map(\.owner), ["Me"])
        XCTAssertEqual(outcomes.unresolvedActionItems.map(\.text), ["Book the room"])
        XCTAssertEqual(outcomes.otherActionItems.map(\.owner), ["Ana"])
    }

    func testFirstPersonActionPreservesExplicitRemoteOwner() throws {
        let outcomes = try XCTUnwrap(OutcomesExtractor.parse("""
            {"action_items": [
                {"text": "I will review the hardening tasks", "owner": "Them 3", "due": "", "for_user": false, "importance": 5}
             ], "decisions": [], "open_questions": []}
            """))

        XCTAssertTrue(outcomes.userActionItems.isEmpty)
        XCTAssertEqual(outcomes.otherActionItems.map(\.owner), ["Them 3"])
        XCTAssertEqual(outcomes.otherActionItems.map(\.importance), [5])
        XCTAssertTrue(OutcomeProse.hasFirstPersonSubject("My next step is to send the plan"))
        XCTAssertFalse(OutcomeProse.hasFirstPersonSubject("I/O migration needs an owner"))
    }

    func testUserOwnershipStaysMeWhileUserFacingProseUsesFirstPerson() throws {
        let persistedID = "persisted-action-id"
        let data = Data("""
            {"actionItems":[
                {"id":"\(persistedID)","text":"Me will touch base on WhatsApp.",
                 "owner":"Me","isForUser":true,"citations":[]}],
             "decisionRecords":[
                {"text":"Me accepted the same terms.","citations":[]}],
             "openQuestions":[]}
            """.utf8)
        let outcomes = try JSONDecoder().decode(MeetingOutcomes.self, from: data)

        XCTAssertEqual(outcomes.actionItems.first?.id, persistedID)
        XCTAssertEqual(outcomes.actionItems.first?.owner, "Me")
        XCTAssertEqual(outcomes.actionItems.first?.text, "I will touch base on WhatsApp.")
        XCTAssertEqual(outcomes.decisionRecords.first?.text, "Me accepted the same terms.")
        XCTAssertEqual(
            OutcomeProse.firstPersonSubject("Me's next step is to send the plan."),
            "My next step is to send the plan.")
        XCTAssertEqual(
            OutcomeProse.actionText("Them 1 will share the repo.", isForUser: false),
            "Them 1 will share the repo.")
    }

    func testDecodingPreservesPersistedRemoteFirstPersonOwnership() throws {
        let data = Data("""
            {"actionItems":[
                {"text":"I will check the hardening tasks.",
                 "owner":"Them 3","isForUser":false,"citations":[]}],
             "decisionRecords":[],"openQuestions":[]}
            """.utf8)

        let outcomes = try JSONDecoder().decode(MeetingOutcomes.self, from: data)

        XCTAssertTrue(outcomes.userActionItems.isEmpty)
        XCTAssertEqual(outcomes.otherActionItems.map(\.owner), ["Them 3"])
        XCTAssertEqual(outcomes.otherActionItems.map(\.text), [
            "I will check the hardening tasks.",
        ])
    }

    // MARK: - Schema and prompt

    func testSchemaSerializesAsJSON() throws {
        let data = try JSONSerialization.data(withJSONObject: OutcomesExtractor.schema)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object["required"] as? [String] ?? []),
                       ["action_items", "decisions", "open_questions"])
        XCTAssertEqual(object["additionalProperties"] as? Bool, false)
        let properties = try XCTUnwrap(object["properties"] as? [String: Any])
        let actionItems = try XCTUnwrap(properties["action_items"] as? [String: Any])
        let item = try XCTUnwrap(actionItems["items"] as? [String: Any])
        XCTAssertEqual(Set(item["required"] as? [String] ?? []),
                       [
                        "text", "owner", "due", "for_user", "importance",
                        "source_segment_ids", "owner_speaker_id", "ownership_basis", "ownership_quote",
                       ])
        XCTAssertEqual(item["additionalProperties"] as? Bool, false)
        let itemProperties = try XCTUnwrap(item["properties"] as? [String: Any])
        let importance = try XCTUnwrap(itemProperties["importance"] as? [String: Any])
        XCTAssertEqual(importance["type"] as? String, "integer")
        XCTAssertNil(OpenAIStrictSchemaValidator.validationIssue(
            in: OutcomesExtractor.schema))
    }

    func testSystemPromptAlwaysChecksWhatTheUserNeedsToDo() {
        let prompt = OutcomesExtractor.systemPrompt(
            userSpeakerLabel: "Stevan",
            outputLanguage: .en)
        XCTAssertTrue(prompt.contains("everything actionable for that user"), prompt)
        XCTAssertTrue(prompt.contains("commitments made by \"Stevan\""), prompt)
        XCTAssertTrue(prompt.contains("requests or assignments directed to \"Stevan\""), prompt)
        XCTAssertTrue(prompt.contains("\"for_user\" to true"), prompt)
        XCTAssertTrue(prompt.contains("set \"owner\" to \"Me\""), prompt)
        XCTAssertTrue(prompt.contains("\"importance\" to an integer from 1"), prompt)
        XCTAssertTrue(prompt.contains("including actions with unclear ownership"), prompt)
        XCTAssertTrue(prompt.contains("at most the five highest-importance actions"), prompt)
        XCTAssertTrue(prompt.contains("Never drop a user action"), prompt)
        XCTAssertTrue(prompt.contains("I will"), prompt)
        XCTAssertTrue(prompt.contains("owner-neutral task descriptions"), prompt)
        XCTAssertTrue(prompt.contains("action descriptions, decisions, and open questions in English"), prompt)
        XCTAssertTrue(prompt.contains("Copy owner names, due dates, and evidence quotes from the source unchanged"), prompt)
    }

    func testPromptUsesOnlySourceLabelledEvidence() {
        let prompt = OutcomesExtractor.prompt(
            evidence: "[segment-0001] [00:00:12] Me: I will send the plan.")

        XCTAssertTrue(prompt.contains("segment-0001"), prompt)
        XCTAssertTrue(prompt.contains("Only cite segment IDs that appear below"), prompt)
    }

    // MARK: - Disk round trip

    func testWriteAndLoadRoundTrip() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("lokalbot-outcomes-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        XCTAssertNil(MeetingOutcomes.load(from: folder))
        var outcomes = MeetingOutcomes()
        outcomes.actionItems = [.init(text: "Benchmark failover", owner: "Ana")]
        outcomes.decisions = ["Adopt Redis"]
        try outcomes.write(to: folder)
        XCTAssertEqual(MeetingOutcomes.load(from: folder), outcomes)
    }

    func testActionPrioritizationKeepsMineAndSelectsOnlyTopOthersWithinTen() {
        let mine = (1...6).map {
            MeetingOutcomes.ActionItem(text: "My action \($0)", owner: "Me", importance: 1)
        }
        let others = [1, 5, 2, 4, 3, 5, 4].enumerated().map { index, importance in
            MeetingOutcomes.ActionItem(
                text: "Other action \(index)",
                owner: "Them",
                importance: importance)
        }
        let prioritized = MeetingOutcomes(actionItems: mine + others)
            .prioritizingActionItems()

        XCTAssertEqual(prioritized.actionItems.count, 10)
        XCTAssertEqual(prioritized.userActionItems.map(\.text), mine.map(\.text))
        XCTAssertEqual(prioritized.otherActionItems.map(\.importance), [5, 5, 4, 4])

        let fewerMine = MeetingOutcomes(actionItems: Array(mine.prefix(3)) + others)
            .prioritizingActionItems()
        XCTAssertEqual(fewerMine.actionItems.count, 8)
        XCTAssertEqual(fewerMine.otherActionItems.map(\.importance), [5, 5, 4, 4, 3])
    }

    func testActionPrioritizationNeverDropsMineEvenAboveNormalCeiling() {
        let mine = (1...11).map {
            MeetingOutcomes.ActionItem(text: "My action \($0)", owner: "Me")
        }
        let other = MeetingOutcomes.ActionItem(
            text: "Other critical action",
            owner: "Them",
            importance: 5)

        let prioritized = MeetingOutcomes(actionItems: mine + [other])
            .prioritizingActionItems()

        XCTAssertEqual(prioritized.actionItems.count, 11)
        XCTAssertEqual(prioritized.userActionItems.count, 11)
        XCTAssertTrue(prioritized.otherActionItems.isEmpty)
    }

    func testOtherAndUnclearOwnersShareOneRankedLimit() {
        let unclear = OutcomeAttribution(resolution: .unresolved, basis: .unclear)
        let candidates: [MeetingOutcomes.ActionItem] = [
            .init(id: "other-low", text: "Other low", owner: "Ana", importance: 2),
            .init(id: "unclear-high", text: "Unclear high", importance: 4, attribution: unclear),
            .init(id: "other-medium", text: "Other medium", owner: "Ana", importance: 3),
            .init(id: "unclear-critical", text: "Unclear critical", importance: 5, attribution: unclear),
            .init(id: "unclear-low", text: "Unclear low", importance: 1, attribution: unclear),
            .init(id: "other-high", text: "Other high", owner: "Ana", importance: 4),
            .init(id: "unclear-medium", text: "Unclear medium", importance: 3, attribution: unclear),
        ]
        let rankedIDs = ["unclear-critical", "other-high", "unclear-high", "other-medium", "unclear-medium"]
        for (userCount, remainingCount) in [(0, 5), (3, 5), (6, 4), (10, 0), (11, 0)] {
            let mine = (0..<userCount).map {
                MeetingOutcomes.ActionItem(text: "My action \($0)", owner: "Me", importance: 1)
            }
            let result = MeetingOutcomes(actionItems: candidates + mine).prioritizingActionItems()

            XCTAssertEqual(result.userActionItems, mine)
            XCTAssertEqual(result.actionItems.count, userCount + remainingCount)
            XCTAssertEqual(Array(result.actionItems.prefix(userCount)), mine)
            XCTAssertEqual(result.actionItems.dropFirst(userCount).map(\.id), Array(rankedIDs.prefix(remainingCount)))
            for action in result.unresolvedActionItems {
                XCTAssertEqual(action, candidates.first { $0.id == action.id })
                XCTAssertEqual(action.attribution?.resolution, .unresolved)
                XCTAssertNil(action.owner)
                XCTAssertFalse(action.isForUser)
            }
        }
    }

    func testSharedRankingUsesCitationTimeThenTextForImportanceTies() {
        func action(_ text: String, owner: String?, importance: Int, start: Double) -> MeetingOutcomes.ActionItem {
            .init(text: text, owner: owner, importance: importance, citations: [
                .init(segmentID: "source-\(text)", start: start, end: start + 1,
                      speaker: "them 1", excerpt: text),
            ])
        }
        let items = [
            action("Late", owner: nil, importance: 4, start: 20),
            action("Beta", owner: "Ana", importance: 4, start: 10),
            action("Critical", owner: "Ana", importance: 5, start: 30),
            action("Alpha", owner: nil, importance: 4, start: 10),
        ]

        let result = MeetingOutcomes(actionItems: items).prioritizingActionItems()

        XCTAssertEqual(result.actionItems.map(\.text), ["Critical", "Alpha", "Beta", "Late"])
        XCTAssertEqual(result.unresolvedActionItems.map(\.text), ["Alpha", "Late"])
    }

    func testLoadingExistingUnclearActionsAppliesSharedLimitWithoutRewritingEvidence() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("lokalbot-unclear-outcome-limit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let others = (0..<3).map {
            MeetingOutcomes.ActionItem(text: "Other action \($0)", owner: "Ana", importance: 3)
        }
        let unclear = (0..<27).map {
            MeetingOutcomes.ActionItem(text: "Unclear action \($0)", importance: $0 % 5 + 1,
                                      attribution: .init(resolution: .unresolved, basis: .unclear))
        }
        try MeetingOutcomes(actionItems: others + unclear).write(to: folder)
        let file = folder.appendingPathComponent(MeetingOutcomes.fileName)
        let original = try Data(contentsOf: file)

        let loaded = try XCTUnwrap(MeetingOutcomes.load(from: folder))

        XCTAssertEqual(loaded.actionItems.count, 5)
        XCTAssertEqual(loaded.actionItems.map(\.importance), [5, 5, 5, 5, 5])
        XCTAssertEqual(loaded.unresolvedActionItems.count, 5)
        XCTAssertTrue(loaded.actionItems.allSatisfy { $0.owner == nil && !$0.isForUser })
        XCTAssertEqual(try Data(contentsOf: file), original)
    }

    func testLoadingExistingArtifactAppliesActionItemSelectionPolicy() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("lokalbot-outcome-limit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let mine = (1...6).map {
            MeetingOutcomes.ActionItem(text: "My action \($0)", owner: "Me")
        }
        let others = (1...7).map {
            MeetingOutcomes.ActionItem(
                text: "Other action \($0)",
                owner: "Them",
                importance: $0.isMultiple(of: 2) ? 5 : 1)
        }
        try MeetingOutcomes(actionItems: mine + others).write(to: folder)

        let loaded = try XCTUnwrap(MeetingOutcomes.load(from: folder))

        XCTAssertEqual(loaded.actionItems.count, 10)
        XCTAssertEqual(loaded.userActionItems.count, 6)
        XCTAssertEqual(loaded.otherActionItems.count, 4)
        XCTAssertEqual(loaded.otherActionItems.map(\.importance), [5, 5, 5, 1])
    }

    func testGroundedParseRejectsUnknownEvidenceAndResolvesKnownSegments() throws {
        let meetingID = UUID(uuidString: "11111111-2222-4333-8444-555555555555")!
        let transcript = Transcript(
            segments: [
                .init(start: 12, end: 18, speaker: "me", text: "I will send the plan. We chose the local store.", attribution: .init(source: .microphone, identity: .user, method: .confirmation)),
            ],
            engine: "fixture")
        let validID = transcript.segmentID(at: 0)
        let outcomes = try XCTUnwrap(OutcomesExtractor.parse(
            """
            {"action_items": [
              {"text":"Send the plan","owner":"Me","due":"","for_user":true,
               "source_segment_ids":["\(validID)"], "owner_speaker_id":"me", "ownership_basis":"commitment", "ownership_quote":"I will send the plan."},
              {"text":"Invented task","owner":"Me","due":"","for_user":true,
               "source_segment_ids":["segment-does-not-exist"]}],
             "decisions": [{"text":"Use the local store","source_segment_ids":["\(validID)"], "speaker_id":"me", "quote":"We chose the local store."}],
             "open_questions":[]}
            """,
            sourceSegments: transcript.segmentSourceMap,
            meetingID: meetingID,
            requireEvidence: true))

        XCTAssertEqual(outcomes.actionItems.map(\.text), ["Send the plan"])
        XCTAssertEqual(outcomes.actionItems.first?.citations.first?.segmentID, validID)
        XCTAssertEqual(outcomes.actionItems.first?.citations.first?.meetingID, meetingID)
        XCTAssertEqual(outcomes.actionItems.first?.schemaVersion, MeetingOutcomes.currentSchemaVersion)
        XCTAssertEqual(outcomes.actionItems.first?.isForUser, true)
        XCTAssertEqual(
            outcomes.actionItems.first?.importance,
            MeetingOutcomes.ActionItem.defaultImportance)
        XCTAssertEqual(outcomes.decisionRecords.map(\.text), ["Use the local store"])
    }

    func testGroundedParseReportsRejectedEvidenceCandidates() throws {
        let transcript = Transcript(
            segments: [
                .init(start: 12, end: 18, speaker: "me", text: "I will send the plan. We chose the local store.", attribution: .init(source: .microphone, identity: .user, method: .confirmation)),
            ],
            engine: "fixture")
        let parsed = try XCTUnwrap(OutcomesExtractor.parseResult(
            """
            {"action_items": [
              {"text":"Send the plan","owner":"Me","due":"","for_user":true,
               "source_segment_ids":["segment-does-not-exist"]}],
             "decisions": ["Proceed"], "open_questions":[]}
            """,
            sourceSegments: transcript.segmentSourceMap,
            requireEvidence: true))

        XCTAssertTrue(parsed.outcomes.actionItems.isEmpty)
        XCTAssertTrue(parsed.outcomes.decisionRecords.isEmpty)
        XCTAssertEqual(parsed.rejectedActionItems, 1)
        XCTAssertEqual(parsed.rejectedDecisions, 1)
    }

    func testLegacyOutcomeShapeStillDecodesWithDerivedOwnership() throws {
        let data = Data(#"{"action_items":[{"text":"Ship it","owner":"Me"}],"decisions":["Proceed"],"open_questions":[]}"#.utf8)
        let outcomes = try JSONDecoder().decode(MeetingOutcomes.self, from: data)

        XCTAssertEqual(outcomes.actionItems.first?.isForUser, true)
        XCTAssertEqual(outcomes.actionItems.first?.schemaVersion, MeetingOutcomes.currentSchemaVersion)
        XCTAssertEqual(outcomes.decisions, ["Proceed"])
    }

    func testOverlayStateAndFollowUpRoundTripWithoutMutatingExtraction() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("lokalbot-outcome-state-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let action = MeetingOutcomes.ActionItem(text: "Ship the fix", owner: "Me")
        var state = MeetingOutcomeState()
        state.actions[action.id] = .init(
            status: .deferred,
            ownerOverride: "Ana",
            dueOverride: "Monday",
            textCorrection: "Ship the verified fix",
            userEdited: true)
        try MeetingOutcomeStore.writeState(state, to: folder)
        XCTAssertEqual(MeetingOutcomeStore.loadState(from: folder), state)

        let sourceID = UUID()
        let draft = FollowUpDraft(
            recipient: "", cc: "Ana", subject: "Follow-up",
            body: "Reviewed locally", seeded: false, reviewed: true,
            sourceMeetingID: sourceID)
        try MeetingOutcomeStore.writeFollowUp(draft, to: folder)
        XCTAssertEqual(MeetingOutcomeStore.loadFollowUp(from: folder), draft)
    }

    func testReprocessingReconcilesEditedStateByEvidence() {
        let citation = OutcomeSourceCitation(
            segmentID: "segment-0000-0000001000-0000002000",
            start: 1, end: 2, speaker: "me", excerpt: "I will ship the fix")
        let priorAction = MeetingOutcomes.ActionItem(
            text: "Ship the fix", owner: "Me", citations: [citation])
        let nextAction = MeetingOutcomes.ActionItem(
            text: "Ship the verified fix", owner: "Me", citations: [citation])
        var state = MeetingOutcomeState()
        state.actions[priorAction.id] = .init(
            status: .done, textCorrection: "Ship the verified fix",
            userEdited: true)

        let reconciled = MeetingOutcomeStore.reconcileState(
            state,
            from: MeetingOutcomes(actionItems: [priorAction]),
            to: MeetingOutcomes(actionItems: [nextAction]))

        XCTAssertEqual(reconciled.actions[nextAction.id]?.status, .done)
        XCTAssertEqual(reconciled.actions[nextAction.id]?.textCorrection, "Ship the verified fix")
        XCTAssertNil(reconciled.actions[priorAction.id])
    }

    // MARK: - Formatting

    func testFormatOutcomesListsSectionsWithIDs() {
        let meeting = Meeting(
            id: UUID(uuidString: "11111111-2222-4333-8444-555555555555")!,
            title: "Caching strategy", appName: "Zoom",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            endedAt: Date(timeIntervalSince1970: 1_700_001_800),
            relativePath: "meetings/2026/06/caching")
        var outcomes = MeetingOutcomes()
        outcomes.actionItems = [
            .init(text: "Send the migration plan", owner: "Me", due: "Thursday"),
            .init(text: "Benchmark failover", owner: "Ana", due: "Friday"),
        ]
        outcomes.decisions = ["Adopt Redis"]
        outcomes.openQuestions = ["Who owns the migration?"]

        let text = MeetingChatFormat.outcomes([(meeting, outcomes)])
        XCTAssertTrue(text.contains("[11111111] Caching strategy"), text)
        XCTAssertTrue(text.contains("My action items:\n- Send the migration plan (due: Thursday)"), text)
        XCTAssertTrue(text.contains("Other action items:"), text)
        XCTAssertTrue(text.contains("- Benchmark failover (owner: Ana, due: Friday)"), text)
        XCTAssertTrue(text.contains("Decisions:\n- Adopt Redis"), text)
        XCTAssertTrue(text.contains("Open questions:\n- Who owns the migration?"), text)
    }

    func testFormatEmptyExplainsWhereOutcomesComeFrom() {
        XCTAssertTrue(MeetingChatFormat.outcomes([]).contains("extracted when a meeting is summarized"))
    }

    func testThreadedFormatDeduplicatesActionsAndPreservesSourceIDs() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let first = Meeting(
            id: UUID(uuidString: "11111111-2222-4333-8444-555555555555")!,
            title: "Planning",
            appName: "Zoom",
            startedAt: start,
            endedAt: start.addingTimeInterval(1_800),
            relativePath: "meetings/planning")
        let second = Meeting(
            id: UUID(uuidString: "22222222-3333-4444-8555-666666666666")!,
            title: "Review",
            appName: "Zoom",
            startedAt: start.addingTimeInterval(86_400),
            endedAt: start.addingTimeInterval(88_200),
            relativePath: "meetings/review")
        let firstAction = MeetingOutcomes.ActionItem(
            text: "I will send the revised launch proposal",
            owner: "Me")
        let secondAction = MeetingOutcomes.ActionItem(
            text: "Send the revised launch proposal",
            owner: "Me")
        var state = MeetingOutcomeState()
        state.actions[secondAction.id] = .init(
            textCorrection: "Send Acme the revised launch proposal",
            userEdited: true)
        let projections = [
            MeetingOutcomeProjection(
                meeting: first,
                outcomes: MeetingOutcomes(actionItems: [firstAction]),
                state: MeetingOutcomeState(),
                followUp: FollowUpDraft()),
            MeetingOutcomeProjection(
                meeting: second,
                outcomes: MeetingOutcomes(
                    actionItems: [secondAction],
                    decisions: ["Keep the rollout staged"]),
                state: state,
                followUp: FollowUpDraft()),
        ]

        let text = MeetingChatFormat.threadedOutcomes(projections)

        XCTAssertEqual(
            text.components(separatedBy: "Send Acme the revised launch proposal").count - 1,
            1)
        XCTAssertTrue(text.contains("[11111111]"), text)
        XCTAssertTrue(text.contains("[22222222]"), text)
        XCTAssertTrue(text.contains("Keep the rollout staged"), text)
    }

    // MARK: - get_action_items tool (planted library)

    func testArchivedActionsCanBeCorrectedWithoutReenteringCurrentIndex() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = StorageManager(rootURL: root)
        let meeting = try storage.createMeetingFolder(title: "Speaker review", appName: "Zoom")
        let folder = meeting.folderURL(in: storage)
        let original = MeetingOutcomes(actionItems: [
            .init(id: "review-action", text: "Benchmark failover", owner: "Them"),
        ], decisions: [], openQuestions: [])
        try original.write(to: folder)
        var evidenceChanges = 0
        let index = OutcomeIndex(storage: storage, onEvidenceChanged: { _ in evidenceChanges += 1 })
        index.refresh(meeting: meeting)
        XCTAssertNotNil(index.projection(for: meeting.id))

        try MeetingAttributionArtifacts.invalidate(in: folder)
        index.refresh(meeting: meeting)
        XCTAssertNil(index.projection(for: meeting.id))
        XCTAssertTrue(index.correctAction(actionID: "review-action", meetingID: meeting.id,
                                          text: nil, owner: "Ana", due: "Friday", reviewing: meeting))
        XCTAssertTrue(index.all.isEmpty)
        XCTAssertTrue(index.openUserActionThreads.isEmpty)
        XCTAssertNil(MeetingOutcomes.load(from: folder))
        XCTAssertTrue(MeetingAttributionArtifacts.needsRefresh(in: folder))
        XCTAssertEqual(MeetingAttributionArtifacts.previous(in: folder)?.actionItems.first?.owner, "Them")
        XCTAssertEqual(evidenceChanges, 0, "Archive-only edits must not invalidate current derived evidence")
        XCTAssertNil(DayDigestMeetingArtifacts.latestModifiedAt(in: folder),
                     "An archive-only correction must not advance the digest's evidence watermark")

        let reopened = OutcomeIndex(storage: storage)
        reopened.refresh(meeting: meeting)
        XCTAssertNil(reopened.projection(for: meeting.id))
        let reviewed = try XCTUnwrap(reopened.projectionForReview(of: meeting)?.actionReferences.first)
        XCTAssertEqual(reviewed.owner, "Ana")
        XCTAssertEqual(reviewed.due, "Friday")
        XCTAssertTrue(reviewed.ownerWasCorrected)
        XCTAssertEqual(reopened.projectionForReview(of: meeting)?.isArchived, true)
        XCTAssertFalse(reopened.correctAction(actionID: "missing", meetingID: meeting.id,
                                               text: nil, owner: "Me", due: nil, reviewing: meeting))
        XCTAssertFalse(reopened.correctAction(actionID: "review-action", meetingID: UUID(),
                                               text: nil, owner: "Me", due: nil, reviewing: meeting))
        XCTAssertTrue(reopened.lastError?.contains("different meeting") == true)
        XCTAssertFalse(reopened.correctAction(actionID: "missing", meetingID: meeting.id,
                                               text: nil, owner: "Me", due: nil, reviewing: meeting))
        XCTAssertTrue(reopened.lastError?.contains("no longer available") == true,
                      "Guard failures must replace the error from an earlier operation")
        try FileManager.default.removeItem(at: folder.appendingPathComponent(MeetingAttributionArtifacts.refreshMarker))
        XCTAssertNil(reopened.projectionForReview(of: meeting), "Old archives are not a fallback for unrelated missing data")

        // An empty cache is not archived evidence: current on-disk outcomes still notify.
        try original.write(to: folder)
        XCTAssertTrue(index.correctAction(actionID: "review-action", meetingID: meeting.id,
                                          text: nil, owner: "Me", due: nil, reviewing: meeting))
        XCTAssertEqual(evidenceChanges, 1)
        XCTAssertNotNil(DayDigestMeetingArtifacts.latestModifiedAt(in: folder))
    }

    func testGetActionItemsAgainstPlantedLibrary() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lokalbot-outcomes-tool-\(UUID().uuidString)", isDirectory: true)
        setenv("LOKALBOT_STORAGE_ROOT", root.path, 1)
        defer {
            unsetenv("LOKALBOT_STORAGE_ROOT")
            try? FileManager.default.removeItem(at: root)
        }

        let storage = StorageManager()
        // A recent meeting with outcomes, and an old one whose outcomes should
        // fall outside the default 7-day scan.
        let recent = Meeting(
            id: UUID(uuidString: "11111111-2222-4333-8444-555555555555")!,
            title: "Caching strategy", appName: "Zoom",
            startedAt: Date().addingTimeInterval(-3_600),
            endedAt: Date(), relativePath: "meetings/2026/07/caching")
        let old = Meeting(
            id: UUID(uuidString: "22222222-3333-4444-8555-666666666666")!,
            title: "Kickoff", appName: "Meet",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            endedAt: Date(timeIntervalSince1970: 1_700_001_800),
            relativePath: "meetings/2023/11/kickoff")
        for meeting in [recent, old] {
            let folder = meeting.folderURL(in: storage)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        var recentOutcomes = MeetingOutcomes()
        recentOutcomes.actionItems = [.init(text: "Benchmark failover", owner: "Ana")]
        try recentOutcomes.write(to: recent.folderURL(in: storage))
        var oldOutcomes = MeetingOutcomes()
        oldOutcomes.decisions = ["Start the project"]
        try oldOutcomes.write(to: old.folderURL(in: storage))

        let sqlite = storage.rootURL.appendingPathComponent("lokalbotv3.sqlite")
        var settings = AppSettings()
        settings.semanticSearchEnabled = false
        let tools = MeetingChatTools(
            meetings: { [recent, old] }, storage: storage,
            searchIndex: SearchIndex(databaseURL: sqlite),
            embeddingIndex: EmbeddingIndex(databaseURL: sqlite, storage: storage),
            activityStore: ActivityStore(databaseURL: sqlite),
            settings: { settings })

        let recentScan = await tools.run(ChatToolCall(name: "get_action_items", arguments: [:]))
        XCTAssertTrue(recentScan.text.contains("Benchmark failover"), recentScan.text)
        XCTAssertFalse(recentScan.text.contains("Start the project"), recentScan.text)
        XCTAssertEqual(recentScan.summary, "last 7 days — 1 action item")

        var completedState = MeetingOutcomeState()
        completedState.actions[recentOutcomes.actionItems[0].id] = .init(
            status: .done, textCorrection: "Benchmark production failover", userEdited: true)
        try MeetingOutcomeStore.writeState(completedState, to: recent.folderURL(in: storage))
        let completed = await tools.run(ChatToolCall(
            name: "get_action_items", arguments: ["status": "done"]))
        XCTAssertTrue(completed.text.contains("Benchmark production failover"))
        XCTAssertTrue(completed.text.contains("status: done"))
        XCTAssertTrue(completed.text.contains("[11111111]"))
        let all = await tools.run(ChatToolCall(name: "get_action_items", arguments: [:]))
        XCTAssertTrue(all.text.contains("Benchmark production failover"))
        let active = await tools.run(ChatToolCall(
            name: "get_action_items", arguments: ["status": "active"]))
        XCTAssertFalse(active.text.contains("Benchmark production failover"))
        XCTAssertEqual(active.text, "No open or deferred action items found in this scope.")
        let deferred = await tools.run(ChatToolCall(
            name: "get_action_items", arguments: ["status": "deferred"]))
        XCTAssertEqual(deferred.text, "No deferred action items found in this scope.")

        let byID = await tools.run(ChatToolCall(
            name: "get_action_items", arguments: ["id": SessionLookup.shortID(old.id)]))
        XCTAssertTrue(byID.text.contains("Start the project"), byID.text)
        XCTAssertEqual(byID.summary, "Kickoff — 0 action items")

        let miss = await tools.run(ChatToolCall(name: "get_action_items",
                                                arguments: ["id": "zzzzzzzz"]))
        XCTAssertTrue(miss.text.contains("No meeting matches"), miss.text)
    }
}
