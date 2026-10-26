import XCTest
@testable import LokalBot

@MainActor
final class SubscriptionPlanSettingsTests: XCTestCase {
    private func settings(_ plan: SubscriptionPlan, approved: Bool = true) -> AppSettings {
        var settings = AppSettings()
        settings.summarizerBackend = plan.backend
        settings.chatGPTPlanModel = "gpt-5.2"
        settings.claudePlanModel = "sonnet"
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
        viaAPI.approvedRemoteInferenceOrigins = ["https://api.openai.com", "https://api.anthropic.com"]
        XCTAssertFalse(viaAPI.usesRemoteMainLLM)
        viaAPI.summarizerBackend = .claudePlan
        XCTAssertFalse(viaAPI.usesRemoteMainLLM)

        var viaPlan = AppSettings()
        viaPlan.summarizerBackend = .openAICompatible
        viaPlan.openAIBaseURL = "https://api.openai.com/v1"
        viaPlan.approvedRemoteInferenceOrigins = SubscriptionPlan.allCases.map(\.consentKey)
        XCTAssertFalse(viaPlan.usesRemoteMainLLM)
        XCTAssertFalse(InferenceEndpointPolicy.isAllowed(
            URL(string: "https://api.openai.com/v1")!, approvedOrigins: viaPlan.approvedRemoteInferenceOrigins))

        let chatGPTOnly = settings(.chatGPT)
        var claude = chatGPTOnly
        claude.summarizerBackend = .claudePlan
        XCTAssertFalse(claude.usesRemoteMainLLM, "each plan has its own approval")
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
        guard case .unsupported(let reason) = ThinkExecution.agentResolution(settings: settings(.claude)) else {
            return XCTFail("Agent Mode has no endpoint for the Claude plan")
        }
        XCTAssertTrue(reason.contains(SubscriptionPlan.claude.title))
    }

    func testDreamProvenanceNamesThePlanNotAnAccount() {
        let provenance = DreamInferenceProvenance(settings: settings(.claude))
        XCTAssertEqual(provenance.location, .remote)
        XCTAssertEqual(provenance.origin, "claude-plan://api.anthropic.com")
        XCTAssertFalse(UpcomingMeetingLocalGenerationPolicy.permitsLocalGeneration(settings: settings(.chatGPT)),
                       "on-device-only briefs must not run on a plan")
    }

    func testSettingsRoundTripAndLegacyDecode() throws {
        var original = settings(.chatGPT)
        original.chatGPTPlanNoticeAcknowledged = true
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(decoded.summarizerBackend, .chatGPTPlan)
        XCTAssertEqual(decoded.chatGPTPlanModel, "gpt-5.2")
        XCTAssertEqual(decoded.claudePlanModel, "sonnet")
        XCTAssertTrue(decoded.chatGPTPlanNoticeAcknowledged)
        XCTAssertEqual(decoded.approvedRemoteInferenceOrigins, [SubscriptionPlan.chatGPT.consentKey])
        XCTAssertTrue(decoded.corruptedSettingsKeys.isEmpty)

        // A blob from a build before plans keeps every default silently.
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(AppSettings())) as? [String: Any])
        legacy.removeValue(forKey: "chatGPTPlanModel")
        legacy.removeValue(forKey: "claudePlanModel")
        legacy.removeValue(forKey: "chatGPTPlanNoticeAcknowledged")
        let old = try JSONDecoder().decode(AppSettings.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertEqual(old.chatGPTPlanModel, "")
        XCTAssertFalse(old.chatGPTPlanNoticeAcknowledged)
        XCTAssertTrue(old.corruptedSettingsKeys.isEmpty)
    }

    func testModelSwitchPatchCarriesOnlyThePlanModel() {
        let current = AppSettings()
        let patch = ModelSelectionPatch(backend: .claudePlan, claudePlanModel: "opus")
        let applied = patch.applying(to: current)
        XCTAssertEqual(applied.summarizerBackend, .claudePlan)
        XCTAssertEqual(applied.claudePlanModel, "opus")
        XCTAssertEqual(applied.chatGPTPlanModel, current.chatGPTPlanModel)
        XCTAssertEqual(applied.openAIModel, current.openAIModel)
        XCTAssertEqual(patch.inverse(in: current).applying(to: applied), current, "Undo restores the previous plan model")
        XCTAssertTrue(patch.matches(applied))
    }

    func testDisplayNamesAndContextWindows() {
        XCTAssertEqual(settings(.chatGPT).thinkModelDisplayName, "gpt-5.2 · ChatGPT plan")
        var defaultClaude = settings(.claude)
        defaultClaude.claudePlanModel = ""
        XCTAssertEqual(defaultClaude.thinkModelDisplayName, "Claude plan")
        XCTAssertEqual(SubscriptionPlan.approvalDisplayName("chatgpt-plan://api.openai.com"),
                       "ChatGPT plan · api.openai.com")
        XCTAssertEqual(SubscriptionPlan.approvalDisplayName("https://openrouter.ai"), "https://openrouter.ai")
        XCTAssertEqual(MeetingSummaryGenerator.contextTokenLimit(for: settings(.chatGPT)), 128_000)
        XCTAssertEqual(MeetingSummaryGenerator.contextTokenLimit(for: settings(.claude)), 200_000)
    }

    func testCheckIdentityFollowsPlanModelAndApproval() {
        let base = settings(.chatGPT)
        var otherModel = base
        otherModel.chatGPTPlanModel = "gpt-5.1"
        var revoked = base
        revoked.approvedRemoteInferenceOrigins = []
        let identity = ModelCheckIdentity(role: .think, settings: base, apiKey: "")
        XCTAssertNotEqual(identity, ModelCheckIdentity(role: .think, settings: otherModel, apiKey: ""))
        XCTAssertNotEqual(identity, ModelCheckIdentity(role: .think, settings: revoked, apiKey: ""))
    }
}
