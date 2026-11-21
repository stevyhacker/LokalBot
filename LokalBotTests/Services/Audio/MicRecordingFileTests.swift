import AVFoundation
import XCTest
@testable import LokalBot

final class MicRecordingFileTests: XCTestCase {

    private func format(_ sampleRate: Double, channels: AVAudioChannelCount = 1) -> AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatFloat32,
                      sampleRate: sampleRate,
                      channels: channels,
                      interleaved: false)!
    }

    private func temporaryURL(_ ext: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("mic-file-\(UUID().uuidString).\(ext)")
    }

    func testOpensAFileAtEveryRateAMacInputCanRun() throws {
        for rate in [8_000.0, 16_000, 22_050, 24_000, 32_000, 44_100, 48_000] {
            let url = temporaryURL("m4a")
            defer { try? FileManager.default.removeItem(at: url) }
            XCTAssertNoThrow(
                try MicRecorder.makeRecordingFile(at: url, recordingFormat: format(rate)),
                "no capture file at \(Int(rate)) Hz")
        }
    }

    func testStereoRatesOpenToo() throws {
        for rate in [16_000.0, 44_100, 48_000] {
            let url = temporaryURL("m4a")
            defer { try? FileManager.default.removeItem(at: url) }
            XCTAssertNoThrow(
                try MicRecorder.makeRecordingFile(at: url, recordingFormat: format(rate, channels: 2)),
                "no stereo capture file at \(Int(rate)) Hz")
        }
    }

    func testBitRateTracksTheSampleRate() {
        XCTAssertEqual(MicRecorder.aacBitRate(forSampleRate: 8_000), 24_000)
        XCTAssertEqual(MicRecorder.aacBitRate(forSampleRate: 16_000), 32_000)
        XCTAssertEqual(MicRecorder.aacBitRate(forSampleRate: 44_100), 64_000)
        XCTAssertEqual(MicRecorder.aacBitRate(forSampleRate: 48_000), 64_000)
    }

    func testLadderOnlyEverStepsDown() {
        for rate in [8_000.0, 16_000, 44_100, 48_000] {
            let ladder = MicRecorder.aacBitRateLadder(forSampleRate: rate)
            XCTAssertFalse(ladder.isEmpty)
            XCTAssertEqual(ladder.first, MicRecorder.aacBitRate(forSampleRate: rate))
            XCTAssertEqual(ladder, ladder.sorted(by: >), "ladder must descend at \(Int(rate)) Hz")
        }
    }

    func testPCMScratchFileIsUntouchedByTheLadder() throws {
        let url = temporaryURL("caf")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertNoThrow(
            try MicRecorder.makeRecordingFile(at: url, recordingFormat: format(16_000)))
    }
}
