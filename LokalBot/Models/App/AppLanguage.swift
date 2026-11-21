import Foundation

enum AppLanguage: String, Codable, CaseIterable, Identifiable, Sendable {
    case system
    case english = "en"
    case simplifiedChinese = "zh-Hans"
    case traditionalChinese = "zh-Hant"
    case hindi = "hi"
    case spanish = "es"
    case arabic = "ar"
    case french = "fr"
    case bengali = "bn"
    case portuguese = "pt"
    case indonesian = "id"
    case urdu = "ur"
    case russian = "ru"
    case german = "de"
    case japanese = "ja"
    case nigerianPidgin = "pcm"
    case egyptianArabic = "ar-EG"
    case marathi = "mr"
    case vietnamese = "vi"
    case telugu = "te"
    case swahili = "sw"
    case hausa = "ha"
    case korean = "ko"
    case italian = "it"
    case serbianLatin = "sr-Latn"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: "Follow System"
        case .english: "English"
        case .simplifiedChinese: "简体中文"
        case .traditionalChinese: "繁體中文"
        case .hindi: "हिन्दी"
        case .spanish: "Español"
        case .arabic: "العربية"
        case .french: "Français"
        case .bengali: "বাংলা"
        case .portuguese: "Português"
        case .indonesian: "Bahasa Indonesia"
        case .urdu: "اردو"
        case .russian: "Русский"
        case .german: "Deutsch"
        case .japanese: "日本語"
        case .nigerianPidgin: "Naijá"
        case .egyptianArabic: "مصري"
        case .marathi: "मराठी"
        case .vietnamese: "Tiếng Việt"
        case .telugu: "తెలుగు"
        case .swahili: "Kiswahili"
        case .hausa: "Hausa"
        case .korean: "한국어"
        case .italian: "Italiano"
        case .serbianLatin: "Srpski (latinica)"
        }
    }

    var englishName: String {
        switch self {
        case .system: "Follow System"
        case .english: "English"
        case .simplifiedChinese: "Simplified Chinese"
        case .traditionalChinese: "Traditional Chinese"
        case .hindi: "Hindi"
        case .spanish: "Spanish"
        case .arabic: "Arabic"
        case .french: "French"
        case .bengali: "Bengali"
        case .portuguese: "Portuguese"
        case .indonesian: "Indonesian"
        case .urdu: "Urdu"
        case .russian: "Russian"
        case .german: "German"
        case .japanese: "Japanese"
        case .nigerianPidgin: "Nigerian Pidgin"
        case .egyptianArabic: "Egyptian Arabic"
        case .marathi: "Marathi"
        case .vietnamese: "Vietnamese"
        case .telugu: "Telugu"
        case .swahili: "Swahili"
        case .hausa: "Hausa"
        case .korean: "Korean"
        case .italian: "Italian"
        case .serbianLatin: "Serbian (Latin)"
        }
    }

    func localizationIdentifier(preferredLanguages: [String] = Locale.preferredLanguages) -> String {
        guard self == .system else { return rawValue }
        for language in preferredLanguages {
            let code = language.replacingOccurrences(of: "_", with: "-").lowercased()
            let parts = code.split(separator: "-").map(String.init)
            let base = parts.first ?? ""
            if base == "zh" {
                let subtags = parts.dropFirst()
                let traditional = subtags.contains("hant")
                    || (!subtags.contains("hans") && subtags.contains { ["tw", "hk", "mo"].contains($0) })
                return traditional ? Self.traditionalChinese.rawValue : Self.simplifiedChinese.rawValue
            }
            if base == "sr" || base == "cnr" {
                return Self.serbianLatin.rawValue
            }
            if base == "arz" {
                return Self.egyptianArabic.rawValue
            }
            if let supported = Self(rawValue: base), supported != .system { return supported.rawValue }
        }
        return "en"
    }

    var locale: Locale { Locale(identifier: localizationIdentifier()) }

    var isRightToLeft: Bool { Self.isRightToLeft(locale) }

    static func isRightToLeft(_ locale: Locale) -> Bool {
        locale.language.characterDirection == .rightToLeft
    }

    func pickerLabel(in interfaceLanguage: Self) -> String {
        self == .system ? interfaceLanguage.localized(displayName) : displayName
    }

    static func matching(_ locale: Locale) -> Self {
        if let selected = Self(rawValue: locale.identifier), selected != .system { return selected }
        let identifier = Self.system.localizationIdentifier(preferredLanguages: [locale.identifier])
        return Self(rawValue: identifier) ?? .english
    }

    func localized(_ key: String, bundle: Bundle = .main) -> String {
        guard let path = bundle.path(forResource: localizationIdentifier(), ofType: "lproj"),
              let localizedBundle = Bundle(path: path) else { return key }
        return localizedBundle.localizedString(forKey: key, value: key, table: nil)
    }

    var catalog: (String) -> String { { localized($0) } }
}
