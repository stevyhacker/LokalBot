import Foundation

enum MeetingSummaryGenerator {
    static let builtInContextTokens = MainLLMRuntimePolicy.contextTokens
    static let conservativeExternalContextTokens = 16_384

    static let verifiedOpenRouterContextTokens: [String: Int] = [
        "z-ai/glm-5.3": 262_144,
        "z-ai/glm-5.3-flash": 262_144,
        "qwen/qwen3.8-flash": 1_000_000,
        "qwen/qwen3.8-27b": 65_536,
        "openai/gpt-5.6-luna": 922_000,
    ]

    static let verifiedCerebrasContextTokens: [String: Int] = [
        "qwen-3.8-27b": 64_000,
        "gpt-oss-120b": 65_000,
    ]

    static func openAIContextTokens(model: String) -> Int? {
        let name = model.lowercased()
        if name.hasPrefix("gpt-4.1") { return 1_000_000 }
        if name.hasPrefix("gpt-6") { return 922_000 }
        let families = ["gpt-5", "gpt-4o", "gpt-4-turbo", "o1", "o3", "o4"]
        return families.contains(where: name.hasPrefix) ? 128_000 : nil
    }

    static func documentedContextTokens(provider: ReasoningSupport.Provider, model: String) -> Int? {
        switch provider {
        case .openRouter:
            verifiedOpenRouterContextTokens[model.lowercased()]
                ?? (model.lowercased().hasPrefix("openai/") ? openAIContextTokens(model: String(model.dropFirst(7))) : nil)
        case .cerebras: verifiedCerebrasContextTokens[model.lowercased()]
        case .openAI: openAIContextTokens(model: model)
        case .anthropic: AnthropicModelTraits(model: model).contextTokens
        case .builtIn, .ollama, .generic: nil
        }
    }

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

    static func contextTokenLimit(for config: AppSettings) -> Int {
        switch config.summarizerBackend {
        case .chatGPTPlan:
            return openAIContextTokens(model: config.chatGPTPlanModel) ?? 128_000
        case .claudePlan:
            return 200_000
        case .antigravityPlan:
            return config.antigravityPlanModel.lowercased().hasPrefix("gpt-oss") ? 128_000 : 200_000
        case .geminiPlan:
            return 1_000_000
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
