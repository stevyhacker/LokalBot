import XCTest
@testable import LokalBot

final class GraniteSpeechModelConfigurationTests: XCTestCase {
    func testSpeech5IsPinnedQ8WithItsOwnProjectorAndCache() throws {
        let configuration = GraniteSpeechModelConfiguration.speech5
        let root = URL(fileURLWithPath: "/tmp/lokalbot", isDirectory: true)

        XCTAssertEqual(configuration.quantization, "Q8_0")
        XCTAssertEqual(configuration.displayName, "Granite Speech 5.0 2B · Q8_0")
        XCTAssertEqual(configuration.revision, "df3833f5e22e7d51c3f5dfedd4726260f7ec7cb5")
        XCTAssertEqual(configuration.model.sizeBytes + configuration.projector.sizeBytes, 3_115_509_856)
        XCTAssertEqual(configuration.model.sha256,
                       "4972786fa455b71ee1f020e8ae1b147ca6cd2b1e5b0818048011d7f1da242790")
        XCTAssertEqual(configuration.projector.sha256,
                       "c0d108e1a3cf345b22c411245fc2762319f1c6b6e56bb15bdffe748c9342ca7d")
        XCTAssertNotEqual(GraniteSpeechEngine.modelRoot(configuration: configuration, appSupport: root),
                          GraniteSpeechEngine.modelRoot(appSupport: root))
        XCTAssertNotEqual(GraniteSpeechEngine.projectorURL(configuration: configuration, appSupport: root),
                          GraniteSpeechEngine.projectorURL(appSupport: root))
        for artifact in [configuration.model, configuration.projector] {
            let url = try XCTUnwrap(configuration.downloadURL(for: artifact))
            XCTAssertEqual(url.host, "huggingface.co")
            XCTAssertTrue(url.path.contains("/resolve/\(configuration.revision)/"))
        }
        let roundTrip = try JSONDecoder().decode(
            GraniteSpeechModelConfiguration.self, from: JSONEncoder().encode(configuration))
        XCTAssertEqual(roundTrip, configuration)
        XCTAssertTrue(configuration.supportsVocabularyPrompt)
        XCTAssertFalse(GraniteSpeechModelConfiguration.defaultModel.supportsVocabularyPrompt)
    }

    func testSpeech5SelectionPersistsIndependentlyOfCustomGranite41() throws {
        var settings = AppSettings()
        settings.transcriptionModel = .graniteSpeech5
        settings.graniteSpeechModel = try makeQ8Configuration()
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))

        XCTAssertEqual(decoded.transcriptionModel, .graniteSpeech5)
        XCTAssertEqual(decoded.graniteSpeechModel, settings.graniteSpeechModel)
        XCTAssertEqual(decoded.transcriptionEngine().displayName, "Granite Speech 5.0 2B · Q8_0")
        XCTAssertEqual(decoded.transcriptionEngine(for: .graniteSpeech).displayName,
                       "Granite Speech 4.1 2B · Q8_0")
        XCTAssertEqual(TranscriptionModelChoice.recommended, .qwenASR17B)
        XCTAssertTrue(TranscriptionModelChoice.graniteSpeech5.acceptsVocabularyPrompt)
        XCTAssertFalse(TranscriptionModelChoice.graniteSpeech.acceptsVocabularyPrompt)
    }

    func testSpeech5VocabularyRequestKeepsTaskLanguageAndAuthentication() throws {
        let wav = FileManager.default.temporaryDirectory.appendingPathComponent("granite5-\(UUID().uuidString).wav")
        try Data("RIFF".utf8).write(to: wav)
        defer { try? FileManager.default.removeItem(at: wav) }
        let request = try GraniteSpeechEngine.makeTranscriptionRequest(
            serverBaseURL: URL(string: "http://127.0.0.1:17875/v1")!,
            authenticationToken: "synthetic-key", boundary: "granite5",
            wav: wav, language: "fr",
            modelFileName: GraniteSpeechModelConfiguration.speech5.localModelFileName,
            vocabularyPrompt: "  LokalBot, Ana Marković  ")
        let body = String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self)

        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic-key")
        XCTAssertTrue(body.contains("granite-speech-5.0-2b-Q8_0.gguf"), body)
        XCTAssertTrue(body.contains("proper punctuation and capitalization. Keywords: LokalBot, Ana Marković\r\n"), body)
        XCTAssertTrue(body.contains("name=\"language\"\r\n\r\nfr\r\n"), body)
    }

    func testSpeech5VocabularyIsBoundedAndEmptyHintsKeepTheDefaultTask() throws {
        let wav = FileManager.default.temporaryDirectory.appendingPathComponent("granite5-budget-\(UUID().uuidString).wav")
        try Data("RIFF".utf8).write(to: wav)
        defer { try? FileManager.default.removeItem(at: wav) }
        for (vocabulary, expected) in [
            (String(repeating: "é", count: 10_000), " Keywords: " + String(repeating: "é", count: 480)),
            (" \n ", ""),
        ] {
            let request = try GraniteSpeechEngine.makeTranscriptionRequest(
                serverBaseURL: URL(string: "http://127.0.0.1:17875/v1")!,
                authenticationToken: "synthetic-key", boundary: "granite5",
                wav: wav, language: nil,
                modelFileName: GraniteSpeechModelConfiguration.speech5.localModelFileName,
                vocabularyPrompt: vocabulary)
            let body = String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self)
            XCTAssertTrue(body.contains("name=\"prompt\"\r\n\r\ntranscribe the speech with proper punctuation and capitalization."
                                       + expected + "\r\n"), body)
            XCTAssertFalse(body.contains("name=\"language\""), body)
        }
    }

    func testDefaultConfigurationPreservesExistingQ4CachePaths() {
        let configuration = GraniteSpeechModelConfiguration.defaultModel
        let root = URL(fileURLWithPath: "/tmp/lokalbot", isDirectory: true)

        XCTAssertTrue(configuration.isDefault)
        XCTAssertEqual(configuration.quantization, "Q4_K_M")
        XCTAssertEqual(configuration.displayName, "Granite Speech 4.1 2B · Q4_K_M")
        XCTAssertEqual(
            GraniteSpeechEngine.modelURL(
                configuration: configuration,
                appSupport: root).path,
            "/tmp/lokalbot/granite-speech/4.1-2b/granite-speech-4.1-2b-Q4_K_M.gguf")
        XCTAssertEqual(
            GraniteSpeechEngine.projectorURL(
                configuration: configuration,
                appSupport: root).path,
            "/tmp/lokalbot/granite-speech/4.1-2b/mmproj-model-f16.gguf")
    }

    func testOfficialQ8ConfigurationReusesProjectorAndPersists() throws {
        let configuration = try makeQ8Configuration()
        let root = URL(fileURLWithPath: "/tmp/lokalbot", isDirectory: true)

        XCTAssertEqual(configuration.quantization, "Q8_0")
        XCTAssertEqual(configuration.displayName, "Granite Speech 4.1 2B · Q8_0")
        XCTAssertEqual(
            GraniteSpeechEngine.modelURL(
                configuration: configuration,
                appSupport: root).path,
            "/tmp/lokalbot/granite-speech/4.1-2b/granite-speech-4.1-2b-Q8_0.gguf")
        XCTAssertEqual(
            GraniteSpeechEngine.projectorURL(
                configuration: configuration,
                appSupport: root).path,
            "/tmp/lokalbot/granite-speech/4.1-2b/mmproj-model-f16.gguf")

        let roundTrip = try JSONDecoder().decode(
            GraniteSpeechModelConfiguration.self,
            from: JSONEncoder().encode(configuration))
        XCTAssertEqual(roundTrip, configuration)
    }

    func testOtherRepositoryGetsRevisionScopedCache() throws {
        let configuration = try makeQ8Configuration(
            repository: "example/granite-speech-custom-GGUF")
        let root = URL(fileURLWithPath: "/tmp/lokalbot", isDirectory: true)
        let directory = GraniteSpeechEngine.modelRoot(
            configuration: configuration,
            appSupport: root)

        XCTAssertTrue(directory.path.hasPrefix(
            "/tmp/lokalbot/granite-speech/custom/"), directory.path)
        XCTAssertNotEqual(directory, GraniteSpeechEngine.modelRoot(appSupport: root))
    }

    func testConfigurationRequiresImmutableRevisionAndIntegrityMetadata() {
        XCTAssertThrowsError(try makeQ8Configuration(revision: "main")) { error in
            XCTAssertEqual(
                error as? GraniteSpeechModelConfiguration.ValidationError,
                .invalidRevision)
        }

        XCTAssertThrowsError(try makeQ8Configuration(modelSHA256: "not-a-digest")) { error in
            XCTAssertEqual(
                error as? GraniteSpeechModelConfiguration.ValidationError,
                .invalidIntegrityMetadata)
        }
    }

    func testSettingsRoundTripKeepsCustomGraniteChoice() throws {
        var settings = AppSettings()
        settings.transcriptionModel = .graniteSpeech
        settings.graniteSpeechModel = try makeQ8Configuration()

        let decoded = try JSONDecoder().decode(
            AppSettings.self,
            from: JSONEncoder().encode(settings))

        XCTAssertEqual(decoded.graniteSpeechModel, settings.graniteSpeechModel)
        XCTAssertEqual(decoded.transcriptionModelDisplayName,
                       "Granite Speech 4.1 2B · Q8_0")
        XCTAssertEqual(decoded.transcriptionEngine().displayName,
                       "Granite Speech 4.1 2B · Q8_0")
    }

    func testLegacySettingsUsePinnedDefaultGraniteConfiguration() throws {
        let decoded = try JSONDecoder().decode(
            AppSettings.self,
            from: Data(#"{"transcriptionModel":"granite-speech-4.1-2b"}"#.utf8))

        XCTAssertEqual(decoded.graniteSpeechModel, .defaultModel)
    }

    func testTranscriptionRequestUsesConfiguredModelFileName() throws {
        let wav = FileManager.default.temporaryDirectory
            .appendingPathComponent("granite-q8-\(UUID().uuidString).wav")
        try Data([0x52, 0x49, 0x46, 0x46]).write(to: wav)
        defer { try? FileManager.default.removeItem(at: wav) }

        let request = try GraniteSpeechEngine.makeTranscriptionRequest(
            serverBaseURL: URL(string: "http://127.0.0.1:17875/v1")!,
            authenticationToken: "granite-secret",
            boundary: "granite-q8-test",
            wav: wav,
            language: nil,
            modelFileName: "granite-speech-4.1-2b-Q8_0.gguf")
        let body = String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self)

        XCTAssertTrue(body.contains(
            "name=\"model\"\r\n\r\ngranite-speech-4.1-2b-Q8_0.gguf\r\n"), body)
    }

    private func makeQ8Configuration(
        repository: String = GraniteSpeechModelConfiguration.defaultModel.repository,
        revision: String = GraniteSpeechModelConfiguration.defaultModel.revision,
        modelSHA256: String = String(repeating: "a", count: 64)
    ) throws -> GraniteSpeechModelConfiguration {
        try GraniteSpeechModelConfiguration(
            repository: repository,
            revision: revision,
            model: .init(
                path: "granite-speech-4.1-2b-Q8_0.gguf",
                sizeBytes: 1_960_000_000,
                sha256: modelSHA256),
            projector: .init(
                path: "mmproj-model-f16.gguf",
                sizeBytes: 1_159_354_752,
                sha256: String(repeating: "b", count: 64)))
    }
}
