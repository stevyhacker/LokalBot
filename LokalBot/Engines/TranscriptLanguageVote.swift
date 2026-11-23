import Foundation
import NaturalLanguage

enum TranscriptLanguageVote {
    struct Result: Equatable {
        var code: String
        var share: Double
    }

    static func dominant(in texts: [String], minimumWords: Int = 3,
                         minimumConfidence: Double = 0.5,
                         aliases: [String: String] = [:]) -> Result? {
        var weights: [String: Double] = [:]
        var total = 0.0
        for text in texts where text.split(whereSeparator: \.isWhitespace).count >= minimumWords {
            guard let code = language(of: text, minimumConfidence: minimumConfidence) else { continue }
            weights[aliases[code] ?? code, default: 0] += Double(text.count)
            total += Double(text.count)
        }
        guard total > 0, let best = weights.max(by: { $0.value < $1.value }) else { return nil }
        return Result(code: best.key, share: best.value / total)
    }

    /// Whether every text long enough to judge reads as `code`. A text too short to judge is no
    /// evidence either way; one that reads as another language, or as none with confidence, is.
    static func unanimous(_ texts: [String], code: String, minimumWords: Int = 3,
                          minimumConfidence: Double = 0.5, aliases: [String: String] = [:]) -> Bool {
        texts.allSatisfy { text in
            guard text.split(whereSeparator: \.isWhitespace).count >= minimumWords else { return true }
            guard let heard = language(of: text, minimumConfidence: minimumConfidence) else { return false }
            return (aliases[heard] ?? heard) == code
        }
    }

    private static func language(of text: String, minimumConfidence: Double) -> String? {
        if SerbianLatinScript.isSerbianCyrillic(text) { return "sr" }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let top = recognizer.languageHypotheses(withMaximum: 1).max(by: { $0.value < $1.value }),
              top.value >= minimumConfidence else { return nil }
        return baseCode(top.key.rawValue)
    }

    static let serbianCroatianAliases: [String: String] = Dictionary(
        uniqueKeysWithValues: SerbianLatinScript.languageCodes.map { ($0, "hr") })

    static func baseCode(_ language: String) -> String {
        String(language.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first ?? "")
    }
}
