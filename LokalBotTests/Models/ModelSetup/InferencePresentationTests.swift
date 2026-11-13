import XCTest
@testable import LokalBot

final class InferencePresentationTests: XCTestCase {
    func testLocalRemoteAndBlockedAreDistinct() {
        var settings = AppSettings()
        XCTAssertEqual(InferencePresentation(settings: settings), .onDevice)
        settings.summarizerBackend = .openAICompatible
        settings.openAIBaseURL = "https://models.example.test/v1"
        XCTAssertTrue(InferencePresentation(settings: settings).isBlocked)
        settings.approvedRemoteInferenceOrigins = ["https://models.example.test"]
        XCTAssertEqual(InferencePresentation(settings: settings), .remote(host: "models.example.test"))
        settings.openAIBaseURL = "http://models.example.test/v1"
        XCTAssertTrue(InferencePresentation(settings: settings).isBlocked)
        settings.openAIBaseURL = "http://127.0.0.1:1234/v1"
        XCTAssertEqual(InferencePresentation(settings: settings), .onDevice)
        settings.openAIBaseURL = "not a server"
        XCTAssertTrue(InferencePresentation(settings: settings).isBlocked)
    }
}
