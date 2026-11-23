import Foundation

enum LanguageCode: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case en
    case zh
    case zhHant = "zh-Hant"
    case yue
    case ja
    case ko
    case es
    case fr
    case de
    case pt
    case ptPT = "pt-PT"
    case ru
    case uk
    case ar
    case hi
    case it
    case nl
    case tr
    case pl
    case sv
    case da
    case no
    case nn
    case sr
    case hr
    case bs
    case cnr
    case bcms
    case th
    case vi

    var id: String { rawValue }

    static let transcriptionSupported: [LanguageCode] = [
        .en, .de, .es, .fr, .it, .nl, .pt, .pl, .sv, .da, .no, .tr,
        .ru, .uk, .sr, .zh, .yue, .ja, .ko, .ar, .hi, .th, .vi,
    ]

    static let summaryPresets: [LanguageCode] = [
        .en, .zh, .zhHant, .yue, .ja, .ko, .es, .fr, .de, .pt, .ptPT,
        .ru, .uk, .ar, .hi, .it, .nl, .tr, .pl, .sv, .da, .no, .nn,
        .bs, .hr, .cnr, .sr, .th, .vi,
    ]

    var summaryDisplayName: String {
        switch self {
        case .en: return "English"
        case .zh: return "Simplified Chinese (Mandarin)"
        case .zhHant: return "Traditional Chinese (Mandarin)"
        case .yue: return "Cantonese"
        case .ja: return "Japanese"
        case .ko: return "Korean"
        case .es: return "Spanish"
        case .fr: return "French"
        case .de: return "German"
        case .pt: return "Portuguese (Brazil)"
        case .ptPT: return "Portuguese (Portugal)"
        case .ru: return "Russian"
        case .uk: return "Ukrainian"
        case .ar: return "Arabic"
        case .hi: return "Hindi"
        case .it: return "Italian"
        case .nl: return "Dutch"
        case .tr: return "Turkish"
        case .pl: return "Polish"
        case .sv: return "Swedish"
        case .da: return "Danish"
        case .no: return "Norwegian (Bokmål)"
        case .nn: return "Norwegian (Nynorsk)"
        case .sr: return "Serbian"
        case .hr: return "Croatian"
        case .bs: return "Bosnian"
        case .cnr: return "Montenegrin"
        case .bcms: return "Bosnian, Croatian, Montenegrin, Serbian"
        case .th: return "Thai"
        case .vi: return "Vietnamese"
        }
    }

    var summaryPromptName: String {
        switch self {
        case .sr, .cnr:
            return summaryDisplayName + ", in the script the source text uses (Latin or Cyrillic)"
        case .bcms:
            return "the transcript's own language (Bosnian, Croatian, Montenegrin or Serbian), "
                + "keeping its ijekavian or ekavian forms and its script"
        default:
            return summaryDisplayName
        }
    }

    var transcriptionDisplayName: String {
        switch self {
        case .pt: return "Portuguese"
        case .no: return "Norwegian"
        case .zh: return "Chinese (Mandarin)"
        case .yue: return "Chinese (Cantonese)"
        default: return summaryDisplayName
        }
    }
}
