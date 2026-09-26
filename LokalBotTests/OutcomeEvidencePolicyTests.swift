import XCTest
@testable import LokalBot

final class OutcomeEvidencePolicyTests: XCTestCase {
    private func source(_ text: String, identity: SpeakerAttribution.Identity = .other) -> Transcript.Segment {
        .init(start: 10, end: 15, speaker: "them 1", text: text,
              attribution: .init(source: .system, identity: identity, method: .diarization))
    }
    private var roster: [String: Transcript.SpeakerDescriptor] {
        ["them 1": .init(id: "them 1", name: "Alice Smith", identity: .other),
         "local 1": .init(id: "local 1", name: "Stevan Jones", identity: .user)]
    }
    private func resolve(_ text: String, quote: String? = nil, owner: String = "them 1",
                         basis: String = "commitment", roster: [String: Transcript.SpeakerDescriptor]? = nil) -> OutcomeAttribution {
        OutcomeEvidencePolicy.resolve(speakerID: owner, basis: basis, quote: quote ?? text,
            sources: [source(text)], roster: roster ?? self.roster)
    }

    func testConversationalAcceptancesAndDiscourseMarkersPreserveTheCitedRemoteOwner() {
        for text in ["Yeah, I can do that.", "Sure, I'll handle it.", "Okay. I will send it.",
                     "And I'll be doing this.", "So, I am going to finish the report.", "Yes, I can take that on."] {
            let result = resolve(text)
            XCTAssertEqual(result.resolution, .other, text)
            XCTAssertEqual(result.speakerID, "them 1", text)
            XCTAssertNil(result.rejectionReason, text)
        }
    }

    func testPersonalPreamblesAndPlansPreserveTheCitedOwner() {
        for text in ["Yeah, so on my side, I'll try to keep up the shipping cadence.",
                     "I do plan to take on a bit more.", "I plan to send the draft.",
                     "For my part, I intend to review it.", "From my side, I do intend to finish it.",
                     "On my end, I'm planning to send the draft.", "I am planning to review it.",
                     "As for me, I'm intending to finish it.", "I am intending to review it."] {
            let result = resolve(text)
            XCTAssertEqual(result.resolution, .other, text)
            XCTAssertEqual(result.speakerID, "them 1", text)
            XCTAssertNil(result.rejectionReason, text)
        }
    }

    func testPersonalPlansStillRejectConditionsNegationReportsAndCollectiveOwnership() {
        for text in ["On my side, I might send the draft.", "I plan to send the draft if approved.",
                     "If approved, I do plan to send the draft.", "Maybe I plan to send it.",
                     "I do not plan to send it.", "I don't plan to send it.", "I plan to not send it.",
                     "I'm planning to never send it.", "I intend to no longer send it.",
                     "I plan to send it?", "Yesterday I said I plan to send it.",
                     "On my side, I said I'll send it.", "On my side, we plan to send it.",
                     "I hope to send it.", "I would like to send it."] {
            XCTAssertFalse(OutcomeEvidencePolicy.isCommitment(text), text)
            XCTAssertEqual(resolve(text).resolution, .unresolved, text)
        }
        for text in ["If approved, I plan to send it.", "Yesterday I said I plan to send it.",
                     "I plan to send it if approved.", "I plan to send it?"] {
            XCTAssertEqual(resolve(text, quote: "I plan to send it").rejectionReason, .unsupportedCommitment, text)
        }
    }

    func testPersonalPreamblesKeepBareAcceptancesAndConversationManagementOutOfStandaloneTasks() {
        XCTAssertTrue(OutcomeEvidencePolicy.isBareAcceptance("On my side, I can do that."))
        for text in ["On my side, I'll be brief.", "For my part, I plan to be brief.",
                     "I'm planning to be more specific."] {
            XCTAssertTrue(OutcomeEvidencePolicy.isConversationManagement(text), text)
            XCTAssertFalse(OutcomeEvidencePolicy.isCommitment(text), text)
        }
    }

    func testACommitmentLaterInTheSegmentCanUseItsOwnCompleteSentence() {
        let result = resolve("That was the first step. And I'll be doing this.", quote: "And I'll be doing this.")
        XCTAssertEqual(result.resolution, .other)
    }

    func testACompleteCommitmentDoesNotInheritTheFollowingQuestionOrCondition() {
        XCTAssertEqual(resolve("Yeah, I can do that. Could someone send the document?",
            quote: "Yeah, I can do that.").resolution, .other)
        XCTAssertEqual(resolve("Alice will send it. If needed, Bob can review it.",
            quote: "Alice will send it.", basis: "assignment").resolution, .other)
    }

    func testQuestionsNegationHypotheticalsPastReportsAndCollectivePlansStayUnclear() {
        for text in ["I can do that?", "I will not send it.", "I will never do that.", "Maybe I will send it.",
                     "If I have time, I will send it.", "I will send it if approved.",
                     "I said I will send it.", "We are going to send it.", "Alice and I are going to send it."] {
            let result = resolve(text)
            XCTAssertEqual(result.resolution, .unresolved, text)
            XCTAssertEqual(result.rejectionReason, .unsupportedCommitment, text)
        }
    }

    func testShortQuotesCannotRemoveSurroundingConditionsOrQuestions() {
        for text in ["If approved, I will send it.", "I will send it if approved.",
                     "Yesterday I said I will send it.", "I will send it?"] {
            XCTAssertEqual(resolve(text, quote: "I will send it").rejectionReason, .unsupportedCommitment, text)
        }
    }

    func testAcceptanceStillRequiresIndependentIdentityAndTheCorrectSpeaker() {
        XCTAssertEqual(resolve("Yeah, I can do that.", owner: "local 1").rejectionReason, .speakerMismatch)
        var roster = roster
        roster["them 1"]?.identity = .unresolved
        XCTAssertEqual(resolve("Yeah, I can do that.", roster: roster).rejectionReason, .unconfirmedIdentity)
    }

    func testUniqueFirstNameRequestsResolveToTheConfirmedUserAndRemainRequests() {
        for text in ["Stevan, could you send it?", "Okay, Stevan, please send it.",
                     "Could you, Stevan, send it?", "Can Stevan send it?"] {
            let result = resolve(text, owner: "local 1", basis: "request")
            XCTAssertEqual(result.resolution, .user, text)
            XCTAssertEqual(result.basis, .request, text)
        }
    }

    func testAmbiguousFirstNameAndUnansweredPronounsCannotSelectAnOwner() {
        var roster = roster
        roster["them 2"] = .init(id: "them 2", name: "Stevan Brown", identity: .other)
        XCTAssertEqual(resolve("Stevan, please send it.", owner: "local 1", basis: "request", roster: roster).resolution, .unresolved)
        XCTAssertEqual(resolve("Stevan Jones, please send it.", owner: "local 1", basis: "request", roster: roster).resolution, .user)
        XCTAssertEqual(resolve("Can you send it?", owner: "local 1", basis: "request").resolution, .unresolved)
        XCTAssertEqual(resolve("Alice said Stevan will send it.", owner: "local 1", basis: "assignment").resolution, .unresolved)
    }

    func testNamedAssignmentsAcceptPreamblesButRejectNegation() {
        XCTAssertEqual(resolve("So, Alice will send it.", basis: "assignment").resolution, .other)
        XCTAssertEqual(resolve("Alice will not send it.", basis: "assignment").resolution, .unresolved)
        XCTAssertEqual(resolve("If approved, Alice will send it.", quote: "Alice will send it.", basis: "assignment").resolution, .unresolved)
        XCTAssertEqual(resolve("Alice will send it if approved.", quote: "Alice will send it", basis: "assignment").resolution, .unresolved)
    }

    func testRejectionReasonsPersistWithoutSavingAnInventedQuote() throws {
        let rejected = resolve("I will send it.", quote: "invented private-looking material")
        XCTAssertEqual(rejected.rejectionReason, .quoteNotFound)
        let data = try JSONEncoder().encode(rejected)
        XCTAssertEqual(try JSONDecoder().decode(OutcomeAttribution.self, from: data), rejected)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("invented"))
        let legacy = try JSONDecoder().decode(OutcomeAttribution.self, from: Data(#"{"resolution":"unresolved","basis":"unclear"}"#.utf8))
        XCTAssertNil(legacy.rejectionReason)
    }
}
