import XCTest
@testable import LokalBot

final class AppleSpeechLocaleResolverTests: XCTestCase {
    private let speechSupportedFixture: [String] = [
        "bn_IN", "de_AT", "de_CH", "de_DE", "en_AU", "en_CA", "en_GB", "en_IE",
        "en_IN", "en_NZ", "en_SG", "en_US", "en_ZA", "es_CL", "es_ES", "es_MX",
        "es_US", "fr_BE", "fr_CA", "fr_CH", "fr_FR", "gu_IN", "hi_IN", "it_CH",
        "it_IT", "ja_JP", "kn_IN", "ko_KR", "ks_IN", "mai_IN", "ml_IN", "mr_IN",
        "mul_IN", "ne_IN", "or_IN", "pa_IN", "pt_BR", "pt_PT", "ta_IN", "te_IN",
        "ur_IN", "yue_CN", "zh_CN", "zh_HK", "zh_TW",
    ]

    private let dictationSupportedFixture: [String] = [
        "ar_SA", "ca_ES", "cs_CZ", "da_DK", "de_AT", "de_CH", "de_DE", "el_GR",
        "en_AU", "en_CA", "en_GB", "en_IE", "en_IN", "en_NZ", "en_SG", "en_US",
        "en_ZA", "es_CL", "es_ES", "es_MX", "es_US", "fi_FI", "fr_BE", "fr_CA",
        "fr_CH", "fr_FR", "he_IL", "hi_IN", "hr_HR", "hu_HU", "id_ID", "it_CH",
        "it_IT", "ja_JP", "ko_KR", "ms_MY", "nb_NO", "nl_BE", "nl_NL", "pl_PL",
        "pt_BR", "pt_PT", "ro_RO", "ru_RU", "sk_SK", "sv_SE", "th_TH", "tr_TR",
        "uk_UA", "vi_VN", "yue_CN", "zh_CN", "zh_HK", "zh_TW",
    ]

    func testAvailabilityStateMapsOSAndDeviceSupport() {
        XCTAssertEqual(
            AppleSpeechAvailability.state(systemSupported: false, osSupported: false),
            .unavailable(reason: AppleSpeechAvailability.unsupportedMessage))
        XCTAssertEqual(
            AppleSpeechAvailability.state(systemSupported: true, osSupported: false),
            .unavailable(reason: AppleSpeechAvailability.unsupportedMessage))
        XCTAssertEqual(
            AppleSpeechAvailability.state(systemSupported: false, osSupported: true),
            .unavailable(reason: AppleSpeechAvailability.unavailableOnDeviceMessage))
        XCTAssertEqual(
            AppleSpeechAvailability.state(systemSupported: true, osSupported: true),
            .available)
    }

    @MainActor
    func testCurrentAvailabilityMatchesHostOS() {
        let state = AppleSpeechAvailability.current()
        if #available(macOS 26.0, *) {
            XCTAssertNotEqual(state.reason, AppleSpeechAvailability.unsupportedMessage)
        } else {
            XCTAssertEqual(state, .unavailable(reason: AppleSpeechAvailability.unsupportedMessage))
        }
    }

    func testAllSupportedLanguagesResolveDeterministicallyAcrossBothModules() throws {
        let expected: [(LanguageCode, String, AppleSpeechLocaleResolver.ModuleKind)] = [
            (.en, "en_US", .speechTranscriber),
            (.de, "de_DE", .speechTranscriber),
            (.es, "es_ES", .speechTranscriber),
            (.fr, "fr_FR", .speechTranscriber),
            (.it, "it_IT", .speechTranscriber),
            (.nl, "nl_NL", .dictationTranscriber),
            (.pt, "pt_BR", .speechTranscriber),
            (.pl, "pl_PL", .dictationTranscriber),
            (.sv, "sv_SE", .dictationTranscriber),
            (.da, "da_DK", .dictationTranscriber),
            (.no, "nb_NO", .dictationTranscriber),
            (.tr, "tr_TR", .dictationTranscriber),
            (.ru, "ru_RU", .dictationTranscriber),
            (.uk, "uk_UA", .dictationTranscriber),
            (.zh, "zh_CN", .speechTranscriber),
            (.yue, "yue_CN", .speechTranscriber),
            (.ja, "ja_JP", .speechTranscriber),
            (.ko, "ko_KR", .speechTranscriber),
            (.ar, "ar_SA", .dictationTranscriber),
            (.hi, "hi_IN", .speechTranscriber),
            (.th, "th_TH", .dictationTranscriber),
            (.vi, "vi_VN", .dictationTranscriber),
        ]

        let shuffledSpeech = speechSupportedFixture.reversed() + ["en_IN", "en_ZA"]
        let shuffledDictation = dictationSupportedFixture.reversed()

        for (code, expectedLocale, expectedModule) in expected {
            XCTAssertTrue(AppleSpeechLocaleResolver.isLanguageSupported(.language(code)), code.rawValue)
            let resolved = try AppleSpeechLocaleResolver.resolve(
                language: code.rawValue,
                preferredLanguages: [],
                speechSupported: Array(shuffledSpeech),
                speechInstalled: [],
                dictationSupported: Array(shuffledDictation),
                dictationInstalled: [])
            XCTAssertEqual(resolved.localeIdentifier, expectedLocale, code.rawValue)
            XCTAssertEqual(resolved.languageCode, code.rawValue, code.rawValue)
            XCTAssertEqual(resolved.module, expectedModule, code.rawValue)
        }
    }

    func testInstalledRegionalVariantTakesPrecedenceOverUnrelatedPreference() throws {
        let resolved = try AppleSpeechLocaleResolver.resolve(
            language: "en",
            preferredLanguages: ["fr-FR"],
            speechSupported: speechSupportedFixture,
            speechInstalled: ["en-GB"],
            dictationSupported: dictationSupportedFixture,
            dictationInstalled: [])
        XCTAssertEqual(resolved.localeIdentifier, "en_GB")
        XCTAssertEqual(resolved.module, .speechTranscriber)
    }

    func testAutoDetectFollowsPreferredLanguagesAndFallsBackToEnglish() throws {
        let turkish = try AppleSpeechLocaleResolver.resolve(
            language: nil,
            preferredLanguages: ["tr-TR", "en-US"],
            speechSupported: speechSupportedFixture,
            speechInstalled: [],
            dictationSupported: dictationSupportedFixture,
            dictationInstalled: [])
        XCTAssertEqual(turkish.localeIdentifier, "tr_TR")
        XCTAssertEqual(turkish.languageCode, "tr")
        XCTAssertEqual(turkish.module, .dictationTranscriber)

        let australian = try AppleSpeechLocaleResolver.resolve(
            language: "auto",
            preferredLanguages: ["en-AU"],
            speechSupported: speechSupportedFixture,
            speechInstalled: [],
            dictationSupported: dictationSupportedFixture,
            dictationInstalled: [])
        XCTAssertEqual(australian.localeIdentifier, "en_AU")
        XCTAssertEqual(australian.languageCode, "en")
        XCTAssertEqual(australian.module, .speechTranscriber)

        let skippedSerbian = try AppleSpeechLocaleResolver.resolve(
            language: nil,
            preferredLanguages: ["sr-Latn-RS"],
            speechSupported: speechSupportedFixture,
            speechInstalled: [],
            dictationSupported: dictationSupportedFixture,
            dictationInstalled: [])
        XCTAssertEqual(skippedSerbian.localeIdentifier, "en_US")
        XCTAssertEqual(skippedSerbian.languageCode, "en")
        XCTAssertEqual(skippedSerbian.module, .speechTranscriber)
    }

    func testSerbianIsRejectedDeterministically() throws {
        XCTAssertFalse(AppleSpeechLocaleResolver.isLanguageSupported(.language(.sr)))
        XCTAssertTrue(AppleSpeechLocaleResolver.isLanguageSupported(.auto))
        XCTAssertTrue(AppleSpeechLocaleResolver.isLanguageSupported(.uk))

        XCTAssertThrowsError(try AppleSpeechLocaleResolver.validateLanguage("sr")) { error in
            XCTAssertEqual(
                error as? UnsupportedTranscriptionLanguage,
                UnsupportedTranscriptionLanguage(language: "Serbian", model: "Apple Speech"))
        }
        XCTAssertThrowsError(try AppleSpeechLocaleResolver.resolve(
            language: " sr ",
            preferredLanguages: ["en-US"],
            speechSupported: speechSupportedFixture,
            speechInstalled: [],
            dictationSupported: dictationSupportedFixture,
            dictationInstalled: [])) { error in
            XCTAssertEqual(
                error as? UnsupportedTranscriptionLanguage,
                UnsupportedTranscriptionLanguage(language: "Serbian", model: "Apple Speech"))
        }
    }
}
