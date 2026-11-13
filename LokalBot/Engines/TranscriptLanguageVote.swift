import Foundation
import NaturalLanguage

/// The dominant language of a transcript, voted over its segments by text
/// length. Apple's recognizer judges a long string mostly by its opening, so
/// classifying the joined transcript let one misdetected first window decide
/// a whole track (Benchmarks/transcribe/QwenSpanLength, language section).
enum TranscriptLanguageVote {
    struct Result: Equatable {
        /// Base ISO code, e.g. "zh" for "zh-Hans".
        var code: String
        /// Share of the voting text in this language, 0...1.
        var share: Double
    }

    /// Segments shorter than `minimumWords` or recognized with less than
    /// `minimumConfidence` do not vote: laughs and one-word replies are where
    /// Qwen's own auto-detection misfires. `aliases` counts several base
    /// codes as one language, keyed by the code they count as.
    static func dominant(in texts: [String], minimumWords: Int = 3,
                         minimumConfidence: Double = 0.5,
                         aliases: [String: String] = [:]) -> Result? {
        var weights: [String: Double] = [:]
        var total = 0.0
        for text in texts where text.split(whereSeparator: \.isWhitespace).count >= minimumWords {
            let code: String
            if SerbianLatinScript.isSerbianCyrillic(text) {
                code = "sr"
            } else {
                let recognizer = NLLanguageRecognizer()
                recognizer.processString(text)
                guard let top = recognizer.languageHypotheses(withMaximum: 1).max(by: { $0.value < $1.value }),
                      top.value >= minimumConfidence else { continue }
                code = baseCode(top.key.rawValue)
            }
            weights[aliases[code] ?? code, default: 0] += Double(text.count)
            total += Double(text.count)
        }
        guard total > 0, let best = weights.max(by: { $0.value < $1.value }) else { return nil }
        return Result(code: best.key, share: best.value / total)
    }

    /// Serbian, Croatian, Bosnian and Montenegrin are one language to a
    /// speech model. Apple's recognizer reads all of them in Latin script as
    /// Croatian (Benchmarks/transcribe/DualASR) and Serbian Cyrillic as Kazakh, so
    /// Cyrillic with Serbian's own letters votes Serbian instead. They vote
    /// together, as Croatian.
    static let serbianCroatianAliases: [String: String] = Dictionary(
        uniqueKeysWithValues: SerbianLatinScript.languageCodes.map { ($0, "hr") })

    /// "zh-Hant" → "zh", "pt_PT" → "pt".
    static func baseCode(_ language: String) -> String {
        String(language.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first ?? "")
    }
}
