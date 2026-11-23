import AppKit
import Foundation
import NaturalLanguage

enum DictationPasteSeam {
    struct Fit: Equatable, Sendable {
        let text: String
        var addedSpace = false
        var loweredFirstWord = false
    }

    static func fit(
        _ text: String,
        textBeforeCaret: String?,
        lowersSentenceCapital: Bool,
        isEverydayWord: (String) -> Bool
    ) -> Fit {
        guard let textBeforeCaret, !textBeforeCaret.isEmpty, !text.isEmpty else { return Fit(text: text) }
        var fit = Fit(text: text)
        if lowersSentenceCapital, continuesSentence(textBeforeCaret),
           let lowered = loweringFirstWord(of: text, isEverydayWord: isEverydayWord) {
            fit = Fit(text: lowered, loweredFirstWord: true)
        }
        if needsSpace(after: textBeforeCaret, before: fit.text) {
            fit = Fit(text: " " + fit.text, addedSpace: true, loweredFirstWord: fit.loweredFirstWord)
        }
        return fit
    }

    private static let opening: Set<Character> = ["(", "[", "{", "“", "‘", "«", "¿", "¡", "/", "\\", "@", "#", "$", "-", "–", "—", "_"]
    private static let attaching: Set<Character> = [".", ",", ";", ":", "!", "?", ")", "]", "}", "”", "’", "»", "%", "…"]

    static func needsSpace(after textBeforeCaret: String, before text: String) -> Bool {
        guard let last = textBeforeCaret.last, let first = text.first else { return false }
        if last.isWhitespace || first.isWhitespace { return false }
        if opening.contains(last) || attaching.contains(first) { return false }
        if last == "\"" || last == "'" {
            guard let beforeQuote = textBeforeCaret.dropLast().last,
                  !beforeQuote.isWhitespace, !opening.contains(beforeQuote) else { return false }
        }
        return !writtenWithoutSpaces(last) && !writtenWithoutSpaces(first)
    }

    static func writtenWithoutSpaces(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        switch scalar.value {
        case 0x0E00...0x0EFF,
             0x1000...0x109F,
             0x1780...0x17FF,
             0x2E80...0x2FDF,
             0x3000...0x30FF,
             0x3100...0x31FF,
             0x3400...0x4DBF,
             0x4E00...0x9FFF,
             0xF900...0xFAFF,
             0xFF00...0xFFEF,
             0x20000...0x3134F:
            return true
        default:
            return false
        }
    }

    private static let sentenceEnds: Set<Character> = [".", "!", "?", "…", ":", "。", "！", "？"]
    private static let closers: Set<Character> = ["\"", "'", "”", "’", ")", "]", "}", "»"]
    private static let listMarkers: Set<Character> = ["-", "*", "•", "+", "–", "—", ">"]

    static func continuesSentence(_ textBeforeCaret: String) -> Bool {
        let trailingSpace = textBeforeCaret.reversed().prefix { $0.isWhitespace }
        if trailingSpace.contains(where: \.isNewline) { return false }
        var trimmed = textBeforeCaret.dropLast(trailingSpace.count)
        guard !trimmed.isEmpty else { return false }
        let line = trimmed.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).last ?? trimmed[...]
        if line.allSatisfy({ listMarkers.contains($0) || $0.isWhitespace }) || isNumberedMarker(line) { return false }
        while let last = trimmed.last, closers.contains(last) { trimmed = trimmed.dropLast() }
        guard let last = trimmed.last else { return false }
        return !sentenceEnds.contains(last)
    }

    private static func isNumberedMarker(_ line: Substring) -> Bool {
        let marker = line.trimmingCharacters(in: .whitespaces)
        guard let last = marker.last, last == "." || last == ")" else { return false }
        let label = marker.dropLast()
        return !label.isEmpty && (label.allSatisfy(\.isNumber) || (label.count == 1 && label.allSatisfy(\.isLetter)))
    }

    static func loweringFirstWord(of text: String, isEverydayWord: (String) -> Bool) -> String? {
        let word = text.prefix { $0.isLetter || $0 == "'" || $0 == "’" }
        guard word.count >= 2, let first = word.first, first.isUppercase,
              word.dropFirst().allSatisfy({ $0.isLowercase || $0 == "'" || $0 == "’" }),
              !word.hasPrefix("I'"), !word.hasPrefix("I’") else { return nil }
        let lowered = word.lowercased()
        guard isEverydayWord(lowered) else { return nil }
        return lowered + text.dropFirst(word.count)
    }

    static func lowersSentenceCapital(language: TranscriptionLanguage, text: String) -> Bool {
        switch language {
        case .language(let code):
            return code == .en
        case .auto:
            let recognizer = NLLanguageRecognizer()
            recognizer.processString(text)
            return (recognizer.languageHypotheses(withMaximum: 1)[.english] ?? 0) >= englishConfidence
        }
    }

    static let englishConfidence = 0.8

    @MainActor
    static func isEverydayEnglishWord(_ word: String) -> Bool {
        let checker = NSSpellChecker.shared
        guard checker.availableLanguages.contains(where: { $0.hasPrefix("en") }) else { return false }
        let miss = checker.checkSpelling(of: word, startingAt: 0, language: "en", wrap: false,
                                         inSpellDocumentWithTag: 0, wordCount: nil)
        guard miss.location == NSNotFound else { return false }
        let range = NSRange(location: 0, length: (word as NSString).length)
        guard let top = checker.guesses(forWordRange: range, in: word, language: "en",
                                        inSpellDocumentWithTag: 0)?.first else { return true }
        return top == word || top.lowercased() != word
    }
}
