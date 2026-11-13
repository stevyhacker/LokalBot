import Foundation

/// Removes only objectively pathological ASR output: extreme repetition,
/// rows that merely repeat the vocabulary prompt, and precisely timed rows
/// too fast to be speech. Normal conversational emphasis is left intact:
/// word/phrase collapse requires a long repeated cycle plus an impossible
/// rate or a fast, overwhelmingly repetitive burst.
enum TranscriptSanitizer {
    struct Result {
        var transcript: Transcript
        var changedSegments: Int
        var removedSegments: Int = 0
        var removedWords: Int
        var removedCharacters: Int

        var changed: Bool { changedSegments > 0 || removedSegments > 0 }
    }

    /// A precisely timed row with at least this many words at this rate is
    /// not speech: the forced aligner packs words a model made up for a
    /// near-silent gap into a fraction of a second (8–12 words in under one).
    /// Coarse or unknown timing never authorizes removal, and a collapsed
    /// filler loop is judged by the words it keeps.
    static let implausibleRateMinimumWords = 8
    static let implausibleWordsPerSecond: Double = 10

    private struct Word: Equatable {
        var normalized: String
        var range: Range<String.Index>
    }

    private struct Loop {
        var period: Int
        var repetitions: Int

        var span: Int { period * repetitions }
    }

    /// `prompt` is the vocabulary prompt the transcript was made with, when
    /// known. Rows that only repeat it are removed (`TranscriptionPromptEcho`).
    static func sanitize(_ transcript: Transcript, prompt: String? = nil) -> Result {
        let echo = TranscriptionPromptEcho(prompt: prompt)
        var kept: [Transcript.Segment] = []
        kept.reserveCapacity(transcript.segments.count)
        var changedSegments = 0
        var removedSegments = 0
        var removedWords = 0
        var removedCharacters = 0

        for segment in transcript.segments {
            let original = segment.displayText
            guard !original.isEmpty else {
                kept.append(segment)
                continue
            }
            let characterCleaned = collapseExtremeCharacterRuns(in: original)
            let originalWords = words(in: characterCleaned)
            if echo?.matches(original) == true {
                removedSegments += 1
                removedWords += originalWords.count
                removedCharacters += original.count
                continue
            }
            var finalText = characterCleaned
            var remainingWords = originalWords.count

            let duration = max(0.25, segment.end - segment.start)
            let wordsPerSecond = Double(originalWords.count) / duration
            if originalWords.count >= 32, wordsPerSecond >= 6 {
                let collapsed = collapseRepeatedCycles(originalWords, in: characterCleaned)
                let removed = collapsed.removedWords
                let impossibleRate = originalWords.count >= 80 && wordsPerSecond >= 12
                // Timestamp-less ASR can place 135 identical filler words in
                // a 15-second VAD window: below the old 12 words/sec gate.
                let dominatedByLoop = Double(removed) / Double(originalWords.count) >= 0.8
                if removed > 0, impossibleRate || dominatedByLoop {
                    finalText = collapsed.text
                    removedWords += removed
                    remainingWords -= removed
                }
            }
            if segment.timingPrecision?.isBleedFilterSafe == true,
               remainingWords >= implausibleRateMinimumWords,
               Double(remainingWords) / duration >= implausibleWordsPerSecond {
                removedSegments += 1
                removedWords += remainingWords
                removedCharacters += original.count
                continue
            }

            finalText = Transcript.normalizedText(finalText)
            guard finalText != original else {
                kept.append(segment)
                continue
            }
            removedCharacters += max(0, original.count - finalText.count)
            var updated = segment
            updated.text = finalText
            kept.append(updated)
            changedSegments += 1
        }

        var cleaned = transcript
        cleaned.segments = kept
        return Result(
            transcript: cleaned,
            changedSegments: changedSegments,
            removedSegments: removedSegments,
            removedWords: removedWords,
            removedCharacters: removedCharacters)
    }

    private static func words(in text: String) -> [Word] {
        text.split(whereSeparator: { character in
            !character.isLetter && !character.isNumber
                && character != "'" && character != "’"
        }).map {
            Word(normalized: $0.lowercased(), range: $0.startIndex..<$0.endIndex)
        }
    }

    private static func collapseRepeatedCycles(
        _ input: [Word], in text: String
    ) -> (text: String, removedWords: Int) {
        guard input.count >= 8 else { return (text, 0) }
        var removals: [Range<String.Index>] = []
        var removedWords = 0
        var index = 0

        while index < input.count {
            if let loop = longestLoop(in: input, startingAt: index) {
                let keptWords = loop.period * 2
                // Delete only the repeated span. Rebuilding from word tokens
                // would also rewrite unrelated amounts, signs and decimals.
                let removalStart = input[index + keptWords - 1].range.upperBound
                removals.append(removalStart..<input[index + loop.span - 1].range.upperBound)
                removedWords += loop.span - keptWords
                index += loop.span
            } else {
                index += 1
            }
        }
        var output = text
        for range in removals.reversed() { output.removeSubrange(range) }
        return (output, removedWords)
    }

    private static func longestLoop(in words: [Word], startingAt start: Int) -> Loop? {
        let maximumPeriod = min(32, (words.count - start) / 4)
        guard maximumPeriod > 0 else { return nil }
        var best: Loop?

        for period in 1...maximumPeriod {
            var repetitions = 1
            while start + (repetitions + 1) * period <= words.count,
                  groupsMatch(words, first: start,
                              second: start + repetitions * period,
                              count: period) {
                repetitions += 1
            }

            let redundantWords = period * max(0, repetitions - 2)
            let isLongRun = period == 1 && repetitions >= 8
            guard repetitions >= 4, redundantWords >= 24 || isLongRun else { continue }
            let candidate = Loop(period: period, repetitions: repetitions)
            if best == nil
                || candidate.span > best!.span
                || candidate.span == best!.span && candidate.period < best!.period {
                best = candidate
            }
        }
        return best
    }

    private static func groupsMatch(
        _ words: [Word],
        first: Int,
        second: Int,
        count: Int
    ) -> Bool {
        for offset in 0..<count
        where words[first + offset].normalized != words[second + offset].normalized {
            return false
        }
        return true
    }

    /// Collapse extreme verbal emphasis, but never numeric runs: repeated
    /// digits can be an amount, identifier, or exact quoted evidence.
    private static func collapseExtremeCharacterRuns(in text: String) -> String {
        guard !text.isEmpty else { return text }
        var output = ""
        var run: [Character] = []

        func appendRun() {
            guard let character = run.first else { return }
            let shouldCollapse = run.count >= 8
                && (character.isLetter || character.isPunctuation)
            let retained = shouldCollapse ? Array(run.prefix(3)) : run
            output.append(contentsOf: retained)
            run.removeAll(keepingCapacity: true)
        }

        for character in text {
            if let first = run.first,
               String(first).lowercased() != String(character).lowercased() {
                appendRun()
            }
            run.append(character)
        }
        appendRun()
        return output
    }

}
