import Foundation

/// The production gate and the experimental fallback. Neither is a calibrated acceptance probability.
enum CotypingConfidenceBoundaryMode: String, Codable, Sendable {
    case selectedToken
    case boundaryMass
}

/// One sampled token stream, with independent sticky confidence decisions.
/// The fallback never changes a passing current decision or a forced midword.
struct CotypingConfidenceDecision: Sendable {
    static let hybridMinimum: Float = 0.31
    private(set) var primary: CotypingFirstWordConfidence
    private(set) var fallback: CotypingFirstWordConfidence?
    private(set) var primaryPassed = true
    private(set) var fallbackPassed = false

    init(minimum: Float, boundaryMode: CotypingConfidenceBoundaryMode, selectiveOneWordHybrid: Bool) {
        primary = CotypingFirstWordConfidence(minimum: minimum, boundaryMode: boundaryMode)
        if selectiveOneWordHybrid, minimum > 0 {
            fallback = CotypingFirstWordConfidence(minimum: Self.hybridMinimum, boundaryMode: .boundaryMass)
            fallbackPassed = true
        }
    }

    var needsEvaluation: Bool {
        (primaryPassed && !primary.isSettled) || (fallbackPassed && fallback?.isSettled == false)
    }

    var needsEOGEvaluation: Bool {
        (primaryPassed && !primary.isSettled && primary.boundaryMode != .selectedToken)
            || (fallbackPassed && fallback?.isSettled == false)
    }

    var usesFallback: Bool { !primaryPassed && fallbackPassed }

    func needsBoundaryMass(for piece: String) -> Bool {
        (primaryPassed && primary.needsBoundaryMass(for: piece))
            || (fallbackPassed && fallback?.needsBoundaryMass(for: piece) == true)
    }

    mutating func accept(piece: String, probability: Float, boundaryProbability: Float?, isEOG: Bool = false) -> Bool {
        // The existing selected-token gate intentionally does not weigh EOS.
        if primaryPassed, !isEOG || primary.boundaryMode != .selectedToken {
            primaryPassed = primary.accept(piece: piece, probability: probability, boundaryProbability: boundaryProbability)
        }
        if fallbackPassed {
            fallbackPassed = fallback?.accept(piece: piece, probability: probability, boundaryProbability: boundaryProbability) == true
        }
        return primaryPassed || fallbackPassed
    }
}

/// The confidence gate: stay quiet when the model is unsure, as Cotypist does.
/// A suggestion at the start of a word is dropped when the model's own
/// probability of its first word falls below `minimumProbability`.
///
/// The probability is the product of the emitted tokens' probabilities up to
/// and including the token in which the first word ends. Measured on real
/// replies and the user's own prompts and messages (2026-10-06, E2B): wrong
/// suggestions shown halve for about 1.5 points of keystrokes saved, because a
/// hidden suggestion usually comes back as a completion once the first letter
/// is typed. Suggestions inside a word are not gated: their first token is
/// forced to re-type the fragment, so its probability is not comparable.
struct CotypingFirstWordConfidence: Equatable, Sendable {
    static let minimumProbability: Float = 0.1

    let minimum: Float
    let boundaryMode: CotypingConfidenceBoundaryMode
    private(set) var probability: Float = 1
    private var text = ""
    /// The first word has ended, or the gate is off: nothing more to weigh.
    private(set) var isSettled: Bool

    init(minimum: Float, boundaryMode: CotypingConfidenceBoundaryMode = .selectedToken) {
        self.minimum = minimum
        self.boundaryMode = boundaryMode
        isSettled = minimum <= 0
    }

    func needsBoundaryMass(for piece: String) -> Bool {
        !isSettled && boundaryMode == .boundaryMass && startsNewBoundary(piece)
    }

    private func startsNewBoundary(_ piece: String) -> Bool {
        guard let first = piece.first else { return false }
        return Self.endsFirstWord(text + String(first))
    }

    /// Inspect the first complete Unicode scalar, even if the token ends in an
    /// incomplete UTF-8 sequence. Byte continuation tokens are never boundaries.
    static func tokenStartsBoundary(_ bytes: [UInt8]) -> Bool {
        guard let first = bytes.first else { return false }
        let length: Int
        switch first {
        case 0...0x7F: length = 1
        case 0xC2...0xDF: length = 2
        case 0xE0...0xEF: length = 3
        case 0xF0...0xF4: length = 4
        default: return false
        }
        guard bytes.count >= length,
              let text = String(bytes: bytes.prefix(length), encoding: .utf8), let character = text.first else { return false }
        if let category = text.unicodeScalars.first?.properties.generalCategory,
           [.nonspacingMark, .spacingMark, .enclosingMark, .format].contains(category) { return false }
        return !(character.isLetter || character.isNumber || character == "_" || "'’-".contains(character))
    }

    /// Weighs the next emitted token. Returns false once the first word is
    /// known to fall below the minimum; the product only falls, so generation
    /// can stop there.
    mutating func accept(piece: String, probability tokenProbability: Float, boundaryProbability: Float? = nil) -> Bool {
        guard !isSettled else { return true }
        if boundaryMode != .selectedToken, startsNewBoundary(piece) {
            // A token that begins the next word is evidence of termination; its
            // particular suffix is irrelevant to first-word agreement. Retain termination mass
            // on this token path; it does not marginalize other tokenizations.
            let factor: Float = boundaryProbability ?? 0
            probability *= factor.isFinite ? min(1, max(0, factor)) : 0
            isSettled = true
            return probability >= minimum
        }
        text += piece
        probability *= max(0, tokenProbability)
        guard probability >= minimum else { return false }
        if Self.endsFirstWord(text) { isSettled = true }
        return true
    }

    /// A word character followed by a character that cannot continue a word.
    static func endsFirstWord(_ text: String) -> Bool {
        var inWord = false
        for character in text.drop(while: \.isWhitespace) {
            if character.isLetter || character.isNumber || character == "_" {
                inWord = true
            } else if inWord, !"'’-".contains(character) {
                return true
            }
        }
        return false
    }
}
