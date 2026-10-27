import CryptoKit
import XCTest
@testable import LokalBot

/// Phase 3 of the personal world model: learning facts and goals from the
/// person's own meeting lines, review of learned preferences, and retraction
/// when the meeting is deleted or corrected.
final class PersonalLearningLinesTests: XCTestCase {
    private func segment(_ speaker: String, _ text: String) -> Transcript.Segment {
        Transcript.Segment(start: 0, end: 1, speaker: speaker, text: text, confidence: nil)
    }

    func testOwnTurnsJoinConsecutiveMicrophoneSegmentsAndDropShortOnes() {
        let turns = PersonalLearning.ownTurns(in: [
            segment("me", "I moved to Belgrade"),
            segment("me", "with my family last spring."),
            segment("them", "Nice, how is it going?"),
            segment("me", "Good, thanks."),
            segment("Them", "And the release?"),
            segment("ME", "I want to run a marathon next year, honestly."),
        ])
        XCTAssertEqual(turns, [
            "I moved to Belgrade with my family last spring.",
            "I want to run a marathon next year, honestly.",
        ])
    }

    func testSharedMicrophoneIsSkippedButASingleLocalVoiceCounts() {
        let shared = PersonalLearning.ownTurns(in: [
            segment("local 1", "I live in Novi Sad with my two kids."),
            segment("local 2", "I have been at the company for ten years."),
        ])
        XCTAssertEqual(shared, [])

        let single = PersonalLearning.ownTurns(in: [
            segment("local", "I live in Novi Sad with my two kids."),
            segment("remote", "Great to hear."),
        ])
        XCTAssertEqual(single, ["I live in Novi Sad with my two kids."])
    }

    func testSelfReferenceScoreCoversEnglishAndSerbian() {
        XCTAssertGreaterThan(PersonalLearning.selfReferenceScore("I'm leading the platform team now"), 0)
        XCTAssertGreaterThan(PersonalLearning.selfReferenceScore("Ja živim u Beogradu sa porodicom"), 0)
        XCTAssertGreaterThan(PersonalLearning.selfReferenceScore("Ја живим у Београду"), 0)
        XCTAssertEqual(PersonalLearning.selfReferenceScore("The deploy failed again on Tuesday"), 0)
    }

    func testUtterancesReadOnlyThatDaysOwnLinesWithHandles() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PersonalLearningLines-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let day = Date(timeIntervalSince1970: 1_790_000_000)
        let meetingID = UUID()
        try MeetingFixture.write([
            .init(id: meetingID, title: "Weekly sync", startedAt: day, transcriptLines: [
                "I live in Belgrade and I work from home most days.",
                "Where do you live these days, by the way?",
                "The deploy failed again on Tuesday afternoon, sadly.",
            ]),
            .init(title: "Yesterday", startedAt: day.addingTimeInterval(-86_400), transcriptLines: [
                "I used to live in Berlin before moving here.",
            ]),
        ], under: root)

        let lines = try PersonalLearning.utterances(day: day, storageRoot: root, calendar: calendar)
        XCTAssertEqual(lines.map(\.text), ["I live in Belgrade and I work from home most days."])
        XCTAssertEqual(lines.first?.handle, "U1")
        XCTAssertEqual(lines.first?.meetingID, meetingID)
        XCTAssertEqual(lines.first?.label, "Weekly sync")
    }
}

final class PersonalLearningReplyTests: XCTestCase {
    private let meetingID = UUID()
    private var lines: [PersonalLearning.Utterance] {
        [
            .init(handle: "U1", meetingID: meetingID, meetingTitle: "Sync", dayKey: "2026-10-14",
                  text: "I live in Belgrade and I work from home most days."),
            .init(handle: "U2", meetingID: meetingID, meetingTitle: "Sync", dayKey: "2026-10-14",
                  text: "My goal is to run a marathon next year."),
            .init(handle: "U3", meetingID: meetingID, meetingTitle: "Sync", dayKey: "2026-10-14",
                  text: "I prefer written updates over calls for status."),
        ]
    }

    private func parse(_ output: String) -> [PersonalModel.LearningCandidate] {
        PersonalLearning.candidates(from: output, utterances: lines) { utterance in
            PersonalLearning.provenance(for: utterance, revision: 7)
        }
    }

    func testGroundedItemsBecomeCandidatesWithEvidence() throws {
        let candidates = parse("""
            {"items": [
              {"line": "U1", "kind": "fact", "text": "I live in Belgrade."},
              {"line": "u2", "kind": "goal", "text": "I want to run a marathon next year."}
            ]}
            """)
        XCTAssertEqual(candidates.map(\.text), ["I live in Belgrade.", "I want to run a marathon next year."])
        XCTAssertEqual(candidates.map(\.kind), [.fact, .goal])
        let first = try XCTUnwrap(candidates.first)
        XCTAssertEqual(first.quote, "I live in Belgrade and I work from home most days.")
        XCTAssertEqual(first.evidence?.sources.map(\.id), [meetingID.uuidString])
        XCTAssertEqual(first.evidence?.revision, 7)
        XCTAssertEqual(first.origin, .learned(meetingID: meetingID, dayKey: "2026-10-14"))
        XCTAssertFalse(first.needsReview)
    }

    func testUngroundedUnknownPrincipleAndExtraItemsAreDropped() {
        let candidates = parse("""
            Sure! {"items": [
              {"line": "U9", "kind": "fact", "text": "I live in Belgrade."},
              {"line": "U1", "kind": "principle", "text": "I live in Belgrade."},
              {"line": "U1", "kind": "fact", "text": "I am an excellent chess player."},
              {"line": "U1", "kind": "fact", "text": "I live in Belgrade."},
              {"line": "U2", "kind": "goal", "text": "I want to run a marathon."},
              {"line": "U3", "kind": "preference", "text": "I prefer written updates."},
              {"line": "U1", "kind": "fact", "text": "I work from home most days."}
            ]}
            """)
        XCTAssertEqual(candidates.map(\.text), [
            "I live in Belgrade.", "I want to run a marathon.", "I prefer written updates.",
        ])
        XCTAssertEqual(parse("not json"), [])
        XCTAssertEqual(parse(#"{"items": []}"#), [])
    }

    func testPromptListsOnlyTheLinesAndKnownItems() {
        let known = PersonalClaim(kind: .fact, text: "Maya is my manager", origin: .added, createdAt: Date())
        let prompt = PersonalLearning.prompt(utterances: lines, known: [known])
        XCTAssertTrue(prompt.contains("U1 (Sync): I live in Belgrade"))
        XCTAssertTrue(prompt.contains("- Maya is my manager"))
        XCTAssertTrue(prompt.contains("never infer their values"))
    }
}

final class PersonalLearningCrossLanguageTests: XCTestCase {
    private let meetingID = UUID()

    private func line(_ handle: String, _ text: String) -> PersonalLearning.Utterance {
        .init(handle: handle, meetingID: meetingID, meetingTitle: "Standup", dayKey: "2026-10-14", text: text)
    }

    private func evidence(_ utterance: PersonalLearning.Utterance) -> DreamEvidenceProvenance {
        DreamEvidenceProvenance(
            sources: [DreamEvidenceSource(kind: .meeting, id: meetingID.uuidString, dayKey: utterance.dayKey)],
            revision: 1)
    }

    /// Two unit vectors whose dot product is `similarity`.
    private func pair(_ similarity: Float) -> [[Float]] {
        [[1, 0], [similarity, (1 - similarity * similarity).squareRoot()]]
    }

    func testWordRootsMatchAcrossScriptsAndInflection() {
        XCTAssertTrue(PersonalLearning.sharesWordRoot("I lead the platform team.", "Ја водим тим за платформу."))
        XCTAssertTrue(PersonalLearning.sharesWordRoot("I want to run a marathon in 2027.",
                                                      "Cilj mi je da sledeće godine istrčim maraton."))
        XCTAssertTrue(PersonalLearning.sharesWordRoot("I live in Novi Sad.", "Živim u Novom Sadu sa porodicom."))
        XCTAssertFalse(PersonalLearning.sharesWordRoot("I work as a doctor in Belgrade.",
                                                       "Radim kao inženjer u Beogradu, uglavnom od kuće."))
    }

    func testOnlyTranslatedItemsCountAsCrossLanguage() {
        XCTAssertTrue(PersonalLearning.isCrossLanguage(
            "I lead the platform team.", "Ja vodim tim za platformu već dve godine i to mi se baš sviđa."))
        XCTAssertFalse(PersonalLearning.isCrossLanguage(
            "I live in Belgrade.", "I live in Belgrade with my family and I work from home."))
    }

    func testVerdictTiers() {
        let claim = "I lead the platform team."
        let line = "Ja vodim tim za platformu već dve godine."
        let unrelated = "Radim kao inženjer u Beogradu, uglavnom od kuće."
        XCTAssertEqual(PersonalLearning.crossLanguageVerdict(similarity: 0.79, claim: claim, line: line), .rejected)
        XCTAssertEqual(PersonalLearning.crossLanguageVerdict(similarity: 0.85, claim: claim, line: line), .grounded)
        XCTAssertEqual(PersonalLearning.crossLanguageVerdict(similarity: 0.85, claim: "I am a doctor.", line: unrelated),
                       .needsReview)
        XCTAssertEqual(PersonalLearning.crossLanguageVerdict(similarity: 0.93, claim: "I am a doctor.", line: unrelated),
                       .grounded)
    }

    func testTranslatedItemsAreCheckedByMeaningAndUncertainOnesWaitForReview() async {
        let lines = [
            line("U1", "Ja vodim tim za platformu već dve godine i to mi se baš sviđa."),
            line("U2", "I live in Belgrade and I work from home most days."),
            line("U3", "Radim kao inženjer u Beogradu, uglavnom od kuće."),
        ]
        let output = """
            {"items": [
              {"line": "U1", "kind": "fact", "text": "I lead the platform team."},
              {"line": "U2", "kind": "fact", "text": "I am an excellent chess player."},
              {"line": "U3", "kind": "fact", "text": "I work as a doctor in Belgrade."}
            ]}
            """
        let recorder = EmbedRecorder(vectors: pair(0.86) + pair(0.85))
        let candidates = await PersonalLearning.groundedCandidates(
            from: output, utterances: lines, embed: { await recorder.embed($0) }, evidence: evidence)
        XCTAssertEqual(candidates.map(\.text), ["I lead the platform team.", "I work as a doctor in Belgrade."])
        XCTAssertEqual(candidates.map(\.needsReview), [false, true])
        let sent = await recorder.calls
        XCTAssertEqual(sent, [[
            "I lead the platform team.", lines[0].text,
            "I work as a doctor in Belgrade.", lines[2].text,
        ]], "the same-language item never reaches the embedder")

        let withoutEmbedder = await PersonalLearning.groundedCandidates(
            from: output, utterances: lines, embed: nil, evidence: evidence)
        XCTAssertTrue(withoutEmbedder.isEmpty)
    }

    func testUncertainFactsAreSuggestedNotSaved() {
        var model = PersonalModel()
        let outcome = model.learn([
            PersonalModel.LearningCandidate(
                kind: .fact, text: "I work as a doctor in Belgrade.", quote: "Radim kao inženjer u Beogradu.",
                meetingID: meetingID, dayKey: "2026-10-14",
                evidence: evidence(line("U1", "x")), needsReview: true),
        ], now: Date())
        XCTAssertTrue(outcome.saved.isEmpty)
        XCTAssertEqual(outcome.proposed.first?.status, .proposed)
    }
}

private actor EmbedRecorder {
    private let vectors: [[Float]]
    private(set) var calls: [[String]] = []

    init(vectors: [[Float]]) { self.vectors = vectors }

    func embed(_ texts: [String]) -> [[Float]]? {
        calls.append(texts)
        return vectors
    }
}

final class PersonalModelLearningRulesTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private let meetingID = UUID()

    private func candidate(_ text: String, _ kind: PersonalClaimKind) -> PersonalModel.LearningCandidate {
        PersonalModel.LearningCandidate(
            kind: kind, text: text, quote: "quote: \(text)", meetingID: meetingID, dayKey: "2026-10-14",
            evidence: DreamEvidenceProvenance(
                sources: [DreamEvidenceSource(kind: .meeting, id: meetingID.uuidString, dayKey: "2026-10-14")],
                revision: 3))
    }

    func testFactsAndGoalsAreSavedPreferencesWaitPrinciplesNever() {
        var model = PersonalModel()
        let outcome = model.learn([
            candidate("I live in Belgrade.", .fact),
            candidate("I want to run a marathon next year.", .goal),
            candidate("I prefer written updates.", .preference),
            candidate("Family comes first.", .principle),
        ], now: now)
        XCTAssertEqual(outcome.saved.map(\.text), ["I live in Belgrade.", "I want to run a marathon next year."])
        XCTAssertEqual(outcome.proposed.map(\.text), ["I prefer written updates."])
        XCTAssertEqual(outcome.skipped, 1)
        let saved = model.claims.filter { $0.status == .confirmed }
        XCTAssertTrue(saved.allSatisfy { $0.authority == .learned && $0.evidence != nil && $0.isLearned })
        XCTAssertEqual(model.claims.first { $0.kind == .preference }?.status, .proposed)
    }

    func testDuplicatesForgottenAndDismissedTextAreNotLearnedAgain() throws {
        var model = PersonalModel()
        _ = model.add("I live in Belgrade", kind: .fact, origin: .added, now: now)
        model.learn([candidate("i live in belgrade.", .fact), candidate("I have two kids.", .fact),
                     candidate("I prefer email.", .preference)], now: now)
        let kids = try XCTUnwrap(model.claims.first { $0.text == "I have two kids." })
        let email = try XCTUnwrap(model.claims.first { $0.text == "I prefer email." })
        XCTAssertEqual(model.claims.count, 3)

        model.remove(ids: [kids.id], now: now)
        model.dismiss(id: email.id, now: now)
        XCTAssertEqual(model.tombstones.count, 2)
        let again = model.learn([candidate("I have two kids", .fact), candidate("I prefer email", .preference)], now: now)
        XCTAssertEqual(again.saved.count + again.proposed.count, 0)
        XCTAssertFalse(model.tombstones.contains { $0.key.contains("kids") }, "tombstones keep only a hash")

        // Retraction (the meeting was deleted) leaves no tombstone.
        let learned = model.learn([candidate("I lead the platform team.", .fact)], now: now).saved
        model.retract(ids: Set(learned.map(\.id)))
        XCTAssertEqual(model.tombstones.count, 2)
    }

    func testRewordedKnownItemsAreNotLearnedAgain() {
        var model = PersonalModel()
        _ = model.add("I want a staff engineer role in 2027.", kind: .goal, origin: .added, now: now)
        let outcome = model.learn([
            candidate("I want to become a staff engineer in 2027.", .goal),
            candidate("I work in Belgrade.", .fact),
        ], now: now)
        XCTAssertEqual(outcome.saved.map(\.text), ["I work in Belgrade."])
        XCTAssertFalse(PersonalModel.isNearDuplicate("I live in Belgrade.", "I work in Belgrade."))
    }

    func testReviewKeepAndRestateMoveClaimsOutOfLearning() throws {
        var model = PersonalModel()
        model.learn([candidate("I prefer written updates.", .preference), candidate("I live in Belgrade.", .fact)],
                    now: now)
        let preference = try XCTUnwrap(model.claims.first { $0.kind == .preference })
        let confirmed = try model.confirm(id: preference.id, now: now).get()
        XCTAssertEqual(confirmed.status, .confirmed)
        XCTAssertEqual(confirmed.authority, .confirmed)
        XCTAssertNotNil(confirmed.evidence)

        let fact = try XCTUnwrap(model.claims.first { $0.kind == .fact })
        let kept = try model.keepAsStatement(id: fact.id, now: now).get()
        XCTAssertEqual(kept.authority, .stated)
        XCTAssertNil(kept.evidence)

        model.learn([candidate("I have two kids.", .fact)], now: now)
        let restated = try model.add("I have two kids", kind: .fact, origin: .added, now: now).get()
        XCTAssertEqual(restated.authority, .stated)
        XCTAssertNil(restated.evidence)
        XCTAssertTrue(restated.isLearned)
    }

    func testPruneDropsOldSuggestionsAndTombstones() {
        var model = PersonalModel()
        model.learn([candidate("I prefer email.", .preference), candidate("I have two kids.", .fact)], now: now)
        model.tombstones.append(.init(key: "old", createdAt: now.addingTimeInterval(-PersonalModel.tombstoneLifetime - 1)))
        model.prune(now: now.addingTimeInterval(PersonalModel.proposalLifetime + 1))
        XCTAssertEqual(model.claims.map(\.text), ["I have two kids."])
        XCTAssertTrue(model.tombstones.isEmpty)
    }
}

@MainActor
final class PersonalLearningRetractionTests: XCTestCase {
    private var root: URL!
    private let key = SymmetricKey(data: Data(repeating: 0x2B, count: 32))
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PersonalLearningRetraction-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func candidate(_ text: String, meetingID: UUID, revision: UInt64) -> PersonalModel.LearningCandidate {
        PersonalModel.LearningCandidate(
            kind: .fact, text: text, quote: text, meetingID: meetingID, dayKey: "2026-09-21",
            evidence: DreamEvidenceProvenance(
                sources: [DreamEvidenceSource(kind: .meeting, id: meetingID.uuidString, dayKey: "2026-09-21")],
                revision: revision))
    }

    func testDeletedMeetingRetractsLearnedClaimsButNotStatedOnes() throws {
        let dreamStore = DreamStore(root: root)
        let revision = try dreamStore.evidenceRevision()
        let deletedMeeting = UUID()
        let keptMeeting = UUID()
        let controller = PersonalModelController(
            store: PersonalModelStore(root: root, encryptionKey: { [key] in key }),
            now: { [now] in now }, evidenceCheck: { dreamStore.evidenceCheck() })
        _ = controller.remember("Maya is my manager", origin: .added)
        controller.learn([
            candidate("I live in Belgrade.", meetingID: deletedMeeting, revision: revision),
            candidate("I have two kids.", meetingID: keptMeeting, revision: revision),
        ])
        XCTAssertEqual(controller.usableClaims().count, 3)

        _ = try dreamStore.invalidateEvidence(
            affectedDayKeys: [], affectedMeetingIDs: [deletedMeeting], reportDayKeys: [])
        controller.retractIfLoaded()
        XCTAssertEqual(controller.usableClaims().map(\.text).sorted(), ["I have two kids.", "Maya is my manager"])
        let reopened = PersonalModelController(store: PersonalModelStore(root: root, encryptionKey: { [key] in key }))
        XCTAssertEqual(reopened.currentClaims().count, 2, "retraction is saved, not just filtered")
    }

    func testPendingRevocationWithholdsLearnedClaimsAndScopedQuestionsSkipThem() throws {
        var available = true
        let controller = PersonalModelController(
            store: PersonalModelStore(root: root, encryptionKey: { [key] in key }),
            now: { [now] in now },
            evidenceCheck: { () -> ((DreamEvidenceProvenance) -> Bool)? in
                available ? { _ in false } : nil
            })
        _ = controller.remember("Maya is my manager", origin: .added)
        controller.learn([candidate("I live in Belgrade.", meetingID: UUID(), revision: 1)])

        XCTAssertEqual(controller.usableClaims(includeEvidenceBacked: false).map(\.text), ["Maya is my manager"])
        available = false
        XCTAssertEqual(controller.usableClaims().map(\.text), ["Maya is my manager"])
        XCTAssertEqual(controller.readableClaims()?.map(\.text), ["Maya is my manager"])
        XCTAssertEqual(controller.currentClaims().count, 2, "withheld, not deleted")
        available = true
        XCTAssertEqual(controller.usableClaims().count, 2)
    }

    func testLearnedClaimsAreLabelledForAskAndAgents() throws {
        let controller = PersonalModelController(
            store: PersonalModelStore(root: root, encryptionKey: { [key] in key }), now: { [now] in now })
        let learned = controller.learn([candidate("I live in Belgrade.", meetingID: UUID(), revision: 1)]).saved
        let claim = try XCTUnwrap(learned.first)
        XCTAssertTrue(PersonalContextBuilder.line(for: claim, timeZone: TimeZone(identifier: "UTC")!)
            .hasPrefix("- [fact · learned 2026-09-21]"))
        XCTAssertEqual(PersonalContextProjection.Claim(claim).source, .learnedFromMeeting)

        let gate = PersonalContextAccessGate(root: root)
        try gate.enable()
        var shared = claim
        shared.sharing = .agents
        try gate.writeProjection(PersonalContextProjection(generatedAt: now, claims: [.init(shared)]))
        let report = try PersonalContextTool.report(task: "Where do I live?", kinds: nil, maxItems: nil, gate: gate).get()
        XCTAssertEqual(report.items.first?.authority, "learned")
    }

    func testRunCallsTheModelOnlyWithTheDaysOwnLines() async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let meetingID = UUID()
        try MeetingFixture.write([
            .init(id: meetingID, title: "Weekly sync", startedAt: now, transcriptLines: [
                "I live in Belgrade and I work from home most days.",
                "My salary is confidential, please keep it quiet.",
            ]),
        ], under: root)
        let engine = LearningStubEngine(#"{"items": [{"line": "U1", "kind": "fact", "text": "I live in Belgrade."}]}"#)
        let candidates = try await PersonalLearning.run(
            day: now, storageRoot: root, known: [], revision: 4, engine: engine, calendar: calendar)
        XCTAssertEqual(candidates.map(\.text), ["I live in Belgrade."])
        XCTAssertEqual(candidates.first?.origin, .learned(meetingID: meetingID, dayKey: "2026-09-21"))
        XCTAssertEqual(engine.prompts.count, 1)
        XCTAssertTrue(engine.prompts[0].contains("U1 (Weekly sync): I live in Belgrade"))
        XCTAssertFalse(engine.prompts[0].contains("salary"), "the other speaker's line is never sent")

        let quiet = LearningStubEngine("{}")
        let none = try await PersonalLearning.run(
            day: now.addingTimeInterval(86_400 * 3), storageRoot: root, known: [], revision: 4,
            engine: quiet, calendar: calendar)
        XCTAssertTrue(none.isEmpty)
        XCTAssertTrue(quiet.prompts.isEmpty, "no lines, no model call")
    }
}

final class PersonalLearningTypedAndWorkTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func burst(_ prompts: [String], start: Date) -> CodingAgentBurst {
        CodingAgentBurst(agent: .claudeCode, sessionID: "s", title: "t", project: "LokalBot", branch: nil,
                         start: start, end: start.addingTimeInterval(60), activeDuration: 60,
                         prompts: prompts, promptCount: prompts.count, finalReply: nil, changedFiles: [],
                         changedFileCount: 0, actions: [], pullRequests: [], toolCallCount: 0)
    }

    func testTypedLinesSkipScheduledRunsOtherDaysAndRememberMessages() {
        let conversation = Conversation(messages: [
            ChatMessage(role: .user, text: "I'm preparing for my Berlin interview, what did we discuss?", createdAt: now),
            ChatMessage(role: .assistant, text: "You discussed …", createdAt: now),
            ChatMessage(role: .user, text: "Remember I live in Belgrade", createdAt: now),
            ChatMessage(role: .assistant, text: "I live in Belgrade", createdAt: now, rememberReceipt: .init(claimID: UUID())),
            ChatMessage(role: .user, text: "I always write tests first, what's my next task?",
                        createdAt: now.addingTimeInterval(-3 * 86_400)),
        ])
        let lines = PersonalLearning.typedLines(
            bursts: [
                burst(["I prefer small PRs, split this change please"], start: now),
                burst(["Scheduled task: nightly summary"], start: now),
            ],
            conversations: [conversation], day: now, calendar: calendar)
        XCTAssertEqual(lines.map(\.text), [
            "I prefer small PRs, split this change please",
            "I'm preparing for my Berlin interview, what did we discuss?",
        ])
        XCTAssertEqual(lines.map(\.label), ["typed to Claude Code", "typed in Ask"])
        XCTAssertEqual(lines.last?.source, .ask(conversationID: conversation.id))
    }

    func testTypedItemsAlwaysWaitForReviewAndCarryTheirSource() async throws {
        let conversationID = UUID()
        let lines = [
            PersonalLearning.Utterance(handle: "U1", source: .typed(.codingAgent(name: "Claude Code")),
                                       label: "typed to Claude Code", dayKey: "2026-09-21",
                                       text: "I prefer small pull requests that are easy to review"),
            PersonalLearning.Utterance(handle: "U2", source: .typed(.ask(conversationID: conversationID)),
                                       label: "typed in Ask", dayKey: "2026-09-21",
                                       text: "I'm moving to Lisbon next spring with my family, what should I plan?"),
        ]
        let output = """
            {"items": [
              {"line": "U1", "kind": "preference", "text": "I prefer small pull requests."},
              {"line": "U2", "kind": "fact", "text": "I'm moving to Lisbon with my family."}
            ]}
            """
        let candidates = await PersonalLearning.groundedCandidates(from: output, utterances: lines, embed: nil) {
            PersonalLearning.provenance(for: $0, revision: 3)
        }
        XCTAssertEqual(candidates.map(\.needsReview), [true, true])
        XCTAssertEqual(candidates.first?.evidence?.sources.map(\.kind), [.screenDay])
        XCTAssertNil(candidates.last?.evidence, "an Ask question retracts with its conversation instead")

        var model = PersonalModel()
        let outcome = model.learn(candidates, now: now)
        XCTAssertTrue(outcome.saved.isEmpty)
        XCTAssertEqual(outcome.proposed.count, 2)
        _ = try model.confirm(id: XCTUnwrap(outcome.proposed.last?.id), now: now).get()

        model.retract(learnedFromConversation: UUID())
        XCTAssertEqual(model.claims.count, 2)
        model.retract(learnedFromConversation: conversationID)
        XCTAssertEqual(model.claims.map(\.text), ["I prefer small pull requests."])
    }

    func testUtterancesCapTypedLinesAndLabelThem() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PersonalLearningTyped-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try MeetingFixture.write([
            .init(title: "Weekly sync", startedAt: now, transcriptLines: ["I live in Belgrade and I work from home most days."]),
        ], under: root)
        var typed: [PersonalLearning.TypedLine] = []
        for index in 0..<30 {
            typed.append(.init(source: .codingAgent(name: "Codex"), text: "I want feature number \(index) done my way please"))
        }
        let lines = try PersonalLearning.utterances(day: now, storageRoot: root, typed: typed, calendar: calendar)
        XCTAssertEqual(lines.filter { $0.meetingID != nil }.count, 1, "meetings are never crowded out")
        XCTAssertEqual(lines.filter { $0.meetingID == nil }.count, PersonalLearning.maxTypedUtterances)
        let prompt = PersonalLearning.prompt(utterances: lines, known: [])
        XCTAssertTrue(prompt.contains("(typed to Codex): I want feature number"))
    }

    private func memory(goalFirstDay: String, lastReinforced: String, provenance: DreamEvidenceProvenance?) -> DreamMemory {
        var memory = DreamMemory(updatedAt: now)
        memory.workGoals = [DreamMemory.Goal(text: "Ship LokalBot 1.0 this year", horizon: "this year",
                                             lastReinforcedDay: lastReinforced, provenance: provenance)]
        memory.activeProjects = [DreamMemory.Project(name: "Atlas billing", status: "in review",
                                                     lastActiveDay: lastReinforced, provenance: provenance)]
        return memory
    }

    func testWorkMemoryKeptForTwoWeeksBecomesSuggestions() {
        let provenance = DreamEvidenceProvenance(
            sources: [DreamEvidenceSource(kind: .meeting, id: UUID().uuidString, dayKey: "2026-10-01")], revision: 2)
        let first = WorkMemoryPromotion.evaluate(
            memory: memory(goalFirstDay: "2026-10-01", lastReinforced: "2026-10-01", provenance: provenance),
            sightings: [], dayKey: "2026-10-01", calendar: calendar)
        XCTAssertTrue(first.candidates.isEmpty)
        XCTAssertEqual(first.sightings.map(\.firstDayKey), ["2026-10-01", "2026-10-01"])

        let early = WorkMemoryPromotion.evaluate(
            memory: memory(goalFirstDay: "", lastReinforced: "2026-10-14", provenance: provenance),
            sightings: first.sightings, dayKey: "2026-10-14", calendar: calendar)
        XCTAssertTrue(early.candidates.isEmpty, "13 days is not enough")

        let due = WorkMemoryPromotion.evaluate(
            memory: memory(goalFirstDay: "", lastReinforced: "2026-10-13", provenance: provenance),
            sightings: first.sightings, dayKey: "2026-10-15", calendar: calendar)
        XCTAssertEqual(due.candidates.map(\.text), ["Ship LokalBot 1.0 this year", "I work on Atlas billing."])
        XCTAssertEqual(due.candidates.map(\.kind), [.goal, .fact])
        XCTAssertTrue(due.candidates.allSatisfy { $0.needsReview && $0.origin == .workMemory(dayKey: "2026-10-01") })

        var model = PersonalModel()
        let outcome = model.learn(due.candidates, now: now)
        XCTAssertEqual(outcome.proposed.count, 2)
        XCTAssertTrue(outcome.saved.isEmpty)
    }

    func testStaleOrUnattributedWorkMemoryIsNotPromotedAndGoneItemsAreForgotten() {
        let sightings = [PersonalModel.WorkSighting(key: "goal:" + PersonalModel.tombstoneKey("Ship LokalBot 1.0 this year"),
                                                    firstDayKey: "2026-09-01")]
        let stale = WorkMemoryPromotion.evaluate(
            memory: memory(goalFirstDay: "", lastReinforced: "2026-09-20",
                           provenance: DreamEvidenceProvenance(sources: [], revision: 1)),
            sightings: sightings, dayKey: "2026-10-15", calendar: calendar)
        XCTAssertTrue(stale.candidates.isEmpty, "not seen in the last week")

        let legacy = WorkMemoryPromotion.evaluate(
            memory: memory(goalFirstDay: "", lastReinforced: "2026-10-14", provenance: nil),
            sightings: sightings, dayKey: "2026-10-15", calendar: calendar)
        XCTAssertTrue(legacy.candidates.isEmpty, "no provenance means it could never retract")

        let gone = WorkMemoryPromotion.evaluate(
            memory: DreamMemory(updatedAt: now), sightings: sightings, dayKey: "2026-10-15", calendar: calendar)
        XCTAssertTrue(gone.sightings.isEmpty)
    }
}

private final class LearningStubEngine: TextEngine {
    private let output: String
    private(set) var prompts: [String] = []

    init(_ output: String) { self.output = output }

    var displayName: String { "Learning stub" }

    func generate(system: String, prompt: String, context: [String]) async throws -> String {
        prompts.append(prompt)
        return output
    }
}
