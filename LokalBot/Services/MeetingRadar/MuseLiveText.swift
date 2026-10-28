import AVFoundation
import Foundation

/// Fast live text: the live transcript preview streams each recorded track to
/// Muse Voice Transcribe's realtime endpoint and gets each turn's text about
/// 0.7 s after the speaker stops, instead of transcribing 12-second chunks on
/// this Mac. Off by default; turning it on sends meeting audio to api.meta.ai
/// while the preview runs. Speaker identity still comes from the track (the
/// microphone is the person), because Muse's own speaker labels measured less
/// accurate than local diarization. Built for the Meta Global AI Developer
/// Hackathon (2026).
enum MuseLiveText {
    static let url = URL(string: "wss://api.meta.ai/v1/asr/realtime")!
    static let model = "muse-voice-transcribe-1.0"
    static let displayName = "Muse Voice Transcribe 1.0"
    static let sampleRate = 16_000.0
    /// The server rejects a stream more than 5 s ahead of real time; a fresh
    /// session may start this far back in the recording.
    static let backlogSeconds = 3.0

    /// Why fast live text can't run, or nil when it can. The preview then
    /// uses the local model as before.
    static func unavailableReason(_ settings: AppSettings) -> String? {
        if !settings.museLiveTextEnabled { return "Fast live text is off." }
        if !settings.metaModelAPIApproved { return MetaModelAPI.ConnectionError.notApproved.errorDescription }
        if settings.effectiveMetaModelAPIKey.isEmpty { return MetaModelAPI.ConnectionError.missingKey.errorDescription }
        return nil
    }

    /// The first frame of a session. The key travels here, not in a header.
    static func handshake(key: String, keywords: [String]) -> [String: Any] {
        var message: [String: Any] = [
            "authorization": ["accessToken": "Bearer " + key],
            "audioEncoding": "PCM_16KHZ",
            "model": model,
            "mode": "ENDPOINTING",
        ]
        if !keywords.isEmpty { message["keywords"] = keywords }
        return message
    }

    enum Event: Equatable {
        case acknowledged(sessionID: String)
        case speechStart(turn: Int, milliseconds: Int)
        /// The turn so far, growing word by word.
        case partial(String)
        case speechComplete(turn: Int, milliseconds: Int, text: String)
        case failed(String)
        case ignored
    }

    static func parse(_ text: String) -> Event {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .ignored }
        let milliseconds = object["audioProcessedMs"] as? Int ?? 0
        switch object["type"] as? String {
        case nil:
            // The handshake acknowledgement is the only frame without a type.
            return (object["sessionId"] as? String).map { .acknowledged(sessionID: $0) } ?? .ignored
        case "speechStart":
            return .speechStart(turn: object["turnId"] as? Int ?? -1, milliseconds: milliseconds)
        case "transcript":
            guard object["final"] as? Bool != true, let text = object["transcript"] as? String else { return .ignored }
            return .partial(text)
        case "speechComplete":
            return .speechComplete(turn: object["turnId"] as? Int ?? -1, milliseconds: milliseconds,
                                   text: (object["transcript"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
        case "error":
            return .failed(object["message"] as? String ?? "Muse Voice Transcribe reported an error.")
        default:
            return .ignored
        }
    }

    /// 16-bit little-endian PCM, as the endpoint expects.
    static func pcm16(_ samples: UnsafeBufferPointer<Float>) -> Data {
        var data = Data(count: samples.count * 2)
        data.withUnsafeMutableBytes { raw in
            let out = raw.bindMemory(to: Int16.self)
            for (index, sample) in samples.enumerated() {
                out[index] = Int16(max(-1, min(1, sample)) * Float(Int16.max)).littleEndian
            }
        }
        return data
    }
}

/// How much of a growing track to send on each tick. Audio goes out as it is
/// recorded; if the file stops growing (a silent or missing source) the
/// session is padded with silence so the server never sees below-real-time
/// ingress, and the padded stretch of the file is skipped when it arrives.
struct MuseLiveTextPacer: Equatable {
    /// File frame where the session's audio starts.
    let originFrame: Int64
    private(set) var sentFrames: Int64 = 0
    var stallSeconds = 1.5
    /// How far audio may run ahead of the session clock: a fresh session's
    /// backlog in the app, about one frame for a replay of a finished file.
    var leadSeconds = MuseLiveText.backlogSeconds
    var cursor: Int64 { originFrame + sentFrames }

    init(originFrame: Int64) { self.originFrame = originFrame }

    /// A session starts at most `backlogSeconds` before the end of the file,
    /// and never before audio already sent.
    static func origin(fileLength: Int64, resumeFrom cursor: Int64?) -> Int64 {
        let recent = max(0, fileLength - Int64(MuseLiveText.backlogSeconds * MuseLiveText.sampleRate))
        return max(cursor ?? 0, recent)
    }

    mutating func plan(fileLength: Int64, elapsedSeconds: Double) -> (read: Int64, silence: Int64) {
        let rate = MuseLiveText.sampleRate
        let wall = Int64(elapsedSeconds * rate)
        let ceiling = wall + Int64(leadSeconds * rate)
        let read = max(0, min(fileLength - cursor, ceiling - sentFrames))
        var silence: Int64 = 0
        if read == 0, wall - sentFrames > Int64(stallSeconds * rate) {
            silence = wall - sentFrames - Int64(rate / 2)
        }
        sentFrames += read + silence
        return (read, silence)
    }

    /// Gives back planned frames the file couldn't deliver yet, so they are
    /// read on a later tick instead of being skipped.
    mutating func unread(_ frames: Int64) {
        sentFrames -= max(0, min(frames, sentFrames))
    }
}

/// The socket a session talks through, so tests can replace the network.
protocol MuseRealtimeSocket: AnyObject, Sendable {
    func send(_ message: URLSessionWebSocketTask.Message) async throws
    func receive() async throws -> URLSessionWebSocketTask.Message
    func close()
}

final class URLSessionMuseRealtimeSocket: MuseRealtimeSocket, @unchecked Sendable {
    private static let session = URLSession(configuration: .ephemeral)
    private let task: URLSessionWebSocketTask

    init(url: URL) {
        task = Self.session.webSocketTask(with: url)
        task.maximumMessageSize = 1 << 20
        task.resume()
    }

    func send(_ message: URLSessionWebSocketTask.Message) async throws { try await task.send(message) }
    func receive() async throws -> URLSessionWebSocketTask.Message { try await task.receive() }
    func close() { task.cancel(with: .normalClosure, reason: nil) }
}

/// One track's realtime session: reads the growing 16 kHz preview file from
/// `cursor`, streams it in 100 ms frames, and reports each turn on the
/// recording's timeline. Returns when the server ends the session (for
/// example at its 60-minute cap); the caller reconnects from `cursor`.
struct MuseLiveTextTrack {
    enum Output: Equatable {
        /// The server accepted the session; its audio starts `origin` seconds
        /// into the recording.
        case connected(origin: Double)
        /// The turn in progress, or nil when it ended without text.
        case partial(time: Double, text: String?)
        case line(time: Double, text: String)
        case progress(cursor: Int64)
    }

    enum SessionError: LocalizedError {
        case rejected(String)
        case unsupportedFormat
        var errorDescription: String? {
            switch self {
            case .rejected(let message): "Muse Voice Transcribe refused the session: \(message)"
            case .unsupportedFormat: "The live audio file isn't 16 kHz mono."
            }
        }
    }

    let source: URL
    var tick: Duration = .milliseconds(100)
    /// Replays only: stream a finished file from this frame, in real time.
    var startFrame: Int64?
    var leadSeconds = MuseLiveText.backlogSeconds
    var handshakeTimeout: Duration = .seconds(10)
    var connect: @Sendable (URL) -> MuseRealtimeSocket = { URLSessionMuseRealtimeSocket(url: $0) }

    func run(key: String, keywords: [String], resumeFrom cursor: Int64?,
             emit: @escaping @MainActor @Sendable (Output) -> Void) async throws {
        guard let length = try Self.length(of: source) else { return }
        let originFrame = startFrame ?? MuseLiveTextPacer.origin(fileLength: length, resumeFrom: cursor)
        let origin = Double(originFrame) / MuseLiveText.sampleRate
        var components = URLComponents(url: MuseLiveText.url, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "sessionId", value: "lokalbot-\(UUID().uuidString.prefix(8).lowercased())")]
        let socket = connect(components.url!)
        try await withTaskCancellationHandler {
            defer { socket.close() }
            let hello = try JSONSerialization.data(withJSONObject: MuseLiveText.handshake(key: key, keywords: keywords))
            try await socket.send(.string(String(decoding: hello, as: UTF8.self)))
            let timeout = handshakeTimeout
            let ack = try await withThrowingTaskGroup(of: MuseLiveText.Event.self) { group in
                group.addTask { MuseLiveText.parse(try await Self.text(of: socket.receive())) }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    socket.close() // unblocks the pending receive
                    throw SessionError.rejected("no reply to the handshake")
                }
                defer { group.cancelAll() }
                return try await group.next()!
            }
            switch ack {
            case .acknowledged: break
            case .failed(let message): throw SessionError.rejected(message)
            default: throw SessionError.rejected("unexpected reply to the handshake")
            }
            await emit(.connected(origin: origin))

            try await withThrowingTaskGroup(of: Void.self) { group in
                let source = source, tick = tick, leadSeconds = leadSeconds
                group.addTask {
                    var pacer = MuseLiveTextPacer(originFrame: originFrame)
                    pacer.leadSeconds = leadSeconds
                    let started = ContinuousClock.now
                    do {
                        while !Task.isCancelled {
                            let elapsed = (ContinuousClock.now - started).components
                            let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
                            let from = pacer.cursor
                            let plan = pacer.plan(fileLength: try Self.length(of: source) ?? from, elapsedSeconds: seconds)
                            if plan.read > 0 {
                                let sent = try await Self.send(frames: plan.read, from: from, of: source, to: socket)
                                pacer.unread(plan.read - sent)
                            }
                            if plan.silence > 0 { try await Self.sendSilence(frames: plan.silence, to: socket) }
                            await emit(.progress(cursor: pacer.cursor))
                            try await Task.sleep(for: tick)
                        }
                    } catch {
                        socket.close() // ends the receiver too
                        throw error
                    }
                }
                group.addTask {
                    var turnStarts: [Int: Double] = [:]
                    var current: Double?
                    while true {
                        let event = MuseLiveText.parse(try await Self.text(of: socket.receive()))
                        switch event {
                        case .speechStart(let turn, let milliseconds):
                            let time = origin + Double(milliseconds) / 1000
                            turnStarts[turn] = time
                            current = time
                        case .partial(let text):
                            if let current, !text.isEmpty { await emit(.partial(time: current, text: text)) }
                        case .speechComplete(let turn, let milliseconds, let text):
                            let time = turnStarts.removeValue(forKey: turn) ?? current ?? origin + Double(milliseconds) / 1000
                            current = nil
                            await emit(text.isEmpty ? .partial(time: time, text: nil) : .line(time: time, text: text))
                        case .failed(let message):
                            throw SessionError.rejected(message)
                        case .acknowledged, .ignored:
                            break
                        }
                    }
                }
                // The receiver ends the session when the server closes it.
                defer { group.cancelAll() }
                try await group.next()
            }
        } onCancel: {
            socket.close()
        }
    }

    /// Frames in the file so far, or nil while it doesn't exist yet.
    static func length(of source: URL) throws -> Int64? {
        guard FileManager.default.fileExists(atPath: source.path) else { return nil }
        let file = try AVAudioFile(forReading: source)
        guard file.processingFormat.sampleRate == MuseLiveText.sampleRate,
              file.processingFormat.channelCount == 1 else { throw SessionError.unsupportedFormat }
        return file.length
    }

    private static let frameSize: Int64 = Int64(MuseLiveText.sampleRate / 10)

    /// Returns the frames actually sent, which can be fewer than asked for
    /// while the writer is mid-append.
    private static func send(frames: Int64, from start: Int64, of source: URL, to socket: MuseRealtimeSocket) async throws -> Int64 {
        // A point-in-time reader, as the local preview uses: the writer keeps
        // appending to the same file.
        let file = try AVAudioFile(forReading: source)
        file.framePosition = start
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(frames)) else { return 0 }
        try file.read(into: buffer, frameCount: AVAudioFrameCount(frames))
        guard let channel = buffer.floatChannelData?[0] else { return 0 }
        var offset = 0
        let count = Int(buffer.frameLength)
        while offset < count {
            let size = min(Int(frameSize), count - offset)
            try await socket.send(.data(MuseLiveText.pcm16(UnsafeBufferPointer(start: channel + offset, count: size))))
            offset += size
        }
        return Int64(count)
    }

    private static func sendSilence(frames: Int64, to socket: MuseRealtimeSocket) async throws {
        var remaining = frames
        while remaining > 0 {
            let size = min(frameSize, remaining)
            try await socket.send(.data(Data(count: Int(size) * 2)))
            remaining -= size
        }
    }

    private static func text(of message: URLSessionWebSocketTask.Message) -> String {
        switch message {
        case .string(let text): text
        case .data(let data): String(decoding: data, as: UTF8.self)
        @unknown default: ""
        }
    }
}
