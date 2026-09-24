import AVFoundation
import XCTest
@testable import LokalBot

final class MeetingAudioAssetTests: XCTestCase {
    func testLateSystemAttachmentPreservesMeetingTimeInAudioPreviewAndExport() async throws {
        let folder = try temporaryFolder()
        let system = folder.appendingPathComponent("system.m4a")
        let preview = folder.appendingPathComponent(AudioPreviewTee.systemFileName)
        let timeline = RecordingAudioTimeline(originHostTime: 100)
        let spans = try writeTimelineFixture(to: system, preview: preview, timeline: timeline,
            buffers: [(hostStart: 104, duration: 2)], sampleRate: 48_000, channels: 2)
        try writeTone(to: folder.appendingPathComponent("mic.m4a"), frequency: 440,
                      duration: 6, sampleRate: 44_100)

        // Every reader continues to use ordinary file time. No consumer may
        // compensate with another offset or skip the newly attached live CAF.
        for source in [system, preview] {
            XCTAssertEqual(try audioDuration(source), 6, accuracy: 0.03)
            XCTAssertLessThan(try rms(source, from: 1, duration: 1), 0.0001)
            XCTAssertGreaterThan(try rms(source, from: 4.5, duration: 1), 0.1)
        }
        let prepared = try MeetingAudioAsset.prepare(folder: folder, hasSystemTrack: true)
        XCTAssertEqual(prepared.trackCount, 2)
        XCTAssertEqual(prepared.duration, 6, accuracy: 0.03)

        let systemOnly = try temporaryFolder()
        try FileManager.default.copyItem(at: system, to: systemOnly.appendingPathComponent("system.m4a"))
        let output = systemOnly.appendingPathComponent("export.m4a")
        try await MeetingAudioAsset.exportMixedRecording(folder: systemOnly, hasSystemTrack: true, to: output)
        XCTAssertEqual(try audioDuration(output), 6, accuracy: 0.03)
        XCTAssertLessThan(try rms(output, from: 1, duration: 1), 0.0001)
        XCTAssertGreaterThan(try rms(output, from: 4.5, duration: 1), 0.1)

        // Clock anchors use the padded frame positions too, so visual speaker
        // evidence and echo-reference ranges stay on the transcript timeline.
        let timing = RecordingAudioTiming(version: 2,
            microphone: [.init(hostStart: 100, hostEnd: 106, startFrame: 0,
                endFrame: 96_000, sampleRate: 16_000, generation: 1)],
            system: spans, timelineOriginHostTime: 100)
        let reference = try XCTUnwrap(timing.referenceRange(start: 4.5, end: 5.5))
        XCTAssertEqual(reference.start, 4.5, accuracy: 0.0001)
        XCTAssertEqual(reference.end, 5.5, accuracy: 0.0001)
        XCTAssertNil(timing.referenceRange(start: 1, end: 2), "padding is not captured speaker evidence")
    }

    func testRecoveredMicrophoneKeepsLongGapAndPreviewOnMeetingTimeline() throws {
        let folder = try temporaryFolder()
        let audio = folder.appendingPathComponent("mic.m4a")
        let preview = folder.appendingPathComponent(AudioPreviewTee.micFileName)
        let timeline = RecordingAudioTimeline(originHostTime: 100)
        let spans = try writeTimelineFixture(to: audio, preview: preview, timeline: timeline,
            buffers: [(hostStart: 100, duration: 1), (hostStart: 191, duration: 1)])

        for source in [audio, preview] {
            XCTAssertEqual(try audioDuration(source), 92, accuracy: 0.03)
            XCTAssertGreaterThan(try rms(source, from: 0.2, duration: 0.5), 0.1)
            XCTAssertLessThan(try rms(source, from: 32, duration: 1), 0.0001)
            XCTAssertLessThan(try rms(source, from: 89, duration: 1), 0.0001)
            XCTAssertGreaterThan(try rms(source, from: 91.2, duration: 0.5), 0.1)
        }
        XCTAssertEqual(Double(spans[1].startFrame) / spans[1].sampleRate, 91)
        let timing = RecordingAudioTiming(version: 2, microphone: spans, system: spans,
                                          timelineOriginHostTime: 100)
        XCTAssertEqual(try XCTUnwrap(timing.referenceRange(start: 91.2, end: 91.7)).start,
                       91.2, accuracy: 0.0001)
        XCTAssertNil(timing.referenceRange(start: 32, end: 33))
    }

    func testTimelinePaddingRetriesOnlyUnwrittenFramesAfterFailure() throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let timeline = RecordingAudioTimeline(originHostTime: 100)
        var written: Int64 = 0
        var calls = 0
        XCTAssertThrowsError(try AudioTimelinePadding.write(
            frames: timeline.silenceFrames(before: 220.5, framesWritten: written, sampleRate: 16_000),
            format: format) { buffer in
                calls += 1
                if calls == 3 { throw CocoaError(.fileWriteUnknown) }
                written += Int64(buffer.frameLength)
            })
        XCTAssertEqual(written, 65_536)
        try AudioTimelinePadding.write(
            frames: timeline.silenceFrames(before: 220.5, framesWritten: written, sampleRate: 16_000),
            format: format) { buffer in
                XCTAssertLessThanOrEqual(buffer.frameCapacity, 32_768)
                written += Int64(buffer.frameLength)
            }
        XCTAssertEqual(written, 1_928_000)
        XCTAssertEqual(timeline.silenceFrames(before: 220.5, framesWritten: written, sampleRate: 16_000), 0)
    }

    func testTimelinePlannerRejectsInvalidTimesAndToleratesSubBufferJitter() {
        let timeline = RecordingAudioTimeline(originHostTime: 100)
        XCTAssertEqual(timeline.silenceFrames(before: .nan, framesWritten: 0, sampleRate: 16_000), 0)
        XCTAssertEqual(timeline.silenceFrames(before: .infinity, framesWritten: 0, sampleRate: 16_000), 0)
        XCTAssertEqual(timeline.silenceFrames(before: 99, framesWritten: 0, sampleRate: 16_000), 0)
        XCTAssertEqual(timeline.silenceFrames(before: 100.01, framesWritten: 0, sampleRate: 16_000), 0)
        XCTAssertEqual(timeline.silenceFrames(before: 100.5, framesWritten: 0, sampleRate: 48_000), 24_000)
    }

    func testMeetingClockPreservesSleepTimeAndExcludesCallbackLatency() {
        let start = ContinuousClock.now
        let timeline = RecordingAudioTimeline(originHostTime: 100, originInstant: start)
        // 90 seconds of sleep pass on the continuous clock while the audio
        // host clock pauses. The resumed callback arrives 0.1s after its data.
        let placed = timeline.hostTimeOnTimeline(bufferHostTime: 101,
            callbackHostTime: 101.1, callbackInstant: start.advanced(by: .seconds(91.1)))
        XCTAssertEqual(placed, 191, accuracy: 0.0001)
        XCTAssertEqual(timeline.silenceFrames(before: placed, framesWritten: 16_000, sampleRate: 16_000),
                       1_440_000)
    }

    func testLegacyTimingRetainsItsRawFileMapping() throws {
        let legacy = Data("""
            {"version":1,"microphone":[{"hostStart":100,"hostEnd":106,"startFrame":0,"endFrame":96000,"sampleRate":16000,"generation":1}],
            "system":[{"hostStart":104,"hostEnd":106,"startFrame":0,"endFrame":32000,"sampleRate":16000,"generation":1}]}
            """.utf8)
        let timing = try JSONDecoder().decode(RecordingAudioTiming.self, from: legacy)
        XCTAssertNil(timing.timelineOriginHostTime)
        XCTAssertEqual(try XCTUnwrap(timing.referenceRange(start: 4.5, end: 5.5)).start, 0.5,
                       accuracy: 0.0001, "old sidecars cannot silently relabel old audio or persisted evidence")
    }

    func testPrepareUsesBothTracksWhenSystemAudioExists() throws {
        let folder = try temporaryFolder()
        try writeTone(to: folder.appendingPathComponent("mic.m4a"), frequency: 440, duration: 0.25)
        try writeTone(to: folder.appendingPathComponent("system.m4a"), frequency: 660, duration: 0.4)

        let prepared = try MeetingAudioAsset.prepare(folder: folder, hasSystemTrack: true)

        XCTAssertEqual(prepared.trackCount, 2)
        XCTAssertEqual(prepared.audioMix.inputParameters.count, 2)
        XCTAssertEqual(prepared.duration, 0.4, accuracy: 0.08)
    }

    func testExportMixedRecordingWritesReadableM4A() async throws {
        let folder = try temporaryFolder()
        try writeTone(to: folder.appendingPathComponent("mic.m4a"), frequency: 440, duration: 0.25)
        try writeTone(to: folder.appendingPathComponent("system.m4a"), frequency: 660, duration: 0.25)
        let output = folder.appendingPathComponent("export.m4a")

        try await MeetingAudioAsset.exportMixedRecording(folder: folder, hasSystemTrack: true, to: output)

        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
        let exported = try AVAudioFile(forReading: output)
        XCTAssertGreaterThan(exported.length, 0)
    }

    func testPlaybackSourcesGainStaging() throws {
        let folder = try temporaryFolder()
        try writeTone(to: folder.appendingPathComponent("mic.m4a"), frequency: 440, duration: 0.1)
        try writeTone(to: folder.appendingPathComponent("system.m4a"), frequency: 660, duration: 0.1)

        // Both tracks: system kept dominant, mic attenuated to tame bleed.
        let both = MeetingAudioAsset.playbackSources(folder: folder, hasSystemTrack: true)
        XCTAssertEqual(both.map(\.url.lastPathComponent), ["system.m4a", "mic.m4a"])
        XCTAssertEqual(both.map(\.gain), [0.85, 0.55])

        // System present on disk but not flagged for this meeting: mic only, full gain.
        let micOnly = MeetingAudioAsset.playbackSources(folder: folder, hasSystemTrack: false)
        XCTAssertEqual(micOnly.map(\.url.lastPathComponent), ["mic.m4a"])
        XCTAssertEqual(micOnly.map(\.gain), [1.0])
    }

    func testPlaybackSourcesSystemOnlyAndEmpty() throws {
        let systemFolder = try temporaryFolder()
        try writeTone(to: systemFolder.appendingPathComponent("system.m4a"), frequency: 660, duration: 0.1)
        let systemOnly = MeetingAudioAsset.playbackSources(folder: systemFolder, hasSystemTrack: true)
        XCTAssertEqual(systemOnly.map(\.url.lastPathComponent), ["system.m4a"])
        XCTAssertEqual(systemOnly.map(\.gain), [1.0])

        XCTAssertTrue(MeetingAudioAsset.playbackSources(folder: try temporaryFolder(),
                                                        hasSystemTrack: true).isEmpty)
    }

    /// A process crash can leave an MP4 container on disk but unreadable. The
    /// append-only CAF tee is then the only copy of the meeting and must remain
    /// the source for playback and transcription until the user deletes it.
    func testUnreadablePrimaryFallsBackToCrashSafeCAFWithoutDeletingIt() throws {
        let folder = try temporaryFolder()
        let primary = folder.appendingPathComponent("mic.m4a")
        let recovery = folder.appendingPathComponent(AudioPreviewTee.micFileName)
        try Data("unfinished m4a container".utf8).write(to: primary)
        try writePCMTone(to: recovery, frequency: 440, duration: 0.5)

        XCTAssertEqual(MeetingAudioFiles.readableURL(for: .mic, in: folder), recovery)
        XCTAssertEqual(MeetingAudioFiles.transcribableURL(for: .mic, in: folder), recovery)
        XCTAssertEqual(
            MeetingAudioAsset.playbackSources(folder: folder, hasSystemTrack: false).map(\.url),
            [recovery])

        MeetingAudioFiles.removeRedundantRecoveryFiles(in: folder)

        XCTAssertTrue(FileManager.default.fileExists(atPath: recovery.path),
                      "recovery must preserve the only decodable meeting audio")
    }

    func testFinalizedPrimaryMakesCrashSafeCAFSafeToRemove() throws {
        let folder = try temporaryFolder()
        let primary = folder.appendingPathComponent("mic.m4a")
        let recovery = folder.appendingPathComponent(AudioPreviewTee.micFileName)
        try writeTone(to: primary, frequency: 440, duration: 0.5)
        try writePCMTone(to: recovery, frequency: 440, duration: 0.5)

        MeetingAudioFiles.removeRedundantRecoveryFiles(in: folder)

        XCTAssertTrue(FileManager.default.fileExists(atPath: primary.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: recovery.path))
    }

    func testReadableButTruncatedPrimaryDoesNotReplaceLongerRecovery() throws {
        let folder = try temporaryFolder()
        let primary = folder.appendingPathComponent("mic.m4a")
        let recovery = folder.appendingPathComponent(AudioPreviewTee.micFileName)
        try writeTone(to: primary, frequency: 440, duration: 0.5)
        try writePCMTone(to: recovery, frequency: 440, duration: 4)

        XCTAssertEqual(MeetingAudioFiles.transcribableURL(for: .mic, in: folder), recovery)

        MeetingAudioFiles.removeRedundantRecoveryFiles(in: folder)

        XCTAssertTrue(FileManager.default.fileExists(atPath: recovery.path),
                      "a decodable but truncated primary must not destroy fuller recovery audio")
    }

    /// The mic and system files routinely differ in sample rate and channel
    /// count; the player must load both and report the longer duration. The
    /// previous composition-based player garbled mismatched tracks during
    /// real-time playback — this guards the per-file engine that replaced it.
    @MainActor
    func testPlayerLoadsMismatchedFormatTracks() throws {
        let folder = try temporaryFolder()
        try writeTone(to: folder.appendingPathComponent("mic.m4a"),
                      frequency: 440, duration: 0.3, sampleRate: 44_100, channels: 1)
        try writeTone(to: folder.appendingPathComponent("system.m4a"),
                      frequency: 660, duration: 0.5, sampleRate: 48_000, channels: 2)

        let player = MeetingPlayer()
        player.load(folder: folder, hasSystemTrack: true)

        XCTAssertTrue(player.isLoaded, "player should load both tracks despite differing formats")
        XCTAssertEqual(player.currentTime, 0)
        XCTAssertEqual(player.duration, 0.5, accuracy: 0.15)   // the longer (system) track
        XCTAssertEqual(player.waveformSources.count, 2)
        XCTAssertEqual(Set(player.waveformSources.map { $0.url.lastPathComponent }), ["mic.m4a", "system.m4a"])
        player.stop()
        XCTAssertTrue(player.waveformSources.isEmpty)
    }

    @MainActor
    func testPlayerNotLoadedWhenNoTracks() throws {
        let player = MeetingPlayer()
        player.load(folder: try temporaryFolder(), hasSystemTrack: true)
        XCTAssertFalse(player.isLoaded)
        XCTAssertEqual(player.duration, 0)
    }

    private func temporaryFolder() throws -> URL {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: folder)
        }
        return folder
    }

    /// Uses the same planner and bounded silence writer as both capture paths,
    /// with synthetic host times and tones; no microphone or output is opened.
    private func writeTimelineFixture(to url: URL, preview: URL, timeline: RecordingAudioTimeline,
                                      buffers: [(hostStart: Double, duration: Double)],
                                      sampleRate: Double = 16_000,
                                      channels: AVAudioChannelCount = 1) throws -> [AudioClockSpan] {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate, channels: channels, interleaved: false))
        var file: AVAudioFile? = try MicRecorder.makeRecordingFile(at: url, recordingFormat: format)
        let tee = try XCTUnwrap(AudioPreviewTee(url: preview, sourceFormat: format))
        var written: Int64 = 0
        var spans: [AudioClockSpan] = []
        for entry in buffers {
            try AudioTimelinePadding.write(frames: timeline.silenceFrames(before: entry.hostStart,
                framesWritten: written, sampleRate: sampleRate), format: format) { silence in
                try file?.write(from: silence)
                tee.write(silence)
                written += Int64(silence.frameLength)
            }
            let frames = AVAudioFrameCount(entry.duration * sampleRate)
            let tone = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
            tone.frameLength = frames
            let channelsData = try XCTUnwrap(tone.floatChannelData)
            for channel in 0..<Int(channels) {
                for index in 0..<Int(frames) {
                    channelsData[channel][index] = Float(sin(2 * .pi * 440 * Double(index) / sampleRate) * 0.25)
                }
            }
            try file?.write(from: tone)
            tee.write(tone)
            spans.append(.init(hostStart: entry.hostStart, hostEnd: entry.hostStart + entry.duration,
                startFrame: written, endFrame: written + Int64(frames), sampleRate: sampleRate,
                generation: spans.count + 1))
            written += Int64(frames)
        }
        file = nil
        tee.close()
        return spans
    }

    private func audioDuration(_ url: URL) throws -> Double {
        let file = try AVAudioFile(forReading: url)
        return Double(file.length) / file.processingFormat.sampleRate
    }

    private func rms(_ url: URL, from start: Double, duration: Double) throws -> Double {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let count = AVAudioFrameCount(duration * format.sampleRate)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count))
        file.framePosition = Int64(start * format.sampleRate)
        try file.read(into: buffer, frameCount: count)
        XCTAssertGreaterThan(buffer.frameLength, 0)
        let channel = try XCTUnwrap(buffer.floatChannelData?[0])
        let values = UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))
        return sqrt(values.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(values.count))
    }

    private func writeTone(to url: URL, frequency: Double, duration: TimeInterval,
                           sampleRate: Double = 16_000, channels: AVAudioChannelCount = 1) throws {
        let frameCount = AVAudioFrameCount(sampleRate * duration)
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                                 sampleRate: sampleRate,
                                                 channels: channels,
                                                 interleaved: false))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
        buffer.frameLength = frameCount

        let channelData = try XCTUnwrap(buffer.floatChannelData)
        for channel in 0..<Int(channels) {
            let samples = channelData[channel]
            for index in 0..<Int(frameCount) {
                samples[index] = Float(sin(2 * .pi * frequency * Double(index) / sampleRate) * 0.25)
            }
        }

        let file = try AVAudioFile(
            forWriting: url,
            settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: Int(channels),
            ])
        try file.write(from: buffer)
    }

    private func writePCMTone(to url: URL, frequency: Double, duration: TimeInterval,
                              sampleRate: Double = 16_000) throws {
        let frameCount = AVAudioFrameCount(sampleRate * duration)
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                                 sampleRate: sampleRate,
                                                 channels: 1,
                                                 interleaved: false))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
        buffer.frameLength = frameCount
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        for index in 0..<Int(frameCount) {
            samples[index] = Float(sin(2 * .pi * frequency * Double(index) / sampleRate) * 0.25)
        }

        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }
}
