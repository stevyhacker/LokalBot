import XCTest
@testable import LokalBot

@MainActor
final class ThinkExecutionTests: XCTestCase {
    func testBuiltInManagedRecoveryDoesNotStackProviderRetry() {
        let execution = ThinkExecution(storage: StorageManager())
        var settings = AppSettings()
        settings.summarizerBackend = .builtIn
        let error = TextEngineError.serverUnreachable(
            "http://127.0.0.1:17872",
            transportCode: -1_004)

        XCTAssertNil(execution.retryDelay(
            for: error,
            settings: settings,
            attempt: 0,
            jitter: 0))
    }

    func testRemoteThinkKeepsOneBoundedTransientRetry() {
        let execution = ThinkExecution(storage: StorageManager())
        var settings = AppSettings()
        settings.summarizerBackend = .openAICompatible
        let error = TextEngineError.httpStatus(
            code: 503,
            detail: "warming",
            retryAfter: nil)

        XCTAssertEqual(
            execution.retryDelay(
                for: error,
                settings: settings,
                attempt: 0,
                jitter: 0),
            1)
        XCTAssertNil(execution.retryDelay(
            for: error,
            settings: settings,
            attempt: 1,
            jitter: 0))
    }

    func testOpenRouterAccountPolicyFlowsIntoTextEngine() async throws {
        let execution = ThinkExecution(storage: StorageManager())
        var settings = AppSettings()
        settings.summarizerBackend = .openAICompatible
        settings.openAIBaseURL = "https://openrouter.ai/api/v1"
        settings.openAIModel = "deepseek/example-model"
        settings.approvedRemoteInferenceOrigins = ["https://openrouter.ai"]
        settings.openRouterDataPolicy = .accountPolicy

        let engine = try await execution.makeTextEngine(settings, includingCredentials: false)
        let openRouterEngine = try XCTUnwrap(engine as? OpenAICompatibleEngine)

        XCTAssertEqual(openRouterEngine.chatDialect, .openRouter)
        XCTAssertEqual(openRouterEngine.openRouterDataPolicy, .accountPolicy)
    }

    func testInjectedAgentConnectionOmitsCredentialsWithoutChangingEndpointPolicy() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("think-agent-fixture-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let execution = ThinkExecution(storage: StorageManager(rootURL: root))
        var settings = AppSettings()
        settings.summarizerBackend = .openAICompatible
        settings.openAIBaseURL = "https://fixture.example/v1"
        settings.openAIModel = "fixture-model"
        settings.approvedRemoteInferenceOrigins = ["https://fixture.example"]

        let connection = try await execution.prepareAgentConnection(settings: settings, includingCredentials: false)
        XCTAssertEqual(connection.endpoint.baseURL.absoluteString, settings.openAIBaseURL)
        XCTAssertEqual(connection.endpoint.model, settings.openAIModel)
        XCTAssertNil(connection.endpoint.apiKey)
        XCTAssertNil(connection.lease)

        settings.approvedRemoteInferenceOrigins = []
        do {
            _ = try await execution.prepareAgentConnection(settings: settings, includingCredentials: false)
            XCTFail("Omitting credentials must not bypass the remote-origin policy")
        } catch is ThinkExecutionError {
            // Expected: fixture transport isolation does not grant an origin.
        }
    }
}
