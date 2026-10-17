import XCTest
@testable import LokalBot

final class AppLanguageTests: XCTestCase {
    func testSystemLanguageUsesSupportedPreferencesAndFallsBackToEnglish() {
        XCTAssertEqual(AppLanguage.system.localizationIdentifier(preferredLanguages: ["zh-Hans-CN", "en"]), "zh-Hans")
        XCTAssertEqual(AppLanguage.system.localizationIdentifier(preferredLanguages: ["zh-TW"]), "zh-Hans")
        XCTAssertEqual(AppLanguage.system.localizationIdentifier(preferredLanguages: ["fr-FR", "zh_CN"]), "fr")
        XCTAssertEqual(AppLanguage.system.localizationIdentifier(preferredLanguages: ["en-GB", "zh-Hans"]), "en")
        XCTAssertEqual(AppLanguage.system.localizationIdentifier(preferredLanguages: ["it-IT"]), "en")
        XCTAssertEqual(AppLanguage.system.localizationIdentifier(preferredLanguages: []), "en")
    }

    func testRegionalAndScriptVariantsResolveToSupportedCatalogs() {
        let variants = ["hi-IN": "hi", "es-MX": "es", "ar-SA": "ar", "fr_CA": "fr",
                        "bn-BD": "bn", "pt-BR": "pt", "pt-PT": "pt", "id-ID": "id",
                        "ur-Arab-PK": "ur", "arz": "ar-EG",
                        "ru-RU": "ru", "de-AT": "de", "ja-JP": "ja", "pcm-NG": "pcm",
                        "mr-IN": "mr", "vi-VN": "vi", "te-IN": "te", "sw-KE": "sw", "ha-Latn-NG": "ha",
                        "ko-KR": "ko", "ko_KP": "ko", "ko-Hang-KR": "ko"]
        for (variant, expected) in variants {
            XCTAssertEqual(AppLanguage.system.localizationIdentifier(preferredLanguages: [variant]), expected)
            XCTAssertEqual(AppLanguage.matching(Locale(identifier: variant)).rawValue, expected)
        }
        XCTAssertEqual(AppLanguage.system.localizationIdentifier(preferredLanguages: ["it-IT", "ur-PK", "en"]), "ur")
    }

    func testArabicVarietiesAndUrduUseRightToLeftLayout() {
        for language in AppLanguage.allCases where language != .system {
            XCTAssertEqual(language.isRightToLeft, language == .arabic || language == .egyptianArabic || language == .urdu)
        }
    }

    func testEgyptianArabicAndStandardArabicRemainDistinct() {
        XCTAssertEqual(AppLanguage.system.localizationIdentifier(preferredLanguages: ["ar-EG", "ar"]), "ar")
        XCTAssertEqual(AppLanguage.system.localizationIdentifier(preferredLanguages: ["ar", "ar-EG"]), "ar")
        for regionalArabic in ["AR_eg", "ar-Arab-EG", "ar-SA"] {
            XCTAssertEqual(AppLanguage.system.localizationIdentifier(preferredLanguages: [regionalArabic]), "ar")
        }
        XCTAssertEqual(AppLanguage.system.localizationIdentifier(preferredLanguages: ["arz-EG", "ar"]), "ar-EG")
        XCTAssertEqual(AppLanguage.egyptianArabic.localizationIdentifier(preferredLanguages: ["ar"]), "ar-EG")
        XCTAssertEqual(AppLanguage.matching(AppLanguage.egyptianArabic.locale), .egyptianArabic)
        XCTAssertNotEqual(AppLanguage.egyptianArabic.localized("Enable the Access You Need"),
                          AppLanguage.arabic.localized("Enable the Access You Need"))
    }

    func testNativeLanguageNamesRemainRecognizable() {
        for language in AppLanguage.allCases where language != .system {
            for interfaceLanguage in AppLanguage.allCases {
                XCTAssertEqual(language.pickerLabel(in: interfaceLanguage), language.displayName)
            }
        }
        XCTAssertEqual(AppLanguage.system.pickerLabel(in: .simplifiedChinese), "跟随系统")
    }

    func testEveryLanguageHasBundledTranslationsAndMissingKeyFallback() {
        for language in AppLanguage.allCases where language != .system {
            XCTAssertEqual(language.localizationIdentifier(preferredLanguages: ["en"]), language.rawValue)
            if language != .english {
                XCTAssertNotEqual(language.localized("App language"), "App language", language.rawValue)
            }
            XCTAssertEqual(language.localized("unknown.localization.key"), "unknown.localization.key")
        }
    }

    func testExplicitSelectionOverridesSystemLanguage() {
        XCTAssertEqual(AppLanguage.english.localizationIdentifier(preferredLanguages: ["zh-Hans"]), "en")
        XCTAssertEqual(AppLanguage.simplifiedChinese.localizationIdentifier(preferredLanguages: ["en"]), "zh-Hans")
    }

    func testLanguagePreferencePersistsWithoutChangingContentLanguages() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "AppLanguageTests.\(UUID().uuidString)"))
        defer { defaults.removeObject(forKey: AppSettings.key) }
        for language in AppLanguage.allCases {
            var settings = AppSettings()
            settings.appLanguage = language
            let transcriptionLanguage = settings.transcriptionLanguage
            let summaryLanguage = settings.summaryLanguage
            settings.save(to: defaults)
            let restored = AppSettings.load(from: defaults)
            XCTAssertEqual(restored.appLanguage, language)
            XCTAssertEqual(restored.transcriptionLanguage, transcriptionLanguage)
            XCTAssertEqual(restored.summaryLanguage, summaryLanguage)
        }
    }

    func testLegacyAndUnknownLanguageDoNotResetOtherSettings() throws {
        XCTAssertEqual(AppSettings().appLanguage, .system)
        for json in [#"{"menuBarOnly":false}"#, #"{"menuBarOnly":false,"appLanguage":"future-language"}"#] {
            let settings = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
            XCTAssertEqual(settings.appLanguage, .system)
            XCTAssertFalse(settings.menuBarOnly)
        }
    }

    func testUserEnteredSettingsValuesAreNotTranslated() throws {
        let descriptor = try XCTUnwrap(SettingDescriptor.all.first { $0.id == "settings.cotypingUserName" })
        var settings = AppSettings()
        settings.cotypingUserName = "Settings"
        XCTAssertEqual(descriptor.currentValue(in: settings, language: .simplifiedChinese), "Settings")
    }

    /// SwiftUI resolves every label through the injected app-language locale,
    /// and Foundation re-reads the table on each such lookup. UTF-16 text
    /// tables made switching Settings categories take seconds.
    func testBundledStringTablesAreBinary() throws {
        for language in AppLanguage.allCases.filter({ $0 != .system }).map(\.rawValue) {
            let url = try XCTUnwrap(Bundle.main.url(
                forResource: "Localizable", withExtension: "strings",
                subdirectory: nil, localization: language))
            var format = PropertyListSerialization.PropertyListFormat.xml
            _ = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: &format)
            XCTAssertEqual(format, .binary, language)
        }
    }

    func testBundledChineseAndEnglishAndMissingKeyFallback() {
        XCTAssertEqual(AppLanguage.simplifiedChinese.localized("Settings"), "设置")
        XCTAssertEqual(AppLanguage.simplifiedChinese.localized("App language"), "界面语言")
        XCTAssertEqual(AppLanguage.english.localized("Settings"), "Settings")
        XCTAssertEqual(AppLanguage.simplifiedChinese.localized("unknown.localization.key"), "unknown.localization.key")
    }

    @MainActor
    func testSettingsSearchFindsTranslatedLabelsAndLanguageAliases() {
        for query in ["语言", "中文", "English", "界面语言", "Korean"] + AppLanguage.allCases.map(\.displayName) {
            XCTAssertTrue(SettingDescriptor.search(query, language: .simplifiedChinese).contains { $0.id == "settings.appLanguage" })
        }
        XCTAssertTrue(SettingDescriptor.search("文字大小", language: .simplifiedChinese).contains { $0.id == "settings.textSize" })
        XCTAssertTrue(SettingDescriptor.search("Theme", language: .simplifiedChinese).contains { $0.id == "settings.appTheme" })
    }
}
