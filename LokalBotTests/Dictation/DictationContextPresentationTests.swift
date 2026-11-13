import XCTest
@testable import LokalBot

/// The Dictation page explains what the Compose context settings contributed.
@MainActor
final class DictationContextPresentationTests: XCTestCase {
    func testLastResultSaysWhichContextWasUsed() {
        XCTAssertTrue(DictationContextUse(wasWritingRequest: false).summary().hasPrefix("Cleanup only."))
        XCTAssertEqual(DictationContextUse(wasWritingRequest: true).summary(),
                       "Writing request. No enabled context matched it.")
        XCTAssertEqual(DictationContextUse(
            wasWritingRequest: true, focusedWindow: true, visibleText: true,
            savedFactSources: ["Marigold", "Thistle"]).summary(),
            "Used: focused window; visible text; saved facts from Marigold, Thistle")
        XCTAssertEqual(DictationContextUse(wasWritingRequest: true, visibleText: true).summary(),
                       "Used: visible text")
    }

    func testSummaryUsesTheInterfaceLanguage() {
        let chinese = DictationContextUse(wasWritingRequest: true, visibleText: true)
            .summary { AppLanguage.simplifiedChinese.localized($0) }
        XCTAssertEqual(chinese, "已使用：可见文字")
    }

    func testWritingProfileSummaryNamesWhatIsSet() {
        var settings = AppSettings()
        settings.cotypingUserName = ""
        settings.cotypingStyleNote = ""
        settings.cotypingLanguages = ""
        settings.cotypingExtendedContext = ""
        XCTAssertEqual(DictationView.writingProfileSummary(settings), "Not set")
        settings.cotypingUserName = "Goran"
        settings.cotypingLanguages = "Serbian, English"
        XCTAssertEqual(DictationView.writingProfileSummary(settings), "Name, Languages")
    }

    func testWindowContextAndWritingProfileAreSearchable() {
        for id in ["settings.dictationUseScreenContext", "settings.dictationWritingProfile"] {
            let descriptor = SettingDescriptor.all.first { $0.id == id }
            XCTAssertEqual(descriptor?.category, .dictation, id)
        }
        XCTAssertTrue(SettingDescriptor.search("screenshot").contains { $0.id == "settings.dictationUseScreenContext" })
    }
}
