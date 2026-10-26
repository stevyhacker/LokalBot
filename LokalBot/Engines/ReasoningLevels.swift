import Foundation

/// The user's reasoning preference for Think and Agent Mode. Automatic keeps
/// each task's own budget and leaves an external server at its default. A
/// chosen level is the level for tasks that set no budget and a ceiling for
/// tasks that do, so a task tuned for no reasoning never starts reasoning.
/// Each model accepts only some levels; see `ReasoningSupport`.
enum ThinkReasoningLevel: String, Codable, CaseIterable, Identifiable, Comparable, Sendable {
    case automatic
    case off
    case minimal
    case low
    case medium
    case high
    case xhigh
    case max

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .automatic: "Automatic"
        case .off: "Off"
        case .minimal: "Minimal"
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        case .xhigh: "Extra high"
        case .max: "Max"
        }
    }

    /// Declaration order, least reasoning first after Automatic.
    static func < (lhs: Self, rhs: Self) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }

    /// `reasoning_effort` and OpenRouter `effort` spell Off as "none".
    init?(effort: String) {
        if effort == "none" { self = .off; return }
        guard let level = Self(rawValue: effort), level != .automatic else { return nil }
        self = level
    }

    var effortValue: String { self == .off ? "none" : rawValue }

    /// llama-server's thinking budget. High is the built-in model's default.
    var budgetTokens: Int? {
        switch self {
        case .automatic: nil
        case .off: 0
        case .minimal: 256
        case .low: 512
        case .medium: 4_096
        case .high: MainLLMRuntimePolicy.highReasoningBudgetTokens
        case .xhigh: 16_384
        case .max: 24_576
        }
    }

    /// The most reasoning a task's own budget allows. The same steps map
    /// budgets onto OpenAI efforts when the level is Automatic.
    static func ceiling(forTaskBudget tokens: Int) -> Self {
        if tokens <= 0 { return .off }
        if tokens <= 512 { return .low }
        if tokens <= 4_096 { return .medium }
        return .high
    }
}

/// The reasoning levels one model accepts on one server.
struct ReasoningSupport: Equatable, Sendable {
    /// Explicit levels, least reasoning first. Empty: nothing LokalBot can set.
    var levels: [ThinkReasoningLevel]
    /// What the model does when a request sets nothing, when that is known.
    var defaultLevel: ThinkReasoningLevel?

    init(levels: [ThinkReasoningLevel], defaultLevel: ThinkReasoningLevel? = nil) {
        self.levels = levels.filter { $0 != .automatic }.sorted()
        self.defaultLevel = defaultLevel
    }

    static let unavailable = ReasoningSupport(levels: [])
    /// `reasoning_effort`'s common values, for servers that publish nothing.
    /// A level the model rejects gets one retry (see the engines).
    static let common = ReasoningSupport(levels: [.off, .low, .medium, .high])

    var isAdjustable: Bool { !levels.isEmpty }

    /// The supported level nearest below `level`, else the lowest one. Nil
    /// for Automatic or a model without a control.
    func clamp(_ level: ThinkReasoningLevel) -> ThinkReasoningLevel? {
        guard level != .automatic, !levels.isEmpty else { return nil }
        return levels.last { $0 <= level } ?? levels.first
    }

    /// The level one request carries: the chosen level, no higher than the
    /// task's own budget allows, clamped to what the model accepts.
    ///
    /// Automatic leaves the server at its default, except that a task tuned
    /// for no reasoning is not handed to a model that reasons by default. On
    /// 2026-10-07 Cerebras Qwen, left at its default on Automatic, spent every
    /// notes request's output on hidden reasoning and returned no notes.
    func requestLevel(_ level: ThinkReasoningLevel, taskBudget: Int?) -> ThinkReasoningLevel? {
        guard level != .automatic else {
            guard taskBudget == 0, let defaultLevel, defaultLevel > .off, levels.contains(.off) else { return nil }
            return .off
        }
        let ceiling = taskBudget.map(ThinkReasoningLevel.ceiling(forTaskBudget:)) ?? level
        return clamp(Swift.min(level, ceiling))
    }

    /// Automatic's menu title, naming the model's own default when known.
    var automaticTitle: String {
        guard let defaultLevel else { return ThinkReasoningLevel.automatic.displayName }
        return "Automatic (\(defaultLevel.displayName))"
    }

    /// The menu value for a stored choice the current model may not accept.
    func displayed(_ level: ThinkReasoningLevel) -> ThinkReasoningLevel {
        clamp(level) ?? .automatic
    }
}

extension ReasoningSupport {
    enum Provider: Equatable, Sendable {
        case builtIn, ollama, openAI, openRouter, cerebras, anthropic, generic

        init(dialect: ChatCompletionDialect, baseURL: URL) {
            switch dialect {
            case .llamaServer: self = .builtIn
            case .openAI: self = .openAI
            case .openRouter: self = .openRouter
            case .generic:
                let host = baseURL.host?.lowercased() ?? ""
                if AnthropicAPI.isAnthropic(baseURL) {
                    self = .anthropic
                } else {
                    self = host == "cerebras.ai" || host.hasSuffix(".cerebras.ai") ? .cerebras : .generic
                }
            }
        }
    }

    /// What LokalBot knows without asking the server. OpenRouter and Ollama
    /// publish more; `resolve(for:)` reads it.
    static func known(provider: Provider, model: String) -> ReasoningSupport {
        let name = model.lowercased()
        switch provider {
        case .builtIn:
            return builtIn(name)
        case .ollama:
            return name.contains("gpt-oss")
                ? .init(levels: [.low, .medium, .high], defaultLevel: .medium)
                : .init(levels: [.off])
        case .openAI:
            return openAI(name)
        case .openRouter:
            if name.hasPrefix("openai/") {
                let support = openAI(String(name.dropFirst(7)))
                if support.isAdjustable { return support }
            }
            return family(name) ?? .common
        case .cerebras:
            return cerebras(name)
        case .anthropic:
            return AnthropicModelTraits(model: name).reasoningSupport
        case .generic:
            return family(name) ?? .common
        }
    }

    static func known(for settings: AppSettings) -> ReasoningSupport {
        switch settings.summarizerBackend {
        case .builtIn:
            return known(provider: .builtIn, model: settings.builtInModelID)
        case .appleIntelligence:
            return .unavailable
        case .ollama:
            return known(provider: .ollama, model: settings.ollamaModel)
        case .openAICompatible:
            guard let url = URL(string: settings.openAIBaseURL) else { return .unavailable }
            return known(provider: .init(dialect: .inferred(from: url), baseURL: url),
                         model: settings.openAIModel)
        case .chatGPTPlan:
            return ChatGPTPlanEngine(model: settings.chatGPTPlanModel).reasoningSupport
        case .claudePlan:
            return ClaudePlanEngine(model: settings.claudePlanModel).traits.support
        }
    }

    /// Adds what the server publishes about the selected model: OpenRouter's
    /// model list and Ollama's capabilities. Both are read only from origins
    /// already allowed for inference and carry no key and no content.
    static func resolve(for settings: AppSettings,
                        openRouter: OpenRouterModelCatalog = .shared) async -> ReasoningSupport {
        switch settings.summarizerBackend {
        case .ollama:
            guard let url = URL(string: settings.ollamaBaseURL), !settings.ollamaModel.isEmpty,
                  InferenceEndpointPolicy.isAllowed(url, approvedOrigins: settings.approvedRemoteInferenceOrigins)
            else { return known(for: settings) }
            return await OllamaEngine.reasoningSupport(baseURL: url, model: settings.ollamaModel)
                ?? known(for: settings)
        case .openAICompatible:
            guard let url = URL(string: settings.openAIBaseURL), !settings.openAIModel.isEmpty else {
                return known(for: settings)
            }
            return await openRouter.reasoningSupport(
                model: settings.openAIModel, baseURL: url,
                approvedOrigins: settings.approvedRemoteInferenceOrigins) ?? known(for: settings)
        case .builtIn, .appleIntelligence, .chatGPTPlan, .claudePlan:
            return known(for: settings)
        }
    }

    /// llama-server's thinking budget works for any model with a thinking turn.
    private static func builtIn(_ id: String) -> ReasoningSupport {
        switch id {
        case "ministral-3-3b-instruct-2512": .unavailable          // instruct only
        case "lfm2.5-2.6b": .init(levels: [.low, .medium, .high])  // always reasons
        default: .init(levels: [.off, .low, .medium, .high])
        }
    }

    /// OpenAI's reasoning models, by generation. Others take no effort.
    private static func openAI(_ name: String) -> ReasoningSupport {
        if name.hasPrefix("o1") || name.hasPrefix("o3") || name.hasPrefix("o4") {
            return .init(levels: [.low, .medium, .high], defaultLevel: .medium)
        }
        if let minor = name.firstMatch(of: /^gpt-5\.(\d+)/).flatMap({ Int($0.1) }) {
            return minor == 1
                ? .init(levels: [.off, .low, .medium, .high], defaultLevel: .off)
                : .init(levels: [.off, .low, .medium, .high, .xhigh], defaultLevel: .medium)
        }
        if name == "gpt-5" || name.hasPrefix("gpt-5-") {
            return .init(levels: [.minimal, .low, .medium, .high], defaultLevel: .medium)
        }
        // GPT-6 adds Max and defaults to Medium. Sol and Luna also take
        // `none`; 6.1 Sol and Astra reject it, so newer models get no Off.
        // Astra documents no default (OpenAI's model pages, 26 October 2026).
        if name == "gpt-6" || name.hasPrefix("gpt-6-") || name.hasPrefix("gpt-6.") {
            let levels: [ThinkReasoningLevel] = [.low, .medium, .high, .xhigh, .max]
            if name.hasPrefix("gpt-6-sol") || name.hasPrefix("gpt-6-luna") {
                return .init(levels: [.off] + levels, defaultLevel: .medium)
            }
            return .init(levels: levels, defaultLevel: name.hasPrefix("gpt-6-astra") ? nil : .medium)
        }
        return .unavailable
    }

    /// Cerebras's documented `reasoning_effort` values per model.
    private static func cerebras(_ name: String) -> ReasoningSupport {
        if name.hasPrefix("qwen") { return .init(levels: [.off, .low, .medium, .high], defaultLevel: .high) }
        if name.hasPrefix("gpt-oss") { return .init(levels: [.low, .medium, .high], defaultLevel: .medium) }
        if name.hasPrefix("gemma") { return .init(levels: [.off, .low, .medium, .high], defaultLevel: .off) }
        if name.hasPrefix("kimi") { return .unavailable }  // accepted but ignored
        return .common
    }

    /// Model families whose levels hold on any server.
    private static func family(_ name: String) -> ReasoningSupport? {
        name.contains("gpt-oss") ? .init(levels: [.low, .medium, .high], defaultLevel: .medium) : nil
    }
}

extension ReasoningSupport {
    /// Changes whenever a different model or server answers for Think.
    static func lookupKey(for settings: AppSettings) -> String {
        let origins = settings.approvedRemoteInferenceOrigins.joined(separator: ",")
        return switch settings.summarizerBackend {
        case .builtIn: "builtIn|\(settings.builtInModelID)"
        case .appleIntelligence: "appleIntelligence"
        case .ollama: "ollama|\(settings.ollamaBaseURL)|\(settings.ollamaModel)|\(origins)"
        case .openAICompatible: "openAICompatible|\(settings.openAIBaseURL)|\(settings.openAIModel)|\(origins)"
        case .chatGPTPlan: "chatGPTPlan|\(settings.chatGPTPlanModel)"
        case .claudePlan: "claudePlan|\(settings.claudePlanModel)"
        }
    }
}

/// A view's last `ReasoningSupport.resolve` answer, valid only while the
/// same model and server are selected.
struct ResolvedReasoningSupport: Equatable {
    let key: String
    let support: ReasoningSupport

    static func resolve(for settings: AppSettings) async -> Self {
        Self(key: ReasoningSupport.lookupKey(for: settings), support: await ReasoningSupport.resolve(for: settings))
    }

    func support(for settings: AppSettings) -> ReasoningSupport? {
        key == ReasoningSupport.lookupKey(for: settings) ? support : nil
    }
}
