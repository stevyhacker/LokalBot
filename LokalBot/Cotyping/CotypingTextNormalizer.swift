// Contains code ported from Cotabby (https://github.com/FuJacob/cotabby),
// copyright the Cotabby authors, under the GNU AGPL v3.0
// (LICENSES/AGPL-3.0.txt). Modified for LokalBot since 23 June 2026.
// See THIRD_PARTY_NOTICES.md.

import Foundation

enum CotypingSuppressionReason: String, Sendable, Equatable {
    case emptyGeneration
    case normalizedToEmpty
    case duplicatesTrailingText
    case echoesPrecedingText
    case placeholderText
    case questionContinuation
    case unsafeToInsert
    case promptContextLeak
    case wordCompletionMismatch
    case lowConfidence
}

struct CotypingNormalizationResult: Equatable, Sendable {
    let text: String
    let suppression: CotypingSuppressionReason?
}

enum CotypingTextNormalizer {
    static func normalize(_ raw: String, for request: CotypingRequest) -> String {
        normalizeDetailed(raw, for: request).text
    }

    static func normalizeDetailed(_ raw: String, for request: CotypingRequest) -> CotypingNormalizationResult {
        let rawHadContent = !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        var normalized = raw.replacingOccurrences(of: "\r", with: "")

        normalized = CotypingControlTokens.sanitize(normalized)
        normalized = stripThinkBlocks(normalized)

        if !request.prompt.isEmpty, normalized.hasPrefix(request.prompt) {
            normalized.removeFirst(request.prompt.count)
            normalized = normalized.trimmingCharacters(in: .controlCharacters.union(.newlines))
        }
        if !request.prefixText.isEmpty, normalized.hasPrefix(request.prefixText) {
            normalized.removeFirst(request.prefixText.count)
        }

        let beganOnNewLine = normalized.prefix(while: \.isWhitespace).contains(where: \.isNewline)
        normalized = normalized.trimmingCharacters(in: .controlCharacters.union(.newlines))
        normalized = normalized.trimmingCharacters(in: .newlines)
        normalized = stripLeadingScaffoldingLabels(normalized)
        normalized = stripBenignInlineMarkup(normalized)
        normalized = normalized.trimmingCharacters(in: .newlines)

        if CotypingPromptLeakGuard.detectsLeak(
            in: normalized,
            conditioningPreface: request.conditioningPreface) {
            return CotypingNormalizationResult(text: "", suppression: .promptContextLeak)
        }

        if request.isMultiLine {
            if let blankLine = normalized.range(of: "\n\n") {
                normalized = String(normalized[..<blankLine.lowerBound])
            }
            while normalized.last?.isWhitespace == true { normalized.removeLast() }
        } else if let firstLine = normalized.split(separator: "\n", maxSplits: 1).first {
            normalized = String(firstLine)
        }

        let partialWord = CotypingMidWord.currentPartialWord(in: request.prefixText)
        if partialWord.count >= 2, normalized.count > partialWord.count,
           normalized.lowercased().hasPrefix(partialWord.lowercased()) {
            normalized = String(normalized.dropFirst(partialWord.count))
        }
        if request.forceWordContinuation {
            normalized = String(normalized.drop(while: { $0.isWhitespace }))
            if !isPlausibleMidWordContinuation(normalized, trailingText: request.trailingText) {
                return CotypingNormalizationResult(text: "", suppression: .unsafeToInsert)
            }
        }
        if !request.forceWordContinuation,
           request.wordPrefixAtCaret.count >= 2,
           !request.wordPrefixIsValidWord,
           let first = normalized.first, first.isWhitespace {
            return CotypingNormalizationResult(text: "", suppression: .wordCompletionMismatch)
        }

        if !request.forceWordContinuation, CotypingTrailingDuplicationFilter.duplicatesTrailingText(
            normalized, trailingText: request.trailingText) {
            return CotypingNormalizationResult(text: "", suppression: .duplicatesTrailingText)
        }

        let beforeEchoStrip = normalized
        normalized = stripEchoPrefix(normalized, precedingText: request.prefixText)
        let collapsedByEcho = !beforeEchoStrip.isEmpty && normalized.isEmpty

        normalized = strippingStylisticEllipses(from: normalized)

        if request.precedingEndsWithWhitespace {
            normalized = String(normalized.drop(while: { $0.isWhitespace }))
        }
        let extendsFragment = request.wordPrefixAtCaret.count >= 2 && !request.wordPrefixIsValidWord
        if beganOnNewLine, !request.forceWordContinuation, !extendsFragment,
           !request.precedingEndsWithWhitespace, !request.prefixText.isEmpty,
           let first = normalized.first, first.isLetter || first.isNumber {
            normalized = " " + normalized
        }
        normalized = insertingMissingSentenceBoundarySpaces(in: normalized)

        if beginsNewQuestion(normalized, prefixText: request.prefixText) {
            return CotypingNormalizationResult(text: "", suppression: .questionContinuation)
        }
        normalized = conservativeSingleLineContinuation(normalized, request: request)
        if containsPlaceholderText(normalized) {
            return CotypingNormalizationResult(text: "", suppression: .placeholderText)
        }

        guard CotypingInsertionSafety.isSafeToInsert(normalized) else {
            return CotypingNormalizationResult(
                text: "",
                suppression: suppressionForEmptyResult(
                    collapsedByEcho: collapsedByEcho,
                    rawHadContent: rawHadContent,
                    normalized: normalized))
        }
        return CotypingNormalizationResult(text: normalized, suppression: nil)
    }

    private static func conservativeSingleLineContinuation(
        _ text: String,
        request: CotypingRequest
    ) -> String {
        guard !request.isMultiLine else { return text }
        var working = text
        if let sentenceEnd = firstSentenceBoundaryBeforeNewThought(in: working) {
            working = String(working[...sentenceEnd])
        }
        return limitWords(working, maxWords: max(1, min(30, request.maxWords)))
    }

    private static func firstSentenceBoundaryBeforeNewThought(in text: String) -> String.Index? {
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character == "." || character == "!" || character == "?" {
                let next = text.index(after: index)
                if next < text.endIndex, text[next].isWhitespace {
                    if character == ".", isNonTerminalSentencePeriod(in: text, at: index) {
                        index = next
                        continue
                    }
                    return index
                }
            }
            index = text.index(after: index)
        }
        return nil
    }

    private static func isNonTerminalSentencePeriod(in text: String, at periodIndex: String.Index) -> Bool {
        guard periodIndex > text.startIndex else { return false }
        let beforeIndex = text.index(before: periodIndex)
        let beforeCharacter = text[beforeIndex]
        if beforeCharacter.isNumber { return true }
        if beforeCharacter.isLetter {
            let priorIsLetter = beforeIndex > text.startIndex
                && text[text.index(before: beforeIndex)].isLetter
            if !priorIsLetter { return true }
            if nonTerminalPeriodAbbreviations.contains(
                trailingLetters(in: text, endingBefore: periodIndex).lowercased()) {
                return true
            }
        }
        return false
    }

    private static func limitWords(_ text: String, maxWords: Int) -> String {
        guard maxWords > 0 else { return "" }
        var words = 0
        var inWord = false
        var end = text.endIndex
        var truncated = false
        var index = text.startIndex
        while index < text.endIndex {
            let isWord = isSuggestionWordCharacter(text[index])
            if isWord, !inWord {
                words += 1
                if words > maxWords {
                    end = index
                    truncated = true
                    break
                }
                inWord = true
            } else if !isWord {
                inWord = false
            }
            index = text.index(after: index)
        }
        let result = String(text[..<end])
        return truncated
            ? trimmingTrailingLimitBoundary(result)
            : trimmingTrailingWhitespace(result)
    }

    private static func isPlausibleMidWordContinuation(_ text: String, trailingText: String) -> Bool {
        let trailingWord = CotypingMidWord.leadingWordRun(in: trailingText)
        guard !trailingWord.isEmpty else { return true }
        let candidate = CotypingMidWord.leadingWordRun(in: text)
        guard !candidate.isEmpty else { return false }
        let foldedCandidate = candidate.lowercased()
        let foldedTrailing = trailingWord.lowercased()
        return foldedTrailing.hasPrefix(foldedCandidate) || foldedCandidate.hasPrefix(foldedTrailing)
    }

    private static func isSuggestionWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "'" || character == "’"
    }

    private static func trimmingTrailingLimitBoundary(_ text: String) -> String {
        var result = trimmingTrailingWhitespace(text)
        while result.last == "." {
            result.removeLast()
            result = trimmingTrailingWhitespace(result)
        }
        return result
    }

    private static func trimmingTrailingWhitespace(_ text: String) -> String {
        var end = text.endIndex
        while end > text.startIndex {
            let previous = text.index(before: end)
            if text[previous].isWhitespace {
                end = previous
            } else {
                break
            }
        }
        return String(text[..<end])
    }

    private static func strippingStylisticEllipses(from text: String) -> String {
        let leadingStripped = strippingLeadingStylisticEllipsis(from: text)
        return strippingTrailingStylisticEllipsis(from: leadingStripped)
    }

    private static func strippingLeadingStylisticEllipsis(from text: String) -> String {
        var cursor = text.startIndex
        while cursor < text.endIndex, text[cursor] == " " || text[cursor] == "\t" {
            cursor = text.index(after: cursor)
        }
        guard let ellipsisEnd = stylisticEllipsisEnd(at: cursor, in: text),
              ellipsisEnd == text.endIndex || text[ellipsisEnd].isWhitespace else {
            return text
        }

        var restStart = ellipsisEnd
        if cursor > text.startIndex {
            while restStart < text.endIndex, text[restStart].isWhitespace {
                restStart = text.index(after: restStart)
            }
        }
        return String(text[..<cursor]) + String(text[restStart...])
    }

    private static func strippingTrailingStylisticEllipsis(from text: String) -> String {
        var end = text.endIndex
        while end > text.startIndex, text[text.index(before: end)].isWhitespace {
            end = text.index(before: end)
        }
        guard end > text.startIndex,
              let ellipsisStart = trailingStylisticEllipsisStart(endingBefore: end, in: text) else {
            return text
        }

        var trimmedEnd = ellipsisStart
        while trimmedEnd > text.startIndex, text[text.index(before: trimmedEnd)].isWhitespace {
            trimmedEnd = text.index(before: trimmedEnd)
        }
        return String(text[..<trimmedEnd])
    }

    private static func stylisticEllipsisEnd(at index: String.Index, in text: String) -> String.Index? {
        guard index < text.endIndex else { return nil }
        if text[index] == "…" {
            return text.index(after: index)
        }
        guard text[index] == "." else { return nil }
        var cursor = index
        var count = 0
        while cursor < text.endIndex, text[cursor] == "." {
            count += 1
            cursor = text.index(after: cursor)
        }
        return count >= 3 ? cursor : nil
    }

    private static func trailingStylisticEllipsisStart(
        endingBefore end: String.Index,
        in text: String
    ) -> String.Index? {
        let previous = text.index(before: end)
        if text[previous] == "…" {
            return previous
        }
        guard text[previous] == "." else { return nil }
        var cursor = end
        var start = previous
        var count = 0
        while cursor > text.startIndex {
            let before = text.index(before: cursor)
            guard text[before] == "." else { break }
            count += 1
            start = before
            cursor = before
        }
        return count >= 3 ? start : nil
    }

    private static func insertingMissingSentenceBoundarySpaces(in text: String) -> String {
        guard text.contains(".") || text.contains("!") || text.contains("?") else { return text }
        var repaired = ""
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            repaired.append(character)
            let next = text.index(after: index)
            if next < text.endIndex,
               shouldInsertSentenceBoundarySpace(after: character, at: index, next: next, in: text) {
                repaired.append(" ")
            }
            index = next
        }
        return repaired
    }

    private static func shouldInsertSentenceBoundarySpace(
        after character: Character,
        at index: String.Index,
        next: String.Index,
        in text: String
    ) -> Bool {
        let nextCharacter = text[next]
        guard !nextCharacter.isWhitespace,
              nextCharacter.isLetter || nextCharacter.isNumber else {
            return false
        }
        if character == "!" || character == "?" { return true }
        guard character == "." else { return false }
        guard index > text.startIndex else { return true }

        let previous = text.index(before: index)
        let previousCharacter = text[previous]
        if previousCharacter.isNumber && nextCharacter.isNumber { return false }
        if previousCharacter == "." || nextCharacter == "." { return false }
        if isContinuingDottedInitialism(in: text, periodIndex: index, nextIndex: next) { return false }
        if isLikelyURLDomainOrFileToken(around: index, in: text) { return false }
        return true
    }

    private static func isContinuingDottedInitialism(
        in text: String,
        periodIndex: String.Index,
        nextIndex: String.Index
    ) -> Bool {
        guard periodIndex > text.startIndex,
              text[text.index(before: periodIndex)].isLetter,
              text[nextIndex].isLetter else {
            return false
        }
        let segmentStart = letterSegmentStart(endingAt: periodIndex, in: text)
        let segment = text[segmentStart..<periodIndex]
        guard segment.count == 1 else { return false }
        let afterNext = text.index(after: nextIndex)
        if afterNext < text.endIndex, text[afterNext] == "." {
            return true
        }
        return text[nextIndex].isUppercase && dottedLetterRunPrecedes(segmentStart, in: text)
    }

    private static func letterSegmentStart(endingAt end: String.Index, in text: String) -> String.Index {
        var cursor = end
        while cursor > text.startIndex {
            let previous = text.index(before: cursor)
            guard text[previous].isLetter else { break }
            cursor = previous
        }
        return cursor
    }

    private static func dottedLetterRunPrecedes(_ index: String.Index, in text: String) -> Bool {
        guard index > text.startIndex else { return false }
        var cursor = index
        var sawDot = false
        while cursor > text.startIndex {
            let previous = text.index(before: cursor)
            let character = text[previous]
            if character.isWhitespace { break }
            if character == "." {
                sawDot = true
            } else if !character.isLetter {
                break
            }
            cursor = previous
        }
        return sawDot
    }

    private static func isLikelyURLDomainOrFileToken(around index: String.Index, in text: String) -> Bool {
        let token = tokenAround(index: index, in: text)
        guard token.contains(".") else { return false }
        let lowercased = token.lowercased()
        if lowercased.contains("://") || lowercased.contains("@") || lowercased.contains("/") {
            return true
        }
        guard lowercased == token else { return false }
        guard let suffix = lowercased.split(separator: ".").last else { return false }
        return likelyDomainOrFileSuffixes.contains(String(suffix))
    }

    private static func tokenAround(index: String.Index, in text: String) -> String {
        var start = index
        while start > text.startIndex {
            let previous = text.index(before: start)
            guard isURLLikeTokenCharacter(text[previous]) else { break }
            start = previous
        }
        var end = text.index(after: index)
        while end < text.endIndex, isURLLikeTokenCharacter(text[end]) {
            end = text.index(after: end)
        }
        return String(text[start..<end])
    }

    private static func isURLLikeTokenCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || ".:/@_+-~%#?=&".contains(character)
    }

    private static let likelyDomainOrFileSuffixes: Set<String> = [
        "ai", "app", "co", "com", "css", "dev", "edu", "env", "gov",
        "html", "io", "js", "json", "jsx", "local", "lock", "md", "me",
        "net", "org", "py", "rs", "swift", "toml", "ts", "tsx", "txt",
        "uk", "us", "yaml", "yml"
    ]

    private static let nonTerminalPeriodAbbreviations: Set<String> = [
        "mr", "mrs", "ms", "dr", "st", "vs", "eg", "ie", "etc", "no",
        "fig", "approx", "inc", "ltd"
    ]

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

    private static func containsPlaceholderText(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return containsDelimitedPlaceholder(trimmed, open: "[", close: "]")
            || containsDelimitedPlaceholder(trimmed, open: "<", close: ">")
    }

    private static func containsDelimitedPlaceholder(_ text: String, open: Character, close: Character) -> Bool {
        var searchStart = text.startIndex
        while let openIndex = text[searchStart...].firstIndex(of: open),
              let closeIndex = text[text.index(after: openIndex)...].firstIndex(of: close) {
            let contentStart = text.index(after: openIndex)
            let content = text[contentStart..<closeIndex]
            if content.count <= 60, content.contains(where: { $0.isLetter }) {
                return true
            }
            searchStart = text.index(after: closeIndex)
        }
        return false
    }

    private static func stripBenignInlineMarkup(_ text: String) -> String {
        text.replacingOccurrences(
            of: #"</?(?:b|br|code|em|i|kbd|samp|span|strong|u|var)(?:\s+[^>]*)?>"#,
            with: "",
            options: .regularExpression)
    }

    private static func beginsNewQuestion(_ text: String, prefixText: String) -> Bool {
        let trimmedPrefix = prefixText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedPrefix.hasSuffix("?") { return false }
        let lowered = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”‘’"))
            .lowercased()
        guard !lowered.isEmpty else { return false }
        let questionPrefixes = [
            "what ", "why ", "how ", "when ", "where ", "who ",
            "would you ", "could you ", "can you ", "do you ", "are you ", "is there ",
        ]
        guard questionPrefixes.contains(where: { lowered.hasPrefix($0) }) else { return false }
        return lowered.contains("?")
    }

    private static func suppressionForEmptyResult(
        collapsedByEcho: Bool, rawHadContent: Bool, normalized: String
    ) -> CotypingSuppressionReason {
        if collapsedByEcho { return .echoesPrecedingText }
        if !normalized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .unsafeToInsert }
        return rawHadContent ? .normalizedToEmpty : .emptyGeneration
    }

    private static func stripThinkBlocks(_ text: String) -> String {
        guard text.contains("<think>") else { return text }
        var result = text
        if let complete = result.range(of: "<think>[\\s\\S]*?</think>", options: .regularExpression) {
            result.replaceSubrange(complete, with: "")
        }
        if let dangling = result.range(of: "<think>[\\s\\S]*", options: .regularExpression) {
            result.replaceSubrange(dangling, with: "")
        }
        return result
    }

    private static func stripEchoPrefix(_ suggestion: String, precedingText: String) -> String {
        let suggestionWords = suggestion.split(whereSeparator: { $0.isWhitespace })
        guard !suggestionWords.isEmpty else { return suggestion }
        let precedingWords = precedingText.split(whereSeparator: { $0.isWhitespace })
        guard !precedingWords.isEmpty else { return suggestion }

        let maxSearchDepth = min(precedingWords.count, 15)
        var bestOverlap = 0
        for startOffset in 1...maxSearchDepth {
            let tailSlice = precedingWords.suffix(startOffset)
            let headSlice = suggestionWords.prefix(startOffset)
            guard tailSlice.count == headSlice.count else { continue }
            let matches = zip(tailSlice, headSlice).allSatisfy {
                $0.0.caseInsensitiveCompare(String($0.1)) == .orderedSame
            }
            if matches { bestOverlap = startOffset }
        }
        guard bestOverlap > 0 else { return suggestion }
        if bestOverlap >= suggestionWords.count { return "" }
        let lastEchoedWord = suggestionWords[bestOverlap - 1]
        return String(suggestion[lastEchoedWord.endIndex...])
    }

    private static let scaffoldingLabels: [String] = [
        "Text before the caret:", "Text before caret:",
        "Text after the caret:", "Text after caret:",
        "User Profile Context:", "Your style preferences:",
        "Final instruction:", "Screen context:", "Screen content:",
        "User's clipboard:", "Continuation:", "Application:", "Task:", "App:",
    ]
    private static let labelsByLengthDescending: [String] =
        scaffoldingLabels.sorted { $0.count > $1.count }

    private static func stripLeadingScaffoldingLabels(_ text: String) -> String {
        var working = text
        while true {
            let leading = String(working.drop(while: { $0.isWhitespace }))
            guard let label = labelsByLengthDescending.first(where: {
                leading.range(of: $0, options: [.caseInsensitive, .anchored]) != nil
            }) else { return working }
            working = String(leading.dropFirst(label.count))
        }
    }
}

enum CotypingPromptLeakGuard {
    private static let rendererMarkerStems = [
        "an email being written in",
        "a chat message being typed in",
        "text being typed in",
        "the window is titled",
        "the text field is labeled",
        "written by",
        "writing style",
        "the text is usually written in",
        "notes the writer keeps in mind",
        "relevant saved facts",
        "current visible text above the field",
        "visible in this window",
        "previously accepted completion",
        "on the clipboard",
    ].map(canonicalize)

    private static let legacyMarkerStems = [
        "text before the caret",
        "text before caret",
        "text after the caret",
        "text after caret",
        "user profile context",
        "your style preferences",
        "final instruction",
        "screen context",
        "screen content",
        "user's clipboard",
    ].map(canonicalize)

    private static let systemMarkerStems = [
        "system prompt",
        "system message",
        "system instruction",
        "hidden prompt",
    ].map(canonicalize)

    static func detectsLeak(in candidateText: String, conditioningPreface: String?) -> Bool {
        let candidate = canonicalize(candidateText)
        guard !candidate.isEmpty,
              let conditioningPreface,
              !conditioningPreface.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }

        let protectedPreface = canonicalize(conditioningPreface)
        if matchesProtectedText(candidate, protected: protectedPreface) {
            return true
        }

        let protectedLines = protectedPrefaceLines(conditioningPreface)

        for line in protectedLines where matchesProtectedText(candidate, protected: line) {
            return true
        }

        let activeMarkers = rendererMarkerStems.filter { marker in
            protectedLines.contains { line in
                line == marker || line.hasPrefix(marker + " ")
            }
        }
        if activeMarkers.contains(where: { marker in
            containsPhrase(candidate, phrase: marker) || marker.hasPrefix(candidate)
        }) {
            return true
        }

        return (legacyMarkerStems + systemMarkerStems).contains {
            containsPhrase(candidate, phrase: $0)
        }
    }

    static func looksLikePromptScaffolding(_ text: String) -> Bool {
        let candidate = canonicalize(text)
        guard !candidate.isEmpty else { return false }
        let markers = rendererMarkerStems + legacyMarkerStems + systemMarkerStems
        return markers.contains { marker in
            containsPhrase(candidate, phrase: marker)
                || (candidate.count >= 8 && marker.hasPrefix(candidate))
        }
    }

    private static func protectedPrefaceLines(_ preface: String) -> [String] {
        var lines: [String] = []
        var inWindow = false
        for raw in preface.split(omittingEmptySubsequences: false, whereSeparator: { $0.isNewline }) {
            let line = String(raw)
            if line == CotypingPromptRenderer.windowLabel {
                inWindow = true
            } else if inWindow {
                if line.trimmingCharacters(in: .whitespaces).isEmpty { inWindow = false }
                continue
            }
            let canonical = canonicalize(line)
            if !canonical.isEmpty { lines.append(canonical) }
        }
        return lines
    }

    private static func matchesProtectedText(_ candidate: String, protected: String) -> Bool {
        guard !protected.isEmpty else { return false }
        return containsPhrase(candidate, phrase: protected) || protected.hasPrefix(candidate)
    }

    private static func containsPhrase(_ text: String, phrase: String) -> Bool {
        guard !phrase.isEmpty else { return false }
        return text == phrase
            || text.hasPrefix(phrase + " ")
            || text.hasSuffix(" " + phrase)
            || text.contains(" " + phrase + " ")
    }

    private static func canonicalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .joined(separator: " ")
    }
}

enum CotypingControlTokens {
    private static let roleHeaderBlockPattern = "<\\|start_header_id\\|>.*?<\\|end_header_id\\|>"

    static let openingMarkers: [String] = [
        "<|im_start|>", "<start_of_turn>", "<|user|>", "<|assistant|>",
        "<|system|>", "<|start_header_id|>", "<|end_header_id|>", "[INST]", "[/INST]",
    ]
    static let stopMarkers: [String] = [
        "<|im_end|>", "<|endoftext|>", "<|end|>", "<end_of_turn>", "<|eot_id|>",
    ]

    static func sanitize(_ text: String) -> String {
        var result = text.replacingOccurrences(
            of: roleHeaderBlockPattern, with: "", options: .regularExpression)
        for marker in openingMarkers {
            result = result.replacingOccurrences(of: marker, with: "")
        }
        if let cut = firstStopMarkerLowerBound(in: result) {
            result = String(result[..<cut])
        }
        return result
    }

    private static func firstStopMarkerLowerBound(in text: String) -> String.Index? {
        var earliest: String.Index?
        for marker in stopMarkers {
            guard let range = text.range(of: marker) else { continue }
            earliest = earliest.map { min($0, range.lowerBound) } ?? range.lowerBound
        }
        return earliest
    }
}

enum CotypingTrailingDuplicationFilter {
    static let minimumFoldedOverlap = 3

    static func duplicatesTrailingText(_ completion: String, trailingText: String) -> Bool {
        let foldedCompletion = fold(completion)
        guard foldedCompletion.count >= minimumFoldedOverlap else { return false }
        let foldedTrailing = fold(trailingText)
        guard !foldedTrailing.isEmpty else { return false }

        if foldedTrailing.hasPrefix(foldedCompletion) { return true }
        if foldedCompletion.hasPrefix(foldedTrailing), foldedTrailing.count >= minimumFoldedOverlap {
            return true
        }
        let overlap = commonPrefixLength(foldedCompletion, foldedTrailing)
        return overlap >= max(minimumFoldedOverlap, foldedCompletion.count / 2)
    }

    private static func fold(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    private static func commonPrefixLength(_ lhs: String, _ rhs: String) -> Int {
        var count = 0
        var l = lhs.startIndex, r = rhs.startIndex
        while l < lhs.endIndex, r < rhs.endIndex, lhs[l] == rhs[r] {
            count += 1
            l = lhs.index(after: l)
            r = rhs.index(after: r)
        }
        return count
    }
}

enum CotypingInsertionSafety {
    static func isSafeToInsert(_ completion: String) -> Bool {
        guard !completion.isEmpty else { return false }
        let scalars = Array(completion.unicodeScalars)
        var index = 0
        var sawVisibleContent = false
        while index < scalars.count {
            let scalar = scalars[index]
            if scalar.value == 0x1F3F4, let flagEnd = subdivisionFlagEnd(in: scalars, startingAt: index) {
                sawVisibleContent = true
                index = flagEnd
                continue
            }
            if isRefusedScalar(scalar) { return false }
            if !CharacterSet.whitespacesAndNewlines.contains(scalar), !isAllowedInvisibleScalar(scalar) {
                sawVisibleContent = true
            }
            index += 1
        }
        return sawVisibleContent
    }

    private static func isRefusedScalar(_ scalar: UnicodeScalar) -> Bool {
        let value = scalar.value
        if value == 0x0A { return false }
        if value < 0x20 || value == 0x7F || (0x80...0x9F).contains(value) { return true }
        if value == 0x00AD || value == 0x180E || value == 0x200B || value == 0xFEFF { return true }
        if value == 0x2028 || value == 0x2029 { return true }
        if (0x202A...0x202E).contains(value) || (0x2060...0x206F).contains(value) { return true }
        if value == 0xFFFC || value == 0xFFFD { return true }
        if (0xE000...0xF8FF).contains(value)
            || (0xF0000...0xFFFFD).contains(value)
            || (0x100000...0x10FFFD).contains(value) { return true }
        if (0xE0000...0xE007F).contains(value) { return true }
        return false
    }

    private static func isAllowedInvisibleScalar(_ scalar: UnicodeScalar) -> Bool {
        let value = scalar.value
        return value == 0x061C
            || (0x200C...0x200F).contains(value)
            || (0xFE00...0xFE0F).contains(value)
            || (0xE0100...0xE01EF).contains(value)
    }

    private static func subdivisionFlagEnd(in scalars: [UnicodeScalar], startingAt start: Int) -> Int? {
        var cursor = start + 1
        var tagCount = 0
        while cursor < scalars.count {
            let value = scalars[cursor].value
            if (0xE0030...0xE0039).contains(value) || (0xE0061...0xE007A).contains(value) {
                tagCount += 1
                if tagCount > 7 { return nil }
                cursor += 1
                continue
            }
            if value == 0xE007F, tagCount >= 3 {
                return cursor + 1
            }
            return nil
        }
        return nil
    }
}
