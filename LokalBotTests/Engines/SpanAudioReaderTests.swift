import AVFoundation
import XCTest
@testable import LokalBot

/// `SpanAudioReader` is the memory fix for transcription: engines decode one
/// span's window at a time instead of holding a whole decoded track. These
/// tests pin the window arithmetic (position, clamping, resampling) against
/// real files written to a temp directory.
final class SpanAudioReaderTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lokalbot-span-reader-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// A 2 s ramp at 16 kHz: sample i encodes i, so a window's first decoded
    /// sample proves the seek landed on the right frame (16-bit WAV quantizes,
    /// hence the tolerance).
    func testWindowReadsTheRequestedRegion() throws {
        let rate = 16_000
        let ramp = (0..<(2 * rate)).map { Float($0) / Float(2 * rate) }
        let url = tempDir.appendingPathComponent("ramp.wav")
        try OnnxTranscriptionEngine.writeWav(ramp, to: url)

        let reader = try SpanAudioReader(url: url)
        let window = try reader.samples(from: 0.5, to: 1.0)

        XCTAssertEqual(window.count, rate / 2)
        XCTAssertEqual(window.first ?? -1, ramp[rate / 2], accuracy: 0.001)
        XCTAssertEqual(window.last ?? -1, ramp[rate - 1], accuracy: 0.001)
    }

    func testWindowClampsToFileBounds() throws {
        let rate = 16_000
        let url = tempDir.appendingPathComponent("short.wav")
        try OnnxTranscriptionEngine.writeWav([Float](repeating: 0.25, count: rate), to: url)

        let reader = try SpanAudioReader(url: url)
        XCTAssertEqual(try reader.samples(from: 0.75, to: 5.0).count, rate / 4,
                       "a window past EOF must clamp to the file's end")
        XCTAssertTrue(try reader.samples(from: 2.0, to: 3.0).isEmpty,
                      "a window entirely past EOF must be empty")
        XCTAssertTrue(try reader.samples(from: 0.5, to: 0.5).isEmpty)
        XCTAssertEqual(reader.duration, 1.0, accuracy: 0.001)
    }

    /// A 32 kHz source must come out resampled to 16 kHz. AVAudioConverter's
    /// rate-conversion filter withholds a tail of ~100 frames (a few ms) even
    /// when drained — immaterial for ASR, where VAD pads every span by 100 ms —
    /// so the count assertion carries a matching tolerance.
    func testResamplesNon16kSources() throws {
        let sourceRate = 32_000.0
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: sourceRate,
            channels: 1, interleaved: false) else {
            return XCTFail("could not build the 32 kHz source format")
        }
        let url = tempDir.appendingPathComponent("hi-rate.caf")
        let file = try AVAudioFile(forWriting: url, settings: format.settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        let frames = AVAudioFrameCount(sourceRate * 2)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            return XCTFail("could not allocate the source buffer")
        }
        buffer.frameLength = frames
        for i in 0..<Int(frames) {
            buffer.floatChannelData![0][i] = sin(Float(i) * 2 * .pi * 440 / Float(sourceRate))
        }
        try file.write(from: buffer)

        let reader = try SpanAudioReader(url: url)
        let window = try reader.samples(from: 0.0, to: 1.0)
        XCTAssertEqual(window.count, 16_000, accuracy: 256,
                       "1 s of a 32 kHz source should decode to ~16k samples at 16 kHz")
        XCTAssertEqual(reader.duration, 2.0, accuracy: 0.001)
    }

    func testResamplerTailCannotExtendASRWindow() throws {
        for sourceRate in [32_000.0, 44_100.0, 48_000.0] {
            let format = try XCTUnwrap(AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: sourceRate,
                channels: 1, interleaved: false))
            // PCM16 matches the speaker-region WAVs and avoids a partial
            // float-CAF read hiding the converter's extra tail samples.
            let url = tempDir.appendingPathComponent("resampler-tail-\(Int(sourceRate)).wav")
            let frameCount = AVAudioFrameCount(sourceRate * 31)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
            buffer.frameLength = frameCount
            for index in 0..<Int(frameCount) { buffer.floatChannelData![0][index] = 0.25 }
            let diskFormat = try XCTUnwrap(AVAudioFormat(
                commonFormat: .pcmFormatInt16, sampleRate: sourceRate, channels: 1, interleaved: true))
            do {
                let file = try AVAudioFile(forWriting: url, settings: diskFormat.settings)
                try file.write(from: buffer)
            }

            let reader = try SpanAudioReader(url: url)
            let samples = try reader.samples(from: 0.5, to: 30.5)
            XCTAssertEqual(samples.count, 480_000,
                           "retain exactly the 30 s speaker region at \(sourceRate) Hz")
            let spans = SpeechActivity.split(start: 0, end: Double(samples.count) / 16_000,
                                             maxSegmentSeconds: 15)
            XCTAssertEqual(spans.count, 2, "resampling must not manufacture a third, sub-frame ASR span")
        }
    }

    // MARK: - SpeechActivity.split (pure span arithmetic)

    func testSuccessfulVADSilenceIsDistinctFromUnavailableVAD() {
        XCTAssertEqual(SpeechActivity.vadSpans(from: [], maxSegmentSeconds: 15), [])
        XCTAssertNil(SpeechActivity.vadSpans(from: nil, maxSegmentSeconds: 15))
    }

    func testConfirmedSilenceDoesNotOpenAudioOrCallASR() async throws {
        let spans = try XCTUnwrap(SpeechActivity.vadSpans(from: [], maxSegmentSeconds: 15))
        let segments = try await SpanTranscription.segments(
            in: tempDir.appendingPathComponent("does-not-need-decoding.wav"), spans: spans
        ) { _, _ in
            XCTFail("confirmed silence must not reach inference")
            return "Thank you."
        }
        XCTAssertTrue(segments.isEmpty)
    }

    func testSplitCapsSpansAtMaxSegmentSeconds() {
        let spans = SpeechActivity.split(start: 10, end: 40, maxSegmentSeconds: 14)
        XCTAssertEqual(spans, [
            SpeechSpan(start: 10, end: 24),
            SpeechSpan(start: 24, end: 38),
            SpeechSpan(start: 38, end: 40),
        ])
    }

    func testSplitWithoutCapKeepsOneSpan() {
        XCTAssertEqual(SpeechActivity.split(start: 3, end: 90, maxSegmentSeconds: nil),
                       [SpeechSpan(start: 3, end: 90)])
    }

    func testSplitPreservesTimingPrecision() {
        let spans = SpeechActivity.split(
            start: 3,
            end: 8,
            maxSegmentSeconds: nil,
            timingPrecision: .span)

        XCTAssertEqual(spans, [SpeechSpan(start: 3, end: 8, timingPrecision: .span)])
    }

    func testSplitOfEmptyOrInvertedRangeIsEmpty() {
        XCTAssertTrue(SpeechActivity.split(start: 5, end: 5, maxSegmentSeconds: 14).isEmpty)
        XCTAssertTrue(SpeechActivity.split(start: 9, end: 5, maxSegmentSeconds: nil).isEmpty)
    }

    // MARK: - SpanTranscription (the shared per-span engine loop)

    func testSpanTranscriptionStampsSpansAndDropsEmptyResults() async throws {
        let rate = 16_000
        let url = tempDir.appendingPathComponent("speech.wav")
        try OnnxTranscriptionEngine.writeWav([Float](repeating: 0.1, count: rate), to: url)

        let spans = [
            SpeechSpan(start: 0.0, end: 0.25, timingPrecision: .span),
            SpeechSpan(start: 0.25, end: 0.5, timingPrecision: .span),
            SpeechSpan(start: 0.5, end: 0.5, timingPrecision: .span),
        ]
        var transcribedIndexes: [Int] = []
        let segments = try await SpanTranscription.segments(in: url, spans: spans) { samples, index in
            transcribedIndexes.append(index)
            XCTAssertEqual(samples.count, rate / 4)
            return index == 0 ? "  hello   there " : "   "
        }

        XCTAssertEqual(transcribedIndexes, [0, 1],
                       "the zero-width span must be skipped without calling the engine")
        XCTAssertEqual(segments, [
            Transcript.Segment(start: 0.0, end: 0.25, speaker: "speaker",
                               text: "hello there", confidence: nil,
                               timingPrecision: .span),
        ], "whitespace-only text must not become a segment; kept text is normalized")
    }

    func testSpanTranscriptionPairsBatchTextsWithSpans() {
        let spans = [SpeechSpan(start: 0, end: 1),
                     SpeechSpan(start: 2, end: 3),
                     SpeechSpan(start: 4, end: 5)]
        let segments = SpanTranscription.segments(pairing: spans, with: ["one", "   "])
        XCTAssertEqual(segments, [
            Transcript.Segment(start: 0, end: 1, speaker: "speaker",
                               text: "one", confidence: nil,
                               timingPrecision: .coarse),
        ], "empty texts and spans past the batch's result count are dropped")
    }
}

private func XCTAssertEqual(_ value: Int, _ expected: Int, accuracy: Int,
                            _ message: String = "", file: StaticString = #filePath,
                            line: UInt = #line) {
    XCTAssertLessThanOrEqual(abs(value - expected), accuracy,
                             "\(value) not within \(accuracy) of \(expected). \(message)",
                             file: file, line: line)
}
