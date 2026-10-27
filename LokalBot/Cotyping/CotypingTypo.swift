// Contains code ported from Cotabby (https://github.com/FuJacob/cotabby),
// copyright the Cotabby authors, under the GNU AGPL v3.0
// (LICENSES/AGPL-3.0.txt). Modified for LokalBot since 23 June 2026.
// See THIRD_PARTY_NOTICES.md.

import Foundation

// Pure typo / autocorrect rules. Ports Cotabby's `CurrentWordExtractor` +
// `TypoCaseTransfer` + `TypoGate` + `TypoCorrectionReplacementPlanner`.
// Detection and correction themselves come from `NSSpellChecker`
// (`CotypingSpellChecker`); these stay pure and testable.

/// The trailing word at the caret plus its grapheme length (one Delete keypress
/// removes one grapheme, so this is the backspace count to erase the word).
enum CotypingWord {
    struct Result: Equatable, Sendable {
        let word: String
        let characterCount: Int
    }

    /// Trailing word, or nil when the caret is on whitespace or the token isn't
    /// plausible natural language.
    static func extract(from precedingText: String) -> Result? {
        guard let last = precedingText.last, !last.isWhitespace else { return nil }
        var start = precedingText.endIndex
        while start > precedingText.startIndex {
            let prior = precedingText.index(before: start)
            if precedingText[prior].isWhitespace { break }
            start = prior
        }
        let word = String(precedingText[start..<precedingText.endIndex])
        guard isPlausibleNaturalWord(word) else { return nil }
        return Result(word: word, characterCount: word.count)
    }

    /// Tolerates exactly one trailing space so a just-finished word stays
    /// actionable (the correction survives pressing Space).
    static func extractTrailingWord(from precedingText: String) -> (result: Result, trailingSpaceCount: Int)? {
        guard precedingText.last == " " else {
            return extract(from: precedingText).map { ($0, 0) }
        }
        let withoutSpace = String(precedingText.dropLast())
        if withoutSpace.last?.isWhitespace == true { return nil }
        guard let result = extract(from: withoutSpace) else { return nil }
        return (result, 1)
    }

    /// Skip non-natural-language tokens (code, URLs, numbers, all-caps acronyms)
    /// so they're never flagged as typos. Conservative: misses are fine, false
    /// positives on code are not.
    static func isPlausibleNaturalWord(_ word: String) -> Bool {
        guard word.count >= 2 else { return false }
        let codeLike: Set<Character> = [
            "@", "/", "\\", "_", ":", ".", "#", "<", ">",
            "(", ")", "[", "]", "{", "}", "$", "%", "^", "*", "=", "+", "|", "~", "`",
        ]
        for character in word {
            if character.isNumber { return false }
            if codeLike.contains(character) { return false }
        }
        let letters = word.filter { $0.isLetter }
        if !letters.isEmpty, letters.allSatisfy({ $0.isUppercase }) { return false }
        return true
    }
}

/// Copies a typo's capitalization onto its dictionary-cased correction
/// (`Teh` → `The`, `HTE` → `THE`).
enum CotypingCaseTransfer {
    static func applying(caseOf source: String, to correction: String) -> String {
        guard !correction.isEmpty else { return correction }
        let letters = source.filter { $0.isLetter }
        guard !letters.isEmpty else { return correction }
        if letters.count > 1, letters.allSatisfy({ $0.isUppercase }) { return correction.uppercased() }
        if let first = letters.first, first.isUppercase {
            return correction.prefix(1).uppercased() + correction.dropFirst()
        }
        return correction
    }
}

/// Gate decision for the trailing word before the caret.
enum CotypingTypoDecision: Equatable {
    /// No actionable typo — generate a normal continuation.
    case proceed
    /// Misspelled word, no correction available — hide the continuation, show nothing.
    case suppress
    /// Misspelled word with a fix — offer it as a one-key word replacement.
    case offerCorrection(word: String, correctedWord: String)
}

enum CotypingTypoGate {
    /// `isTypo` / `bestCorrection` / `isCompletableWordPrefix` are injected
    /// (production: `CotypingSpellChecker`; tests: stubs) so this stays pure.
    ///
    /// A word still being typed (no trailing space yet) that is a live prefix
    /// of a real word ("follo" → follow) is NOT a typo — it is an unfinished
    /// word, and the LLM continuation must run so it can complete it inline
    /// (Cotypist's core mid-word behavior). Only a fragment that no dictionary
    /// word starts with ("recieve") is treated as a typo mid-word. Once the
    /// word is finished (trailing space), completability no longer applies.
    static func resolve(
        precedingText: String,
        enabled: Bool,
        isTypo: (String) -> Bool,
        bestCorrection: (String) -> String?,
        isCompletableWordPrefix: (String) -> Bool = { _ in false }
    ) -> CotypingTypoDecision {
        guard enabled else { return .proceed }
        guard let current = CotypingWord.extractTrailingWord(from: precedingText) else { return .proceed }
        guard isTypo(current.result.word) else { return .proceed }
        if current.trailingSpaceCount == 0, isCompletableWordPrefix(current.result.word) {
            return .proceed
        }
        guard let corrected = bestCorrection(current.result.word) else { return .suppress }
        return .offerCorrection(word: current.result.word, correctedWord: corrected)
    }
}

/// The synthetic edit to replace a verified trailing typo, recomputed from the
/// live text at accept time (the field may have changed since the offer).
struct CotypingCorrectionPlan: Equatable, Sendable {
    let deletingCharacters: Int
    let replacementText: String

    static func plan(
        precedingText: String, expectedTypo: String, correctedWord: String
    ) -> CotypingCorrectionPlan? {
        let corrected = correctedWord.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !corrected.isEmpty, corrected != expectedTypo,
              let live = CotypingWord.extractTrailingWord(from: precedingText),
              live.result.word == expectedTypo else { return nil }
        let spaces = String(repeating: " ", count: live.trailingSpaceCount)
        return CotypingCorrectionPlan(
            deletingCharacters: live.result.characterCount + live.trailingSpaceCount,
            replacementText: corrected + spaces)
    }
}
