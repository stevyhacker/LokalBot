import AVFoundation
import XCTest
@testable import LokalBot

final class AudioRecoveryJournalTests: XCTestCase {
    private func fixture() throws -> (URL, AVAudioFormat) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("journal-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return (folder, try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)))
    }

    private func buffer(_ format: AVAudioFormat, frames: AVAudioFrameCount = 32_000, value: Float) throws -> AVAudioPCMBuffer {
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        buffer.floatChannelData![0].initialize(repeating: value, count: Int(frames))
        return buffer
    }

    private func samples(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                  frameCapacity: 16_384))
        var result: [Float] = []
        while file.framePosition < file.length {
            try file.read(into: buffer)
            guard buffer.frameLength > 0 else { throw CocoaError(.fileReadCorruptFile) }
            result += UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))
        }
        XCTAssertEqual(Int64(result.count), file.length)
        return result
    }

    func testPrimaryFailureStillSavesWaveformAndLongGapInIndependentJournal() throws {
        let (folder, format) = try fixture()
        let preview = folder.appendingPathComponent(AudioPreviewTee.micFileName)
        let tee = try XCTUnwrap(AudioPreviewTee(url: preview, sourceFormat: format))
        var primaryAttempts = 0
        func write(_ buffer: AVAudioPCMBuffer, isPadding: Bool = false) {
            let result = AudioWriteSafety.write(recovery: { tee.write(buffer, isPadding: isPadding) }, primary: {
                primaryAttempts += 1
                throw CocoaError(.fileWriteOutOfSpace)
            })
            XCTAssertTrue(result.saved)
            XCTAssertNotNil(result.error)
        }
        write(try buffer(format, value: 0.25))
        try AudioTimelinePadding.write(frames: 90 * 16_000, format: format) { write($0, isPadding: true) }
        write(try buffer(format, value: -0.5))
        tee.close()
        XCTAssertGreaterThan(primaryAttempts, 40)
        let manifest = try JSONDecoder().decode(AudioRecoveryJournal.Manifest.self, from: Data(contentsOf:
            AudioRecoveryJournal.directory(for: preview).appendingPathComponent("manifest.json")))
        XCTAssertEqual(manifest.padding.count, 1)
        XCTAssertEqual(manifest.padding.first?.startFrame, 32_000)
        XCTAssertEqual(manifest.padding.first?.frames, 90 * 16_000)
        // Neither a finalized AAC nor the single growing CAF is available.
        try Data("unfinalized AAC".utf8).write(to: folder.appendingPathComponent("mic.m4a"))
        try FileManager.default.removeItem(at: preview)
        let recovered = try XCTUnwrap(MeetingAudioFiles.readableURL(for: .mic, in: folder))
        let audio = try samples(recovered)
        XCTAssertEqual(audio.count, 94 * 16_000)
        XCTAssertEqual(audio[16_000], 0.25, accuracy: 0.0001)
        XCTAssertEqual(audio[50 * 16_000], 0, accuracy: 0.0001)
        XCTAssertEqual(audio[93 * 16_000], -0.5, accuracy: 0.0001)
        MeetingAudioFiles.removeRedundantRecoveryFiles(in: folder)
        XCTAssertTrue(FileManager.default.fileExists(atPath: AudioRecoveryJournal.directory(for: preview).path))
        XCTAssertEqual(try samples(recovered), audio)
    }

    func testManifestLostBeforeCommitStillRecoversEveryContiguousFrame() throws {
        let (folder, format) = try fixture()
        let preview = folder.appendingPathComponent(AudioPreviewTee.systemFileName)
        let journal = try AudioRecoveryJournal(previewURL: preview, format: format)
        try journal.append(buffer(format, value: 0.3))
        let manifest = journal.directory.appendingPathComponent("manifest.json")
        let firstManifest = try Data(contentsOf: manifest)
        try journal.append(buffer(format, value: 0.6))
        journal.close()
        // Process died after the next segment was closed, before its manifest committed.
        try firstManifest.write(to: manifest)
        let recovered = try XCTUnwrap(AudioRecoveryJournal.recover(previewURL: preview))
        let audio = try samples(recovered)
        XCTAssertEqual(audio.count, 64_000)
        XCTAssertEqual(audio[16_000], 0.3, accuracy: 0.0001)
        XCTAssertEqual(audio[48_000], 0.6, accuracy: 0.0001)
        try Data("partial json".utf8).write(to: manifest)
        XCTAssertEqual(try samples(XCTUnwrap(AudioRecoveryJournal.recover(previewURL: preview))), audio)
        XCTAssertFalse(try XCTUnwrap(AudioRecoveryJournal.receipt(previewURL: preview)).complete)
    }

    func testCorruptTailInvalidatesCacheAndPreservesVerifiedPrefixAndOriginalChunks() throws {
        let (folder, format) = try fixture()
        let preview = folder.appendingPathComponent(AudioPreviewTee.micFileName)
        let journal = try AudioRecoveryJournal(previewURL: preview, format: format)
        try journal.append(buffer(format, value: 0.2))
        try journal.append(buffer(format, value: 0.4))
        journal.close()
        let files = try FileManager.default.contentsOfDirectory(at: journal.directory, includingPropertiesForKeys: nil)
        let tail = try XCTUnwrap(files.first { $0.lastPathComponent.hasPrefix("frame-32000-") })
        try Data("corrupt CAF".utf8).write(to: tail)
        let prefix = try XCTUnwrap(AudioRecoveryJournal.recover(previewURL: preview))
        XCTAssertEqual(try samples(prefix).count, 32_000)
        XCTAssertEqual(try samples(prefix)[16_000], 0.2, accuracy: 0.0001)
        XCTAssertFalse(try XCTUnwrap(AudioRecoveryJournal.receipt(previewURL: preview)).complete)
        MeetingAudioFiles.removeRedundantRecoveryFiles(in: folder)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tail.path))
        XCTAssertTrue(MeetingAudioFiles.recoveryNeedsAttention(in: folder))
    }

    func testMissingCommittedChunkCannotBeHiddenByCachedRecovery() throws {
        let (folder, format) = try fixture()
        let preview = folder.appendingPathComponent(AudioPreviewTee.micFileName)
        let journal = try AudioRecoveryJournal(previewURL: preview, format: format)
        try journal.append(buffer(format, value: 0.2))
        try journal.append(buffer(format, value: 0.4))
        journal.close()
        _ = try AudioRecoveryJournal.recover(previewURL: preview)
        let files = try FileManager.default.contentsOfDirectory(at: journal.directory, includingPropertiesForKeys: nil)
        try FileManager.default.removeItem(at: XCTUnwrap(files.first { $0.lastPathComponent.hasPrefix("frame-32000-") }))
        let recovered = try XCTUnwrap(AudioRecoveryJournal.recover(previewURL: preview))
        XCTAssertEqual(try samples(recovered).count, 64_000, "Keep the earlier complete reconstruction")
        XCTAssertFalse(try XCTUnwrap(AudioRecoveryJournal.receipt(previewURL: preview)).complete)
    }

    func testRecoveryFailureDoesNotSkipPrimaryAndBothFailuresAreReported() {
        var primaryWritten = false
        let result = AudioWriteSafety.write(recovery: { false }, primary: { primaryWritten = true })
        XCTAssertTrue(primaryWritten)
        XCTAssertTrue(result.saved)
        let failure = AudioWriteSafety.write(recovery: { false }, primary: { throw CocoaError(.fileWriteOutOfSpace) })
        XCTAssertFalse(failure.saved)
        XCTAssertNotNil(failure.error)
    }

    func testExistingJournalCannotBeOverwrittenByAnotherStart() throws {
        let (folder, format) = try fixture()
        let preview = folder.appendingPathComponent(AudioPreviewTee.micFileName)
        let journal = try AudioRecoveryJournal(previewURL: preview, format: format)
        try journal.append(buffer(format, value: 0.7))
        journal.close()
        XCTAssertThrowsError(try AudioRecoveryJournal(previewURL: preview, format: format))
        XCTAssertEqual(try samples(XCTUnwrap(AudioRecoveryJournal.recover(previewURL: preview)))[0], 0.7)
    }
}
