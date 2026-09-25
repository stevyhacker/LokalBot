import XCTest
@testable import LokalBot

// MARK: - Scripted engine

/// Records every request and returns (or throws) a canned result, so the
/// coordinator's engine-facing paths run without a model or server.
@MainActor
private final class ScriptedCotypingEngine: CotypingCompleting {
    var result: Result<String, Error> = .success("")
    private(set) var requests: [CotypingRequest] = []

    func generate(_ request: CotypingRequest) async throws -> CotypingNormalizationResult {
        requests.append(request)
        return CotypingNormalizationResult(text: try result.get(), suppression: nil)
    }
}

private struct EngineBoom: Error {}

private final class CotypingSettingsBox {
    var value: AppSettings

    init(_ value: AppSettings) {
        self.value = value
    }
}

// MARK: - Coordinator

/// Most of the coordinator needs live AX + event taps, so these tests pin the
/// paths that run before any permission check: the settings gate in
/// `applySettings()` (which must bail out without touching AX) and the
/// permission-free `previewSuggestion` pipeline the in-app playground uses.
@MainActor
final class CotypingCoordinatorTests: XCTestCase {
    private var tempDir: URL!
    private var engine: ScriptedCotypingEngine!
    private var settings = AppSettings()

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lokalbot-cotyping-coordinator-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        engine = ScriptedCotypingEngine()
        settings = AppSettings()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeCoordinator() -> CotypingCoordinator {
        CotypingCoordinator(
            engine: engine,
            settingsProvider: { [settings] in settings },
            learningStore: CotypingLearningStore(storageRoot: tempDir),
            selfBundleID: "me.dotenv.LokalBot.tests")
    }

    private func makeCoordinator(settingsBox: CotypingSettingsBox) -> CotypingCoordinator {
        CotypingCoordinator(
            engine: engine,
            settingsProvider: { settingsBox.value },
            learningStore: CotypingLearningStore(storageRoot: tempDir),
            selfBundleID: "me.dotenv.LokalBot.tests")
    }

    func testApplySettingsWithCotypingOffDisablesWithoutRunning() {
        settings.cotypingEnabled = false
        let coordinator = makeCoordinator()

        coordinator.applySettings()

        XCTAssertFalse(coordinator.isRunning)
        XCTAssertEqual(coordinator.state, .disabled("Cotyping is off."))
    }

    func testStopWithoutReasonReturnsToIdle() {
        settings.cotypingEnabled = false
        let coordinator = makeCoordinator()
        coordinator.applySettings()

        coordinator.stop()

        XCTAssertFalse(coordinator.isRunning)
        XCTAssertEqual(coordinator.state, .idle)
    }

    func testExclusionChangesRefreshCachedAppReadPolicy() {
        defer { CotypingAXHelper.configureAppReadPolicy(CotypingAppReadPolicy()) }
        settings.cotypingEnabled = true
        let box = CotypingSettingsBox(settings)
        let coordinator = makeCoordinator(settingsBox: box)
        coordinator.applySettings()

        box.value.cotypingExcludedApps = "Mail"
        coordinator.applySettings()

        let expected = CotypingAppReadPolicy(
            enabled: true,
            excludedApps: ["Mail"],
            selfBundleID: "me.dotenv.LokalBot.tests")
        XCTAssertFalse(
            CotypingAXHelper.configureAppReadPolicy(expected),
            "applySettings must install the updated exclusion policy before the next AX read")
    }

    func testAppStateReconcilesCotypingWhenExclusionListsChange() {
        var original = AppSettings()
        original.cotypingEnabled = true

        var changed = original
        changed.cotypingExcludedApps = "Mail"
        XCTAssertTrue(AppState.cotypingLifecycleChanged(from: original, to: changed))

        changed = original
        changed.cotypingExcludedDomains = "bank.example"
        XCTAssertTrue(AppState.cotypingLifecycleChanged(from: original, to: changed))
    }

    func testPreviewSuggestionRunsThePipelineAgainstTheEngine() async throws {
        engine.result = .success("ld, how are you?")

        let text = try await makeCoordinator()
            .previewSuggestion(precedingText: "Hello wor", trailingText: "ld!")

        XCTAssertEqual(text, "ld, how are you?")
        XCTAssertEqual(engine.requests.count, 1)
        let request = try XCTUnwrap(engine.requests.first)
        XCTAssertTrue(request.prefixText.hasSuffix("Hello wor"),
                      "the caret prefix must reach the engine")
        XCTAssertTrue(request.prompt.contains("Hello wor"))
        XCTAssertEqual(request.trailingText, "ld!")
        XCTAssertTrue(request.forceWordContinuation,
                      "word characters on both sides of the caret must force word continuation")
    }

    func testPreviewSuggestionWithBlankPrefixSkipsTheEngine() async throws {
        let text = try await makeCoordinator()
            .previewSuggestion(precedingText: "   \n  ")

        XCTAssertEqual(text, "")
        XCTAssertTrue(engine.requests.isEmpty,
                      "a blank-before-caret field must never hit the model")
    }

    func testSetupCheckUsesSampleTextWithoutPersonalization() async throws {
        settings.cotypingUserName = "PRIVATE TEST NAME"
        settings.cotypingStyleNote = "PRIVATE STYLE NOTE"
        settings.cotypingExtendedContext = "PRIVATE VOCABULARY"
        let coordinator = makeCoordinator()

        _ = try await coordinator.previewSuggestion(precedingText: "The local model setup is", sampleOnly: true)
        let sample = try XCTUnwrap(engine.requests.last)
        XCTAssertTrue(sample.prompt.contains("The local model setup is"))
        XCTAssertFalse(sample.prompt.contains("PRIVATE TEST NAME"))
        XCTAssertFalse(sample.prompt.contains("PRIVATE STYLE NOTE"))
        XCTAssertFalse(sample.prompt.contains("PRIVATE VOCABULARY"))

        _ = try await coordinator.previewSuggestion(precedingText: "The local model setup is")
        let personalized = try XCTUnwrap(engine.requests.last)
        XCTAssertTrue(personalized.prompt.contains("PRIVATE TEST NAME"))
        XCTAssertTrue(personalized.prompt.contains("PRIVATE VOCABULARY"))
    }

    func testPreviewSuggestionPropagatesEngineFailure() async {
        engine.result = .failure(EngineBoom())

        do {
            _ = try await makeCoordinator().previewSuggestion(precedingText: "Hello wor")
            XCTFail("an engine failure must surface to the playground caller")
        } catch is EngineBoom {
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }
}
