import Foundation

#if canImport(Speech)
import Speech
#endif

enum AppleSpeechLocaleResolver {
    enum ModuleKind: String, Equatable, Sendable {
        case speechTranscriber
        case dictationTranscriber
    }

    struct Resolution: Equatable, Sendable {
        let localeIdentifier: String
        let languageCode: String
        let module: ModuleKind

        var locale: Locale { Locale(identifier: localeIdentifier) }
    }

    enum ResolutionError: LocalizedError, Equatable, Sendable {
        case noSupportedLocales

        var errorDescription: String? {
            switch self {
            case .noSupportedLocales:
                return "Apple Speech has no supported languages on this Mac."
            }
        }
    }

    static let modelDisplayName = "Apple Speech"

    static let canonicalLocale: [String: String] = [
        "en": "en_US",
        "de": "de_DE",
        "es": "es_ES",
        "fr": "fr_FR",
        "it": "it_IT",
        "nl": "nl_NL",
        "pt": "pt_BR",
        "pl": "pl_PL",
        "sv": "sv_SE",
        "da": "da_DK",
        "no": "nb_NO",
        "tr": "tr_TR",
        "ru": "ru_RU",
        "uk": "uk_UA",
        "zh": "zh_CN",
        "yue": "yue_CN",
        "ja": "ja_JP",
        "ko": "ko_KR",
        "ar": "ar_SA",
        "hi": "hi_IN",
        "th": "th_TH",
        "vi": "vi_VN",
    ]

    static func isLanguageSupported(_ language: TranscriptionLanguage) -> Bool {
        language != .language(.sr)
    }

    static func validateLanguage(_ code: String?, modelName: String = modelDisplayName) throws {
        guard let normalized = normalizedCode(code) else { return }
        guard normalized != "sr", canonicalLocale[normalized] != nil else {
            throw UnsupportedTranscriptionLanguage(
                language: displayLanguageName(for: normalized),
                model: modelName)
        }
    }

    static func resolve(
        language: String?,
        preferredLanguages: [String],
        speechSupported: [String],
        speechInstalled: [String],
        dictationSupported: [String],
        dictationInstalled: [String]
    ) throws -> Resolution {
        try validateLanguage(language)

        let speechSupportedSorted = normalizedSorted(speechSupported)
        let speechInstalledSorted = normalizedSorted(speechInstalled)
        let dictationSupportedSorted = normalizedSorted(dictationSupported)
        let dictationInstalledSorted = normalizedSorted(dictationInstalled)
        let preferredNormalized = preferredLanguages.flatMap(normalizedPreferredVariants)

        if let code = normalizedCode(language) {
            if let resolution = resolveExplicit(
                code: code,
                preferred: preferredNormalized,
                speechSupported: speechSupportedSorted,
                speechInstalled: speechInstalledSorted,
                dictationSupported: dictationSupportedSorted,
                dictationInstalled: dictationInstalledSorted) {
                return resolution
            }
            throw UnsupportedTranscriptionLanguage(
                language: displayLanguageName(for: code),
                model: modelDisplayName)
        }

        for preferred in preferredNormalized {
            guard let code = lokalbotLanguageCode(for: preferred) else { continue }
            if let resolution = resolveExplicit(
                code: code,
                preferred: preferredNormalized,
                speechSupported: speechSupportedSorted,
                speechInstalled: speechInstalledSorted,
                dictationSupported: dictationSupportedSorted,
                dictationInstalled: dictationInstalledSorted) {
                return resolution
            }
        }

        if let english = resolveExplicit(
            code: "en",
            preferred: preferredNormalized,
            speechSupported: speechSupportedSorted,
            speechInstalled: speechInstalledSorted,
            dictationSupported: dictationSupportedSorted,
            dictationInstalled: dictationInstalledSorted) {
            return english
        }

        for code in canonicalLocale.keys.sorted() {
            if let resolution = resolveExplicit(
                code: code,
                preferred: preferredNormalized,
                speechSupported: speechSupportedSorted,
                speechInstalled: speechInstalledSorted,
                dictationSupported: dictationSupportedSorted,
                dictationInstalled: dictationInstalledSorted) {
                return resolution
            }
        }

        throw ResolutionError.noSupportedLocales
    }

    #if canImport(Speech)
    @available(macOS 26.0, *)
    static func resolveLive(
        language: String?,
        preferredLanguages: [String] = Locale.preferredLanguages
    ) async throws -> Resolution {
        try validateLanguage(language)
        async let speechSupported = SpeechTranscriber.supportedLocales.map(\.identifier)
        async let speechInstalled = SpeechTranscriber.installedLocales.map(\.identifier)
        async let dictationSupported = DictationTranscriber.supportedLocales.map(\.identifier)
        async let dictationInstalled = DictationTranscriber.installedLocales.map(\.identifier)
        return try await resolve(
            language: language,
            preferredLanguages: preferredLanguages,
            speechSupported: speechSupported,
            speechInstalled: speechInstalled,
            dictationSupported: dictationSupported,
            dictationInstalled: dictationInstalled)
    }
    #endif

    private static func resolveExplicit(
        code: String,
        preferred: [String],
        speechSupported: [String],
        speechInstalled: [String],
        dictationSupported: [String],
        dictationInstalled: [String]
    ) -> Resolution? {
        if let localeID = pickVariant(
            for: code,
            supported: speechSupported,
            installed: speechInstalled,
            preferred: preferred) {
            return Resolution(localeIdentifier: localeID, languageCode: code, module: .speechTranscriber)
        }
        if let localeID = pickVariant(
            for: code,
            supported: dictationSupported,
            installed: dictationInstalled,
            preferred: preferred) {
            return Resolution(localeIdentifier: localeID, languageCode: code, module: .dictationTranscriber)
        }
        return nil
    }

    private static func pickVariant(
        for code: String,
        supported: [String],
        installed: [String],
        preferred: [String]
    ) -> String? {
        let supportedSet = Set(supported)
        let installedSet = Set(installed)

        if let match = preferred.first(where: {
            matchesLanguage($0, code: code) && installedSet.contains($0) && supportedSet.contains($0)
        }) {
            return match
        }
        if let match = installed.first(where: {
            matchesLanguage($0, code: code) && supportedSet.contains($0)
        }) {
            return match
        }
        if let match = preferred.first(where: {
            matchesLanguage($0, code: code) && supportedSet.contains($0)
        }) {
            return match
        }
        for fallback in canonicalCandidates(for: code) where supportedSet.contains(fallback) {
            return fallback
        }
        return supported.first { matchesLanguage($0, code: code) }
    }

    private static func canonicalCandidates(for code: String) -> [String] {
        if code == "yue" { return ["yue_CN", "zh_HK"] }
        return canonicalLocale[code].map { [$0] } ?? []
    }

    static func matchesLanguage(_ localeID: String, code: String) -> Bool {
        let (lang, region) = languageAndRegion(from: normalizeIdentifier(localeID))
        switch code.lowercased() {
        case "no":
            return lang == "no" || lang == "nb" || lang == "nn"
        case "yue":
            return lang == "yue" || (lang == "zh" && region == "HK")
        case "zh":
            return lang == "zh" && region != "HK"
        default:
            return lang == code.lowercased()
        }
    }

    private static func lokalbotLanguageCode(for normalizedID: String) -> String? {
        let (lang, region) = languageAndRegion(from: normalizedID)
        let candidate: String
        if lang == "nb" || lang == "nn" {
            candidate = "no"
        } else if lang == "zh" && region == "HK" {
            candidate = "yue"
        } else {
            candidate = lang
        }
        return canonicalLocale[candidate] != nil ? candidate : nil
    }

    private static func normalizedCode(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !trimmed.isEmpty, trimmed != "auto" else { return nil }
        return trimmed
    }

    private static func displayLanguageName(for code: String) -> String {
        LanguageCode(rawValue: code)?.transcriptionDisplayName ?? code
    }

    private static func normalizedSorted(_ identifiers: [String]) -> [String] {
        Array(Set(identifiers.map(normalizeIdentifier).filter { !$0.isEmpty })).sorted()
    }

    private static func normalizedPreferredVariants(_ raw: String) -> [String] {
        let normalized = normalizeIdentifier(raw)
        guard !normalized.isEmpty else { return [] }
        if normalized.lowercased() == "zh_hant" {
            return ["zh_TW", normalized]
        }
        return [normalized]
    }

    private static func normalizeIdentifier(_ raw: String) -> String {
        let parts = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "_")
            .split(separator: "_")
            .map(String.init)
        guard let first = parts.first, !first.isEmpty else { return "" }
        let lang = first.lowercased()
        if parts.count >= 3, parts[1].count == 4 {
            return "\(lang)_\(parts[2].uppercased())"
        }
        if parts.count >= 2 {
            let second = parts[1]
            let formatted = second.count == 4
                ? second.prefix(1).uppercased() + second.dropFirst().lowercased()
                : second.uppercased()
            return "\(lang)_\(formatted)"
        }
        return lang
    }

    private static func languageAndRegion(from normalizedID: String) -> (language: String, region: String?) {
        let parts = normalizedID.split(separator: "_").map(String.init)
        let lang = parts.first?.lowercased() ?? ""
        let region = parts.count > 1 ? parts.last?.uppercased() : nil
        return (lang, region)
    }
}
