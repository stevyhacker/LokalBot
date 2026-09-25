import Foundation

/// Token healing for mid-word completions — the mechanism behind Cotypist's
/// "snaps to the word you meant" behavior (its binary calls it
/// `requiredPrefix` / `remainingRequiredPrefix`).
///
/// A prompt that ends mid-word ("…I wanted to follo") tokenizes unnaturally at
/// the tail, so a small model often treats the fragment as a finished word and
/// continues with " up …". Healing cuts the prompt back to the last word
/// boundary ("…I wanted to") and turns the cut text (" follo") into a decode
/// constraint: generation must re-produce those bytes through naturally
/// tokenized pieces (" fol"+"lo", or " follow" overshooting the boundary), and
/// only then run free. The ghost text is everything after the constraint, so
/// the suggestion extends the word the user is typing.
///
/// Pure value logic; `LlamaCotypingRuntime` enforces the constraint.
enum CotypingTokenHealing {
    /// Longest word fragment worth healing. Longer runs (URLs, identifiers)
    /// would spend many forced decode steps for text the LLM path should not
    /// assist anyway.
    static let maxWordLength = 16

    struct Split: Equatable, Sendable {
        /// The prompt to tokenize: original prompt cut at the word boundary,
        /// with the separating whitespace run removed too (a trailing space
        /// tokenizes as badly as a partial word).
        let healedPrompt: String
        /// The exact cut substring (separator whitespace + word fragment).
        /// Generation must begin by reproducing these bytes.
        let requiredPrefix: String
    }

    /// Returns the healed split, or nil when healing does not apply: the prompt
    /// does not end in a word fragment, the fragment is too long, or cutting it
    /// would leave no usable context.
    static func split(prompt: String) -> Split? {
        guard let last = prompt.last, isWordCharacter(last) else { return nil }

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
            guard prompt[prior].isWhitespace else { break }
            cutStart = prior
        }

        let healed = String(prompt[..<cutStart])
        guard healed.contains(where: { !$0.isWhitespace }) else { return nil }
        return Split(healedPrompt: healed, requiredPrefix: String(prompt[cutStart...]))
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber
    }
}

/// Byte-level matching of one detokenized piece against the remaining required
/// prefix. Bytes (not Characters) because BPE pieces can split UTF-8 scalars.
enum CotypingRequiredPrefixMatcher {
    enum Match: Equatable, Sendable {
        /// Piece lies entirely inside the remaining prefix; consume its bytes.
        case consumes(count: Int)
        /// Piece covers all remaining bytes and continues past the caret; the
        /// extra bytes are the first visible ghost text.
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

    /// True when an overshoot's first extra byte continues the WORD (ASCII
    /// letter/digit, apostrophe, or a multi-byte scalar lead). Used to prefer a
    /// boundary-crossing token over one that lands exactly on the caret: a
    /// constraint that ends exactly mid-word leaves the model in the same
    /// awkward state healing exists to avoid ("tomorro" + free decode → "ow."),
    /// while a word-extending overshoot completes the word inside the
    /// constraint — Cotypist's `transitionExpansionLimit` behavior.
    static func extendsWord(extraBytes: [UInt8]) -> Bool {
        guard let first = extraBytes.first else { return false }
        if first >= 0x80 { return true }   // multi-byte UTF-8 scalar (letter-ish)
        let scalar = Unicode.Scalar(first)
        return scalar.properties.isAlphabetic
            || ("0"..."9").contains(Character(scalar))
            || first == UInt8(ascii: "'")
    }
}

/// Token pieces are byte fragments, not necessarily complete Unicode scalars.
/// Keep an unfinished scalar for the next piece and publish only validated UTF-8.
/// An incomplete final scalar is withheld; malformed bytes reject the generation.
struct CotypingUTF8TokenDecoder {
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
