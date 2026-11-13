import XCTest
@testable import LokalBot

final class ServerContextWindowCatalogTests: XCTestCase {
    private actor Server {
        var replies: [String: (Int, Data)]
        var requests: [URLRequest] = []

        init(_ replies: [String: (Int, Data)]) { self.replies = replies }
        func answer(_ request: URLRequest) throws -> (Data, URLResponse) {
            requests.append(request)
            guard let url = request.url, let (status, data) = replies[url.absoluteString] else {
                throw URLError(.cannotConnectToHost)
            }
            return (data, HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
        func recorded() -> [URLRequest] { requests }
        func stop() { replies = [:] }
    }

    private final class Clock: @unchecked Sendable {
        var now = Date(timeIntervalSince1970: 1_790_000_000)
    }

    private final class KeyReads: @unchecked Sendable {
        var count = 0
    }

    private func json(_ object: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }

    private func defaults() -> UserDefaults {
        let name = "ServerContextWindowCatalogTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    private func catalog(_ server: Server, defaults: UserDefaults? = nil, clock: Clock = Clock()) -> ServerContextWindowCatalog {
        ServerContextWindowCatalog(fetch: { try await server.answer($0) }, defaults: defaults ?? self.defaults(),
                                   now: { clock.now })
    }

    func testModelListsNameTheWindowInEachServersOwnField() {
        let list = json(["object": "list", "data": [
            ["id": "llama-3.3-70b", "max_model_len": 32_768],                       // vLLM
            ["id": "openai/gpt-oss-120b", "context_window": 131_072],               // Groq
            ["id": "Qwen/Qwen3.8-27B", "context_length": 262_144],                  // Together, DeepInfra
            ["id": "mistral-medium-latest", "max_context_length": 128_000],         // Mistral
            ["id": "two-fields", "context_length": 200_000, "max_model_len": 100_000],
            ["id": "qwen-3.8-27b", "owned_by": "Cerebras"],                         // Cerebras, OpenAI: none
        ]])
        XCTAssertEqual(ServerContextWindowCatalog.windows(inModelList: list), [
            "llama-3.3-70b": 32_768, "openai/gpt-oss-120b": 131_072, "qwen/qwen3.8-27b": 262_144,
            "mistral-medium-latest": 128_000, "two-fields": 100_000,
        ])
        XCTAssertEqual(ServerContextWindowCatalog.window(inModelList: json([["id": "bare", "context_length": 8_192]]),
                                                         model: "BARE"), 8_192)
        XCTAssertNil(ServerContextWindowCatalog.window(inModelList: json(["data": [["id": "flag", "context_length": true]]]),
                                                       model: "flag"))
    }

    func testAnApprovedServerIsAskedWithTheInferenceKey() async throws {
        let base = URL(string: "https://api.groq.com/openai/v1")!
        let server = Server(["https://api.groq.com/openai/v1/models":
            (200, json(["data": [["id": "openai/gpt-oss-120b", "context_window": 131_072]]]))])
        let tokens = await catalog(server).contextTokens(model: "openai/gpt-oss-120b", baseURL: base,
            approvedOrigins: ["https://api.groq.com"], apiKey: { "test-key" })
        XCTAssertEqual(tokens, 131_072)
        let requests = await server.recorded()
        XCTAssertEqual(requests.count, 1, "a remote server is never asked for local-server endpoints")
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertNil(request.httpBody)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
    }

    func testUnapprovedAndOpenRouterServersAreNotAskedAndTheKeyIsNotRead() async {
        let server = Server([:])
        let reads = KeyReads()
        let key: @Sendable () -> String? = { reads.count += 1; return "test-key" }
        let lookups = catalog(server)
        let unapproved = await lookups.contextTokens(model: "m", baseURL: URL(string: "https://api.example.com/v1")!,
                                                     approvedOrigins: [], apiKey: key)
        let insecure = await lookups.contextTokens(model: "m", baseURL: URL(string: "http://api.example.com/v1")!,
                                                   approvedOrigins: ["http://api.example.com"], apiKey: key)
        let openRouter = await lookups.contextTokens(model: "z-ai/glm-5.3-flash",
                                                     baseURL: URL(string: "https://openrouter.ai/api/v1")!,
                                                     approvedOrigins: ["https://openrouter.ai"], apiKey: key)
        XCTAssertNil(unapproved)
        XCTAssertNil(insecure)
        XCTAssertNil(openRouter, "OpenRouter has its own lookup, without a key")
        let requests = await server.recorded()
        XCTAssertTrue(requests.isEmpty)
        XCTAssertEqual(reads.count, 0)
    }

    func testServersOnThisMacReportTheWindowTheyRunWith() async throws {
        let llama = Server([
            "http://localhost:8080/v1/models": (200, json(["data": [["id": "qwen", "meta": ["n_ctx_train": 262_144]]]])),
            "http://localhost:8080/props": (200, json(["default_generation_settings": ["n_ctx": 8_192]])),
        ])
        let llamaWindow = await catalog(llama).contextTokens(model: "qwen", baseURL: URL(string: "http://localhost:8080/v1")!,
                                                             approvedOrigins: [], apiKey: { nil })
        XCTAssertEqual(llamaWindow, 8_192, "the window it runs with, not the trained one")

        let lmStudio = Server([
            "http://127.0.0.1:1234/v1/models": (200, json(["data": [["id": "qwen/qwen3.5-4b", "object": "model"]]])),
            "http://127.0.0.1:1234/props": (404, Data()),
            "http://127.0.0.1:1234/api/v0/models/qwen/qwen3.5-4b":
                (200, json(["id": "qwen/qwen3.5-4b", "state": "loaded", "loaded_context_length": 4_096,
                            "max_context_length": 262_144])),
        ])
        let lmStudioWindow = await catalog(lmStudio).contextTokens(model: "qwen/qwen3.5-4b",
            baseURL: URL(string: "http://127.0.0.1:1234/v1")!, approvedOrigins: [], apiKey: { nil })
        XCTAssertEqual(lmStudioWindow, 4_096, "a smaller loaded window wins over the model's maximum")
        let requests = await lmStudio.recorded()
        XCTAssertNil(requests.first?.value(forHTTPHeaderField: "Authorization"), "no key, no header")
    }

    func testTheLastWindowSurvivesAServerThatStopsAnswering() async {
        let base = URL(string: "https://api.together.xyz/v1")!
        let origins = ["https://api.together.xyz"]
        let server = Server(["https://api.together.xyz/v1/models": (200, json([["id": "m", "context_length": 32_768]]))])
        let stored = defaults()
        let clock = Clock()
        let lookups = catalog(server, defaults: stored, clock: clock)
        let first = await lookups.contextTokens(model: "m", baseURL: base, approvedOrigins: origins, apiKey: { "k" })
        XCTAssertEqual(first, 32_768)
        await server.stop()
        clock.now += ServerContextWindowCatalog.refreshInterval + 1
        let refreshed = await lookups.contextTokens(model: "m", baseURL: base, approvedOrigins: origins, apiKey: { "k" })
        XCTAssertEqual(refreshed, 32_768)
        let soon = await lookups.contextTokens(model: "m", baseURL: base, approvedOrigins: origins, apiKey: { "k" })
        XCTAssertEqual(soon, 32_768)
        let requests = await server.recorded()
        XCTAssertEqual(requests.count, 2, "a failed server is not asked again for ten minutes")
        let relaunched = await catalog(Server([:]), defaults: stored, clock: clock)
            .contextTokens(model: "m", baseURL: base, approvedOrigins: origins, apiKey: { "k" })
        XCTAssertEqual(relaunched, 32_768)
    }

    /// The reported window beats the documented one, and a provider that
    /// reports nothing keeps its documented window.
    func testReportedWindowsComeBeforeDocumentedOnes() async {
        var config = AppSettings()
        config.summarizerBackend = .openAICompatible
        config.openAIBaseURL = "https://api.cerebras.ai/v1"
        config.openAIModel = "qwen-3.8-27b"
        config.approvedRemoteInferenceOrigins = ["https://api.cerebras.ai"]
        let openRouter = OpenRouterModelCatalog(fetch: { _ in throw URLError(.notConnectedToInternet) }, defaults: defaults())
        let silent = Server(["https://api.cerebras.ai/v1/models": (200, json(["data": [["id": "qwen-3.8-27b"]]]))])
        let documented = await MeetingSummaryGenerator.contextTokenLimit(
            for: config, catalog: openRouter, servers: catalog(silent), apiKey: { "k" })
        XCTAssertEqual(documented, 64_000)
        let reporting = Server(["https://api.cerebras.ai/v1/models":
            (200, json(["data": [["id": "qwen-3.8-27b", "context_length": 131_072]]]))])
        let reported = await MeetingSummaryGenerator.contextTokenLimit(
            for: config, catalog: openRouter, servers: catalog(reporting), apiKey: { "k" })
        XCTAssertEqual(reported, 131_072)
    }

    func testAnthropicReportsTheSelectedModelsInputWindow() async {
        let server = Server(["https://api.anthropic.com/v1/models/claude-sonnet-5-5": (200, json([
            "type": "model", "id": "claude-sonnet-5-5", "max_input_tokens": 1_000_000, "max_tokens": 128_000,
        ]))])
        let tokens = await catalog(server).contextTokens(
            model: "claude-sonnet-5-5", baseURL: URL(string: "https://api.anthropic.com")!,
            approvedOrigins: ["https://api.anthropic.com"], apiKey: { "sk-ant-test" })
        XCTAssertEqual(tokens, 1_000_000)
        let request = await server.recorded().first
        XCTAssertEqual(request?.value(forHTTPHeaderField: "x-api-key"), "sk-ant-test")
        XCTAssertEqual(request?.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        XCTAssertNil(request?.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(ServerContextWindowCatalog.anthropicModelURL(
            baseURL: URL(string: "https://api.anthropic.com")!, model: "../organizations"))
    }
}
