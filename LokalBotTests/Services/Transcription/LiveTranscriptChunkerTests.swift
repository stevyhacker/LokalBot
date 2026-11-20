import XCTest
@testable import LokalBot

final class LiveTranscriptChunkerTests: XCTestCase {

    private let rate = 16_000.0

    func testNoChunkUntilMinimumAudioAvailable() {
        let justUnder = Int64(LiveTranscriptChunker.minChunkSeconds * rate) - 1
        XCTAssertNil(LiveTranscriptChunker.nextChunk(
            processedFrames: 0, totalFrames: justUnder, sampleRate: rate))
    }

    func testChunkAtExactMinimumBoundary() {
        let exactly = Int64(LiveTranscriptChunker.minChunkSeconds * rate)
        let chunk = LiveTranscriptChunker.nextChunk(
            processedFrames: 0, totalFrames: exactly, sampleRate: rate)
        XCTAssertEqual(chunk, 0..<exactly)
    }

    func testChunkCappedAtTargetWhenBacklogIsLarge() {
        let total = Int64(60 * rate)
        let chunk = LiveTranscriptChunker.nextChunk(
            processedFrames: 0, totalFrames: total, sampleRate: rate)
        XCTAssertEqual(chunk, 0..<Int64(LiveTranscriptChunker.targetChunkSeconds * rate))
    }

    func testChunkStartsAtProcessedFrames() {
        let processed = Int64(10 * rate)
        let total = Int64(16 * rate)
        let chunk = LiveTranscriptChunker.nextChunk(
            processedFrames: processed, totalFrames: total, sampleRate: rate)
        XCTAssertEqual(chunk, processed..<total)
    }

    func testZeroSampleRateProducesNoChunk() {
        XCTAssertNil(LiveTranscriptChunker.nextChunk(
            processedFrames: 0, totalFrames: 1_000_000, sampleRate: 0))
    }

    func testCutLandsInTheQuietValley() {
        var tail = [Float](repeating: 0.5, count: Int(LiveTranscriptChunker.cutSearchSeconds * rate))
        let valleyStart = 8_000
        let window = Int(0.2 * rate)
        for i in valleyStart..<(valleyStart + window) { tail[i] = 0 }
        let cut = LiveTranscriptChunker.refinedCutOffset(tail: tail, sampleRate: rate)
        XCTAssertEqual(cut, valleyStart + window / 2)
    }

    func testShortTailCutsAtItsEnd() {
        let tail = [Float](repeating: 0.5, count: 1_000)
        XCTAssertEqual(LiveTranscriptChunker.refinedCutOffset(tail: tail, sampleRate: rate), 1_000)
    }

    func testUniformTailStillReturnsAValidOffset() {
        let tail = [Float](repeating: 0.3, count: Int(rate))
        let cut = LiveTranscriptChunker.refinedCutOffset(tail: tail, sampleRate: rate)
        XCTAssertGreaterThan(cut, 0)
        XCTAssertLessThanOrEqual(cut, tail.count)
    }

    func testPureSilenceHasNoSpeech() {
        XCTAssertFalse(isCandidate(
            [Float](repeating: 0, count: Int(4 * rate)), sampleRate: rate))
    }

    func testStationaryRoomToneIsLeftForVAD() {
        XCTAssertTrue(isCandidate(
            tone(amplitude: 0.02, seconds: 4), sampleRate: rate))
    }

    func testStationaryHumIsLeftForVAD() {
        XCTAssertTrue(isCandidate(
            tone(amplitude: 0.25, seconds: 4), sampleRate: rate))
    }

    func testAmplitudeModulatedSubsonicRumbleHasNoSpeech() {
        var samples = tone(amplitude: 0.004, seconds: 6, frequency: 15)
        for second in [1.0, 3.0, 5.0] {
            burst(
                into: &samples,
                at: second,
                seconds: 0.4,
                amplitude: 0.04,
                frequency: 15)
        }
        XCTAssertFalse(isCandidate(samples, sampleRate: rate))
        XCTAssertNil(LiveTranscriptChunker.speechCandidate(from: samples, sampleRate: rate))
    }

    func testSpeechLikeBurstsOverQuietFloorHaveSpeech() {
        var samples = tone(amplitude: 0.002, seconds: 6)
        for second in [1.0, 3.0, 5.0] {
            burst(into: &samples, at: second, seconds: 0.3, amplitude: 0.1)
        }
        XCTAssertTrue(isCandidate(samples, sampleRate: rate))
    }

    func testQuietBurstsJustAboveAbsoluteFloorHaveSpeech() {
        var samples = tone(amplitude: 0.0005, seconds: 6)
        for second in [1.0, 3.0, 5.0] {
            burst(into: &samples, at: second, seconds: 0.3, amplitude: 0.02)
        }
        XCTAssertTrue(isCandidate(samples, sampleRate: rate))
    }

    func testSpeechOverHotRoomToneHasSpeech() {
        var samples = tone(amplitude: 0.02, seconds: 6)
        for second in [1.0, 3.0, 5.0] {
            burst(into: &samples, at: second, seconds: 0.3, amplitude: 0.2)
        }
        XCTAssertTrue(isCandidate(samples, sampleRate: rate))
    }

    func testLowVoiceFundamentalAndHarmonicsStillHaveSpeech() {
        var samples = [Float](repeating: 0, count: Int(6 * rate))
        for second in [1.0, 3.0, 5.0] {
            voicedBurst(into: &samples, at: second, seconds: 0.45)
        }
        XCTAssertTrue(isCandidate(samples, sampleRate: rate))
        XCTAssertNotNil(LiveTranscriptChunker.speechCandidate(from: samples, sampleRate: rate))
    }

    func testShortBurstIsLeftForVAD() {
        var samples = tone(amplitude: 0.002, seconds: 6)
        burst(into: &samples, at: 3.0, seconds: 0.2, amplitude: 0.1)
        XCTAssertTrue(isCandidate(samples, sampleRate: rate))
    }

    func testBriefQuietSpeechIsNotDilutedByTheWholeChunk() {
        var samples = [Float](repeating: 0, count: Int(12 * rate))
        burst(into: &samples, at: 4, seconds: 0.3, amplitude: 0.015)
        XCTAssertTrue(isCandidate(samples, sampleRate: rate))
    }

    func testContinuousVoiceCandidateDoesNotRequireTenDecibelsOfVariation() {
        var samples = [Float](repeating: 0, count: Int(6 * rate))
        for i in samples.indices {
            let t = Double(i) / rate
            let envelope = 0.08 + 0.02 * sin(2 * .pi * 3 * t)
            samples[i] = Float(envelope * (sin(2 * .pi * 190 * t) + 0.5 * sin(2 * .pi * 380 * t)))
        }
        XCTAssertTrue(isCandidate(samples, sampleRate: rate))
    }

    func testInvalidChunkBoundsReturnNoWork() {
        XCTAssertNil(LiveTranscriptChunker.nextChunk(processedFrames: -1, totalFrames: 100, sampleRate: rate))
        XCTAssertNil(LiveTranscriptChunker.nextChunk(processedFrames: 200, totalFrames: 100, sampleRate: rate))
        XCTAssertNil(LiveTranscriptChunker.nextChunk(processedFrames: 0, totalFrames: 100, sampleRate: .infinity))
    }

    func testEmptyChunkHasNoSpeech() {
        XCTAssertFalse(isCandidate([], sampleRate: rate))
    }

    func testZeroSampleRateHasNoSpeech() {
        XCTAssertFalse(isCandidate(
            [Float](repeating: 0.1, count: 16_000), sampleRate: 0))
    }

    func testSubWindowChunkAboveAbsoluteFloorHasSpeech() {
        XCTAssertTrue(isCandidate(
            tone(amplitude: 0.1, seconds: 0.1), sampleRate: rate))
    }

    func testSubWindowChunkBelowAbsoluteFloorHasNoSpeech() {
        XCTAssertFalse(isCandidate(
            tone(amplitude: 0.002, seconds: 0.1), sampleRate: rate))
    }

    private func isCandidate(_ samples: [Float], sampleRate: Double) -> Bool {
        LiveTranscriptChunker.speechCandidate(from: samples, sampleRate: sampleRate) != nil
    }

    private func tone(amplitude: Float, seconds: Double, frequency: Double = 400) -> [Float] {
        (0..<Int((seconds * rate).rounded())).map {
            amplitude * Float(sin(2 * Double.pi * frequency * Double($0) / rate))
        }
    }

    private func burst(into samples: inout [Float], at second: Double,
                       seconds: Double, amplitude: Float, frequency: Double = 400) {
        let start = Int((second * rate).rounded())
        for i in 0..<Int((seconds * rate).rounded()) {
            samples[start + i] = amplitude * Float(
                sin(2 * Double.pi * frequency * Double(i) / rate))
        }
    }

    private func voicedBurst(into samples: inout [Float], at second: Double,
                             seconds: Double) {
        let start = Int((second * rate).rounded())
        for i in 0..<Int((seconds * rate).rounded()) {
            let time = Double(i) / rate
            samples[start + i] =
                0.05 * Float(sin(2 * Double.pi * 95 * time))
                + 0.035 * Float(sin(2 * Double.pi * 190 * time))
                + 0.02 * Float(sin(2 * Double.pi * 285 * time))
        }
    }
}
