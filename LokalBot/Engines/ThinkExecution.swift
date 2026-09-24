import Foundation

struct AgentLLMConnection: Equatable, Sendable {
    let endpoint: AgentLLMEndpoint
    let lease: InferenceLease?
}

enum ThinkExecutionError: LocalizedError, Sendable {
    case invalidConfiguration
    case agentConfiguration(String)

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            "Invalid LLM server URL in Settings → Models."
        case .agentConfiguration(let reason):
            reason
        }
    }
}

/// The complete execution boundary for LokalBot's Think role: backend
/// selection, local model preparation, endpoint privacy checks, runtime
/// leases, managed recovery, and Agent Mode endpoint resolution.
@MainActor
final class ThinkExecution {
    typealias BuiltInModelPreparer = (
        ModelCatalog.Entry,
        StorageManager
    ) async throws -> URL

    private let storage: StorageManager
    private let builtInModelPreparer: BuiltInModelPreparer

    init(
        storage: StorageManager,
        builtInModelPreparer: @escaping BuiltInModelPreparer = { entry, storage in
            try await ModelDownloadManager.shared.ensureAvailable(entry, storage: storage)
        }
    ) {
        self.storage = storage
        self.builtInModelPreparer = builtInModelPreparer
    }

    func makeTextEngine(
        _ settings: AppSettings,
        includingCredentials: Bool = true,
        server: LlamaServer = .shared,
        priority: InferencePriority = .background,
        purpose: String = "summary",
        broker: InferenceBroker = .shared
    ) async throws -> TextEngine {
        switch settings.summarizerBackend {
        case .builtIn:
            let entry = try builtInEntry(settings)
            let modelURL = try await prepareBuiltInModel(settings)
            let authenticationToken = includingCredentials ? await server.authenticationToken() : nil
            let engine = OpenAICompatibleEngine(
                baseURL: server.baseURL,
                model: entry.id,
                apiKey: authenticationToken,
                extraBody: MainLLMRuntimePolicy.requestOverrides(for: entry.id),
                chatDialect: .llamaServer,
                defaultThinkingBudgetTokens:
                    MainLLMRuntimePolicy.highReasoningBudgetTokens,
                displayNameOverride: "Built-in — \(entry.displayName)")
            guard let role = InferenceRole(serverPort: server.port) else {
                try await server.ensureRunning(modelAt: modelURL)
                return engine
            }
            return LeasedTextEngine(
                base: engine,
                broker: broker,
                role: role,
                modelURL: modelURL,
                priority: priority,
                purpose: purpose)

        case .appleIntelligence:
            if case .unavailable(let reason) = FoundationModelAvailability.current() {
                throw TextEngineError.unavailable(reason)
            }
            return AppleIntelligenceEngine()

        case .ollama:
            guard let url = URL(string: settings.ollamaBaseURL) else {
                throw ThinkExecutionError.invalidConfiguration
            }
            try InferenceEndpointPolicy.validate(
                url,
                approvedOrigins: settings.approvedRemoteInferenceOrigins)
            var model = settings.ollamaModel
            if model.isEmpty {
                model = await OllamaEngine.listModels(baseURL: url).first ?? ""
            }
            return OllamaEngine(baseURL: url, model: model)

        case .openAICompatible:
            guard let url = URL(string: settings.openAIBaseURL) else {
                throw ThinkExecutionError.invalidConfiguration
            }
            try InferenceEndpointPolicy.validate(
                url,
                approvedOrigins: settings.approvedRemoteInferenceOrigins)
            return OpenAICompatibleEngine(
                baseURL: url,
                model: settings.openAIModel,
                apiKey: includingCredentials ? settings.openAIAPIKey : nil,
                chatDialect: .inferred(from: url),
                openRouterDataPolicy: settings.openRouterDataPolicy)
        }
    }

    /// Ensure the selected built-in model is present before the first request.
    /// The shared download manager coalesces callers and validates pinned model
    /// digests before returning the local URL.
    @discardableResult
    func prepareBuiltInModel(_ settings: AppSettings) async throws -> URL {
        try await builtInModelPreparer(try builtInEntry(settings), storage)
    }

    /// A built-in request already gets one managed server relaunch and replay
    /// inside `LeasedTextEngine`; never stack the provider retry on top of it.
    func retryDelay(
        for error: Error,
        settings: AppSettings,
        attempt: Int,
        jitter: TimeInterval = Double.random(in: 0...0.5)
    ) -> TimeInterval? {
        if settings.summarizerBackend == .builtIn,
           let engineError = error as? TextEngineError,
           case .serverUnreachable = engineError {
            return nil
        }
        return TextEngineRetryPolicy.delay(
            for: error,
            attempt: attempt,
            jitter: jitter)
    }

    /// Resolve and, for the built-in backend, lease the endpoint used for one
    /// Agent Mode session. Remote endpoints pass through the same approval and
    /// encrypted-transport policy as the rest of the Think role.
    func prepareAgentConnection(
        settings: AppSettings,
        includingCredentials: Bool = true,
        broker: InferenceBroker = .shared,
        server: LlamaServer = .shared
    ) async throws -> AgentLLMConnection {
        switch Self.agentResolution(settings: settings, includingCredentials: includingCredentials) {
        case .ready(let endpoint):
            return AgentLLMConnection(endpoint: endpoint, lease: nil)

        case .builtIn(let modelID):
            guard let entry = ModelCatalog.entry(
                id: modelID,
                custom: settings.customBuiltInModels) ?? ModelCatalog.entry(id: modelID),
                let modelURL = await ModelDownloadManager.shared.verifiedExistingURL(
                    entry,
                    storage: storage) else {
                throw ThinkExecutionError.agentConfiguration(
                    "The built-in model isn't downloaded yet. Download it under Settings → Models.")
            }
            let lease = try await broker.lease(
                .mainLLM,
                model: modelURL,
                priority: .interactive,
                purpose: "agent session")
            let authenticationToken = includingCredentials ? await server.authenticationToken() : nil
            let endpoint = AgentLLMEndpoint(
                baseURL: server.baseURL,
                model: entry.id,
                contextTokens: AgentLLMEndpoint.defaultContextTokens,
                apiKey: authenticationToken)
            return AgentLLMConnection(endpoint: endpoint, lease: lease)

        case .unsupported(let reason):
            throw ThinkExecutionError.agentConfiguration(reason)
        }
    }

    /// Pure settings-to-endpoint resolution shared by Agent Mode and the
    /// external agent-access wake path. Runtime acquisition remains explicit.
    nonisolated static func agentResolution(
        settings: AppSettings,
        includingCredentials: Bool = true
    ) -> AgentLLMResolution {
        switch settings.summarizerBackend {
        case .builtIn:
            guard let entry = ModelCatalog.entry(
                id: settings.builtInModelID,
                custom: settings.customBuiltInModels)
                    ?? ModelCatalog.entry(id: ModelCatalog.recommendedSummarizationID) else {
                return .unsupported(
                    reason: "No built-in model is configured. Pick one under Settings → Models.")
            }
            return .builtIn(modelID: entry.id)

        case .appleIntelligence:
            return .unsupported(
                reason: "Apple Intelligence doesn't expose a local endpoint Agent Mode can use. Switch the Think model to Built-in (on-device), Ollama, or an OpenAI-compatible server under Settings → Models.")

        case .ollama:
            guard let base = URL(string: settings.ollamaBaseURL) else {
                return .unsupported(
                    reason: "The Ollama server URL under Settings → Models isn't a valid URL.")
            }
            guard InferenceEndpointPolicy.isAllowed(
                base,
                approvedOrigins: settings.approvedRemoteInferenceOrigins) else {
                return .unsupported(
                    reason: "Approve this remote Ollama server under Settings → Models before Agent Mode sends context to it.")
            }
            guard InferenceEndpointPolicy.isLoopback(base)
                    || base.scheme?.lowercased() == "https" else {
                return .unsupported(
                    reason: "Remote Ollama servers must use HTTPS so meeting context is encrypted in transit.")
            }
            guard !settings.ollamaModel.isEmpty else {
                return .unsupported(
                    reason: "Pick an Ollama model under Settings → Models — Agent Mode needs an explicit model.")
            }
            return .ready(AgentLLMEndpoint(
                baseURL: base.appendingPathComponent("v1"),
                model: settings.ollamaModel,
                contextTokens: AgentLLMEndpoint.defaultContextTokens,
                apiKey: nil))

        case .openAICompatible:
            guard let base = URL(string: settings.openAIBaseURL) else {
                return .unsupported(
                    reason: "The server URL under Settings → Models isn't a valid URL.")
            }
            guard InferenceEndpointPolicy.isAllowed(
                base,
                approvedOrigins: settings.approvedRemoteInferenceOrigins) else {
                return .unsupported(
                    reason: "Approve this remote inference server under Settings → Models before Agent Mode sends context to it.")
            }
            guard InferenceEndpointPolicy.isLoopback(base)
                    || base.scheme?.lowercased() == "https" else {
                return .unsupported(
                    reason: "Remote inference servers must use HTTPS; LokalBot will not send meeting context or API keys over HTTP.")
            }
            guard !settings.openAIModel.isEmpty else {
                return .unsupported(
                    reason: "Set a model name for the OpenAI-compatible server under Settings → Models.")
            }
            // Presentation can validate the same destination without reading
            // Keychain on every view update. Launch resolution keeps credentials.
            let key = includingCredentials ? settings.openAIAPIKey : ""
            return .ready(AgentLLMEndpoint(
                baseURL: base,
                model: settings.openAIModel,
                contextTokens: AgentLLMEndpoint.defaultContextTokens,
                apiKey: key.isEmpty ? nil : key))
        }
    }

    private func builtInEntry(_ settings: AppSettings) throws -> ModelCatalog.Entry {
        guard let entry = ModelCatalog.entry(
            id: settings.builtInModelID,
            custom: settings.customBuiltInModels)
                ?? ModelCatalog.entry(id: ModelCatalog.recommendedSummarizationID) else {
            throw ThinkExecutionError.invalidConfiguration
        }
        return entry
    }
}
