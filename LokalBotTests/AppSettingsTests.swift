import XCTest
@testable import LokalBot

final class AppSettingsTests: XCTestCase {
    func testDecodesLegacyLanguageHintIntoTypedLanguage() throws {
        let data = #"{"languageHint":"fr"}"#.data(using: .utf8)!

        let settings = try JSONDecoder().decode(AppSettings.self, from: data)

        XCTAssertEqual(settings.transcriptionLanguage, .fr)
    }

    func testEncodesTypedLanguageWithoutLegacyHintKey() throws {
        var settings = AppSettings()
        settings.transcriptionLanguage = .es

        let data = try JSONEncoder().encode(settings)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(object["transcriptionLanguage"] as? String, "es")
        XCTAssertNil(object["languageHint"])
    }

    func testTranscriptionPromptDefaultsEmptyAndRoundTrips() throws {
        XCTAssertEqual(AppSettings().transcriptionPrompt, "")

        var settings = AppSettings()
        settings.transcriptionPrompt = "LokalBot, QVAC, Stevan"
        let decoded = try JSONDecoder().decode(
            AppSettings.self,
            from: JSONEncoder().encode(settings))

        XCTAssertEqual(decoded.transcriptionPrompt, "LokalBot, QVAC, Stevan")
    }

    func testOlderSettingsDefaultToEmptyTranscriptionPrompt() throws {
        let settings = try JSONDecoder().decode(
            AppSettings.self,
            from: Data(#"{"autoTranscribe":true}"#.utf8))

        XCTAssertEqual(settings.transcriptionPrompt, "")
    }

    func testMenuBarOnlyDefaultsTrue() {
        XCTAssertTrue(AppSettings().menuBarOnly)
    }

    func testThinkModelDisplayNameFollowsSelectedBackendNotLeftoverLocalID() {
        var settings = AppSettings()
        settings.builtInModelID = ModelCatalog.defaultSummarizationID
        XCTAssertEqual(settings.thinkModelDisplayName, "Qwen3.5 4B")

        settings.summarizerBackend = .openAICompatible
        settings.openAIModel = "z-ai/glm-5.3"
        XCTAssertEqual(
            settings.thinkModelDisplayName, "z-ai/glm-5.3",
            "Core roles must not keep showing the leftover local Think model")

        settings.openAIModel = "  "
        XCTAssertEqual(settings.thinkModelDisplayName,
                       AppSettings.SummarizerBackend.openAICompatible.displayName)

        settings.summarizerBackend = .ollama
        settings.ollamaModel = "llama3.1"
        XCTAssertEqual(settings.thinkModelDisplayName, "llama3.1")

        settings.summarizerBackend = .appleIntelligence
        XCTAssertEqual(settings.thinkModelDisplayName, "Apple Intelligence")
    }

    func testUsesRemoteMainLLMRequiresApprovedRemoteEndpoint() {
        var settings = AppSettings()
        XCTAssertFalse(settings.usesRemoteMainLLM, "built-in Think is local")

        settings.summarizerBackend = .ollama
        XCTAssertFalse(settings.usesRemoteMainLLM, "loopback Ollama is local")

        settings.ollamaBaseURL = "https://inference.example.com"
        XCTAssertFalse(settings.usesRemoteMainLLM, "configured is not approved")
        settings.approvedRemoteInferenceOrigins = ["https://inference.example.com"]
        XCTAssertTrue(settings.usesRemoteMainLLM)

        settings.summarizerBackend = .openAICompatible
        XCTAssertFalse(settings.usesRemoteMainLLM, "loopback LM Studio default is local")

        settings.openAIBaseURL = "https://api.example.com/v1"
        XCTAssertFalse(settings.usesRemoteMainLLM, "approval is origin-specific")
        settings.approvedRemoteInferenceOrigins.append("https://api.example.com")
        XCTAssertTrue(settings.usesRemoteMainLLM)

        settings.openAIBaseURL = "http://api.example.com/v1"
        settings.approvedRemoteInferenceOrigins.append("http://api.example.com")
        XCTAssertFalse(settings.usesRemoteMainLLM, "insecure remote inference stays blocked")

        settings.summarizerBackend = .appleIntelligence
        XCTAssertFalse(settings.usesRemoteMainLLM, "Apple Intelligence is on-device")
    }

    func testOpenRouterDataPolicyDefaultsPrivateForLegacySettings() throws {
        XCTAssertEqual(AppSettings().openRouterDataPolicy, .privateOnly)

        let legacyData = #"{"openAIBaseURL":"https://openrouter.ai/api/v1"}"#
            .data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AppSettings.self, from: legacyData)

        XCTAssertEqual(decoded.openRouterDataPolicy, .privateOnly)
        XCTAssertTrue(decoded.corruptedSettingsKeys.isEmpty)
    }

    func testOpenRouterAccountPolicyRoundTrips() throws {
        var settings = AppSettings()
        settings.openRouterDataPolicy = .accountPolicy

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)

        XCTAssertEqual(decoded.openRouterDataPolicy, .accountPolicy)
    }

    func testUnknownOpenRouterDataPolicyFallsBackPrivateAndIsReported() throws {
        let data = #"{"openRouterDataPolicy":"future-policy"}"#.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)

        XCTAssertEqual(decoded.openRouterDataPolicy, .privateOnly)
        XCTAssertTrue(decoded.corruptedSettingsKeys.contains("openRouterDataPolicy"))
    }

    func testMultiSpeakerDiarizationDefaultsTrue() {
        XCTAssertTrue(AppSettings().multiSpeakerDiarization)
    }

    // MARK: - Decode-fallback audit

    func testAbsentKeysAreNotReportedAsCorruption() throws {
        // An older build's blob simply lacks newer keys — that is the normal
        // tolerant-decoding case and must stay silent.
        let data = #"{"autoTranscribe":true}"#.data(using: .utf8)!
        let settings = try JSONDecoder().decode(AppSettings.self, from: data)

        XCTAssertTrue(settings.corruptedSettingsKeys.isEmpty)
    }

    func testCorruptFieldFallsBackToDefaultAndIsReported() throws {
        // Key present but the value is the wrong shape: the field resets to
        // its default, and — because a silently flipped privacy setting is a
        // real event — the reset is recorded by name.
        let data = #"{"screenContextCaptureMode":42,"autoTranscribe":"yes"}"#
            .data(using: .utf8)!
        let settings = try JSONDecoder().decode(AppSettings.self, from: data)

        let defaults = AppSettings()
        XCTAssertEqual(settings.screenContextCaptureMode, defaults.screenContextCaptureMode)
        XCTAssertEqual(settings.autoTranscribe, defaults.autoTranscribe)
        XCTAssertEqual(Set(settings.corruptedSettingsKeys),
                       ["screenContextCaptureMode", "autoTranscribe"])
    }

    func testHealthyRoundTripReportsNoCorruption() throws {
        var original = AppSettings()
        original.autoRecordMode = .ask
        original.retentionDays = 7

        let decoded = try JSONDecoder().decode(
            AppSettings.self, from: JSONEncoder().encode(original))

        XCTAssertTrue(decoded.corruptedSettingsKeys.isEmpty)
        XCTAssertEqual(decoded.autoRecordMode, .ask)
        XCTAssertEqual(decoded.retentionDays, 7)
    }

    func testCorruptedKeysAreNeverPersisted() throws {
        var settings = AppSettings()
        settings.corruptedSettingsKeys = ["autoTranscribe"]

        let data = try JSONEncoder().encode(settings)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertNil(object["corruptedSettingsKeys"],
                     "the audit is transient — one notice, not a sticky flag")
    }

    func testWholeStoreCorruptionResetsWithMarker() throws {
        let suiteName = "AppSettingsTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }

        // No stored blob at all: a genuine first run, nothing to report.
        XCTAssertTrue(AppSettings.load(from: defaults).corruptedSettingsKeys.isEmpty)

        // Unreadable blob: reset to defaults, but say so.
        defaults.set(Data("not json".utf8), forKey: AppSettings.key)
        let reset = AppSettings.load(from: defaults)
        XCTAssertEqual(reset.corruptedSettingsKeys,
                       [AppSettings.wholeStoreCorruptionMarker])
        XCTAssertEqual(reset.autoRecordMode, AppSettings().autoRecordMode)
    }

    func testSemanticSearchDefaultsOnButPreservesAnExplicitOffChoice() throws {
        XCTAssertTrue(AppSettings().semanticSearchEnabled)

        let data = #"{"semanticSearchEnabled":false}"#.data(using: .utf8)!
        let settings = try JSONDecoder().decode(AppSettings.self, from: data)

        XCTAssertFalse(settings.semanticSearchEnabled)
    }

    func testDictationDefaultsMatchHandyStyleShortcutFlow() {
        let settings = AppSettings()

        XCTAssertFalse(settings.dictationEnabled)
        XCTAssertEqual(settings.dictationTriggerMode, .pushToTalk)
        XCTAssertEqual(settings.dictationOutputMode, .pasteIntoFocusedApp)
        XCTAssertTrue(settings.dictationShowOverlay)
        XCTAssertTrue(settings.dictationLivePreview)
        XCTAssertFalse(settings.dictationRetainAudio)
        XCTAssertTrue(settings.dictationCompositionBuiltInModelID.isEmpty)
    }

    func testSpeechDefaultsUseKokoroHeartAtNormalSpeed() {
        let settings = AppSettings()

        XCTAssertEqual(settings.speechVoice, .heart)
        XCTAssertEqual(settings.speechSpeed, 1.0)
    }

    func testSpeechSettingsRoundTripAndClampSpeed() throws {
        var settings = AppSettings()
        settings.speechVoice = .fable
        settings.speechSpeed = 3.5

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)

        XCTAssertEqual(decoded.speechVoice, .fable)
        XCTAssertEqual(decoded.speechSpeed, AppSettings.maximumSpeechSpeed)
    }

    /// Settings written before TranscriptionModelChoice raw values were
    /// stabilized persisted the display strings — they must keep decoding so
    /// an update never silently resets a user's model choice.
    func testDecodesLegacyTranscriptionModelDisplayString() throws {
        let data = #"{"transcriptionModel":"Parakeet TDT 0.6B v3 (multilingual)"}"#.data(using: .utf8)!

        let settings = try JSONDecoder().decode(AppSettings.self, from: data)

        XCTAssertEqual(settings.transcriptionModel, .parakeetV3)
    }

    func testTranscriptionModelPersistsStableRawValue() throws {
        var settings = AppSettings()
        settings.transcriptionModel = .whisperLarge

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)

        XCTAssertTrue(String(data: data, encoding: .utf8)!.contains("whisper-large-v3-turbo"))
        XCTAssertEqual(decoded.transcriptionModel, .whisperLarge)
    }

    func testUnknownTranscriptionModelFallsBackToDefault() throws {
        let data = #"{"transcriptionModel":"some-future-model"}"#.data(using: .utf8)!

        let settings = try JSONDecoder().decode(AppSettings.self, from: data)

        XCTAssertEqual(settings.transcriptionModel, TranscriptionModelChoice.recommended)
    }

    func testFreshDayMemoryDefaultsToActivityOnly() {
        let settings = AppSettings()
        XCTAssertTrue(settings.trackingEnabled)
        XCTAssertFalse(settings.screenshotsEnabled)
        XCTAssertEqual(settings.screenContextCaptureMode, .activityOnly)
        XCTAssertFalse(settings.meetingVisualContextEnabled)
        XCTAssertFalse(settings.capturePrivateWindows)
    }

    func testPersistedDayTrackingOptOutSurvivesDefaultFlip() throws {
        var settings = AppSettings()
        settings.trackingEnabled = false
        settings.screenContextCaptureMode = .activityOnly
        settings.screenshotsEnabled = false

        let decoded = try JSONDecoder().decode(
            AppSettings.self, from: JSONEncoder().encode(settings))

        XCTAssertFalse(decoded.trackingEnabled)
        XCTAssertFalse(decoded.screenshotsEnabled)
        XCTAssertEqual(decoded.screenContextCaptureMode, .activityOnly)
    }

    func testFreshInstallAsksBeforeRecordingMeetings() {
        XCTAssertEqual(AppSettings().autoRecordMode, .ask)
    }

    func testPersistedManualMeetingRecordingSurvivesDefaultFlip() throws {
        var settings = AppSettings()
        settings.autoRecordMode = .manual

        let decoded = try JSONDecoder().decode(
            AppSettings.self, from: JSONEncoder().encode(settings))

        XCTAssertEqual(decoded.autoRecordMode, .manual)
    }

    func testApprovedRemoteInferenceOriginsRoundTrip() throws {
        var settings = AppSettings()
        settings.approvedRemoteInferenceOrigins = ["https://inference.example.com"]

        let decoded = try JSONDecoder().decode(
            AppSettings.self, from: JSONEncoder().encode(settings))

        XCTAssertEqual(decoded.approvedRemoteInferenceOrigins,
                       ["https://inference.example.com"])
    }

    func testGenerationBudgetPresetRoundTrips() throws {
        var settings = AppSettings()
        settings.generationBudgetPreset = .generous

        let decoded = try JSONDecoder().decode(
            AppSettings.self, from: JSONEncoder().encode(settings))

        XCTAssertEqual(decoded.generationBudgetPreset, .generous)
    }

    func testLegacySettingsDefaultToStandardGenerationBudget() throws {
        let settings = try JSONDecoder().decode(
            AppSettings.self, from: Data(#"{"autoTranscribe":true}"#.utf8))

        XCTAssertEqual(settings.generationBudgetPreset, .standard)
        XCTAssertTrue(settings.corruptedSettingsKeys.isEmpty)
    }

    func testLegacySettingsHaveNoApprovedRemoteInferenceOrigins() throws {
        let settings = try JSONDecoder().decode(
            AppSettings.self, from: Data(#"{"autoTranscribe":false}"#.utf8))

        XCTAssertTrue(settings.approvedRemoteInferenceOrigins.isEmpty)
    }

    /// Legacy settings that predate the typed screen-context mode still map the
    /// old screenshot switch to visual context.
    func testLegacyScreenshotChoiceMapsToVisualContext() throws {
        let data = #"{"trackingEnabled":true,"screenshotsEnabled":true}"#.data(using: .utf8)!

        let settings = try JSONDecoder().decode(AppSettings.self, from: data)

        XCTAssertTrue(settings.trackingEnabled)
        XCTAssertTrue(settings.screenshotsEnabled)
        XCTAssertEqual(settings.screenContextCaptureMode, .visualContext)
    }

    func testTextContextPrivacyAndRoutineSettingsRoundTrip() throws {
        var settings = AppSettings()
        settings.screenContextCaptureMode = .accessibleText
        settings.meetingVisualContextEnabled = true
        settings.capturePrivateWindows = true
        settings.excludedScreenDomains = "example.com, *.private.test"
        settings.memoryRoutinesEnabled = true
        settings.memoryRoutineFolder = "/tmp/Memory Drafts"
        settings.enabledMemoryRoutines = [.dailyStandup, .weeklyWorkLog]
        settings.memoryRoutineHour = 99
        settings.memoryRoutineWeekday = -3

        let decoded = try JSONDecoder().decode(
            AppSettings.self, from: JSONEncoder().encode(settings))

        XCTAssertEqual(decoded.screenContextCaptureMode, .accessibleText)
        XCTAssertFalse(decoded.screenshotsEnabled)
        XCTAssertTrue(decoded.meetingVisualContextEnabled)
        XCTAssertTrue(decoded.capturePrivateWindows)
        XCTAssertEqual(decoded.excludedScreenDomainList, ["example.com", "*.private.test"])
        XCTAssertTrue(decoded.memoryRoutinesEnabled)
        XCTAssertEqual(decoded.memoryRoutineFolder, "/tmp/Memory Drafts")
        XCTAssertEqual(decoded.enabledMemoryRoutines, [.dailyStandup, .weeklyWorkLog])
        XCTAssertEqual(decoded.memoryRoutineHour, 23)
        XCTAssertEqual(decoded.memoryRoutineWeekday, 1)
    }

    /// The default prunes OCR text on the same schedule as the pixels;
    /// keeping it forever is the explicit opt-in.
    func testKeepOCRTextForeverDefaultsFalse() {
        XCTAssertFalse(AppSettings().keepOCRTextForever)
    }

    func testDecodesSettingsWithoutKeepOCRTextForeverKeyAsDefault() throws {
        let data = #"{"autoTranscribe":false}"#.data(using: .utf8)!

        let settings = try JSONDecoder().decode(AppSettings.self, from: data)

        XCTAssertFalse(settings.keepOCRTextForever)
        XCTAssertFalse(settings.autoTranscribe)
    }

    func testKeepOCRTextForeverRoundTrips() throws {
        var settings = AppSettings()
        settings.keepOCRTextForever = true

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)

        XCTAssertTrue(decoded.keepOCRTextForever)
    }

    /// Fresh installs generate the evening digest without a click; 18:00
    /// matches the daily memory export's default refresh hour.
    func testDayDigestDefaultsToAutomaticEveningGeneration() {
        let settings = AppSettings()
        XCTAssertTrue(settings.dayDigestAutoEnabled)
        XCTAssertEqual(settings.dayDigestHour, 18)
        XCTAssertEqual(settings.dayDigestCustomPrompt, "")
    }

    func testDayDigestSettingsRoundTripAndClampHour() throws {
        var settings = AppSettings()
        settings.dayDigestAutoEnabled = false
        settings.dayDigestHour = 99
        settings.dayDigestCustomPrompt = "Focus on deep work; keep it under 10 bullets."

        let decoded = try JSONDecoder().decode(
            AppSettings.self, from: JSONEncoder().encode(settings))

        XCTAssertFalse(decoded.dayDigestAutoEnabled)
        XCTAssertEqual(decoded.dayDigestHour, 23)
        XCTAssertEqual(decoded.dayDigestCustomPrompt,
                       "Focus on deep work; keep it under 10 bullets.")
    }

    /// Settings blobs from builds without the day-digest keys decode to the
    /// new defaults instead of failing or disabling the schedule.
    func testLegacySettingsDecodeWithDayDigestDefaults() throws {
        let decoded = try JSONDecoder().decode(
            AppSettings.self, from: Data("{}".utf8))
        XCTAssertTrue(decoded.dayDigestAutoEnabled)
        XCTAssertEqual(decoded.dayDigestHour, 18)
        XCTAssertEqual(decoded.dayDigestCustomPrompt, "")
    }

    func testScreenMemoryAutomationDefaultsOff() {
        let settings = AppSettings()

        XCTAssertFalse(settings.quickRecallEnabled)
        XCTAssertFalse(settings.dailyMemoryExportEnabled)
        XCTAssertTrue(settings.dailyMemoryExportFolder.isEmpty)
        XCTAssertEqual(settings.dailyMemoryExportFormat, .markdown)
        XCTAssertEqual(settings.dailyMemoryExportHour, 18)
    }

    func testScreenMemoryAutomationRoundTripsAndClampsHour() throws {
        var settings = AppSettings()
        settings.quickRecallEnabled = true
        settings.dailyMemoryExportEnabled = true
        settings.dailyMemoryExportFolder = "/tmp/My Vault"
        settings.dailyMemoryExportFormat = .obsidian
        settings.dailyMemoryExportHour = 99

        let decoded = try JSONDecoder().decode(
            AppSettings.self, from: JSONEncoder().encode(settings))

        XCTAssertTrue(decoded.quickRecallEnabled)
        XCTAssertTrue(decoded.dailyMemoryExportEnabled)
        XCTAssertEqual(decoded.dailyMemoryExportFolder, "/tmp/My Vault")
        XCTAssertEqual(decoded.dailyMemoryExportFormat, .obsidian)
        XCTAssertEqual(decoded.dailyMemoryExportHour, 23)
    }

    func testLegacySettingsKeepScreenMemoryAutomationOff() throws {
        let settings = try JSONDecoder().decode(
            AppSettings.self, from: Data(#"{"autoTranscribe":false}"#.utf8))

        XCTAssertFalse(settings.quickRecallEnabled)
        XCTAssertFalse(settings.dailyMemoryExportEnabled)
        XCTAssertEqual(settings.dailyMemoryExportFormat, .markdown)
    }

    func testStopDebounceDefaultsToBackToBackFriendlyValue() {
        XCTAssertEqual(AppSettings().stopDebounceSeconds, AppSettings.defaultStopDebounceSeconds)
    }

    func testMigratesLegacyStopDebounceDefault() throws {
        let data = #"{"stopDebounceSeconds":60}"#.data(using: .utf8)!

        let settings = try JSONDecoder().decode(AppSettings.self, from: data)

        XCTAssertEqual(settings.stopDebounceSeconds, AppSettings.defaultStopDebounceSeconds)
    }

    func testPreservesExplicitCurrentStopDebounceValue() throws {
        let data = #"{"meetingSettingsVersion":1,"stopDebounceSeconds":60}"#.data(using: .utf8)!

        let settings = try JSONDecoder().decode(AppSettings.self, from: data)

        XCTAssertEqual(settings.stopDebounceSeconds, 60)
    }

    func testDecodesSettingsWithoutMultiSpeakerDiarizationKeyAsDefault() throws {
        let data = #"{"autoTranscribe":false}"#.data(using: .utf8)!

        let settings = try JSONDecoder().decode(AppSettings.self, from: data)

        XCTAssertTrue(settings.multiSpeakerDiarization)
        XCTAssertFalse(settings.autoTranscribe)
    }

    func testMenuBarOnlyRoundTrips() throws {
        for value in [true, false] {
            var settings = AppSettings()
            settings.menuBarOnly = value
            let data = try JSONEncoder().encode(settings)
            let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
            XCTAssertEqual(decoded.menuBarOnly, value)
        }
    }

    func testDictationSettingsRoundTrip() throws {
        var settings = AppSettings()
        settings.dictationEnabled = true
        settings.dictationTriggerMode = .toggle
        settings.dictationOutputMode = .copyToClipboard
        settings.dictationShowOverlay = false
        settings.dictationLivePreview = false
        settings.dictationRetainAudio = true
        settings.dictationCompositionBuiltInModelID = "qwen3.5-2b"

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)

        XCTAssertTrue(decoded.dictationEnabled)
        XCTAssertEqual(decoded.dictationTriggerMode, .toggle)
        XCTAssertEqual(decoded.dictationOutputMode, .copyToClipboard)
        XCTAssertFalse(decoded.dictationShowOverlay)
        XCTAssertFalse(decoded.dictationLivePreview)
        XCTAssertTrue(decoded.dictationRetainAudio)
        XCTAssertEqual(decoded.dictationCompositionBuiltInModelID, "qwen3.5-2b")
    }

    func testDictationCompositionDefaultsToMainLLMSettings() {
        var settings = AppSettings()
        settings.summarizerBackend = .ollama
        settings.ollamaModel = "fast-local-model"

        let resolved = settings.dictationCompositionTextEngineSettings

        XCTAssertEqual(resolved.summarizerBackend, .ollama)
        XCTAssertEqual(resolved.ollamaModel, "fast-local-model")
        XCTAssertEqual(resolved.builtInModelID, settings.builtInModelID)
    }

    func testDictationCompositionCanOverrideMainLLMWithSmallerBuiltInModel() {
        var settings = AppSettings()
        settings.summarizerBackend = .ollama
        settings.ollamaModel = "large-main-model"
        settings.dictationCompositionBuiltInModelID = "qwen3.5-2b"

        let resolved = settings.dictationCompositionTextEngineSettings

        XCTAssertEqual(resolved.summarizerBackend, .builtIn)
        XCTAssertEqual(resolved.builtInModelID, "qwen3.5-2b")
        XCTAssertEqual(settings.summarizerBackend, .ollama)
        XCTAssertEqual(settings.ollamaModel, "large-main-model")
    }

    func testInvalidDictationCompositionModelFallsBackToMainLLM() {
        var settings = AppSettings()
        settings.summarizerBackend = .appleIntelligence
        settings.dictationCompositionBuiltInModelID = "removed-model"

        let resolved = settings.dictationCompositionTextEngineSettings

        XCTAssertEqual(resolved.summarizerBackend, .appleIntelligence)
        XCTAssertEqual(resolved.builtInModelID, settings.builtInModelID)
    }

    func testDecodesSettingsWithoutDictationLivePreviewKeyAsDefault() throws {
        let data = #"{"autoTranscribe":false}"#.data(using: .utf8)!

        let settings = try JSONDecoder().decode(AppSettings.self, from: data)

        XCTAssertTrue(settings.dictationLivePreview)
        XCTAssertTrue(settings.dictationCompositionBuiltInModelID.isEmpty)
        XCTAssertFalse(settings.autoTranscribe)
    }

    /// Settings persisted by a build that predates the key keep working and
    /// fall back to the menu-bar-only default rather than resetting everything.
    func testDecodesSettingsWithoutMenuBarOnlyKeyAsDefault() throws {
        let data = #"{"autoTranscribe":false}"#.data(using: .utf8)!

        let settings = try JSONDecoder().decode(AppSettings.self, from: data)

        XCTAssertTrue(settings.menuBarOnly)
        XCTAssertFalse(settings.autoTranscribe)
    }

    func testLoadAndSaveCanUseInjectedDefaultsSuite() throws {
        let suiteName = "AppSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var saved = AppSettings()
        saved.menuBarOnly = false
        saved.cotypingEnabled = true
        saved.save(to: defaults)

        let loaded = AppSettings.load(from: defaults)

        XCTAssertFalse(loaded.menuBarOnly)
        XCTAssertTrue(loaded.cotypingEnabled)
    }
}
