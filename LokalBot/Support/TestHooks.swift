#if LOKALBOT_TEST_HOOKS
import Foundation

enum TestHooks {
    private static func value(_ key: String) -> String? {
        let value = ProcessInfo.processInfo.environment[key]
        return value?.isEmpty == false ? value : nil
    }

    static var goldenTranscriptsDirectory: URL? {
        value("LOKALBOT_TEST_GOLDEN_TRANSCRIPTS").map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    static var backgroundHostEnabled: Bool { value("LOKALBOT_UI_TEST_BACKGROUND") == "1" }
    static var backgroundTracePath: String? { value("LOKALBOT_UI_TEST_TRACE") }
    static var backgroundAudioDirectory: URL? {
        value("LOKALBOT_UI_TEST_AUDIO").map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    static var filmsAutocomplete: Bool {
        value("LOKALBOT_TEST_FILM_GHOST") == "1"
            || ProcessInfo.processInfo.arguments.contains("--lokalbot-film-ghost")
    }
}

struct GoldenTranscriptionEngine: TranscriptionEngine {
    struct Region: Sendable {
        let track: URL
        let start: TimeInterval
        let end: TimeInterval
    }

    @TaskLocal static var region: Region?

    let directory: URL
    var displayName: String { "Golden transcript" }
    var supportsStreaming: Bool { false }

    func prepare(progress: ModelPreparationProgressHandler?) async throws {}

    func transcribe(audio: URL, language: String?) async throws -> Transcript {
        let region = Self.region
        let source = region?.track ?? audio
        let folderName = source.deletingLastPathComponent().lastPathComponent
        let slug = folderName.replacingOccurrences(of: #"^\d{2}-"#, with: "", options: .regularExpression)
        let track = source.deletingPathExtension().lastPathComponent
        var url = directory.appendingPathComponent(slug).appendingPathComponent("\(track).json")
        if !FileManager.default.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent("default").appendingPathComponent("\(track).json")
        }
        var transcript = try JSONDecoder().decode(Transcript.self, from: Data(contentsOf: url))
        guard let region else { return transcript }
        transcript.segments = transcript.segments.compactMap { segment in
            guard segment.end > region.start, segment.start < region.end else { return nil }
            var clipped = segment
            clipped.start = max(segment.start, region.start) - region.start
            clipped.end = min(segment.end, region.end) - region.start
            return clipped
        }
        return transcript
    }
}
#endif
