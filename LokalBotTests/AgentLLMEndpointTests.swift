import XCTest
@testable import LokalBot

final class AgentLLMEndpointTests: XCTestCase {

    private func settings(_ backend: AppSettings.SummarizerBackend) -> AppSettings {
        var s = AppSettings()
        s.summarizerBackend = backend
        return s
    }

    func testMainLLMUsesHighReasoningAnd32KContextPolicy() {
        XCTAssertEqual(MainLLMRuntimePolicy.contextTokens, 32_768)
        XCTAssertEqual(MainLLMRuntimePolicy.highReasoningBudgetTokens, 8_192)
        XCTAssertEqual(AgentLLMEndpoint.defaultContextTokens, 32_768)
        XCTAssertEqual(
            Array(MainLLMRuntimePolicy.serverExtraArguments.suffix(2)),
            ["--reasoning", "on"])
    }

    func testBuiltInResolvesToModelID() {
        let resolution = ThinkExecution.agentResolution(settings: settings(.builtIn))
        guard case .builtIn(let modelID) = resolution else {
            return XCTFail("expected .builtIn, got \(resolution)")
        }
        XCTAssertFalse(modelID.isEmpty)
    }

    func testAppleIntelligenceIsUnsupportedWithGuidance() {
        let resolution = ThinkExecution.agentResolution(settings: settings(.appleIntelligence))
        guard case .unsupported(let reason) = resolution else {
            return XCTFail("expected unsupported resolution, got \(resolution)")
        }
        XCTAssertTrue(reason.contains("Apple Intelligence"))
        XCTAssertTrue(reason.contains("Built-in"))
    }

    func testOllamaRequiresExplicitModel() {
        var s = settings(.ollama)
        s.ollamaModel = ""
        guard case .unsupported(let reason) = ThinkExecution.agentResolution(settings: s) else {
            return XCTFail("expected unsupported resolution for missing Ollama model")
        }
        XCTAssertTrue(reason.contains("Ollama"))
    }

    func testOllamaAppendsV1() {
        var s = settings(.ollama)
        s.ollamaModel = "qwen3:8b"
        guard case .ready(let endpoint) = ThinkExecution.agentResolution(settings: s) else {
            return XCTFail("expected ready Ollama endpoint")
        }
        XCTAssertEqual(endpoint.baseURL.absoluteString, "http://localhost:11434/v1")
        XCTAssertEqual(endpoint.model, "qwen3:8b")
        XCTAssertNil(endpoint.apiKey)
        XCTAssertEqual(endpoint.contextTokens, AgentLLMEndpoint.defaultContextTokens)
    }

    func testOpenAICompatibleUsesBaseURLVerbatim() {
        var s = settings(.openAICompatible)
        s.openAIBaseURL = "http://localhost:1234/v1"
        s.openAIModel = "my-model"
        guard case .ready(let endpoint) = ThinkExecution.agentResolution(settings: s, includingCredentials: false) else {
            return XCTFail("expected ready OpenAI-compatible endpoint")
        }
        XCTAssertEqual(endpoint.baseURL.absoluteString, "http://localhost:1234/v1")
        XCTAssertEqual(endpoint.model, "my-model")
    }

    func testOpenAICompatibleRequiresModel() {
        var s = settings(.openAICompatible)
        s.openAIModel = ""
        guard case .unsupported = ThinkExecution.agentResolution(settings: s) else {
            return XCTFail("expected unsupported resolution for missing OpenAI-compatible model")
        }
    }

    func testRemoteOllamaRequiresExplicitApproval() {
        var s = settings(.ollama)
        s.ollamaBaseURL = "https://ollama.example.com"
        s.ollamaModel = "qwen3:8b"

        guard case .unsupported(let reason) = ThinkExecution.agentResolution(settings: s) else {
            return XCTFail("expected remote Ollama to require approval")
        }
        XCTAssertTrue(reason.contains("Approve"))
    }

    func testApprovedRemoteOpenAICompatibleEndpointResolves() {
        var s = settings(.openAICompatible)
        s.openAIBaseURL = "https://inference.example.com/v1"
        s.openAIModel = "private-model"
        s.approvedRemoteInferenceOrigins = ["https://inference.example.com"]

        guard case .ready(let endpoint) = ThinkExecution.agentResolution(settings: s, includingCredentials: false) else {
            return XCTFail("expected approved remote endpoint")
        }
        XCTAssertEqual(endpoint.baseURL.absoluteString, "https://inference.example.com/v1")
    }
}
