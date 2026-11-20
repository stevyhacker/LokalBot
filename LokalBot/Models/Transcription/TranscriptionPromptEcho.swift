import Foundation

struct TranscriptionPromptEcho {
    private let words: Set<String>
    private let terms: Set<String>

    init?(prompt: String?) {
        guard let prompt = TranscriptionPrompt.normalized(prompt) else { return nil }
        let terms = prompt
            .split(whereSeparator: { $0 == "," || $0 == ";" || $0.isNewline })
            .map { Self.words(in: String($0)).joined(separator: " ") }
            .filter { !$0.isEmpty }
        guard !terms.isEmpty else { return nil }
        self.terms = Set(terms)
        self.words = Set(terms.flatMap { $0.split(separator: " ").map(String.init) })
    }

    func matches(_ text: String) -> Bool {
        let rowWords = Self.words(in: text)
        guard rowWords.count >= 2, rowWords.allSatisfy(words.contains) else { return false }
        return !terms.contains(rowWords.joined(separator: " "))
    }

    func removing(from segments: [Transcript.Segment]) -> [Transcript.Segment] {
        segments.filter { !matches($0.displayText) }
    }

    static func words(in text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" && $0 != "’" })
            .map(String.init)
    }
}
