import XCTest
@testable import LokalBot

/// A transcription server withdrawn while a meeting is being transcribed: the
/// error that says so has to reach the pipeline, whatever else went wrong on
/// the way, because it decides what happens to the meeting next.
final class WithdrawnTranscriptionServerTests: XCTestCase {
    private let serverError = RemoteTranscriptionError.rejected(status: 503, detail: "busy")
    private let revoked = RemoteTranscriptionError.approvalRequired("https://transcribe.example")

    /// The microphone track failed with a server error, then the server was
    /// revoked during the system track. The first error used to win, and the
    /// meeting was marked failed instead of starting over.
    func testAWithdrawnServerDecidesOverAnEarlierTrackFailure() {
        func failure(_ earlier: Error?, _ later: Error) -> RemoteTranscriptionError? {
            ProcessingPipeline.trackFailure(earlier: earlier, later: later) as? RemoteTranscriptionError
        }
        XCTAssertEqual(failure(serverError, revoked), revoked)
        XCTAssertEqual(failure(serverError, RemoteTranscriptionError.noLongerSelected), .noLongerSelected)
        XCTAssertEqual(failure(revoked, serverError), revoked)
        XCTAssertEqual(failure(nil, serverError), serverError)
        XCTAssertEqual(failure(serverError, RemoteTranscriptionError.unreachable("offline")), serverError,
                       "otherwise the first failure is the one reported")
    }

    /// Throws for every clip, as the server engine does once its approval is gone.
    private struct WithdrawnASR: TranscriptionEngine {
        let error: RemoteTranscriptionError
        var displayName: String { "Withdrawn fixture" }
        var supportsStreaming: Bool { false }
        func prepare(progress: ModelPreparationProgressHandler?) async throws {}
        func transcribe(audio: URL, language: String?) async throws -> Transcript { throw error }
    }

    /// With speaker turns, a region under a second that the engine rejects is
    /// skipped. A withdrawn server is not such a sliver: skipped, the track
    /// finished without the rest of its audio.
    @MainActor func testAWithdrawnServerIsNeverSkippedAsARejectedSliver() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("raw.wav")
        let writer = try WavWriter(url: url, sampleRate: 16_000)
        try writer.append(Array(repeating: Float(0.3), count: 16_000))
        try writer.finish()
        // Every region is shorter than the one-second limit.
        let turns: [DiarizedSegment] = [
            .init(start: 0, end: 0.5, speakerId: "A"),
            .init(start: 0.5, end: 1, speakerId: "B"),
        ]
        for withdrawn in [revoked, RemoteTranscriptionError.noLongerSelected] {
            do {
                _ = try await AttributedTrackTranscriber.transcribe(
                    url: url, duration: 1, diarization: turns, source: .system,
                    engine: WithdrawnASR(error: withdrawn), language: nil, prompt: nil)
                XCTFail("the track finished without its audio")
            } catch {
                XCTAssertEqual(error as? RemoteTranscriptionError, withdrawn)
            }
        }
        // Any other failure on a sliver is still skipped.
        let skipped = try await AttributedTrackTranscriber.transcribe(
            url: url, duration: 1, diarization: turns, source: .system,
            engine: WithdrawnASR(error: serverError), language: nil, prompt: nil)
        XCTAssertTrue(skipped.segments.isEmpty)
    }
}
