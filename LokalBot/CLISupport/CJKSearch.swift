import Foundation

/// Keyword search for Chinese, Japanese and Korean text.
///
/// SQLite's `unicode61` tokenizer splits on spaces and punctuation. These
/// scripts put no spaces between words, so an unbroken run of CJK text, and any
/// Latin letters glued to it, is indexed as one token, and FTS5 can match a word
/// only at the start of that run: "深色模式" finds "深色模式下设置页面…", but
/// "对比度" finds nothing. Queries that contain CJK text therefore match by
/// substring on the stored text. A query without CJK text that FTS finds nowhere
/// falls back to the same substring match, restricted to rows that contain CJK
/// text, so "logo" still finds "比如logo再大一点" while libraries without CJK
/// text see no change.
///
/// Compiled into the app and `lokalbot-cli`, so meeting search, screen search
/// and the MCP screen reader share one matcher.
enum CJKSearch {
    /// Whether `text` has at least one Han, kana, Hangul or Bopomofo character.
    static func containsCJK(_ text: String) -> Bool {
        text.unicodeScalars.contains(where: isCJK)
    }

    static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x1100...0x11FF,    // Hangul Jamo
             0x3040...0x309F,    // Hiragana
             0x30A0...0x30FF,    // Katakana
             0x3100...0x312F,    // Bopomofo
             0x3130...0x318F,    // Hangul Compatibility Jamo
             0x31A0...0x31BF,    // Bopomofo Extended
             0x31F0...0x31FF,    // Katakana Phonetic Extensions
             0x3400...0x4DBF,    // CJK Unified Ideographs Extension A
             0x4E00...0x9FFF,    // CJK Unified Ideographs
             0xAC00...0xD7AF,    // Hangul Syllables
             0xF900...0xFAFF,    // CJK Compatibility Ideographs
             0xFF66...0xFF9F,    // Halfwidth Katakana
             0x20000...0x3134F:  // CJK Unified Ideographs Extensions B–G
            return true
        default:
            return false
        }
    }

    /// SQL `GLOB` pattern for text that contains CJK characters. SQLite compares
    /// class ranges by code point, so this matches the same characters as
    /// ``isCJK(_:)`` within the Basic Multilingual Plane.
    static let rowGlobPattern = "*[\u{1100}-\u{11FF}\u{3040}-\u{30FF}\u{3100}-\u{318F}\u{31A0}-\u{31FF}"
        + "\u{3400}-\u{4DBF}\u{4E00}-\u{9FFF}\u{AC00}-\u{D7AF}\u{F900}-\u{FAFF}\u{FF66}-\u{FF9F}]*"

    /// The escape clause that goes with ``likePattern(for:)``.
    static let likeEscapeClause = #"ESCAPE '\'"#

    /// Relaxed matching ORs at most this many pieces, so a long sentence
    /// cannot turn one search into dozens of scans.
    static let maximumRelaxedTerms = 8

    /// Separators between search terms: whitespace, sentence punctuation and
    /// brackets in ASCII and full-width forms. Dots, hyphens, apostrophes and
    /// underscores stay inside a term, so "2.0.1" and "e-mail" match as written.
    private static let separators = CharacterSet.whitespacesAndNewlines
        .union(CharacterSet(charactersIn: ",;:!?()[]{}<>\"“”‘’「」『』（）《》〈〉【】〔〕［］｛｝，。、；：！？…—～·"))

    /// Distinct terms of `query`, in order. Every term must occur for a match.
    static func terms(from query: String) -> [String] {
        var seen = Set<String>()
        return query.components(separatedBy: separators)
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    /// Terms for recall-oriented (OR) matching of a spaceless question: each CJK
    /// run of three or more characters becomes its overlapping two-character
    /// pieces, so "下周四发布之前" can still find "下周四发布". Single CJK
    /// characters and single Latin letters are dropped as too common, unless
    /// nothing else is left.
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

    /// `LIKE` pattern that matches `term` anywhere, escaping `%`, `_` and `\`.
    /// Use it with ``likeEscapeClause``. Like SQLite's `LIKE`, it ignores case
    /// for ASCII letters only.
    static func likePattern(for term: String) -> String {
        var escaped = ""
        for character in term {
            if character == "\\" || character == "%" || character == "_" { escaped.append("\\") }
            escaped.append(character)
        }
        return "%\(escaped)%"
    }

    /// How many of `terms` occur in `text`, for ranking OR matches.
    static func matchedTermCount(in text: String, terms: [String]) -> Int {
        terms.filter { text.range(of: $0, options: .caseInsensitive) != nil }.count
    }

    /// An excerpt around the first match, with « » around every match inside
    /// it and … where text was cut. Only the markers and ellipses are added, so
    /// the excerpt without them is a contiguous piece of `text`, as FTS5's
    /// `snippet()` output is. Nil when no term occurs.
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

    /// Every occurrence of every term, sorted, with overlapping and touching
    /// matches merged, so overlapping pieces mark one span.
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
