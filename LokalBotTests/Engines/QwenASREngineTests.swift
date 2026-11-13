import XCTest
import Qwen3ASR
@testable import LokalBot

final class QwenASREngineTests: XCTestCase {
    /// The cache dir handed to the Qwen3ASR package must be the Hub layout
    /// `base/models/<org>/<model>` so its downloader writes into the same
    /// directory `fromPretrained` loads from. A flat path makes the package's
    /// `makeHubApi` fall back to `~/Library/Caches`, leaving the load dir empty
    /// and surfacing "No safetensors files found".
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

    /// Opt-in hardware regression: exercise the same encoder that trapped,
    /// with an already downloaded model and no network or meeting-library I/O.
    func testCachedModelTranscribesSubFrameAudio() async throws {
        guard let path = ProcessInfo.processInfo.environment["LOKALBOT_QWEN_TEST_MODEL_DIR"] else {
            throw XCTSkip("Set LOKALBOT_QWEN_TEST_MODEL_DIR to a cached Qwen model for real inference")
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        let model = try await Qwen3ASRModel.fromPretrained(
            modelId: "aufklarer/\(directory.lastPathComponent)", cacheDir: directory, offlineMode: true)
        for count in [1, 11, 159, 160, 161] {
            let text = model.transcribe(
                audio: QwenASREngine.samplesForInference([Float](repeating: 0, count: count)),
                sampleRate: 16_000, language: "English", maxTokens: 8)
            XCTAssertFalse(text.contains("Text decoder not loaded"))
        }
    }

    /// Compare real speech with a pinned reference across MLX upgrades. The
    /// manifest must name public or synthetic audio and already cached weights.
    func testCachedModelTranscriptionMatchesReferenceWhenProvided() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["LOKALBOT_QWEN_TEST_REFERENCE"],
              let modelPath = environment["LOKALBOT_QWEN_TEST_MODEL_DIR"] else {
            throw XCTSkip("Set cached Qwen weights and a public-audio reference manifest for upgrade parity")
        }
        struct Clip: Decodable {
            let id: String
            let audio: String
            let language: String?
            let text: String
        }
        let clips = try JSONDecoder().decode([Clip].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        XCTAssertFalse(clips.isEmpty)
        let directory = URL(fileURLWithPath: modelPath, isDirectory: true)
        let model = try await Qwen3ASRModel.fromPretrained(
            modelId: "aufklarer/\(directory.lastPathComponent)", cacheDir: directory, offlineMode: true)
        defer { model.unload() }
        var results: [[String: Any]] = []
        for clip in clips {
            let reader = try SpanAudioReader(url: URL(fileURLWithPath: clip.audio))
            let samples = try reader.samples(from: 0, to: reader.duration)
            XCTAssertFalse(samples.isEmpty, clip.id)
            for unblocked in [false, true] {
                let text = try QwenASREngine.transcribeWindow(
                    samples: samples, language: clip.language, prompt: nil,
                    disablesRepetitionBlocking: unblocked, model: model)
                XCTAssertEqual(text, clip.text, "\(clip.id), repetition blocking disabled: \(unblocked)")
                results.append(["id": clip.id, "text": text, "unblocked": unblocked])
            }
        }
        if let output = environment["LOKALBOT_QWEN_TEST_REPORT"] {
            try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys])
                .write(to: URL(fileURLWithPath: output))
        }
    }

    func testCancellationAwareOptionsKeepExistingDecodingPolicy() {
        let ordinary = QwenASREngine.decodingOptions(
            sampleCount: 320_000, language: "Serbian", prompt: "  LokalBot  ", disablesRepetitionBlocking: false)
        XCTAssertEqual(ordinary.maxTokens, 360)
        XCTAssertEqual(ordinary.language, "Serbian")
        XCTAssertEqual(ordinary.context, "LokalBot")
        XCTAssertEqual(ordinary.longInputThresholdSeconds, 15)
        XCTAssertEqual(ordinary.longInputNoRepeatNgramSize, 3)
        XCTAssertEqual(ordinary.noRepeatNgramSize, 0)
        XCTAssertEqual(ordinary.repetitionPenalty, 1)
        XCTAssertEqual(ordinary.temperature, 0)
        let merged = QwenASREngine.decodingOptions(
            sampleCount: 960_000, language: nil, prompt: nil, disablesRepetitionBlocking: true)
        XCTAssertEqual(merged.maxTokens, 768)
        XCTAssertNil(merged.language)
        XCTAssertNil(merged.context)
        XCTAssertEqual(merged.longInputThresholdSeconds, .infinity)
        XCTAssertEqual(merged.noRepeatNgramSize, 0)
    }

    /// Exercises the exact app entry point with real, already cached weights.
    /// The old synchronous API returned text after cancellation, failing this.
    func testCachedModelCancellationThrowsInsteadOfReturningTranscript() async throws {
        guard let path = ProcessInfo.processInfo.environment["LOKALBOT_QWEN_TEST_MODEL_DIR"] else {
            throw XCTSkip("Set LOKALBOT_QWEN_TEST_MODEL_DIR to a cached Qwen model for cancellation regression")
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        let model = try await Qwen3ASRModel.fromPretrained(
            modelId: "aufklarer/\(directory.lastPathComponent)", cacheDir: directory, offlineMode: true)
        defer { model.unload() }
        for unblocked in [false, true] {
            let task = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                return try QwenASREngine.transcribeWindow(
                    samples: [Float](repeating: 0, count: 160), language: "English", prompt: nil,
                    disablesRepetitionBlocking: unblocked, model: model)
            }
            do {
                _ = try await task.value
                XCTFail("Cancelled Qwen decode must throw without returning a partial transcript")
            } catch is CancellationError {
                // No cancelled transcript can be persisted by SpanTranscription.
            }
        }
    }

}
