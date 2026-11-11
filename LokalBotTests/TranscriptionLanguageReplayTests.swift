import XCTest
@testable import LokalBot

/// Opt-in replay of track transcription on a saved recording, for checking
/// how each engine handles the meeting's language and silent stretches.
/// Runs the steps processing runs for one track (speaker separation,
/// attributed transcription, cleanup) on copies of the tracks, once per
/// engine and language condition. Nothing leaves this Mac.
final class TranscriptionLanguageReplayTests: XCTestCase {
    private struct Manifest: Decodable {
        struct Track: Decodable {
            var name: String
            var path: String
            /// "microphone" or "system".
            var source: String
        }

        struct Condition: Decodable {
            /// "whisper", "qwen-1.7b" or "qwen-0.6b".
            var engine: String
            /// A transcription language code, or nil for auto-detect.
            var language: String?
        }

        var tracks: [Track]
        var conditions: [Condition]
        /// A meeting's saved `transcription-vocabulary.json`, if any.
        var vocabulary: String?
        /// The meeting's content range in seconds, as saved in meta.json.
        var contentRange: [Double]?
        /// Report folder; keep it outside the repository.
        var output: String
    }

    @MainActor
    func testTracksAcrossEnginesAndLanguages() async throws {
        guard let path = ProcessInfo.processInfo.environment["LOKALBOT_TRANSCRIPTION_REPLAY_MANIFEST"] else {
            throw XCTSkip("Set LOKALBOT_TRANSCRIPTION_REPLAY_MANIFEST to replay track transcription on saved audio.")
        }
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let output = URL(fileURLWithPath: manifest.output, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var prompt: String?
        if let vocabulary = manifest.vocabulary {
            let folder = URL(fileURLWithPath: vocabulary).deletingLastPathComponent()
            let saved = try XCTUnwrap(TranscriptionVocabulary.load(from: folder))
            prompt = TranscriptionVocabulary.prompt(manual: "", terms: saved.terms)
        }
        let contentRange = manifest.contentRange.map { Meeting.ContentRange(start: $0[0], end: $0[1]) }
        let settings = AppSettings()
        let diarizer = NeuralDiarizationEngine()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        for track in manifest.tracks {
            let url = URL(fileURLWithPath: track.path)
            let source: SpeakerAttribution.Source = track.source == "microphone" ? .microphone : .system
            let duration = try XCTUnwrap(AudioFileInspector.duration(at: url))
            let diarization = try await diarizer.diarizeDetailed(
                url: url, model: settings.diarizationModel, includeVoiceSamples: false)
            for condition in manifest.conditions {
                let engine: TranscriptionEngine = switch condition.engine {
                case "whisper": WhisperEngine.shared
                case "qwen-0.6b": QwenASREngine.compact
                default: QwenASREngine.accuracy
                }
                let started = Date()
                // The two halves of `ProcessingPipeline.transcribedTrack`, so
                // the report holds the transcript before and after cleanup.
                let speech = await ProcessingPipeline.speechRanges(in: url)
                let raw = try await AttributedTrackTranscriber.transcribe(
                    url: url, duration: duration, diarization: diarization.segments, source: source,
                    engine: engine, language: condition.language, prompt: prompt, contentRange: contentRange,
                    speech: speech)
                let transcript = ProcessingPipeline.cleanedTrack(
                    raw, language: condition.language, prompt: prompt, trackName: track.name)
                let label = "\(condition.engine)-\(condition.language ?? "auto")-\(track.name)"
                try encoder.encode(raw).write(to: output.appendingPathComponent("\(label).raw.json"))
                try encoder.encode(transcript).write(to: output.appendingPathComponent("\(label).json"))
                let line = "\(label) seconds=\(String(format: "%.1f", Date().timeIntervalSince(started))) "
                    + "segments=\(transcript.segments.count)\n"
                let log = output.appendingPathComponent("runs.log")
                if let handle = try? FileHandle(forWritingTo: log) {
                    handle.seekToEndOfFile()
                    handle.write(Data(line.utf8))
                    try handle.close()
                } else {
                    try Data(line.utf8).write(to: log)
                }
            }
        }
    }
}
