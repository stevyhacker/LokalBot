#if LOKALBOT_TEST_HOOKS
import Foundation

/// Switches that exist only in Debug builds (`LOKALBOT_TEST_HOOKS`). Each
/// replaces one external dependency with a recorded fake for CI and the UI
/// background host; release builds never compile this file's effects.
enum TestHooks {
    private static func value(_ key: String) -> String? {
        let value = ProcessInfo.processInfo.environment[key]
        return value?.isEmpty == false ? value : nil
    }

    /// Directory of golden transcripts: `<slug>/<track>.json`.
    static var goldenTranscriptsDirectory: URL? {
        value("LOKALBOT_TEST_GOLDEN_TRANSCRIPTS").map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    static var backgroundHostEnabled: Bool { value("LOKALBOT_UI_TEST_BACKGROUND") == "1" }
    static var backgroundTracePath: String? { value("LOKALBOT_UI_TEST_TRACE") }
    static var backgroundAudioDirectory: URL? {
        value("LOKALBOT_UI_TEST_AUDIO").map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    /// Filming the autocomplete demo (`Scripts/autocomplete-demo`): the ghost
    /// panel stays visible to screen capture and autocomplete logs its states.
    /// Set by `LOKALBOT_TEST_FILM_GHOST=1` or the `--lokalbot-film-ghost`
    /// launch argument, which `open --args` can pass.
    static var filmsAutocomplete: Bool {
        value("LOKALBOT_TEST_FILM_GHOST") == "1"
            || ProcessInfo.processInfo.arguments.contains("--lokalbot-film-ghost")
    }
}

/// Returns the golden transcript for a meeting track instead of running ASR.
struct GoldenTranscriptionEngine: TranscriptionEngine {
    /// The track and time span a sliced region file was cut from. Boundary
    /// reviews transcribe `<temp>/<index>.wav` slices, which name no meeting.
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
        // A manual recording's folder name is generated; it reads `default/`.
        if !FileManager.default.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent("default").appendingPathComponent("\(track).json")
        }
        var transcript = try JSONDecoder().decode(Transcript.self, from: Data(contentsOf: url))
        guard let region else { return transcript }
        // A slice's timestamps start at the region's start.
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
