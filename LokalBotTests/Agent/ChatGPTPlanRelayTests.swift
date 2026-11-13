import XCTest
@testable import LokalBot

/// The relay Agent Mode's pi talks to for the ChatGPT plan, over real
/// loopback HTTP with a fake OpenAI upstream and token source.
final class ChatGPTPlanRelayTests: XCTestCase {
    /// Records upstream requests and answers them from a queue.
    private final class FakeOpenAI: @unchecked Sendable {
        struct Reply {
            var status = 200
            var headers = ["Content-Type": "text/event-stream"]
            var chunks: [String] = []
            /// Keeps the body open after the chunks, like a model still thinking.
            var staysOpen = false
        }

        private let lock = NSLock()
        private var replies: [Reply]
        private(set) var requests: [URLRequest] = []
        private(set) var tokenRequests: [String?] = []
        private(set) var endings = 0
        let ended = XCTestExpectation(description: "upstream body ended")

        init(_ replies: [Reply]) {
            self.replies = replies
            ended.assertForOverFulfill = false
        }

        var tokens: ChatGPTPlanRelay.TokenSource {
            { rejected in
                self.lock.withLock {
                    self.tokenRequests.append(rejected)
                    return rejected == nil ? "plan-token-1" : "plan-token-2"
                }
            }
        }

        var upstream: ChatGPTPlanRelay.Upstream {
            { request in
                let reply = self.lock.withLock {
                    self.requests.append(request)
                    return self.replies.removeFirst()
                }
                let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1",
                                               headerFields: reply.headers)!
                let body = AsyncThrowingStream<Data, Error> { continuation in
                    for chunk in reply.chunks { continuation.yield(Data(chunk.utf8)) }
                    if !reply.staysOpen { continuation.finish() }
                    continuation.onTermination = { _ in
                        self.lock.withLock { self.endings += 1 }
                        self.ended.fulfill()
                    }
                }
                return (response, body)
            }
        }
    }

    private var relays: [ChatGPTPlanRelay] = []

    override func tearDown() {
        relays.forEach { $0.stop() }
        relays = []
        super.tearDown()
    }

    private func start(_ openAI: FakeOpenAI) async throws -> ChatGPTPlanRelay {
        let relay = try await ChatGPTPlanRelay.start(tokens: openAI.tokens, upstream: openAI.upstream)
        relays.append(relay)
        return relay
    }

    private func request(_ relay: ChatGPTPlanRelay, key: String? = nil, path: String = "/v1/responses",
                         body: [String: Any] = piBody) throws -> URLRequest {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(relay.port)\(path)")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key ?? relay.key)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    private static let piBody: [String: Any] = [
        "model": "gpt-6.1-sol",
        "input": [
            ["role": "system", "content": "Synthetic instructions."],
            ["role": "user", "content": [["type": "input_text", "text": "synthetic-private-context"]]],
        ],
        "stream": false,
        "store": true,
        "prompt_cache_key": "session-1",
        "prompt_cache_retention": "24h",
        "max_output_tokens": 4_096,
        "temperature": 0.2,
        "tools": [["type": "function", "name": "read", "parameters": ["type": "object"]]],
        "reasoning": ["effort": "medium", "summary": "auto"],
        "include": ["reasoning.encrypted_content"],
    ]

    private static func json(_ data: Data?) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(data)) as? [String: Any])
    }

    // MARK: Request reading

    private func head(_ lines: [String], body: String = "") -> Data {
        Data((lines.joined(separator: "\r\n") + "\r\n\r\n" + body).utf8)
    }

    func testTheKeyIsCheckedBeforeTheBodyIsBuffered() {
        let partial = head(["POST /v1/responses HTTP/1.1", "Authorization: Bearer wrong", "Content-Length: 900"])
        guard case .rejected(401, _) = ChatGPTPlanRelayRequest.read(partial, key: "right") else {
            return XCTFail("a wrong key must be refused as soon as the head arrives")
        }
        let good = ["POST /v1/responses HTTP/1.1", "Authorization: Bearer right", "Content-Length: 4"]
        XCTAssertEqual(ChatGPTPlanRelayRequest.read(head(good, body: "{}"), key: "right"), .incomplete)
        XCTAssertEqual(ChatGPTPlanRelayRequest.read(head(good, body: "{ }\n"), key: "right"),
                       .complete(body: Data("{ }\n".utf8)))
        XCTAssertEqual(ChatGPTPlanRelayRequest.read(Data("POST /v1/resp".utf8), key: "right"), .incomplete)
    }

    func testOnlyPiShapedRequestsAreRelayed() {
        func status(_ lines: [String]) -> Int? {
            guard case .rejected(let status, _) = ChatGPTPlanRelayRequest.read(head(lines), key: "k") else { return nil }
            return status
        }
        let auth = "Authorization: Bearer k"
        XCTAssertEqual(status(["GET /v1/responses HTTP/1.1", auth, "Content-Length: 0"]), 404)
        XCTAssertEqual(status(["POST /v1/chat/completions HTTP/1.1", auth, "Content-Length: 0"]), 404)
        XCTAssertEqual(status(["POST /v1/responses HTTP/1.1", auth, "Origin: https://example.com",
                               "Content-Length: 0"]), 403)
        XCTAssertEqual(status(["POST /v1/responses HTTP/1.1", "Content-Length: 0"]), 401)
        XCTAssertEqual(status(["POST /v1/responses HTTP/1.1", auth, auth, "Content-Length: 0"]), 400)
        XCTAssertEqual(status(["POST /v1/responses HTTP/1.1", auth, "Transfer-Encoding: chunked"]), 411)
        XCTAssertEqual(status(["POST /v1/responses HTTP/1.1", auth,
                               "Content-Length: \(ChatGPTPlanRelay.maximumRequestBytes + 1)"]), 413)
        XCTAssertNil(status(["POST /v1/responses?x=1 HTTP/1.1", auth, "Content-Length: 0"]))
    }

    // MARK: Plan rules

    func testBodyFollowsThePlanRoutesRules() throws {
        let body = try Self.json(ChatGPTPlanRelayPolicy.upstreamBody(JSONSerialization.data(withJSONObject: Self.piBody)))
        XCTAssertEqual(body["store"] as? Bool, false)
        XCTAssertEqual(body["stream"] as? Bool, true)
        for field in ["max_output_tokens", "temperature", "prompt_cache_retention"] {
            XCTAssertNil(body[field], field)
        }
        let input = try XCTUnwrap(body["input"] as? [[String: Any]])
        XCTAssertEqual(input.first?["role"] as? String, "developer", "the route rejects system messages")
        XCTAssertEqual(input.last?["role"] as? String, "user")
        XCTAssertEqual(body["prompt_cache_key"] as? String, "session-1")
        XCTAssertEqual((body["tools"] as? [[String: Any]])?.first?["name"] as? String, "read")
        XCTAssertEqual(body["include"] as? [String], ["reasoning.encrypted_content"])
        XCTAssertThrowsError(try ChatGPTPlanRelayPolicy.upstreamBody(Data("[1]".utf8)))
    }

    func testPlanLimitsAreNotRetriedButOutagesAre() {
        XCTAssertEqual(ChatGPTPlanRelayPolicy.shouldRetry(
            code: "subscription_sharing_usage_limit_exceeded", message: nil, param: nil), false)
        XCTAssertEqual(ChatGPTPlanRelayPolicy.shouldRetry(
            code: "subscription_sharing_unsupported_capability", message: nil, param: "tools"), false)
        XCTAssertEqual(ChatGPTPlanRelayPolicy.shouldRetry(
            code: "subscription_sharing_usage_unavailable", message: nil, param: nil), true)
        XCTAssertNil(ChatGPTPlanRelayPolicy.shouldRetry(code: "rate_limit_exceeded", message: nil, param: nil))
    }

    // MARK: Relaying

    func testStreamsOpenAIsReplyWithThePlanTokenNotPisKey() async throws {
        let events = ["data: {\"type\":\"response.created\"}\n\n", "data: {\"type\":\"response.completed\"}\n\n"]
        let openAI = FakeOpenAI([.init(chunks: events)])
        let relay = try await start(openAI)
        let (data, response) = try await URLSession.shared.data(for: request(relay))
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), events.joined())
        let upstream = try XCTUnwrap(openAI.requests.first)
        XCTAssertEqual(upstream.url, ChatGPTPlanEngine.responsesURL)
        XCTAssertEqual(upstream.value(forHTTPHeaderField: "Authorization"), "Bearer plan-token-1")
        XCTAssertEqual(try Self.json(upstream.httpBody)["store"] as? Bool, false)
        XCTAssertEqual(openAI.tokenRequests, [nil])
    }

    func testARejectedTokenIsRefreshedOnce() async throws {
        let openAI = FakeOpenAI([
            .init(status: 401, headers: ["Content-Type": "application/json"], chunks: ["{}"]),
            .init(chunks: ["data: {}\n\n"]),
        ])
        let relay = try await start(openAI)
        let (_, response) = try await URLSession.shared.data(for: request(relay))
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(openAI.tokenRequests, [nil, "plan-token-1"])
        XCTAssertEqual(openAI.requests.map { $0.value(forHTTPHeaderField: "Authorization") },
                       ["Bearer plan-token-1", "Bearer plan-token-2"])
    }

    func testAWrongKeyNeverReachesOpenAI() async throws {
        let openAI = FakeOpenAI([])
        let relay = try await start(openAI)
        let (_, response) = try await URLSession.shared.data(for: request(relay, key: "not-the-key"))
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 401)
        XCTAssertTrue(openAI.requests.isEmpty)
        XCTAssertTrue(openAI.tokenRequests.isEmpty)
    }

    func testAUsageLimitTellsPiNotToRetry() async throws {
        let error = #"{"error":{"code":"subscription_sharing_usage_limit_exceeded","message":"limit"}}"#
        let openAI = FakeOpenAI([.init(status: 429, headers: ["Content-Type": "application/json", "Retry-After": "60"],
                                       chunks: [error])])
        let relay = try await start(openAI)
        let (data, response) = try await URLSession.shared.data(for: request(relay))
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 429)
        XCTAssertEqual(http.value(forHTTPHeaderField: "X-Should-Retry"), "false")
        XCTAssertEqual(http.value(forHTTPHeaderField: "Retry-After"), "60")
        XCTAssertEqual(String(decoding: data, as: UTF8.self), error, "pi links the usage page from the code")
    }

    func testASignedOutPlanAsksToSignIn() async throws {
        let relay = try await ChatGPTPlanRelay.start(
            tokens: { _ in throw ChatGPTPlanError.signedOut },
            upstream: { _ in XCTFail("no token, no request"); throw URLError(.cancelled) })
        relays.append(relay)
        let (data, response) = try await URLSession.shared.data(for: request(relay))
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 401)
        XCTAssertEqual(http.value(forHTTPHeaderField: "X-Should-Retry"), "false")
        let error = try XCTUnwrap(Self.json(data)["error"] as? [String: Any])
        XCTAssertEqual(error["message"] as? String, ChatGPTPlanError.signedOut.localizedDescription)
    }

    func testPiHangingUpStopsTheUpstreamRequest() async throws {
        let openAI = FakeOpenAI([.init(chunks: ["data: {\"type\":\"response.created\"}\n\n"], staysOpen: true)])
        let relay = try await start(openAI)
        let firstLine = XCTestExpectation(description: "first event relayed")
        firstLine.assertForOverFulfill = false
        let client = Task {
            let (bytes, _) = try await URLSession.shared.bytes(for: request(relay))
            for try await _ in bytes.lines {
                firstLine.fulfill()
            }
        }
        await fulfillment(of: [firstLine], timeout: 5)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(openAI.endings, 0, "the relay must keep a thinking model's stream open")
        client.cancel()
        await fulfillment(of: [openAI.ended], timeout: 5)
    }

    func testStoppingEndsOpenRequests() async throws {
        let openAI = FakeOpenAI([.init(chunks: [], staysOpen: true)])
        let relay = try await start(openAI)
        let client = Task { try await URLSession.shared.data(for: request(relay)) }
        while openAI.requests.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(openAI.endings, 0)
        relay.stop()
        await fulfillment(of: [openAI.ended], timeout: 5)
        _ = await client.result
    }

    // MARK: Agent Mode connection

    func testAgentModePointsPiAtARelayOnThisMac() async throws {
        var settings = AppSettings()
        settings.summarizerBackend = .chatGPTPlan
        settings.chatGPTPlanModel = "gpt-6.1-sol"
        settings.approvedRemoteInferenceOrigins = [SubscriptionPlan.chatGPT.consentKey]
        let connection = try await ThinkExecution(storage: StorageManager())
            .prepareAgentConnection(settings: settings, includingCredentials: false)
        let relay = try XCTUnwrap(connection.relay)
        relays.append(relay)
        let endpoint = connection.endpoint
        XCTAssertEqual(endpoint.baseURL, relay.baseURL)
        XCTAssertTrue(InferenceEndpointPolicy.isLoopback(endpoint.baseURL))
        XCTAssertEqual(endpoint.apiKey, relay.key)
        XCTAssertEqual(endpoint.model, "gpt-6.1-sol")
        XCTAssertEqual(endpoint.api, .responses)
        XCTAssertEqual(endpoint.plan, .chatGPT)
        XCTAssertEqual(endpoint.contextTokens, MeetingSummaryGenerator.contextTokenLimit(for: settings))
        XCTAssertNil(connection.lease)
        let context = await AgentSessionController.ModelContext(endpoint: endpoint, settings: settings)
        XCTAssertEqual(context.destination, .remote(host: SubscriptionPlan.chatGPT.title),
                       "a relay on this Mac still sends content to OpenAI")
    }

    func testAgentModeAsksForSignInBeforeStarting() async throws {
        var settings = AppSettings()
        settings.summarizerBackend = .chatGPTPlan
        settings.chatGPTPlanModel = "gpt-6.1-sol"
        settings.approvedRemoteInferenceOrigins = [SubscriptionPlan.chatGPT.consentKey]
        let account = ChatGPTPlanAccount(store: ChatGPTPlanTests.MemoryStore(),
                                         transport: { _ in throw URLError(.notConnectedToInternet) })
        do {
            _ = try await ThinkExecution(storage: StorageManager())
                .prepareAgentConnection(settings: settings, planAccount: account)
            XCTFail("a signed-out plan must not start a session")
        } catch ThinkExecutionError.agentConfiguration(let reason) {
            XCTAssertEqual(reason, ChatGPTPlanError.signedOut.localizedDescription)
        }
    }
}
