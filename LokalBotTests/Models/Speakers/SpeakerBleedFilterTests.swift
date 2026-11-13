import XCTest
@testable import LokalBot

final class SpeakerBleedFilterTests: XCTestCase {

    private func segment(
        _ speaker: String,
        _ start: TimeInterval,
        _ end: TimeInterval,
        _ text: String,
        confidence: Double? = nil,
        timing: Transcript.Segment.TimingPrecision? = .span
    ) -> Transcript.Segment {
        Transcript.Segment(
            start: start,
            end: end,
            speaker: speaker,
            text: text,
            confidence: confidence,
            timingPrecision: timing)
    }

    private func transcript(_ segments: [Transcript.Segment]) -> Transcript {
        Transcript(segments: segments, engine: "test")
    }

    func testRemovesOnlyACompleteCotimedSpeakerBleedSpan() {
        let prompt = "Wenn Sie mit der Qualität der Nachricht zufrieden sind, haben Sie Teams "
            + "richtig konfiguriert. Wenn nicht, überprüfen Sie die Einstellung Ihres Gerätes "
            + "und versuchen Sie es erneut"
        let input = transcript([
            segment("me", 1, 4, "1, 2, 5, 5"),
            segment("me", 5, 17, ". " + prompt + "."),
            segment("them", 5, 17, prompt),
        ])

        let result = SpeakerBleedFilter.filter(input, acousticallyVerifiedIndices: Set(input.segments.indices))

        XCTAssertEqual(result.removedSegments, 1)
        XCTAssertEqual(result.transcript.segments.map(\.speaker), ["me", "them"])
        XCTAssertEqual(result.transcript.segments.first?.text, "1, 2, 5, 5")
        XCTAssertEqual(result.transcript.segments.last?.text, prompt)
    }

    func testPreservesMixedEchoAndReplyExactlyInsteadOfPartiallyTrimming() {
        let remote = segment(
            "them", 10, 20,
            "aber ich weiß nicht ob das für heute angedacht war")
        let mic = segment(
            "me", 11, 22,
            "aber ich weiß nicht ob das für heute angedacht war. "
                + "Das sollte mit denen abgestimmt sein die gefehlt haben",
            confidence: 0.73)
        let input = transcript([remote, mic])

        let result = SpeakerBleedFilter.filter(input, acousticallyVerifiedIndices: Set(input.segments.indices))

        XCTAssertFalse(result.changed)
        XCTAssertEqual(result.transcript.segments, input.segments)
        XCTAssertEqual(result.transcript.segments.last?.start, 11)
        XCTAssertEqual(result.transcript.segments.last?.end, 22)
        XCTAssertEqual(result.transcript.segments.last?.confidence, 0.73)
    }

    func testPreservesShortGenuineReplyAfterEcho() {
        let echoed = "we will move the release to Thursday"
        let mic = segment("me", 10, 22, echoed + " yes absolutely")
        let input = transcript([
            segment("them", 10, 20, echoed),
            mic,
        ])

        let result = SpeakerBleedFilter.filter(input, acousticallyVerifiedIndices: Set(input.segments.indices))

        XCTAssertFalse(result.changed)
        XCTAssertEqual(result.transcript.segments.last, mic)
    }

    func testPreservesLegitimateOneWordPrefix() {
        let echoed = "we should postpone the product launch"
        let mic = segment("me", 10, 20, "Absolutely " + echoed)
        let input = transcript([
            segment("them", 10, 20, echoed),
            mic,
        ])

        let result = SpeakerBleedFilter.filter(input, acousticallyVerifiedIndices: Set(input.segments.indices))

        XCTAssertFalse(result.changed)
        XCTAssertEqual(result.transcript.segments.last, mic)
    }

    func testPreservesPhraseRepeatedLaterInsideOverlappingLongSegments() {
        let phrase = "we should postpone the product launch"
        let remote = phrase + " while we review the remaining engineering and legal risks"
        let mic = segment("me", 18, 22, phrase)
        let input = transcript([
            // The shared phrase is at the beginning of this long remote span.
            segment("them", 0, 20, remote),
            // The local speaker genuinely repeats it near the end.
            mic,
        ])

        let result = SpeakerBleedFilter.filter(input, acousticallyVerifiedIndices: Set(input.segments.indices))

        XCTAssertFalse(result.changed)
        XCTAssertEqual(result.transcript.segments.last, mic)
    }

    func testPreservesIdenticalTextWhenOnlyCoarseTimingExists() {
        let line = "we will review the launch plan tomorrow"
        let input = transcript([
            segment("them", 0, 10, line, timing: .coarse),
            segment("me", 0, 10, line, timing: .coarse),
        ])

        let result = SpeakerBleedFilter.filter(input, acousticallyVerifiedIndices: Set(input.segments.indices))

        XCTAssertFalse(result.changed)
        XCTAssertEqual(result.transcript.segments, input.segments)
    }

    func testPreservesLegacySegmentsWithUnknownTimingPrecision() {
        let line = "we will review the launch plan tomorrow"
        let input = transcript([
            segment("them", 0, 10, line, timing: nil),
            segment("me", 0, 10, line, timing: nil),
        ])

        let result = SpeakerBleedFilter.filter(input, acousticallyVerifiedIndices: Set(input.segments.indices))

        XCTAssertFalse(result.changed)
        XCTAssertEqual(result.transcript.segments, input.segments)
    }

    func testSegmentOverlapAloneDoesNotProveCotiming() {
        let line = "we should postpone the product launch"
        let mic = segment("me", 8, 12, line)
        let input = transcript([
            segment("them", 0, 10, line),
            mic,
        ])

        let result = SpeakerBleedFilter.filter(input, acousticallyVerifiedIndices: Set(input.segments.indices))

        XCTAssertFalse(result.changed)
        XCTAssertEqual(result.transcript.segments.last, mic)
    }

    func testPreservesShortContractionAcknowledgement() {
        let input = transcript([
            segment("them", 3, 6, "That's right"),
            segment("me", 3.1, 5.9, "That's right"),
        ])

        let result = SpeakerBleedFilter.filter(input, acousticallyVerifiedIndices: Set(input.segments.indices))

        XCTAssertFalse(result.changed)
        XCTAssertEqual(result.transcript.segments.count, 2)
        XCTAssertEqual(SpeakerBleedFilter.comparisonTokens(in: "That's right")?.count, 2)
    }

    func testPreservesSemanticallyDifferentOneEditWord() {
        let input = transcript([
            segment("them", 3, 8, "we can ship the build"),
            segment("me", 3, 8, "we can skip the build"),
        ])

        let result = SpeakerBleedFilter.filter(input, acousticallyVerifiedIndices: Set(input.segments.indices))

        XCTAssertFalse(result.changed)
        XCTAssertEqual(result.transcript.segments.count, 2)
    }

    func testKeepsGenuineRepetitionAfterTheRemoteTurn() {
        let line = "we will move the release to next Thursday"
        let input = transcript([
            segment("them", 10, 14, line),
            segment("me", 14.5, 18.5, line),
        ])

        let result = SpeakerBleedFilter.filter(input, acousticallyVerifiedIndices: Set(input.segments.indices))

        XCTAssertFalse(result.changed)
        XCTAssertEqual(result.transcript.segments.count, 2)
    }

    func testNeverRemovesTheRemoteTrack() {
        let line = "the protocol is ready in the shared folder"
        let remote = segment("them", 2, 8, line, confidence: 0.91, timing: .token)
        let input = transcript([
            segment("me", 2, 8, line, timing: .token),
            remote,
        ])

        let result = SpeakerBleedFilter.filter(input, acousticallyVerifiedIndices: Set(input.segments.indices))

        XCTAssertEqual(result.removedSegments, 1)
        XCTAssertEqual(result.transcript.segments, [remote])
    }

    func testMicOnlyTranscriptIsUnchanged() {
        let input = transcript([
            segment("me", 0, 4, "this is a normal recording with no remote track"),
            segment("me", 4, 8, "this remains completely local microphone speech"),
        ])

        let result = SpeakerBleedFilter.filter(input, acousticallyVerifiedIndices: Set(input.segments.indices))

        XCTAssertFalse(result.changed)
        XCTAssertEqual(result.transcript.segments, input.segments)
    }

    func testRequiresBothSpanBoundariesToAlign() {
        let line = "we should postpone the product launch"
        let remote = segment("them", 10, 20, line)
        let aligned = segment("me", 10.2, 20.2, line)
        let shiftedEnd = segment("me", 10.2, 22, line)

        XCTAssertTrue(SpeakerBleedFilter.spansAreAligned(aligned, remote))
        XCTAssertFalse(SpeakerBleedFilter.spansAreAligned(shiftedEnd, remote))
    }

    func testLongPreciselyLabelledSpanIsStillTooCoarseForDeletion() {
        let line = "we should postpone the product launch"
        let input = transcript([
            segment("them", 0, 30, line, timing: .token),
            segment("me", 0, 30, line, timing: .token),
        ])

        let result = SpeakerBleedFilter.filter(input, acousticallyVerifiedIndices: Set(input.segments.indices))

        XCTAssertFalse(result.changed)
        XCTAssertEqual(result.transcript.segments, input.segments)
    }

    // MARK: - Unicode and work bounds

    func testTokenizesUnspacedScriptsPerCharacterAndCoversModernRanges() {
        let mandarin = SpeakerBleedFilter.comparisonTokens(in: "我们下周开会")
        XCTAssertEqual(mandarin?.count, 6)
        XCTAssertTrue(mandarin?.allSatisfy(\.isIdeographic) == true)

        let japanese = SpeakerBleedFilter.comparisonTokens(in: "会議は月曜日です")
        XCTAssertEqual(japanese?.count, 8)

        XCTAssertTrue(SpeakerBleedFilter.isIdeographic("𰀀")) // Extension G
        XCTAssertTrue(SpeakerBleedFilter.isIdeographic("ｶ")) // Halfwidth Katakana
    }

    func testRemovesCompleteCotimedMandarinEcho() {
        let line = "我们下周一开会讨论这个项目的进度"
        let input = transcript([
            segment("them", 10, 20, line, timing: .token),
            segment("me", 10, 20, line, timing: .token),
        ])

        let result = SpeakerBleedFilter.filter(input, acousticallyVerifiedIndices: Set(input.segments.indices))

        XCTAssertEqual(result.removedSegments, 1)
        XCTAssertEqual(result.transcript.segments.map(\.speaker), ["them"])
    }

    func testPreservesMandarinEchoPlusReplyWithOriginalTimestamps() {
        let echoed = "我们下周一开会讨论这个项目的进度"
        let mic = segment("me", 10, 22, echoed + "，好的我知道了", confidence: 0.81)
        let input = transcript([
            segment("them", 10, 20, echoed),
            mic,
        ])

        let result = SpeakerBleedFilter.filter(input, acousticallyVerifiedIndices: Set(input.segments.indices))

        XCTAssertFalse(result.changed)
        XCTAssertEqual(result.transcript.segments.last, mic)
    }

    func testKeepsShortMandarinOverlap() {
        let input = transcript([
            segment("them", 3, 6, "好的谢谢"),
            segment("me", 3, 6, "好的谢谢"),
        ])

        let result = SpeakerBleedFilter.filter(input, acousticallyVerifiedIndices: Set(input.segments.indices))

        XCTAssertFalse(result.changed)
        XCTAssertEqual(result.transcript.segments.count, 2)
    }

    func testOversizedCJKInputIsSkippedBeforeComparisonCanGrow() {
        let line = String(
            repeating: "会",
            count: SpeakerBleedFilter.maximumComparableTokenCount + 1)
        XCTAssertNil(SpeakerBleedFilter.comparisonTokens(in: line))
        let input = transcript([
            segment("them", 0, 10, line, timing: .token),
            segment("me", 0, 10, line, timing: .token),
        ])

        let result = SpeakerBleedFilter.filter(input, acousticallyVerifiedIndices: Set(input.segments.indices))

        XCTAssertFalse(result.changed)
        XCTAssertEqual(result.transcript.segments, input.segments)
    }

    func testOversizedTextIsSkippedAfterOnlyABoundedPrefix() {
        let line = String(
            repeating: "a",
            count: SpeakerBleedFilter.maximumComparableTextBytes + 1)
        XCTAssertNil(SpeakerBleedFilter.comparisonTokens(in: line))
    }

    func testCrowdedCandidateWindowIsConservativelySkipped() {
        let matching = "we should postpone the product launch"
        var segments = (0...SpeakerBleedFilter.maximumCandidateSegments).map { index in
            segment("them", 10, 20, index == 0
                    ? matching
                    : "remote alternative number \(index) has enough words")
        }
        let mic = segment("me", 10, 20, matching)
        segments.append(mic)

        let result = SpeakerBleedFilter.filter(transcript(segments))

        XCTAssertFalse(result.changed)
        XCTAssertEqual(result.transcript.segments.last, mic)
    }

    // MARK: - Persistence compatibility

    func testLegacySegmentWithoutTimingMetadataDecodesAsUnknown() throws {
        let data = Data(
            #"{"start":1,"end":2,"speaker":"me","text":"hello","confidence":null}"#.utf8)

        let decoded = try JSONDecoder().decode(Transcript.Segment.self, from: data)

        XCTAssertNil(decoded.timingPrecision)
    }

    func testTimingPrecisionRoundTrips() throws {
        let original = segment(
            "me", 1, 2, "four words with timing", timing: .token)

        let decoded = try JSONDecoder().decode(
            Transcript.Segment.self,
            from: JSONEncoder().encode(original))

        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.timingPrecision, .token)
    }
}
