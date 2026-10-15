import Foundation

/// Where autocomplete runs.
enum CotypingBackend: String, Codable, CaseIterable, Identifiable, Sendable {
    /// The built-in autocomplete model, in process or on its own llama-server.
    case onDevice
    /// The Ollama or OpenAI-compatible server Think uses, with Think's model
    /// or another one on the same server.
    case thinkServer
    /// A separate OpenAI-compatible server: a cloud API, or a model server on
    /// this Mac or another device on the user's network.
    case server

    var id: String { rawValue }

    var title: String {
        switch self {
        case .onDevice: "On this Mac"
        case .thinkServer: "Think's server"
        case .server: "Another server"
        }
    }
}

/// How a server is asked for a continuation.
enum CotypingServerRequestStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Raw text completion for servers people run themselves, chat for hosted
    /// chat APIs, and chat after a server answers that it has no raw route.
    case automatic
    /// Raw `/v1/completions`: the model continues the text directly.
    case textCompletion
    /// `/v1/chat/completions` with the autocomplete instruction, thinking off.
    case chat

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: "Automatic"
        case .textCompletion: "Text completion"
        case .chat: "Chat"
        }
    }
}

/// One resolved autocomplete server. Built from settings for every request,
/// so a settings change applies to the next keystroke.
struct CotypingServerEndpoint: Equatable, Sendable {
    var baseURL: URL
    var model: String
    var apiKey: String?
    var dialect: ChatCompletionDialect
    var requestStyle: CotypingServerRequestStyle
    var openRouterDataPolicy: OpenRouterDataPolicy
    var origin: String

    /// Loopback: the prompt never leaves this Mac.
    var isOnThisMac: Bool { InferenceEndpointPolicy.isLoopback(baseURL) }

    /// A server the user runs on this Mac or their own network, which accepts
    /// llama.cpp's sampling fields. Hosted APIs may reject unknown fields.
    var isSelfHosted: Bool { isOnThisMac || InferenceEndpointPolicy.isPrivateNetwork(baseURL) }

    /// Whether the first request goes through chat rather than raw text completion.
    var startsWithChat: Bool {
        switch requestStyle {
        case .chat: true
        case .textCompletion: false
        // OpenAI and Anthropic offer no raw completions for current models, and
        // OpenRouter's raw route continues text as gibberish on many hosts
        // (Benchmarks/Cotyping/README.md). Servers people run themselves,
        // such as llama-server, LM Studio and Ollama, offer raw completions.
        case .automatic: AnthropicAPI.isAnthropic(baseURL) || dialect == .openAI || dialect == .openRouter
        }
    }

    /// The server and model, without the key.
    var identity: String { "\(origin)|\(baseURL.path)|\(model)" }
}

enum CotypingRoute: Equatable, Sendable {
    case onDevice
    case server(CotypingServerEndpoint)
    /// A server is selected but cannot be used; the reason says what to change.
    case unavailable(String)
}

extension AppSettings {
    static let cotypingServerAPIKeyAccount = "autocomplete-server-api-key"

    /// API key for `.server`. Think's server uses Think's key.
    var cotypingServerAPIKey: String {
        get { KeychainSecrets.string(account: Self.cotypingServerAPIKeyAccount) ?? "" }
        set { KeychainSecrets.setString(newValue, account: Self.cotypingServerAPIKeyAccount) }
    }

    /// The selected server's base URL as configured, before approval checks.
    /// Nil for the on-device route and for a server that is not set up.
    var cotypingConfiguredServerURL: URL? {
        switch cotypingBackend {
        case .onDevice:
            return nil
        case .thinkServer:
            switch summarizerBackend {
            case .ollama:
                return Self.serverURL(ollamaBaseURL)?.appendingPathComponent("v1")
            case .openAICompatible:
                return Self.serverURL(openAIBaseURL)
            case .builtIn, .appleIntelligence, .chatGPTPlan, .claudePlan:
                return nil
            }
        case .server:
            return Self.serverURL(cotypingServerBaseURL)
        }
    }

    /// Where the next completion goes. `includingCredentials: false` skips the
    /// Keychain read, for presentation and for decisions about context.
    func cotypingRoute(includingCredentials: Bool = true) -> CotypingRoute {
        switch cotypingBackend {
        case .onDevice:
            return .onDevice
        case .thinkServer:
            let override = cotypingThinkServerModel.trimmingCharacters(in: .whitespacesAndNewlines)
            switch summarizerBackend {
            case .ollama:
                let model = override.isEmpty
                    ? ollamaModel.trimmingCharacters(in: .whitespacesAndNewlines) : override
                return cotypingServerRoute(
                    url: cotypingConfiguredServerURL, model: model, apiKey: nil,
                    missingModel: "Choose a model for Think's Ollama server, or name one for autocomplete, under Settings → Writing.")
            case .openAICompatible:
                let model = override.isEmpty
                    ? openAIModel.trimmingCharacters(in: .whitespacesAndNewlines) : override
                return cotypingServerRoute(
                    url: cotypingConfiguredServerURL, model: model,
                    apiKey: includingCredentials ? openAIAPIKey : nil,
                    missingModel: "Set a model for Think's server, or name one for autocomplete, under Settings → Writing.")
            case .builtIn, .appleIntelligence, .chatGPTPlan, .claudePlan:
                return .unavailable("Think doesn't use a server. Choose another server for autocomplete, or run it on this Mac, under Settings → Writing.")
            }
        case .server:
            guard !cotypingServerBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .unavailable("Add a server URL for autocomplete under Settings → Writing.")
            }
            return cotypingServerRoute(
                url: cotypingConfiguredServerURL,
                model: cotypingServerModel.trimmingCharacters(in: .whitespacesAndNewlines),
                apiKey: includingCredentials ? cotypingServerAPIKey : nil,
                missingModel: "Name the model autocomplete should use on this server under Settings → Writing.")
        }
    }

    /// True unless autocomplete's prompt stays on this Mac: the on-device
    /// model, or a server on a loopback address. A server that is not set up
    /// yet counts as off this Mac, so nothing changes once it is.
    var cotypingLeavesThisMac: Bool {
        guard cotypingBackend != .onDevice else { return false }
        guard let url = cotypingConfiguredServerURL else { return true }
        return !InferenceEndpointPolicy.isLoopback(url)
    }

    /// Settings the autocomplete pipeline runs under. Off this Mac, the server
    /// gets only the text before the caret, the app and window context, and
    /// the writing profile: the clipboard, text read from the screen, saved
    /// memory and learned examples stay local, so their grants are off here.
    var cotypingEffectiveSettings: AppSettings {
        guard cotypingLeavesThisMac else { return self }
        var settings = self
        settings.cotypingUseClipboard = false
        settings.cotypingUseVisibleContext = false
        settings.cotypingUseWindowText = false
        settings.cotypingUseMeetingMemory = false
        settings.cotypingUseScreenMemory = false
        settings.cotypingUseLocalLearning = false
        return settings
    }

    /// Model ID recorded with autocomplete statistics.
    var cotypingStatisticsModelID: String {
        guard cotypingBackend != .onDevice else { return cotypingBuiltInModelID }
        if case .server(let endpoint) = cotypingRoute(includingCredentials: false) { return endpoint.model }
        return cotypingBackend.rawValue
    }

    /// Name of the model autocomplete uses, for Settings.
    var cotypingModelDisplayName: String {
        switch cotypingRoute(includingCredentials: false) {
        case .onDevice:
            return ModelCatalog.entry(id: cotypingBuiltInModelID, custom: customBuiltInModels)?.displayName
                ?? cotypingBuiltInModelID
        case .server(let endpoint):
            return "\(endpoint.model) · \(endpoint.baseURL.host ?? endpoint.origin)"
        case .unavailable:
            return cotypingBackend.title
        }
    }

    /// Everything about the route that changes what a completion can be,
    /// for caches and setup checks. The key is left out.
    var cotypingRouteFingerprint: String {
        switch cotypingRoute(includingCredentials: false) {
        case .onDevice:
            return "on-device"
        case .server(let endpoint):
            return ["server", endpoint.identity, endpoint.requestStyle.rawValue,
                    endpoint.openRouterDataPolicy.rawValue].joined(separator: "|")
        case .unavailable(let reason):
            return "unavailable|\(reason)"
        }
    }

    private static func serverURL(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return URL(string: trimmed)
    }

    private func cotypingServerRoute(url: URL?, model: String, apiKey: String?,
                                     missingModel: String) -> CotypingRoute {
        guard let url, let origin = InferenceEndpointPolicy.origin(for: url) else {
            return .unavailable("The autocomplete server URL must start with http:// or https://.")
        }
        do {
            try InferenceEndpointPolicy.validate(
                url, approvedOrigins: approvedRemoteAutocompleteOrigins, allowsPrivateNetworkHTTP: true)
        } catch InferenceEndpointPolicy.PolicyError.insecureRemoteEndpoint {
            return .unavailable("Autocomplete won't send typing to \(origin) unencrypted. Use HTTPS, or a server on this Mac or your own network.")
        } catch InferenceEndpointPolicy.PolicyError.remoteApprovalRequired {
            return .unavailable("Approve \(origin) for autocomplete under Settings → Writing before anything you type is sent there.")
        } catch {
            return .unavailable("The autocomplete server URL must start with http:// or https://.")
        }
        guard !model.isEmpty else { return .unavailable(missingModel) }
        let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        return .server(CotypingServerEndpoint(
            baseURL: url,
            model: model,
            apiKey: key?.isEmpty == false ? key : nil,
            dialect: .inferred(from: url),
            requestStyle: cotypingServerRequestStyle,
            openRouterDataPolicy: openRouterDataPolicy,
            origin: origin))
    }
}

/// Autocomplete on a server: raw text completion where the server offers it,
/// chat continuation otherwise. Each request takes a slot on the origin's
/// `RemoteInferenceGate` like Think's requests do, and is never replayed:
/// a newer keystroke supersedes it anyway.
@MainActor
final class RemoteCotypingEngine: CotypingCompleting {
    typealias EngineFactory = @MainActor (CotypingServerEndpoint, _ chat: Bool) -> CotypingCompleting

    /// A completion slower than this is no longer worth showing. Matches the
    /// raw-completion session's own limit, which chat requests do not have.
    nonisolated static let deadlineSeconds: Double = 15

    private let route: () -> CotypingRoute
    private let makeEngine: EngineFactory
    private let deadline: Duration
    /// Servers whose raw route answered as unsupported. With the automatic
    /// style they are asked through chat from then on, until LokalBot quits.
    private(set) var chatOnlyServers: Set<String> = []

    init(route: @escaping () -> CotypingRoute,
         deadline: Duration = .seconds(RemoteCotypingEngine.deadlineSeconds),
         makeEngine: @escaping EngineFactory = RemoteCotypingEngine.defaultEngine) {
        self.route = route
        self.deadline = deadline
        self.makeEngine = makeEngine
    }

    func generate(_ request: CotypingRequest) async throws -> CotypingNormalizationResult {
        try await generateStreaming(request) { _ in }
    }

    func generateStreaming(
        _ request: CotypingRequest,
        onPartial: @escaping @Sendable (CotypingNormalizationResult) -> Void
    ) async throws -> CotypingNormalizationResult {
        let endpoint: CotypingServerEndpoint
        switch route() {
        case .server(let resolved): endpoint = resolved
        case .unavailable(let reason): throw TextEngineError.unavailable(reason)
        case .onDevice: throw TextEngineError.unavailable("Autocomplete runs on this Mac.")
        }
        if endpoint.startsWithChat || chatOnlyServers.contains(endpoint.identity) {
            return try await run(endpoint, chat: true, request, onPartial)
        }
        do {
            return try await run(endpoint, chat: false, request, onPartial)
        } catch let error where endpoint.requestStyle == .automatic && Self.rejectsTextCompletion(error) {
            chatOnlyServers.insert(endpoint.identity)
            lokalbotLog("autocomplete server has no raw completions host=\(endpoint.baseURL.host ?? "unknown"); using chat")
            return try await run(endpoint, chat: true, request, onPartial)
        }
    }

    private func run(
        _ endpoint: CotypingServerEndpoint, chat: Bool, _ request: CotypingRequest,
        _ onPartial: @escaping @Sendable (CotypingNormalizationResult) -> Void
    ) async throws -> CotypingNormalizationResult {
        let engine = makeEngine(endpoint, chat)
        let timeout = TextEngineError.serverUnreachable(
            endpoint.baseURL.absoluteString, transportCode: NSURLErrorTimedOut)
        let deadline = deadline
        return try await withThrowingTaskGroup(of: CotypingNormalizationResult.self) { group in
            group.addTask { @MainActor in try await engine.generateStreaming(request, onPartial: onPartial) }
            group.addTask {
                try await Task.sleep(for: deadline)
                throw timeout
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw CancellationError() }
            return result
        }
    }

    /// A server without a raw completion route: missing, not allowed, or not
    /// implemented, or a model the server serves through chat only.
    nonisolated static func rejectsTextCompletion(_ error: Error) -> Bool {
        guard case .httpStatus(let code, let detail, _) = error as? TextEngineError else { return false }
        if [404, 405, 501].contains(code) { return true }
        guard code == 400 || code == 422 else { return false }
        let lowered = detail.lowercased()
        return ["not supported", "unsupported", "chat", "does not support"].contains { lowered.contains($0) }
    }

    static func defaultEngine(_ endpoint: CotypingServerEndpoint, chat: Bool) -> CotypingCompleting {
        // Anthropic serves chat completions under /v1 whichever form of its URL was entered.
        let baseURL = chat && AnthropicAPI.isAnthropic(endpoint.baseURL)
            ? AnthropicAPI.versionedRoot(endpoint.baseURL) : endpoint.baseURL
        let openAI = OpenAICompatibleEngine(
            baseURL: baseURL,
            model: endpoint.model,
            apiKey: endpoint.apiKey,
            sendsLlamaSamplingExtensions: endpoint.isSelfHosted,
            chatDialect: endpoint.dialect,
            openRouterDataPolicy: endpoint.openRouterDataPolicy)
        let text: TextEngine = chat ? ChatContinuationEngine(base: openAI) : openAI
        let gated = GatedTextEngine(
            base: text,
            origin: RemoteInferenceGate.origin(for: endpoint.baseURL),
            priority: .interactive,
            purpose: "autocomplete")
        // A chat reply has no token boundary at the caret, so it is not healed.
        return CotypingEngine(makeEngine: { gated }, healsCaretBoundary: !chat)
    }
}

/// Autocomplete through a chat endpoint: the app's autocomplete instruction as the
/// system message and the rendered prompt as the user message, with thinking off.
/// The reply budget is at least 32 tokens, so a phrase that runs a little long is
/// trimmed by the normalizer instead of failing as truncated. An empty reply means
/// the model had nothing to add, which is an empty suggestion rather than an error.
struct ChatContinuationEngine: TextEngine {
    let base: OpenAICompatibleEngine

    var displayName: String { base.displayName }

    func generate(system: String, prompt: String, context: [String]) async throws -> String {
        try await base.generate(system: system, prompt: prompt, context: context)
    }

    func complete(_ request: CompletionRequest) async throws -> String {
        do {
            return try await base.generate(
                system: PromptTemplates.autocompleteSystem, prompt: request.prompt, context: [],
                options: TextGenerationOptions(maxTokens: max(request.maxTokens, 32), reasoningBudgetTokens: 0,
                                               temperature: request.temperature))
        } catch TextEngineError.badResponse(let detail) where detail.contains("contained no text") {
            return ""
        }
    }
}
