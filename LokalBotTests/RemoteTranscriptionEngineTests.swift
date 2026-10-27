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

    func testUkrainianHintReachesOpenAIAndWhisperCppRequests() throws {
        let language = try XCTUnwrap(TranscriptionLanguage(rawValue: "uk"))
        for base in ["http://127.0.0.1:8080/v1", "http://127.0.0.1:8080/inference"] {
            let request = RemoteTranscriptionEngine.makeRequest(
                endpoint: try configuration(base).validatedEndpoint(), apiKey: "", model: "large-v3-turbo", boundary: "B",
                wav: OnnxTranscriptionEngine.wavData([0]), language: language.code, prompt: nil)
            let text = String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self)
            XCTAssertTrue(text.contains("name=\"language\"\r\n\r\nuk\r\n"), base)
            XCTAssertFalse(text.contains("\r\nru\r\n"), base)
        }
    }

    func testSingleModelServerGetsNoModelKeyOrLanguage() throws {
        let request = RemoteTranscriptionEngine.makeRequest(
            endpoint: try endpoint(), apiKey: "", model: "", boundary: "B",
            wav: OnnxTranscriptionEngine.wavData([0]), language: nil, prompt: nil)
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(formFieldNames(try XCTUnwrap(request.httpBody)), ["response_format", "temperature", "file"])
    }

    func testTranscriptTextReadsJSONOrPlainText() throws {
        XCTAssertEqual(try RemoteTranscriptionEngine.transcription(
            from: Data(#"{"text":" Hello there. "}"#.utf8), response: response(contentType: "application/json")),
                       .init(text: " Hello there. "))
        XCTAssertEqual(try RemoteTranscriptionEngine.transcription(
            from: Data("Hello there.".utf8), response: response(contentType: "text/plain; charset=utf-8")),
                       .init(text: "Hello there."))
        XCTAssertThrowsError(try RemoteTranscriptionEngine.transcription(
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

    // MARK: - Word timings

    func testWordTimesAreRequestedOnlyFromServersKnownToReturnThem() {
        let rejections = WordTimingRejections()
        func engine(_ base: String, _ model: String) -> RemoteTranscriptionEngine {
            var engine = RemoteTranscriptionEngine(configuration: configuration(base, model: model), apiKey: { "" })
            engine.wordTimingRejections = rejections
            return engine
        }
        XCTAssertTrue(engine("https://openrouter.ai/api/v1", "microsoft/mai-transcribe-2").providesWordTimings)
        XCTAssertTrue(engine("https://openrouter.ai/api/v1/audio/transcriptions", " Microsoft/MAI-Transcribe-2 ")
            .providesWordTimings)
        XCTAssertTrue(engine("https://openrouter.ai/api/v1", "google/gemini-3.5-transcribe").providesWordTimings)
        XCTAssertTrue(engine("https://openrouter.ai/api/v1", "openai/whisper-large-v3-turbo").providesWordTimings)
        XCTAssertFalse(engine("https://openrouter.ai/api/v1", "openai/whisper-large-v3").providesWordTimings,
                       "One of its providers stretches words across pauses")
        XCTAssertFalse(engine("https://openrouter.ai/api/v1", "openai/gpt-4o-mini-transcribe").providesWordTimings)
        XCTAssertFalse(engine("https://openrouter.ai/api/v1", "microsoft/mai-transcribe-1.5").providesWordTimings)
        XCTAssertFalse(engine("https://api.openai.com/v1", "whisper-1").providesWordTimings)
        XCTAssertFalse(engine("http://127.0.0.1:8080/inference", "microsoft/mai-transcribe-2").providesWordTimings)

        rejections.insert(configuration("https://openrouter.ai/api/v1", model: "microsoft/mai-transcribe-2").wordTimingKey)
        XCTAssertFalse(engine("https://openrouter.ai/api/v1", "microsoft/mai-transcribe-2").providesWordTimings,
                       "A refusal is remembered for that server and model")
    }

    func testWordTimingRequestAsksForVerboseJSONWithWordTimestamps() throws {
        let request = RemoteTranscriptionEngine.makeRequest(
            endpoint: try endpoint(), apiKey: "sk-test", model: "microsoft/mai-transcribe-2", boundary: "B",
            wav: OnnxTranscriptionEngine.wavData([0]), language: "en", prompt: "Orion", wordTimings: true)
        let body = try XCTUnwrap(request.httpBody)
        XCTAssertEqual(formFieldNames(body), ["model", "response_format", "timestamp_granularities[]", "temperature",
                                              "language", "prompt", "file"])
        let text = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(text.contains("name=\"response_format\"\r\n\r\nverbose_json\r\n"))
        XCTAssertTrue(text.contains("name=\"timestamp_granularities[]\"\r\n\r\nword\r\n"))
    }

    func testVerboseJSONWordsAreReadRelativeToTheClip() throws {
        let reply = try RemoteTranscriptionEngine.transcription(
            from: Data(Self.recordedVerboseJSON.utf8), response: response(contentType: "application/json"))

        XCTAssertEqual(reply.text, "The quarterly plan is ready for review. Thanks. I will send my notes tomorrow.")
        let words = try XCTUnwrap(reply.words)
        XCTAssertEqual(words.count, 14)
        XCTAssertEqual(words.first, AlignedWordTiming(text: "The", start: 0.08, end: 0.179))
        XCTAssertEqual(words[7], AlignedWordTiming(text: "Thanks.", start: 5.16, end: 5.66))
        XCTAssertEqual(words.last?.text, "tomorrow.")
    }

    func testUnusableWordTimesAreDropped() throws {
        func words(_ list: String) throws -> [AlignedWordTiming]? {
            try RemoteTranscriptionEngine.transcription(
                from: Data((#"{"text":"Ready. Go","words":"# + list + "}").utf8),
                response: response(contentType: "application/json")).words
        }
        XCTAssertEqual(try words(#"[{"word":" Ready.","start":0,"end":0.4},{"word":"—","start":0.4,"end":0.5},"#
                                    + #"{"word":"Go","start":0.6,"end":0.9}]"#)?.map(\.text), ["Ready.", "Go"],
                       "Punctuation tokens carry no word to attribute")
        XCTAssertNil(try words(#"[{"word":"Ready.","start":0,"end":0.4},{"word":"Go","start":0.6}]"#),
                     "One word without times leaves the window to the aligner")
        XCTAssertNil(try words(#"[{"word":"Ready.","start":0.5,"end":0.4}]"#))
        XCTAssertNil(try words(#"[{"word":"Ready.","start":-1,"end":0.4}]"#))
        XCTAssertNil(try words("[]"))
        XCTAssertNil(try RemoteTranscriptionEngine.transcription(
            from: Data(#"{"text":"Ready. Go"}"#.utf8), response: response(contentType: "application/json")).words)
    }

    func testWindowWordsMoveOntoTheTrackTimeline() async throws {
        let url = try writeTrack(seconds: 3)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let spans = [SpeechSpan(start: 0.5, end: 1.5, timingPrecision: .span),
                     SpeechSpan(start: 2, end: 2.5, timingPrecision: .span)]

        let segments = try await RemoteTranscriptionEngine.segments(
            in: url, spans: spans, maximumConcurrent: 1
        ) { wav in
            wav.count > 20_000
                ? .init(text: "Hello there", words: [.init(text: "Hello", start: 0.1, end: 0.4),
                                                     .init(text: "there", start: 0.5, end: 1.2)])
                : .init(text: "No times")
        }

        XCTAssertEqual(segments.map(\.segment.text), ["Hello there", "No times"])
        let words = try XCTUnwrap(segments[0].words)
        XCTAssertEqual(words.map(\.text), ["Hello", "there"])
        // Offset by the window start, and kept inside the window.
        for (actual, expected) in zip(words.flatMap { [$0.start, $0.end] }, [0.6, 0.9, 1.0, 1.5]) {
            XCTAssertEqual(actual, expected, accuracy: 1e-9)
        }
        XCTAssertNil(segments[1].words)
    }

    func testRefusedWordTimingsFallBackToJSONAndAreRemembered() async throws {
        RemoteTranscriptionURLProtocolStub.enqueue(
            status: 400, headers: ["Content-Type": "application/json"],
            body: #"{"error":{"message":"The selected model does not support response_format \"verbose_json\". "# +
                #"Use \"json\" instead.","code":400}}"#)
        RemoteTranscriptionURLProtocolStub.enqueue(
            status: 200, headers: ["Content-Type": "application/json"], body: #"{"text":"Hello"}"#)
        RemoteTranscriptionURLProtocolStub.enqueue(
            status: 200, headers: ["Content-Type": "application/json"], body: #"{"text":"Again"}"#)
        let session = RemoteTranscriptionURLProtocolStub.session()
        defer { session.invalidateAndCancel() }
        let delays = DelayLog()
        let engine = wordTimingEngine(session: session, delays: delays)
        XCTAssertTrue(engine.providesWordTimings)

        let first = try await engine.upload(
            OnnxTranscriptionEngine.wavData([0, 0]), endpoint: try endpoint(), apiKey: "sk-test",
            model: "microsoft/mai-transcribe-2", language: nil, prompt: nil, wordTimings: true)
        let second = try await engine.upload(
            OnnxTranscriptionEngine.wavData([0, 0]), endpoint: try endpoint(), apiKey: "sk-test",
            model: "microsoft/mai-transcribe-2", language: nil, prompt: nil, wordTimings: true)

        XCTAssertEqual(first, .init(text: "Hello"))
        XCTAssertEqual(second, .init(text: "Again"))
        XCTAssertEqual(RemoteTranscriptionURLProtocolStub.requests.map(responseFormat),
                       ["verbose_json", "json", "json"])
        XCTAssertFalse(engine.providesWordTimings, "The next meeting goes straight to the aligner")
        let waited = await delays.values
        XCTAssertTrue(waited.isEmpty, "The fallback is not a retry")
    }

    func testA400ForPlainJSONTooIsNotBlamedOnWordTimings() async throws {
        for _ in 0..<2 {
            RemoteTranscriptionURLProtocolStub.enqueue(
                status: 400, headers: ["Content-Type": "application/json"],
                body: #"{"error":{"message":"Audio file is too short"}}"#)
        }
        let session = RemoteTranscriptionURLProtocolStub.session()
        defer { session.invalidateAndCancel() }
        let engine = wordTimingEngine(session: session, delays: DelayLog())

        do {
            _ = try await engine.upload(
                OnnxTranscriptionEngine.wavData([0, 0]), endpoint: try endpoint(), apiKey: "sk-test",
                model: "microsoft/mai-transcribe-2", language: nil, prompt: nil, wordTimings: true)
            XCTFail("A clip the server refuses either way must surface")
        } catch {
            XCTAssertEqual(error as? RemoteTranscriptionError,
                           .rejected(status: 400, detail: "Audio file is too short"))
        }
        XCTAssertEqual(RemoteTranscriptionURLProtocolStub.requests.map(responseFormat), ["verbose_json", "json"])
        XCTAssertTrue(engine.providesWordTimings)
    }

    func testRetriesKeepAskingForWordTimes() async throws {
        RemoteTranscriptionURLProtocolStub.enqueue(status: 503, headers: [:], body: "busy")
        RemoteTranscriptionURLProtocolStub.enqueue(
            status: 200, headers: ["Content-Type": "application/json"], body: Self.recordedVerboseJSON)
        let session = RemoteTranscriptionURLProtocolStub.session()
        defer { session.invalidateAndCancel() }
        let engine = wordTimingEngine(session: session, delays: DelayLog())

        let reply = try await engine.upload(
            OnnxTranscriptionEngine.wavData([0, 0]), endpoint: try endpoint(), apiKey: "sk-test",
            model: "microsoft/mai-transcribe-2", language: nil, prompt: nil, wordTimings: true)

        XCTAssertEqual(reply.words?.count, 14)
        XCTAssertEqual(RemoteTranscriptionURLProtocolStub.requests.map(responseFormat),
                       ["verbose_json", "verbose_json"])
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

        let reply = try await engine.upload(
            OnnxTranscriptionEngine.wavData([0, 0]), endpoint: try endpoint(), apiKey: "sk-test",
            model: "whisper-1", language: nil, prompt: nil)

        XCTAssertEqual(reply, .init(text: "Hello"))
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
            return .init(text: wav.count > 40_000 ? " second clip " : "first clip")
        }

        XCTAssertEqual(segments.map(\.segment.text), ["first clip", "second clip"])
        XCTAssertEqual(segments.map(\.segment.start), [0, 1.5])
        XCTAssertEqual(segments.map(\.segment.end), [1, 3])
        XCTAssertEqual(segments.map(\.segment.timingPrecision), [.span, .span])
        XCTAssertTrue(segments.allSatisfy { $0.words == nil })
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
            return .init(text: "words")
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

    /// MAI-Transcribe-2 on OpenRouter, 2026-10-19: a synthetic `say` clip,
    /// Samantha from 0 s and Daniel from 5.0 s.
    private static let recordedVerboseJSON = #"""
        {"text":"The quarterly plan is ready for review. Thanks. I will send my notes tomorrow.",\#
        "usage":{"seconds":9,"cost":0.00025},"language":"en","duration":8.2,\#
        "segments":[{"id":0,"start":0,"end":8.195,\#
        "text":"The quarterly plan is ready for review. Thanks. I will send my notes tomorrow."}],\#
        "words":[{"word":"The","start":0.08,"end":0.179},{"word":"quarterly","start":0.24,"end":0.62},\#
        {"word":"plan","start":0.72,"end":0.92},{"word":"is","start":0.98,"end":1.06},\#
        {"word":"ready","start":1.16,"end":1.36},{"word":"for","start":1.4,"end":1.519},\#
        {"word":"review.","start":1.64,"end":1.979},{"word":"Thanks.","start":5.16,"end":5.66},\#
        {"word":"I","start":5.96,"end":6.04},{"word":"will","start":6.08,"end":6.24},\#
        {"word":"send","start":6.36,"end":6.539},{"word":"my","start":6.6,"end":6.719},\#
        {"word":"notes","start":6.84,"end":7.08},{"word":"tomorrow.","start":7.16,"end":7.719}]}
        """#

    private func wordTimingEngine(session: URLSession, delays: DelayLog) -> RemoteTranscriptionEngine {
        var engine = RemoteTranscriptionEngine(
            configuration: configuration("https://openrouter.ai/api/v1", model: "microsoft/mai-transcribe-2",
                                         approved: ["https://openrouter.ai"]),
            apiKey: { "" }, session: session, sleep: { await delays.record($0) })
        engine.wordTimingRejections = WordTimingRejections()
        return engine
    }

    private func responseFormat(_ request: URLRequest) -> String {
        let body = request.httpBody ?? request.httpBodyStream.map(Self.read) ?? Data()
        let text = String(decoding: body, as: UTF8.self)
        guard let range = text.range(of: "name=\"response_format\"\r\n\r\n") else { return "" }
        return String(text[range.upperBound...].prefix { !$0.isNewline })
    }

    private static func read(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
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
