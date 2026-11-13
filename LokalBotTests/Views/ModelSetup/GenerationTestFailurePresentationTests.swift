import XCTest
@testable import LokalBot

final class GenerationTestFailurePresentationTests: XCTestCase {
    func testPrivateOpenRouterPolicyExplainsLocalRestriction() throws {
        let error = TextEngineError.httpStatus(
            code: 404,
            detail: "No endpoints found matching your data policy (Paid model training). "
                + "Configure: https://openrouter.ai/settings/privacy",
            retryAfter: nil)

        let presentation = GenerationTestFailurePresentation(
            error: error,
            baseURL: "https://openrouter.ai/api/v1",
            model: "deepseek/deepseek-v4-flash-vision-exp")

        XCTAssertEqual(presentation.kind, .openRouterDataPolicy)
        XCTAssertEqual(presentation.title, "No private endpoint for this model")
        XCTAssertTrue(presentation.explanation.contains("deepseek-v4-flash-vision-exp"))
        XCTAssertTrue(presentation.explanation.contains("LokalBot restricts OpenRouter"))
        XCTAssertTrue(presentation.recovery.contains("Provider data use"))
        XCTAssertTrue(presentation.privacyNote?.contains("recommended") == true)
        XCTAssertNil(presentation.actionTitle)
        XCTAssertNil(presentation.actionURL)
        XCTAssertTrue(presentation.technicalDetails.contains("HTTP 404"))
    }

    func testAccountOpenRouterPolicyLinksToEffectivePolicySettings() throws {
        let error = TextEngineError.httpStatus(
            code: 404,
            detail: "No endpoints found matching your data policy (Paid model training). "
                + "Configure: https://openrouter.ai/settings/privacy",
            retryAfter: nil)

        let presentation = GenerationTestFailurePresentation(
            error: error,
            baseURL: "https://openrouter.ai/api/v1",
            model: "deepseek/deepseek-v4-flash-vision-exp",
            openRouterDataPolicy: .accountPolicy)

        XCTAssertEqual(presentation.kind, .openRouterDataPolicy)
        XCTAssertEqual(presentation.title, "OpenRouter still blocks this model")
        XCTAssertTrue(presentation.explanation.contains("following your OpenRouter policy"))
        XCTAssertTrue(presentation.recovery.contains("guardrail"))
        XCTAssertTrue(presentation.privacyNote?.contains("cannot read") == true)
        XCTAssertEqual(
            presentation.actionURL,
            URL(string: "https://openrouter.ai/settings/privacy"))
    }

    func testDataPolicyTextFromAnotherServerDoesNotCreateOpenRouterLink() {
        let error = TextEngineError.httpStatus(
            code: 404,
            detail: "No endpoints found matching your data policy (Paid model training).",
            retryAfter: nil)

        let presentation = GenerationTestFailurePresentation(
            error: error,
            baseURL: "https://inference.example.com/v1",
            model: "example/model")

        XCTAssertEqual(presentation.kind, .generic)
        XCTAssertNil(presentation.actionTitle)
        XCTAssertNil(presentation.actionURL)
    }

    func testUnrelatedOpenRouterFailureKeepsGenericGuidanceAndFullError() {
        let error = TextEngineError.httpStatus(
            code: 401,
            detail: "Invalid API key",
            retryAfter: nil)

        let presentation = GenerationTestFailurePresentation(
            error: error,
            baseURL: "https://openrouter.ai/api/v1",
            model: "deepseek/deepseek-v4-flash-vision-exp")

        XCTAssertEqual(presentation.kind, .generic)
        XCTAssertEqual(presentation.title, "Generation test failed")
        XCTAssertNil(presentation.actionURL)
        XCTAssertEqual(
            presentation.technicalDetails,
            "LLM server returned HTTP 401: Invalid API key")
    }
}
