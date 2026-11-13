import AVFoundation
import XCTest
@testable import LokalBot

final class AudioFileInspectorTests: XCTestCase {
    func testRejectsHeaderOnlyAudioFile() throws {
        let url = temporaryURL(name: "empty.caf")
        do {
            let file = try AVAudioFile(
                forWriting: url,
                settings: [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: 16_000,
                    AVNumberOfChannelsKey: 1,
                    AVLinearPCMBitDepthKey: 32,
                    AVLinearPCMIsFloatKey: true,
                    AVLinearPCMIsNonInterleaved: true,
                ])
            XCTAssertEqual(file.length, 0)
        }

        XCTAssertFalse(AudioFileInspector.isTranscribableAudio(at: url))
    }

    func testAcceptsAudioAboveMinimumDuration() throws {
        let url = temporaryURL(name: "speech.caf")
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                                 sampleRate: 16_000,
                                                 channels: 1,
                                                 interleaved: false))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8_000))
        buffer.frameLength = 8_000

        do {
            let file = try AVAudioFile(
                forWriting: url,
                settings: [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: 16_000,
                    AVNumberOfChannelsKey: 1,
                    AVLinearPCMBitDepthKey: 32,
                    AVLinearPCMIsFloatKey: true,
                    AVLinearPCMIsNonInterleaved: true,
                ])
            try file.write(from: buffer)
            XCTAssertGreaterThan(file.length, 0)
        }

        XCTAssertTrue(AudioFileInspector.isTranscribableAudio(at: url))
    }

    func testWriteWavIsReadable16kHzMonoPCM() throws {
        let url = temporaryURL(name: "onnx.wav")
        // 0.5 s sawtooth so sample fidelity is checkable through int16.
        let samples = (0..<8_000).map { Float($0 % 200) / 200.0 - 0.5 }
        try OnnxTranscriptionEngine.writeWav(samples, to: url)

        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(file.fileFormat.sampleRate, 16_000)
        XCTAssertEqual(file.fileFormat.channelCount, 1)
        XCTAssertEqual(Int(file.length), samples.count, "frame count must match the input")
        XCTAssertTrue(AudioFileInspector.isTranscribableAudio(at: url),
                      "the hand-rolled WAV must be valid, transcribable audio")

        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                    frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let read = try XCTUnwrap(buffer.floatChannelData?[0])
        XCTAssertEqual(read[1_000], samples[1_000], accuracy: 2.0 / 32_767, "int16 round-trip")
    }

    private func temporaryURL(name: String) -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(name)
    }
}
