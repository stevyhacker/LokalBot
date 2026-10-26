import Foundation

/// Shared model context policy and cleanup of pre-unified checkpoints.
enum MeetingSummaryGenerator {
    static let builtInContextTokens = MainLLMRuntimePolicy.contextTokens
    static let conservativeExternalContextTokens = 16_384

    /// The smallest context window OpenRouter advertised across every endpoint
    /// of these models (`/api/v1/models/<id>/endpoints`; 1 October 2026, and
    /// 7 October for Qwen3.8 27B and GPT-5.6 Luna), used when the live lookup
    /// has never answered. Exact ids only: variants such as `:free` route to
    /// other endpoints. The window also sets the notes part size
    /// (`notesPartTokens`).
    static let verifiedOpenRouterContextTokens: [String: Int] = [
        "z-ai/glm-5.3": 262_144,
        "z-ai/glm-5.3-flash": 262_144,
        "qwen/qwen3.8-flash": 1_000_000,
        "qwen/qwen3.8-27b": 65_536,
        "openai/gpt-5.6-luna": 922_000,
    ]

    /// Cerebras's documented free-tier windows on 7 October 2026
    /// (inference-docs.cerebras.ai/models/overview); its models API lists ids
    /// only. Paid tiers allow about twice as much; the smaller window holds
    /// for every key.
    static let verifiedCerebrasContextTokens: [String: Int] = [
        "qwen-3.8-27b": 64_000,
        "gpt-oss-120b": 65_000,
    ]

    /// OpenAI's documented windows by model family, at the family's smallest
    /// variant (`gpt-5-chat` and `o1-mini` have 128K). Its models API reports
    /// none.
    static func openAIContextTokens(model: String) -> Int? {
        let name = model.lowercased()
        if name.hasPrefix("gpt-4.1") { return 1_000_000 }
        // Every GPT-6 model takes at most 922K input tokens of a 1.05M window.
        if name.hasPrefix("gpt-6") { return 922_000 }
        let families = ["gpt-5", "gpt-4o", "gpt-4-turbo", "o1", "o3", "o4"]
        return families.contains(where: name.hasPrefix) ? 128_000 : nil
    }

    /// The window a provider documents for the model, where its API does not
    /// report one. OpenRouter's published window comes first
    /// (`contextTokenLimit(for:catalog:)`).
    static func documentedContextTokens(provider: ReasoningSupport.Provider, model: String) -> Int? {
        switch provider {
        case .openRouter:
            verifiedOpenRouterContextTokens[model.lowercased()]
                // OpenRouter serves OpenAI's models with OpenAI's windows.
                ?? (model.lowercased().hasPrefix("openai/") ? openAIContextTokens(model: String(model.dropFirst(7))) : nil)
        case .cerebras: verifiedCerebrasContextTokens[model.lowercased()]
        case .openAI: openAIContextTokens(model: model)
        case .anthropic: AnthropicModelTraits(model: model).contextTokens
        case .builtIn, .ollama, .generic: nil
        }
    }

    /// Notes parts target 6,000 estimated tokens on the built-in model and on
    /// servers whose window is unknown: small windows, slow prefill, and
    /// frequent checkpoints. A model with a known larger window takes bigger
    /// parts, so a 20-minute meeting on Cerebras Qwen is two requests instead
    /// of four (its schema enum limit keeps it from one; see `makeChunks`). Fixed steps, not a fraction of the window, keep a window that
    /// drifts between OpenRouter lookups from re-planning a meeting and
    /// discarding its saved parts. Even at one token per UTF-8 byte a part
    /// stays well inside its step's window beside the output allowance.
    static let standardNotesPartTokens = 6_000

    static func notesPartTokens(contextTokens: Int) -> Int {
        switch contextTokens {
        case 128_000...: 24_000
        case 64_000...: 16_000
        default: standardNotesPartTokens
        }
    }

    static func contextTokenLimit(for backend: AppSettings.SummarizerBackend) -> Int {
        backend == .builtIn ? builtInContextTokens : conservativeExternalContextTokens
    }

    /// The selected provider's documented window for the model. Unknown
    /// servers and models retain 16K.
    static func contextTokenLimit(for config: AppSettings) -> Int {
        switch config.summarizerBackend {
        case .chatGPTPlan:
            // Every model offered on a ChatGPT plan has at least 128K.
            return openAIContextTokens(model: config.chatGPTPlanModel) ?? 128_000
        case .claudePlan:
            // Claude Code's default window on subscription plans.
            return 200_000
        case .builtIn, .appleIntelligence, .ollama, .openAICompatible:
            break
        }
        if config.summarizerBackend == .openAICompatible, let url = URL(string: config.openAIBaseURL),
           let documented = documentedContextTokens(
            provider: .init(dialect: .inferred(from: url), baseURL: url), model: config.openAIModel) {
            return documented
        }
        return contextTokenLimit(for: config.summarizerBackend)
    }

    /// The window the server reports for the selected model wins, including
    /// one smaller than 16K: OpenRouter's published endpoints, or another
    /// server's model list (`ServerContextWindowCatalog`). Otherwise the
    /// provider's documented window, then 16K.
    static func contextTokenLimit(for config: AppSettings, catalog: OpenRouterModelCatalog,
                                  servers: ServerContextWindowCatalog = .shared,
                                  apiKey: (@Sendable () -> String?)? = nil) async -> Int {
        if config.summarizerBackend == .openAICompatible, let url = URL(string: config.openAIBaseURL) {
            let origins = config.approvedRemoteInferenceOrigins
            if let published = await catalog.contextTokens(model: config.openAIModel, baseURL: url,
                                                           approvedOrigins: origins) {
                return published
            }
            if let reported = await servers.contextTokens(model: config.openAIModel, baseURL: url,
                                                          approvedOrigins: origins,
                                                          apiKey: apiKey ?? { config.openAIAPIKey }) {
                return reported
            }
        }
        return contextTokenLimit(for: config)
    }

    static func removeCheckpoint(in folder: URL) {
        try? FileManager.default.removeItem(at: folder.appendingPathComponent("summary.parts.partial.json"))
        MeetingNotesGenerator.removeCheckpoint(in: folder)
    }
}
