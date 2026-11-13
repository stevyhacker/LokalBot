import Darwin
import FluidAudio
import Foundation
import MLX
import Qwen3ASR
import XCTest
@testable import LokalBot

/// Opt-in measurement harness for public audio. No UI automation or app settings writes.
final class FunASRComparisonTests: XCTestCase {
    struct Clip: Decodable {
        let id: String
        let audio: String
        let duration: Double
        let kind: String
    }
    struct Fixture: Decodable {
        let nativeModelDirectory: String
        let clips: [Clip]
    }

    @MainActor
    func testPublicAudioComparison() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let fixturePath = environment["LOKALBOT_FUNASR_FIXTURE"],
              let reportPath = environment["LOKALBOT_FUNASR_REPORT"] else {
            throw XCTSkip("Set public-audio comparison fixture and report paths.")
        }
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: fixturePath)))
        let started = Date()
        let model = try await Qwen3ASRModel.fromPretrained(
            modelId: "aufklarer/Qwen3-ASR-1.7B-MLX-8bit",
            cacheDir: URL(fileURLWithPath: fixture.nativeModelDirectory), offlineMode: true)
        let modelLoadSeconds = Date().timeIntervalSince(started)
        let diarizer = NeuralDiarizationEngine()
        let prepareStart = Date()
        await diarizer.prepareModels()
        XCTAssertTrue(diarizer.isReady)
        let diarizerLoadSeconds = Date().timeIntervalSince(prepareStart)
        var rows: [[String: Any]] = []

        func run(_ clip: Clip, warmup: Bool) async throws -> [String: Any] {
            let url = URL(fileURLWithPath: clip.audio)
            let totalStart = Date()
            let spans = try await SpeechActivity.shared.spans(in: url, maxSegmentSeconds: 15)
            let vadSeconds = Date().timeIntervalSince(totalStart)
            let asrStart = Date()
            let transcript = try await SpanTranscription.segments(in: url, spans: spans, speaker: "them") { samples, _ in
                model.transcribe(audio: samples, sampleRate: 16_000, language: "en",
                                 maxTokens: min(768, max(128, Int(Double(samples.count) / 16_000 * 18))),
                                 context: nil)
            }
            let asrSeconds = Date().timeIntervalSince(asrStart)
            let diarizationStart = Date()
            let turns = clip.kind == "meeting" ? await diarizer.diarize(url: url) : []
            let diarizationSeconds = Date().timeIntervalSince(diarizationStart)
            let totalSeconds = Date().timeIntervalSince(totalStart)
            if clip.kind == "meeting" { XCTAssertFalse(turns.isEmpty, clip.id) }
            var usage = rusage()
            getrusage(RUSAGE_SELF, &usage)
            return ["id": clip.id, "warmup": warmup, "duration": clip.duration,
                    "seconds": totalSeconds, "vad_seconds": vadSeconds, "asr_seconds": asrSeconds,
                    "diarization_seconds": diarizationSeconds, "max_rss_bytes": usage.ru_maxrss,
                    "mlx_peak_bytes": MLX.Memory.snapshot().peakMemory,
                    "text": transcript.map(\.text).joined(separator: " "),
                    "spans": spans.map { ["start": $0.start, "end": $0.end] },
                    "segments": transcript.map { segment -> [String: Any] in
                        ["start": segment.start, "end": segment.end, "text": segment.text,
                         "speaker": turns.dominantSpeaker(coveringStart: segment.start, end: segment.end) ?? "unknown"]
                    },
                    "diarization": turns.map { ["start": $0.start, "end": $0.end, "speaker": $0.speakerId] }]
        }

        let warmup = try await run(try XCTUnwrap(fixture.clips.first), warmup: true)
        for clip in fixture.clips {
            rows.append(try await run(clip, warmup: false))
            let report: [String: Any] = ["model_load_seconds": modelLoadSeconds,
                                      "diarizer_load_seconds": diarizerLoadSeconds,
                                      "warmup": warmup, "rows": rows]
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: URL(fileURLWithPath: reportPath), options: .atomic)
            print("FUNASR_NATIVE \(clip.id) \(rows.last?["seconds"] ?? 0)")
        }
    }
}
