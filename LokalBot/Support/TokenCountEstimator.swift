import Foundation

enum TokenCountEstimator {
    static func estimate(_ text: String) -> Int {
        let words = text.split(whereSeparator: { $0.isWhitespace || $0.isPunctuation })
        guard !words.isEmpty else { return 0 }
        return words.reduce(0) { running, word in
            running + max(1, Int((Double(word.count) / 4.0).rounded()))
        }
    }
}
