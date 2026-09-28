import XCTest
@testable import LokalBot

/// CONTEXT.md names the model roles Transcribe, Think, and Autocomplete. Every
/// surface that labels a role must use those names.
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
        XCTAssertEqual(TranscriptionModelChoice.qwenASR17B.sizeLabel, "2.47 GB")
        XCTAssertEqual(TranscriptionModelChoice.parakeetV3.sizeLabel, "0.6 GB")
        XCTAssertNil(TranscriptionModelChoice.graniteSpeech.sizeLabel)
    }

    /// Each stated size must round to the bytes the engine actually downloads,
    /// at the label's own precision (decimal GB, matching the README).
    func testTranscriptionSizesMatchPinnedDownloads() throws {
        func total(_ snapshots: [PinnedModelSnapshot]) -> Int64 {
            snapshots.flatMap(\.files).reduce(0) { $0 + $1.bytes }
        }
        let downloads: [(TranscriptionModelChoice, Int64)] = try [
            (.parakeetV3, total([.catalog("parakeetV3")])),
            (.parakeetV2, total([.catalog("parakeetV2")])),
            (.qwenASR17B, total([.qwenAccuracy])),
            (.qwenASR06B, total([.qwenCompact])),
            (.whisperLarge, total([.catalog("whisper"), .catalog("whisperTokenizer")])),
            (.graniteTurbo, GraniteTurboEngine.artifacts.reduce(0) { $0 + $1.bytes }),
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
