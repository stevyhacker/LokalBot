import Foundation
import XCTest
@testable import LokalBot

final class SpeechRuntimeEngineTests: XCTestCase {
    private var temporaryDirectory: URL!
    private var tokenURL: URL!
    private var engine: SpeechRuntimeEngine!

    override func setUpWithError() throws {
        try super.setUpWithError()
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpeechRuntimeEngineTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        tokenURL = temporaryDirectory.appendingPathComponent("token")
        try "test-runtime-token\n".write(to: tokenURL, atomically: true, encoding: .utf8)
        engine = SpeechRuntimeEngine(
            baseURL: URL(string: "http://speech-runtime.test:8477")!,
            tokenURL: tokenURL,
            protocolClasses: [SpeechRuntimeStubURLProtocol.self],
            spanProvider: { url in
                let duration = try SpanAudioReader(url: url).duration
                return SpeechActivity.split(start: 0, end: duration, maxSegmentSeconds: 120)
            })
        SpeechRuntimeStubURLProtocol.reset()
    }

    override func tearDownWithError() throws {
        SpeechRuntimeStubURLProtocol.reset()
        if let temporaryDirectory { try? FileManager.default.removeItem(at: temporaryDirectory) }
        try super.tearDownWithError()
    }

    func testRuntimeTokenTimestampsDoNotBecomeWordTimingSegments() {
        let segments = SpeechRuntimeEngine.segments(
            text: "Проверим API и endpoint",
            tokens: [
                .init(text: "Проверим", startMilliseconds: 120),
                .init(text: "API", startMilliseconds: 800),
                .init(text: "endpoint", startMilliseconds: 1_400),
            ],
            duration: 2.2,
            offset: 120)

        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].text, "Проверим API и endpoint")
        XCTAssertEqual(segments[0].start, 120)
        XCTAssertEqual(segments[0].end, 122.2, accuracy: 0.0001)
        XCTAssertEqual(segments[0].timingPrecision, .coarse)
    }

    func testEmptyRuntimeTextProducesNoSegments() {
        XCTAssertTrue(SpeechRuntimeEngine.segments(text: "  ", tokens: [], duration: 4).isEmpty)
    }

    func testInjectedVADSpansKeepOffsetsAndSkipSilence() async throws {
        engine = makeEngine { _ in
            [SpeechSpan(start: 1, end: 2, timingPrecision: .span),
             SpeechSpan(start: 4.5, end: 5.5, timingPrecision: .span)]
        }
        SpeechRuntimeStubURLProtocol.handler = { request in
            request.url?.path == "/v1/audio/transcriptions"
                ? .json(["text": "spoken", "audio_ms": 500])
                : .json(["text": "spoken"])
        }
        let source = try makeWAV(sampleRate: 16_000, channels: 1, seconds: 6)

        let transcript = try await engine.transcribe(audio: source, language: nil)

        let requests = SpeechRuntimeStubURLProtocol.requests.filter {
            $0.url.path == "/v1/audio/transcriptions"
        }
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests.map { $0.body.uint32LE(at: 40) }, [32_000, 32_000])
        XCTAssertEqual(transcript.segments.map(\.start), [1, 4.5])
        XCTAssertEqual(transcript.segments.map(\.end), [1.5, 5])
    }

    func testNoVADSpansReturnEmptyTranscriptWithoutRuntimeRequest() async throws {
        engine = makeEngine { _ in [] }
        let source = try makeWAV(sampleRate: 16_000, channels: 1, seconds: 1)

        let transcript = try await engine.transcribe(audio: source, language: nil)

        XCTAssertTrue(transcript.segments.isEmpty)
        XCTAssertTrue(SpeechRuntimeStubURLProtocol.requests.isEmpty)
    }

    func testVADSpanFailurePropagatesWithoutRuntimeRequest() async throws {
        engine = makeEngine { _ in throw SpanProviderFailure.failed }
        let source = try makeWAV(sampleRate: 16_000, channels: 1, seconds: 1)

        do {
            _ = try await engine.transcribe(audio: source, language: nil)
            XCTFail("Expected the VAD span error")
        } catch is SpanProviderFailure {
            XCTAssertTrue(SpeechRuntimeStubURLProtocol.requests.isEmpty)
        }
    }

    func testLongAudioFallbackSpansAreSplitIntoBoundedContiguousChunks() {
        let chunks = SpeechActivity.split(start: 0, end: 251, maxSegmentSeconds: 120)

        XCTAssertEqual(chunks, [
            .init(start: 0, end: 120, timingPrecision: .coarse),
            .init(start: 120, end: 240, timingPrecision: .coarse),
            .init(start: 240, end: 251, timingPrecision: .coarse),
        ])
        XCTAssertTrue(chunks.allSatisfy { $0.end - $0.start <= 120 })
    }

    func testPriorityQueryUsesRuntimePriorityAndNoUnsupportedLanguageHint() {
        let query = SpeechRuntimeEngine.queryItems(priority: .interactive)

        XCTAssertEqual(query.first(where: { $0.name == "model" })?.value, "parakeet-ultra")
        XCTAssertEqual(query.first(where: { $0.name == "priority" })?.value, "interactive")
        XCTAssertNil(query.first(where: { $0.name == "language" }))
    }

    func testTranscriptionAuthenticatesSendsInteractive16kMonoWAVAndPostprocesses() async throws {
        SpeechRuntimeStubURLProtocol.handler = { request in
            switch request.url?.path {
            case "/v1/audio/transcriptions":
                return .json(["text": "recognized text", "audio_ms": 1_000,
                              "tokens": [["text": "recognized", "start_ms": 0]]])
            case "/v1/text/postprocess":
                return .json(["text": "Recognized text."])
            default:
                return .error(404, "unexpected path")
            }
        }
        let source = try makeWAV(sampleRate: 48_000, channels: 2, seconds: 1)

        let transcript = try await engine.transcribe(audio: source, language: "ru", prompt: "ignored",
                                                     priority: .interactive)
        let requests = SpeechRuntimeStubURLProtocol.requests
        let audioRequest = try XCTUnwrap(requests.first { $0.url.path == "/v1/audio/transcriptions" })
        let cleanupRequest = try XCTUnwrap(requests.first { $0.url.path == "/v1/text/postprocess" })
        let wav = audioRequest.body

        XCTAssertEqual(transcript.segments.map(\.text), ["Recognized text."])
        XCTAssertEqual(audioRequest.method, "POST")
        XCTAssertEqual(audioRequest.headers["authorization"], "Bearer test-runtime-token")
        XCTAssertEqual(audioRequest.headers["content-type"], "audio/wav")
        XCTAssertEqual(URLComponents(url: audioRequest.url, resolvingAgainstBaseURL: false)?.queryItems?
            .first(where: { $0.name == "priority" })?.value, "interactive")
        XCTAssertNil(URLComponents(url: audioRequest.url, resolvingAgainstBaseURL: false)?.queryItems?
            .first(where: { $0.name == "language" }))
        XCTAssertEqual(String(data: wav.prefix(4), encoding: .ascii), "RIFF")
        XCTAssertEqual(wav.uint16LE(at: 22), 1)
        XCTAssertEqual(wav.uint32LE(at: 24), 16_000)
        XCTAssertEqual(wav.uint16LE(at: 34), 16)
        XCTAssertEqual(wav.uint32LE(at: 40), 32_000)
        let cleanup = try XCTUnwrap(try JSONSerialization.jsonObject(with: cleanupRequest.body) as? [String: Any])
        XCTAssertEqual(cleanup["text"] as? String, "recognized text")
        XCTAssertEqual(cleanup["cleanup"] as? Bool, true)
        XCTAssertEqual((cleanup["rules"] as? [[String: String]])?.count, 0)
    }

    func testBatchPriorityIsSentByProtocolTranscriptionMethod() async throws {
        SpeechRuntimeStubURLProtocol.handler = { request in
            request.url?.path == "/v1/audio/transcriptions"
                ? .json(["text": "batch", "audio_ms": 1_000])
                : .json(["text": "batch"])
        }
        let source = try makeWAV(sampleRate: 16_000, channels: 1, seconds: 1)

        _ = try await engine.transcribe(audio: source, language: nil)

        let audioRequest = try XCTUnwrap(SpeechRuntimeStubURLProtocol.requests.first {
            $0.url.path == "/v1/audio/transcriptions"
        })
        let query = URLComponents(url: audioRequest.url, resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(query?.first(where: { $0.name == "priority" })?.value, "batch")
    }

    func testPrepareLoadsModelOnlyWhenRuntimeReportsItUnloaded() async throws {
        SpeechRuntimeStubURLProtocol.handler = { request in
            if request.url?.path == "/v1/models" {
                return .json(["models": [["model": "parakeet-ultra", "loaded": false]]])
            }
            if request.url?.path == "/v1/models/load" {
                return .json(["model": "parakeet-ultra", "result": ["loaded": "parakeet-ultra"]])
            }
            return .error(404, "unexpected path")
        }

        try await engine.prepare()

        let requests = SpeechRuntimeStubURLProtocol.requests
        let loadRequest = try XCTUnwrap(requests.first { $0.url.path == "/v1/models/load" })
        XCTAssertEqual(loadRequest.headers["authorization"], "Bearer test-runtime-token")
        XCTAssertEqual(try JSONSerialization.jsonObject(with: loadRequest.body) as? [String: String],
                       ["model": "parakeet-ultra"])
        XCTAssertFalse(requests.contains { $0.url.path.contains("unload") })
    }

    func testPrepareDoesNotLoadModelAlreadySharedByAnotherClient() async throws {
        SpeechRuntimeStubURLProtocol.handler = { request in
            request.url?.path == "/v1/models"
                ? .json(["models": [["model": "parakeet-ultra", "loaded": true]]])
                : .error(404, "unexpected path")
        }

        try await engine.prepare()

        XCTAssertEqual(SpeechRuntimeStubURLProtocol.requests.map(\.url.path), ["/v1/models"])
    }

    func testMissingTokenFailsBeforeSendingARequest() async throws {
        try FileManager.default.removeItem(at: tokenURL)
        SpeechRuntimeStubURLProtocol.handler = { _ in .error(500, "unexpected request") }

        do {
            try await engine.prepare()
            XCTFail("Expected missing-token failure")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("token"), error.localizedDescription)
        }
        XCTAssertTrue(SpeechRuntimeStubURLProtocol.requests.isEmpty)
    }

    func testHTTPErrorIsReturnedAsSpeechRuntimeFailure() async throws {
        SpeechRuntimeStubURLProtocol.handler = { request in
            request.url?.path == "/v1/audio/transcriptions"
                ? .error(503, "worker unavailable")
                : .json(["text": "unused"])
        }
        let source = try makeWAV(sampleRate: 16_000, channels: 1, seconds: 1)

        do {
            _ = try await engine.transcribe(audio: source, language: nil, prompt: nil, priority: .batch)
            XCTFail("Expected Speech Runtime HTTP error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("worker unavailable"), error.localizedDescription)
        }
        XCTAssertFalse(SpeechRuntimeStubURLProtocol.requests.contains { $0.url.path == "/v1/text/postprocess" })
    }

    func testCancelledUploadPropagatesCancellationAndStopsLoading() async throws {
        let requestStarted = expectation(description: "transcription request started")
        let requestStopped = expectation(description: "transcription request stopped")
        SpeechRuntimeStubURLProtocol.startedExpectation = requestStarted
        SpeechRuntimeStubURLProtocol.stoppedExpectation = requestStopped
        SpeechRuntimeStubURLProtocol.handler = { _ in .pending }
        let source = try makeWAV(sampleRate: 16_000, channels: 1, seconds: 1)
        let task = Task {
            try await engine.transcribe(audio: source, language: nil, prompt: nil, priority: .interactive)
        }

        await fulfillment(of: [requestStarted], timeout: 5)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected task cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError, "Unexpected error: \(error)")
        }
        await fulfillment(of: [requestStopped], timeout: 5)
    }

    func testLongRecordingUsesSeparateRequestsAndOffsetsCoarseSegments() async throws {
        SpeechRuntimeStubURLProtocol.handler = { request in
            request.url?.path == "/v1/audio/transcriptions"
                ? .json(["text": "segment", "tokens": [["text": "segment", "start_ms": 0]]])
                : .json(["text": "segment"])
        }
        let source = try makeWAV(sampleRate: 16_000, channels: 1, seconds: 121)

        let transcript = try await engine.transcribe(audio: source, language: nil, prompt: nil, priority: .batch)

        let requests = SpeechRuntimeStubURLProtocol.requests.filter { $0.url.path == "/v1/audio/transcriptions" }
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests.map { $0.body.uint32LE(at: 40) }, [3_840_000, 32_000])
        XCTAssertEqual(transcript.segments.map(\.start), [0, 120])
        XCTAssertEqual(transcript.segments.map(\.end), [120, 121])
        XCTAssertTrue(transcript.segments.allSatisfy { $0.timingPrecision == .coarse })
    }

    private func makeWAV(sampleRate: Int, channels: Int, seconds: Int) throws -> URL {
        let frames = sampleRate * seconds
        let dataBytes = frames * channels * MemoryLayout<Int16>.size
        var wav = Data("RIFF".utf8)
        wav.appendLE(UInt32(36 + dataBytes))
        wav.append(Data("WAVEfmt ".utf8))
        wav.appendLE(UInt32(16))
        wav.appendLE(UInt16(1))
        wav.appendLE(UInt16(channels))
        wav.appendLE(UInt32(sampleRate))
        wav.appendLE(UInt32(sampleRate * channels * 2))
        wav.appendLE(UInt16(channels * 2))
        wav.appendLE(UInt16(16))
        wav.append(Data("data".utf8))
        wav.appendLE(UInt32(dataBytes))
        wav.append(Data(repeating: 0, count: dataBytes))
        let url = temporaryDirectory.appendingPathComponent("source-\(UUID().uuidString).wav")
        try wav.write(to: url)
        return url
    }

    private func makeEngine(spanProvider: @escaping SpeechRuntimeEngine.SpanProvider) -> SpeechRuntimeEngine {
        SpeechRuntimeEngine(
            baseURL: URL(string: "http://speech-runtime.test:8477")!,
            tokenURL: tokenURL,
            protocolClasses: [SpeechRuntimeStubURLProtocol.self],
            spanProvider: spanProvider)
    }

    private enum SpanProviderFailure: Error {
        case failed
    }
}

private struct SpeechRuntimeStubRequest {
    let url: URL
    let method: String
    let headers: [String: String]
    let body: Data
}

private struct SpeechRuntimeStubReply {
    let status: Int
    let body: Data
    let pending: Bool

    static func json(_ value: [String: Any]) -> SpeechRuntimeStubReply {
        SpeechRuntimeStubReply(status: 200,
                               body: (try? JSONSerialization.data(withJSONObject: value)) ?? Data(),
                               pending: false)
    }

    static func error(_ status: Int, _ message: String) -> SpeechRuntimeStubReply {
        json(["error": message]).withStatus(status)
    }

    static var pending: SpeechRuntimeStubReply {
        SpeechRuntimeStubReply(status: 200, body: Data(), pending: true)
    }

    private func withStatus(_ status: Int) -> SpeechRuntimeStubReply {
        SpeechRuntimeStubReply(status: status, body: body, pending: pending)
    }
}

private class SpeechRuntimeStubURLProtocol: URLProtocol, @unchecked Sendable {
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var requests: [SpeechRuntimeStubRequest] = []
        var handler: ((URLRequest) -> SpeechRuntimeStubReply)?
        var startedExpectation: XCTestExpectation?
        var stoppedExpectation: XCTestExpectation?
    }

    private static let state = State()
    private var shouldNotifyStopped = false

    static var requests: [SpeechRuntimeStubRequest] {
        state.lock.lock()
        defer { state.lock.unlock() }
        return state.requests
    }

    static var handler: ((URLRequest) -> SpeechRuntimeStubReply)? {
        get {
            state.lock.lock()
            defer { state.lock.unlock() }
            return state.handler
        }
        set {
            state.lock.lock()
            defer { state.lock.unlock() }
            state.handler = newValue
        }
    }

    static var startedExpectation: XCTestExpectation? {
        get {
            state.lock.lock()
            defer { state.lock.unlock() }
            return state.startedExpectation
        }
        set {
            state.lock.lock()
            defer { state.lock.unlock() }
            state.startedExpectation = newValue
        }
    }

    static var stoppedExpectation: XCTestExpectation? {
        get {
            state.lock.lock()
            defer { state.lock.unlock() }
            return state.stoppedExpectation
        }
        set {
            state.lock.lock()
            defer { state.lock.unlock() }
            state.stoppedExpectation = newValue
        }
    }

    static func reset() {
        state.lock.lock()
        defer { state.lock.unlock() }
        state.requests = []
        state.handler = nil
        state.startedExpectation = nil
        state.stoppedExpectation = nil
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "speech-runtime.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = Self.readBody(from: request)
        Self.state.lock.lock()
        Self.state.requests.append(SpeechRuntimeStubRequest(
            url: request.url!, method: request.httpMethod ?? "GET",
            headers: (request.allHTTPHeaderFields ?? [:]).reduce(into: [:]) { result, pair in
                result[pair.key.lowercased()] = pair.value
            }, body: body))
        let handler = Self.state.handler
        let started = Self.state.startedExpectation
        Self.state.lock.unlock()
        let reply = handler?(request) ?? .error(500, "no stub response")
        guard !reply.pending else {
            shouldNotifyStopped = true
            started?.fulfill()
            return
        }
        started?.fulfill()
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status,
                                       httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {
        guard shouldNotifyStopped else { return }
        Self.state.lock.lock()
        let stopped = Self.state.stoppedExpectation
        Self.state.lock.unlock()
        stopped?.fulfill()
        shouldNotifyStopped = false
    }

    private static func readBody(from request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }

    func uint16LE(at offset: Int) -> UInt16 {
        withUnsafeBytes { raw in
            UInt16(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
        }
    }

    func uint32LE(at offset: Int) -> UInt32 {
        withUnsafeBytes { raw in
            UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
        }
    }
}
