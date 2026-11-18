import CoreMedia
import XCTest
@testable import LokalBot

#if canImport(Speech)
import Speech
#endif

final class AppleSpeechWordAttributionTests: XCTestCase {
    func testAppleSpeechDeclaresNativeWordTimingsAndAlignedWordsStrategy() {
        XCTAssertEqual(AppleSpeechEngine.shared.speakerAttribution, .alignedWords)
        XCTAssertTrue(AppleSpeechEngine.shared.providesWordTimings)
    }

    func testBuildTimedSegmentsSplitsOnPausesAndDurationLimitWhileKeepingPunctuation() throws {
        let words = [
            AlignedWordTiming(text: "Hello", start: 0.1, end: 0.5),
            AlignedWordTiming(text: "world.", start: 0.5, end: 0.9),
            AlignedWordTiming(text: "Next", start: 2.0, end: 2.4),
            AlignedWordTiming(text: "turn.", start: 2.4, end: 2.8),
        ]
        let segments = AppleSpeechEngine.buildTimedSegments(from: [
            .init(start: 0.1, end: 2.8, text: "Hello world. Next turn.", words: words),
        ])
        XCTAssertEqual(segments.map(\.segment.text), ["Hello world.", "Next turn."])
        XCTAssertEqual(segments.map(\.segment.timingPrecision), [.token, .token])
        for segment in segments {
            XCTAssertNotNil(AttributedTrackTranscriber.engineWords(of: segment))
        }

        // 45 seconds of continuous 0.5 s words splits into <= 15 s chunks.
        let longWords = (0..<90).map { index in
            AlignedWordTiming(
                text: "word\(index)",
                start: Double(index) * 0.5,
                end: Double(index) * 0.5 + 0.5)
        }
        let longUtterance = AppleSpeechEngine.RawUtterance(
            start: 0,
            end: 45,
            text: longWords.map(\.text).joined(separator: " "),
            words: longWords)
        let split = AppleSpeechEngine.buildTimedSegments(from: [longUtterance])
        XCTAssertEqual(split.count, 3)
        for segment in split {
            XCTAssertLessThanOrEqual(segment.segment.end - segment.segment.start, 15.0 + 0.001)
            XCTAssertNotNil(AttributedTrackTranscriber.engineWords(of: segment))
        }
    }

    func testStandalonePunctuationRunsAndCJKPreserveWordStartMatching() throws {
        #if canImport(Speech)
        if #available(macOS 26.0, *) {
            var attributed = AttributedString()
            func append(_ text: String, start: Double?, end: Double?) {
                var part = AttributedString(text)
                if let start, let end {
                    part.audioTimeRange = CMTimeRange(
                        start: CMTime(seconds: start, preferredTimescale: 600),
                        end: CMTime(seconds: end, preferredTimescale: 600))
                }
                attributed += part
            }
            append("Hello", start: 0.0, end: 0.4)
            append(",", start: 0.4, end: 0.45)
            append(" world", start: 0.5, end: 0.9)
            append("!", start: 0.9, end: 0.95)

            let words = AppleSpeechEngine.extractWordTimings(from: attributed)
            XCTAssertEqual(words.map(\.text), ["Hello,", "world!"])
            let built = AppleSpeechEngine.buildTimedSegments(from: [
                .init(start: 0, end: 0.95, text: String(attributed.characters), words: words),
            ])
            XCTAssertEqual(built.count, 1)
            XCTAssertNotNil(AttributedTrackTranscriber.engineWords(of: try XCTUnwrap(built.first)))
        }
        #endif

        let cjkWords = [
            AlignedWordTiming(text: "你", start: 0.0, end: 0.2),
            AlignedWordTiming(text: "好", start: 0.2, end: 0.4),
            AlignedWordTiming(text: "世", start: 1.5, end: 1.7),
            AlignedWordTiming(text: "界。", start: 1.7, end: 2.0),
        ]
        let cjkSegments = AppleSpeechEngine.buildTimedSegments(from: [
            .init(start: 0.0, end: 2.0, text: "你好世界。", words: cjkWords),
        ])
        XCTAssertEqual(cjkSegments.map(\.segment.text), ["你好", "世界。"])
        for segment in cjkSegments {
            XCTAssertNotNil(AttributedTrackTranscriber.engineWords(of: segment))
        }
    }

    @MainActor
    func testAttributedTrackTranscriberUsesNativeWordTimingsWithoutDownloadingAligner() async throws {
        let english = AppleSpeechLocaleResolver.Resolution(
            localeIdentifier: "en_US",
            languageCode: "en",
            module: .speechTranscriber)
        let engine = AppleSpeechEngine(backend: .init(
            availabilityError: { nil },
            resolve: { _ in english },
            ensureAsset: { _, _ in },
            analyze: { _, _, _ in
                [
                    .init(
                        start: 0.1,
                        end: 4.0,
                        text: "Hello Maya. Yes I agree.",
                        words: [
                            AlignedWordTiming(text: "Hello", start: 0.2, end: 0.6),
                            AlignedWordTiming(text: "Maya.", start: 0.6, end: 1.0),
                            AlignedWordTiming(text: "Yes", start: 2.2, end: 2.5),
                            AlignedWordTiming(text: "I", start: 2.5, end: 2.7),
                            AlignedWordTiming(text: "agree.", start: 2.7, end: 3.1),
                        ]),
                ]
            }))

        let wav = FileManager.default.temporaryDirectory
            .appendingPathComponent("apple-speech-attrib-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: wav) }
        let writer = try WavWriter(url: wav, sampleRate: 16_000)
        try writer.finish()

        let turns: [DiarizedSegment] = [
            .init(start: 0.0, end: 1.4, speakerId: "A"),
            .init(start: 2.0, end: 4.0, speakerId: "B"),
        ]
        let transcript = try await AttributedTrackTranscriber.transcribe(
            url: wav,
            duration: 4.0,
            diarization: turns,
            source: .system,
            engine: engine,
            language: "en",
            prompt: nil,
            prepareAligner: {
                XCTFail("QwenWordAligner must not be downloaded when AppleSpeechEngine provides word timings")
            })

        XCTAssertEqual(transcript.segments.map(\.text), ["Hello Maya.", "Yes I agree."])
        XCTAssertEqual(transcript.segments.map(\.speaker), ["them 1", "them 2"])
        XCTAssertEqual(transcript.segments.map(\.timingPrecision), [.token, .token])
    }
}
