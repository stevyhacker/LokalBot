import XCTest
@testable import LokalBot

@MainActor
final class ModelSettingsTests: XCTestCase {
    private enum PreparationFailure: LocalizedError {
        case expected
        var errorDescription: String? { "Expected download failure" }
    }

    private actor Gate {
        private var released = false
        private var waiter: CheckedContinuation<Void, Never>?
        func wait() async {
            if released { return }
            await withCheckedContinuation { waiter = $0 }
        }
        func release() {
            released = true
            waiter?.resume()
            waiter = nil
        }
    }

    func testSwitchWaitsForPreparationAndPreservesConcurrentPreferenceEdits() async {
        var settings = AppSettings()
        let original = settings.builtInModelID
        let gate = Gate()
        let controller = ModelSetupController(settings: { settings }, update: { settings = $0 }) { _, _ in
            await gate.wait()
        }
        controller.apply(.init(backend: .builtIn, assistantModelID: "replacement"), title: "Replacement")

        XCTAssertEqual(settings.builtInModelID, original)
        XCTAssertNotNil(controller.pending)
        settings.summaryLanguage = .en
        settings.approvedRemoteInferenceOrigins = ["https://approved.example"]
        let concurrent = settings
        await gate.release()
        await waitUntil { controller.pending == nil }

        XCTAssertEqual(settings.builtInModelID, "replacement")
        XCTAssertEqual(settings.summaryLanguage, concurrent.summaryLanguage)
        XCTAssertEqual(settings.approvedRemoteInferenceOrigins, concurrent.approvedRemoteInferenceOrigins)
        XCTAssertNil(controller.failure)
    }

    func testFailedDownloadLeavesCurrentSetupUntouched() async {
        var settings = AppSettings()
        let original = settings
        let controller = ModelSetupController(settings: { settings }, update: { settings = $0 }) { _, _ in
            throw PreparationFailure.expected
        }
        controller.apply(.init(autocompleteModelID: "replacement"), title: "Replacement")
        await waitUntil { controller.pending == nil }

        XCTAssertEqual(settings, original)
        XCTAssertEqual(controller.failure, "Expected download failure")
        XCTAssertNotNil(controller.failedChange)
        XCTAssertNil(controller.completed)
    }

    func testNewerSelectionWinsWhenDownloadCompletes() async {
        var settings = AppSettings()
        let gate = Gate()
        let controller = ModelSetupController(settings: { settings }, update: { settings = $0 }) { _, _ in
            await gate.wait()
        }
        controller.apply(.init(autocompleteModelID: "downloaded-choice"), title: "Downloaded choice")
        settings.cotypingBuiltInModelID = "newer-choice"
        await gate.release()
        await waitUntil { controller.pending == nil }

        XCTAssertEqual(settings.cotypingBuiltInModelID, "newer-choice")
        XCTAssertTrue(controller.failure?.contains("newer selection was kept") == true)
    }

    func testCancelledSwitchCannotApplyALateDownload() async {
        var settings = AppSettings()
        let original = settings
        let gate = Gate()
        var prepared = false
        let controller = ModelSetupController(settings: { settings }, update: { settings = $0 }) { _, _ in
            await gate.wait()
            prepared = true
        }
        controller.apply(.init(autocompleteModelID: "replacement"), title: "Replacement")
        await Task.yield()
        controller.cancelSwitch()
        await gate.release()
        await waitUntil { prepared }
        await Task.yield()

        XCTAssertEqual(settings, original)
        XCTAssertNil(controller.pending)
        XCTAssertNil(controller.completed)
        XCTAssertNil(controller.failure)
    }

    func testChangedServerCannotActivateAPendingRemoteSwitch() async {
        var settings = AppSettings()
        settings.summarizerBackend = .builtIn
        settings.openAIBaseURL = "https://first.example/v1"
        settings.approvedRemoteInferenceOrigins = ["https://first.example", "https://second.example"]
        let gate = Gate()
        let controller = ModelSetupController(settings: { settings }, update: { settings = $0 }) { _, _ in
            await gate.wait()
        }
        controller.apply(.init(backend: .openAICompatible, remoteModel: "replacement"), title: "Remote replacement")
        settings.openAIBaseURL = "https://second.example/v1"
        await gate.release()
        await waitUntil { controller.pending == nil }

        XCTAssertEqual(settings.summarizerBackend, .builtIn)
        XCTAssertEqual(settings.openAIBaseURL, "https://second.example/v1")
        XCTAssertTrue(controller.failure?.contains("connection changed") == true)
    }

    func testRevokedApprovalCannotActivateAPendingRemoteSwitch() async {
        var settings = AppSettings()
        settings.summarizerBackend = .builtIn
        settings.openAIBaseURL = "https://models.example/v1"
        settings.approvedRemoteInferenceOrigins = ["https://models.example"]
        let gate = Gate()
        let controller = ModelSetupController(settings: { settings }, update: { settings = $0 }) { _, _ in
            await gate.wait()
        }
        controller.apply(.init(backend: .openAICompatible, remoteModel: "replacement"), title: "Remote replacement")
        settings.approvedRemoteInferenceOrigins = []
        await gate.release()
        await waitUntil { controller.pending == nil }

        XCTAssertEqual(settings.summarizerBackend, .builtIn)
        XCTAssertTrue(settings.approvedRemoteInferenceOrigins.isEmpty)
        XCTAssertNotNil(controller.failure)
    }

    func testChangedCustomModelFilesCannotActivateAPreparedID() async {
        var settings = AppSettings()
        let originalID = settings.cotypingBuiltInModelID
        settings.customBuiltInModels = [customEntry(file: "first.gguf")]
        let gate = Gate()
        let controller = ModelSetupController(settings: { settings }, update: { settings = $0 }) { _, _ in
            await gate.wait()
        }
        controller.apply(.init(autocompleteModelID: "custom-test"), title: "Custom replacement")
        settings.customBuiltInModels = [customEntry(file: "second.gguf")]
        await gate.release()
        await waitUntil { controller.pending == nil }

        XCTAssertEqual(settings.cotypingBuiltInModelID, originalID)
        XCTAssertEqual(settings.customBuiltInModels.first?.fileName, "second.gguf")
        XCTAssertTrue(controller.failure?.contains("model files or connection changed") == true)
    }

    func testUndoRestoresOnlyTheChangedAssignments() async {
        var settings = AppSettings()
        let originalID = settings.cotypingBuiltInModelID
        let controller = ModelSetupController(settings: { settings }, update: { settings = $0 }) { _, _ in }
        controller.apply(.init(autocompleteModelID: "replacement"), title: "Replacement")
        await waitUntil { controller.pending == nil }
        settings.openAIBaseURL = "https://new.example/v1"
        settings.approvedRemoteInferenceOrigins = ["https://new.example"]
        settings.speechSpeed = 1.5

        controller.undo()
        await waitUntil { controller.pending == nil }

        XCTAssertEqual(settings.cotypingBuiltInModelID, originalID)
        XCTAssertEqual(settings.openAIBaseURL, "https://new.example/v1")
        XCTAssertEqual(settings.approvedRemoteInferenceOrigins, ["https://new.example"])
        XCTAssertEqual(settings.speechSpeed, 1.5)
    }

    func testPreparingAlreadySelectedMissingModelStillRunsPreparation() async {
        var settings = AppSettings()
        var didPrepare = false
        let controller = ModelSetupController(settings: { settings }, update: { settings = $0 }) { _, _ in didPrepare = true }
        controller.apply(.init(autocompleteModelID: settings.cotypingBuiltInModelID), title: "Current model")
        await waitUntil { controller.pending == nil }
        XCTAssertTrue(didPrepare)
    }

    func testPresetMatchingDoesNotDescribeACustomRemoteSetupAsLocal() {
        var settings = ModelStackPreset.recommended.patch.applying(to: AppSettings())
        XCTAssertEqual(ModelStackPreset.matching(settings), .recommended)
        settings.summarizerBackend = .openAICompatible
        XCTAssertNil(ModelStackPreset.matching(settings))
        settings = ModelStackPreset.recommended.patch.applying(to: settings)
        settings.cotypingBuiltInModelID = "different"
        XCTAssertNil(ModelStackPreset.matching(settings))
    }

    func testPresetPreservesIndependentDictationModelAndConnectionApprovals() {
        var settings = AppSettings()
        settings.dictationCompositionBuiltInModelID = "qwen3.5-2b"
        settings.approvedRemoteInferenceOrigins = ["https://approved.example"]
        settings.openAIModel = "keep-this-model"
        let result = ModelStackPreset.lightweight.patch.applying(to: settings)

        XCTAssertEqual(result.dictationCompositionBuiltInModelID, "qwen3.5-2b")
        XCTAssertEqual(result.approvedRemoteInferenceOrigins, ["https://approved.example"])
        XCTAssertEqual(result.openAIModel, "keep-this-model")
    }

    func testSharedModelDownloadsAreDeduplicated() {
        let patch = ModelSelectionPatch(backend: .builtIn, assistantModelID: "same",
                                        autocompleteModelID: "same", dictationModelID: "same")
        XCTAssertEqual(patch.localModelIDs(in: AppSettings()), ["same"])
    }

    func testDictationInheritanceShowsTheEffectiveRemoteDestination() {
        var settings = AppSettings()
        settings.summarizerBackend = .openAICompatible
        settings.openAIBaseURL = "https://openrouter.ai/api/v1"
        settings.openAIModel = "z-ai/glm-5.3-flash"
        settings.approvedRemoteInferenceOrigins = ["https://openrouter.ai"]
        settings.dictationCompositionBuiltInModelID = ""
        XCTAssertEqual(ModelSettingsPresentation.dictationLabel(settings), "Uses Think · OpenRouter")

        settings.dictationCompositionBuiltInModelID = "qwen3.5-2b"
        XCTAssertTrue(ModelSettingsPresentation.dictationLabel(settings).contains("On this Mac"))
        settings.dictationCompositionBuiltInModelID = "removed-custom-model"
        XCTAssertEqual(ModelSettingsPresentation.dictationLabel(settings), "Uses Think · OpenRouter")
    }

    func testModelUsageIncludesInheritedDictation() {
        var settings = AppSettings()
        settings.summarizerBackend = .builtIn
        settings.builtInModelID = "shared"
        settings.cotypingBuiltInModelID = "shared"
        settings.dictationCompositionBuiltInModelID = ""
        XCTAssertEqual(ModelSettingsPresentation.uses(of: "shared", in: settings),
                       ["Think", "Autocomplete", "Dictation composition"])
    }

    func testCheckIdentityIgnoresUnrelatedPreferencesButTracksRelevantChanges() {
        var settings = AppSettings()
        settings.transcriptionModel = .graniteSpeech
        let original = ModelCheckIdentity(role: .transcribe, settings: settings)
        for _ in 0..<10 { XCTAssertEqual(original, ModelCheckIdentity(role: .transcribe, settings: settings)) }
        settings.speechSpeed = 1.5
        settings.cotypingBuiltInModelID = "another"
        XCTAssertEqual(original, ModelCheckIdentity(role: .transcribe, settings: settings))
        settings.transcriptionLanguage = .en
        XCTAssertNotEqual(original, ModelCheckIdentity(role: .transcribe, settings: settings))
    }

    func testRemoteCheckIdentityTracksCredentialAndApprovalChangesWithoutStoringTheKey() {
        var settings = AppSettings()
        settings.summarizerBackend = .openAICompatible
        settings.openAIBaseURL = "https://models.example/v1"
        settings.openAIModel = "example"
        settings.approvedRemoteInferenceOrigins = ["https://models.example"]
        let first = ModelCheckIdentity(role: .think, settings: settings, apiKey: "synthetic-first-key")
        let second = ModelCheckIdentity(role: .think, settings: settings, apiKey: "synthetic-second-key")
        XCTAssertNotEqual(first, second)
        XCTAssertFalse(first.parts.joined().contains("synthetic-first-key"))
        settings.approvedRemoteInferenceOrigins = []
        XCTAssertNotEqual(first, ModelCheckIdentity(role: .think, settings: settings, apiKey: "synthetic-first-key"))
    }

    private func waitUntil(_ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(2)
        while !condition(), Date() < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(condition(), "Timed out waiting for model setup")
    }

    private func customEntry(file: String) -> ModelCatalog.Entry {
        .init(id: "custom-test", displayName: "Custom test", fileName: file,
              url: "https://models.example/\(file)", sizeGB: 1, blurb: "Test fixture", disablesThinking: false)
    }
}
