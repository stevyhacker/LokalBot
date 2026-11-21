import Foundation

enum SpeakerBleedFilter {

    struct Result {
        var transcript: Transcript
        var removedSegments: Int
        var removedWords: Int
        var suspectedIndices: Set<Int> = []
        var acousticCandidateIndices: Set<Int> = []

        var changed: Bool { removedSegments > 0 || !suspectedIndices.isEmpty }
    }

    static let maximumComparableSpanDuration: TimeInterval = 15
    static let maximumBoundaryDrift: TimeInterval = 0.75
    static let minimumAlignedCoverage = 0.85
    static let minimumWordTokenCount = 4
    static let minimumIdeographicTokenCount = 8
    static let maximumComparableTextBytes = 4_096
    static let maximumComparableTokenCount = 256
    static let maximumCandidateSegments = 8

    struct Token: Equatable {
        var word: String
        var isIdeographic: Bool
    }

    private struct IndexedRemote {
        var segment: Transcript.Segment
        var tokens: [Token]
    }

    static func filter(_ transcript: Transcript, acousticallyVerifiedIndices: Set<Int> = []) -> Result {
        let remote = transcript.segments.compactMap { segment -> IndexedRemote? in
            guard segment.resolvedAttribution.source == .system || canonical(segment.speaker) == "them",
                  isComparableSpan(segment),
                  let tokens = evidenceTokens(in: segment.text) else { return nil }
            return IndexedRemote(segment: segment, tokens: tokens)
        }.sorted {
            if $0.segment.start == $1.segment.start {
                return $0.segment.end < $1.segment.end
            }
            return $0.segment.start < $1.segment.start
        }

        guard !remote.isEmpty else {
            return Result(transcript: transcript, removedSegments: 0, removedWords: 0)
        }

        var kept: [Transcript.Segment] = []
        kept.reserveCapacity(transcript.segments.count)
        var removedSegments = 0
        var removedWords = 0
        var suspectedIndices = Set<Int>()
        var acousticCandidateIndices = Set<Int>()

        for (index, segment) in transcript.segments.enumerated() {
            guard segment.resolvedAttribution.source == .microphone || canonical(segment.speaker) == "me",
                  isComparableSpan(segment),
                  let tokens = evidenceTokens(in: segment.text),
                  hasMatchingRemote(segment: segment, tokens: tokens, remote: remote) else {
                kept.append(segment)
                continue
            }
            if !segment.resolvedAttribution.hasIdentityDecision {
                acousticCandidateIndices.insert(index)
            }
            if !acousticallyVerifiedIndices.contains(index) || segment.resolvedAttribution.hasIdentityDecision {
                var retained = segment
                if !segment.resolvedAttribution.hasIdentityDecision {
                    retained.attribution = .init(source: .microphone, identity: .unresolved, method: .suspectedEcho)
                    suspectedIndices.insert(index)
                }
                kept.append(retained)
                continue
            }
            removedSegments += 1
            removedWords += tokens.count
        }

        guard removedSegments > 0 || !suspectedIndices.isEmpty else {
            return Result(transcript: transcript, removedSegments: 0, removedWords: 0,
                          acousticCandidateIndices: acousticCandidateIndices)
        }
        var cleaned = transcript
        cleaned.segments = kept
        return Result(transcript: cleaned,
                      removedSegments: removedSegments,
                      removedWords: removedWords, suspectedIndices: suspectedIndices,
                      acousticCandidateIndices: acousticCandidateIndices)
    }

    static let minimumEchoWordCoverage = 0.8
    static let maximumEchoTimeGap: TimeInterval = 2

    static func nearDuplicateEchoIndices(in transcript: Transcript) -> Set<Int> {
        let remote = transcript.segments.compactMap { segment -> (start: Double, end: Double, words: Set<String>)? in
            guard segment.resolvedAttribution.source == .system || canonical(segment.speaker).hasPrefix("them"),
                  segment.start.isFinite, segment.end.isFinite,
                  let tokens = comparisonTokens(in: segment.text), !tokens.isEmpty else { return nil }
            return (segment.start, segment.end, Set(tokens.map(\.word)))
        }.sorted { $0.start < $1.start }
        guard !remote.isEmpty else { return [] }
        let starts = remote.map(\.start)
        var result = Set<Int>()
        for (index, segment) in transcript.segments.enumerated() {
            let attribution = segment.resolvedAttribution
            guard attribution.source == .microphone || canonical(segment.speaker) == "me",
                  !attribution.hasIdentityDecision, attribution.method != .suspectedEcho,
                  segment.start.isFinite, segment.end.isFinite,
                  let tokens = evidenceTokens(in: segment.text) else { continue }
            var candidate = starts.partitioningIndex { $0 >= segment.start - 60 }
            var scanned = 0
            while candidate < remote.count, remote[candidate].start <= segment.end + maximumEchoTimeGap,
                  scanned < 4 * maximumCandidateSegments {
                defer { candidate += 1; scanned += 1 }
                guard remote[candidate].end >= segment.start - maximumEchoTimeGap else { continue }
                let covered = tokens.reduce(0) { $0 + (remote[candidate].words.contains($1.word) ? 1 : 0) }
                if Double(covered) / Double(tokens.count) >= minimumEchoWordCoverage {
                    result.insert(index)
                    break
                }
            }
        }
        return result
    }

    private static func hasMatchingRemote(
        segment: Transcript.Segment,
        tokens: [Token],
        remote: [IndexedRemote]
    ) -> Bool {
        let earliestStart = segment.start - maximumBoundaryDrift
        let latestStart = segment.start + maximumBoundaryDrift
        var index = lowerBound(in: remote, start: earliestStart)
        var scanned = 0
        var foundMatch = false

        while index < remote.count, remote[index].segment.start <= latestStart {
            scanned += 1
            guard scanned <= maximumCandidateSegments else { return false }
            let candidate = remote[index]
            if spansAreAligned(segment, candidate.segment), candidate.tokens == tokens {
                foundMatch = true
            }
            index += 1
        }
        return foundMatch
    }

    private static func lowerBound(in segments: [IndexedRemote], start: TimeInterval) -> Int {
        var lower = 0
        var upper = segments.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if segments[middle].segment.start < start {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return lower
    }

    static func isComparableSpan(_ segment: Transcript.Segment) -> Bool {
        guard segment.timingPrecision?.isBleedFilterSafe == true,
              segment.start.isFinite, segment.end.isFinite else { return false }
        let duration = segment.end - segment.start
        return duration > 0 && duration <= maximumComparableSpanDuration
    }

    static func spansAreAligned(
        _ lhs: Transcript.Segment,
        _ rhs: Transcript.Segment
    ) -> Bool {
        guard isComparableSpan(lhs), isComparableSpan(rhs),
              abs(lhs.start - rhs.start) <= maximumBoundaryDrift,
              abs(lhs.end - rhs.end) <= maximumBoundaryDrift else { return false }
        let overlap = min(lhs.end, rhs.end) - max(lhs.start, rhs.start)
        let longest = max(lhs.end - lhs.start, rhs.end - rhs.start)
        return overlap > 0 && overlap / longest >= minimumAlignedCoverage
    }

    static func evidenceTokens(in text: String) -> [Token]? {
        guard let tokens = comparisonTokens(in: text) else { return nil }
        let ideographic = tokens.reduce(into: 0) { count, token in
            if token.isIdeographic { count += 1 }
        }
        let minimum = ideographic * 2 >= tokens.count
            ? minimumIdeographicTokenCount
            : minimumWordTokenCount
        return tokens.count >= minimum ? tokens : nil
    }

    static func comparisonTokens(in text: String) -> [Token]? {
        guard text.utf8.prefix(maximumComparableTextBytes + 1).count
                <= maximumComparableTextBytes else { return nil }

        var tokens: [Token] = []
        var currentWord = ""

        func flushWord() {
            guard !currentWord.isEmpty else { return }
            tokens.append(Token(word: currentWord.lowercased(), isIdeographic: false))
            currentWord.removeAll(keepingCapacity: true)
        }

        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if isIdeographic(character) {
                flushWord()
                tokens.append(Token(word: String(character).lowercased(), isIdeographic: true))
            } else if character.isLetter || character.isNumber {
                currentWord.append(character)
            } else if isApostrophe(character), !currentWord.isEmpty {
                let next = text.index(after: index)
                if next < text.endIndex,
                   text[next].isLetter || text[next].isNumber,
                   !isIdeographic(text[next]) {
                    currentWord.append("'")
                } else {
                    flushWord()
                }
            } else {
                flushWord()
            }
            guard tokens.count <= maximumComparableTokenCount else { return nil }
            index = text.index(after: index)
        }
        flushWord()
        guard tokens.count <= maximumComparableTokenCount else { return nil }
        return tokens
    }

    static func isIdeographic(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        switch scalar.value {
        case 0x3040...0x30FF,
             0x31F0...0x31FF,
             0x3400...0x4DBF,
             0x4E00...0x9FFF,
             0xF900...0xFAFF,
             0xFF66...0xFF9D,
             0x20000...0x2FA1F,
             0x30000...0x323AF:
            return true
        default:
            return false
        }
    }

    private static func isApostrophe(_ character: Character) -> Bool {
        character == "'" || character == "’"
    }

    private static func canonical(_ speaker: String) -> String {
        speaker.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

extension Transcript {
    func markingSuspectedEcho() -> Transcript {
        let indices = SpeakerBleedFilter.nearDuplicateEchoIndices(in: self)
        guard !indices.isEmpty else { return self }
        var result = self
        for index in indices {
            result.segments[index].attribution = .init(source: .microphone, identity: .unresolved, method: .suspectedEcho)
        }
        return result
    }
}

private extension Array where Element == Double {
    func partitioningIndex(where predicate: (Double) -> Bool) -> Int {
        var lower = 0, upper = count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if predicate(self[middle]) { upper = middle } else { lower = middle + 1 }
        }
        return lower
    }
}
