import AVFoundation
import XCTest
@testable import LokalBot

/// The real writer, preview tee, and health path, fed from a file instead of
/// the microphone — what the UI background host and CI use.
final class MicRecorderFileInputTests: XCTestCase {
    func testFileInputRecordsThroughTheRealWriter() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("mic-file-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("tone.wav")
        try Self.writeTone(to: source, seconds: 2)

        let recorder = MicRecorder(makeInput: { try FileMicrophoneInput(url: source, speed: 4) })
        let output = folder.appendingPathComponent("mic.m4a")
        try recorder.start(writingTo: output)
        Thread.sleep(forTimeInterval: 1.0)
        let health = recorder.captureHealth()
        recorder.stop()

        XCTAssertGreaterThan(health.duration, 1.5, "about 4 s of audio at 4× speed")
        XCTAssertNotNil(health.lastSignalAt)
        let written = try AVAudioFile(forReading: output)
        XCTAssertGreaterThan(written.length, 0)
    }

    /// #373: a closed MacBook lid leaves the default input writing digital
    /// silence. Those writes must not count as signal, while a room-noise
    /// level input (about -69 dBFS) still does.
    func testDigitalSilenceIsWrittenButIsNotSignal() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("mic-file-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        for (amplitude, isSignal) in [(Float(0), false), (Float(0.0005), true)] {
            let source = folder.appendingPathComponent("input-\(amplitude).wav")
            try Self.writeTone(to: source, seconds: 2, amplitude: amplitude)
            let recorder = MicRecorder(makeInput: { try FileMicrophoneInput(url: source, speed: 4) })
            try recorder.start(writingTo: folder.appendingPathComponent("mic-\(amplitude).m4a"))
            Thread.sleep(forTimeInterval: 1.0)
            let health = recorder.captureHealth()
            recorder.stop()

            XCTAssertNotNil(health.lastAudioWriteAt, "amplitude \(amplitude)")
            XCTAssertEqual(health.lastSignalAt != nil, isSignal, "amplitude \(amplitude)")
        }
    }

    static func writeTone(to url: URL, seconds: Double, amplitude: Float = 0.2) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let frames = AVAudioFrameCount(16_000 * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for index in 0..<Int(frames) {
            buffer.floatChannelData![0][index] = amplitude * sinf(Float(index) * 2 * .pi * 220 / 16_000)
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }
}
