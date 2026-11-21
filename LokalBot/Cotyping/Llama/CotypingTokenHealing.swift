import Foundation

enum CotypingHealingMode: String, Codable, Sendable {
    case wordBoundary, prefixSearch
}

enum CotypingSearchExperiment: String, Codable, Sendable {
    case baseline, reuseRoot, memoized, certified, widthTwo, budgetEight, exactOnly

    var reusesIdenticalState: Bool { self != .baseline }
    var memoizesRankings: Bool { self != .baseline && self != .reuseRoot }
    var width: Int { self == .widthTwo ? 2 : 4 }
    var expansionLimit: Int { self == .budgetEight ? 8 : 32 }
}

struct CotypingHealingPath {
    var tokens: [Int32] = []
    var remaining: [UInt8]
    var logProbability: Double = 0

    func appending(token: Int32, bytes: [UInt8], logProbability score: Double) -> Self? {
        guard score.isFinite, score <= 0 else { return nil }
        var child = self
        switch CotypingRequiredPrefixMatcher.match(pieceBytes: bytes, remaining: remaining[...]) {
        case .consumes(let count): child.remaining.removeFirst(count)
        case .overshoots: child.remaining.removeAll()
        case .mismatch: return nil
        }
        child.tokens.append(token)
        child.logProbability += score
        return child
    }

    static func outranks(_ lhs: Self, _ rhs: Self) -> Bool {
        lhs.logProbability == rhs.logProbability
            ? lhs.tokens.lexicographicallyPrecedes(rhs.tokens) : lhs.logProbability > rhs.logProbability
    }
}

struct CotypingHealingTrace: Encodable, Sendable {
    struct Search: Encodable, Sendable {
        let expansions: Int
        let baselineLogProbability: Double
        let selectedLogProbability: Double
        let changedPath: Bool
        let certified: Bool
        let budgetFallback: Bool
    }
    struct Step: Encodable, Sendable {
        let token: Int32
        let bytes: [UInt8]
        let remaining: Int
    }
    let promptTokens: [Int32]
    let requiredPrefix: [UInt8]
    var steps: [Step] = []
    var freeTokens: [Int32] = []
    var canonicalTokens: [Int32] = []
    var search: Search?
}

enum CotypingTokenHealing {
    static let maxWordLength = 16
    static let maxSeparatorLength = 8

    struct Split: Equatable, Sendable {
        let healedPrompt: String
        let requiredPrefix: String
    }

    static func split(prompt: String) -> Split? {
        guard let last = prompt.last else { return nil }
        if last.isWhitespace, !last.isNewline {
            var start = prompt.endIndex
            while start > prompt.startIndex {
                let previous = prompt.index(before: start)
                guard prompt[previous].isWhitespace, !prompt[previous].isNewline else { break }
                start = previous
            }
            guard prompt.distance(from: start, to: prompt.endIndex) <= maxSeparatorLength,
                  prompt[..<start].contains(where: { !$0.isWhitespace }) else { return nil }
            return Split(healedPrompt: String(prompt[..<start]), requiredPrefix: String(prompt[start...]))
        }
        guard isWordCharacter(last) else { return nil }

        var wordStart = prompt.endIndex
        while wordStart > prompt.startIndex {
            let prior = prompt.index(before: wordStart)
            guard isWordCharacter(prompt[prior]) else { break }
            wordStart = prior
        }
        let wordLength = prompt.distance(from: wordStart, to: prompt.endIndex)
        guard wordLength <= maxWordLength else { return nil }

        var cutStart = wordStart
        while cutStart > prompt.startIndex {
            let prior = prompt.index(before: cutStart)
            guard prompt[prior].isWhitespace, !prompt[prior].isNewline else { break }
            cutStart = prior
        }
        guard prompt.distance(from: cutStart, to: wordStart) <= maxSeparatorLength else { return nil }

        let healed = String(prompt[..<cutStart])
        guard healed.contains(where: { !$0.isWhitespace }) else { return nil }
        return Split(healedPrompt: healed, requiredPrefix: String(prompt[cutStart...]))
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber
    }
}

enum CotypingRequiredPrefixMatcher {
    enum Match: Equatable, Sendable {
        case consumes(count: Int)
        case overshoots(extraBytes: [UInt8])
        case mismatch
    }

    static func match(pieceBytes: [UInt8], remaining: ArraySlice<UInt8>) -> Match {
        guard !pieceBytes.isEmpty, !remaining.isEmpty else { return .mismatch }
        if pieceBytes.count <= remaining.count {
            return remaining.starts(with: pieceBytes)
                ? .consumes(count: pieceBytes.count)
                : .mismatch
        }
        guard pieceBytes.starts(with: remaining) else { return .mismatch }
        return .overshoots(extraBytes: Array(pieceBytes[remaining.count...]))
    }

    static func extendsWord(extraBytes: [UInt8]) -> Bool {
        guard let first = extraBytes.first else { return false }
        if first >= 0x80 { return true }
        let scalar = Unicode.Scalar(first)
        return scalar.properties.isAlphabetic
            || ("0"..."9").contains(Character(scalar))
            || first == UInt8(ascii: "'")
    }
}

struct CotypingUTF8TokenDecoder: Sendable {
    private var pending: [UInt8] = []
    private var failed = false

    mutating func append(_ bytes: [UInt8]) -> String? {
        guard !failed else { return nil }
        pending.append(contentsOf: bytes)
        var end = 0
        while end < pending.count {
            let lead = pending[end]
            let length: Int
            switch lead {
            case 0...0x7F: length = 1
            case 0xC2...0xDF: length = 2
            case 0xE0...0xEF: length = 3
            case 0xF0...0xF4: length = 4
            default: return reject()
            }
            let available = min(length, pending.count - end)
            if available > 1 {
                for offset in 1..<available {
                    let byte = pending[end + offset]
                    guard (0x80...0xBF).contains(byte) else { return reject() }
                    if offset == 1 {
                        if lead == 0xE0 && byte < 0xA0 { return reject() }
                        if lead == 0xED && byte > 0x9F { return reject() }
                        if lead == 0xF0 && byte < 0x90 { return reject() }
                        if lead == 0xF4 && byte > 0x8F { return reject() }
                    }
                }
            }
            guard available == length else { break }
            end += length
        }
        let complete = String(decoding: pending.prefix(end), as: UTF8.self)
        pending.removeFirst(end)
        return complete
    }

    private mutating func reject() -> String? {
        failed = true
        pending.removeAll()
        return nil
    }
}
