import XCTest
@testable import LokalBot

final class CotypingServerRouteTests: XCTestCase {
    private let tailnetURL = "http://100.101.102.103:1234/v1"
    private let tailnetOrigin = "http://100.101.102.103:1234"

    func testAutocompleteStaysOnThisMacByDefault() {
        let settings = AppSettings()
        XCTAssertEqual(settings.cotypingBackend, .onDevice)
        XCTAssertEqual(settings.cotypingRoute(includingCredentials: false), .onDevice)
        XCTAssertFalse(settings.cotypingLeavesThisMac)
        XCTAssertEqual(settings.cotypingEffectiveSettings, settings)
        XCTAssertEqual(settings.cotypingRouteFingerprint, "on-device")
    }

    func testAnotherServerNeedsAURLAnApprovalAndAModel() throws {
        var settings = AppSettings()
        settings.cotypingBackend = .server
        XCTAssertTrue(unavailableReason(settings).contains("Add a server URL"))

        settings.cotypingServerBaseURL = tailnetURL
        XCTAssertTrue(unavailableReason(settings).contains("Approve \(tailnetOrigin) for autocomplete"))

        settings.approvedRemoteAutocompleteOrigins = [tailnetOrigin]
        XCTAssertTrue(unavailableReason(settings).contains("Name the model"))

        settings.cotypingServerModel = " qwen2.5-coder-1.5b "
        let endpoint = try XCTUnwrap(serverEndpoint(settings))
        XCTAssertEqual(endpoint.baseURL.absoluteString, tailnetURL)
        XCTAssertEqual(endpoint.model, "qwen2.5-coder-1.5b")
        XCTAssertEqual(endpoint.origin, tailnetOrigin)
        XCTAssertEqual(endpoint.dialect, .generic)
        XCTAssertNil(endpoint.apiKey)
        XCTAssertTrue(endpoint.isSelfHosted)
        XCTAssertFalse(endpoint.isOnThisMac)
        XCTAssertFalse(endpoint.startsWithChat, "a server people run themselves gets raw text completion first")
        XCTAssertEqual(settings.cotypingModelDisplayName, "qwen2.5-coder-1.5b · 100.101.102.103")
        XCTAssertEqual(settings.cotypingStatisticsModelID, "qwen2.5-coder-1.5b")
    }

    func testTailnetNamesWorkOverPlainHTTPOnceApproved() throws {
        var settings = AppSettings()
        settings.cotypingBackend = .server
        settings.cotypingServerBaseURL = "http://windows-box.tail1234.ts.net:1234/v1"
        settings.cotypingServerModel = "llama-3.2-3b"
        XCTAssertTrue(unavailableReason(settings).contains("Approve"))
        settings.approvedRemoteAutocompleteOrigins = ["http://windows-box.tail1234.ts.net:1234"]
        XCTAssertNotNil(serverEndpoint(settings))
    }

    func testInternetServerMustUseHTTPSEvenWhenApproved() {
        var settings = AppSettings()
        settings.cotypingBackend = .server
        settings.cotypingServerBaseURL = "http://inference.example.com/v1"
        settings.cotypingServerModel = "model"
        settings.approvedRemoteAutocompleteOrigins = ["http://inference.example.com"]
        XCTAssertTrue(unavailableReason(settings).contains("unencrypted"))

        settings.cotypingServerBaseURL = "https://inference.example.com/v1"
        settings.approvedRemoteAutocompleteOrigins = ["https://inference.example.com"]
        XCTAssertNotNil(serverEndpoint(settings))
    }

    func testThinkApprovalDoesNotCoverAutocomplete() {
        var settings = AppSettings()
        settings.cotypingBackend = .server
        settings.cotypingServerBaseURL = "https://inference.example.com/v1"
        settings.cotypingServerModel = "model"
        settings.approvedRemoteInferenceOrigins = ["https://inference.example.com"]
        XCTAssertTrue(unavailableReason(settings).contains("Approve https://inference.example.com for autocomplete"))
    }

    func testThinkServerUsesThinksModelUnlessAnotherIsNamed() throws {
        var settings = AppSettings()
        settings.cotypingBackend = .thinkServer
        settings.summarizerBackend = .ollama
        settings.ollamaBaseURL = "http://localhost:11434"
        settings.ollamaModel = "gemma3:12b"
        var endpoint = try XCTUnwrap(serverEndpoint(settings))
        XCTAssertEqual(endpoint.baseURL.absoluteString, "http://localhost:11434/v1")
        XCTAssertEqual(endpoint.model, "gemma3:12b")
        XCTAssertTrue(endpoint.isOnThisMac)

        settings.cotypingThinkServerModel = "gemma3:1b"
        endpoint = try XCTUnwrap(serverEndpoint(settings))
        XCTAssertEqual(endpoint.model, "gemma3:1b")

        settings.summarizerBackend = .openAICompatible
        settings.openAIBaseURL = "https://openrouter.ai/api/v1"
        settings.openAIModel = "openai/gpt-5-mini"
        settings.cotypingThinkServerModel = ""
        settings.approvedRemoteInferenceOrigins = ["https://openrouter.ai"]
        XCTAssertTrue(unavailableReason(settings).contains("for autocomplete"),
                      "Think's approval of the same server does not cover typing")
        settings.approvedRemoteAutocompleteOrigins = ["https://openrouter.ai"]
        endpoint = try XCTUnwrap(serverEndpoint(settings))
        XCTAssertEqual(endpoint.model, "openai/gpt-5-mini")
        XCTAssertEqual(endpoint.dialect, .openRouter)
        XCTAssertTrue(endpoint.startsWithChat)
        XCTAssertFalse(endpoint.isSelfHosted)

        for backend in [AppSettings.SummarizerBackend.builtIn, .appleIntelligence] {
            settings.summarizerBackend = backend
            XCTAssertTrue(unavailableReason(settings).contains("Think doesn't use a server"), backend.rawValue)
        }
    }

    func testRequestStyleDecidesTheFirstRequest() throws {
        func endpoint(_ url: String, _ style: CotypingServerRequestStyle) throws -> CotypingServerEndpoint {
            let baseURL = try XCTUnwrap(URL(string: url))
            return CotypingServerEndpoint(
                baseURL: baseURL, model: "m", apiKey: nil, dialect: .inferred(from: baseURL),
                requestStyle: style, openRouterDataPolicy: .privateOnly,
                origin: try XCTUnwrap(InferenceEndpointPolicy.origin(for: baseURL)))
        }
        XCTAssertFalse(try endpoint("http://192.168.1.20:8080/v1", .automatic).startsWithChat)
        XCTAssertTrue(try endpoint("https://api.openai.com/v1", .automatic).startsWithChat)
        XCTAssertTrue(try endpoint("https://api.anthropic.com", .automatic).startsWithChat)
        XCTAssertTrue(try endpoint("https://openrouter.ai/api/v1", .automatic).startsWithChat)
        XCTAssertTrue(try endpoint("http://192.168.1.20:8080/v1", .chat).startsWithChat)
        XCTAssertFalse(try endpoint("https://openrouter.ai/api/v1", .textCompletion).startsWithChat)
    }

    func testServerOffThisMacGetsOnlyTheTextBeforeTheCaretAndTheProfile() {
        var settings = AppSettings()
        settings.cotypingUseAppContext = true
        settings.cotypingUseClipboard = true
        settings.cotypingUseVisibleContext = true
        settings.cotypingUseWindowText = true
        settings.cotypingUseMeetingMemory = true
        settings.cotypingUseScreenMemory = true
        settings.cotypingUseLocalLearning = true
        settings.cotypingUserName = "Ada"
        settings.cotypingBackend = .server
        settings.cotypingServerBaseURL = tailnetURL
        XCTAssertTrue(settings.cotypingLeavesThisMac)

        let effective = settings.cotypingEffectiveSettings
        XCTAssertFalse(effective.cotypingUseClipboard)
        XCTAssertFalse(effective.cotypingUseVisibleContext)
        XCTAssertFalse(effective.cotypingUseWindowText)
        XCTAssertFalse(effective.cotypingUseMeetingMemory)
        XCTAssertFalse(effective.cotypingUseScreenMemory)
        XCTAssertFalse(effective.cotypingUseLocalLearning)
        XCTAssertTrue(effective.cotypingUseAppContext)
        XCTAssertEqual(effective.cotypingUserName, "Ada")
        XCTAssertTrue(settings.cotypingUseWindowText, "the saved choice is kept for when autocomplete returns to this Mac")

        let context = CotypingContextAvailability(
            settings: settings, accessibilityGranted: true, screenRecordingGranted: true,
            inventory: .init(recentMeetings: 3, meetingFacts: 2, screenFacts: 2))
        XCTAssertEqual(context.visibleText, .unavailable(CotypingContextAvailability.pausedForServer))
        XCTAssertEqual(context.windowText, .unavailable(CotypingContextAvailability.pausedForServer))
        XCTAssertEqual(context.meetingMemory, .unavailable(CotypingContextAvailability.pausedForServer))
        XCTAssertEqual(context.screenMemory, .unavailable(CotypingContextAvailability.pausedForServer))
    }

    func testServerOnThisMacKeepsLocalContext() {
        var settings = AppSettings()
        settings.cotypingUseClipboard = true
        settings.cotypingUseWindowText = true
        settings.cotypingBackend = .server
        settings.cotypingServerBaseURL = "http://127.0.0.1:8080/v1"
        XCTAssertFalse(settings.cotypingLeavesThisMac)
        XCTAssertEqual(settings.cotypingEffectiveSettings, settings)
    }

    func testUnfinishedServerSetupCountsAsLeavingTheMac() {
        var settings = AppSettings()
        settings.cotypingBackend = .server
        XCTAssertTrue(settings.cotypingLeavesThisMac)
        settings.cotypingBackend = .thinkServer
        settings.summarizerBackend = .builtIn
        XCTAssertTrue(settings.cotypingLeavesThisMac)
    }

    func testFingerprintFollowsTheServerAndModelButNotTheKey() {
        var settings = AppSettings()
        settings.cotypingBackend = .server
        settings.cotypingServerBaseURL = tailnetURL
        settings.cotypingServerModel = "a"
        settings.approvedRemoteAutocompleteOrigins = [tailnetOrigin]
        let first = settings.cotypingRouteFingerprint
        settings.cotypingServerModel = "b"
        XCTAssertNotEqual(settings.cotypingRouteFingerprint, first)
        let second = settings.cotypingRouteFingerprint
        settings.cotypingServerRequestStyle = .chat
        XCTAssertNotEqual(settings.cotypingRouteFingerprint, second)
    }

    func testServerSettingsRoundTripAndOlderSettingsDecodeToTheDefaults() throws {
        var settings = AppSettings()
        settings.cotypingBackend = .thinkServer
        settings.cotypingServerBaseURL = tailnetURL
        settings.cotypingServerModel = "m"
        settings.cotypingThinkServerModel = "small"
        settings.cotypingServerRequestStyle = .chat
        settings.approvedRemoteAutocompleteOrigins = [tailnetOrigin]
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(decoded.cotypingBackend, .thinkServer)
        XCTAssertEqual(decoded.cotypingServerBaseURL, tailnetURL)
        XCTAssertEqual(decoded.cotypingServerModel, "m")
        XCTAssertEqual(decoded.cotypingThinkServerModel, "small")
        XCTAssertEqual(decoded.cotypingServerRequestStyle, .chat)
        XCTAssertEqual(decoded.approvedRemoteAutocompleteOrigins, [tailnetOrigin])

        let older = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"cotypingEnabled":true}"#.utf8))
        XCTAssertTrue(older.cotypingEnabled)
        XCTAssertEqual(older.cotypingBackend, .onDevice)
        XCTAssertEqual(older.cotypingServerRequestStyle, .automatic)
        XCTAssertTrue(older.approvedRemoteAutocompleteOrigins.isEmpty)

        let unknown = try JSONDecoder().decode(
            AppSettings.self, from: Data(#"{"cotypingBackend":"future","cotypingServerRequestStyle":"future"}"#.utf8))
        XCTAssertEqual(unknown.cotypingBackend, .onDevice)
        XCTAssertEqual(unknown.cotypingServerRequestStyle, .automatic)
    }

    func testSettingsSearchFindsTheServerSetting() {
        XCTAssertTrue(SettingDescriptor.all.contains { $0.id == "settings.cotypingBackend" && $0.category == .writing })
        var settings = AppSettings()
        let url = SettingDescriptor.all.first { $0.id == "settings.cotypingServerBaseURL" }
        XCTAssertEqual(url?.focusTarget(in: settings), "settings.cotypingBackend")
        settings.cotypingBackend = .server
        XCTAssertEqual(url?.focusTarget(in: settings), "settings.cotypingServerBaseURL")
    }

    // MARK: Helpers

    private func unavailableReason(_ settings: AppSettings, file: StaticString = #filePath, line: UInt = #line) -> String {
        guard case .unavailable(let reason) = settings.cotypingRoute(includingCredentials: false) else {
            XCTFail("expected an unavailable route", file: file, line: line)
            return ""
        }
        return reason
    }

    private func serverEndpoint(_ settings: AppSettings) -> CotypingServerEndpoint? {
        guard case .server(let endpoint) = settings.cotypingRoute(includingCredentials: false) else { return nil }
        return endpoint
    }
}

@MainActor
final class RemoteCotypingEngineTests: XCTestCase {
    func testAServerWithoutTextCompletionIsAskedThroughChatFromThenOn() async throws {
        var requests: [Bool] = []
        let engine = RemoteCotypingEngine(route: { .server(Self.endpoint(.automatic)) }) { _, chat in
            requests.append(chat)
            return chat ? ScriptedServer(.success("chat reply"))
                : ScriptedServer(.failure(TextEngineError.httpStatus(code: 404, detail: "Not Found", retryAfter: nil)))
        }
        let first = try await engine.generate(Self.request())
        XCTAssertEqual(first.text, "chat reply")
        XCTAssertEqual(requests, [false, true])
        _ = try await engine.generate(Self.request())
        XCTAssertEqual(requests, [false, true, true], "the raw route is not asked again")
    }

    func testAChosenRequestTypeIsNeverSwitched() async {
        var requests: [Bool] = []
        let engine = RemoteCotypingEngine(route: { .server(Self.endpoint(.textCompletion)) }) { _, chat in
            requests.append(chat)
            return ScriptedServer(.failure(TextEngineError.httpStatus(code: 404, detail: "Not Found", retryAfter: nil)))
        }
        do {
            _ = try await engine.generate(Self.request())
            XCTFail("expected the server's error")
        } catch {
            XCTAssertTrue(RemoteCotypingEngine.rejectsTextCompletion(error))
        }
        XCTAssertEqual(requests, [false])
    }

    func testOtherServerErrorsAreNotMistakenForAMissingRoute() {
        func status(_ code: Int, _ detail: String) -> Error {
            TextEngineError.httpStatus(code: code, detail: detail, retryAfter: nil)
        }
        XCTAssertTrue(RemoteCotypingEngine.rejectsTextCompletion(status(405, "")))
        XCTAssertTrue(RemoteCotypingEngine.rejectsTextCompletion(status(501, "")))
        XCTAssertTrue(RemoteCotypingEngine.rejectsTextCompletion(status(400, "This model only supports chat completions")))
        XCTAssertFalse(RemoteCotypingEngine.rejectsTextCompletion(status(400, "Model not found")))
        XCTAssertFalse(RemoteCotypingEngine.rejectsTextCompletion(status(401, "Invalid API key")))
        XCTAssertFalse(RemoteCotypingEngine.rejectsTextCompletion(status(500, "chat failed")))
        XCTAssertFalse(RemoteCotypingEngine.rejectsTextCompletion(
            TextEngineError.serverUnreachable("http://100.64.0.7:1234/v1", transportCode: NSURLErrorTimedOut)))
    }

    func testAnUnusableRouteSaysWhatToChange() async {
        let engine = RemoteCotypingEngine(route: { .unavailable("Approve it first.") }) { _, _ in
            XCTFail("nothing may be sent")
            return ScriptedServer(.success(""))
        }
        do {
            _ = try await engine.generate(Self.request())
            XCTFail("expected the route's reason")
        } catch {
            XCTAssertEqual((error as? LocalizedError)?.errorDescription, "Approve it first.")
        }
    }

    func testASlowServerIsAbandonedAtTheDeadline() async {
        let engine = RemoteCotypingEngine(route: { .server(Self.endpoint(.chat)) },
                                          deadline: .milliseconds(50)) { _, _ in
            ScriptedServer(.success("late"), delay: .seconds(30))
        }
        let started = Date()
        do {
            _ = try await engine.generate(Self.request())
            XCTFail("expected a timeout")
        } catch TextEngineError.serverUnreachable(_, let code) {
            XCTAssertEqual(code, NSURLErrorTimedOut)
        } catch {
            XCTFail("unexpected \(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
    }

    private static func endpoint(_ style: CotypingServerRequestStyle) -> CotypingServerEndpoint {
        let url = URL(string: "http://100.64.0.7:1234/v1")!
        return CotypingServerEndpoint(
            baseURL: url, model: "m", apiKey: nil, dialect: .generic, requestStyle: style,
            openRouterDataPolicy: .privateOnly, origin: "http://100.64.0.7:1234")
    }

    private static func request() -> CotypingRequest {
        let field = CotypingField(
            appName: "Mail", bundleID: "com.apple.mail", processID: 0, role: "AXTextArea",
            precedingText: "Thanks for sending this over. I wanted to follow",
            trailingText: "", selectionLength: 0, caretRect: .zero, isSecure: false,
            caretIsExact: true, windowTitle: "Re: Q3", fieldPlaceholder: nil)
        return CotypingRequestBuilder.build(
            field: field, config: .standard, personalization: .none, generation: 1, learnedExamples: [])!
    }
}

@MainActor
private final class ScriptedServer: CotypingCompleting {
    private let result: Result<String, Error>
    private let delay: Duration?

    init(_ result: Result<String, Error>, delay: Duration? = nil) {
        self.result = result
        self.delay = delay
    }

    func generate(_ request: CotypingRequest) async throws -> CotypingNormalizationResult {
        if let delay { try await Task.sleep(for: delay) }
        return CotypingNormalizationResult(text: try result.get(), suppression: nil)
    }
}
