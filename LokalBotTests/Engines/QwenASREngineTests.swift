import XCTest
import Qwen3ForcedAlignerCoreML
@testable import LokalBot

final class QwenASREngineTests: XCTestCase {
    /// speech-swift's loaders use the Hub layout `base/models/<org>/<model>`.
    /// The forced aligner lives there, and both Qwen tiers find the MLX
    /// weights they replaced there to delete them.
    func testHubStyleCacheDirMatchesPackageLayout() {
        let base = URL(fileURLWithPath: "/tmp/qwen3-asr-models", isDirectory: true)
        let dir = QwenASREngine.hubStyleCacheDir(
            base: base, modelID: "aufklarer/Qwen3-ASR-0.6B-MLX-4bit")
        XCTAssertEqual(
            dir.path, "/tmp/qwen3-asr-models/models/aufklarer/Qwen3-ASR-0.6B-MLX-4bit")
    }

    func testSubFrameAudioRetainsSamplesAndProducesEncoderFrames() {
        let extractor = WhisperFeatureExtractor()
        // The crash left a 30 s + 11-sample WAV. Its final split had no
        // features, causing Qwen3AudioEncoder to stack an empty array.
        XCTAssertEqual(extractor.extractFeaturesRaw([Float](repeating: 0.25, count: 11)).timeFrames, 0)
        for count in [1, 11, 159, 160, 161, 400] {
            let original = [Float](repeating: 0.25, count: count)
            let input = QwenASREngine.samplesForInference(original)
            XCTAssertEqual(Array(input.prefix(count)), original)
            XCTAssertTrue(input.dropFirst(count).allSatisfy { $0 == 0 })
            XCTAssertGreaterThan(extractor.extractFeaturesRaw(input).timeFrames, 0,
                                 "Qwen needs at least one feature frame for \(count) samples")
            if count >= extractor.hopLength { XCTAssertEqual(input, original) }
        }
        XCTAssertTrue(QwenASREngine.samplesForInference([]).isEmpty)
    }

    func testTinySplitTailKeepsAudioAndOriginalTimestamps() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("qwen-tail-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try OnnxTranscriptionEngine.writeWav([Float](repeating: 0.25, count: 480_011), to: url)
        let duration = try SpanAudioReader(url: url).duration
        let spans = SpeechActivity.split(start: 0, end: duration, maxSegmentSeconds: 15)
        let extractor = WhisperFeatureExtractor()
        var sampleCounts: [Int] = []
        let segments = try await SpanTranscription.segments(in: url, spans: spans) { samples, _ in
            sampleCounts.append(samples.count)
            let features = extractor.extractFeaturesRaw(QwenASREngine.samplesForInference(samples))
            XCTAssertGreaterThan(features.timeFrames, 0)
            return "recognized speech"
        }
        XCTAssertEqual(sampleCounts, [240_000, 240_000, 11])
        XCTAssertEqual(segments.map(\.start), [0, 15, 30])
        XCTAssertEqual(segments.map(\.end), [15, 30, duration])
    }
}
