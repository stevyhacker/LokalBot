// Contains code ported from Cotabby (https://github.com/FuJacob/cotabby),
// copyright the Cotabby authors, under the GNU AGPL v3.0
// (LICENSES/AGPL-3.0.txt). Modified for LokalBot since 25 June 2026.
// See THIRD_PARTY_NOTICES.md.

import Foundation

/// Final guard for visible failures at the caret seam. Ported from Cotabby's
/// `CompletionSeamGuard`: showing no suggestion is better than showing a junk
/// punctuation run or a mid-word splice that misspells the word being typed.
enum CotypingSeamGuard {
    enum Verdict: Equatable {
        case allow
        case junkPunctuationRun
        case seamMisspelling(word: String)
    }

    private static let junkRunLength = 4
    private static let minimumSeamWordLength = 4

    static func verdict(
        precedingText: String,
        completion: String,
        isKnownWord: (String) -> Bool
    ) -> Verdict {
        if introducesJunkPunctuationRun(precedingText: precedingText, completion: completion) {
            return .junkPunctuationRun
        }

        if let seamWord = misspellingCandidateSeamWord(
            precedingText: precedingText,
            completion: completion
        ), !isKnownWord(seamWord) {
            return .seamMisspelling(word: seamWord)
        }

        return .allow
    }

    private static func introducesJunkPunctuationRun(
        precedingText: String,
        completion: String
    ) -> Bool {
        var runCharacter: Character?
        var runLength = 0
        var runStartsAtCompletionStart = false
        var index = 0

        for character in completion {
            if character == runCharacter {
                runLength += 1
            } else {
                runCharacter = character
                runLength = 1
                runStartsAtCompletionStart = index == 0
            }
            index += 1

            guard runLength >= junkRunLength,
                  let current = runCharacter,
                  current.isPunctuation || current.isSymbol
            else { continue }

            if runStartsAtCompletionStart,
               trailingRunLength(of: precedingText, character: current) >= 2 {
                continue
            }
            return true
        }
        return false
    }

    private static func misspellingCandidateSeamWord(
        precedingText: String,
        completion: String
    ) -> String? {
        guard let lastBefore = precedingText.last, lastBefore.isLetter,
              let firstAfter = completion.first, firstAfter.isLetter
        else { return nil }

        let seamWord = trailingLetterRun(of: precedingText) + leadingLetterRun(of: completion)
        guard seamWord.count >= minimumSeamWordLength else { return nil }
        guard let first = seamWord.first, first.isLowercase else { return nil }
        guard !containsCJK(seamWord) else { return nil }
        return seamWord
    }

    private static func trailingRunLength(of text: String, character: Character) -> Int {
        text.reversed().prefix(while: { $0 == character }).count
    }

    private static func trailingLetterRun(of text: String) -> String {
        String(text.reversed().prefix(while: { $0.isLetter }).reversed())
    }

    private static func leadingLetterRun(of text: String) -> String {
        String(text.prefix(while: { $0.isLetter }))
    }

    private static func containsCJK(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x2E80...0x9FFF, 0xAC00...0xD7AF, 0xF900...0xFAFF, 0xFF65...0xFF9F:
                return true
            default:
                return false
            }
        }
    }
}
