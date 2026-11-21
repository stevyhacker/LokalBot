import Foundation

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

    static func < (lhs: Self, rhs: Self) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }

    init?(effort: String) {
        if effort == "none" { self = .off; return }
        guard let level = Self(rawValue: effort), level != .automatic else { return nil }
        self = level
    }

    var effortValue: String { self == .off ? "none" : rawValue }

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
}

enum TaskReasoning: Equatable, Sendable {
    case modelDefault
    case off
}

struct ReasoningSupport: Equatable, Sendable {
    var levels: [ThinkReasoningLevel]
    var defaultLevel: ThinkReasoningLevel?
    var templateTakesEffort: Bool

    init(levels: [ThinkReasoningLevel], defaultLevel: ThinkReasoningLevel? = nil, templateTakesEffort: Bool = false) {
        self.levels = levels.filter { $0 != .automatic }.sorted()
        self.defaultLevel = defaultLevel
        self.templateTakesEffort = templateTakesEffort
    }

    static let unavailable = ReasoningSupport(levels: [])
    static let common = ReasoningSupport(levels: [.off, .low, .medium, .high])

    var isAdjustable: Bool { !levels.isEmpty }

    func clamp(_ level: ThinkReasoningLevel) -> ThinkReasoningLevel? {
        guard level != .automatic, !levels.isEmpty else { return nil }
        return levels.last { $0 <= level } ?? levels.first
    }

    func requestLevel(_ level: ThinkReasoningLevel, reasoning: TaskReasoning) -> ThinkReasoningLevel? {
        guard level != .automatic else {
            guard reasoning == .off, let defaultLevel, defaultLevel > .off, levels.contains(.off) else { return nil }
            return .off
        }
        return clamp(reasoning == .off ? .off : level)
    }

    var thinksByDefault: Bool { defaultLevel.map { $0 > .off } ?? true }

    func reasoningAllowance(_ level: ThinkReasoningLevel, reasoning: TaskReasoning, answerTokens: Int?) -> Int {
        guard reasoning == .modelDefault else { return 0 }
        if let chosen = requestLevel(level, reasoning: reasoning) { return max(0, chosen.budgetTokens ?? 0) }
        guard thinksByDefault else { return 0 }
        let cap = MainLLMRuntimePolicy.highReasoningBudgetTokens
        return min(cap, answerTokens.map { max(1, $0) } ?? cap)
    }

    var automaticTitle: String {
        guard let defaultLevel else { return ThinkReasoningLevel.automatic.displayName }
        return "Automatic (\(defaultLevel.displayName))"
    }

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
        case .antigravityPlan:
            return AntigravityPlanEngine(model: settings.antigravityPlanModel).traits.support
        case .geminiPlan:
            return .unavailable
        }
    }

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
        case .builtIn, .appleIntelligence, .chatGPTPlan, .claudePlan, .antigravityPlan, .geminiPlan:
            return known(for: settings)
        }
    }

    private static func builtIn(_ id: String) -> ReasoningSupport {
        let adjustable: [ThinkReasoningLevel] = [.off, .low, .medium, .high]
        switch id {
        case "ministral-3-3b-instruct-2512":
            return .init(levels: [], defaultLevel: .off)
        case "lfm2.5-2.6b":
            return .init(levels: [.low, .medium, .high], defaultLevel: .high)
        case "qwen3.5-4b", "qwen3.6-35b-a3b", "qwen3.6-27b":
            return .init(levels: adjustable, defaultLevel: .high)
        case "inkling-2-mini":
            return .init(levels: adjustable, defaultLevel: .high, templateTakesEffort: true)
        case "qwen3.5-0.8b", "qwen3.5-2b", "gemma4-e4b", "gemma4-e4b-q5-xl", "gemma4-12b",
             "lfm2.5-1.2b-instruct", "granite-4.1-3b":
            return .init(levels: adjustable, defaultLevel: .off)
        default:
            return .init(levels: adjustable)
        }
    }

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
        if name == "gpt-6" || name.hasPrefix("gpt-6-") || name.hasPrefix("gpt-6.") {
            let levels: [ThinkReasoningLevel] = [.low, .medium, .high, .xhigh, .max]
            if name.hasPrefix("gpt-6-sol") || name.hasPrefix("gpt-6-luna") {
                return .init(levels: [.off] + levels, defaultLevel: .medium)
            }
            return .init(levels: levels, defaultLevel: name.hasPrefix("gpt-6-astra") ? nil : .medium)
        }
        return .unavailable
    }

    private static func cerebras(_ name: String) -> ReasoningSupport {
        if name.hasPrefix("qwen") { return .init(levels: [.off, .low, .medium, .high], defaultLevel: .high) }
        if name.hasPrefix("gpt-oss") { return .init(levels: [.low, .medium, .high], defaultLevel: .medium) }
        if name.hasPrefix("gemma") { return .init(levels: [.off, .low, .medium, .high], defaultLevel: .off) }
        if name.hasPrefix("kimi") { return .unavailable }
        return .common
    }

    private static func family(_ name: String) -> ReasoningSupport? {
        name.contains("gpt-oss") ? .init(levels: [.low, .medium, .high], defaultLevel: .medium) : nil
    }
}

extension ReasoningSupport {
    static func lookupKey(for settings: AppSettings) -> String {
        let origins = settings.approvedRemoteInferenceOrigins.joined(separator: ",")
        return switch settings.summarizerBackend {
        case .builtIn: "builtIn|\(settings.builtInModelID)"
        case .appleIntelligence: "appleIntelligence"
        case .ollama: "ollama|\(settings.ollamaBaseURL)|\(settings.ollamaModel)|\(origins)"
        case .openAICompatible: "openAICompatible|\(settings.openAIBaseURL)|\(settings.openAIModel)|\(origins)"
        case .chatGPTPlan: "chatGPTPlan|\(settings.chatGPTPlanModel)"
        case .claudePlan: "claudePlan|\(settings.claudePlanModel)"
        case .antigravityPlan: "antigravityPlan|\(settings.antigravityPlanModel)"
        case .geminiPlan: "geminiPlan|\(settings.geminiPlanModel)"
        }
    }
}

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
