import XCTest
@testable import LokalBot

final class ModelCatalogTests: XCTestCase {
    func testCatalogIDsAreUnique() {
        let ids = ModelCatalog.entries.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count)
    }

    func testCatalogFileNamesAreUnique() {
        let names = ModelCatalog.entries.map(\.fileName)
        XCTAssertEqual(names.count, Set(names).count)
    }

    func testCompactFallbackModelExistsInCatalog() {
        XCTAssertNotNil(ModelCatalog.entry(id: ModelCatalog.compactFallbackID))
    }

    func testRecommendedCotypingModelExistsInCatalog() {
        XCTAssertNotNil(ModelCatalog.entry(id: ModelCatalog.recommendedCotypingID))
    }

    func testQualityCotypingModelIsPinnedAndOnlyOfferedForAutocomplete() throws {
        let entry = try XCTUnwrap(ModelCatalog.entry(id: ModelCatalog.qualityCotypingID))
        XCTAssertEqual(entry.id, "gemma4-e2b-lokalbot-v4-q5")
        XCTAssertEqual(entry.fileName, "Gemma-4-E2B-LokalBot-v4-i1-Q5_K_M-pleQ4K.gguf")
        XCTAssertEqual(entry.sizeBytes, 3_021_725_952)
        XCTAssertEqual(entry.sha256, "fac8a71506ef985292edb5c1ef190ea07288a6cca2aba0428b07d0f5feefbdf4")
        XCTAssertTrue(entry.url.contains("/resolve/58300b1a9d5545fe8225e73e6dc72db3cb5090c4/"))
        XCTAssertTrue(ModelCatalog.keystrokeScaleEntries(custom: []).contains(entry))
        XCTAssertFalse(ModelCatalog.mainLLMEntries(custom: []).contains(entry))
        let previousV4 = try XCTUnwrap(ModelCatalog.entry(id: ModelCatalog.previousV4QualityCotypingID))
        XCTAssertEqual(previousV4.id, "gemma4-e2b-lokalbot-v4")
        XCTAssertEqual(previousV4.fileName, "Gemma-4-E2B-LokalBot-v4-i1-Q6_K.gguf")
        XCTAssertEqual(previousV4.sizeBytes, 3_845_323_008)
        XCTAssertEqual(previousV4.sha256, "ea8c01dd28abaae0a6664eb9c1324f6bf6cd0ffef99dace496510f7cceb40581")
        XCTAssertTrue(ModelCatalog.keystrokeScaleEntries(custom: []).contains(previousV4))
        XCTAssertFalse(ModelCatalog.mainLLMEntries(custom: []).contains(previousV4))
        let stock = try XCTUnwrap(ModelCatalog.entry(id: ModelCatalog.previousQualityCotypingID))
        XCTAssertEqual(stock.fileName, "gemma-4-E2B.i1-Q6_K.gguf")
        XCTAssertTrue(ModelCatalog.keystrokeScaleEntries(custom: []).contains(stock))
        XCTAssertFalse(ModelCatalog.mainLLMEntries(custom: []).contains(stock))
        XCTAssertEqual(AppSettings().cotypingBuiltInModelID, entry.id)
        XCTAssertEqual(ModelCatalog.recommendedCotypingID, entry.id)
        XCTAssertEqual(ModelCatalog.recommendedCotypingLicenseURL.absoluteString,
                       "https://ai.google.dev/gemma/apache_2")
    }

    func testLightweightCotypingModelKeepsBenchmarkedLFMQuant() throws {
        let entry = try XCTUnwrap(ModelCatalog.entry(id: ModelCatalog.lightweightCotypingID))
        XCTAssertEqual(entry.id, "lfm2.5-1.2b-instruct")
        XCTAssertEqual(entry.fileName, "LFM2.5-1.2B-Instruct-Q4_K_M.gguf")
        XCTAssertTrue(entry.url.contains("LFM2.5-1.2B-Instruct-Q4_K_M.gguf"))
        XCTAssertEqual(entry.sizeBytes, 730_895_584)
        XCTAssertEqual(entry.sizeGB, 0.73)
    }

    func testRecommendedSummarizationAndMaximumQualityModelsExist() {
        XCTAssertNotNil(ModelCatalog.entry(id: ModelCatalog.recommendedSummarizationID))
        XCTAssertNotNil(ModelCatalog.entry(id: ModelCatalog.defaultSummarizationID))
        XCTAssertNotNil(ModelCatalog.entry(id: "qwen3.6-27b"))
        XCTAssertNotNil(ModelCatalog.entry(id: "gemma4-12b"))
        XCTAssertNotNil(ModelCatalog.entry(id: "qwen3.5-4b"))
        XCTAssertNotNil(ModelCatalog.entry(id: "lfm2.5-2.6b"))
        XCTAssertNotNil(ModelCatalog.entry(id: "lfm2.5-1.2b-instruct"))
        XCTAssertNotNil(ModelCatalog.entry(id: "granite-4.1-3b"))
        XCTAssertNotNil(ModelCatalog.entry(id: "ministral-3-3b-instruct-2512"))
    }

    func testInklingIsAnIntegrityPinnedOptInThatNoTierDefaultsTo() throws {
        let entry = try XCTUnwrap(ModelCatalog.entry(id: "inkling-2-mini"))
        XCTAssertEqual(entry.fileName, "Inkling-2-Mini-IQ4_NL.gguf")
        XCTAssertTrue(entry.url.hasPrefix("https://huggingface.co/ggml-org/Inkling-2-Mini-GGUF/resolve/"),
                      "Unsloth's files use a pre-merge layout mainline llama.cpp refuses")
        XCTAssertTrue(entry.url.contains("/e8a2cecf0e78914f07cc27b9be711a9b2c7561d9/"))
        XCTAssertEqual(entry.expectedSHA256, "cbdf3fa9dc50a4124977980f37da4f1fa764b0cfe800d275cd43d26ce2a81af4")
        XCTAssertEqual(entry.sizeBytes, 17_627_940_768)
        XCTAssertNotEqual(ModelCatalog.defaultSummarizationID, entry.id)
        XCTAssertNotEqual(ModelCatalog.recommendedSummarizationID, entry.id)
        XCTAssertFalse(ModelCatalog.keystrokeScaleEntries(custom: []).map(\.id).contains(entry.id))
    }

    func testExperimentalLFM26BArtifactIsIntegrityPinned() throws {
        let entry = try XCTUnwrap(ModelCatalog.entry(id: "lfm2.5-2.6b"))
        XCTAssertEqual(entry.fileName, "LFM2.5-2.6B-Q4_K_M.gguf")
        XCTAssertEqual(entry.sizeBytes, 1_674_454_848)
        XCTAssertEqual(
            entry.sha256,
            "79fdf00351b46cf26f020aead28d01889886be87c55fa0eb907e6f9b00bfee14")
        XCTAssertTrue(entry.url.contains("/resolve/b22e29ebf6249a8c9fcdda36914743e9980595c4/"))
    }

    func testExperimentalLFM26BUsesVendorSamplingProfile() throws {
        let overrides = MainLLMRuntimePolicy.requestOverrides(for: "lfm2.5-2.6b")
        XCTAssertEqual(overrides["temperature"] as? Double, 0.1)
        XCTAssertEqual(overrides["top_k"] as? Int, 50)
        XCTAssertEqual(overrides["repeat_penalty"] as? Double, 1.1)
        XCTAssertTrue(MainLLMRuntimePolicy.requestOverrides(for: "qwen3.5-4b").isEmpty)
    }

    func testExperimentalSmallMainLLMArtifactsAreIntegrityPinned() throws {
        let granite = try XCTUnwrap(ModelCatalog.entry(id: "granite-4.1-3b"))
        XCTAssertEqual(granite.fileName, "granite-4.1-3b-Q4_K_M.gguf")
        XCTAssertEqual(granite.sizeBytes, 2_099_501_664)
        XCTAssertEqual(
            granite.sha256,
            "662b0626cd58f443baea23559b469df6576a81d349649c59413b36a9fb32eb29")
        XCTAssertTrue(granite.url.contains("/resolve/ab4701481089b58a082ef63cc1cee738887293ff/"))

        let ministral = try XCTUnwrap(
            ModelCatalog.entry(id: "ministral-3-3b-instruct-2512"))
        XCTAssertEqual(
            ministral.fileName,
            "Ministral-3-3B-Instruct-2512-Q4_K_M.gguf")
        XCTAssertEqual(ministral.sizeBytes, 2_147_023_008)
        XCTAssertEqual(
            ministral.sha256,
            "9ed150d4367e68df0ac8e1540f6ddc65b42d0ee26378329d1ecbca60f93fc5f8")
        XCTAssertTrue(ministral.url.contains("/resolve/eb599d408350ea2bb60452cb86be7c7b2fc28227/"))
    }

    func testMinistralUsesVendorLowTemperatureProfile() {
        let overrides = MainLLMRuntimePolicy.requestOverrides(
            for: "ministral-3-3b-instruct-2512")
        XCTAssertEqual(overrides["temperature"] as? Double, 0.05)
        XCTAssertEqual(overrides.count, 1)
    }

    func testFreshSettingsDefaultToQwen35FourBOnEveryMac() throws {
        XCTAssertEqual(ModelCatalog.defaultSummarizationID, "qwen3.5-4b-lokalbot-v4")
        XCTAssertEqual(AppSettings().builtInModelID, ModelCatalog.defaultSummarizationID)
        let entry = try XCTUnwrap(ModelCatalog.entry(id: ModelCatalog.defaultSummarizationID))
        XCTAssertEqual(entry.fileName, "Qwen3.5-4B-LokalBot-v4-Q4_K_M.gguf")
        XCTAssertEqual(entry.sizeBytes, 2_741_241_952)
        XCTAssertEqual(entry.sha256, "678f3d49c92ece8cd9425bad9e30cd626d35149b00f5dc2b661cb78ad9346ab0")
        XCTAssertTrue(entry.url.contains("/resolve/b7c9e3308abcf996350e35c9dc97d9590bf6a00a/"))
        XCTAssertTrue(ModelCatalog.mainLLMEntries(custom: []).contains(entry))
        XCTAssertFalse(ModelCatalog.keystrokeScaleEntries(custom: []).contains(entry))
    }

    func testQwenASRModelsAreRunnableChoices() {
        XCTAssertTrue(TranscriptionModelChoice.allCases.contains(.qwenASR17BLokalBotV3))
        XCTAssertTrue(TranscriptionModelChoice.allCases.contains(.qwenASR17B))
        XCTAssertTrue(TranscriptionModelChoice.allCases.contains(.qwenASR06BLokalBotV1))
        XCTAssertTrue(TranscriptionModelChoice.allCases.contains(.qwenASR06B))
        XCTAssertEqual(TranscriptionModelChoice.recommended, .qwenASR17BLokalBotV3)
        XCTAssertEqual(AppSettings().transcriptionModel, .qwenASR17BLokalBotV3)
        XCTAssertEqual(ModelStackPreset.recommended.transcription, .qwenASR17BLokalBotV3)
        XCTAssertEqual(ModelStackPreset.recommended.patch.transcription, .qwenASR17BLokalBotV3)
        XCTAssertEqual(ModelStackPreset.lightweight.transcription, .qwenASR06BLokalBotV1)
        XCTAssertEqual(TranscriptionModelChoice.qwenASR17BLokalBotV3.displayName, "Qwen3-ASR 1.7B (LokalBot v3)")
        XCTAssertEqual(TranscriptionModelChoice.qwenASR17B.displayName, "Qwen3-ASR 1.7B")
        XCTAssertEqual(TranscriptionModelChoice.qwenASR06BLokalBotV1.displayName, "Qwen3-ASR 0.6B (LokalBot v1)")
        XCTAssertEqual(TranscriptionModelChoice.qwenASR06B.displayName, "Qwen3-ASR 0.6B")
    }

    func testParakeetUltraIsSelectableAndPersistsWithoutReplacingExistingChoices() throws {
        let choice = TranscriptionModelChoice.parakeetUltra
        XCTAssertTrue(TranscriptionModelChoice.allCases.contains(choice))
        XCTAssertFalse(choice.isLegacy)
        XCTAssertTrue((choice.engine as? ParakeetEngine) === ParakeetEngine.ultra)
        XCTAssertEqual(choice.engine.displayName, "Parakeet Ultra 0.6B")
        XCTAssertFalse(choice.acceptsVocabularyPrompt)
        XCTAssertFalse(choice.engine.supportsStreaming)
        XCTAssertEqual(choice.engine.speakerAttribution, .regions)

        let decoder = JSONDecoder()
        for (rawValue, expected) in [("parakeet-ultra", choice), ("parakeet-v3", .parakeetV3), ("parakeet-v2", .parakeetV2)] {
            let decoded = try decoder.decode(TranscriptionModelChoice.self, from: JSONEncoder().encode(rawValue))
            XCTAssertEqual(decoded, expected)
        }
        var settings = AppSettings()
        settings.transcriptionModel = choice
        let restored = try decoder.decode(AppSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(restored.transcriptionModel, choice)
    }

    func testPresetModelSummaryNamesEveryRoleModel() {
        XCTAssertEqual(ModelStackPreset.recommended.modelSummary,
                       "Transcribe: Qwen3-ASR 1.7B (LokalBot v3), Think: Qwen3.5 4B (LokalBot v4), Autocomplete: Gemma 4 E2B (LokalBot v4)")
        XCTAssertEqual(ModelStackPreset.lightweight.modelSummary,
                       "Transcribe: Qwen3-ASR 0.6B (LokalBot v1), Think: Qwen3.5 0.8B, Autocomplete: LFM2.5 1.2B Instruct")
    }

    func testGraniteSpeechModelIsRunnableChoice() {
        XCTAssertTrue(TranscriptionModelChoice.allCases.contains(.graniteSpeech))
        XCTAssertEqual(TranscriptionModelChoice.graniteSpeech.engine.displayName, "Granite Speech 4.1 2B")
    }

    func testGraniteSpeechFilesUseDedicatedSupportFolder() {
        let root = URL(fileURLWithPath: "/tmp/lokalbot", isDirectory: true)
        XCTAssertEqual(
            GraniteSpeechEngine.modelURL(appSupport: root).path,
            "/tmp/lokalbot/granite-speech/4.1-2b/granite-speech-4.1-2b-Q4_K_M.gguf")
        XCTAssertEqual(
            GraniteSpeechEngine.projectorURL(appSupport: root).path,
            "/tmp/lokalbot/granite-speech/4.1-2b/mmproj-model-f16.gguf")
    }

    func testGraniteSpeechRequestAuthenticatesToPrivateServer() throws {
        let wav = FileManager.default.temporaryDirectory
            .appendingPathComponent("granite-auth-\(UUID().uuidString).wav")
        try Data([0x52, 0x49, 0x46, 0x46]).write(to: wav)
        defer { try? FileManager.default.removeItem(at: wav) }

        let request = try GraniteSpeechEngine.makeTranscriptionRequest(
            serverBaseURL: URL(string: "http://127.0.0.1:17875/v1")!,
            authenticationToken: "granite-secret",
            boundary: "granite-test-boundary",
            wav: wav,
            language: "en")

        XCTAssertEqual(request.url?.absoluteString,
                       "http://127.0.0.1:17875/v1/audio/transcriptions")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"),
                       "Bearer granite-secret")
        let body = String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self)
        XCTAssertTrue(body.contains("name=\"language\"\r\n\r\nen\r\n"), body)
    }

    func testGraniteSpeechRequestOmitsLanguageHintInAutoMode() throws {
        let wav = FileManager.default.temporaryDirectory
            .appendingPathComponent("granite-auto-\(UUID().uuidString).wav")
        try Data([0x52, 0x49, 0x46, 0x46]).write(to: wav)
        defer { try? FileManager.default.removeItem(at: wav) }

        let request = try GraniteSpeechEngine.makeTranscriptionRequest(
            serverBaseURL: URL(string: "http://127.0.0.1:17875/v1")!,
            authenticationToken: "granite-secret",
            boundary: "granite-test-boundary",
            wav: wav,
            language: nil)

        let body = String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self)
        XCTAssertFalse(body.contains("name=\"language\""), body)
    }

    func testLlamaServerParsesServedModelNames() {
        let payload = """
        {
          "models": [{"name":"gemma-4-E4B-UD-Q5_K_XL.gguf","model":"gemma-4-E4B-UD-Q5_K_XL.gguf"}],
          "data": [{"id":"gemma-4-E4B-UD-Q5_K_XL.gguf"}]
        }
        """

        let names = LlamaServer.servedModelNames(from: Data(payload.utf8))

        XCTAssertTrue(names.contains("gemma-4-E4B-UD-Q5_K_XL.gguf"))
    }

    func testCotypingServerContextFitsWindowTextAndDraft() {
        XCTAssertEqual(LlamaServer.cotyping.contextTokens, 4_096)
    }

    func testDownloadURLsAreValid() {
        for entry in ModelCatalog.entries {
            XCTAssertNotNil(URL(string: entry.url), "\(entry.id) has an invalid URL")
        }
    }

    func testCatalogDownloadsAreImmutableAndIntegrityPinned() throws {
        for entry in ModelCatalog.entries {
            XCTAssertFalse(entry.url.contains("/resolve/main/"),
                           "\(entry.id) must pin an immutable Hugging Face revision")
            let digest = try XCTUnwrap(entry.sha256, "\(entry.id) needs a SHA-256 digest")
            XCTAssertNotNil(digest.range(of: #"^[0-9a-f]{64}$"#,
                                         options: .regularExpression),
                            "\(entry.id) has an invalid SHA-256 digest")
        }
    }

    func testKeystrokeScaleEntriesOmitHeavyAndLegacyModels() {
        let ids = ModelCatalog.keystrokeScaleEntries(custom: []).map(\.id)
        XCTAssertFalse(ids.contains("qwen3.6-35b-a3b"), "17 GB models are not keystroke-scale")
        XCTAssertFalse(ids.contains("qwen3.6-27b"))
        XCTAssertFalse(ids.contains("gemma4-12b"))
        XCTAssertFalse(ids.contains("gemma4-e4b"), "the legacy Gemma quant is superseded")
        XCTAssertFalse(ids.contains("lfm2.5-2.6b"), "always-reasoning models are not for cotyping")
        XCTAssertFalse(ids.contains("granite-4.1-3b"), "Main LLM experiments are not for cotyping")
        XCTAssertFalse(ids.contains("ministral-3-3b-instruct-2512"),
                       "Main LLM experiments are not for cotyping")
        XCTAssertTrue(ids.contains(ModelCatalog.recommendedCotypingID))
        XCTAssertTrue(ids.contains("qwen3.5-2b"))
        XCTAssertTrue(ids.contains("lfm2.5-1.2b-instruct"))
    }

    func testKeystrokeScaleEntriesKeepTheActiveSelection() {
        let ids = ModelCatalog.keystrokeScaleEntries(
            custom: [], keeping: "qwen3.6-27b").map(\.id)
        XCTAssertTrue(ids.contains("qwen3.6-27b"),
                      "an existing selection must stay pickable, filter or not")
    }

    func testKeystrokeScaleEntriesAlwaysIncludeCustomModels() {
        let custom = ModelCatalog.Entry(
            id: "my-local-model", displayName: "My local model",
            fileName: "my-local-model.gguf", url: "https://example.invalid/x.gguf",
            sha256: "", sizeBytes: nil, sizeGB: 42, blurb: "",
            disablesThinking: false)
        let ids = ModelCatalog.keystrokeScaleEntries(custom: [custom]).map(\.id)
        XCTAssertTrue(ids.contains("my-local-model"),
                      "user-added models are never filtered, whatever their size")
    }

    func testCatalogDisplayNamesAreUnique() {
        let names = ModelCatalog.entries.map(\.displayName)
        XCTAssertEqual(Set(names).count, names.count,
                       "two catalog entries render identically in pickers: \(names)")
    }
}
