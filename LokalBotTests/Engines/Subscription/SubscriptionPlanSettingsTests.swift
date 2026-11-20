import XCTest
@testable import LokalBot

@MainActor
final class SubscriptionPlanSettingsTests: XCTestCase {
    private func settings(_ plan: SubscriptionPlan, approved: Bool = true) -> AppSettings {
        var settings = AppSettings()
        settings.summarizerBackend = plan.backend
        settings.chatGPTPlanModel = "gpt-5.2"
        settings.claudePlanModel = "sonnet"
        settings.antigravityPlanModel = "gemini-4-neon"
        settings.geminiPlanModel = "gemini-3.5-flash"
        if approved { settings.approvedRemoteInferenceOrigins = [plan.consentKey] }
        return settings
    }

    func testPlanUseRequiresItsOwnApproval() {
        for plan in SubscriptionPlan.allCases {
            let unapproved = settings(plan, approved: false)
            XCTAssertFalse(unapproved.usesRemoteMainLLM)
            XCTAssertFalse(unapproved.allowsAutomaticMainInference,
                           "scheduled digests and Dream must wait for the plan's approval")
            guard case .blocked = InferencePresentation(settings: unapproved) else {
                return XCTFail("\(plan) without approval must present as blocked")
            }

            let approved = settings(plan)
            XCTAssertTrue(approved.usesRemoteMainLLM)
            XCTAssertTrue(approved.allowsAutomaticMainInference)
            XCTAssertEqual(InferencePresentation(settings: approved), .remote(host: plan.title))
        }
    }

    func testAPIApprovalAndPlanApprovalNeverCoverEachOther() {
        var viaAPI = settings(.chatGPT, approved: false)
        viaAPI.approvedRemoteInferenceOrigins = [
            "https://api.openai.com",
            "https://api.anthropic.com",
            "https://generativelanguage.googleapis.com",
            "https://antigravity.google",
        ]
        XCTAssertFalse(viaAPI.usesRemoteMainLLM)
        for plan in SubscriptionPlan.allCases {
            viaAPI.summarizerBackend = plan.backend
            XCTAssertFalse(viaAPI.usesRemoteMainLLM, "API approval must never cover \(plan)")
        }

        var viaPlan = AppSettings()
        viaPlan.summarizerBackend = .openAICompatible
        viaPlan.openAIBaseURL = "https://api.openai.com/v1"
        viaPlan.approvedRemoteInferenceOrigins = SubscriptionPlan.allCases.map(\.consentKey)
        XCTAssertFalse(viaPlan.usesRemoteMainLLM)
        XCTAssertFalse(InferenceEndpointPolicy.isAllowed(
            URL(string: "https://api.openai.com/v1")!, approvedOrigins: viaPlan.approvedRemoteInferenceOrigins))

        for plan in SubscriptionPlan.allCases {
            let approved = settings(plan)
            for other in SubscriptionPlan.allCases where other != plan {
                var switched = approved
                switched.summarizerBackend = other.backend
                XCTAssertFalse(switched.usesRemoteMainLLM, "approval for \(plan) must not cover \(other)")
            }
        }
    }

    func testFactoryRefusesUnapprovedPlanAndGatesApprovedOne() async throws {
        let execution = ThinkExecution(storage: StorageManager())
        for plan in SubscriptionPlan.allCases {
            do {
                _ = try await execution.makeTextEngine(settings(plan, approved: false), includingCredentials: false)
                XCTFail("an unapproved plan must not produce an engine")
            } catch let error as SubscriptionPlanError {
                XCTAssertEqual(error, .approvalRequired(plan))
            }
            let engine = try await execution.makeTextEngine(settings(plan), includingCredentials: false,
                                                            priority: .background, purpose: "digest")
            let gated = try XCTUnwrap(engine as? GatedTextEngine)
            XCTAssertEqual(gated.origin, plan.consentKey)
            XCTAssertEqual(gated.priority, .background)
            switch plan {
            case .chatGPT: XCTAssertEqual((gated.base as? ChatGPTPlanEngine)?.model, "gpt-5.2")
            case .claude: XCTAssertEqual((gated.base as? ClaudePlanEngine)?.model, "sonnet")
            case .antigravity: XCTAssertEqual((gated.base as? AntigravityPlanEngine)?.model, "gemini-4-neon")
            case .gemini: XCTAssertEqual((gated.base as? GeminiPlanEngine)?.model, "gemini-3.5-flash")
            }
        }
    }

    func testAgentModeRunsOnTheChatGPTPlanOnly() {
        XCTAssertEqual(ThinkExecution.agentResolution(settings: settings(.chatGPT)), .chatGPTPlan(model: "gpt-5.2"))
        XCTAssertEqual(AgentSessionController.ModelContext(settings: settings(.chatGPT)).destination,
                       .remote(host: SubscriptionPlan.chatGPT.title))
        XCTAssertEqual(ThinkExecution.agentResolution(settings: settings(.chatGPT, approved: false)),
                       .unsupported(reason: SubscriptionPlanError.approvalRequired(.chatGPT).localizedDescription))
        var noModel = settings(.chatGPT)
        noModel.chatGPTPlanModel = ""
        XCTAssertEqual(ThinkExecution.agentResolution(settings: noModel),
                       .unsupported(reason: SubscriptionPlanError.noModel(.chatGPT).localizedDescription))
        for plan in [SubscriptionPlan.claude, .antigravity, .gemini] {
            guard case .unsupported(let reason) = ThinkExecution.agentResolution(settings: settings(plan)) else {
                return XCTFail("Agent Mode has no endpoint for \(plan)")
            }
            XCTAssertTrue(reason.contains(plan.title), "expected \(plan.title) in: \(reason)")
        }
    }

    func testDreamProvenanceNamesThePlanNotAnAccount() {
        for plan in SubscriptionPlan.allCases {
            let provenance = DreamInferenceProvenance(settings: settings(plan))
            XCTAssertEqual(provenance.location, .remote)
            XCTAssertEqual(provenance.origin, plan.consentKey)
            XCTAssertFalse(UpcomingMeetingLocalGenerationPolicy.permitsLocalGeneration(settings: settings(plan)),
                           "on-device-only briefs must not run on \(plan)")
        }
    }

    func testSettingsRoundTripAndLegacyDecode() throws {
        var original = settings(.antigravity)
        original.chatGPTPlanNoticeAcknowledged = true
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(decoded.summarizerBackend, .antigravityPlan)
        XCTAssertEqual(decoded.chatGPTPlanModel, "gpt-5.2")
        XCTAssertEqual(decoded.claudePlanModel, "sonnet")
        XCTAssertEqual(decoded.antigravityPlanModel, "gemini-4-neon")
        XCTAssertEqual(decoded.geminiPlanModel, "gemini-3.5-flash")
        XCTAssertTrue(decoded.chatGPTPlanNoticeAcknowledged)
        XCTAssertEqual(decoded.approvedRemoteInferenceOrigins, [SubscriptionPlan.antigravity.consentKey])
        XCTAssertTrue(decoded.corruptedSettingsKeys.isEmpty)

        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(AppSettings())) as? [String: Any])
        legacy.removeValue(forKey: "chatGPTPlanModel")
        legacy.removeValue(forKey: "claudePlanModel")
        legacy.removeValue(forKey: "antigravityPlanModel")
        legacy.removeValue(forKey: "geminiPlanModel")
        legacy.removeValue(forKey: "chatGPTPlanNoticeAcknowledged")
        let old = try JSONDecoder().decode(AppSettings.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertEqual(old.chatGPTPlanModel, "")
        XCTAssertEqual(old.antigravityPlanModel, "")
        XCTAssertEqual(old.geminiPlanModel, "")
        XCTAssertFalse(old.chatGPTPlanNoticeAcknowledged)
        XCTAssertTrue(old.corruptedSettingsKeys.isEmpty)
    }

    func testModelSwitchPatchCarriesOnlyThePlanModel() {
        let current = AppSettings()
        let patch = ModelSelectionPatch(backend: .antigravityPlan, antigravityPlanModel: "gemini-4-neon")
        let applied = patch.applying(to: current)
        XCTAssertEqual(applied.summarizerBackend, .antigravityPlan)
        XCTAssertEqual(applied.antigravityPlanModel, "gemini-4-neon")
        XCTAssertEqual(applied.chatGPTPlanModel, current.chatGPTPlanModel)
        XCTAssertEqual(applied.claudePlanModel, current.claudePlanModel)
        XCTAssertEqual(applied.geminiPlanModel, current.geminiPlanModel)
        XCTAssertEqual(applied.openAIModel, current.openAIModel)
        XCTAssertEqual(patch.inverse(in: current).applying(to: applied), current, "Undo restores the previous plan model")
        XCTAssertTrue(patch.matches(applied))
    }

    func testDisplayNamesAndContextWindows() {
        XCTAssertEqual(settings(.chatGPT).thinkModelDisplayName, "gpt-5.2 · ChatGPT plan")
        XCTAssertEqual(settings(.antigravity).thinkModelDisplayName, "gemini-4-neon · Antigravity plan")
        XCTAssertEqual(settings(.gemini).thinkModelDisplayName, "gemini-3.5-flash · Gemini plan")
        var defaultClaude = settings(.claude)
        defaultClaude.claudePlanModel = ""
        XCTAssertEqual(defaultClaude.thinkModelDisplayName, "Claude plan")
        var defaultAntigravity = settings(.antigravity)
        defaultAntigravity.antigravityPlanModel = ""
        XCTAssertEqual(defaultAntigravity.thinkModelDisplayName, "Antigravity plan")
        var defaultGemini = settings(.gemini)
        defaultGemini.geminiPlanModel = ""
        XCTAssertEqual(defaultGemini.thinkModelDisplayName, "Gemini plan")
        XCTAssertEqual(SubscriptionPlan.approvalDisplayName("chatgpt-plan://api.openai.com"),
                       "ChatGPT plan · api.openai.com")
        XCTAssertEqual(SubscriptionPlan.approvalDisplayName("antigravity-plan://antigravity.google"),
                       "Antigravity plan · antigravity.google")
        XCTAssertEqual(SubscriptionPlan.approvalDisplayName("gemini-plan://cloudcode-pa.googleapis.com"),
                       "Gemini plan · cloudcode-pa.googleapis.com")
        XCTAssertEqual(SubscriptionPlan.approvalDisplayName("https://openrouter.ai"), "https://openrouter.ai")
        XCTAssertEqual(MeetingSummaryGenerator.contextTokenLimit(for: settings(.chatGPT)), 128_000)
        XCTAssertEqual(MeetingSummaryGenerator.contextTokenLimit(for: settings(.claude)), 200_000)
        XCTAssertEqual(MeetingSummaryGenerator.contextTokenLimit(for: settings(.antigravity)), 200_000)
        var gptOss = settings(.antigravity)
        gptOss.antigravityPlanModel = "gpt-oss-120b-medium"
        XCTAssertEqual(MeetingSummaryGenerator.contextTokenLimit(for: gptOss), 128_000)
        XCTAssertEqual(MeetingSummaryGenerator.contextTokenLimit(for: settings(.gemini)), 1_000_000)
    }

    func testCheckIdentityFollowsPlanModelAndApproval() {
        for plan in SubscriptionPlan.allCases {
            let base = settings(plan)
            var otherModel = base
            switch plan {
            case .chatGPT: otherModel.chatGPTPlanModel = "gpt-5.1"
            case .claude: otherModel.claudePlanModel = "opus"
            case .antigravity: otherModel.antigravityPlanModel = "gemini-3.8-flash"
            case .gemini: otherModel.geminiPlanModel = "gemini-2.5-pro"
            }
            var revoked = base
            revoked.approvedRemoteInferenceOrigins = []
            let identity = ModelCheckIdentity(role: .think, settings: base, apiKey: "")
            XCTAssertNotEqual(identity, ModelCheckIdentity(role: .think, settings: otherModel, apiKey: ""))
            XCTAssertNotEqual(identity, ModelCheckIdentity(role: .think, settings: revoked, apiKey: ""))
        }
    }
}
