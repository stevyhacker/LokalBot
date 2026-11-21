import Foundation

enum CotypingSuggestionExtension {
    static let thresholdWords = 2

    static func threshold(wordLimit: Int) -> Int {
        max(0, min(thresholdWords, wordLimit - 1))
    }

    static func topUpWordLimit(wordLimit: Int) -> Int {
        max(1, wordLimit - 1)
    }

    static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace)
            .filter { word in word.contains { $0.isLetter || $0.isNumber } }
            .count
    }

    static func isOpenEnded(_ chunk: String, wordLimit: Int) -> Bool {
        guard !chunk.contains(where: \.isNewline),
              !CotypingSentenceBoundary.endsSentence(chunk) else { return false }
        return wordCount(chunk) >= max(1, wordLimit - 1)
    }

    static func shouldExtend(_ session: CotypingSession, wordLimit: Int) -> Bool {
        let threshold = threshold(wordLimit: wordLimit)
        guard threshold > 0, session.kind == .continuation, session.isOpenEnded,
              !session.isExhausted else { return false }
        return wordCount(session.remainingText) <= threshold
    }

    static func continuationPrefix(of session: CotypingSession) -> String {
        session.field.precedingText + session.fullText
    }

    static func addition(from output: String, to suggestion: String) -> String? {
        guard let first = output.first, let last = suggestion.last,
              output.contains(where: { !$0.isWhitespace }),
              !output.contains(where: \.isNewline) else { return nil }
        let lastIsWord = last.isLetter || last.isNumber
        let firstIsWord = first.isLetter || first.isNumber
        guard !(lastIsWord && firstIsWord) else { return nil }
        let said = normalized(suggestion)
        let added = normalized(output)
        guard !added.isEmpty, !said.hasSuffix(added) else { return nil }
        return output
    }

    private static func normalized(_ text: String) -> String {
        text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
