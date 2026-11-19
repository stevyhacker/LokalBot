import XCTest
@testable import LokalBot

final class AppleSpeechSettingsTests: XCTestCase {
    func testAppleSpeechPersistsRawValueAndDecodesLegacyDisplayString() throws {
        var settings = AppSettings()
        settings.transcriptionModel = .appleSpeech

        let data = try JSONEncoder().encode(settings)
        XCTAssertTrue(String(data: data, encoding: .utf8)?.contains("apple-speech") == true)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertEqual(decoded.transcriptionModel, .appleSpeech)

        let legacy = Data(#"{"transcriptionModel":"Apple Speech"}"#.utf8)
        let legacyDecoded = try JSONDecoder().decode(AppSettings.self, from: legacy)
        XCTAssertEqual(legacyDecoded.transcriptionModel, .appleSpeech)
    }

    func testSettingRegistryExposesAppleSpeechTokenAndSearchAlias() throws {
        let spec = try XCTUnwrap(SettingRegistry.spec(for: "transcriptionModel"))
        let choices = try XCTUnwrap(spec.kind.choices)
        XCTAssertTrue(choices.contains { $0.token == "appleSpeech" && $0.stored == .string("apple-speech") })
        XCTAssertEqual(SettingRegistry.search("apple speech").first?.key, "transcriptionModel")
    }

    func testLanguageValidationAndVocabularySupport() async throws {
        let choice = TranscriptionModelChoice.appleSpeech
        XCTAssertTrue(choice.acceptsVocabularyPrompt)
        XCTAssertTrue(choice.isBuiltInSystem)
        XCTAssertFalse(choice.isRemote)
        XCTAssertNil(choice.sizeLabel)
        XCTAssertTrue(choice.isLanguageSelectable(.auto))
        XCTAssertEqual(choice.languageDisplayName(for: .auto), "System language")
        XCTAssertEqual(TranscriptionModelChoice.whisperLarge.languageDisplayName(for: .auto), "Auto-detect")
        XCTAssertTrue(choice.isLanguageSelectable(.uk))
        XCTAssertTrue(choice.isLanguageSelectable(.language(.tr)))
        XCTAssertFalse(choice.isLanguageSelectable(.language(.sr)))

        let message = try XCTUnwrap(choice.languageSelectionMessage(for: .language(.sr)))
        XCTAssertTrue(message.contains("Serbian"))
        XCTAssertNil(choice.languageSelectionMessage(for: .uk))

        var settings = AppSettings()
        settings.transcriptionModel = .appleSpeech
        settings.transcriptionLanguage = .language(.sr)
        let engine = settings.transcriptionEngine()
        let missingAudio = URL(fileURLWithPath: "/nonexistent/apple-speech-sr.wav")

        for path in 0..<3 {
            do {
                switch path {
                case 0: _ = try await engine.transcribe(audio: missingAudio, language: "sr")
                case 1: _ = try await engine.transcribe(audio: missingAudio, language: "sr", prompt: "Mila")
                default:
                    _ = try await engine.transcribeForWordAttribution(
                        audio: missingAudio,
                        language: "sr",
                        prompt: "Mila")
                }
                XCTFail("Expected Serbian to be rejected on path \(path)")
            } catch {
                XCTAssertEqual(
                    error as? UnsupportedTranscriptionLanguage,
                    UnsupportedTranscriptionLanguage(language: "Serbian", model: "Apple Speech"))
            }
        }
    }

    func testTranscriptionModelStoreTracksAvailabilityAndIgnoresDelete() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("apple-speech-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let environment = TranscriptionModelStore.Environment(
            appSupport: tempRoot,
            fluidAudioRoot: tempRoot.appendingPathComponent("FluidAudio", isDirectory: true),
            fluidAudioModelsRoot: tempRoot.appendingPathComponent("FluidAudio/Models", isDirectory: true),
            whisperKitDownloadRoot: tempRoot.appendingPathComponent("WhisperKit", isDirectory: true),
            whisperKitRepoRoot: tempRoot.appendingPathComponent("WhisperKit/models", isDirectory: true),
            legacyWhisperKitRepoRoot: nil)

        XCTAssertTrue(TranscriptionModelStore.isDownloaded(
            .appleSpeech,
            environment: environment,
            appleSpeechAssetInstalled: true))
        XCTAssertFalse(TranscriptionModelStore.isDownloaded(
            .appleSpeech,
            environment: environment))
        XCTAssertNoThrow(try TranscriptionModelStore.delete(.appleSpeech, environment: environment))
    }
}
