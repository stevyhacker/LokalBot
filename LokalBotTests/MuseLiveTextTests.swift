import AVFoundation
import XCTest
@testable import LokalBot

/// Plays the server's side of a realtime session: scripted replies, then it
/// stays open until closed (or closes itself after `closeAfterReplies`).
private final class FakeSocket: MuseRealtimeSocket, @unchecked Sendable {
    private let lock = NSLock()
    private var replies: [String]
    private var sentMessages: [URLSessionWebSocketTask.Message] = []
    private var isClosed = false
    private let closeAfterReplies: Duration?

    init(replies: [String], closeAfterReplies: Duration? = .milliseconds(300)) {
        self.replies = replies
        self.closeAfterReplies = closeAfterReplies
    }

    var sent: [URLSessionWebSocketTask.Message] { lock.withLock { sentMessages } }
    var closed: Bool { lock.withLock { isClosed } }

    func send(_ message: URLSessionWebSocketTask.Message) async throws {
        try lock.withLock {
            if isClosed { throw URLError(.networkConnectionLost) }
            sentMessages.append(message)
        }
    }

    func receive() async throws -> URLSessionWebSocketTask.Message {
        if let next = lock.withLock({ replies.isEmpty ? nil : replies.removeFirst() }) { return .string(next) }
        if let closeAfterReplies {
            try await Task.sleep(for: closeAfterReplies)
            close()
        }
        while !closed { try await Task.sleep(for: .milliseconds(5)) }
        throw URLError(.networkConnectionLost)
    }

    func close() { lock.withLock { isClosed = true } }
}

@MainActor
private final class Recorder {
    var outputs: [MuseLiveTextTrack.Output] = []
    var turns: [MuseLiveTextTrack.Output] { outputs.filter { if case .progress = $0 { false } else { true } } }
}

private final class ConnectCount: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func increment() { lock.withLock { value += 1 } }
}

private func json(_ object: [String: Any]) -> String {
    (try? JSONSerialization.data(withJSONObject: object)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
}

/// A 16 kHz mono float CAF like the live preview tee writes.
private func writeTrack(_ url: URL, seconds: Double) throws {
    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000.0, AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: true,
    ]
    let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    let frames = AVAudioFrameCount(seconds * 16_000)
    let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames))
    buffer.frameLength = frames
    let channel = try XCTUnwrap(buffer.floatChannelData?[0])
    for index in 0..<Int(frames) { channel[index] = 0.1 * sin(Float(index) * 0.05) }
    try file.write(from: buffer)
}

final class MuseLiveTextTests: XCTestCase {
    func testParsesTheRealtimeEvents() {
        XCTAssertEqual(MuseLiveText.parse(#"{"sessionId":"s1"}"#), .acknowledged(sessionID: "s1"))
        XCTAssertEqual(MuseLiveText.parse(#"{"type":"speechStart","audioProcessedMs":6940,"turnId":1}"#),
                       .speechStart(turn: 1, milliseconds: 6940))
        XCTAssertEqual(MuseLiveText.parse(#"{"type":"transcript","transcript":"I'll send the","final":false,"audioProcessedMs":8080}"#),
                       .partial("I'll send the"))
        XCTAssertEqual(MuseLiveText.parse(#"{"type":"transcript","transcript":"","final":true,"audioProcessedMs":19760}"#),
                       .ignored)
        XCTAssertEqual(MuseLiveText.parse(#"{"type":"speechComplete","audioProcessedMs":10060,"turnId":1,"transcript":" I'll send the deck. "}"#),
                       .speechComplete(turn: 1, milliseconds: 10060, text: "I'll send the deck."))
        XCTAssertEqual(MuseLiveText.parse(#"{"type":"audioProgress","audioProcessedMs":15520}"#), .ignored)
        XCTAssertEqual(MuseLiveText.parse(#"{"type":"error","message":"Invalid key"}"#), .failed("Invalid key"))
        XCTAssertEqual(MuseLiveText.parse("not json"), .ignored)
    }

    func testHandshakeCarriesTheKeyAndEndpointingMode() {
        let message = MuseLiveText.handshake(key: "k", keywords: ["Ana"])
        XCTAssertEqual((message["authorization"] as? [String: String])?["accessToken"], "Bearer k")
        XCTAssertEqual(message["mode"] as? String, "ENDPOINTING")
        XCTAssertEqual(message["audioEncoding"] as? String, "PCM_16KHZ")
        XCTAssertEqual(message["keywords"] as? [String], ["Ana"])
        XCTAssertNil(MuseLiveText.handshake(key: "k", keywords: [])["keywords"])
    }

    func testPCM16IsClampedLittleEndian() {
        let samples: [Float] = [0, 1, -1, 2, -0.5]
        let data = samples.withUnsafeBufferPointer { MuseLiveText.pcm16($0) }
        let values = data.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)).map(Int16.init(littleEndian:)) }
        XCTAssertEqual(values, [0, 32_767, -32_767, 32_767, -16_383])
    }

    func testFastLiveTextNeedsItsOwnSwitchAndTheApproval() {
        var settings = AppSettings()
        settings.approvedRemoteInferenceOrigins = ["https://api.meta.ai"]
        XCTAssertNotNil(MuseLiveText.unavailableReason(settings), "off by default, even with the approval")
        settings.museLiveTextEnabled = true
        settings.approvedRemoteInferenceOrigins = []
        XCTAssertEqual(MuseLiveText.unavailableReason(settings), MetaModelAPI.ConnectionError.notApproved.errorDescription)
    }

    func testPacerStartsNearTheLiveEdgeAndNeverRewinds() {
        XCTAssertEqual(MuseLiveTextPacer.origin(fileLength: 100_000, resumeFrom: nil), 52_000)
        XCTAssertEqual(MuseLiveTextPacer.origin(fileLength: 100_000, resumeFrom: 80_000), 80_000)
        XCTAssertEqual(MuseLiveTextPacer.origin(fileLength: 100_000, resumeFrom: 10_000), 52_000,
                       "a resumed session skips audio from a pause rather than racing ahead of real time")
        XCTAssertEqual(MuseLiveTextPacer.origin(fileLength: 20_000, resumeFrom: nil), 0)
    }

    func testPacerSendsWhatIsRecordedAndPadsAStalledTrack() {
        var pacer = MuseLiveTextPacer(originFrame: 0)
        XCTAssertEqual(pacer.plan(fileLength: 16_000, elapsedSeconds: 0).read, 16_000, "a short backlog goes at once")
        XCTAssertEqual(pacer.plan(fileLength: 17_600, elapsedSeconds: 0.1).read, 1_600)
        // The file stops growing; after 1.5 s behind real time the session is padded.
        XCTAssertEqual(pacer.plan(fileLength: 17_600, elapsedSeconds: 1.0).silence, 0)
        let padded = pacer.plan(fileLength: 17_600, elapsedSeconds: 3.0)
        XCTAssertEqual(padded.read, 0)
        XCTAssertEqual(padded.silence, 48_000 - 17_600 - 8_000)
        XCTAssertEqual(pacer.cursor, 40_000)
        // The padded stretch of the file is skipped when it arrives.
        XCTAssertEqual(pacer.plan(fileLength: 50_000, elapsedSeconds: 3.2).read, 10_000)
        // Frames the file couldn't deliver are read again, not skipped.
        pacer.unread(128)
        XCTAssertEqual(pacer.cursor, 49_872)
        // Never more than three seconds ahead of the clock.
        var fresh = MuseLiveTextPacer(originFrame: 0)
        XCTAssertEqual(fresh.plan(fileLength: 160_000, elapsedSeconds: 0).read, 48_000)
    }

    @MainActor
    func testSessionStreamsAudioAndReportsTurnsOnTheRecordingTimeline() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("muse-live-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        try writeTrack(url, seconds: 5)
        let socket = FakeSocket(replies: [
            json(["sessionId": "s1"]),
            json(["type": "speechStart", "audioProcessedMs": 500, "turnId": 0]),
            json(["type": "transcript", "transcript": "I'll send", "final": false, "audioProcessedMs": 900]),
            json(["type": "speechComplete", "audioProcessedMs": 1_800, "turnId": 0, "transcript": "I'll send the deck."]),
        ])
        let track = MuseLiveTextTrack(source: url, tick: .milliseconds(10), connect: { _ in socket })
        let recorder = Recorder()
        do {
            try await track.run(key: "test-key", keywords: ["Ana"], resumeFrom: nil) { recorder.outputs.append($0) }
            XCTFail("a session ends when the server closes it")
        } catch {}

        // Five seconds recorded: the session starts three seconds back, at 2.0 s.
        XCTAssertEqual(recorder.turns, [
            .connected(origin: 2),
            .partial(time: 2.5, text: "I'll send"),
            .line(time: 2.5, text: "I'll send the deck."),
        ])
        let sent = socket.sent
        guard case .string(let hello) = sent.first else { return XCTFail("the handshake goes first") }
        XCTAssertTrue(hello.contains("Bearer test-key"))
        XCTAssertTrue(hello.contains("ENDPOINTING"))
        let audio = sent.dropFirst().compactMap { message -> Data? in
            if case .data(let data) = message { data } else { nil }
        }
        // The three-second backlog as 16-bit samples; AVAudioFile may hold
        // back the last packet of a just-written file.
        XCTAssertEqual(Double(audio.reduce(0) { $0 + $1.count }), 48_000 * 2, accuracy: 512)
        XCTAssertTrue(audio.allSatisfy { $0.count <= 3_200 }, "100 ms frames at most")
        XCTAssertTrue(socket.closed)
    }

    @MainActor
    func testRefusedHandshakeFailsWithTheServersMessage() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("muse-live-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        try writeTrack(url, seconds: 1)
        let socket = FakeSocket(replies: [json(["type": "error", "message": "Invalid key"])])
        let track = MuseLiveTextTrack(source: url, tick: .milliseconds(10), connect: { _ in socket })
        let recorder = Recorder()
        do {
            try await track.run(key: "bad", keywords: [], resumeFrom: nil) { recorder.outputs.append($0) }
            XCTFail("expected a refusal")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Invalid key"), error.localizedDescription)
        }
        XCTAssertTrue(recorder.outputs.isEmpty)
        XCTAssertEqual(socket.sent.count, 1, "no audio before the session is accepted")
    }

    @MainActor
    func testMissingTrackOpensNoSession() async throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("missing-\(UUID().uuidString).caf")
        let connections = ConnectCount()
        let track = MuseLiveTextTrack(source: missing, connect: { _ in
            connections.increment()
            return FakeSocket(replies: [])
        })
        try await track.run(key: "k", keywords: [], resumeFrom: nil) { _ in }
        XCTAssertEqual(connections.count, 0, "no call audio yet means nothing is sent or billed")
    }

    @MainActor
    func testPreviewStreamsTurnsAsLinesWhenFastLiveTextIsOn() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("muse-preview-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try writeTrack(root.appendingPathComponent(AudioPreviewTee.micFileName), seconds: 5)
        let socket = FakeSocket(replies: [
            json(["sessionId": "s1"]),
            json(["type": "speechStart", "audioProcessedMs": 500, "turnId": 0]),
            json(["type": "speechComplete", "audioProcessedMs": 1_800, "turnId": 0, "transcript": "I'll send the deck."]),
        ], closeAfterReplies: nil)
        let transcriber = LiveMeetingTranscriber(
            storageRoot: root,
            museTrack: { MuseLiveTextTrack(source: $0, tick: .milliseconds(10), connect: { _ in socket }) },
            museConnection: { _ in ("test-key", []) },
            settings: { AppSettings() })
        transcriber.prepare(folder: root)
        transcriber.activate()
        XCTAssertEqual(transcriber.engine, .muse)
        XCTAssertTrue(transcriber.deliversTurns)
        let deadline = Date().addingTimeInterval(3)
        while transcriber.lines.isEmpty, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(transcriber.lines.map(\.text), ["I'll send the deck."])
        XCTAssertEqual(transcriber.lines.first?.speaker, "local", "the microphone track is the person")
        XCTAssertEqual(transcriber.lines.first?.time ?? 0, 2.5, accuracy: 0.001)
        XCTAssertEqual(transcriber.previewStartTime ?? 0, 2, accuracy: 0.001)
        transcriber.stop()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(socket.closed, "stopping the preview closes the session")
    }

    @MainActor
    func testPreviewStaysLocalWhenFastLiveTextIsUnavailable() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("muse-preview-\(UUID().uuidString)")
        let transcriber = LiveMeetingTranscriber(storageRoot: root, museConnection: { _ in nil }, settings: { AppSettings() })
        transcriber.prepare(folder: root)
        transcriber.activate()
        XCTAssertEqual(transcriber.engine, .local)
        XCTAssertFalse(transcriber.deliversTurns)
        transcriber.stop()
    }
}
