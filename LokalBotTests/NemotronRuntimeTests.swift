import FluidAudio
import XCTest
@testable import LokalBot

/// Explicit public-fixture test. CI stays offline; see the benchmark README for
/// preparing these pinned models, AMI audio, and the old runtime's voice vectors.
final class NemotronRuntimeTests: XCTestCase {
    struct Baseline: Decodable {
        struct Sample: Decodable { var start: Double; var end: Double; var vector: [Float] }
        struct Segment: Decodable { var start: Double; var end: Double; var speaker: String }
        var voiceSamples: [Sample]?
        var segments: [Segment]
    }

    func testPublicRecordingResetAndVoiceCompatibility() async throws {
        guard let path = ProcessInfo.processInfo.environment["NEMOTRON_BENCH_ROOT"] else {
            throw XCTSkip("Set TEST_RUNNER_NEMOTRON_BENCH_ROOT to the prepared public benchmark directory")
        }
        let root = URL(fileURLWithPath: path)
        let nemotronModels = root.appendingPathComponent("models/nemotron")
        let communityModels = root.appendingPathComponent("models/baseline")
        let engine = NeuralDiarizationEngine(communityLoader: {
            try await OfflineDiarizerModels.load(from: communityModels)
        }, nemotronLoader: {
            try await Nemotron3Models.load(config: .offline, directory: nemotronModels)
        })
        let audio = root.appendingPathComponent("audio/ES2004a.Mix-Headset.wav")
        let reference = try JSONDecoder().decode(Baseline.self,
            from: Data(contentsOf: root.appendingPathComponent("results/offline/ES2004a_mhm.json")))
        let first = try await engine.diarizeDetailed(url: audio, model: .nemotron3, includeVoiceSamples: false)
        XCTAssertTrue(first.samples.isEmpty)
        XCTAssertEqual(first.segments.count, reference.segments.count)
        for (actual, expected) in zip(first.segments, reference.segments) {
            XCTAssertEqual(actual.speakerId, expected.speaker)
            XCTAssertEqual(actual.start, expected.start, accuracy: 0.00001)
            XCTAssertEqual(actual.end, expected.end, accuracy: 0.00001)
        }
        let second = try await engine.diarizeDetailed(url: audio, model: .nemotron3, includeVoiceSamples: true)
        XCTAssertEqual(second.segments.map(\.start), first.segments.map(\.start))
        XCTAssertEqual(second.segments.map(\.end), first.segments.map(\.end))
        XCTAssertEqual(second.segments.map(\.speakerId), first.segments.map(\.speakerId))
        let baseline = try JSONDecoder().decode(Baseline.self,
            from: Data(contentsOf: root.appendingPathComponent("voices-baseline/ES2004a_mhm.json")))
        let samples = try XCTUnwrap(baseline.voiceSamples)
        XCTAssertFalse(samples.isEmpty)
        XCTAssertEqual(second.samples.count, samples.count)
        var maxDifference: Float = 0
        var minimumCosine = 1.0
        for (actual, expected) in zip(second.samples, samples) {
            XCTAssertEqual(actual.range.start, expected.start, accuracy: 0.00001)
            XCTAssertEqual(actual.range.end, expected.end, accuracy: 0.00001)
            XCTAssertEqual(actual.vector.count, 256)
            XCTAssertEqual(expected.vector.count, 256)
            for (a, b) in zip(actual.vector, expected.vector) { maxDifference = max(maxDifference, abs(a - b)) }
            minimumCosine = min(minimumCosine, SpeakerVoiceMatcher.cosine(actual.vector, expected.vector))
            XCTAssertEqual(actual.model, SpeakerVoiceSample.fingerprint)
        }
        // Profiles compare normalized directions, not bitwise-equal model output.
        // CoreML execution can round differently across builds/accelerator routes.
        XCTAssertGreaterThan(minimumCosine, 0.99999)
        print("Nemotron runtime: \(first.segments.count) matching segments; \(samples.count) voice samples; min cosine \(minimumCosine); max component delta \(maxDifference)")
    }
}
