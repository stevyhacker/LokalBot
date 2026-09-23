import XCTest
@testable import LokalBot

final class MeetingSpeakerReviewItemTests: XCTestCase {
    func testNamedUserIsNotOfferedAsAnotherActionOwner() throws {
        let transcript = Transcript(segments: [
            .init(start: 0, end: 5, speaker: "me", text: "I will follow up.",
                  attribution: .init(source: .microphone, identity: .user, method: .confirmation)),
            .init(start: 5, end: 10, speaker: "them", text: "Thanks.",
                  attribution: .init(source: .system, identity: .other, method: .confirmation)),
        ], engine: "fixture", speakerAliases: ["me": "Stevan", "them": "Ana"])
        let speakers = MeetingSpeakerReviewItem.items(in: transcript)
        let user = try XCTUnwrap(speakers.first { $0.isUser })
        XCTAssertEqual(user.name, "Stevan")
        XCTAssertTrue(user.isNamed)
        XCTAssertEqual(MeetingSpeakerReviewItem.ownerSuggestions(from: speakers), ["Ana"])
        for speaker in speakers {
            XCTAssertEqual(speaker.canConfirm, transcript.canConfirmSpeaker(speaker.id))
        }
    }

    func testReviewKeepsVoiceKeysAndUsesLongerValidExcerpt() {
        let transcript = Transcript(segments: [
            .init(start: 0, end: 1, speaker: "them 1", text: "Yes.",
                  attribution: .init(source: .system, identity: .unresolved, method: .diarization)),
            .init(start: 1, end: 6, speaker: "them 2", text: "Another voice.",
                  attribution: .init(source: .system, identity: .other, method: .confirmation)),
            .init(start: 6, end: 14, speaker: "them 1", text: "A clear sample of the first voice.",
                  attribution: .init(source: .system, identity: .unresolved, method: .diarization)),
        ], engine: "fixture", speakerAliases: ["them 2": "Ana"])
        let items = MeetingSpeakerReviewItem.items(in: transcript)
        XCTAssertEqual(items.map(\.id), ["them 1", "them 2"])
        XCTAssertEqual(items[0].sample?.start, 6)
        XCTAssertFalse(items[0].isNamed)
        XCTAssertTrue(items[0].canConfirm)
        XCTAssertEqual(items[1].name, "Ana")
        XCTAssertTrue(items[1].isNamed)
        XCTAssertFalse(items[1].isUser)
    }

    func testMixedAudioAndMicrophoneDoNotBecomeConfirmedPeople() {
        let transcript = Transcript(segments: [
            .init(start: 0, end: 5, speaker: "me", text: "Microphone input."),
            .init(start: 5, end: 10, speaker: "them", text: "Overlapping voices.",
                  attribution: .init(source: .system, identity: .unresolved, method: .overlappingSpeech)),
        ], engine: "fixture")
        let items = MeetingSpeakerReviewItem.items(in: transcript)
        XCTAssertFalse(items[0].isUser)
        XCTAssertFalse(items[1].canConfirm)
        XCTAssertEqual(items[1].status, "Mixed or unresolved audio")
    }

    func testMergePlaceholdersAreNotPresentedAsConfirmedNames() {
        let transcript = Transcript(segments: [
            .init(start: 0, end: 5, speaker: "source1:them 1", text: "First source."),
            .init(start: 5, end: 10, speaker: "source2:them 1", text: "Second source."),
        ], engine: "merged",
           speakerAliases: ["source1:them 1": "Them 1 · source 1", "source2:them 1": "Ana · source 2"])
        let items = MeetingSpeakerReviewItem.items(in: transcript)
        XCTAssertEqual(items.map(\.name), ["Speaker 1", "Ana"])
        XCTAssertFalse(items[0].isNamed)
        XCTAssertTrue(items[1].isNamed)
        XCTAssertNotEqual(items[0].id, items[1].id)
    }

    func testContentQualityBeatsLongFillerAndReturnsNoMisleadingSample() {
        let segments: [Transcript.Segment] = [
            .init(start: 0, end: 20, speaker: "them", text: "Okay."),
            .init(start: 20, end: 26, speaker: "them", text: "I will review the redemption queue after this call."),
            .init(start: 26, end: 40, speaker: "them", text: String(repeating: "uh ", count: 30)),
        ]
        XCTAssertEqual(MeetingSpeakerReviewItem.bestSample(in: segments)?.start, 20)
        XCTAssertNil(MeetingSpeakerReviewItem.bestSample(in: [segments[0], segments[2]]))
    }

    func testActionLinkedSpeakersComeFirstWithoutGuessingAnOwner() {
        let transcript = Transcript(segments: [
            .init(start: 0, end: 5, speaker: "them 1", text: "Discuss the release."),
            .init(start: 5, end: 10, speaker: "them 2", text: "Please review the queue."),
            .init(start: 10, end: 15, speaker: "them 3", text: "We should follow up."),
        ], engine: "fixture")
        let citation = OutcomeSourceCitation(segmentID: "5", start: 5, end: 10,
                                             speaker: "them 2", excerpt: "Please review the queue.")
        let action = MeetingOutcomes.ActionItem(text: "Review queue", citations: [citation])
        let ranked = MeetingSpeakerReviewItem.prioritized(MeetingSpeakerReviewItem.items(in: transcript), actions: [action])
        XCTAssertEqual(ranked.map(\.id), ["them 2", "them 1", "them 3"])
        XCTAssertEqual(ranked.map(\.actionCount), [1, 0, 0])
        XCTAssertTrue(ranked.allSatisfy { !$0.isNamed })
        XCTAssertNil(action.owner)
    }

    func testMalformedExcerptCannotBePlayedAndEmptyTranscriptHasNoRows() {
        let transcript = Transcript(segments: [
            .init(start: .nan, end: 10, speaker: "them", text: "Invalid timestamp."),
            .init(start: -1, end: 2, speaker: "them", text: "Negative timestamp."),
        ], engine: "fixture")
        XCTAssertNil(MeetingSpeakerReviewItem.items(in: transcript).first?.sample)
        XCTAssertTrue(MeetingSpeakerReviewItem.items(in: nil).isEmpty)
    }
}
