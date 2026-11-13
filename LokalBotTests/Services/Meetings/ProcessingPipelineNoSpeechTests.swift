import AVFoundation
import XCTest
@testable import LokalBot

/// Three silent recordings (June 25, June 30, July 16) stayed in the failed
/// list for months as "No audio tracks found", were re-run through the speech
/// model on every launch, and came back each time the person pressed Retry.
@MainActor
final class ProcessingPipelineNoSpeechTests: XCTestCase {
    func testSilentRecordingFinishesWithAnEmptyTranscript() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let meeting = Meeting(id: UUID(), title: "Manual recording", appName: "Manual",
                              startedAt: Date(), endedAt: Date().addingTimeInterval(10),
                              relativePath: "meetings/2026/07/16-manual-recording")
        let folder = root.appendingPathComponent(meeting.relativePath, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try writeSilence(to: folder.appendingPathComponent("mic.m4a"), seconds: 2)

        var settings = AppSettings()
        settings.multiSpeakerDiarization = false
        settings.echoCancellation = false
        settings.autoTranscriptionVocabulary = false
        let pipeline = ProcessingPipeline(
            storage: StorageManager(rootURL: root),
            settings: { settings },
            automationReadiness: .init(transcription: { _ in true }, think: { _, _ in true }),
            speechSeconds: { _ in 0 })

        var finished = false
        pipeline.onArtifactsWritten = { if $0.id == meeting.id { finished = true } }
        pipeline.enqueue(meeting, transcribe: true, summarize: true)
        for _ in 0..<500 where !finished { try await Task.sleep(for: .milliseconds(10)) }

        XCTAssertTrue(finished)
        XCTAssertNil(pipeline.stages[meeting.id], "a silent recording is finished, not failed")
        let data = try Data(contentsOf: folder.appendingPathComponent("transcript.json"))
        XCTAssertTrue(try JSONDecoder().decode(Transcript.self, from: data).segments.isEmpty)
        XCTAssertNil(MissingTranscription.reason(for: meeting, folder: folder),
                     "launch recovery does not queue it again")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("summary.md").path))
    }

    func testNoSpeechErrorDescribesTheRecordingNotMissingFiles() {
        XCTAssertEqual(ProcessingPipeline.PipelineError.noSpeech.errorDescription,
                       "No speech was detected in this recording.")
    }

    private func writeSilence(to url: URL, seconds: Double) throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1,
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
        let frames = AVAudioFrameCount(seconds * 16_000)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        try file.write(from: buffer)
    }
}
