import Foundation
import XCTest
@testable import LokalBot

/// The transcription server sends meeting audio off the Mac, so these tests
/// pin where it may go (approval, HTTPS outside the user's own network), what
/// each request carries, and how chunked results keep their timing.
final class RemoteTranscriptionEngineTests: XCTestCase {
    override func tearDown() {
        RemoteTranscriptionURLProtocolStub.reset()
        super.tearDown()
    }

    // MARK: - Endpoint

    func testBaseURLGetsTheTranscriptionsPath() {
        XCTAssertEqual(configuration("https://api.openai.com/v1").endpoint?.absoluteString,
                       "https://api.openai.com/v1/audio/transcriptions")
        XCTAssertEqual(configuration("  https://api.groq.com/openai/v1/  ").endpoint?.absoluteString,
                       "https://api.groq.com/openai/v1/audio/transcriptions")
        XCTAssertEqual(configuration("http://gpu-box.tail1234.ts.net:8080").endpoint?.absoluteString,
                       "http://gpu-box.tail1234.ts.net:8080/audio/transcriptions")
    }

    func testFullEndpointURLsAreKept() {
        XCTAssertEqual(configuration("https://openrouter.ai/api/v1/audio/transcriptions").endpoint?.absoluteString,
                       "https://openrouter.ai/api/v1/audio/transcriptions")
        XCTAssertEqual(configuration("http://192.168.1.20:8080/inference/").endpoint?.absoluteString,
                       "http://192.168.1.20:8080/inference")
    }

    func testUnusableURLsHaveNoEndpoint() {
        for value in ["", "   ", "api.openai.com/v1", "ftp://example.com/v1",
                      "https://user:secret@example.com/v1", "https://example.com/v1?key=secret",
                      "https://example.com/v1#fragment"] {
            XCTAssertNil(configuration(value).endpoint, value)
        }
        XCTAssertThrowsError(try configuration("").validatedEndpoint()) {
            XCTAssertEqual($0 as? RemoteTranscriptionError, .notConfigured)
        }
        XCTAssertThrowsError(try configuration("https://example.com/v1?key=secret").validatedEndpoint()) {
            XCTAssertEqual($0 as? RemoteTranscriptionError, .invalidURL)
        }
    }

    // MARK: - Where audio may go

    func testLoopbackServerNeedsNoApproval() throws {
        let local = configuration("http://127.0.0.1:8080/v1")
        XCTAssertEqual(try local.validatedEndpoint().absoluteString,
                       "http://127.0.0.1:8080/v1/audio/transcriptions")
        XCTAssertTrue(local.isReady)
        XCTAssertEqual(local.presentation, .onDevice)
    }

    func testInternetServerNeedsHTTPSAndItsOwnApproval() {
        let pending = configuration("https://api.openai.com/v1")
        XCTAssertThrowsError(try pending.validatedEndpoint()) {
            XCTAssertEqual($0 as? RemoteTranscriptionError, .approvalRequired("https://api.openai.com"))
        }
        XCTAssertFalse(pending.isReady)
        XCTAssertTrue(pending.presentation.isBlocked)

        let approved = configuration("https://api.openai.com/v1", approved: ["https://api.openai.com"])
        XCTAssertTrue(approved.isReady)
        XCTAssertEqual(approved.presentation, .remote(host: "api.openai.com"))

        let plain = configuration("http://api.openai.com/v1", approved: ["http://api.openai.com"])
        XCTAssertThrowsError(try plain.validatedEndpoint()) {
            XCTAssertEqual($0 as? RemoteTranscriptionError, .insecure("http://api.openai.com"))
        }
        XCTAssertFalse(plain.isReady)
    }

    func testPlainHTTPReachesPrivateNetworksAndTailnetsOnlyAfterApproval() {
        for base in ["http://192.168.1.20:8080/inference", "http://10.0.0.5:8000/v1",
                     "http://169.254.10.2:8080", "http://100.101.102.103:8080/v1",
                     "http://gpu-box.tail1234.ts.net:8080/v1", "http://studio.local:9000/v1"] {
            let pending = configuration(base)
            guard let origin = pending.origin else {
                XCTFail("No origin for \(base)")
                continue
            }
            XCTAssertThrowsError(try pending.validatedEndpoint(), base) {
                XCTAssertEqual($0 as? RemoteTranscriptionError, .approvalRequired(origin), base)
            }
            let approved = configuration(base, approved: [origin])
            XCTAssertTrue(approved.isReady, base)
            XCTAssertTrue(approved.presentation.isRemote, base)
        }
    }

    func testThinkApprovalDoesNotApproveAudio() {
        var settings = AppSettings()
        settings.transcriptionModel = .remoteServer
        settings.remoteTranscriptionBaseURL = "https://api.openai.com/v1"
        settings.approvedRemoteInferenceOrigins = ["https://api.openai.com"]
        XCTAssertFalse(settings.remoteTranscription.isReady)
        XCTAssertFalse(ModelReadinessSnapshot.transcriptionReady(settings))
        XCTAssertTrue(settings.transcriptionPresentation.isBlocked)

        settings.approvedRemoteTranscriptionOrigins = ["https://api.openai.com"]
        XCTAssertTrue(ModelReadinessSnapshot.transcriptionReady(settings))
        XCTAssertEqual(settings.transcriptionPresentation, .remote(host: "api.openai.com"))
    }

    func testLocalModelsKeepAudioOnThisMac() {
        var settings = AppSettings()
        settings.transcriptionModel = .parakeetV3
        settings.remoteTranscriptionBaseURL = "https://api.openai.com/v1"
        settings.approvedRemoteTranscriptionOrigins = ["https://api.openai.com"]
        XCTAssertEqual(settings.transcriptionPresentation, .onDevice)
    }

    func testServerCountsAsAvailableOnlyWhenReady() {
        XCTAssertFalse(TranscriptionModelStore.isDownloaded(.remoteServer))
        XCTAssertTrue(TranscriptionModelStore.isDownloaded(.remoteServer, remoteTranscriptionReady: true))
        XCTAssertNil(TranscriptionModelChoice.remoteServer.sizeLabel)
    }

    // MARK: - Settings

    func testServerSettingsSurviveEncoding() throws {
        var settings = AppSettings()
        settings.transcriptionModel = .remoteServer
        settings.remoteTranscriptionBaseURL = "http://gpu-box.tail1234.ts.net:8080/v1"
        settings.remoteTranscriptionModel = "large-v3-turbo"
        settings.approvedRemoteTranscriptionOrigins = ["http://gpu-box.tail1234.ts.net:8080"]

        let reloaded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))

        XCTAssertEqual(reloaded.transcriptionModel, .remoteServer)
        XCTAssertEqual(reloaded.remoteTranscriptionBaseURL, "http://gpu-box.tail1234.ts.net:8080/v1")
        XCTAssertEqual(reloaded.remoteTranscriptionModel, "large-v3-turbo")
        XCTAssertEqual(reloaded.approvedRemoteTranscriptionOrigins, ["http://gpu-box.tail1234.ts.net:8080"])
        XCTAssertEqual(reloaded.transcriptionModelDisplayName, "large-v3-turbo · gpu-box.tail1234.ts.net")
    }

    func testOlderSettingsHaveNoServer() throws {
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(settings.remoteTranscriptionBaseURL, "")
        XCTAssertEqual(settings.remoteTranscriptionModel, "")
        XCTAssertTrue(settings.approvedRemoteTranscriptionOrigins.isEmpty)
        XCTAssertFalse(settings.remoteTranscription.isReady)
    }

    func testSelectionPatchAppliesAndUndoesServerFields() {
        var settings = AppSettings()
        settings.transcriptionModel = .parakeetV3
        settings.remoteTranscriptionBaseURL = "https://api.groq.com/openai/v1"
        settings.remoteTranscriptionModel = "whisper-large-v3"
        let patch = ModelSelectionPatch(transcription: .remoteServer,
                                        remoteTranscriptionBaseURL: "http://192.168.1.20:8080/inference",
                                        remoteTranscriptionModel: "")
        let inverse = patch.inverse(in: settings)

        let applied = patch.applying(to: settings)
        XCTAssertEqual(applied.transcriptionModel, .remoteServer)
        XCTAssertEqual(applied.remoteTranscriptionBaseURL, "http://192.168.1.20:8080/inference")
        XCTAssertEqual(applied.remoteTranscriptionModel, "")
        XCTAssertTrue(patch.matches(applied))

        let undone = inverse.applying(to: applied)
        XCTAssertEqual(undone.transcriptionModel, .parakeetV3)
        XCTAssertEqual(undone.remoteTranscriptionBaseURL, "https://api.groq.com/openai/v1")
        XCTAssertEqual(undone.remoteTranscriptionModel, "whisper-large-v3")
    }

    func testThinkKeyIsReusedOnlyForTheSameOrigin() {
        var thinkKeyReads = 0
        let thinkKey: () -> String = {
            thinkKeyReads += 1
            return "think-key"
        }
        XCTAssertEqual(AppSettings.remoteTranscriptionRequestKey(
            transcriptionBaseURL: "https://openrouter.ai/api/v1", thinkBaseURL: "https://openrouter.ai/api/v1",
            ownKey: "own-key", thinkKey: thinkKey), "own-key")
        XCTAssertEqual(AppSettings.remoteTranscriptionRequestKey(
            transcriptionBaseURL: "https://openrouter.ai/api/v1/audio/transcriptions",
            thinkBaseURL: "https://openrouter.ai/api/v1",
            ownKey: "", thinkKey: thinkKey), "think-key")
        XCTAssertEqual(AppSettings.remoteTranscriptionRequestKey(
            transcriptionBaseURL: "https://api.groq.com/openai/v1", thinkBaseURL: "https://openrouter.ai/api/v1",
            ownKey: "", thinkKey: thinkKey), "")
        XCTAssertEqual(AppSettings.remoteTranscriptionRequestKey(
            transcriptionBaseURL: "http://gpu-box.tail1234.ts.net:8080", thinkBaseURL: "https://openrouter.ai/api/v1",
            ownKey: "", thinkKey: thinkKey), "")
        XCTAssertEqual(thinkKeyReads, 1, "Think's key is read only when it would be sent to Think's own origin")
    }

    func testCheckpointIdentityNamesTheServerButNeverTheKey() {
        let engine = RemoteTranscriptionEngine(
            configuration: configuration("https://api.openai.com/v1"), apiKey: { "sk-secret" })
        XCTAssertEqual(engine.checkpointIdentity, "remote:https://api.openai.com/v1/audio/transcriptions|whisper-1")
        XCTAssertFalse(engine.checkpointIdentity.contains("sk-secret"))
        XCTAssertEqual(configuration("https://api.openai.com/v1").transcriptEngine,
                       "whisper-1 (remote https://api.openai.com)")
        XCTAssertEqual(configuration("http://192.168.1.20:8080/inference", model: " ").transcriptEngine,
                       "server default (remote http://192.168.1.20:8080)")
    }

    func testReadinessDetailNamesTheTranscriptionServer() {
        let snapshot = ModelReadinessSnapshot(
            transcriptionReady: true, thinkReady: true, autocompleteReady: true, provenance: .local,
            storedBytes: 0, availableBytes: nil, activeDownloads: 0, failedDownloads: 0,
            transcriptionHost: "gpu-box.tail1234.ts.net")
        XCTAssertEqual(snapshot.detail,
                       "Transcription uses gpu-box.tail1234.ts.net. Think runs on this Mac. Autocomplete is also available.")
    }

    func testCoreRolesShowWhereTheServerIs() {
        var settings = AppSettings()
        settings.transcriptionModel = .remoteServer
        settings.remoteTranscriptionBaseURL = "https://openrouter.ai/api/v1"
        settings.approvedRemoteTranscriptionOrigins = ["https://openrouter.ai"]
        XCTAssertEqual(ModelSettingsPresentation.transcriptionServerDestination(settings), "OpenRouter · Remote")

        settings.remoteTranscriptionBaseURL = "http://gpu-box.tail1234.ts.net:8080/v1"
        XCTAssertEqual(ModelSettingsPresentation.transcriptionServerDestination(settings),
                       "Connection needs attention")
        settings.approvedRemoteTranscriptionOrigins.append("http://gpu-box.tail1234.ts.net:8080")
        XCTAssertEqual(ModelSettingsPresentation.transcriptionServerDestination(settings),
                       "gpu-box.tail1234.ts.net · Remote")

        settings.remoteTranscriptionBaseURL = "http://127.0.0.1:8080/inference"
        XCTAssertEqual(ModelSettingsPresentation.transcriptionServerDestination(settings),
                       "On this Mac · Local server")
    }

    // MARK: - Request

    func testRequestIsOpenAIStyleMultipart() throws {
        let request = RemoteTranscriptionEngine.makeRequest(
            endpoint: try endpoint(), apiKey: "sk-test", model: "whisper-1", boundary: "B",
            wav: OnnxTranscriptionEngine.wavData([0, 0.5, -0.5]), language: "sr", prompt: "Mila Novak, Orion")

        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "multipart/form-data; boundary=B")
        let body = try XCTUnwrap(request.httpBody)
        XCTAssertEqual(formFieldNames(body), ["model", "response_format", "temperature", "language", "prompt", "file"])
        let text = String(decoding: body, as: UTF8.self)
        for (name, value) in [("model", "whisper-1"), ("response_format", "json"), ("temperature", "0"),
                              ("language", "sr"), ("prompt", "Mila Novak, Orion")] {
            XCTAssertTrue(text.contains("name=\"\(name)\"\r\n\r\n\(value)\r\n"), name)
        }
        XCTAssertTrue(text.contains(
            "name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\nRIFF"))
        XCTAssertTrue(text.hasSuffix("\r\n--B--\r\n"))
    }

    func testSingleModelServerGetsNoModelKeyOrLanguage() throws {
        let request = RemoteTranscriptionEngine.makeRequest(
            endpoint: try endpoint(), apiKey: "", model: "", boundary: "B",
            wav: OnnxTranscriptionEngine.wavData([0]), language: nil, prompt: nil)
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(formFieldNames(try XCTUnwrap(request.httpBody)), ["response_format", "temperature", "file"])
    }

    func testTranscriptTextReadsJSONOrPlainText() throws {
        XCTAssertEqual(try RemoteTranscriptionEngine.transcriptText(
            from: Data(#"{"text":" Hello there. "}"#.utf8), response: response(contentType: "application/json")),
                       " Hello there. ")
        XCTAssertEqual(try RemoteTranscriptionEngine.transcriptText(
            from: Data("Hello there.".utf8), response: response(contentType: "text/plain; charset=utf-8")),
                       "Hello there.")
        XCTAssertThrowsError(try RemoteTranscriptionEngine.transcriptText(
            from: Data("<html></html>".utf8), response: response(contentType: "text/html"))) {
            XCTAssertEqual($0 as? RemoteTranscriptionError, .invalidResponse)
        }
    }

    func testErrorDetailReadsTheServerMessage() {
        func detail(_ body: String) -> String { RemoteTranscriptionEngine.errorDetail(from: Data(body.utf8)) }
        XCTAssertEqual(detail(#"{"error":{"message":"Invalid API key"}}"#), "Invalid API key")
        XCTAssertEqual(detail(#"{"error":"model not found"}"#), "model not found")
        XCTAssertEqual(detail(#"{"detail":"File too large"}"#), "File too large")
        XCTAssertEqual(detail("Bad Gateway\n"), "Bad Gateway")
        let long = detail(#"{"error":{"message":""# + String(repeating: "x", count: 400) + #""}}"#)
        XCTAssertEqual(long.count, 301)
        XCTAssertTrue(long.hasSuffix("…"))
        XCTAssertEqual(RemoteTranscriptionError.rejected(status: 401, detail: "Invalid API key").errorDescription,
                       "The transcription server rejected the API key (HTTP 401). Invalid API key")
    }

    // MARK: - Upload

    func testUploadRetriesAServerErrorThenReturnsText() async throws {
        RemoteTranscriptionURLProtocolStub.enqueue(status: 503, headers: ["Retry-After": "1"], body: "busy")
        RemoteTranscriptionURLProtocolStub.enqueue(
            status: 200, headers: ["Content-Type": "application/json"], body: #"{"text":"Hello"}"#)
        let delays = DelayLog()
        let session = RemoteTranscriptionURLProtocolStub.session()
        defer { session.invalidateAndCancel() }
        let engine = RemoteTranscriptionEngine(
            configuration: configuration("https://api.openai.com/v1", approved: ["https://api.openai.com"]),
            apiKey: { "" }, session: session, sleep: { await delays.record($0) })

        let text = try await engine.upload(
            OnnxTranscriptionEngine.wavData([0, 0]), endpoint: try endpoint(), apiKey: "sk-test",
            model: "whisper-1", language: nil, prompt: nil)

        XCTAssertEqual(text, "Hello")
        XCTAssertEqual(RemoteTranscriptionURLProtocolStub.requests.count, 2)
        XCTAssertEqual(RemoteTranscriptionURLProtocolStub.requests.last?.value(forHTTPHeaderField: "Authorization"),
                       "Bearer sk-test")
        let waited = await delays.values
        XCTAssertEqual(waited, [1])
    }

    func testUploadDoesNotRetryARejectedKey() async throws {
        RemoteTranscriptionURLProtocolStub.enqueue(
            status: 401, headers: ["Content-Type": "application/json"],
            body: #"{"error":{"message":"Invalid API key"}}"#)
        let delays = DelayLog()
        let session = RemoteTranscriptionURLProtocolStub.session()
        defer { session.invalidateAndCancel() }
        let engine = RemoteTranscriptionEngine(
            configuration: configuration("https://api.openai.com/v1", approved: ["https://api.openai.com"]),
            apiKey: { "" }, session: session, sleep: { await delays.record($0) })

        do {
            _ = try await engine.upload(
                OnnxTranscriptionEngine.wavData([0, 0]), endpoint: try endpoint(), apiKey: "wrong",
                model: "whisper-1", language: nil, prompt: nil)
            XCTFail("A rejected key must surface")
        } catch {
            XCTAssertEqual(error as? RemoteTranscriptionError,
                           .rejected(status: 401, detail: "Invalid API key"))
        }
        XCTAssertEqual(RemoteTranscriptionURLProtocolStub.requests.count, 1)
        let waited = await delays.values
        XCTAssertTrue(waited.isEmpty)
    }

    func testTranscribeRefusesAnUnapprovedServerBeforeReadingAudio() async {
        let engine = RemoteTranscriptionEngine(
            configuration: configuration("https://api.openai.com/v1"), apiKey: { "" })
        do {
            _ = try await engine.transcribe(
                audio: URL(fileURLWithPath: "/nonexistent/track.wav"), language: nil, prompt: nil)
            XCTFail("An unapproved server must not receive audio")
        } catch {
            XCTAssertEqual(error as? RemoteTranscriptionError, .approvalRequired("https://api.openai.com"))
        }
    }

    // MARK: - Spans

    func testSpeakerTurnsAreAttributedAfterTranscription() {
        let engine = RemoteTranscriptionEngine(
            configuration: configuration("https://api.openai.com/v1"), apiKey: { "" })
        // Cutting at every turn sent each sub-second fragment as its own request.
        XCTAssertEqual(engine.speakerAttribution, .alignedWords)
    }

    func testNearbySpeechSharesOneRequest() {
        let spans = [0.0, 1.5, 3.0].map { SpeechSpan(start: $0, end: $0 + 1, timingPrecision: .span) }
            + [SpeechSpan(start: 10, end: 12, timingPrecision: .span)]

        let lines = RemoteTranscriptionEngine.windows(in: spans, RemoteTranscriptionEngine.lineWindows)

        XCTAssertEqual(lines.map(\.start), [0, 10], "A pause longer than the gap starts a new request")
        XCTAssertEqual(lines.map(\.end), [4, 12])
        XCTAssertEqual(lines.map(\.timingPrecision), [.span, .span])
    }

    func testWindowsStayWithinTheirLength() {
        let spans = stride(from: 0.0, to: 120, by: 2).map {
            SpeechSpan(start: $0, end: $0 + 1.5, timingPrecision: .span)
        }
        for windowing in [RemoteTranscriptionEngine.lineWindows, RemoteTranscriptionEngine.attributionWindows] {
            let windows = RemoteTranscriptionEngine.windows(in: spans, windowing)
            XCTAssertTrue(windows.allSatisfy { $0.end - $0.start <= windowing.maxSeconds })
            XCTAssertLessThan(windows.count, spans.count / 3)
            XCTAssertEqual(windows.first?.start, 0)
            XCTAssertEqual(windows.last?.end, 119.5)
        }
        XCTAssertLessThanOrEqual(RemoteTranscriptionEngine.attributionWindows.maxSeconds, 30,
                                 "Clips stay far below provider upload limits and timeouts")
    }

    func testSpansUploadAsWavClipsAndKeepTheirTiming() async throws {
        let url = try writeTrack(seconds: 3)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let spans = [
            SpeechSpan(start: 0, end: 1, timingPrecision: .span),
            SpeechSpan(start: 1.2, end: 1.25, timingPrecision: .span), // 50 ms holds no words
            SpeechSpan(start: 1.5, end: 3, timingPrecision: .span),
        ]
        let uploads = UploadLog()

        let segments = try await RemoteTranscriptionEngine.segments(
            in: url, spans: spans, maximumConcurrent: 2
        ) { wav in
            await uploads.record(wav)
            return wav.count > 40_000 ? " second clip " : "first clip"
        }

        XCTAssertEqual(segments.map(\.text), ["first clip", "second clip"])
        XCTAssertEqual(segments.map(\.start), [0, 1.5])
        XCTAssertEqual(segments.map(\.end), [1, 3])
        XCTAssertEqual(segments.map(\.timingPrecision), [.span, .span])
        let clips = await uploads.clips
        XCTAssertEqual(clips.map(\.count).sorted(), [44 + 16_000 * 2, 44 + 24_000 * 2])
        XCTAssertTrue(clips.allSatisfy { $0.prefix(4) == Data("RIFF".utf8) })
    }

    func testUploadsStayWithinTheConcurrencyLimit() async throws {
        let url = try writeTrack(seconds: 3)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let spans = (0..<6).map { SpeechSpan(start: Double($0) * 0.5, end: Double($0) * 0.5 + 0.5, timingPrecision: .span) }
        let tracker = ConcurrencyTracker()

        let segments = try await RemoteTranscriptionEngine.segments(
            in: url, spans: spans, maximumConcurrent: 2
        ) { _ in
            await tracker.enter()
            try await Task.sleep(for: .milliseconds(20))
            await tracker.leave()
            return "words"
        }

        XCTAssertEqual(segments.count, 6)
        let peak = await tracker.peak
        XCTAssertLessThanOrEqual(peak, 2)
        XCTAssertGreaterThanOrEqual(peak, 1)
    }

    // MARK: - Helpers

    private func configuration(_ baseURL: String, model: String = "whisper-1",
                               approved: [String] = []) -> RemoteTranscriptionConfiguration {
        RemoteTranscriptionConfiguration(baseURL: baseURL, model: model, approvedOrigins: approved)
    }

    private func endpoint() throws -> URL {
        try XCTUnwrap(URL(string: "https://api.openai.com/v1/audio/transcriptions"))
    }

    private func response(contentType: String) throws -> HTTPURLResponse {
        try XCTUnwrap(HTTPURLResponse(
            url: try endpoint(), statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": contentType]))
    }

    private func formFieldNames(_ body: Data) -> [String] {
        String(decoding: body, as: UTF8.self)
            .components(separatedBy: "Content-Disposition: form-data; name=\"")
            .dropFirst()
            .map { String($0.prefix { $0 != "\"" }) }
    }

    private func writeTrack(seconds: Int) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lokalbot-remote-asr-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("track.wav")
        try OnnxTranscriptionEngine.writeWav([Float](repeating: 0.1, count: seconds * 16_000), to: url)
        return url
    }
}

private actor UploadLog {
    private(set) var clips: [Data] = []
    func record(_ clip: Data) { clips.append(clip) }
}

private actor DelayLog {
    private(set) var values: [TimeInterval] = []
    func record(_ value: TimeInterval) { values.append(value) }
}

private actor ConcurrencyTracker {
    private var running = 0
    private(set) var peak = 0
    func enter() {
        running += 1
        peak = max(peak, running)
    }
    func leave() { running -= 1 }
}

/// Answers each request with the next queued response and records it.
private final class RemoteTranscriptionURLProtocolStub: URLProtocol {
    private struct Reply {
        let status: Int
        let headers: [String: String]
        let body: Data
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var replies: [Reply] = []
    nonisolated(unsafe) private static var storedRequests: [URLRequest] = []

    static var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return storedRequests
    }

    static func enqueue(status: Int, headers: [String: String], body: String) {
        lock.lock()
        replies.append(Reply(status: status, headers: headers, body: Data(body.utf8)))
        lock.unlock()
    }

    static func reset() {
        lock.lock()
        replies = []
        storedRequests = []
        lock.unlock()
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RemoteTranscriptionURLProtocolStub.self]
        return URLSession(configuration: configuration)
    }

    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.storedRequests.append(request)
        let reply = Self.replies.isEmpty ? nil : Self.replies.removeFirst()
        Self.lock.unlock()

        guard let reply, let url = request.url,
              let response = HTTPURLResponse(
                  url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
