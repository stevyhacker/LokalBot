import Foundation

struct AgentLLMConnection: Equatable, Sendable {
    let endpoint: AgentLLMEndpoint
    let lease: InferenceLease?
    var relay: ChatGPTPlanRelay?
}

enum ThinkExecutionError: LocalizedError, Sendable {
    case invalidConfiguration
    case unknownBuiltInModel
    case agentConfiguration(String)

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            "Invalid LLM server URL in Settings → Models."
        case .unknownBuiltInModel:
            "The selected built-in model is no longer available. Pick a model under Settings → Models."
        case .agentConfiguration(let reason):
            reason
        }
    }
}

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
                reasoningLevel: settings.thinkReasoningLevel,
                reasoningSupport: .known(provider: .builtIn, model: entry.id),
                displayNameOverride: "Built-in — \(entry.displayName)")
            guard let role = server.role.flatMap(InferenceRole.init(serverRole:)) else {
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
            let support = settings.thinkReasoningLevel == .automatic || model.isEmpty ? nil
                : await OllamaEngine.reasoningSupport(baseURL: url, model: model)
            return GatedTextEngine(
                base: OllamaEngine(baseURL: url, model: model,
                                   reasoningLevel: settings.thinkReasoningLevel,
                                   reasoningSupport: support),
                origin: RemoteInferenceGate.origin(for: url),
                priority: priority,
                purpose: purpose)

        case .openAICompatible:
            guard let url = URL(string: settings.openAIBaseURL) else {
                throw ThinkExecutionError.invalidConfiguration
            }
            try InferenceEndpointPolicy.validate(
                url,
                approvedOrigins: settings.approvedRemoteInferenceOrigins)
            if AnthropicAPI.isAnthropic(url) {
                return GatedTextEngine(
                    base: AnthropicEngine(
                        baseURL: url,
                        model: settings.openAIModel,
                        apiKey: includingCredentials ? settings.openAIAPIKey : nil,
                        reasoningLevel: settings.thinkReasoningLevel),
                    origin: RemoteInferenceGate.origin(for: url),
                    priority: priority,
                    purpose: purpose)
            }
            let engine = OpenAICompatibleEngine(
                baseURL: url,
                model: settings.openAIModel,
                apiKey: includingCredentials ? settings.openAIAPIKey : nil,
                chatDialect: .inferred(from: url),
                openRouterDataPolicy: settings.openRouterDataPolicy,
                reasoningLevel: settings.thinkReasoningLevel,
                reasoningSupport: settings.thinkReasoningLevel == .automatic
                    ? nil : await ReasoningSupport.resolve(for: settings))
            return GatedTextEngine(
                base: engine,
                origin: RemoteInferenceGate.origin(for: url),
                priority: priority,
                purpose: purpose)

        case .chatGPTPlan, .claudePlan, .antigravityPlan, .geminiPlan:
            guard let plan = SubscriptionPlan(backend: settings.summarizerBackend) else {
                throw ThinkExecutionError.invalidConfiguration
            }
            guard plan.isApproved(in: settings) else { throw SubscriptionPlanError.approvalRequired(plan) }
            let base: TextEngine = switch plan {
            case .chatGPT:
                ChatGPTPlanEngine(model: settings.chatGPTPlanModel,
                                  reasoningLevel: settings.thinkReasoningLevel)
            case .claude:
                ClaudePlanEngine(model: settings.claudePlanModel,
                                 reasoningLevel: settings.thinkReasoningLevel)
            case .antigravity:
                AntigravityPlanEngine(model: settings.antigravityPlanModel,
                                      reasoningLevel: settings.thinkReasoningLevel)
            case .gemini:
                GeminiPlanEngine(model: settings.geminiPlanModel)
            }
            return GatedTextEngine(base: base, origin: plan.consentKey, priority: priority, purpose: purpose)
        }
    }

    @discardableResult
    func prepareBuiltInModel(_ settings: AppSettings) async throws -> URL {
        try await builtInModelPreparer(try builtInEntry(settings), storage)
    }

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

    func prepareAgentConnection(
        settings: AppSettings,
        includingCredentials: Bool = true,
        broker: InferenceBroker = .shared,
        server: LlamaServer = .shared,
        planAccount: ChatGPTPlanAccount = .shared
    ) async throws -> AgentLLMConnection {
        switch Self.agentResolution(settings: settings, includingCredentials: includingCredentials) {
        case .ready(let endpoint):
            return AgentLLMConnection(endpoint: endpoint, lease: nil)

        case .chatGPTPlan(let model):
            if includingCredentials {
                let status = await planAccount.status()
                guard status.isSignedIn else {
                    throw ThinkExecutionError.agentConfiguration(ChatGPTPlanError.signedOut.localizedDescription)
                }
                guard status.allowsPlanUsage else {
                    throw ThinkExecutionError.agentConfiguration(
                        ChatGPTPlanError.planUsageNotGranted.localizedDescription)
                }
            }
            let relay = try await ChatGPTPlanRelay.start(tokens: { rejected in
                if let rejected { return try await planAccount.accessTokenAfterRejection(of: rejected) }
                return try await planAccount.accessToken()
            })
            let endpoint = AgentLLMEndpoint(
                baseURL: relay.baseURL,
                model: model,
                contextTokens: MeetingSummaryGenerator.contextTokenLimit(for: settings),
                apiKey: relay.key,
                reasoningDialect: .openAI,
                api: .responses,
                plan: .chatGPT)
            return AgentLLMConnection(endpoint: endpoint, lease: nil, relay: relay)

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
                apiKey: authenticationToken,
                reasoningDialect: .llamaServer)
            return AgentLLMConnection(endpoint: endpoint, lease: lease)

        case .unsupported(let reason):
            throw ThinkExecutionError.agentConfiguration(reason)
        }
    }

    nonisolated static func agentResolution(
        settings: AppSettings,
        includingCredentials: Bool = true
    ) -> AgentLLMResolution {
        switch settings.summarizerBackend {
        case .builtIn:
            guard let entry = ModelCatalog.entry(
                id: settings.builtInModelID,
                custom: settings.customBuiltInModels) else {
                return .unsupported(
                    reason: ThinkExecutionError.unknownBuiltInModel.localizedDescription)
            }
            return .builtIn(modelID: entry.id)

        case .appleIntelligence:
            return .unsupported(
                reason: "Apple Intelligence doesn't expose a local endpoint Agent Mode can use. Switch the Think model to Built-in (on-device), Ollama, an OpenAI-compatible server, or your ChatGPT plan under Settings → Models.")

        case .chatGPTPlan:
            let plan = SubscriptionPlan.chatGPT
            guard plan.isApproved(in: settings) else {
                return .unsupported(reason: SubscriptionPlanError.approvalRequired(plan).localizedDescription)
            }
            let model = plan.model(in: settings)
            guard !model.isEmpty else {
                return .unsupported(reason: SubscriptionPlanError.noModel(plan).localizedDescription)
            }
            return .chatGPTPlan(model: model)

        case .claudePlan, .antigravityPlan, .geminiPlan:
            let title = SubscriptionPlan(backend: settings.summarizerBackend)?.title ?? settings.summarizerBackend.displayName
            return .unsupported(
                reason: "Agent Mode can't run on your \(title) yet. Switch the Think model to Built-in (on-device), Ollama, an OpenAI-compatible server, or your ChatGPT plan under Settings → Models.")

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
                apiKey: nil,
                reasoningDialect: .ollama))

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
            let key = includingCredentials ? settings.openAIAPIKey : ""
            return .ready(AgentLLMEndpoint(
                baseURL: AnthropicAPI.isAnthropic(base) ? AnthropicAPI.versionedRoot(base) : base,
                model: settings.openAIModel,
                contextTokens: AgentLLMEndpoint.defaultContextTokens,
                apiKey: key.isEmpty ? nil : key,
                reasoningDialect: AgentReasoningDialect(.inferred(from: base))))
        }
    }

    private func builtInEntry(_ settings: AppSettings) throws -> ModelCatalog.Entry {
        guard let entry = ModelCatalog.entry(
            id: settings.builtInModelID,
            custom: settings.customBuiltInModels) else {
            throw ThinkExecutionError.unknownBuiltInModel
        }
        return entry
    }
}
