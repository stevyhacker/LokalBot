import Foundation

/// Fallback for a typed fragment whose compatible tokens are outside the global
/// top candidates. Rank only tokens that can actually spell the user's prefix;
/// canonical tokenization alone discards the model's preference between them.
struct CotypingTokenPrefixIndex {
    private struct Entry {
        var token: Int32
        var bytes: [UInt8]
    }
    private var buckets: [[Entry]] = Array(repeating: [], count: 256)

    init(vocabularySize: Int32, piece: (Int32) -> [UInt8]) {
        for token in 0..<max(0, vocabularySize) {
            let bytes = piece(token)
            if let first = bytes.first {
                buckets[Int(first)].append(Entry(token: token, bytes: bytes))
            }
        }
    }

    func bestToken(
        in logits: UnsafePointer<Float>, matching remaining: ArraySlice<UInt8>,
        preferWordExtendingOvershoot: Bool
    ) -> Int32? {
        guard let first = remaining.first else { return nil }
        var best: Int32?
        var boundary: Int32?
        for entry in buckets[Int(first)] {
            guard logits[Int(entry.token)] > -Float.infinity else { continue }
            var isBoundary = false
            switch CotypingRequiredPrefixMatcher.match(pieceBytes: entry.bytes, remaining: remaining) {
            case .mismatch: continue
            case .consumes(let count):
                isBoundary = preferWordExtendingOvershoot && count == remaining.count
            case .overshoots(let extra):
                isBoundary = preferWordExtendingOvershoot && !CotypingRequiredPrefixMatcher.extendsWord(extraBytes: extra)
            }
            if isBoundary {
                if outranks(entry.token, boundary, logits: logits) { boundary = entry.token }
            } else if outranks(entry.token, best, logits: logits) {
                best = entry.token
            }
        }
        return best ?? boundary
    }

    func bestTokens(
        in logits: UnsafePointer<Float>, matching remaining: ArraySlice<UInt8>,
        preferWordExtendingOvershoot: Bool, limit: Int, exactOnly: Bool = false
    ) -> [Int32] {
        guard let first = remaining.first else { return [] }
        var preferred: [Int32] = []
        var fallback: [Int32] = []
        for entry in buckets[Int(first)] {
            guard logits[Int(entry.token)].isFinite else { continue }
            var boundary = false
            switch CotypingRequiredPrefixMatcher.match(pieceBytes: entry.bytes, remaining: remaining) {
            case .mismatch: continue
            case .consumes(let count): boundary = preferWordExtendingOvershoot && count == remaining.count
            case .overshoots(let extra):
                if exactOnly { continue }
                boundary = preferWordExtendingOvershoot && !CotypingRequiredPrefixMatcher.extendsWord(extraBytes: extra)
            }
            if boundary { fallback.append(entry.token) } else { preferred.append(entry.token) }
        }
        return Array((preferred.isEmpty ? fallback : preferred).sorted {
            outranks($0, $1, logits: logits)
        }.prefix(max(1, limit)))
    }

    private func outranks(_ token: Int32, _ other: Int32?, logits: UnsafePointer<Float>) -> Bool {
        guard let other else { return true }
        let score = logits[Int(token)]
        let previous = logits[Int(other)]
        return score > previous || (score == previous && token < other)
    }
}
