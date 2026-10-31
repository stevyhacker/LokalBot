import AVFoundation
import XCTest
@testable import LokalBot

/// The assistant hears a recording's matched 30 seconds, transcribed on
/// demand with the person's own model, and only when that model is here.
@MainActor
final class FileMomentTranscriberTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("moments-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func testTheClipIsTheMatchedThirtySecondsOrWhatIsLeft() async throws {
        let recording = try writeTone(seconds: 70)
        let clip = folder.appendingPathComponent("clip.m4a")

        try await FileMomentTranscriber.exportClip(of: recording, from: 25, duration: 30, to: clip)
        let clipSeconds = try await AVURLAsset(url: clip).load(.duration).seconds
        XCTAssertEqual(clipSeconds, 30, accuracy: 0.3)

        let tail = folder.appendingPathComponent("tail.m4a")
        try await FileMomentTranscriber.exportClip(of: recording, from: 50, duration: 30, to: tail)
        let tailSeconds = try await AVURLAsset(url: tail).load(.duration).seconds
        XCTAssertEqual(tailSeconds, 20, accuracy: 0.3)
    }

    func testAMomentIsTranscribedOnceAndOnlyWhenTheModelIsHere() async throws {
        let recording = try writeTone(seconds: 40)
        var clips: [TimeInterval] = []
        var available = true
        let transcriber = FileMomentTranscriber(isAvailable: { available }) { clip in
            clips.append(try await AVURLAsset(url: clip).load(.duration).seconds)
            return "  we moved the launch to Thursday  "
        }
        let moment = FileSearchHit(id: 1, path: recording.path, kind: .audio, seconds: 25, excerpt: nil,
                                   modified: Date(), isSemantic: true)

        let first = await transcriber.passage(for: moment)
        let again = await transcriber.passage(for: moment)

        XCTAssertEqual(first, "we moved the launch to Thursday")
        XCTAssertEqual(again, first)
        XCTAssertEqual(clips.count, 1, "the same moment is transcribed once")
        XCTAssertEqual(clips.first ?? 0, 15, accuracy: 0.3)

        available = false
        let elsewhere = FileSearchHit(id: 2, path: recording.path, kind: .audio, seconds: 0, excerpt: nil,
                                      modified: Date(), isSemantic: true)
        let unavailable = await transcriber.passage(for: elsewhere)
        XCTAssertNil(unavailable, "no model on this Mac, or a meeting recording: no transcription")
        let document = FileSearchHit(id: 3, path: recording.path, kind: .doc, excerpt: nil, modified: Date(),
                                     isSemantic: false)
        available = true
        let notAMoment = await transcriber.passage(for: document)
        XCTAssertNil(notAMoment)
        XCTAssertEqual(clips.count, 1)
    }

    func testTheAssistantSeesWhatWasSaidAtTheMoment() {
        let moment = FileSearchHit(id: 7, path: "/Users/me/Podcasts/sleep.mp3", kind: .audio, seconds: 754,
                                   excerpt: nil, modified: Date(timeIntervalSince1970: 0), isSemantic: true)
        let silent = FileSearchHit(id: 8, path: "/Users/me/Movies/zebra.mov", kind: .video, seconds: 12,
                                   excerpt: nil, modified: Date(timeIntervalSince1970: 0), isSemantic: true)

        let text = MeetingChatFormat.fileResults(query: "sleep", hits: [(moment, "naps after lunch help"), (silent, nil)])

        XCTAssertTrue(text.contains("[file:7] sleep.mp3 (Recording · 00:12:34"), text)
        XCTAssertTrue(text.contains("said in these 30 seconds: naps after lunch help"), text)
        XCTAssertTrue(text.contains("[file:8] zebra.mov (Video · 00:00:12"), text)
        XCTAssertTrue(text.contains("matched by its sound or picture; no words transcribed"), text)
    }

    private func writeTone(seconds: Int) throws -> URL {
        let url = folder.appendingPathComponent("tone-\(seconds).wav")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frames = AVAudioFrameCount(16_000 * seconds)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        for index in 0..<Int(frames) { samples[index] = Float(sin(Double(index) * 2 * .pi * 440 / 16_000)) * 0.3 }
        try file.write(from: buffer)
        return url
    }
}
