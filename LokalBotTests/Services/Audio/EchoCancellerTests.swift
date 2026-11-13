import XCTest
@testable import LokalBot

/// The echo canceller learns the path from the Mac's speakers back into its
/// microphone and subtracts it, so the user's own voice is what is left.
/// Synthetic room here — a delay plus a decaying tail — because a real room's
/// impulse response is exactly what the filter is supposed to discover.
final class EchoCancellerTests: XCTestCase {

    private let sampleRate = SpanAudioReader.sampleRate

    /// Deterministic noise: `Float.random` would make a convergence assertion
    /// flaky for no benefit. Zero-mean matters — a shared DC offset is a real
    /// component the canceller would correctly subtract, which looks exactly
    /// like it eating the user's voice.
    private func noise(_ count: Int, seed: UInt64 = 42) -> [Float] {
        var state = seed
        return (0..<count).map { _ in
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let unit = Float(state >> 40) / Float(1 << 24)      // [0, 1)
            return unit * 2 - 1
        }
    }

    /// Speaker → room → microphone: a delay and a short decaying tail.
    private func echo(of reference: [Float], delay: Int, gain: Float = 0.5) -> [Float] {
        var out = [Float](repeating: 0, count: reference.count)
        let tail: [Float] = [gain, gain * 0.4, gain * 0.15, gain * 0.05]
        for (offset, weight) in tail.enumerated() {
            let shift = delay + offset * 17
            for n in shift..<reference.count {
                out[n] += weight * reference[n - shift]
            }
        }
        return out
    }

    private func rms(_ samples: [Float]) -> Double {
        guard !samples.isEmpty else { return 0 }
        let sum = samples.reduce(0.0) { $0 + Double($1) * Double($1) }
        return (sum / Double(samples.count)).squareRoot()
    }

    func testCancelsAKnownEchoPath() throws {
        let reference = noise(Int(sampleRate) * 8)
        let microphone = echo(of: reference, delay: 120)
        var canceller = EchoCanceller()

        let residual = try canceller.process(microphone: microphone, reference: reference)

        // Judge the converged tail, not the first pass over an unknown room.
        let tail = Int(sampleRate) * 6
        XCTAssertLessThan(rms(Array(residual[tail...])), rms(Array(microphone[tail...])) * 0.1)
        XCTAssertGreaterThan(canceller.echoReturnLossDB, 10)
    }

    /// Headphones: nothing of the remote audio is in the microphone, and the
    /// filter must leave the user's voice alone rather than fit noise.
    func testLeavesTheMicrophoneAloneWhenThereIsNoEcho() throws {
        let reference = noise(Int(sampleRate) * 8, seed: 7)
        let voice = noise(Int(sampleRate) * 8, seed: 99).map { $0 * 0.3 }
        var canceller = EchoCanceller()

        let residual = try canceller.process(microphone: voice, reference: reference)

        XCTAssertEqual(rms(residual), rms(voice), accuracy: rms(voice) * 0.1)
        XCTAssertLessThan(canceller.echoReturnLossDB, 1)
    }

    /// The user talking over the remote side. Without a double-talk guard the
    /// filter learns to cancel *them*, which is worse than no cancellation —
    /// a first attempt diverged to -17 dB exactly here.
    func testKeepsTheUsersVoiceThroughDoubleTalk() throws {
        let reference = noise(Int(sampleRate) * 10)
        var microphone = echo(of: reference, delay: 120)
        let voice = noise(Int(sampleRate) * 10, seed: 5).map { $0 * 0.6 }
        let talkStart = Int(sampleRate) * 6
        for n in talkStart..<microphone.count { microphone[n] += voice[n] }
        var canceller = EchoCanceller()

        let residual = try canceller.process(microphone: microphone, reference: reference)

        // The user's own words survive at close to their original level.
        let spoken = Array(residual[talkStart...])
        XCTAssertEqual(rms(spoken), rms(Array(voice[talkStart...])), accuracy: rms(voice) * 0.35)
        XCTAssertGreaterThan(canceller.echoReturnLossDB, 3)
    }

    func testFindsTheBulkDelay() {
        let reference = noise(Int(sampleRate) * 6)
        let microphone = echo(of: reference, delay: Int(0.146 * sampleRate))

        let delay = EchoDelayEstimator.delay(microphone: microphone, reference: reference,
                                             sampleRate: sampleRate)

        // Envelope resolution is one 10 ms frame, deliberately biased early so
        // the causal filter can still reach the echo.
        XCTAssertGreaterThan(delay, Int(0.10 * sampleRate))
        XCTAssertLessThanOrEqual(delay, Int(0.146 * sampleRate))
    }

    func testAcceptanceRejectsTheKnownVoiceIsolationRange() {
        func report(_ erle: Double) -> EchoCancelledTrack.Report {
            .init(delaySeconds: 0.1, echoReturnLossDB: erle, processedSeconds: 60)
        }

        XCTAssertFalse(EchoCancelledTrack.shouldUse(report(3.1)))
        XCTAssertFalse(EchoCancelledTrack.shouldUse(report(.nan)))
        XCTAssertFalse(EchoCancelledTrack.shouldUse(report(.infinity)))
        XCTAssertTrue(EchoCancelledTrack.shouldUse(report(12.9)))
    }

    /// Capture paths do not always stop on the same frame. The reference may
    /// end first, but the cleaned sidecar must retain the microphone's full
    /// timeline so ASR does not lose the user's closing words.
    func testShorterReferencePreservesTheWholeMicrophone() async throws {
        let directory = try temporaryDirectory()
        let microphoneURL = directory.appendingPathComponent("mic.wav")
        let referenceURL = directory.appendingPathComponent("system.wav")
        let outputURL = directory.appendingPathComponent("cancelled.wav")
        let reference = noise(Int(sampleRate * 1.25), seed: 101).map { $0 * 0.15 }
        let microphone = noise(Int(sampleRate * 2.25), seed: 202).map { $0 * 0.2 }
        try OnnxTranscriptionEngine.writeWav(reference, to: referenceURL)
        try OnnxTranscriptionEngine.writeWav(microphone, to: microphoneURL)

        let report = try await EchoCancelledTrack.write(
            microphone: microphoneURL,
            reference: referenceURL,
            to: outputURL)

        let outputReader = try SpanAudioReader(url: outputURL)
        let output = try outputReader.samples(from: 0, to: 3)
        XCTAssertEqual(output.count, microphone.count)
        XCTAssertEqual(outputReader.duration, 2.25, accuracy: 1 / sampleRate)
        XCTAssertEqual(report.processedSeconds, 2.25, accuracy: 1 / sampleRate)
        XCTAssertGreaterThan(rms(Array(output[reference.count...])), 0.01,
                             "the microphone-only tail must not be replaced with silence")
    }

    func testWriteCancellationPropagatesAndRemovesPartialDestination() async throws {
        let directory = try temporaryDirectory()
        let microphoneURL = directory.appendingPathComponent("mic.wav")
        let referenceURL = directory.appendingPathComponent("system.wav")
        let outputURL = directory.appendingPathComponent("partial.wav")
        let reference = noise(Int(sampleRate * 8), seed: 303).map { $0 * 0.15 }
        let microphone = echo(of: reference, delay: 120)
        try OnnxTranscriptionEngine.writeWav(reference, to: referenceURL)
        try OnnxTranscriptionEngine.writeWav(microphone, to: microphoneURL)
        try Data("partial".utf8).write(to: outputURL)

        let task = Task {
            try await EchoCancelledTrack.write(
                microphone: microphoneURL,
                reference: referenceURL,
                to: outputURL)
        }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("cancelled echo processing unexpectedly completed")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path))
    }

    /// Runs the whole stage over a real meeting folder when one is pointed at,
    /// so the numbers in the log come from actual audio rather than a model of
    /// it. Skips by default — no fixture, no network, no fixed path.
    func testRealMeetingFolderIfProvided() async throws {
        guard let folder = ProcessInfo.processInfo.environment["LOKALBOT_AEC_FIXTURE"] else {
            throw XCTSkip("set LOKALBOT_AEC_FIXTURE to a meeting folder to run this")
        }
        let root = URL(fileURLWithPath: folder, isDirectory: true)
        // Keep the result when a path is given, so the cleaned track can be
        // measured against the original instead of only being scored by the
        // filter's own ERLE.
        let keep = ProcessInfo.processInfo.environment["LOKALBOT_AEC_OUTPUT"]
        let destination = keep.map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory
                .appendingPathComponent("aec-\(UUID().uuidString).wav")
        defer { if keep == nil { try? FileManager.default.removeItem(at: destination) } }

        let report = try await EchoCancelledTrack.write(
            microphone: root.appendingPathComponent("mic.m4a"),
            reference: root.appendingPathComponent("system.m4a"),
            to: destination)

        print("AEC report: delay=\(report.delaySeconds * 1000) ms "
                + "erle=\(report.echoReturnLossDB) dB "
                + "processed=\(report.processedSeconds) s")
        XCTAssertGreaterThan(report.processedSeconds, 1)
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lokalbot-aec-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory
    }
}
