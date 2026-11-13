import AVFoundation
import XCTest
@testable import LokalBot

final class SystemAudioRecorderFileTapTests: XCTestCase {
    func testFileTapRecordsThroughTheRealWriter() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("system-file-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("tone.wav")
        try MicRecorderFileInputTests.writeTone(to: source, seconds: 2)

        let tap = try FileSystemAudioTap(url: source, speed: 4)
        let recorder = SystemAudioRecorder(makeTap: { tap })
        let output = folder.appendingPathComponent("system.m4a")
        try recorder.start(capturingPID: ProcessInfo.processInfo.processIdentifier, writingTo: output)
        Thread.sleep(forTimeInterval: 1.0)
        let health = recorder.captureHealth()
        recorder.stop()

        XCTAssertGreaterThan(health.duration, 1.5)
        XCTAssertGreaterThan(health.audibleDuration, 0.5, "the tone is audible, so audible time is tracked")
        XCTAssertGreaterThan(try AVAudioFile(forReading: output).length, 0)
    }

    /// RecordingController keeps its old target when a reattach throws, so a
    /// process the tap cannot find must leave the running capture untouched.
    func testReattachToAMissingProcessKeepsTheCurrentCapture() throws {
        final class PickyTap: SystemAudioTap {
            private let base: FileSystemAudioTap
            init(_ base: FileSystemAudioTap) { self.base = base }
            func resolves(processID: pid_t) -> Bool { processID != 424_242 }
            func attach(processID: pid_t) throws -> AVAudioFormat { try base.attach(processID: processID) }
            func start(_ deliver: @escaping (UnsafePointer<AudioBufferList>, UnsafePointer<AudioTimeStamp>) -> Void) throws {
                try base.start(deliver)
            }
            func stopDelivery() { base.stopDelivery() }
            func destroy() { base.destroy() }
        }
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("system-reattach-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("tone.wav")
        try MicRecorderFileInputTests.writeTone(to: source, seconds: 4)

        var taps = [PickyTap(try FileSystemAudioTap(url: source, speed: 4)),
                    PickyTap(try FileSystemAudioTap(url: source, speed: 4))]
        let recorder = SystemAudioRecorder(makeTap: { taps.removeFirst() })
        try recorder.start(capturingPID: ProcessInfo.processInfo.processIdentifier,
                           writingTo: folder.appendingPathComponent("system.m4a"))
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertThrowsError(try recorder.reattach(capturingPID: 424_242))
        let before = recorder.captureHealth().framesSinceAttach
        Thread.sleep(forTimeInterval: 0.5)
        let after = recorder.captureHealth().framesSinceAttach
        recorder.stop()
        XCTAssertGreaterThan(after, before, "the original tap keeps delivering")
    }
}
