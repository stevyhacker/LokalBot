import XCTest
@testable import LokalBot

final class LiveTranscriptChunkerTests: XCTestCase {

    private let rate = 16_000.0

    // MARK: - nextChunk

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

    // MARK: - refinedCutOffset

    func testCutLandsInTheQuietValley() {
        // 1.5 s of loud signal with a silent stretch at a known position.
        var tail = [Float](repeating: 0.5, count: Int(LiveTranscriptChunker.cutSearchSeconds * rate))
        let valleyStart = 8_000
        let window = Int(0.2 * rate)
        for i in valleyStart..<(valleyStart + window) { tail[i] = 0 }
        let cut = LiveTranscriptChunker.refinedCutOffset(tail: tail, sampleRate: rate)
        XCTAssertEqual(cut, valleyStart + window / 2)
    }

    func testShortTailCutsAtItsEnd() {
        let tail = [Float](repeating: 0.5, count: 1_000) // shorter than the 200 ms window
        XCTAssertEqual(LiveTranscriptChunker.refinedCutOffset(tail: tail, sampleRate: rate), 1_000)
    }

    func testUniformTailStillReturnsAValidOffset() {
        let tail = [Float](repeating: 0.3, count: Int(rate))
        let cut = LiveTranscriptChunker.refinedCutOffset(tail: tail, sampleRate: rate)
        XCTAssertGreaterThan(cut, 0)
        XCTAssertLessThanOrEqual(cut, tail.count)
    }

    // MARK: - Conservative prefilter (VAD makes the speech decision)

    func testPureSilenceHasNoSpeech() {
        // A dead input (several seconds of digital zeros) must never reach the ASR.
        XCTAssertFalse(isCandidate(
            [Float](repeating: 0, count: Int(4 * rate)), sampleRate: rate))
    }

    func testStationaryRoomToneIsLeftForVAD() {
        // Room tone reaches the speech detector; energy alone cannot reliably
        // distinguish steady speech from steady background noise.
        XCTAssertTrue(isCandidate(
            tone(amplitude: 0.02, seconds: 4), sampleRate: rate))
    }

    func testStationaryHumIsLeftForVAD() {
        // A steady signal must not be rejected solely for lacking dynamics.
        XCTAssertTrue(isCandidate(
            tone(amplitude: 0.25, seconds: 4), sampleRate: rate))
    }

    func testAmplitudeModulatedSubsonicRumbleHasNoSpeech() {
        // Regression: the live mic tee carried strong 10–50 Hz drift whose
        // changing amplitude cleared the dynamics gate and made Granite emit
        // fluent sentences in random languages. It has no speech-band energy.
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
        // Syllable-like bursts over a quiet floor, 0.9 s total: clearly speech.
        var samples = tone(amplitude: 0.002, seconds: 6)
        for second in [1.0, 3.0, 5.0] {
            burst(into: &samples, at: second, seconds: 0.3, amplitude: 0.1)
        }
        XCTAssertTrue(isCandidate(samples, sampleRate: rate))
    }

    func testQuietBurstsJustAboveAbsoluteFloorHaveSpeech() {
        // Very quiet speech (burst RMS ≈ 0.014, ~4.7× the absolute floor) over
        // a near-silent room must still pass the gate.
        var samples = tone(amplitude: 0.0005, seconds: 6)
        for second in [1.0, 3.0, 5.0] {
            burst(into: &samples, at: second, seconds: 0.3, amplitude: 0.02)
        }
        XCTAssertTrue(isCandidate(samples, sampleRate: rate))
    }

    func testSpeechOverHotRoomToneHasSpeech() {
        // Dynamics rescue what an absolute threshold would misjudge: the same
        // hot room tone as the regression case, plus real speech bursts.
        var samples = tone(amplitude: 0.02, seconds: 6)
        for second in [1.0, 3.0, 5.0] {
            burst(into: &samples, at: second, seconds: 0.3, amplitude: 0.2)
        }
        XCTAssertTrue(isCandidate(samples, sampleRate: rate))
    }

    func testLowVoiceFundamentalAndHarmonicsStillHaveSpeech() {
        // A 95 Hz fundamental is below the cleanup cutoff, but a natural voice
        // carries harmonics above it. The rumble filter must not erase that.
        var samples = [Float](repeating: 0, count: Int(6 * rate))
        for second in [1.0, 3.0, 5.0] {
            voicedBurst(into: &samples, at: second, seconds: 0.45)
        }
        XCTAssertTrue(isCandidate(samples, sampleRate: rate))
        XCTAssertNotNil(LiveTranscriptChunker.speechCandidate(from: samples, sampleRate: rate))
    }

    func testShortBurstIsLeftForVAD() {
        // Do not reject brief replies based on duration. VAD distinguishes
        // an actual short utterance from a thump or keyboard click.
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
        // Shorter than one 200 ms window: falls back to whole-chunk RMS.
        XCTAssertTrue(isCandidate(
            tone(amplitude: 0.1, seconds: 0.1), sampleRate: rate))
    }

    func testSubWindowChunkBelowAbsoluteFloorHasNoSpeech() {
        // Shorter than one window and below the absolute floor: not speech.
        XCTAssertFalse(isCandidate(
            tone(amplitude: 0.002, seconds: 0.1), sampleRate: rate))
    }

    private func isCandidate(_ samples: [Float], sampleRate: Double) -> Bool {
        LiveTranscriptChunker.speechCandidate(from: samples, sampleRate: sampleRate) != nil
    }

    // MARK: - Synthesis helpers

    /// 400 Hz sine: its 40-sample period at 16 kHz divides the gate's window
    /// and hop exactly, so every full window has RMS = amplitude/√2 and every
    /// test is fully deterministic.
    private func tone(amplitude: Float, seconds: Double, frequency: Double = 400) -> [Float] {
        (0..<Int((seconds * rate).rounded())).map {
            amplitude * Float(sin(2 * Double.pi * frequency * Double($0) / rate))
        }
    }

    /// Overwrite a hop-aligned stretch of `samples` with a louder 400 Hz
    /// burst, standing in for a run of syllables.
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
