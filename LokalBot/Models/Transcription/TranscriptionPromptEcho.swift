import Foundation

/// Text a speech model copied from its vocabulary prompt instead of hearing.
///
/// On a near-silent span, prompt-capable recognizers (Qwen3-ASR, Whisper)
/// return the hint itself or its tail — "Them 6 · source 2, Mila Novak,
/// Orion Launch, Acme." — as a row of 8–12 words timed to a fraction of a
/// second. Such rows are not speech: they reach the notes model as evidence,
/// fill speaker review, and vote in language detection. The Qwen engine, the
/// track transcriber, and `TranscriptSanitizer` drop them through this one
/// definition.
struct TranscriptionPromptEcho {
    /// Every word of the prompt, normalized like `words(in:)`.
    private let words: Set<String>
    /// Each comma-, semicolon-, or line-separated term as one normalized string.
    private let terms: Set<String>

    /// Nil for a prompt without words, so callers skip the check cheaply.
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

    /// True when every word of `text` is a prompt word and the text is more
    /// than one vocabulary term. A row that is only "Mila Novak" may be a
    /// person saying a name; a row of several listed terms is the list.
    func matches(_ text: String) -> Bool {
        let rowWords = Self.words(in: text)
        guard rowWords.count >= 2, rowWords.allSatisfy(words.contains) else { return false }
        return !terms.contains(rowWords.joined(separator: " "))
    }

    func removing(from segments: [Transcript.Segment]) -> [Transcript.Segment] {
        segments.filter { !matches($0.displayText) }
    }

    /// Letter and digit runs, lowercased and accent-folded, so "Marković",
    /// "Markovic", and "MARKOVIC" are one word and "·" or "," never count.
    static func words(in text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" && $0 != "’" })
            .map(String.init)
    }
}
