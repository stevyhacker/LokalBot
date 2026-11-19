import Foundation

/// Think backends that run on the user's own ChatGPT, Claude, Antigravity,
/// or Gemini plan instead of an API key. Requests count toward that plan's
/// usage limits.
///
/// Each plan has its own approval entry in
/// `AppSettings.approvedRemoteInferenceOrigins`. The entries are not URL
/// origins, so approving an API server (`https://api.openai.com` with a key)
/// never approves plan usage, and the reverse: the two run under different
/// provider terms.
enum SubscriptionPlan: String, CaseIterable, Identifiable, Sendable {
    case chatGPT
    case claude
    case antigravity
    case gemini

    var id: String { rawValue }

    init?(backend: AppSettings.SummarizerBackend) {
        switch backend {
        case .chatGPTPlan: self = .chatGPT
        case .claudePlan: self = .claude
        case .antigravityPlan: self = .antigravity
        case .geminiPlan: self = .gemini
        case .builtIn, .appleIntelligence, .ollama, .openAICompatible: return nil
        }
    }

    var backend: AppSettings.SummarizerBackend {
        switch self {
        case .chatGPT: .chatGPTPlan
        case .claude: .claudePlan
        case .antigravity: .antigravityPlan
        case .gemini: .geminiPlan
        }
    }

    var title: String {
        switch self {
        case .chatGPT: "ChatGPT plan"
        case .claude: "Claude plan"
        case .antigravity: "Antigravity plan"
        case .gemini: "Gemini plan"
        }
    }

    var providerName: String {
        switch self {
        case .chatGPT: "OpenAI"
        case .claude: "Anthropic"
        case .antigravity: "Google"
        case .gemini: "Google"
        }
    }

    /// Where Think content goes. Claude, Antigravity, and Gemini requests
    /// travel through the user's own CLI installation, which sends them to
    /// that provider.
    var destinationHost: String {
        switch self {
        case .chatGPT: "api.openai.com"
        case .claude: "api.anthropic.com"
        case .antigravity: "antigravity.google"
        case .gemini: "cloudcode-pa.googleapis.com"
        }
    }

    /// The approval entry, also used as the request gate's origin.
    var consentKey: String {
        switch self {
        case .chatGPT: "chatgpt-plan://api.openai.com"
        case .claude: "claude-plan://api.anthropic.com"
        case .antigravity: "antigravity-plan://antigravity.google"
        case .gemini: "gemini-plan://cloudcode-pa.googleapis.com"
        }
    }

    /// The provider's own page for checking and capping plan usage.
    var manageUsageURL: URL {
        switch self {
        case .chatGPT: URL(string: "https://chatgpt.com/settings/usage")!
        case .claude: URL(string: "https://claude.ai/settings/usage")!
        case .antigravity: URL(string: "https://antigravity.google/docs/plans")!
        case .gemini: URL(string: "https://one.google.com/ai")!
        }
    }

    static func plan(forConsentKey key: String) -> SubscriptionPlan? {
        allCases.first { $0.consentKey == key }
    }

    func isApproved(in settings: AppSettings) -> Bool {
        settings.approvedRemoteInferenceOrigins.contains(consentKey)
    }

    func model(in settings: AppSettings) -> String {
        switch self {
        case .chatGPT: settings.chatGPTPlanModel
        case .claude: settings.claudePlanModel
        case .antigravity: settings.antigravityPlanModel
        case .gemini: settings.geminiPlanModel
        }
    }

    /// The approval list shows a plan entry by name rather than its key.
    static func approvalDisplayName(_ entry: String) -> String {
        guard let plan = plan(forConsentKey: entry) else { return entry }
        return "\(plan.title) · \(plan.destinationHost)"
    }
}

enum SubscriptionPlanError: LocalizedError, Equatable, Sendable {
    case approvalRequired(SubscriptionPlan)
    case noModel(SubscriptionPlan)

    var errorDescription: String? {
        switch self {
        case .approvalRequired(let plan):
            "Allow sending context to \(plan.providerName) with your \(plan.title) under Settings → Models → Think before Think uses it."
        case .noModel(let plan):
            "Choose a model for your \(plan.title) under Settings → Models."
        }
    }
}
