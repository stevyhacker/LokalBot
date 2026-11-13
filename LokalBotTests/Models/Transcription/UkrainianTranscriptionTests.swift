import FluidAudio
import WhisperKit
import XCTest
@testable import LokalBot

final class UkrainianTranscriptionTests: XCTestCase {
    func testSavedUkrainianSelectionReachesWhisperAfterReload() throws {
        let suite = "UkrainianTranscriptionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var settings = try JSONDecoder().decode(AppSettings.self, from: Data(
            #"{"transcriptionModel":"whisper-large-v3-turbo","transcriptionLanguage":"uk"}"#.utf8))
        settings.transcriptionPrompt = "Київ, Україна"
        settings.save(to: defaults)

        let restored = AppSettings.load(from: defaults)
        XCTAssertEqual(restored.transcriptionLanguage, .uk)
        XCTAssertEqual(restored.transcriptionPrompt, settings.transcriptionPrompt)
        XCTAssertTrue(restored.corruptedSettingsKeys.isEmpty)
        let options = WhisperEngine.decodingOptions(language: restored.transcriptionLanguage.code, promptTokens: [42])
        XCTAssertEqual(options.language, "uk")
        XCTAssertFalse(options.detectLanguage)
        XCTAssertTrue(options.usePrefillPrompt)
        XCTAssertEqual(options.task, .transcribe)
        XCTAssertEqual(options.promptTokens, [42])
    }

    func testWhisperAutoDetectionIsStillEnabledWithoutASelection() {
        let options = WhisperEngine.decodingOptions(language: TranscriptionLanguage.auto.code)
        XCTAssertNil(options.language)
        XCTAssertTrue(options.detectLanguage)
    }

    func testLegacyUkrainianSettingsUpgradeAndExplicitSelectionWins() throws {
        for json in [#"{"languageHint":" UK "}"#,
                     #"{"languageHint":"ru","transcriptionLanguage":"uk"}"#] {
            let settings = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
            XCTAssertEqual(settings.transcriptionLanguage, .uk)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any])
            XCTAssertEqual(object["transcriptionLanguage"] as? String, "uk")
            XCTAssertNil(object["languageHint"])
        }
    }

    func testModelSwitchKeepsUkrainianAndExplainsAnIncompatibleChoice() throws {
        var settings = AppSettings()
        settings.transcriptionModel = .whisperLarge
        settings.transcriptionLanguage = .uk
        let changed = ModelSelectionPatch(transcription: .qwenASR17B).applying(to: settings)
        let restored = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(changed))
        XCTAssertEqual(restored.transcriptionLanguage, .uk)
        XCTAssertFalse(restored.transcriptionModel.isLanguageSelectable(.uk))
        XCTAssertTrue(try XCTUnwrap(restored.transcriptionModel.languageSelectionMessage(for: .uk)).contains("does not support Ukrainian"))
        XCTAssertTrue(restored.transcriptionModel.isLanguageSelectable(.auto))
        XCTAssertTrue(restored.transcriptionModel.isLanguageSelectable(.en))
    }

    func testModelPickerNeverReplacesUkrainianWithEnglish() {
        for choice in TranscriptionModelChoice.allCases {
            XCTAssertNil(choice.languageOverrideOnSelection(current: .uk), choice.rawValue)
        }
        XCTAssertEqual(TranscriptionModelChoice.graniteTurbo.languageOverrideOnSelection(current: .auto), .en)
        XCTAssertNil(TranscriptionModelChoice.whisperLarge.languageOverrideOnSelection(current: .auto))
    }

    func testUkrainianAvailabilityMatchesEveryBackend() throws {
        let available: Set<TranscriptionModelChoice> = [.whisperLarge, .parakeetUltra, .parakeetV3, .remoteServer]
        for choice in TranscriptionModelChoice.allCases {
            XCTAssertEqual(choice.isLanguageSelectable(.uk), available.contains(choice), choice.rawValue)
            if available.contains(choice) {
                XCTAssertNoThrow(try choice.validateLanguage("uk"), choice.rawValue)
            } else {
                XCTAssertThrowsError(try choice.validateLanguage("uk"), choice.rawValue)
            }
            XCTAssertNoThrow(try choice.validateLanguage(nil), choice.rawValue)
            XCTAssertNoThrow(try choice.validateLanguage("en"), choice.rawValue)
        }
        XCTAssertEqual(TranscriptionModelChoice.remoteServer.ukrainianSupport, .serverDependent)
        XCTAssertNotNil(TranscriptionModelChoice.remoteServer.languageSelectionMessage(for: .uk))
        XCTAssertFalse(TranscriptionModelChoice.graniteTurbo.isLanguageSelectable(.uk))
        XCTAssertTrue(TranscriptionModelChoice.graniteTurbo.isLanguageSelectable(.en))
    }

    func testMultilingualParakeetReceivesUkrainianButOnlyConstrainsScript() throws {
        for variant in [ParakeetEngine.Variant.ultra, .v3] {
            let hint = try XCTUnwrap(ParakeetEngine.languageHint("uk", variant: variant))
            XCTAssertEqual(hint, .ukrainian)
            XCTAssertEqual(hint.script, Language.russian.script)
            XCTAssertNil(try ParakeetEngine.languageHint(nil, variant: variant))
        }
        XCTAssertThrowsError(try ParakeetEngine.languageHint("uk", variant: .v2))
        for choice in [TranscriptionModelChoice.parakeetUltra, .parakeetV3] {
            XCTAssertEqual(choice.ukrainianSupport, .scriptHint)
            XCTAssertTrue(try XCTUnwrap(choice.languageSelectionMessage(for: .uk)).contains("cannot distinguish Ukrainian from Russian"))
        }
    }

    func testUnsupportedEnginesRejectUkrainianBeforeLoadingModelsOrAudio() async throws {
        let missingAudio = URL(fileURLWithPath: "/nonexistent/ukrainian-regression.wav")
        for choice in TranscriptionModelChoice.allCases where choice.ukrainianSupport == .unsupported {
            var settings = AppSettings()
            settings.transcriptionModel = choice
            settings.transcriptionLanguage = .uk
            let engine = settings.transcriptionEngine()
            // Exercise meeting, dictation/live-preview, and word-attribution entry points.
            for path in 0..<3 {
                do {
                    switch path {
                    case 0: _ = try await engine.transcribe(audio: missingAudio, language: "uk")
                    case 1: _ = try await engine.transcribe(audio: missingAudio, language: "uk", prompt: "Київ")
                    default: _ = try await engine.transcribeForWordAttribution(audio: missingAudio, language: "uk", prompt: "Київ")
                    }
                    XCTFail("\(choice) accepted Ukrainian on path \(path)")
                } catch {
                    if choice == .graniteTurbo {
                        guard case GraniteTurboError.unsupportedLanguage = error else {
                            return XCTFail("Expected language rejection, received \(error)")
                        }
                    } else {
                        XCTAssertEqual(error as? UnsupportedTranscriptionLanguage,
                                       .init(language: "Ukrainian", model: choice.displayName), "\(choice), path \(path)")
                    }
                }
            }
        }
    }
}
