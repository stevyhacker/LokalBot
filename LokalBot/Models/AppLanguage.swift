import Foundation

/// Interface language only. Speech recognition and generated notes keep their
/// own preferences; changing the interface never changes stored user content.
enum AppLanguage: String, Codable, CaseIterable, Identifiable, Sendable {
    case system
    case english = "en"
    case simplifiedChinese = "zh-Hans"
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

    var id: String { rawValue }

    /// Native names keep the language picker recognizable regardless of the current interface language.
    var displayName: String {
        switch self {
        case .system: "Follow System"
        case .english: "English"
        case .simplifiedChinese: "简体中文"
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
        }
    }

    func localizationIdentifier(preferredLanguages: [String] = Locale.preferredLanguages) -> String {
        guard self == .system else { return rawValue }
        for language in preferredLanguages {
            let code = language.replacingOccurrences(of: "_", with: "-").lowercased()
            if code == "zh" || code.hasPrefix("zh-") { return "zh-Hans" }
            let base = String(code.split(separator: "-").first ?? "")
            // A system ar-EG preference is Arabic with region Egypt, not a
            // dialect choice. Only the language code arz selects Egyptian Arabic.
            if base == "arz" {
                return Self.egyptianArabic.rawValue
            }
            if let supported = Self(rawValue: base), supported != .system { return supported.rawValue }
        }
        return "en"
    }

    var locale: Locale { Locale(identifier: localizationIdentifier()) }

    var isRightToLeft: Bool {
        ["ar", "ar-EG", "ur"].contains(localizationIdentifier())
    }

    /// Translate only the system option; language names remain native so a
    /// person can recover from accidentally selecting an unfamiliar language.
    func pickerLabel(in interfaceLanguage: Self) -> String {
        self == .system ? interfaceLanguage.localized(displayName) : displayName
    }

    /// Native text-field bridges receive the locale from their SwiftUI parent.
    static func matching(_ locale: Locale) -> Self {
        // These bridges receive the selected catalog locale, so an explicit
        // Egyptian Arabic choice must stay ar-EG instead of following system rules.
        if let selected = Self(rawValue: locale.identifier), selected != .system { return selected }
        let identifier = Self.system.localizationIdentifier(preferredLanguages: [locale.identifier])
        return Self(rawValue: identifier) ?? .english
    }

    /// AppKit menus and settings search do not read SwiftUI's locale. Resolve
    /// their app-owned labels explicitly without changing AppleLanguages or
    /// replacing Bundle.main (which would affect other frameworks).
    func localized(_ key: String, bundle: Bundle = .main) -> String {
        guard let path = bundle.path(forResource: localizationIdentifier(), ofType: "lproj"),
              let localizedBundle = Bundle(path: path) else { return key }
        return localizedBundle.localizedString(forKey: key, value: key, table: nil)
    }
}
