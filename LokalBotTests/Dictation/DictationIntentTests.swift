import XCTest
@testable import LokalBot

@MainActor
final class DictationIntentTests: XCTestCase {
    func testTranscribeNeverConstructsModelOrReadsContext() async throws {
        var settings = AppSettings()
        settings.dictationIntent = .transcribe
        settings.dictationUseScreenContext = true // Even a stale stored opt-in cannot widen Transcribe.
        var contextReads = 0, modelCreations = 0
        let result = try await DictationTextPreparation.prepare(speech: "Recognized speech.", settings: settings,
            screenContext: { contextReads += 1; return nil }, makeEngine: { _ in modelCreations += 1; return IntentTestEngine() })
        XCTAssertEqual(result.text, "Recognized speech.")
        XCTAssertNil(result.compositionModel)
        XCTAssertEqual(contextReads, 0)
        XCTAssertEqual(modelCreations, 0)
    }

    func testComposeUsesFrozenConfigurationAndOnlyChosenContext() async throws {
        var configuration = AppSettings()
        configuration.dictationIntent = .compose
        configuration.dictationUseScreenContext = false
        configuration.openAIBaseURL = "https://reviewed.example/v1"
        var contextReads = 0
        var received: AppSettings?
        let engine = IntentTestEngine()
        let result = try await DictationTextPreparation.prepare(speech: "Draft a reply", settings: configuration,
            screenContext: { contextReads += 1; return nil }, makeEngine: { received = $0; return engine })
        XCTAssertEqual(received, configuration)
        XCTAssertEqual(contextReads, 0)
        XCTAssertEqual(engine.calls, 1)
        XCTAssertEqual(result.text, "Reviewed draft")
        XCTAssertEqual(result.compositionModel, "Synthetic model")
    }

    func testCancellationCannotReturnLateComposition() async throws {
        var configuration = AppSettings()
        configuration.dictationIntent = .compose
        let task = Task {
            try await DictationTextPreparation.prepare(speech: "Draft", settings: configuration,
                screenContext: { nil }, makeEngine: { _ in IntentTestEngine() })
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled composition returned output") } catch is CancellationError { } catch { XCTFail("Unexpected error: \(error)") }
    }
}

private final class IntentTestEngine: TextEngine {
    var calls = 0
    var displayName: String { "Synthetic model" }
    func generate(system: String, prompt: String, context: [String]) async throws -> String {
        calls += 1
        return "Reviewed draft"
    }
}
