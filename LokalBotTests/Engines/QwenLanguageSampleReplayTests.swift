import XCTest
@testable import LokalBot

/// Opt-in replay for Benchmarks/transcribe/QwenLanguageSample. Decodes
/// benchmark tracks on Qwen3-ASR 1.7B's llama-server with the language on
/// auto-detect, as the engine did before language sampling (`before`: every
/// window on auto, then the whole track again when its vote holds) and as it
/// does now (`after`: `QwenASREngine.decodeOnAuto`). Windows come from the
/// app's own VAD path, in the plain layout (`transcribe`) or the merged
/// word-attribution layout. Each track, layout and mode appends one JSON line
/// with every window decode, its time and its language vote, and the result.
///
/// LOKALBOT_QWEN_SAMPLE_MANIFEST names the job (see make_manifest.py there);
/// LOKALBOT_QWEN_LLAMA_TEST_MODEL_DIR holds both 1.7B GGUFs. Runs resume.
final class QwenLanguageSampleReplayTests: XCTestCase {
    private struct Manifest: Decodable {
        struct Track: Decodable {
            var id: String
            var wav: String
        }

        var output: String
        /// "before" and/or "after", run in this order for each track and layout.
        var modes: [String]
        /// Reverse the order of `modes` on every other track and layout, so
        /// the two paths of a pair share the machine's state for timing.
        var alternate: Bool?
        /// "plain" (VAD spans of at most 15 s) and/or "word" (merged windows).
        var layouts: [String]
        /// Sample sizes whose spans are recorded for the offline simulation.
        var sampleSizes: [Int]
        var tracks: [Track]
    }

    private struct Window: Encodable {
        var index: Int
        /// nil: auto-detect.
        var language: String?
        var text: String
        var seconds: Double
        /// Auto windows: the language this window's text votes for, aliased
        /// as the engine's vote does, and its weight (characters); nil and 0
        /// when it does not vote.
        var vote: String?
        var weight: Int
    }

    private struct Record: Encodable {
        var id: String
        var layout: String
        var mode: String
        var spans: [[Double]]
        var audioSeconds: Double
        var vadSeconds: Double
        var decodeSeconds: Double
        var pinned: String?
        var sampled: Int
        var decodedTwice: Bool
        var needsSpeakerRegions: Bool
        var text: String
        var windows: [Window]
        var samples: [String: [Int]]
    }

    private final class Log: @unchecked Sendable {
        var windows: [Window] = []
    }

    func testReplayBenchmarkTracks() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let manifestPath = environment["LOKALBOT_QWEN_SAMPLE_MANIFEST"],
              let modelPath = environment["LOKALBOT_QWEN_LLAMA_TEST_MODEL_DIR"] else {
            throw XCTSkip("Set LOKALBOT_QWEN_SAMPLE_MANIFEST and LOKALBOT_QWEN_LLAMA_TEST_MODEL_DIR (both 1.7B GGUFs)")
        }
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: URL(fileURLWithPath: manifestPath)))
        let outputURL = URL(fileURLWithPath: manifest.output)
        var done = Set<String>()
        if let existing = try? String(contentsOf: outputURL, encoding: .utf8) {
            for line in existing.split(separator: "\n") {
                guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      let id = object["id"] as? String, let layout = object["layout"] as? String,
                      let mode = object["mode"] as? String else { continue }
                done.insert("\(id)|\(layout)|\(mode)")
            }
        } else {
            FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: outputURL)
        defer { try? handle.close() }
        handle.seekToEndOfFile()

        let models = URL(fileURLWithPath: modelPath, isDirectory: true)
        let weights = QwenLlamaASR.accuracy
        let server = weights.makeServer(projector: models.appendingPathComponent(weights.projector.name))
        guard LocalLlamaServerAuthentication.readMarker(port: server.port) == nil else {
            throw XCTSkip("Needs the unused port \(server.port).")
        }
        do {
            try await server.ensureRunning(modelAt: models.appendingPathComponent(weights.model.name))
            try await replay(manifest, done: done, server: server, handle: handle)
        } catch {
            await server.stop()
            throw error
        }
        await server.stop()
    }

    private func replay(_ manifest: Manifest, done: Set<String>, server: LlamaServer, handle: FileHandle) async throws {
        var warmedUp = false
        var pairs = 0
        for track in manifest.tracks {
            let url = URL(fileURLWithPath: track.wav)
            let pending = manifest.layouts.enumerated().flatMap { position, layout in
                let reversed = manifest.alternate == true && (pairs + position) % 2 == 1
                return (reversed ? manifest.modes.reversed() : manifest.modes).map { (layout, $0) }
            }.filter { !done.contains("\(track.id)|\($0.0)|\($0.1)") }
            pairs += manifest.layouts.count
            guard !pending.isEmpty else { continue }
            let vadStarted = Date()
            guard let vadSpans = await SpeechActivity.shared.vadSpans(in: url, maxSegmentSeconds: 15) else {
                return XCTFail("VAD is unavailable; the replay needs the app's own windows")
            }
            let vadSeconds = Date().timeIntervalSince(vadStarted)
            let reader = try SpanAudioReader(url: url)
            if !warmedUp, let first = vadSpans.first {
                // The first decode after launch pays Metal's shader compilation.
                _ = try await QwenASREngine.transcribeWindow(
                    samples: try reader.samples(from: first.start, to: first.end), language: "en", prompt: nil, server: server)
                warmedUp = true
            }
            for (layout, mode) in pending {
                var spans = vadSpans
                if layout == "word" {
                    let windows = QwenASREngine.wordAttributionWindows(for: .accuracy)
                    spans = QwenASREngine.merged(spans, maxGap: windows.maxGapSeconds, maxLength: windows.maxSeconds)
                }
                let index = Dictionary(uniqueKeysWithValues: spans.enumerated().map { ($1.start, $0) })
                let log = Log()
                // The engine's decoder, timed per window (no prompt, so no echoes to drop).
                let decode: QwenASREngine.SpanDecoder = { batch, language in
                    try await SpanTranscription.segments(in: url, spans: batch) { samples, position in
                        let started = Date()
                        let raw = try await QwenASREngine.transcribeWindow(
                            samples: samples, language: language, prompt: nil, server: server)
                        let text = Transcript.normalizedText(raw)
                        let vote = language == nil ? TranscriptLanguageVote.dominant(
                            in: [text], aliases: TranscriptLanguageVote.serbianCroatianAliases)?.code : nil
                        log.windows.append(Window(index: index[batch[position].start] ?? -1, language: language,
                                                  text: text, seconds: Date().timeIntervalSince(started),
                                                  vote: vote, weight: vote == nil ? 0 : text.count))
                        return raw
                    }
                }
                let started = Date()
                let decision: QwenASREngine.AutoLanguageDecision
                if mode == "before" {
                    decision = try await decodeAsBefore(spans, wordAttribution: layout == "word", decode: decode)
                } else {
                    decision = try await QwenASREngine.decodeOnAuto(spans, wordAttribution: layout == "word", decode: decode)
                }
                let record = Record(
                    id: track.id, layout: layout, mode: mode, spans: spans.map { [$0.start, $0.end] },
                    audioSeconds: spans.last?.end ?? 0, vadSeconds: vadSeconds,
                    decodeSeconds: Date().timeIntervalSince(started), pinned: decision.pinned,
                    sampled: decision.sampled, decodedTwice: decision.decodedTwice,
                    needsSpeakerRegions: decision.needsSpeakerRegions,
                    text: decision.segments.map(\.text).joined(separator: " "), windows: log.windows,
                    samples: Dictionary(uniqueKeysWithValues: manifest.sampleSizes.map {
                        (String($0), QwenASREngine.languageSample(spans, count: $0))
                    }))
                handle.write(try JSONEncoder().encode(record))
                handle.write(Data("\n".utf8))
                print("qwen-sample \(track.id) \(layout) \(mode): \(spans.count) windows, "
                    + "\(String(format: "%.1f", record.decodeSeconds)) s, pinned=\(decision.pinned ?? "none")")
            }
        }
    }

    /// The engine's auto-detect path before language sampling, line for line:
    /// every window on auto, the whole-track vote, and every window again in
    /// the voted language unless the aligner cannot time it.
    private func decodeAsBefore(_ spans: [SpeechSpan], wordAttribution: Bool,
                                decode: QwenASREngine.SpanDecoder) async throws -> QwenASREngine.AutoLanguageDecision {
        let segments = try await decode(spans, nil)
        guard let vote = QwenASREngine.pinnedLanguage(for: segments.map(\.text)) else {
            return .init(segments: segments, pinned: nil, sampled: spans.count, decodedTwice: false,
                         needsSpeakerRegions: false)
        }
        guard !wordAttribution || QwenWordAligner.supports(vote) else {
            return .init(segments: segments, pinned: vote, sampled: spans.count, decodedTwice: false,
                         needsSpeakerRegions: true)
        }
        return .init(segments: try await decode(spans, vote), pinned: vote, sampled: spans.count,
                     decodedTwice: true, needsSpeakerRegions: false)
    }
}
