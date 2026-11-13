import XCTest
@testable import LokalBot

/// Ownership of action items in speech as it is actually transcribed: run-on
/// clauses, stumbled words, and sentences cut across rows. Every transcript
/// here is invented, but shaped like the recordings that kept the user's own
/// commitments under "Owner unclear" (2026-10-05).
final class RunOnSpeechOwnershipTests: XCTestCase {
    private func microphone(_ start: Double, _ text: String, length: Double = 4) -> Transcript.Segment {
        .init(start: start, end: start + length, speaker: "local 1", text: text,
              attribution: .init(source: .microphone, identity: .user, method: .diarization))
    }

    private func remote(_ start: Double, _ speaker: String, _ text: String, length: Double = 4) -> Transcript.Segment {
        .init(start: start, end: start + length, speaker: speaker, text: text,
              attribution: .init(source: .system, identity: .other, method: .diarization))
    }

    private func action(_ source: String, _ text: String, owner: String = "source", basis: String = "commitment",
                        context: [String] = [], quote: String = "") -> [String: Any] {
        ["text": text, "source": source, "context": context, "owner": owner, "basis": basis, "quote": quote,
         "due": "", "importance": 3]
    }

    private func validate(_ transcript: Transcript, _ actions: [[String: Any]]) throws -> MeetingNotesEvidence.Validated {
        let evidence = MeetingNotesEvidence(transcript: transcript)
        let output = String(decoding: try JSONSerialization.data(withJSONObject: [
            "notes": [[String: Any]](), "actions": actions, "has_more": false] as [String: Any]), as: UTF8.self)
        return evidence.validate(output, units: evidence.units, template: .meeting, meetingID: UUID(),
                                 maximumNotes: 12, maximumActions: 10)
    }

    /// A standup update with no punctuation, cut by the diarizer mid-sentence.
    private var standup: Transcript {
        Transcript(segments: [
            microphone(0, "so it just video is not working for me right now. Anyway, so these."),
            microphone(5, "The", length: 0.1),
            microphone(5.2, "export change is something I I have to update"),
            microphone(9.4, "and confirm the the plan is still"),
            microphone(13.6, "true because it was initially written"),
            microphone(17.8, "before the last merges so"),
            microphone(22, "I would say it needs a bit of a revisit right now the nightly export is a separate queue"),
            microphone(26.2, "from the the main queue so I think"),
            microphone(30.4, "those can be a bit more simplified if we update the plan but I'll ping you Mira and Jonas "
                + "to to get that resolved in chat."),
        ], engine: "fixture")
    }

    // MARK: - The reported meeting

    func testCommitmentBuriedMidSentenceIsMineHoweverTheModelQuotesIt() throws {
        let task = "Update the export change and confirm the plan is still true after the last merges"
        // The sentence as transcribed, over the rows it was cut into.
        let spoken = "export change is something I I have to update and confirm the the plan is still true because it was initially written"
        let answers = [
            // Tidied, and run over the row cut: the answer that was rejected.
            action("s3", task, quote: "export change is something I have to update and confirm the plan is still true"),
            action("s3", task, quote: spoken),
            action("s3", task),
            action("s3", task, owner: "unknown", basis: "unclear"),
            action("s3", task, context: ["s4", "s5"], quote: "I have to update"),
            // A later row of the same sentence as source.
            action("s4", task, context: ["s3"]),
        ]
        for raw in answers {
            let result = try validate(standup, [raw])
            let item = try XCTUnwrap(result.outcomes.actionItems.first, "\(raw)")
            XCTAssertTrue(result.rejected.isEmpty, "\(raw)")
            XCTAssertTrue(item.isForUser, "\(raw)")
            XCTAssertEqual(item.owner, "Me")
            XCTAssertEqual(item.attribution?.basis, .commitment)
            XCTAssertEqual(item.attribution?.quote, spoken, "The saved quote is what was said, not the model's version of it")
            XCTAssertEqual(item.citations.first?.segmentID, standup.segmentID(at: 2))
        }
    }

    func testCommitmentAfterAnUnrelatedIfAndCanIsMine() throws {
        let task = "Ping Mira and Jonas in chat to resolve the plan simplifications"
        let row = standup.segments[8].text
        for quote in ["", row, "I'll ping you Mira and Jonas to get that resolved in chat", "I'll ping you Mira and Jonas"] {
            for (owner, basis) in [("source", "commitment"), ("unknown", "unclear")] {
                let result = try validate(standup, [action("s9", task, owner: owner, basis: basis, quote: quote)])
                let item = try XCTUnwrap(result.outcomes.actionItems.first, quote)
                XCTAssertTrue(result.rejected.isEmpty, quote)
                XCTAssertTrue(item.isForUser, "quote=\(quote) owner=\(owner)")
                XCTAssertEqual(item.attribution?.quote, row)
            }
        }
    }

    func testBothCommitmentsAreListedForTheModelAndNothingElseIs() {
        let evidence = MeetingNotesEvidence(transcript: standup)
        XCTAssertEqual(evidence.units.filter(\.isUserCommitment).map(\.source), ["s3", "s9"])
        XCTAssertTrue(MeetingNotesGenerator.prompt(units: evidence.units, roster: evidence.roster)
            .contains("Explicit user commitments: s3, s9."))
    }

    // MARK: - Sentences cut into rows

    /// Each pause became its own row, with a period the speaker never said.
    private var fragments: Transcript {
        Transcript(segments: [
            remote(0, "them 1", "So that's like also a priority for me for next week."),
            microphone(5, "Yeah, so.", length: 0.8),
            microphone(6, "My side, I'll.", length: 0.8),
            microphone(7, "Try to.", length: 0.6),
            microphone(8, "Update the tickets to the.", length: 1.5),
            microphone(10, "New product.", length: 1),
            microphone(11.5, "Direction.", length: 0.8),
            microphone(13, "Also.", length: 0.8),
            microphone(14, "Try to.", length: 0.8),
            microphone(15, "Push forward with my.", length: 1.5),
            microphone(17, "Part of the tickets too, and.", length: 2),
        ], engine: "fixture")
    }

    func testAnUndertakingSpreadOverFragmentsIsMine() throws {
        let task = "Update the tickets to the new product direction"
        for raw in [action("s6", task, context: ["s3", "s4"]),
                    action("s6", task, owner: "unknown", basis: "unclear", context: ["s3", "s4"]),
                    action("s5", task),
                    action("s5", task, owner: "unknown", basis: "unclear")] {
            let result = try validate(fragments, [raw])
            XCTAssertTrue(try XCTUnwrap(result.outcomes.actionItems.first, "\(raw)").isForUser, "\(raw)")
            XCTAssertEqual(result.outcomes.actionItems.first?.attribution?.quote,
                           "My side, I'll. Try to. Update the tickets to the. New product.")
        }
    }

    func testAnUncitedUndertakingOwnsOnlyATaskItIsAbout() throws {
        // The model cited a fragment of the user's sentence for something else.
        let result = try validate(fragments, [action("s5", "Define payment models and set a timeline", owner: "unknown", basis: "unclear")])
        XCTAssertTrue(try XCTUnwrap(result.outcomes.actionItems.first).ownershipIsUnclear)
    }

    func testAnEarlierIllCarriesAcrossFragmentsOnlyOnTheModelsClaim() throws {
        let task = "Push forward on my part of the tickets"
        let claimed = try validate(fragments, [action("s11", task, context: ["s9", "s10"])])
        XCTAssertTrue(try XCTUnwrap(claimed.outcomes.actionItems.first).isForUser)
        XCTAssertEqual(claimed.outcomes.actionItems.first?.attribution?.quote,
                       "My side, I'll. Try to. Update the tickets to the. New product.")

        let unclaimed = try validate(fragments, [action("s11", task, owner: "unknown", basis: "unclear", context: ["s9", "s10"])])
        let item = try XCTUnwrap(unclaimed.outcomes.actionItems.first)
        XCTAssertTrue(item.ownershipIsUnclear)
        XCTAssertTrue(item.isLikelyUserAction)

        // Once someone else is mentioned, the fragments may be about them.
        var others = fragments
        others.segments[7].text = "And you."
        let handedOver = try validate(others, [action("s11", task, context: ["s9", "s10"])])
        XCTAssertTrue(handedOver.outcomes.userActionItems.isEmpty)
    }

    func testTextNobodyCouldHaveSaidDoesNotEndATurn() throws {
        // A recognizer echoing its vocabulary hint between two rows.
        let transcript = Transcript(segments: [
            microphone(0, "The report is something I have to update"),
            remote(2, "them", "Dana, Mira, Jonas, Product, Export, Queue, Nightly.", length: 0.4),
            microphone(4.2, "and send to the whole team."),
        ], engine: "fixture")
        let result = try validate(transcript, [action("s3", "Send the report to the whole team", owner: "unknown", basis: "unclear")])
        XCTAssertTrue(try XCTUnwrap(result.outcomes.actionItems.first).isForUser)
    }

    // MARK: - Someone else's work in my own speech

    func testWhatIAskOfOthersOrSayOfUsIsNotMine() throws {
        let cases: [([String], String)] = [
            (["Dropped a question in the channel, so when you have time, just check it out."], "Check the question in the channel"),
            (["We can like try to.", "Deploy the backend.", "Soon."], "Deploy the backend soon"),
            (["For this, I'm looking forward to your comments. I think it should be in good shape now."], "Review the change and comment"),
            (["I think Dana will send the summary."], "Send the summary"),
            (["I'll need you to send the report."], "Send the report"),
            (["I'm wondering if I should focus on anything in particular for the demo."], "Focus on the demo"),
        ]
        for (rows, task) in cases {
            let transcript = Transcript(segments: rows.enumerated().map { microphone(Double($0.offset) * 2, $0.element, length: 1.8) },
                                        engine: "fixture")
            for (owner, basis) in [("source", "commitment"), ("unknown", "unclear")] {
                let result = try validate(transcript, [action("s\(rows.count == 1 ? 1 : 2)", task, owner: owner, basis: basis,
                                                              context: rows.count == 1 ? [] : ["s1"])])
                XCTAssertTrue(result.outcomes.userActionItems.isEmpty, "\(rows) \(basis)")
            }
        }
    }

    func testMyTaskAndTheirsInOneBreathAreToldApartByTheTask() throws {
        let transcript = Transcript(segments: [
            microphone(0, "I'll write the release notes and Dana will handle the rollout on Thursday."),
        ], engine: "fixture")
        let result = try validate(transcript, [action("s1", "Write the release notes"), action("s1", "Handle the rollout on Thursday")])
        XCTAssertEqual(result.outcomes.actionItems.map(\.isForUser), [true, false])
        XCTAssertEqual(result.outcomes.actionItems[1].attribution?.rejectionReason, .ambiguousQuote)
        // A passive or a question names no rival.
        for text in ["The plan can be simplified and I'll write the release notes.",
                     "I'll have the guide ready today. So what do we need to change for the rollout?"] {
            let single = try validate(Transcript(segments: [microphone(0, text)], engine: "fixture"),
                                      [action("s1", "Prepare the release notes and the rollout guide")])
            XCTAssertTrue(try XCTUnwrap(single.outcomes.actionItems.first).isForUser, text)
        }
    }

    // MARK: - Replies

    func testAReplyTakesOnWhatWasAsked() throws {
        let transcript = Transcript(segments: [
            remote(0, "them 5", "Maybe if we could do it by the end of this week, that'd be good. So we can have our new."),
            remote(4.2, "them 5", "A new engine running with the new contracts."),
            microphone(9, "I think I can.", length: 1.2),
            remote(9.1, "them 5", "Okay.", length: 0.6),
            microphone(10.5, "Do that, but I'd prefer if we merged the other change first."),
        ], engine: "fixture")
        let task = "Deploy the new contracts for the engine run by the end of the week"
        for raw in [action("s1", task, owner: "unknown", context: ["s3", "s5"]),
                    action("s1", task, owner: "unknown", basis: "unclear", context: ["s3", "s5"]),
                    action("s3", task, context: ["s1"])] {
            let item = try XCTUnwrap(try validate(transcript, [raw]).outcomes.actionItems.first, "\(raw)")
            XCTAssertTrue(item.isForUser, "\(raw)")
            XCTAssertEqual(item.citations.first?.segmentID, transcript.segmentID(at: 2))
        }
    }

    func testTwoPeopleUndertakingNeedTheModelsQuoteToChoose() throws {
        let transcript = Transcript(segments: [
            remote(0, "them 5", "Is there an option to stack it when you already created the change? So maybe I'll just do that."),
            remote(4.2, "them 5", "Like the storage part as a first request, and then this one on top of that."),
            microphone(9, "Yeah, I can do that.", length: 1.5),
        ], engine: "fixture")
        let task = "Stack the change with the storage part as the first request"
        let unquoted = try validate(transcript, [action("s1", task, owner: "unknown", context: ["s2", "s3"])])
        XCTAssertEqual(unquoted.outcomes.actionItems.first?.attribution?.rejectionReason, .ambiguousQuote)
        XCTAssertEqual(unquoted.rejected.first?.reason, "ambiguous_ownership_evidence", "The model is asked once more")
        let quoted = try validate(transcript, [action("s1", task, owner: "unknown", context: ["s2", "s3"], quote: "Yeah, I can do that.")])
        XCTAssertTrue(try XCTUnwrap(quoted.outcomes.actionItems.first).isForUser)
    }

    // MARK: - Other speakers

    func testTheCitedVoiceOwnsItsUndertakingWhateverSpeakerTheModelNames() throws {
        let transcript = Transcript(segments: [
            microphone(0, "How is the cancel flow going?"),
            remote(5, "them 3", "almost have it ready. I need to polish it a bit and send the change, but yeah, it should be ready to review very"),
            remote(10, "them 2", "Sounds good."),
        ], engine: "fixture")
        let evidence = MeetingNotesEvidence(transcript: transcript)
        let user = try XCTUnwrap(evidence.speakers.first { $0.value.identity == .user }?.key)
        let other = try XCTUnwrap(evidence.speakers.first { $0.value.id == "them 2" }?.key)
        for owner in ["source", "unknown", user, other] {
            let result = try validate(transcript, [action("s2", "Polish the cancel flow and send the change for review", owner: owner)])
            let item = try XCTUnwrap(result.outcomes.actionItems.first, owner)
            XCTAssertEqual(item.attribution?.resolution, .other, owner)
            XCTAssertEqual(item.attribution?.speakerID, "them 3", owner)
            XCTAssertFalse(item.isForUser, "Another participant's first person is never the user's")
        }
        // A named owner is overruled only for the task the cited voice took on.
        let unrelated = try validate(transcript, [action("s2", "Book the offsite venue", owner: user)])
        XCTAssertTrue(try XCTUnwrap(unrelated.outcomes.actionItems.first).ownershipIsUnclear)
    }

    func testAJointUndertakingBelongsToTheSpeakerWhoSaidIt() throws {
        let transcript = Transcript(segments: [
            remote(0, "them 1", "And Dana and I will be together in person tomorrow to start to write the cases for the optimizer."),
        ], engine: "fixture")
        let result = try validate(transcript, [action("s1", "Work with Dana tomorrow to start writing cases for the optimizer",
                                                      owner: "unknown", basis: "unclear")])
        XCTAssertEqual(result.outcomes.actionItems.first?.attribution?.resolution, .other)
    }

    // MARK: - Not tasks

    func testRemarksAboutTheConversationAreNotTasks() throws {
        let transcript = Transcript(segments: [
            microphone(0, "I'm going to be honest with you."),
            microphone(5, "I'll share my screen, and then I have to say the numbers look good."),
        ], engine: "fixture")
        let result = try validate(transcript, [action("s1", "Be honest with the other person"), action("s2", "Share the screen")])
        XCTAssertTrue(result.outcomes.userActionItems.isEmpty)
        XCTAssertEqual(result.rejected.first?.reason, "conversation_management")
        XCTAssertTrue(MeetingNotesEvidence(transcript: transcript).units.filter(\.isUserCommitment).isEmpty)
    }

    func testNegatedAndQuestionedUndertakingsAreDroppedButAStrayNotIsHarmless() throws {
        let transcript = Transcript(segments: [
            microphone(0, "I will not ship the update on Friday."),
            microphone(5, "Should we move the release to Monday?"),
            microphone(10, "It's not yet ready for review. Let me do a bit more work on it before the handoff."),
        ], engine: "fixture")
        let result = try validate(transcript, [
            action("s1", "Ship the update on Friday"),
            action("s2", "Move the release to Monday"),
            action("s3", "Do more work on the change before the handoff"),
        ])
        XCTAssertEqual(result.outcomes.actionItems.map(\.text), ["Do more work on the change before the handoff"])
        XCTAssertTrue(result.outcomes.actionItems[0].isForUser)
        XCTAssertEqual(result.rejected.map(\.reason), ["unsupported_commitment", "unsupported_commitment"])
    }
}
