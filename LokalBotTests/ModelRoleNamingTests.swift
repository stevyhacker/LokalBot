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
