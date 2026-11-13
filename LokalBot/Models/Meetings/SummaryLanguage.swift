import Foundation
import NaturalLanguage

/// Target language for AI-generated summary notes. Distinct from
/// `TranscriptionLanguage`: that controls what WhisperKit/Parakeet listens
/// for, this controls what the LLM writes notes in. Default `.matchTranscript`
/// resolves the transcript text to a concrete language before prompt
/// construction. Ported from Seminarly's `SummaryLanguage`.
enum SummaryLanguage: Equatable, Hashable, Sendable {
    case matchTranscript
    case language(LanguageCode)
    case custom(String)

    static let en: SummaryLanguage = .language(.en)
    static let zh: SummaryLanguage = .language(.zh)
    static let zhHant: SummaryLanguage = .language(.zhHant)
    static let yue: SummaryLanguage = .language(.yue)
    static let ja: SummaryLanguage = .language(.ja)
    static let ko: SummaryLanguage = .language(.ko)
    static let es: SummaryLanguage = .language(.es)
    static let fr: SummaryLanguage = .language(.fr)
    static let de: SummaryLanguage = .language(.de)
    static let pt: SummaryLanguage = .language(.pt)
    static let ptPT: SummaryLanguage = .language(.ptPT)
    static let ru: SummaryLanguage = .language(.ru)
    static let ar: SummaryLanguage = .language(.ar)
    static let hi: SummaryLanguage = .language(.hi)
    static let it: SummaryLanguage = .language(.it)
    static let nl: SummaryLanguage = .language(.nl)
    static let tr: SummaryLanguage = .language(.tr)
    static let pl: SummaryLanguage = .language(.pl)
    static let sv: SummaryLanguage = .language(.sv)
    static let da: SummaryLanguage = .language(.da)
    static let no: SummaryLanguage = .language(.no)
    static let nn: SummaryLanguage = .language(.nn)
    static let th: SummaryLanguage = .language(.th)
    static let vi: SummaryLanguage = .language(.vi)

    /// Stable preset cases (excludes `.matchTranscript` and `.custom`) - used
    /// to drive Pickers without exposing two-mode logic.
    static let presets: [SummaryLanguage] = LanguageCode.summaryPresets.map { .language($0) }

    var displayName: String {
        switch self {
        case .matchTranscript: return "Match Transcript"
        case .language(let code): return code.summaryDisplayName
        case .custom(let name): return name.isEmpty ? "Custom" : name
        }
    }

    /// Name to drop into the LLM prompt (e.g. "Korean", "Klingon"). Returns
    /// nil for `.matchTranscript`, signalling the caller to inject no directive.
    var promptLanguageName: String? {
        switch self {
        case .matchTranscript:
            return nil
        case .language(let code):
            return code.summaryDisplayName
        case .custom(let name):
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    /// Resolve `.matchTranscript` against a transcript by running language
    /// detection; concrete languages are returned as-is.
    static func resolvedForTranscript(_ language: SummaryLanguage, transcript: String) -> SummaryLanguage {
        guard language == .matchTranscript else { return language }
        return detectTranscriptLanguage(transcript)
    }

    static func resolvedForTranscript(_ language: SummaryLanguage, transcript: Transcript) -> SummaryLanguage {
        guard language == .matchTranscript else { return language }
        return detectTranscriptLanguage(transcript.segments.map(\.displayText))
    }

    static func detectTranscriptLanguage(_ text: String) -> SummaryLanguage {
        detectTranscriptLanguage(detectionWindows(in: text))
    }

    /// Detect each bounded passage independently, then choose the language
    /// with the most material support. `NLLanguageRecognizer` can lock onto a
    /// foreign-language opening even when the rest of a long string is in a
    /// different language, so a single prefix must never decide a meeting.
    private static func detectTranscriptLanguage(_ passages: [String]) -> SummaryLanguage {
        let samples = distributedSamples(
            passages.flatMap(detectionWindows(in:)),
            limit: maximumDetectionSamples)
        guard !samples.isEmpty else { return .en }

        struct Evidence {
            var material = 0.0
            var confidence = 0.0
        }
        var evidence: [SummaryLanguage: Evidence] = [:]
        for sample in samples {
            guard let (language, confidence) = recognizedLanguage(in: sample) else { continue }
            let letters = sample.unicodeScalars.reduce(into: 0) { count, scalar in
                if CharacterSet.letters.contains(scalar) { count += 1 }
            }
            let material = min(1, Double(letters) / minimumFullVoteLetters)
            evidence[language, default: Evidence()].material += material
            evidence[language, default: Evidence()].confidence += confidence * material
        }

        return evidence.sorted { lhs, rhs in
            if lhs.value.material != rhs.value.material {
                return lhs.value.material > rhs.value.material
            }
            if lhs.value.confidence != rhs.value.confidence {
                return lhs.value.confidence > rhs.value.confidence
            }
            if lhs.key == .en { return true }
            if rhs.key == .en { return false }
            return lhs.key.displayName < rhs.key.displayName
        }.first?.key ?? .en
    }

    /// Whether most of a transcript is English, sampled across the meeting
    /// for the same reason as above. Languages outside the summary presets
    /// count as themselves here instead of falling back to English.
    static func isMostlyEnglish(_ transcript: Transcript) -> Bool {
        let samples = distributedSamples(detectionWindows(in: transcript.languageDetectionText), limit: maximumDetectionSamples)
        var english = 0.0
        var total = 0.0
        for sample in samples {
            let recognizer = NLLanguageRecognizer()
            recognizer.processString(sample)
            guard let language = recognizer.dominantLanguage else { continue }
            let letters = sample.unicodeScalars.reduce(into: 0) { count, scalar in
                if CharacterSet.letters.contains(scalar) { count += 1 }
            }
            let material = min(1, Double(letters) / minimumFullVoteLetters)
            total += material
            if language == .english { english += material }
        }
        return total == 0 || english * 2 >= total
    }

    private static func recognizedLanguage(in sample: String) -> (SummaryLanguage, Double)? {
        if let chinese = chineseScriptLanguage(in: sample) {
            return (chinese, 1)
        }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(sample)

        for (language, confidence) in recognizer.languageHypotheses(withMaximum: 5)
            .sorted(by: { $0.value > $1.value }) where confidence >= 0.15 {
            if let mapped = fromLanguageCode(language.rawValue, sample: sample) {
                return (mapped, confidence)
            }
        }
        if let dominant = recognizer.dominantLanguage,
           let mapped = fromLanguageCode(dominant.rawValue, sample: sample) {
            return (mapped, 0.1)
        }
        return nil
    }

    private static func detectionWindows(in text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let characters = Array(trimmed)
        guard characters.count > detectionWindowCharacters else { return [trimmed] }

        return stride(from: 0, to: characters.count, by: detectionWindowCharacters).map { start in
            let end = min(start + detectionWindowCharacters, characters.count)
            return String(characters[start..<end])
        }
    }

    private static func distributedSamples(_ samples: [String], limit: Int) -> [String] {
        let material = samples.filter { sample in
            sample.unicodeScalars.reduce(into: 0) { count, scalar in
                if CharacterSet.letters.contains(scalar) { count += 1 }
            } >= minimumDetectionLetters
        }
        guard material.count > limit else { return material }
        return (0..<limit).map { slot in
            let position = Double(slot) * Double(material.count - 1) / Double(limit - 1)
            return material[Int(position.rounded())]
        }
    }

    private static let detectionWindowCharacters = 400
    private static let maximumDetectionSamples = 32
    private static let minimumDetectionLetters = 12
    private static let minimumFullVoteLetters = 80.0

    static func fromLanguageCode(_ code: String?, sample: String = "") -> SummaryLanguage? {
        guard let code else { return nil }
        let normalized = code.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-")
            .lowercased()
        guard !normalized.isEmpty else { return nil }

        switch normalized {
        case "zh-hant", "zh-tw", "zh-hk": return .zhHant
        case "zh-hans", "zh-cn", "zh-sg", "zh":
            return chineseScriptLanguage(in: sample, allowLowSignal: true) ?? .zh
        case "pt-pt": return .ptPT
        case "nb", "no": return .no
        default:
            guard let language = LanguageCode(rawValue: normalized),
                  LanguageCode.summaryPresets.contains(language) else { return nil }
            return .language(language)
        }
    }

    // MARK: - Chinese script detection
    //
    // Simplified vs Traditional vs Cantonese is script, not language code - we
    // look at the character set to pick the right Mandarin variant (or
    // Cantonese when bopomofo appears).

    private static func chineseScriptLanguage(in text: String, allowLowSignal: Bool = false) -> SummaryLanguage? {
        var hanCount = 0
        var bopomofoCount = 0
        var traditionalOnlyCount = 0
        var simplifiedOnlyCount = 0
        var letterCount = 0

        for scalar in text.unicodeScalars {
            if CharacterSet.letters.contains(scalar) { letterCount += 1 }
            let value = scalar.value
            if isHanScalar(value) {
                hanCount += 1
                if traditionalOnlyScalars.contains(value) { traditionalOnlyCount += 1 }
                if simplifiedOnlyScalars.contains(value) { simplifiedOnlyCount += 1 }
            } else if isBopomofoScalar(value) {
                bopomofoCount += 1
            }
        }

        let chineseSignalCount = hanCount + bopomofoCount
        guard chineseSignalCount > 0 else { return nil }
        let ratio = Double(chineseSignalCount) / Double(max(letterCount, chineseSignalCount))
        let hasMaterial = chineseSignalCount >= 8 && (ratio >= 0.08 || chineseSignalCount >= 20)
        guard allowLowSignal || hasMaterial else { return nil }

        if bopomofoCount > 0 || traditionalOnlyCount > simplifiedOnlyCount { return .zhHant }
        if simplifiedOnlyCount > traditionalOnlyCount { return .zh }
        return .zh
    }

    private static func isHanScalar(_ value: UInt32) -> Bool {
        (0x3400...0x4DBF).contains(value)
            || (0x4E00...0x9FFF).contains(value)
            || (0xF900...0xFAFF).contains(value)
            || (0x20000...0x2A6DF).contains(value)
            || (0x2A700...0x2B73F).contains(value)
            || (0x2B740...0x2B81F).contains(value)
            || (0x2B820...0x2CEAF).contains(value)
    }

    private static func isBopomofoScalar(_ value: UInt32) -> Bool {
        (0x3100...0x312F).contains(value) || (0x31A0...0x31BF).contains(value)
    }

    private static let traditionalOnlyScalars: Set<UInt32> = [
        0x5167, 0x5718, 0x5834, 0x5C0D, 0x5F8C, 0x64C7, 0x6703, 0x6E96,
        0x7522, 0x78BA, 0x7E41, 0x7E8C, 0x807D, 0x8A0A, 0x8A0E, 0x8A9E,
        0x8AD6, 0x8AAA, 0x8B70, 0x8CC7, 0x9078, 0x9304, 0x9375, 0x95DC,
        0x968A, 0x9806, 0x986F, 0x994B, 0x9AD4, 0x9EDE,
    ]

    private static let simplifiedOnlyScalars: Set<UInt32> = [
        0x4EA7, 0x4F18, 0x4F1A, 0x4F53, 0x5173, 0x5185, 0x51C6, 0x540E,
        0x542C, 0x56E2, 0x573A, 0x5BF9, 0x5F55, 0x62E9, 0x663E, 0x70B9,
        0x786E, 0x7B80, 0x7EED, 0x8BAE, 0x8BA8, 0x8BAF, 0x8BED, 0x8BBA,
        0x8BF4, 0x9009, 0x961F, 0x987A, 0x9988, 0x952E,
    ]
}

// MARK: - RawRepresentable / Codable

extension SummaryLanguage: RawRepresentable {
    init?(rawValue: String) {
        switch rawValue {
        case "match":
            self = .matchTranscript
        default:
            if rawValue.hasPrefix("custom:") {
                self = .custom(String(rawValue.dropFirst("custom:".count)))
            } else if let code = LanguageCode(rawValue: rawValue),
                      LanguageCode.summaryPresets.contains(code) {
                self = .language(code)
            } else {
                return nil
            }
        }
    }

    var rawValue: String {
        switch self {
        case .matchTranscript: return "match"
        case .language(let code): return code.rawValue
        case .custom(let name): return "custom:\(name)"
        }
    }
}

extension SummaryLanguage: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        guard let language = Self(rawValue: rawValue) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unknown summary language: \(rawValue)"
            )
        }
        self = language
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
