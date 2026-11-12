import XCTest
@testable import LokalBot

final class MeetingSpeakerNamingTests: XCTestCase {
    private func segment(_ start: Double, _ end: Double, _ speaker: String, _ text: String,
                         user: Bool = false) -> Transcript.Segment {
        .init(start: start, end: end, speaker: speaker, text: text,
              attribution: .init(source: user ? .microphone : .system,
                                 identity: user ? .user : .unresolved,
                                 method: user ? .confirmation : .diarization))
    }

    private var transcript: Transcript {
        Transcript(segments: [
            segment(0, 10, "me", "Let's start with the synthetic beta date.", user: true),
            segment(10, 40, "them 1", "The synthetic gateway is up in staging already."),
            segment(40, 400, "them 2", "The synthetic mobile build needs three more weeks of work."),
            segment(400, 520, "them 3", "Legal has not started the synthetic data review yet."),
        ], engine: "fixture", speakerAliases: ["them 1": "Maya Chen"])
    }

    private var guests: [CalendarParticipantIdentity] {
        [CalendarParticipantIdentity(id: "guest-daniel", name: "Daniel Ortiz", emailAddress: "daniel@example.com"),
         CalendarParticipantIdentity(id: "guest-sarah", name: "Sarah Kim", emailAddress: "sarah@example.com")]
            .compactMap { $0 }
    }

    private func lists(recognized: [String: String] = [:], recognizedSpeakers: Set<String> = [],
                       actions: [MeetingOutcomes.ActionItem] = [])
        -> (voices: [MeetingSpeakerNamingVoice], known: [MeetingSpeakerNamingKnown]) {
        let transcript = transcript
        return MeetingSpeakerNaming.lists(
            speakers: MeetingDetailPresentation.speakers(
                in: transcript, presentation: MeetingSpeakerPresentation(transcript: transcript)),
            reviewItems: MeetingSpeakerReviewItem.prioritized(
                MeetingSpeakerReviewItem.items(in: transcript), actions: actions),
            speechSeconds: MeetingDetailPresentation.speechSeconds(in: transcript),
            recognized: recognized, recognizedSpeakers: recognizedSpeakers)
    }

    func testSheetListsUnnamedVoicesWithSpeechTimeAndKeepsNamedSpeakersApart() {
        let result = lists(recognizedSpeakers: ["them 1"])
        XCTAssertEqual(result.voices.map(\.id), ["them 2", "them 3"])
        XCTAssertEqual(result.voices.map(\.label), ["Speaker 2", "Speaker 3"])
        XCTAssertEqual(result.voices.map(\.speechSeconds), [360, 120])
        XCTAssertEqual(result.voices.first?.sample?.start, 40)
        XCTAssertEqual(result.known.map(\.name), ["Maya Chen"], "you are not offered for renaming here")
        XCTAssertEqual(result.known.first?.wasRecognized, true)
    }

    func testVoicesLinkedToActionsComeFirst() {
        let result = lists(actions: [.init(text: "Start the synthetic legal review", owner: "Them 3")])
        XCTAssertEqual(result.voices.map(\.id), ["them 3", "them 2"])
        XCTAssertEqual(result.voices.map(\.actionCount), [1, 0])
    }

    func testRecognizedGuestStartsPickedAsThatGuest() {
        let voices = lists(recognized: ["them 2": "sarah kim", "them 3": "Priya Nair"]).voices
        let suggestions = MeetingSpeakerSuggestion.choices(calendar: guests, hints: [])
        let draft = MeetingSpeakerNamingDraft(voices: voices, suggestions: suggestions)
        XCTAssertEqual(draft.choices(for: voices.map(\.id)), [
            .init(speaker: "them 2", name: "Sarah Kim", calendarIdentityID: "guest-sarah"),
            .init(speaker: "them 3", name: "Priya Nair"),
        ])
        XCTAssertTrue(draft.isPicked("calendar:guest-sarah", for: "them 2"))
        XCTAssertTrue(draft.isPicked("recognized:them 3", for: "them 3"))
    }

    func testOnePersonIsOneVoice() {
        var draft = MeetingSpeakerNamingDraft()
        let daniel = MeetingSpeakerNamingDraft.Pick(id: "calendar:guest-daniel", name: "Daniel Ortiz",
                                                    calendarIdentityID: "guest-daniel")
        draft.toggle(daniel, for: "them 2")
        XCTAssertTrue(draft.isTakenElsewhere(daniel.id, for: "them 3"))
        XCTAssertFalse(draft.isTakenElsewhere(daniel.id, for: "them 2"))
        draft.toggle(daniel, for: "them 3")
        XCTAssertEqual(draft.choices(for: ["them 2", "them 3"]),
                       [.init(speaker: "them 3", name: "Daniel Ortiz", calendarIdentityID: "guest-daniel")])
        draft.toggle(daniel, for: "them 3")
        XCTAssertTrue(draft.choices(for: ["them 2", "them 3"]).isEmpty, "picking a name again clears it")
    }

    func testTypedNameReplacesAPickAndBlankNamesAreSkipped() {
        var draft = MeetingSpeakerNamingDraft()
        draft.toggle(.init(id: "hint:ana", name: "Ana"), for: "them 2")
        draft.typeName(for: "them 2")
        XCTAssertTrue(draft.isTyping(for: "them 2"))
        XCTAssertTrue(draft.choices(for: ["them 2"]).isEmpty, "nothing typed yet")
        draft.typedNames["them 2"] = "  Jovana Ilić "
        draft.typeName(for: "them 3")
        draft.typedNames["them 3"] = "   "
        XCTAssertEqual(draft.choices(for: ["them 2", "them 3"]), [.init(speaker: "them 2", name: "Jovana Ilić")])
        // Picking a chip afterwards leaves typing.
        draft.toggle(.init(id: "hint:ana", name: "Ana"), for: "them 2")
        XCTAssertFalse(draft.isTyping(for: "them 2"))
        XCTAssertEqual(draft.choices(for: ["them 2"]), [.init(speaker: "them 2", name: "Ana")])
    }
}
