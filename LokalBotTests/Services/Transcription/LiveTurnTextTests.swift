import AVFoundation
import XCTest
@testable import LokalBot

/// Turn-by-turn live text on this Mac: the preview cuts each track at pauses
/// and transcribes one turn at a time. Speech detection and the model are
/// stand-ins; a tone is speech and digital silence is a pause.
@MainActor
final class LiveTurnTextTests: XCTestCase {

    private var root: URL!
    private var transcriber: LiveMeetingTranscriber!
    private let rate = 16_000.0

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("live-turn-text-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        transcriber?.stop()
        try? FileManager.default.removeItem(at: root)
    }

    func testEachPauseDeliversItsTurn() async throws {
        // 2 s of speech, a pause, 5 s of speech, a pause.
        try write(track(seconds: 12, speech: [(1, 3), (5, 10)]), to: AudioPreviewTee.micFileName)
        var heard: [Double] = []
        start { url, _ in
            heard.append(try Self.seconds(of: url))
            return Self.transcript("turn \(heard.count)")
        }
        XCTAssertEqual(transcriber.engine, .turns)
        XCTAssertTrue(transcriber.deliversTurns, "Live Radar follows each turn")
        try await waitUntil { self.transcriber.lines.count == 2 }

        XCTAssertEqual(transcriber.lines.map(\.text), ["turn 1", "turn 2"])
        XCTAssertEqual(transcriber.lines.map(\.speaker), ["local", "local"])
        // A turn starts up to one 256 ms chunk and 0.1 s of padding before its first word.
        XCTAssertEqual(transcriber.lines[0].time, 1, accuracy: 0.4)
        XCTAssertEqual(transcriber.lines[1].time, 5, accuracy: 0.4)
        // The model was handed each turn alone, not a window across both.
        XCTAssertEqual(heard.count, 2)
        XCTAssertEqual(heard[0], 2, accuracy: 0.8)
        XCTAssertEqual(heard[1], 5, accuracy: 0.8)
        XCTAssertTrue(transcriber.partials.isEmpty)
        XCTAssertNil(transcriber.errorMessage)
    }

    func testWindowsStayTheDefault() async throws {
        try write(track(seconds: 12, speech: [(1, 3)]), to: AudioPreviewTee.micFileName)
        start(settings: AppSettings(), detectSpeech: { _ in true }, transcribe: { _, _ in Self.transcript("window") })
        XCTAssertEqual(transcriber.engine, .local)
        XCTAssertFalse(transcriber.deliversTurns)
        try await waitUntil { !self.transcriber.lines.isEmpty }
    }

    func testBothTracksShareTheModelInTheOrderTheirTurnsClosed() async throws {
        try write(track(seconds: 9, speech: [(1, 2.5)]), to: AudioPreviewTee.micFileName)
        try write(track(seconds: 9, speech: [(4, 5.5)]), to: AudioPreviewTee.systemFileName)
        var running = 0
        var overlapped = false
        start { _, _ in
            running += 1
            overlapped = overlapped || running > 1
            try await Task.sleep(for: .milliseconds(5))
            running -= 1
            return Self.transcript("said")
        }
        try await waitUntil { self.transcriber.lines.count == 2 }
        XCTAssertEqual(transcriber.lines.map(\.speaker), ["local", "them"])
        XCTAssertEqual(transcriber.lines[1].time, 4, accuracy: 0.4)
        XCTAssertFalse(overlapped, "one turn at a time")
    }

    func testAFailedTurnIsTriedAgainAndAppearsOnce() async throws {
        try write(track(seconds: 6, speech: [(1, 3)]), to: AudioPreviewTee.micFileName)
        var calls = 0
        start { _, _ in
            calls += 1
            if calls == 1 { throw TestError.unavailable }
            return Self.transcript("second try")
        }
        try await waitUntil { self.transcriber.lines.count == 1 }
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(transcriber.lines.map(\.text), ["second try"])
        XCTAssertTrue(transcriber.isRunning)
    }

    func testRetryAfterGivingUpTranscribesTheTurnThatWasWaiting() async throws {
        try write(track(seconds: 6, speech: [(1, 3)]), to: AudioPreviewTee.micFileName)
        var calls = 0
        var broken = true
        start { _, _ in
            calls += 1
            if broken { throw TestError.unavailable }
            return Self.transcript("kept")
        }
        try await waitUntil { self.transcriber.errorMessage != nil }
        XCTAssertEqual(calls, 3)
        XCTAssertFalse(transcriber.isRunning)
        XCTAssertTrue(transcriber.lines.isEmpty)

        broken = false
        transcriber.activate()
        try await waitUntil { self.transcriber.lines.count == 1 }
        XCTAssertEqual(transcriber.lines.map(\.text), ["kept"])
        XCTAssertEqual(transcriber.lines[0].time, 1, accuracy: 0.4)
    }

    func testAPauseOfThePreviewLosesNoTurn() async throws {
        try write(track(seconds: 6, speech: [(1, 3)]), to: AudioPreviewTee.micFileName)
        var calls = 0
        var release: CheckedContinuation<Void, Never>?
        start { _, _ in
            calls += 1
            if calls == 1 { await withCheckedContinuation { release = $0 } }
            return Self.transcript("answer \(calls)")
        }
        try await waitUntil { release != nil }
        transcriber.pause()
        release?.resume()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(transcriber.lines.isEmpty, "an answer for a paused preview is not shown")

        transcriber.activate()
        try await waitUntil { self.transcriber.lines.count == 1 }
        XCTAssertEqual(transcriber.lines.map(\.text), ["answer 2"])
    }

    func testSpeechDetectionFailingStopsThePreviewBeforeTheModelHearsAnything() async throws {
        try write(track(seconds: 6, speech: [(1, 3)]), to: AudioPreviewTee.micFileName)
        var calls = 0
        start(voiceActivity: { _, _ in throw TestError.unavailable }, transcribe: { _, _ in
            calls += 1
            return Self.transcript("never")
        })
        try await waitUntil { self.transcriber.errorMessage != nil }
        XCTAssertEqual(calls, 0)
        XCTAssertFalse(transcriber.isRunning)
    }

    func testATurnStillBeingSpokenIsShownThenReplacedByItsText() async throws {
        // A short turn, then one that is still going when the file ends.
        let speech: [(Double, Double)] = [(0.5, 1.5), (3, 11)]
        try write(track(seconds: 11, speech: speech), to: AudioPreviewTee.micFileName)
        var calls = 0
        start { _, _ in
            calls += 1
            return Self.transcript("answer \(calls)")
        }
        try await waitUntil { self.transcriber.lines.count == 1 && self.transcriber.partials.count == 1 }
        XCTAssertEqual(transcriber.lines.map(\.text), ["answer 1"])
        XCTAssertEqual(transcriber.partials.first?.speaker, "local")
        XCTAssertEqual(transcriber.partials.first?.time ?? 0, 3, accuracy: 0.4)
        XCTAssertEqual(transcriber.partials.first?.text, "answer 2")

        // The speaker stops: the turn's own text takes the partial's place.
        try write(track(seconds: 13, speech: speech), to: AudioPreviewTee.micFileName)
        try await waitUntil { self.transcriber.lines.count == 2 }
        XCTAssertTrue(transcriber.partials.isEmpty)
        XCTAssertEqual(transcriber.lines[1].time, 3, accuracy: 0.4)
    }

    func testAModelThatAnswersSlowlyShowsOnlyFinishedTurns() async throws {
        try write(track(seconds: 11, speech: [(0.5, 1.5), (3, 11)]), to: AudioPreviewTee.micFileName)
        var calls = 0
        var timing = LiveMeetingTranscriber.Timing(idlePoll: .milliseconds(2), retryBaseSeconds: 0.002,
                                                   turnPoll: .milliseconds(2))
        timing.interimBudgetSeconds = 0.01
        start(timing: timing) { _, _ in
            calls += 1
            try await Task.sleep(for: .milliseconds(40))
            return Self.transcript("answer \(calls)")
        }
        try await waitUntil { self.transcriber.lines.count == 1 }
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(transcriber.partials.isEmpty)
        XCTAssertEqual(calls, 1, "the open turn was not sent to a model too slow to keep up")
    }

    func testATranscriptionServerHearsEachTurnOnce() async throws {
        try write(track(seconds: 11, speech: [(0.5, 1.5), (3, 11)]), to: AudioPreviewTee.micFileName)
        var settings = Self.turnsOn
        settings.transcriptionModel = .remoteServer
        var calls = 0
        start(settings: settings) { _, _ in
            calls += 1
            return Self.transcript("answer \(calls)")
        }
        try await waitUntil { self.transcriber.lines.count == 1 }
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(transcriber.partials.isEmpty)
        XCTAssertEqual(calls, 1, "a turn still being spoken is not uploaded")
    }

    // MARK: - Audio preparation worker

    func testWorkerHandsOverWholeChunksOnly() async throws {
        let source = root.appendingPathComponent(AudioPreviewTee.micFileName)
        let worker = LiveMeetingAudioPreparationWorker(storageRoot: root)
        var samples = [Float](repeating: 0, count: 10_000)
        samples[4_096] = 0.5
        try write(samples, to: AudioPreviewTee.micFileName)

        let missing = try await worker.readChunks(source: root.appendingPathComponent("absent.caf"),
                                                  from: 0, chunkFrames: 4_096, maximumChunks: 8)
        XCTAssertTrue(missing.isEmpty)
        let all = try await worker.readChunks(source: source, from: 0, chunkFrames: 4_096, maximumChunks: 8)
        XCTAssertEqual(all.count, 8_192, "the last 1,808 frames wait for the rest of their chunk")
        XCTAssertEqual(all[4_096], 0.5)
        let one = try await worker.readChunks(source: source, from: 0, chunkFrames: 4_096, maximumChunks: 1)
        XCTAssertEqual(one.count, 4_096)
        let later = try await worker.readChunks(source: source, from: 4_096, chunkFrames: 4_096, maximumChunks: 8)
        XCTAssertEqual(later.count, 4_096)
        XCTAssertEqual(later[0], 0.5)
        let none = try await worker.readChunks(source: source, from: 8_192, chunkFrames: 4_096, maximumChunks: 8)
        XCTAssertTrue(none.isEmpty)
    }

    func testWorkerWritesExactlyTheTurnAndRefusesAnotherSampleRate() async throws {
        let source = root.appendingPathComponent(AudioPreviewTee.micFileName)
        let worker = LiveMeetingAudioPreparationWorker(storageRoot: root)
        try write((0..<32_000).map { Float($0) / 32_000 }, to: AudioPreviewTee.micFileName)

        let prepared = try await worker.prepareSpan(source: source, start: 8_000, end: 24_000)
        let span = try XCTUnwrap(prepared)
        let file = try AVAudioFile(forReading: span)
        XCTAssertEqual(file.length, 16_000)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 1))
        try file.read(into: buffer, frameCount: 1)
        XCTAssertEqual(try XCTUnwrap(buffer.floatChannelData)[0][0], 0.25, accuracy: 0.0001)
        await worker.removePreparedChunk(at: span)
        XCTAssertFalse(FileManager.default.fileExists(atPath: span.path))

        let beyond = try await worker.prepareSpan(source: source, start: 40_000, end: 48_000)
        XCTAssertNil(beyond)

        try write([Float](repeating: 0, count: 44_100), to: AudioPreviewTee.systemFileName, sampleRate: 44_100)
        do {
            _ = try await worker.readChunks(source: root.appendingPathComponent(AudioPreviewTee.systemFileName),
                                            from: 0, chunkFrames: 4_096, maximumChunks: 1)
            XCTFail("frames are counted at 16 kHz")
        } catch {}
    }

    // MARK: - Helpers

    private enum TestError: Error { case unavailable, timeout }

    private static let fast = LiveMeetingTranscriber.Timing(idlePoll: .milliseconds(2), retryBaseSeconds: 0.002,
                                                            turnPoll: .milliseconds(2))

    /// A tone is speech; anything quieter is a pause.
    private static let toneIsSpeech: LiveMeetingTranscriber.VoiceActivity = { chunk, state in
        let energy = chunk.reduce(Float(0)) { $0 + $1 * $1 } / Float(max(1, chunk.count))
        return (energy.squareRoot() > 0.01 ? 0.95 : 0.02, state)
    }

    private static var turnsOn: AppSettings {
        var settings = AppSettings()
        settings.turnByTurnLiveTextEnabled = true
        return settings
    }

    /// Starts a preview from the beginning of the recording: turn by turn,
    /// polling every 2 ms, with a tone for speech, unless told otherwise.
    private func start(settings: AppSettings? = nil,
                       timing: LiveMeetingTranscriber.Timing? = nil,
                       detectSpeech: LiveMeetingTranscriber.SpeechDetector? = nil,
                       voiceActivity: LiveMeetingTranscriber.VoiceActivity? = nil,
                       transcribe: @escaping LiveMeetingTranscriber.Transcribe) {
        let settings = settings ?? Self.turnsOn
        transcriber = LiveMeetingTranscriber(storageRoot: root, detectSpeech: detectSpeech, transcribe: transcribe,
                                             voiceActivity: voiceActivity ?? Self.toneIsSpeech,
                                             timing: timing ?? Self.fast) { settings }
        transcriber.prepare(folder: root)
        transcriber.activate(from: .beginning)
    }

    private static func transcript(_ text: String) -> Transcript {
        Transcript(segments: [.init(start: 0, end: 0.001, speaker: "speaker", text: text, confidence: nil)],
                   engine: "test")
    }

    private static func seconds(of url: URL) throws -> Double {
        let file = try AVAudioFile(forReading: url)
        return Double(file.length) / file.processingFormat.sampleRate
    }

    /// Silence with a 400 Hz tone wherever someone speaks.
    private func track(seconds: Double, speech: [(Double, Double)]) -> [Float] {
        var samples = [Float](repeating: 0, count: Int(seconds * rate))
        for (from, to) in speech {
            for index in Int(from * rate)..<min(samples.count, Int(to * rate)) {
                samples[index] = 0.1 * Float(sin(2 * Double.pi * 400 * Double(index) / rate))
            }
        }
        return samples
    }

    private func write(_ samples: [Float], to name: String, sampleRate: Double = 16_000) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: true,
        ]
        // Written beside the track and moved into place, so a preview that
        // is already running never opens a half-written file.
        let draft = root.appendingPathComponent("draft-\(UUID().uuidString).caf")
        do {
            let file = try AVAudioFile(forWriting: draft, settings: settings,
                                       commonFormat: .pcmFormatFloat32, interleaved: false)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                frameCapacity: AVAudioFrameCount(samples.count)),
                  let channel = buffer.floatChannelData?[0] else { throw CocoaError(.fileWriteUnknown) }
            samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }
            buffer.frameLength = AVAudioFrameCount(samples.count)
            try file.write(from: buffer)
        }
        _ = try FileManager.default.replaceItemAt(root.appendingPathComponent(name), withItemAt: draft)
    }

    private func waitUntil(_ predicate: @escaping @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while !predicate() {
            guard ContinuousClock.now < deadline else {
                XCTFail("timed out waiting for live text: lines=\(transcriber.lines.map(\.text)) "
                        + "partials=\(transcriber.partials.map(\.text)) error=\(transcriber.errorMessage ?? "none")")
                throw TestError.timeout
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}
