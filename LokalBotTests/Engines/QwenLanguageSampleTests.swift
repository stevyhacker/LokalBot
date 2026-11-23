import XCTest
@testable import LokalBot

final class QwenLanguageSampleTests: XCTestCase {
    private let english = [
        "I dropped a question on Discord, so any time just check it out and let me know what you think.",
        "We are polishing the fee extraction pull request and I have a few conflicts to solve now.",
        "Hopefully I have something by next week that we can try integrating into the interface.",
        "The release notes still need a section about the new import screen and its limits.",
    ]
    private let german = [
        "Wir haben gestern die neue Version veröffentlicht und die ersten Rückmeldungen sind sehr positiv.",
        "Könnten Sie mir bitte die Unterlagen bis Freitag schicken, damit wir alles vorbereiten können?",
        "Die Besprechung am Donnerstag verschieben wir auf nächste Woche, weil zwei Kollegen krank sind.",
    ]
    private let croatian = [
        "Sastanak smo pomjerili za sljedeću sedmicu jer su dvije koleginice bolesne.",
        "Nakon sastanka ćemo poslati zapisnik i dogovoriti sljedeće korake s timom.",
        "Prijedlog je da proračun za idući kvartal odobrimo do petka.",
        "Projekat kasni dvije sedmice zbog problema sa dobavljačem.",
    ]

    private func spans(_ count: Int) -> [SpeechSpan] {
        (0..<count).map { index in
            let start = Double(index) * 10
            return SpeechSpan(start: start, end: start + 2 + Double((index * 7) % 5), timingPrecision: .span)
        }
    }

    private final class Decoder: @unchecked Sendable {
        private(set) var calls: [(spans: [Int], language: String?)] = []
        private let auto: (Int) -> String

        init(auto: @escaping (Int) -> String) { self.auto = auto }

        func decode(_ spans: [SpeechSpan], _ language: String?) -> [Transcript.Segment] {
            let indices = spans.map { Int($0.start / 10) }
            calls.append((indices, language))
            return zip(spans, indices).map { span, index in
                Transcript.Segment(start: span.start, end: span.end, speaker: "speaker",
                                   text: language.map { "pinned \($0) \(index)" } ?? auto(index),
                                   timingPrecision: span.timingPrecision)
            }
        }
    }

    private func decide(_ spans: [SpeechSpan], wordAttribution: Bool = false,
                        decoder: Decoder) async throws -> QwenASREngine.AutoLanguageDecision {
        try await QwenASREngine.decodeOnAuto(spans, wordAttribution: wordAttribution, sampleSize: 8) {
            decoder.decode($0, $1)
        }
    }

    func testSampleTakesTheLongestSpanOfEachStretchThroughTheEnd() {
        let spans = spans(20)
        let sample = QwenASREngine.languageSample(spans, count: 8)
        XCTAssertEqual(sample.count, 8)
        XCTAssertEqual(sample, sample.sorted())
        let bounds = [0, 2, 5, 7, 10, 12, 15, 17, 20]
        for (group, index) in sample.enumerated() {
            let range = bounds[group]..<bounds[group + 1]
            XCTAssertTrue(range.contains(index), "group \(group) picked \(index)")
            let longest = range.map { spans[$0].end - spans[$0].start }.max()!
            XCTAssertEqual(spans[index].end - spans[index].start, longest)
        }
        XCTAssertGreaterThanOrEqual(sample.last!, 17, "The final stretch, where a late language change would be, is heard")
    }

    func testSampleTiesGoToTheEarliestSpan() {
        let even = (0..<20).map { SpeechSpan(start: Double($0) * 10, end: Double($0) * 10 + 5) }
        XCTAssertEqual(QwenASREngine.languageSample(even, count: 8), [0, 2, 5, 7, 10, 12, 15, 17])
    }

    func testShortTracksAreSampledWhole() {
        XCTAssertEqual(QwenASREngine.languageSample(spans(8), count: 8), Array(0..<8))
        XCTAssertEqual(QwenASREngine.languageSample(spans(1), count: 8), [0])
        XCTAssertEqual(QwenASREngine.languageSample([], count: 8), [])
    }

    func testOneLanguageTrackDecodesOncePinnedAfterTheSample() async throws {
        let spans = spans(20)
        let decoder = Decoder { self.english[$0 % self.english.count] }
        let decision = try await decide(spans, decoder: decoder)

        let sample = QwenASREngine.languageSample(spans, count: 8)
        XCTAssertEqual(decoder.calls.count, 2)
        XCTAssertEqual(decoder.calls[0].spans, sample)
        XCTAssertNil(decoder.calls[0].language)
        XCTAssertEqual(decoder.calls[1].spans, Array(0..<20), "The sampled spans decode again, pinned, with the rest")
        XCTAssertEqual(decoder.calls[1].language, "en")
        XCTAssertEqual(decision.pinned, "en")
        XCTAssertEqual(decision.sampled, 8)
        XCTAssertFalse(decision.decodedTwice)
        XCTAssertFalse(decision.needsSpeakerRegions)
        XCTAssertEqual(decision.segments.map(\.text), (0..<20).map { "pinned en \($0)" })
    }

    func testCroatianTrackDecodesOncePinnedWithoutWordAttribution() async throws {
        let decoder = Decoder { self.croatian[$0 % self.croatian.count] }
        let decision = try await decide(spans(20), decoder: decoder)

        XCTAssertEqual(decoder.calls.map(\.language), [nil, "hr"])
        XCTAssertEqual(decision.pinned, "hr")
        XCTAssertFalse(decision.needsSpeakerRegions)
    }

    func testCroatianTrackForWordAttributionStopsAfterTheSample() async throws {
        let decoder = Decoder { self.croatian[$0 % self.croatian.count] }
        let decision = try await decide(spans(20), wordAttribution: true, decoder: decoder)

        XCTAssertEqual(decoder.calls.count, 1)
        XCTAssertEqual(decoder.calls[0].spans.count, 8)
        XCTAssertEqual(decision.pinned, "hr")
        XCTAssertTrue(decision.needsSpeakerRegions)
        XCTAssertFalse(decision.decodedTwice)
    }

    func testEnglishTrackForWordAttributionStillDecodesPinned() async throws {
        let decoder = Decoder { self.english[$0 % self.english.count] }
        let decision = try await decide(spans(20), wordAttribution: true, decoder: decoder)

        XCTAssertEqual(decoder.calls.map(\.language), [nil, "en"])
        XCTAssertFalse(decision.needsSpeakerRegions)
    }

    func testMixedTrackStaysOnAutoAndIsDecodedOnce() async throws {
        let spans = spans(20)
        let decoder = Decoder { $0 % 2 == 0 ? self.english[$0 % self.english.count] : self.german[$0 % self.german.count] }
        let decision = try await decide(spans, decoder: decoder)

        let sample = QwenASREngine.languageSample(spans, count: 8)
        XCTAssertEqual(decoder.calls.count, 2)
        XCTAssertEqual(decoder.calls.map(\.language), [nil, nil])
        XCTAssertEqual(decoder.calls[1].spans, (0..<20).filter { !sample.contains($0) }, "Only the rest decodes")
        XCTAssertNil(decision.pinned)
        XCTAssertFalse(decision.decodedTwice)
        XCTAssertEqual(decision.segments.map(\.start), spans.map(\.start), "Sampled and later spans keep track order")
        XCTAssertEqual(decision.segments[3].text, german[0])
    }

    func testLateLanguageChangeKeepsTheTrackOnAuto() async throws {
        let decoder = Decoder { $0 < 14 ? self.english[$0 % self.english.count] : self.german[$0 % self.german.count] }
        let decision = try await decide(spans(20), decoder: decoder)

        XCTAssertNil(decision.pinned)
        XCTAssertEqual(decoder.calls.map(\.language), [nil, nil])
        XCTAssertEqual(decision.segments.count, 20)
    }

    func testTrackTheSampleMisjudgedIsStillPinnedByTheWholeTrackVote() async throws {
        let spans = spans(40)
        let sample = QwenASREngine.languageSample(spans, count: 8)
        let misdetected = Set([sample[1], sample[3], sample[5]])
        let decoder = Decoder { misdetected.contains($0) ? self.german[$0 % self.german.count]
                                                        : self.english[$0 % self.english.count] }
        let decision = try await decide(spans, decoder: decoder)

        XCTAssertEqual(decoder.calls.map(\.language), [nil, nil, "en"])
        XCTAssertEqual(decoder.calls[2].spans, Array(0..<40))
        XCTAssertEqual(decision.pinned, "en")
        XCTAssertTrue(decision.decodedTwice)
    }

    func testSampleBelowItsShareFallsBackToTheWholeTrackVote() async throws {
        XCTAssertGreaterThan(QwenASREngine.sampleShare, 0.88)
        let spans = spans(40)
        let sample = QwenASREngine.languageSample(spans, count: 8)
        let decoder = Decoder { $0 == sample[7] ? self.german[$0 % self.german.count]
                                                : self.english[$0 % self.english.count] }
        let decision = try await decide(spans, decoder: decoder)

        XCTAssertEqual(decoder.calls.map(\.language), [nil, nil, "en"])
        XCTAssertEqual(decision.pinned, "en")
        XCTAssertTrue(decision.decodedTwice)
    }

    func testShortTrackInOneLanguageKeepsItsFirstDecode() async throws {
        let decoder = Decoder { self.english[$0 % self.english.count] }
        let decision = try await decide(spans(3), decoder: decoder)

        XCTAssertEqual(decoder.calls.map(\.spans), [[0, 1, 2]], "Every span already read as English")
        XCTAssertEqual(decoder.calls.map(\.language), [nil])
        XCTAssertEqual(decision.pinned, "en")
        XCTAssertFalse(decision.decodedTwice)
        XCTAssertFalse(decision.needsSpeakerRegions)
        XCTAssertEqual(decision.segments.map(\.text), Array(english.prefix(3)))
    }

    func testShortTrackWithOneSpanInAnotherLanguageDecodesAgainPinned() async throws {
        let decoder = Decoder { $0 == 4 ? self.german[0] : self.english[$0 % self.english.count] }
        let decision = try await decide(spans(7), decoder: decoder)

        XCTAssertEqual(decoder.calls.map(\.spans), [Array(0..<7), Array(0..<7)])
        XCTAssertEqual(decoder.calls.map(\.language), [nil, "en"])
        XCTAssertEqual(decision.pinned, "en")
        XCTAssertTrue(decision.decodedTwice)
        XCTAssertEqual(decision.segments[4].text, "pinned en 4")
    }

    func testShortCroatianTrackStillDecodesAgainPinned() async throws {
        let decoder = Decoder { self.croatian[$0 % self.croatian.count] }
        let decision = try await decide(spans(4), decoder: decoder)

        XCTAssertEqual(decoder.calls.map(\.language), [nil, "hr"],
                       "Serbian and its neighbours vote as one language, so the pinned decode is kept")
        XCTAssertEqual(decision.pinned, "hr")
        XCTAssertTrue(decision.decodedTwice)
    }

    func testShortSpansTooBriefToJudgeDoNotForceASecondDecode() async throws {
        let decoder = Decoder { $0 == 1 ? "Okay." : self.english[$0 % self.english.count] }
        let decision = try await decide(spans(4), decoder: decoder)

        XCTAssertEqual(decoder.calls.map(\.language), [nil])
        XCTAssertEqual(decision.pinned, "en")
        XCTAssertEqual(decision.segments[1].text, "Okay.")
    }

    func testSingleWindowIsNeverPinned() async throws {
        let decoder = Decoder { self.english[$0 % self.english.count] }
        let decision = try await decide(spans(1), decoder: decoder)

        XCTAssertEqual(decoder.calls.map(\.spans), [[0]])
        XCTAssertNil(decision.pinned)
        XCTAssertEqual(decision.segments.map(\.text), [english[0]])
    }

    func testShortCroatianTrackForWordAttributionGoesToSpeakerRegions() async throws {
        let decoder = Decoder { self.croatian[$0 % self.croatian.count] }
        let decision = try await decide(spans(4), wordAttribution: true, decoder: decoder)

        XCTAssertEqual(decoder.calls.map(\.language), [nil])
        XCTAssertEqual(decision.pinned, "hr")
        XCTAssertTrue(decision.needsSpeakerRegions)
    }

    func testSilentTrackDecodesNothing() async throws {
        let decoder = Decoder { _ in "" }
        let decision = try await decide([], decoder: decoder)

        XCTAssertTrue(decoder.calls.isEmpty)
        XCTAssertTrue(decision.segments.isEmpty)
        XCTAssertNil(decision.pinned)
    }
}
