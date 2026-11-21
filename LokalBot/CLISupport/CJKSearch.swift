import Foundation

enum CJKSearch {
    static func containsCJK(_ text: String) -> Bool {
        text.unicodeScalars.contains(where: isCJK)
    }

    static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x1100...0x11FF,
             0x3040...0x309F,
             0x30A0...0x30FF,
             0x3100...0x312F,
             0x3130...0x318F,
             0x31A0...0x31BF,
             0x31F0...0x31FF,
             0x3400...0x4DBF,
             0x4E00...0x9FFF,
             0xAC00...0xD7AF,
             0xF900...0xFAFF,
             0xFF66...0xFF9F,
             0x20000...0x3134F:
            return true
        default:
            return false
        }
    }

    static let rowGlobPattern = "*[\u{1100}-\u{11FF}\u{3040}-\u{30FF}\u{3100}-\u{318F}\u{31A0}-\u{31FF}"
        + "\u{3400}-\u{4DBF}\u{4E00}-\u{9FFF}\u{AC00}-\u{D7AF}\u{F900}-\u{FAFF}\u{FF66}-\u{FF9F}]*"

    static let likeEscapeClause = #"ESCAPE '\'"#

    static let maximumRelaxedTerms = 8

    private static let separators = CharacterSet.whitespacesAndNewlines
        .union(CharacterSet(charactersIn: ",;:!?()[]{}<>\"“”‘’「」『』（）《》〈〉【】〔〕［］｛｝，。、；：！？…—～·"))

    static func terms(from query: String) -> [String] {
        var seen = Set<String>()
        return query.components(separatedBy: separators)
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    static func relaxedTerms(from query: String) -> [String] {
        var seen = Set<String>()
        var pieces: [String] = []
        for term in terms(from: query) {
            for piece in Self.pieces(of: term) where seen.insert(piece.lowercased()).inserted {
                pieces.append(piece)
            }
        }
        let distinctive = pieces.filter { $0.count > 1 }
        return Array((distinctive.isEmpty ? pieces : distinctive).prefix(maximumRelaxedTerms))
    }

    private static func pieces(of term: String) -> [String] {
        var runs: [(cjk: Bool, characters: [Character])] = []
        for character in term {
            let cjk = character.unicodeScalars.contains(where: isCJK)
            if let last = runs.last, last.cjk == cjk {
                runs[runs.count - 1].characters.append(character)
            } else {
                runs.append((cjk, [character]))
            }
        }
        return runs.flatMap { run -> [String] in
            guard run.cjk, run.characters.count > 2 else { return [String(run.characters)] }
            return (0..<(run.characters.count - 1)).map { String(run.characters[$0...($0 + 1)]) }
        }
    }

    static func likePattern(for term: String) -> String {
        var escaped = ""
        for character in term {
            if character == "\\" || character == "%" || character == "_" { escaped.append("\\") }
            escaped.append(character)
        }
        return "%\(escaped)%"
    }

    static func matchedTermCount(in text: String, terms: [String]) -> Int {
        terms.filter { text.range(of: $0, options: .caseInsensitive) != nil }.count
    }

    static func snippet(in text: String, terms: [String], before: Int = 18, after: Int = 54) -> String? {
        let ranges = matchRanges(in: text, terms: terms)
        guard let first = ranges.first else { return nil }
        let start = text.index(first.lowerBound, offsetBy: -before, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(first.upperBound, offsetBy: after, limitedBy: text.endIndex) ?? text.endIndex
        var excerpt = start > text.startIndex ? "…" : ""
        var cursor = start
        for range in ranges where range.lowerBound >= cursor && range.upperBound <= end {
            excerpt += text[cursor..<range.lowerBound]
            excerpt += "«\(text[range])»"
            cursor = range.upperBound
        }
        excerpt += text[cursor..<end]
        if end < text.endIndex { excerpt += "…" }
        return excerpt
    }

    static func matchRanges(in text: String, terms: [String]) -> [Range<String.Index>] {
        var found: [Range<String.Index>] = []
        for term in terms where !term.isEmpty {
            var searchStart = text.startIndex
            while searchStart < text.endIndex,
                  let range = text.range(of: term, options: .caseInsensitive,
                                         range: searchStart..<text.endIndex) {
                found.append(range)
                searchStart = range.upperBound
            }
        }
        found.sort { $0.lowerBound < $1.lowerBound }
        var merged: [Range<String.Index>] = []
        for range in found {
            if let last = merged.last, range.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        return merged
    }
}
