import XCTest
@testable import LokalBot

final class TranscriptionLanguageReplayTests: XCTestCase {
    private struct Manifest: Decodable {
        struct Track: Decodable {
            var name: String
            var path: String
            var source: String
        }

        struct Condition: Decodable {
            var engine: String
            var language: String?
        }

        var tracks: [Track]
        var conditions: [Condition]
        var vocabulary: String?
        var contentRange: [Double]?
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
                let speech = await ProcessingPipeline.speechRanges(in: url)
                let raw = try await AttributedTrackTranscriber.transcribe(
                    url: url, duration: duration, diarization: diarization.segments, source: source,
                    engine: engine, language: condition.language, prompt: prompt, contentRange: contentRange,
                    speech: speech)
                let transcript = ProcessingPipeline.cleanedTrack(
                    raw, engine: engine, language: condition.language, prompt: prompt, trackName: track.name)
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
