import Foundation
import NaturalLanguage

nonisolated enum CotypingSpellLanguageGate {
    static let contextWindowCharacters = 200
    static let minimumConfidence = 0.5
    static let minimumWordCount = 2

    static func spellVerdictsApply(context: String, availableLanguages: [String]) -> Bool {
        let window = String(context.suffix(contextWindowCharacters))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !window.isEmpty else { return true }
        guard window.split(whereSeparator: { $0.isWhitespace }).count >= minimumWordCount else {
            return true
        }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(window)
        guard let (language, confidence) = recognizer.languageHypotheses(withMaximum: 1).first,
              confidence >= minimumConfidence else {
            return true
        }
        return hasDictionary(for: language.rawValue, in: availableLanguages)
    }

    static func hasDictionary(for languageCode: String, in availableLanguages: [String]) -> Bool {
        let base = baseCode(languageCode)
        guard !base.isEmpty else { return true }
        return availableLanguages.contains { baseCode($0) == base }
    }

    private static func baseCode(_ identifier: String) -> String {
        identifier.split(whereSeparator: { $0 == "_" || $0 == "-" })
            .first.map { $0.lowercased() } ?? ""
    }
}
