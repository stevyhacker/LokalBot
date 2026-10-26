import Foundation

/// A resolved OpenAI-compatible endpoint the agent's provider will talk to.
struct AgentLLMEndpoint: Equatable, Sendable {
    let baseURL: URL
    let model: String
    let contextTokens: Int
    let apiKey: String?
    /// Which request fields carry a reasoning level to this server. The pi
    /// extension writes them; see `applyReasoningLevel` in its index.ts.
    var reasoningDialect: AgentReasoningDialect = .generic
    /// The wire format pi's provider speaks to `baseURL`.
    var api: AgentLLMAPI = .chatCompletions
    /// Set when requests run on a subscription plan through LokalBot's local
    /// relay: `baseURL` is on this Mac, but the content goes to the plan's
    /// provider.
    var plan: SubscriptionPlan?

    /// Matches the built-in Main LLM and gives Agent Mode the same compaction
    /// boundary. External endpoints use it as a conservative declared window
    /// when their true model metadata is unavailable.
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

/// pi-ai's names for the wire formats Agent Mode uses.
enum AgentLLMAPI: String, Equatable, Sendable {
    case chatCompletions = "openai-completions"
    case responses = "openai-responses"
}

enum AgentLLMResolution: Equatable, Sendable {
    /// Caller resolves the model URL and holds an `InferenceBroker` Main LLM
    /// lease before building the endpoint from the shared base URL + model id.
    case builtIn(modelID: String)
    /// Caller starts a `ChatGPTPlanRelay` for the session and points pi at it.
    case chatGPTPlan(model: String)
    case ready(AgentLLMEndpoint)
    case unsupported(reason: String)
}
