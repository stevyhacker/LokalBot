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

    var icon: String {
        switch self {
        case .onDevice: "desktopcomputer"
        case .thinkServer: "server.rack"
        case .server: "network"
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
                    missingModel: "Choose a model for Think's Ollama server, or name one for autocomplete, under Settings → Models.")
            case .openAICompatible:
                let model = override.isEmpty
                    ? openAIModel.trimmingCharacters(in: .whitespacesAndNewlines) : override
                return cotypingServerRoute(
                    url: cotypingConfiguredServerURL, model: model,
                    apiKey: includingCredentials ? openAIAPIKey : nil,
                    missingModel: "Set a model for Think's server, or name one for autocomplete, under Settings → Models.")
            case .builtIn, .appleIntelligence, .chatGPTPlan, .claudePlan:
                return .unavailable("Think doesn't use a server. Choose another server for autocomplete, or run it on this Mac, under Settings → Models.")
            }
        case .server:
            guard !cotypingServerBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .unavailable("Add a server URL for autocomplete under Settings → Models.")
            }
            return cotypingServerRoute(
                url: cotypingConfiguredServerURL,
                model: cotypingServerModel.trimmingCharacters(in: .whitespacesAndNewlines),
                apiKey: includingCredentials ? cotypingServerAPIKey : nil,
                missingModel: "Name the model autocomplete should use on this server under Settings → Models.")
        }
    }

    /// True unless autocomplete's prompt stays on this Mac: the on-device
    /// model, or a server on a loopback address. A server that is not set up
    /// yet counts as off this Mac.
    var cotypingLeavesThisMac: Bool {
        guard cotypingBackend != .onDevice else { return false }
        guard let url = cotypingConfiguredServerURL else { return true }
        return !InferenceEndpointPolicy.isLoopback(url)
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
            return .unavailable("Approve \(origin) for autocomplete under Settings → Models before anything you type is sent there.")
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

/// Where autocomplete runs, as edited in the Models picker. Applied with Use
/// model, so Cancel changes nothing.
struct CotypingServerDraft: Equatable {
    var backend: CotypingBackend
    var baseURL: String
    var model: String
    var thinkServerModel: String
    var requestStyle: CotypingServerRequestStyle
    /// A typed key for `.server`, saved to Keychain with Use model. Empty
    /// keeps the saved one.
    var apiKey = ""
    /// Typing approval for the draft server's origin.
    var approved = false

    init(settings: AppSettings) {
        backend = settings.cotypingBackend
        baseURL = settings.cotypingServerBaseURL
        model = settings.cotypingServerModel
        thinkServerModel = settings.cotypingThinkServerModel
        requestStyle = settings.cotypingServerRequestStyle
        approved = savedApproval(in: settings)
    }

    /// The settings change Use model makes. The on-device model is assigned
    /// only when autocomplete runs on this Mac, so a server needs no download.
    func patch(onDeviceModelID: String) -> ModelSelectionPatch {
        var patch = ModelSelectionPatch(cotypingBackend: backend)
        switch backend {
        case .onDevice:
            patch.autocompleteModelID = onDeviceModelID
        case .thinkServer:
            patch.cotypingThinkServerModel = thinkServerModel.trimmingCharacters(in: .whitespacesAndNewlines)
            patch.cotypingServerRequestStyle = requestStyle
        case .server:
            patch.cotypingServerBaseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            patch.cotypingServerModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
            patch.cotypingServerRequestStyle = requestStyle
        }
        return patch
    }

    /// The draft server's URL, before approval checks.
    func serverURL(in settings: AppSettings) -> URL? {
        patch(onDeviceModelID: settings.cotypingBuiltInModelID).applying(to: settings).cotypingConfiguredServerURL
    }

    /// The origin the approval belongs to. Nil on this Mac, where nothing
    /// leaves it and nothing needs approving.
    func origin(in settings: AppSettings) -> String? {
        guard let url = serverURL(in: settings), !InferenceEndpointPolicy.isLoopback(url) else { return nil }
        return InferenceEndpointPolicy.origin(for: url)
    }

    /// The saved approval for the draft's origin.
    func savedApproval(in settings: AppSettings) -> Bool {
        guard let origin = self.origin(in: settings) else { return false }
        return settings.approvedRemoteAutocompleteOrigins.contains(origin)
    }

    /// Approved origins with the draft's approval as the checkbox stands.
    func approvedOrigins(in settings: AppSettings) -> [String] {
        var origins = settings.approvedRemoteAutocompleteOrigins
        guard let origin = self.origin(in: settings) else { return origins }
        origins.removeAll { $0 == origin }
        if approved { origins.append(origin) }
        return origins
    }

    /// Where completions would go with this draft applied. The key is not read.
    func route(in settings: AppSettings) -> CotypingRoute {
        var target = patch(onDeviceModelID: settings.cotypingBuiltInModelID).applying(to: settings)
        target.approvedRemoteAutocompleteOrigins = approvedOrigins(in: settings)
        return target.cotypingRoute(includingCredentials: false)
    }
}

/// Why the last request to one server brought no suggestion.
struct CotypingServerProblem: Equatable, Sendable {
    /// `CotypingServerEndpoint.identity` of the server it belongs to.
    var identity: String
    var message: String
}

/// Autocomplete on a server: raw text completion where the server offers it,
/// chat continuation otherwise. Each request takes a slot on the origin's
/// `RemoteInferenceGate` like Think's requests do, and a failed one is never
/// replayed: a newer keystroke supersedes it anyway.
@MainActor
final class RemoteCotypingEngine: CotypingCompleting, ObservableObject {
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
    /// The last request's failure or empty reply, until a request brings a
    /// suggestion. Writing shows it, since typing elsewhere shows no error.
    @Published private(set) var problem: CotypingServerProblem?

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
        do {
            let result = try await suggest(from: endpoint, request, onPartial)
            report(result.suppression == .emptyGeneration
                   ? CotypingServerProblem(identity: endpoint.identity,
                                           message: "\(endpoint.model) answered with no text.")
                   : nil)
            return result
        } catch {
            if !(error is CancellationError), (error as? URLError)?.code != .cancelled {
                report(CotypingServerProblem(
                    identity: endpoint.identity,
                    message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription))
            }
            throw error
        }
    }

    /// Publishes only a change, so a working server does not redraw Settings
    /// on every suggestion.
    private func report(_ problem: CotypingServerProblem?) {
        if self.problem != problem { self.problem = problem }
    }

    private func suggest(
        from endpoint: CotypingServerEndpoint, _ request: CotypingRequest,
        _ onPartial: @escaping @Sendable (CotypingNormalizationResult) -> Void
    ) async throws -> CotypingNormalizationResult {
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
        // A chat reply has no token boundary at the caret: it is not healed, and the
        // space a chat model leaves out before a new word is put back.
        return CotypingEngine(makeEngine: { gated }, healsCaretBoundary: !chat, restoresWordSpace: chat)
    }
}

/// Autocomplete through a chat endpoint: the app's autocomplete instruction as the
/// system message and the rendered prompt as the user message, with thinking off.
/// The reply budget is at least 32 tokens; a reply cut off there keeps the text it
/// has, which the normalizer trims to a phrase. An empty reply means the model had
/// nothing to add, which is an empty suggestion rather than an error.
struct ChatContinuationEngine: TextEngine {
    /// Room for reasoning a model cannot turn off, on top of the phrase. On
    /// OpenRouter `z-ai/glm-5.3-flash` always reasons, and on 2026-10-15 a
    /// 32-token reply ended inside that reasoning with no suggestion.
    static let reasoningRoomTokens = 2_048
    /// Models that spent a whole short reply on reasoning, by server and model.
    /// Asked with reasoning room from then on, until LokalBot quits.
    private static let reasoningModels = ReasoningModels()

    let base: OpenAICompatibleEngine

    var displayName: String { base.displayName }

    func generate(system: String, prompt: String, context: [String]) async throws -> String {
        try await base.generate(system: system, prompt: prompt, context: context)
    }

    func complete(_ request: CompletionRequest) async throws -> String {
        let phrase = max(request.maxTokens, 32)
        let key = "\(base.baseURL.absoluteString)|\(base.model)"
        guard !Self.reasoningModels.contains(key) else {
            return try await reply(request, maxTokens: phrase + Self.reasoningRoomTokens)
        }
        do {
            return try await reply(request, maxTokens: phrase)
        } catch TextEngineError.outputTruncated {
            Self.reasoningModels.insert(key)
            lokalbotLog("autocomplete model reasons before replying model=\(base.model); asking with room for it")
            return try await reply(request, maxTokens: phrase + Self.reasoningRoomTokens)
        }
    }

    private func reply(_ request: CompletionRequest, maxTokens: Int) async throws -> String {
        do {
            return try await base.generate(
                system: PromptTemplates.autocompleteSystem, prompt: request.prompt, context: [],
                options: TextGenerationOptions(maxTokens: maxTokens, reasoningBudgetTokens: 0,
                                               temperature: request.temperature, keepsTruncatedReply: true))
        } catch TextEngineError.badResponse(let detail) where detail.contains("contained no text") {
            return ""
        } catch TextEngineError.outputTruncated where maxTokens > Self.reasoningRoomTokens {
            throw TextEngineError.unavailable(
                "\(base.model) reasoned until its reply ran out and wrote no suggestion. "
                    + "Choose a model that can answer without reasoning.")
        }
    }

    private final class ReasoningModels: @unchecked Sendable {
        private let lock = NSLock()
        private var keys: Set<String> = []

        func contains(_ key: String) -> Bool { lock.withLock { keys.contains(key) } }
        func insert(_ key: String) { _ = lock.withLock { keys.insert(key) } }
    }
}
