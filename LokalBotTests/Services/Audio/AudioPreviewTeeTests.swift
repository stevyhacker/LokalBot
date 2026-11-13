import AVFoundation
import XCTest
@testable import LokalBot

final class AudioPreviewTeeTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("audio-preview-tee-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func makeSourceBuffer(format: AVAudioFormat, frames: AVAudioFrameCount) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for channel in 0..<Int(format.channelCount) {
            let samples = buffer.floatChannelData![channel]
            for i in 0..<Int(frames) {
                samples[i] = sinf(Float(i) * 0.05) * 0.4
            }
        }
        return buffer
    }

    func testTeeResamplesToSixteenKilohertzMono() throws {
        let source = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                   sampleRate: 48_000, channels: 2, interleaved: false)!
        let url = dir.appendingPathComponent("tee.caf")
        let tee = try XCTUnwrap(AudioPreviewTee(url: url, sourceFormat: source))

        // One second of 48 kHz stereo, written in recorder-sized slices.
        for _ in 0..<10 {
            tee.write(makeSourceBuffer(format: source, frames: 4_800))
        }
        tee.close()

        let reader = try AVAudioFile(forReading: url)
        XCTAssertEqual(reader.fileFormat.sampleRate, 16_000)
        XCTAssertEqual(reader.fileFormat.channelCount, 1)
        // The resampler may hold back a few frames of latency; the point is
        // that ~1 s in yields ~1 s out.
        XCTAssertEqual(Double(reader.length), 16_000, accuracy: 1_600)
    }

    func testSnapshotOfOpenTeeIsReadable() throws {
        // The property the live transcript depends on: a mid-write copy of the
        // CAF must decode even though the writer is still open (the AAC .m4a
        // tracks fail exactly this).
        let source = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                   sampleRate: 48_000, channels: 1, interleaved: false)!
        let url = dir.appendingPathComponent("growing.caf")
        let tee = try XCTUnwrap(AudioPreviewTee(url: url, sourceFormat: source))
        for _ in 0..<10 {
            tee.write(makeSourceBuffer(format: source, frames: 4_800))
        }

        let snapshot = dir.appendingPathComponent("snapshot.caf")
        try FileManager.default.copyItem(at: url, to: snapshot)
        let reader = try AVAudioFile(forReading: snapshot)
        XCTAssertGreaterThan(reader.length, 8_000)

        tee.close()
    }

    func testReplacesLeftoverFileFromPreviousRun() throws {
        let source = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                   sampleRate: 48_000, channels: 1, interleaved: false)!
        let url = dir.appendingPathComponent("tee.caf")
        try Data("stale".utf8).write(to: url)

        let tee = try XCTUnwrap(AudioPreviewTee(url: url, sourceFormat: source))
        tee.write(makeSourceBuffer(format: source, frames: 48_000))
        tee.close()

        let reader = try AVAudioFile(forReading: url)
        XCTAssertGreaterThan(reader.length, 8_000)
    }
}
