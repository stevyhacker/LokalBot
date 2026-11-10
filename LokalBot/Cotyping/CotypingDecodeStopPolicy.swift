import Foundation

/// Stop policy for cotyping completions, shared by both routes.
///
/// Cotypist/Cotabby can stop inside the native decode loop once the accumulated
/// text reaches a natural suggestion boundary. LokalBot's in-process engine
/// asks this policy from its decode loop (`LocalLlamaCotypingEngine`). The
/// HTTP llama-server path cannot run that native hook, so its streaming client
/// applies the same visible boundary rule and returns early. This does not
/// improve first-token latency, but it prevents useful streamed suggestions
/// from being replaced by later rambling or control-token scaffolding.
nonisolated enum CotypingDecodeStopPolicy {
    enum StopReason: String, Equatable {
        case sentenceBoundary = "sentence_boundary"
        case scaffoldingMarker = "scaffolding_marker"
    }

    static func verdict(
        accumulated: String,
        tokensGenerated: Int,
        minimumTokens: Int = 2
    ) -> StopReason? {
        if containsScaffoldingStopMarker(accumulated) {
            return .scaffoldingMarker
        }
        guard tokensGenerated >= minimumTokens else { return nil }
        return CotypingSentenceBoundary.endsSentence(accumulated) ? .sentenceBoundary : nil
    }

    private static func containsScaffoldingStopMarker(_ text: String) -> Bool {
        guard text.contains("<") else { return false }
        return CotypingControlTokens.stopMarkers.contains { text.contains($0) }
    }
}

nonisolated enum CotypingSentenceBoundary {
    private static let abbreviations: Set<String> = [
        "mr", "mrs", "ms", "dr", "st", "vs", "eg", "ie", "etc", "no", "fig", "approx", "inc", "ltd"
    ]

    static func endsSentence(_ text: String) -> Bool {
        var index = text.endIndex
        while index > text.startIndex {
            let previous = text.index(before: index)
            guard text[previous].isWhitespace else { break }
            index = previous
        }
        while index > text.startIndex {
            let previous = text.index(before: index)
            guard text[previous].isSentenceClosingPunctuation else { break }
            index = previous
        }
        guard index > text.startIndex else { return false }
        let lastIndex = text.index(before: index)
        switch text[lastIndex] {
        case "!", "?":
            return true
        case let character where character.isCJKSentenceTerminator:
            return true
        case ".":
            return isTerminalPeriod(in: text, at: lastIndex)
        default:
            return false
        }
    }

    static func isTerminalPeriod(in text: String, at periodIndex: String.Index) -> Bool {
        guard periodIndex > text.startIndex else { return true }
        let beforeIndex = text.index(before: periodIndex)
        let beforeChar = text[beforeIndex]

        if beforeChar.isNumber { return false }

        if beforeChar.isLetter {
            let priorIsLetter = beforeIndex > text.startIndex
                && text[text.index(before: beforeIndex)].isLetter
            if !priorIsLetter { return false }
            if abbreviations.contains(trailingLetters(in: text, endingBefore: periodIndex).lowercased()) {
                return false
            }
        }
        return true
    }

    private static func trailingLetters(in text: String, endingBefore index: String.Index) -> String {
        var letters: [Character] = []
        var cursor = index
        while cursor > text.startIndex {
            let previous = text.index(before: cursor)
            guard text[previous].isLetter else { break }
            letters.append(text[previous])
            cursor = previous
        }
        return String(letters.reversed())
    }
}

private extension Character {
    var isSentenceClosingPunctuation: Bool {
        self == "\"" || self == "'" || self == ")" || self == "]" || self == "}"
            || self == "\u{201D}" || self == "\u{2019}" || isCJKClosingPunctuation
    }

    var isCJKSentenceTerminator: Bool {
        self == "\u{3002}" || self == "\u{FF01}" || self == "\u{FF1F}"
            || self == "\u{FF61}" || self == "\u{0964}" || self == "\u{0965}"
    }

    var isCJKClosingPunctuation: Bool {
        self == "\u{300D}" || self == "\u{300F}" || self == "\u{3011}"
            || self == "\u{3015}" || self == "\u{3017}" || self == "\u{3019}"
            || self == "\u{301B}" || self == "\u{FF09}" || self == "\u{FF3D}"
            || self == "\u{FF5D}" || self == "\u{FF60}" || self == "\u{3001}"
            || self == "\u{FF0C}"
    }
}
