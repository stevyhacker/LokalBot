import XCTest
@testable import LokalBot

final class MeetingSpeakerPresentationTests: XCTestCase {
    func testMergedSpeakersStayDistinctWithoutSourceMetadata() {
        let transcript = fixture([
            ("source1:them 1", "Them 1 · source 1"),
            ("source2:them 1", "Them 1 · source 2"),
            ("source2:them 2", "Ana · source 2")
        ])
        let display = MeetingSpeakerPresentation(transcript: transcript)
        XCTAssertEqual(display.speaker("source1:them 1", in: transcript), "Speaker 1")
        XCTAssertEqual(display.speaker("source2:them 1", in: transcript), "Speaker 2")
        XCTAssertEqual(display.speaker("source2:them 2", in: transcript), "Ana")
        XCTAssertEqual(display.text("Them 1 · source 2"), "Speaker 2")
        XCTAssertEqual(transcript.speakerAliases["source2:them 1"], "Them 1 · source 2")
        XCTAssertEqual(transcript.segments[1].speaker, "source2:them 1")
    }

    func testNestedMergeAndMultiDigitSourceLabels() {
        let transcript = fixture([
            ("source1:them", "Them · source 1"),
            ("source10:them", "Them · source 10"),
            ("source2:source1:them", "Ana · source 1 · source 2")
        ])
        let display = MeetingSpeakerPresentation(transcript: transcript)
        XCTAssertEqual(display.text("**Them · source 10:** Ship it. — [00:12]"),
                       "**Speaker 2:** Ship it. — [00:12]")
        XCTAssertEqual(display.text("Ana · source 1 · source 2"), "Ana")
        XCTAssertEqual(display.text("Them · source 100"), "Them · source 100")
    }

    func testOrdinaryAndConfirmedNamesRemainUnchanged() {
        let transcript = fixture([
            ("them 1", "Ana"),
            ("source1:them", "Rob")
        ])
        let display = MeetingSpeakerPresentation(transcript: transcript)
        XCTAssertEqual(display.speaker("them 1", in: transcript), "Ana")
        XCTAssertEqual(display.speaker("source1:them", in: transcript), "Rob")
        XCTAssertEqual(display.text("Use source 2 for the report."), "Use source 2 for the report.")
    }

    func testPlaceholderNamesReadNaturally() {
        XCTAssertEqual(SpeakerDisplayName.label("Me"), "You")
        XCTAssertEqual(SpeakerDisplayName.label("Them"), "Other speaker")
        XCTAssertEqual(SpeakerDisplayName.label("Them 2"), "Speaker 2")
        XCTAssertEqual(SpeakerDisplayName.label("Local speaker"), "Local speaker")
        XCTAssertEqual(SpeakerDisplayName.label("Ana"), "Ana")
        XCTAssertEqual(SpeakerDisplayName.label("Theme 2"), "Theme 2")
    }

    func testUnnamedSpeakersAndOwnersUseDisplayNamesButPromptsKeepCanonicalNames() {
        let transcript = Transcript(segments: [
            .init(start: 0, end: 1, speaker: "them", text: "Evidence."),
            .init(start: 1, end: 2, speaker: "them 2", text: "Evidence."),
        ], engine: "test", speakerAliases: [:])
        let display = MeetingSpeakerPresentation(transcript: transcript)
        XCTAssertEqual(display.speaker("them", in: transcript), "Other speaker")
        XCTAssertEqual(display.speaker("them 2", in: transcript), "Speaker 2")
        XCTAssertEqual(display.owner("Me"), "You")
        XCTAssertEqual(display.owner("Them"), "Other speaker")
        XCTAssertTrue(transcript.promptSpeaker(for: "them").hasSuffix("] Them"))
    }

    private func fixture(_ speakers: [(String, String)]) -> Transcript {
        Transcript(segments: speakers.enumerated().map { index, speaker in
            .init(start: Double(index), end: Double(index + 1), speaker: speaker.0, text: "Evidence.")
        }, engine: "merged", speakerAliases: Dictionary(uniqueKeysWithValues: speakers))
    }
}
