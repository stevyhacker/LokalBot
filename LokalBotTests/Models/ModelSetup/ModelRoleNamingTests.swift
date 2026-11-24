import XCTest
@testable import LokalBot

@MainActor
final class ModelRoleNamingTests: XCTestCase {
    func testRoleTitlesMatchTheGlossary() {
        XCTAssertEqual(ModelRole.allCases.map(\.settingsTitle), ["Transcribe", "Think", "Autocomplete"])
    }

    func testPickerTitlesMatchRoleTitles() {
        XCTAssertEqual(ModelPickerRole.transcription.title, ModelRole.transcribe.settingsTitle)
        XCTAssertEqual(ModelPickerRole.assistant.title, ModelRole.think.settingsTitle)
        XCTAssertEqual(ModelPickerRole.autocomplete.title, ModelRole.autocomplete.settingsTitle)
    }

    func testSettingsSearchTitlesAvoidLegacyLLMNaming() {
        let titles = SettingDescriptor.all.map(\.title)
        XCTAssertFalse(titles.contains { $0.localizedCaseInsensitiveContains("LLM") }, "\(titles)")
        XCTAssertFalse(SettingDescriptor.search("main llm").isEmpty,
                       "The legacy name should still find the Think backend setting")
    }
}

final class ModelStorageCopyTests: XCTestCase {
    func testTranscriptionSizesComeFromTheBlurb() {
        XCTAssertEqual(TranscriptionModelChoice.qwenASR17B.sizeLabel, "2.52 GB")
        XCTAssertEqual(TranscriptionModelChoice.parakeetV3.sizeLabel, "0.6 GB")
        XCTAssertNil(TranscriptionModelChoice.graniteSpeech.sizeLabel)
    }

    func testTranscriptionSizesMatchPinnedDownloads() throws {
        func total(_ snapshots: [PinnedModelSnapshot]) -> Int64 {
            snapshots.flatMap(\.files).reduce(0) { $0 + $1.bytes }
        }
        let downloads: [(TranscriptionModelChoice, Int64)] = try [
            (.parakeetUltra, total([.catalog("parakeetUltra")])),
            (.parakeetV3, total([.catalog("parakeetV3")])),
            (.parakeetV2, total([.catalog("parakeetV2")])),
            (.qwenASR17BLokalBotV3, QwenLlamaASR.accuracyLokalBotV3.totalBytes),
            (.qwenASR17B, QwenLlamaASR.accuracy.totalBytes),
            (.qwenASR06BLokalBotV1, QwenLlamaASR.compactLokalBotV1.totalBytes),
            (.qwenASR06B, QwenLlamaASR.compact.totalBytes),
            (.whisperLarge, total([.catalog("whisper"), .catalog("whisperTokenizer")])),
            (.graniteSpeech5, GraniteSpeechModelConfiguration.speech5.model.sizeBytes
                + GraniteSpeechModelConfiguration.speech5.projector.sizeBytes),
        ]
        for (choice, bytes) in downloads {
            let label = try XCTUnwrap(choice.sizeLabel, choice.rawValue)
            XCTAssertTrue(label.hasSuffix(" GB"), label)
            let number = label.dropLast(" GB".count)
            let decimals = number.split(separator: ".").dropFirst().first?.count ?? 0
            XCTAssertEqual(String(number),
                           String(format: "%.\(decimals)f", Double(bytes) / 1e9),
                           "\(choice.rawValue): \(bytes) bytes")
        }
    }
}
