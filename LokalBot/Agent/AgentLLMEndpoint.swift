import Foundation

struct AgentLLMEndpoint: Equatable, Sendable {
    let baseURL: URL
    let model: String
    let contextTokens: Int
    let apiKey: String?
    var reasoningDialect: AgentReasoningDialect = .generic
    var api: AgentLLMAPI = .chatCompletions
    var plan: SubscriptionPlan?

    static let defaultContextTokens = MainLLMRuntimePolicy.contextTokens
}

enum AgentReasoningDialect: String, Equatable, Sendable {
    case llamaServer = "llama-server"
    case openAI = "openai"
    case openRouter = "openrouter"
    case ollama
    case generic

    init(_ dialect: ChatCompletionDialect) {
        switch dialect {
        case .llamaServer: self = .llamaServer
        case .openAI: self = .openAI
        case .openRouter: self = .openRouter
        case .generic: self = .generic
        }
    }
}

enum AgentLLMAPI: String, Equatable, Sendable {
    case chatCompletions = "openai-completions"
    case responses = "openai-responses"
}

enum AgentLLMResolution: Equatable, Sendable {
    case builtIn(modelID: String)
    case chatGPTPlan(model: String)
    case ready(AgentLLMEndpoint)
    case unsupported(reason: String)
}
