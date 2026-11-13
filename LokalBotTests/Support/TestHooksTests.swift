import XCTest
@testable import LokalBot

final class TestHooksTests: XCTestCase {
    func testGoldenEngineReturnsTheTrackTranscriptForTheMeetingSlug() async throws {
        let golden = FileManager.default.temporaryDirectory
            .appendingPathComponent("golden-\(UUID().uuidString)", isDirectory: true)
        let slugFolder = golden.appendingPathComponent("design-review", isDirectory: true)
        try FileManager.default.createDirectory(at: slugFolder, withIntermediateDirectories: true)
        let transcript = Transcript(segments: [
            .init(start: 0, end: 4, speaker: "me", text: "I'll draft the eviction-policy doc by Thursday."),
        ], engine: "golden")
        try JSONEncoder().encode(transcript).write(to: slugFolder.appendingPathComponent("mic.json"))
        let audio = URL(fileURLWithPath: "/tmp/meetings/2026/09/29-design-review/mic.m4a")

        let result = try await GoldenTranscriptionEngine(directory: golden).transcribe(audio: audio, language: nil)
        XCTAssertEqual(result.segments.first?.text, "I'll draft the eviction-policy doc by Thursday.")
    }

    func testMissingGoldenFails() async {
        let engine = GoldenTranscriptionEngine(directory: URL(fileURLWithPath: "/nonexistent"))
        do {
            _ = try await engine.transcribe(audio: URL(fileURLWithPath: "/x/01-a/mic.m4a"), language: nil)
            XCTFail("a missing golden transcript must fail the job, not return nothing")
        } catch {}
    }

    func testParsesSetBoundaries() {
        XCTAssertEqual(HeadlessCommand.parse(["LokalBot", "--set-boundaries", "/tmp/m", "5", "60"]),
                       .setBoundaries(folder: URL(fileURLWithPath: "/tmp/m", isDirectory: true), start: 5, end: 60))
    }

    func testParsesSearchScreen() {
        XCTAssertEqual(HeadlessCommand.parse(["LokalBot", "--search-screen", "connection pool"]),
                       .searchScreen(query: "connection pool"))
    }

    /// Boundary reviews re-transcribe sliced regions of a track; the golden
    /// engine answers a slice with that region's segments, relative to it.
    func testGoldenEngineAnswersARegionSliceRelativeToItsStart() async throws {
        let golden = FileManager.default.temporaryDirectory
            .appendingPathComponent("golden-\(UUID().uuidString)", isDirectory: true)
        let slugFolder = golden.appendingPathComponent("design-review", isDirectory: true)
        try FileManager.default.createDirectory(at: slugFolder, withIntermediateDirectories: true)
        let transcript = Transcript(segments: [
            .init(start: 0, end: 5, speaker: "me", text: "Let's lock the caching layer."),
            .init(start: 16, end: 20, speaker: "me", text: "I'll draft the eviction-policy doc by Thursday."),
            .init(start: 30, end: 35, speaker: "me", text: "I'll borrow the load harness."),
        ], engine: "golden")
        try JSONEncoder().encode(transcript).write(to: slugFolder.appendingPathComponent("mic.json"))
        let track = URL(fileURLWithPath: "/tmp/meetings/2026/09/29-design-review/mic.m4a")
        let slice = URL(fileURLWithPath: "/tmp/lokalbot-speaker-asr-test/0.wav")

        let result = try await GoldenTranscriptionEngine.$region.withValue(
            GoldenTranscriptionEngine.Region(track: track, start: 10, end: 30)) {
            try await GoldenTranscriptionEngine(directory: golden).transcribe(audio: slice, language: nil)
        }
        XCTAssertEqual(result.segments.map(\.text), ["I'll draft the eviction-policy doc by Thursday."])
        XCTAssertEqual(result.segments.first?.start, 6)
        XCTAssertEqual(result.segments.first?.end, 10)
    }

    func testGoldenEngineFallsBackToDefault() async throws {
        let golden = FileManager.default.temporaryDirectory.appendingPathComponent("golden-\(UUID())", isDirectory: true)
        let fallback = golden.appendingPathComponent("default", isDirectory: true)
        try FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: true)
        try JSONEncoder().encode(Transcript(segments: [
            .init(start: 0, end: 4, speaker: "me", text: "Fallback line."),
        ], engine: "golden")).write(to: fallback.appendingPathComponent("mic.json"))
        let result = try await GoldenTranscriptionEngine(directory: golden)
            .transcribe(audio: URL(fileURLWithPath: "/x/01-unknown/mic.m4a"), language: nil)
        XCTAssertEqual(result.segments.first?.text, "Fallback line.")
    }
}
