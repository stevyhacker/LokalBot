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

    func testPersonalObligationsKeepTheCitedOwner() {
        for text in ["I have to review the change.", "I still have to review the change.",
                     "I need to review it.", "I must review it.", "I think I still have to review it.",
                     "So, I think I need to review it."] {
            XCTAssertTrue(OutcomeEvidencePolicy.isCommitment(text), text)
            XCTAssertEqual(resolve(text).resolution, .other, text)
        }
    }

    func testObligationRecognitionRefusesNegationQuestionsAndReportedSpeech() {
        for text in ["I don't have to review it.", "I have to not review it.", "I no longer have to review it.",
                     "I had to review it.", "Do I have to review it?", "I think you have to review it.",
                     "I think I might have to review it.", "We need to review it.", "Yesterday I said I have to review it.",
                     "When I have to review it, the build breaks.", "I should have reviewed it."] {
            XCTAssertFalse(OutcomeEvidencePolicy.isCommitment(text), text)
            XCTAssertEqual(resolve(text).resolution, .unresolved, text)
        }
    }

    /// A condition says when a task happens, not whose it is. In run-on
    /// speech an "if" from a neighboring clause used to cost the speaker a
    /// plain "I'll" (2026-10-05).
    func testAConditionOrAHedgeDoesNotChangeWhoseTaskItIs() {
        for text in ["If approved, I have to review it.", "I need to review it unless it is cancelled.",
                     "I plan to send the draft if approved.", "If approved, I do plan to send the draft.",
                     "Maybe I will send it.", "If I have time, I will send it.", "I will send it if approved.",
                     "Those can be simpler if we update the plan but I'll ping Mira to get that resolved."] {
            XCTAssertTrue(OutcomeEvidencePolicy.isCommitment(text), text)
            XCTAssertEqual(resolve(text).resolution, .other, text)
        }
        for text in ["If approved, I will send it.", "I will send it if approved."] {
            XCTAssertEqual(resolve(text, quote: "I will send it").resolution, .other, text)
        }
    }

    func testPersonalPlansStillRejectNegationReportsAndCollectiveOwnership() {
        for text in ["On my side, I might send the draft.", "I do not plan to send it.", "I don't plan to send it.",
                     "I plan to not send it.", "I'm planning to never send it.", "I intend to no longer send it.",
                     "I plan to send it?", "Yesterday I said I plan to send it.",
                     "On my side, I said I'll send it.", "On my side, we plan to send it.", "I hope to send it."] {
            XCTAssertFalse(OutcomeEvidencePolicy.isCommitment(text), text)
            XCTAssertEqual(resolve(text).resolution, .unresolved, text)
        }
        for text in ["Yesterday I said I plan to send it.", "I plan to send it?"] {
            XCTAssertEqual(resolve(text, quote: "I plan to send it").rejectionReason, .unsupportedCommitment, text)
        }
    }

    func testOffersAndStatedWishesAreTheSpeakersOwn() {
        for text in ["I can send you the numbers tomorrow morning.", "I would like to send it.", "I could share that benchmark.",
                     "Let me do a bit more work on it.", "I have some comments from you to resolve.",
                     "Alice and I are going to send it."] {
            XCTAssertTrue(OutcomeEvidencePolicy.isCommitment(text), text)
            XCTAssertEqual(resolve(text).resolution, .other, text)
        }
        for text in ["I have nothing to add.", "I have a question to ask.", "Let me know when it is merged.",
                     "I'll need you to send the report."] {
            XCTAssertFalse(OutcomeEvidencePolicy.isCommitment(text), text)
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

    func testQuestionsNegationPastReportsAndCollectivePlansStayUnclear() {
        for text in ["I can do that?", "I will not send it.", "I will never do that.",
                     "I said I will send it.", "We are going to send it."] {
            let result = resolve(text)
            XCTAssertEqual(result.resolution, .unresolved, text)
            XCTAssertEqual(result.rejectionReason, .unsupportedCommitment, text)
        }
    }

    func testShortQuotesCannotRemoveSurroundingReportsOrQuestions() {
        for text in ["Yesterday I said I will send it.", "I will send it?"] {
            XCTAssertEqual(resolve(text, quote: "I will send it").rejectionReason, .unsupportedCommitment, text)
        }
    }

    /// The model tidies what it copies. A quote without the stumble still
    /// points at the words that were said.
    func testATidiedQuoteStillFindsTheSpokenCommitment() {
        let spoken = "The export change is something I I have to update and and confirm."
        XCTAssertEqual(resolve(spoken, quote: "the export change is something I have to update and confirm").resolution, .other)
        XCTAssertEqual(resolve(spoken, quote: "something I have to rewrite").rejectionReason, .quoteNotFound)
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
