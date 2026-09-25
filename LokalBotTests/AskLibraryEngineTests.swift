import XCTest
@testable import LokalBot

private final class MockChatClient: LlamaChatClient {
    var healthyScript: [Bool]
    var completion: Result<String, Error>
    var onHealth: (() -> Void)?
    var onCompletion: (() throws -> Void)?
    private(set) var completedMessages: [[[String: String]]] = []

    init(
        healthyScript: [Bool] = [],
        completion: Result<String, Error> = .success("mock answer")
    ) {
        self.healthyScript = healthyScript
        self.completion = completion
    }

    func healthy() async -> Bool {
        onHealth?()
        return healthyScript.isEmpty ? true : healthyScript.removeFirst()
    }

    func complete(messages: [[String: String]]) async throws -> String {
        completedMessages.append(messages)
        try onCompletion?()
        return try completion.get()
    }
}

final class AskLibraryEngineTests: XCTestCase {
    private var root: URL!
    private var gate: AgentAccessGate!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("askengine-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        setenv("LOKALBOT_STORAGE_ROOT", root.path, 1)
        gate = AgentAccessGate(root: root)
        try gate.enable()

        try MeetingFixture.write([
            .init(
                id: UUID(uuidString: "AAAAAAAA-1111-4222-8333-444444444444")!,
                title: "Cache planning",
                startedAt: Date(timeIntervalSince1970: 1_780_000_000),
                summary: "We chose Redis for the caching layer.",
                transcriptLines: ["Redis wins because of pub sub."]),
        ], under: root)
    }

    override func tearDown() {
        unsetenv("LOKALBOT_STORAGE_ROOT")
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func makeEngine(
        client: MockChatClient,
        onPoll: @escaping () -> Void = {}
    ) -> AskLibraryEngine {
        var engine = AskLibraryEngine(gate: gate)
        engine.client = client
        engine.maxPollAttempts = 3
        engine.pollDelay = { onPoll() }
        return engine
    }

    func testAnswersWithSourcesWhenHealthy() async {
        let client = MockChatClient(healthyScript: [true])
        let result = await makeEngine(client: client)
            .ask("What did we decide about caching?")
        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.text.hasPrefix("mock answer"))
        XCTAssertTrue(result.text.contains("Sources:"))
        XCTAssertTrue(result.text.contains("Cache planning (2026-05-28, id aaaaaaaa)"))

        let messages = client.completedMessages.first ?? []
        XCTAssertEqual(messages.first?["role"], "system")
        XCTAssertTrue(messages.last?["content"]?.contains("caching") ?? false)
    }

    func testGateDisabledRefuses() async {
        gate.disable()
        let result = await makeEngine(client: MockChatClient()).ask("anything at all")
        XCTAssertTrue(result.text.hasPrefix("[access_disabled]"))
    }

    func testRevocationDuringHealthPreventsReadingTheLibrary() async {
        let client = MockChatClient()
        client.onHealth = { self.gate.disable() }
        var engine = makeEngine(client: client)
        var readLibrary = false
        engine.loadMeetings = { readLibrary = true; return [] }
        let result = await engine.ask("caching decision")
        XCTAssertTrue(result.text.hasPrefix("[access_disabled]"))
        XCTAssertFalse(readLibrary)
        XCTAssertTrue(client.completedMessages.isEmpty)
    }

    func testRevocationWhileWakingPreventsInference() async {
        let client = MockChatClient(healthyScript: [false, true])
        let engine = makeEngine(client: client) { self.gate.disable() }
        let result = await engine.ask("caching decision")
        XCTAssertTrue(result.text.hasPrefix("[access_disabled]"))
        XCTAssertTrue(client.completedMessages.isEmpty)
    }

    func testRevocationDuringInferenceWithholdsAnswerEvenAfterReenable() async {
        let client = MockChatClient(completion: .success("private answer"))
        client.onCompletion = {
            self.gate.disable()
            try self.gate.enable()
        }
        let result = await makeEngine(client: client).ask("caching decision")
        XCTAssertEqual(client.completedMessages.count, 1)
        XCTAssertTrue(result.text.hasPrefix("[access_disabled]"))
        XCTAssertFalse(result.text.contains("private answer"))
    }

    func testEmptyQuestionIsInvalidArguments() async {
        let result = await makeEngine(client: MockChatClient()).ask("   ")
        XCTAssertTrue(result.text.hasPrefix("[invalid_arguments]"))
    }

    func testWakesAppThenAnswers() async {
        let client = MockChatClient(healthyScript: [false, false, true])
        let result = await makeEngine(client: client).ask("caching decision")
        XCTAssertFalse(result.isError)
        XCTAssertTrue(gate.pendingWake)
    }

    func testWakeErrorBecomesEngineUnavailable() async {
        let client = MockChatClient(healthyScript: [false, false, false, false])
        let engine = makeEngine(client: client) {
            self.gate.writeWakeError(
                "Main LLM is an external server; pick a built-in model.")
        }
        let result = await engine.ask("caching decision")
        XCTAssertTrue(result.text.hasPrefix("[engine_unavailable]"))
        XCTAssertTrue(result.text.contains("external server"))
    }

    func testTimeoutWithUnconsumedWakeIsAppNotRunning() async {
        let client = MockChatClient(healthyScript: [false, false, false, false])
        let result = await makeEngine(client: client).ask("caching decision")
        XCTAssertTrue(result.text.hasPrefix("[app_not_running]"))
        XCTAssertTrue(result.text.contains("read tools still work"))
    }

    func testTimeoutAfterConsumedWakeIsModelLoadingTimeout() async {
        let client = MockChatClient(healthyScript: [false, false, false, false])
        let engine = makeEngine(client: client) {
            _ = self.gate.consumeWake()
        }
        let result = await engine.ask("caching decision")
        XCTAssertTrue(result.text.hasPrefix("[model_loading_timeout]"))
    }

    func testEmptyLibraryIsFriendlyNonError() async {
        var engine = makeEngine(client: MockChatClient(healthyScript: [true]))
        engine.loadMeetings = { [] }
        let result = await engine.ask("caching decision")
        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.text.contains("empty"))
    }

    func testNoRetrievalMatchesIsFriendlyNonError() async {
        let client = MockChatClient(healthyScript: [true])
        let result = await makeEngine(client: client)
            .ask("quantum blockchain synergy")
        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.text.contains("couldn't find"))
        XCTAssertTrue(client.completedMessages.isEmpty)
    }

    func testCompletionFailureIsAppNotRunning() async {
        let client = MockChatClient(
            healthyScript: [true],
            completion: .failure(URLError(.cannotConnectToHost)))
        let result = await makeEngine(client: client).ask("caching decision")
        XCTAssertTrue(result.text.hasPrefix("[app_not_running]"))
    }

    @MainActor
    func testClientBaseURLMatchesLlamaServerPort() {
        XCTAssertEqual(
            "\(URLSessionLlamaChatClient.mainServerBaseURL)/v1",
            "\(LlamaServer.shared.baseURL)")
    }

    func testLocalServerAuthenticationAddsBearerHeader() throws {
        var request = URLRequest(url: try XCTUnwrap(URL(string: "http://127.0.0.1:17872/health")))
        LocalLlamaServerAuthentication.apply(to: &request, token: "secret")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
    }
}
