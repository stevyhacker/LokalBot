import AVFoundation
import CoreML
import FluidAudio
import XCTest
@testable import LokalBot

@MainActor
final class LiveMeetingTranscriberTests: XCTestCase {

    private var root: URL!
    private var transcriber: LiveMeetingTranscriber!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("live-transcriber-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        transcriber = LiveMeetingTranscriber(storageRoot: root) { AppSettings() }
    }

    override func tearDownWithError() throws {
        transcriber.stop()
        try? FileManager.default.removeItem(at: root)
    }

    func testActivateWithoutPreparedRecordingIsANoOp() {
        transcriber.activate()
        XCTAssertFalse(transcriber.isRunning)
    }

    func testPrepareAloneCostsNothing() {
        transcriber.prepare(folder: root)
        XCTAssertFalse(transcriber.isRunning)
    }

    func testActivateStartsAfterPrepare() {
        transcriber.prepare(folder: root)
        transcriber.activate()
        XCTAssertTrue(transcriber.isRunning)
        transcriber.activate() // idempotent while running
        XCTAssertTrue(transcriber.isRunning)
    }

    func testOptInCarriesAcrossCalendarSplit() {
        transcriber.prepare(folder: root)
        transcriber.activate()
        transcriber.prepare(folder: root.appendingPathComponent("next-meeting"))
        XCTAssertTrue(transcriber.isRunning, "an activated transcriber resumes on the new folder")
    }

    func testStopEndsTheSessionAndDropsTheOptIn() {
        transcriber.prepare(folder: root)
        transcriber.activate()
        transcriber.stop()
        XCTAssertFalse(transcriber.isRunning)
        transcriber.activate()
        XCTAssertFalse(transcriber.isRunning, "no recording is prepared after stop")
    }

    func testSweepRemovesTheScratchDirectory() throws {
        let scratch = root.appendingPathComponent(LiveMeetingTranscriber.scratchDirectoryName,
                                                  isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        try Data("orphan".utf8).write(to: scratch.appendingPathComponent("snap-x.caf"))
        LiveMeetingTranscriber.sweepOrphanedSnapshots(storageRoot: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: scratch.path))
    }

    func testCalendarStopStartPreservesActivePreview() {
        transcriber.prepare(folder: root)
        transcriber.activate()
        // Actual handoff emits idle between the two recording states.
        transcriber.stop(preservingHandoff: true)
        XCTAssertFalse(transcriber.isRunning)
        transcriber.prepare(folder: root.appendingPathComponent("next-meeting"))
        XCTAssertTrue(transcriber.isRunning)
    }

    func testFailedCalendarStartClearsPendingOptIn() {
        transcriber.prepare(folder: root)
        transcriber.activate()
        transcriber.stop(preservingHandoff: true)
        // A starting -> idle failure must be observed even though neither
        // state has a meeting ID.
        transcriber.stop()
        transcriber.prepare(folder: root.appendingPathComponent("unrelated-meeting"))
        XCTAssertFalse(transcriber.isRunning)
    }

    func testPausedPreviewDoesNotAutoResumeAcrossCalendarHandoff() {
        transcriber.prepare(folder: root)
        transcriber.activate()
        transcriber.pause()
        transcriber.stop(preservingHandoff: true)
        transcriber.prepare(folder: root.appendingPathComponent("next-meeting"))
        XCTAssertFalse(transcriber.isRunning)
    }

    func testSilentSecondTrackCannotResetInferenceFailures() async throws {
        try writeSpeech(seconds: 60)
        try writeCAF(samples: [Float](repeating: 0, count: 60 * 16_000),
                     to: root.appendingPathComponent(AudioPreviewTee.systemFileName))
        var calls = 0
        replaceTranscriber(transcribe: { _, _ in
            calls += 1
            throw TestError.unavailable
        })
        transcriber.prepare(folder: root)
        transcriber.activate(from: .beginning)
        try await waitUntil { self.transcriber.errorMessage != nil }
        XCTAssertEqual(calls, 3)
        XCTAssertFalse(transcriber.isRunning)
        XCTAssertFalse(transcriber.isWorking)
    }

    func testRetryKeepsAcceptedCursorAndDoesNotDuplicateLines() async throws {
        try writeSpeech(seconds: 30)
        var calls = 0
        var fail = true
        replaceTranscriber(transcribe: { _, _ in
            calls += 1
            if fail && calls > 1 { throw TestError.unavailable }
            return Self.transcript("accepted")
        })
        transcriber.prepare(folder: root)
        transcriber.activate(from: .beginning)
        try await waitUntil { self.transcriber.errorMessage != nil }
        XCTAssertEqual(transcriber.lines.map(\.time), [0])
        fail = false
        transcriber.activate()
        try await waitUntil { self.transcriber.lines.count >= 2 }
        transcriber.pause()
        XCTAssertEqual(transcriber.lines.filter { $0.time == 0 }.count, 1)
        XCTAssertGreaterThan(transcriber.lines[1].time, 0)
        XCTAssertNil(transcriber.errorMessage)
    }

    func testPauseResumeKeepsExistingLinesAndPosition() async throws {
        try writeSpeech(seconds: 6)
        replaceTranscriber()
        transcriber.prepare(folder: root)
        transcriber.activate(from: .beginning)
        try await waitUntil { self.transcriber.lines.count == 1 }
        transcriber.pause()
        let first = transcriber.lines[0]
        XCTAssertEqual(transcriber.state, .paused)
        try writeSpeech(seconds: 12)
        transcriber.activate()
        try await waitUntil { self.transcriber.lines.count >= 2 }
        transcriber.pause()
        XCTAssertEqual(transcriber.lines.first, first)
        XCTAssertEqual(transcriber.lines.filter { $0.time == 0 }.count, 1)
        XCTAssertGreaterThan(transcriber.lines[1].time, 0)
    }

    func testVADRejectsNoiseWithoutCallingASR() async throws {
        try writeSpeech(seconds: 30)
        var detections = 0
        var calls = 0
        replaceTranscriber(detectSpeech: { _ in detections += 1; return false }, transcribe: { _, _ in
            calls += 1
            return Self.transcript("must not appear")
        })
        transcriber.prepare(folder: root)
        transcriber.activate(from: .beginning)
        try await waitUntil { detections >= 2 }
        transcriber.pause()
        XCTAssertEqual(calls, 0)
        XCTAssertTrue(transcriber.lines.isEmpty)
    }

    func testUnavailableVADFailsPreviewInsteadOfFeedingUnclassifiedAudioToASR() async throws {
        try writeSpeech(seconds: 12)
        var calls = 0
        replaceTranscriber(detectSpeech: { _ in throw TestError.unavailable }, transcribe: { _, _ in
            calls += 1
            return Self.transcript("must not appear")
        })
        transcriber.prepare(folder: root)
        transcriber.activate(from: .beginning)
        try await waitUntil { self.transcriber.errorMessage != nil }
        XCTAssertEqual(calls, 0)
        XCTAssertTrue(transcriber.lines.isEmpty)
    }

    func testLateActivationStartsAtRecentAudioWithoutFourSecondWait() async throws {
        try writeSpeech(seconds: 30)
        replaceTranscriber()
        transcriber.prepare(folder: root)
        transcriber.activate()
        try await waitUntil { !self.transcriber.lines.isEmpty }
        transcriber.pause()
        XCTAssertEqual(transcriber.previewStartTime, 18)
        XCTAssertEqual(transcriber.lines.first?.time, 18)
    }

    func testRecentCursorsShareOneTimelineAcrossDifferentTrackLengths() async throws {
        try writeSpeech(seconds: 30)
        try writeCAF(samples: [Float](repeating: 0, count: 10 * 16_000),
                     to: root.appendingPathComponent(AudioPreviewTee.systemFileName))
        let worker = LiveMeetingAudioPreparationWorker(storageRoot: root)
        let cursors = try await worker.initialCursors(in: root,
            fileNames: [AudioPreviewTee.micFileName, AudioPreviewTee.systemFileName], recent: true)
        let expectedCursor = Int64(18 * 16_000)
        XCTAssertEqual(cursors, [expectedCursor, expectedCursor])
        let waiting = try await worker.prepareNextChunk(
            source: root.appendingPathComponent(AudioPreviewTee.systemFileName), processedFrames: cursors[1])
        XCTAssertEqual(waiting, .noWork)
    }

    func testRecentCursorForMissingTrackUsesTheSameStart() async throws {
        try writeSpeech(seconds: 30)
        let worker = LiveMeetingAudioPreparationWorker(storageRoot: root)
        let cursors = try await worker.initialCursors(in: root,
            fileNames: [AudioPreviewTee.micFileName, AudioPreviewTee.systemFileName], recent: true)
        let expectedCursor = Int64(18 * 16_000)
        XCTAssertEqual(cursors, [expectedCursor, expectedCursor])
    }

    func testObsoleteInferenceCannotPublishIntoNewRecording() async throws {
        try writeSpeech(seconds: 12)
        var continuation: CheckedContinuation<Transcript, Error>?
        var returned = false
        replaceTranscriber(transcribe: { _, _ in
            let result = try await withCheckedThrowingContinuation { continuation = $0 }
            returned = true
            return result
        })
        defer { continuation?.resume(throwing: CancellationError()) }
        transcriber.prepare(folder: root)
        transcriber.activate(from: .beginning)
        try await waitUntil { continuation != nil }
        let next = root.appendingPathComponent("next-meeting")
        transcriber.prepare(folder: next)
        continuation?.resume(returning: Self.transcript("stale"))
        continuation = nil
        try await waitUntil { returned }
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(transcriber.lines.isEmpty)
        XCTAssertTrue(transcriber.isRunning)
        XCTAssertFalse(transcriber.isWorking)
        XCTAssertNil(transcriber.errorMessage)
    }

    func testNewestLineIdentityChangesAfterBoundedHistoryReaches400() async throws {
        try writeSpeech(seconds: 24)
        var calls = 0
        var continuation: CheckedContinuation<Transcript, Error>?
        replaceTranscriber(transcribe: { _, _ in
            calls += 1
            if calls == 1 { return Self.transcript("first batch", count: 400) }
            return try await withCheckedThrowingContinuation { continuation = $0 }
        })
        defer { continuation?.resume(throwing: CancellationError()) }
        transcriber.prepare(folder: root)
        transcriber.activate(from: .beginning)
        try await waitUntil { continuation != nil }
        XCTAssertEqual(transcriber.lines.count, 400)
        let previous = transcriber.lines.last?.id
        continuation?.resume(returning: Self.transcript("newest"))
        continuation = nil
        try await waitUntil { self.transcriber.lines.last?.id != previous }
        transcriber.pause()
        XCTAssertEqual(transcriber.lines.count, 400)
        XCTAssertEqual(transcriber.lines.last?.text, "newest")
    }

    func testContinuousSpeechFixtureReachesSpeechDetection() async throws {
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(
            forResource: "continuous-speech", withExtension: "wav", subdirectory: "Fixtures/LiveTranscript"))
        let worker = LiveMeetingAudioPreparationWorker(storageRoot: root)
        guard case .ready(let first) = try await worker.prepareNextChunk(source: fixture, processedFrames: 0) else {
            return XCTFail("first spoken chunk was incorrectly discarded by the prefilter")
        }
        await worker.removePreparedChunk(at: first.url)
        guard case .ready(let second) = try await worker.prepareNextChunk(source: fixture, processedFrames: first.processedFrames) else {
            return XCTFail("second spoken chunk was incorrectly discarded by the prefilter")
        }
        await worker.removePreparedChunk(at: second.url)
    }

    func testInstalledVADAcceptsContinuousSpeechAndRejectsSteadyHum() async throws {
        let modelURL = AppDirectories.fluidAudioRoot.appendingPathComponent("Models/silero-vad")
            .appendingPathComponent(ModelNames.VAD.sileroVadFile)
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            throw XCTSkip("Requires an already-installed Silero model; this test never downloads one")
        }
        let config = MLModelConfiguration()
        config.computeUnits = .cpuOnly
        let model = try MLModel(contentsOf: modelURL, configuration: config)
        let vad = VadManager(vadModel: model)
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(
            forResource: "continuous-speech", withExtension: "wav", subdirectory: "Fixtures/LiveTranscript"))
        let worker = LiveMeetingAudioPreparationWorker(storageRoot: root)
        var cursor: Int64 = 0
        for _ in 0..<2 {
            guard case .ready(let prepared) = try await worker.prepareNextChunk(source: fixture, processedFrames: cursor) else {
                return XCTFail("speech was dropped before VAD")
            }
            let reader = try AVAudioFile(forReading: prepared.url)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: reader.processingFormat,
                                                       frameCapacity: AVAudioFrameCount(reader.length)))
            try reader.read(into: buffer)
            let channel = try XCTUnwrap(buffer.floatChannelData)[0]
            let samples = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
            let segments = try await vad.segmentSpeech(samples)
            XCTAssertFalse(segments.isEmpty, "steady spoken audio should pass speech-aware VAD")
            cursor = prepared.processedFrames
            await worker.removePreparedChunk(at: prepared.url)
        }
        let angularStep = 2.0 * Double.pi * 400.0 / 16_000.0
        let hum = (0..<96_000).map { Float(0.02 * sin(angularStep * Double($0))) }
        let segments = try await vad.segmentSpeech(hum)
        XCTAssertTrue(segments.isEmpty, "stationary tone should not reach ASR")
    }

    private enum TestError: Error { case unavailable, timeout }

    private func replaceTranscriber(
        detectSpeech: @escaping LiveMeetingTranscriber.SpeechDetector = { _ in true },
        transcribe: @escaping LiveMeetingTranscriber.Transcribe = { _, _ in LiveMeetingTranscriberTests.transcript("preview") }
    ) {
        self.transcriber.stop()
        self.transcriber = LiveMeetingTranscriber(storageRoot: root, detectSpeech: detectSpeech,
            transcribe: transcribe, timing: .init(idlePoll: .milliseconds(2), retryBaseSeconds: 0.002)) { AppSettings() }
    }

    private static func transcript(_ text: String, count: Int = 1) -> Transcript {
        Transcript(segments: (0..<count).map { index in
            .init(start: Double(index) * 0.001, end: Double(index + 1) * 0.001,
                  speaker: "speaker", text: text, confidence: nil)
        }, engine: "test")
    }

    private func waitUntil(_ predicate: @escaping @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !predicate() {
            guard ContinuousClock.now < deadline else {
                XCTFail("timed out waiting for live-preview state")
                throw TestError.timeout
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private func writeSpeech(seconds: Int) throws {
        var samples = [Float](repeating: 0, count: seconds * 16_000)
        for second in stride(from: 1, to: seconds - 1, by: 2) {
            addBurst(to: &samples, at: Double(second), duration: 0.4, sampleRate: 16_000)
        }
        try writeCAF(samples: samples, to: root.appendingPathComponent(AudioPreviewTee.micFileName))
    }

    // MARK: - Audio preparation worker

    func testWorkerSkipsSnapshotWhenFreshAudioIsBelowMinimum() async throws {
        let source = root.appendingPathComponent(AudioPreviewTee.micFileName)
        let liveWriter = try writeCAF(
            samples: [Float](repeating: 0, count: Int(6 * 16_000)),
            to: source)
        let worker = LiveMeetingAudioPreparationWorker(storageRoot: root)

        let result = try await worker.prepareNextChunk(
            source: source,
            processedFrames: Int64(3 * 16_000))

        XCTAssertEqual(result, .noWork)
        XCTAssertFalse(FileManager.default.fileExists(atPath: scratchDirectory.path),
                       "the metadata preflight should return before copying the growing CAF")
        XCTAssertGreaterThan(liveWriter.length, Int64(3 * 16_000),
                             "keep the production-like CAF writer open across the preflight")
    }

    func testWorkerAdvancesQuietAudioAndCleansSnapshot() async throws {
        let sampleRate = 16_000.0
        let samples = [Float](repeating: 0, count: Int(6 * sampleRate))
        let source = root.appendingPathComponent(AudioPreviewTee.micFileName)
        try writeCAF(samples: samples, to: source, sampleRate: sampleRate)
        let worker = LiveMeetingAudioPreparationWorker(storageRoot: root)
        let previousCursor = Int64(sampleRate)

        let result = try await worker.prepareNextChunk(
            source: source,
            processedFrames: previousCursor)

        guard case .advance(let processedFrames) = result else {
            return XCTFail("quiet audio should advance without producing an ASR window")
        }
        XCTAssertGreaterThan(processedFrames, previousCursor)
        XCTAssertLessThanOrEqual(processedFrames, Int64(samples.count))
        XCTAssertEqual(try scratchContents(), [],
                       "quiet chunks advance the cursor without leaking a snapshot or ASR window")
    }

    func testWorkerProducesSpeechWindowAndOwnsItsCleanup() async throws {
        let sampleRate = 16_000.0
        var samples = [Float](repeating: 0, count: Int(6 * sampleRate))
        addBurst(to: &samples, at: 1.0, duration: 0.4, sampleRate: sampleRate)
        addBurst(to: &samples, at: 3.0, duration: 0.4, sampleRate: sampleRate)
        let source = root.appendingPathComponent(AudioPreviewTee.micFileName)
        let liveWriter = try writeCAF(samples: samples, to: source, sampleRate: sampleRate)
        let worker = LiveMeetingAudioPreparationWorker(storageRoot: root)

        let result = try await worker.prepareNextChunk(source: source, processedFrames: 0)

        guard case .ready(let prepared) = result else {
            return XCTFail("speech-like audio should produce an ASR window")
        }
        XCTAssertEqual(prepared.startTime, 0, accuracy: 0.000_001)
        XCTAssertGreaterThan(prepared.processedFrames, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: prepared.url.path))
        let contents = try scratchContents()
        XCTAssertEqual(contents.count, 1)
        XCTAssertEqual(
            contents.first?.resolvingSymlinksInPath(),
            prepared.url.resolvingSymlinksInPath())
        XCTAssertGreaterThan(liveWriter.length, 0,
                             "suffix preparation must work while the append-only writer remains open")

        let reader = try AVAudioFile(forReading: prepared.url)
        XCTAssertEqual(reader.length, prepared.processedFrames)

        await worker.removePreparedChunk(at: prepared.url)
        XCTAssertEqual(try scratchContents(), [])
    }

    private var scratchDirectory: URL {
        root.appendingPathComponent(
            LiveMeetingTranscriber.scratchDirectoryName,
            isDirectory: true)
    }

    private func scratchContents() throws -> [URL] {
        guard FileManager.default.fileExists(atPath: scratchDirectory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(
            at: scratchDirectory,
            includingPropertiesForKeys: nil)
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func addBurst(
        to samples: inout [Float],
        at startTime: TimeInterval,
        duration: TimeInterval,
        sampleRate: Double
    ) {
        let start = Int(startTime * sampleRate)
        let count = Int(duration * sampleRate)
        for offset in 0..<count {
            samples[start + offset] = 0.1 * Float(sin(
                2 * Double.pi * 400 * Double(offset) / sampleRate))
        }
    }

    @discardableResult
    private func writeCAF(
        samples: [Float],
        to url: URL,
        sampleRate: Double = 16_000
    ) throws -> AVAudioFile {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: true,
        ]
        let file = try AVAudioFile(
            forWriting: url,
            settings: settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false)
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else {
            throw CocoaError(.fileWriteUnknown)
        }
        samples.withUnsafeBufferPointer { pointer in
            channel.update(from: pointer.baseAddress!, count: samples.count)
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        try file.write(from: buffer)
        return file
    }
}
