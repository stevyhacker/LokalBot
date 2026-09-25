import XCTest
@testable import LokalBot

// MARK: - Token healing (mid-word prompt split)

final class CotypingTokenHealingTests: XCTestCase {
    func testSplitsTrailingFragmentAndKeepsSeparatorInRequiredPrefix() {
        XCTAssertEqual(
            CotypingTokenHealing.split(prompt: "I wanted to follo"),
            CotypingTokenHealing.Split(healedPrompt: "I wanted to", requiredPrefix: " follo"))
    }

    func testNoSplitWhenPromptEndsAtWordBoundary() {
        XCTAssertNil(CotypingTokenHealing.split(prompt: "I wanted to "))
        XCTAssertNil(CotypingTokenHealing.split(prompt: "end."))
    }

    func testSplitsFragmentAfterPunctuationWithoutWhitespace() {
        XCTAssertEqual(
            CotypingTokenHealing.split(prompt: "(follo"),
            CotypingTokenHealing.Split(healedPrompt: "(", requiredPrefix: "follo"))
    }

    func testNewlineSeparatorBecomesPartOfRequiredPrefix() {
        XCTAssertEqual(
            CotypingTokenHealing.split(prompt: "line one\nfollo"),
            CotypingTokenHealing.Split(healedPrompt: "line one", requiredPrefix: "\nfollo"))
    }

    func testFragmentLengthLimitIsInclusive() {
        // Contract: a fragment of exactly maxWordLength still heals; one more
        // word character (URL/identifier territory) opts out of healing.
        let atLimit = String(repeating: "a", count: CotypingTokenHealing.maxWordLength)
        XCTAssertEqual(
            CotypingTokenHealing.split(prompt: "see \(atLimit)"),
            CotypingTokenHealing.Split(healedPrompt: "see", requiredPrefix: " \(atLimit)"))
        XCTAssertNil(CotypingTokenHealing.split(prompt: "see \(atLimit)a"))
    }

    func testNoSplitWithoutUsableContextBeforeFragment() {
        XCTAssertNil(CotypingTokenHealing.split(prompt: "follo"))
        XCTAssertNil(CotypingTokenHealing.split(prompt: "  follo"))
    }

    func testKeepsMultiByteScalarsIntact() {
        XCTAssertEqual(
            CotypingTokenHealing.split(prompt: "vielen Dank für deine Unterstüt"),
            CotypingTokenHealing.Split(
                healedPrompt: "vielen Dank für deine", requiredPrefix: " Unterstüt"))
    }
}

// MARK: - Required-prefix byte matching (decode constraint)

final class CotypingRequiredPrefixMatcherTests: XCTestCase {
    private func match(_ piece: String, against remaining: String) -> CotypingRequiredPrefixMatcher.Match {
        CotypingRequiredPrefixMatcher.match(
            pieceBytes: Array(piece.utf8), remaining: Array(remaining.utf8)[...])
    }

    func testPieceInsidePrefixConsumesItsByteCount() {
        XCTAssertEqual(match(" fol", against: " follo"), .consumes(count: 4))
    }

    func testPieceCoveringWholePrefixConsumesEverything() {
        XCTAssertEqual(match(" follo", against: " follo"), .consumes(count: 6))
    }

    func testOvershootingPieceReturnsBytesPastTheCaret() {
        XCTAssertEqual(
            match(" follow", against: " follo"),
            .overshoots(extraBytes: Array("w".utf8)))
    }

    func testDivergingPieceIsMismatch() {
        XCTAssertEqual(match(" xyz", against: " follo"), .mismatch)
        // Longer than the remaining prefix but diverging before its end: the
        // overshoot path must still verify every remaining byte.
        XCTAssertEqual(match(" follxx", against: " follo"), .mismatch)
    }

    func testEmptyPieceOrEmptyRemainingIsMismatch() {
        XCTAssertEqual(match("", against: " follo"), .mismatch)
        XCTAssertEqual(match(" f", against: ""), .mismatch)
    }

    func testMatchesAtByteLevelInsideMultiByteScalar() {
        // BPE pieces can split a UTF-8 scalar: a piece carrying only the first
        // byte of "ü" (0xC3) must consume that single byte, not be rejected for
        // failing to align on a Character boundary.
        let remaining = Array("ü".utf8)
        XCTAssertEqual(remaining.count, 2)
        XCTAssertEqual(
            CotypingRequiredPrefixMatcher.match(pieceBytes: [remaining[0]], remaining: remaining[...]),
            .consumes(count: 1))
    }

    // MARK: extendsWord (prefer word-extending overshoots)

    func testLetterAndDigitFirstBytesExtendTheWord() {
        XCTAssertTrue(CotypingRequiredPrefixMatcher.extendsWord(extraBytes: [UInt8(ascii: "w")]))
        XCTAssertTrue(CotypingRequiredPrefixMatcher.extendsWord(extraBytes: [UInt8(ascii: "0")]))
        XCTAssertTrue(CotypingRequiredPrefixMatcher.extendsWord(extraBytes: [UInt8(ascii: "9")]))
    }

    func testApostropheExtendsTheWord() {
        // Contractions must complete inside the constraint: overshooting
        // "don" with "'t" (don' -> don't) is word-extending.
        XCTAssertTrue(CotypingRequiredPrefixMatcher.extendsWord(extraBytes: Array("'t".utf8)))
    }

    func testMultiByteScalarLeadExtendsTheWord() {
        // An overshoot can start mid-scalar; a lead byte like 0xC3 (first
        // byte of "ü") is always letter-ish and must count as word-extending.
        XCTAssertEqual(Array("ü".utf8).first, 0xC3)
        XCTAssertTrue(CotypingRequiredPrefixMatcher.extendsWord(extraBytes: [0xC3]))
    }

    func testPunctuationAndWhitespaceFirstBytesDoNotExtendTheWord() {
        for extra in [".", ",", " ", "-"] {
            XCTAssertFalse(
                CotypingRequiredPrefixMatcher.extendsWord(extraBytes: Array(extra.utf8)),
                "\(extra.debugDescription) must not extend the word")
        }
        // Only the FIRST extra byte decides; letters after a boundary don't help.
        XCTAssertFalse(CotypingRequiredPrefixMatcher.extendsWord(extraBytes: Array(". And".utf8)))
    }

    func testEmptyOvershootDoesNotExtendTheWord() {
        XCTAssertFalse(CotypingRequiredPrefixMatcher.extendsWord(extraBytes: []))
    }

    func testOvershootPreferencePairThroughMatch() {
        // The runtime pairing: of two candidates overshooting " tomorro", the
        // one continuing the word (" tomorrow" -> extra "w") is preferred over
        // one ending it at the caret (" tomorro." -> extra ".").
        guard case .overshoots(let wordExtra) = match(" tomorrow", against: " tomorro") else {
            return XCTFail("expected \" tomorrow\" to overshoot \" tomorro\"")
        }
        XCTAssertEqual(wordExtra, Array("w".utf8))
        XCTAssertTrue(CotypingRequiredPrefixMatcher.extendsWord(extraBytes: wordExtra))

        guard case .overshoots(let boundaryExtra) = match(" tomorro.", against: " tomorro") else {
            return XCTFail("expected \" tomorro.\" to overshoot \" tomorro\"")
        }
        XCTAssertEqual(boundaryExtra, Array(".".utf8))
        XCTAssertFalse(CotypingRequiredPrefixMatcher.extendsWord(extraBytes: boundaryExtra))
    }
}

// MARK: - Engine healing seam

final class LocalLlamaHealedGenerationTests: XCTestCase {
    private func request(prompt: String, wordPrefix: String) -> CotypingRequest {
        CotypingRequest(
            prompt: prompt, prefixText: prompt, trailingText: "", isMultiLine: false,
            maxTokens: 24, temperature: 0.1, topP: 0.7, topK: 20, minP: 0.08,
            repeatPenalty: 1.05, seed: 0, generation: 0,
            wordPrefixAtCaret: wordPrefix)
    }

    @MainActor
    func testHealsPromptAndEmitsRequiredBytesForMidWordCaret() {
        let healed = LocalLlamaCotypingEngine.healedGeneration(
            for: request(prompt: "Hi Sarah. I wanted to follo", wordPrefix: "follo"))
        XCTAssertEqual(healed.prompt, "Hi Sarah. I wanted to")
        XCTAssertEqual(healed.requiredPrefixUTF8, Array(" follo".utf8))
    }

    @MainActor
    func testPassthroughWhenCaretIsNotMidWord() {
        // No fragment at the caret: today's prompt must survive byte-for-byte
        // and generation must run unconstrained.
        let healed = LocalLlamaCotypingEngine.healedGeneration(
            for: request(prompt: "I wanted to ", wordPrefix: ""))
        XCTAssertEqual(healed.prompt, "I wanted to ")
        XCTAssertTrue(healed.requiredPrefixUTF8.isEmpty)
    }
}

final class CotypingUTF8TokenDecoderTests: XCTestCase {
    func testEveryByteSplitPreservesUnicodeScalars() throws {
        for text in ["é", "€", "😀", "café 👩🏽‍💻 done"] {
            let bytes = Array(text.utf8)
            for split in 0...bytes.count {
                var decoder = CotypingUTF8TokenDecoder()
                let first = try XCTUnwrap(decoder.append(Array(bytes[..<split])))
                let last = try XCTUnwrap(decoder.append(Array(bytes[split...])))
                XCTAssertEqual(first + last, text)
                XCTAssertFalse(first.contains("\u{FFFD}"))
            }
        }
    }

    func testHealingOvershootAndFreeDecodeShareThePendingScalar() throws {
        let required = Array(" follo".utf8)
        let piece = required + Array("w ".utf8) + [0xF0, 0x9F]
        guard case .overshoots(let extra) = CotypingRequiredPrefixMatcher.match(
            pieceBytes: piece, remaining: required[...]) else { return XCTFail("expected overshoot") }
        var decoder = CotypingUTF8TokenDecoder()
        XCTAssertEqual(decoder.append(extra), "w ")
        XCTAssertEqual(decoder.append([0x98, 0x80]), "😀")
    }

    func testMalformedUTF8RejectsGenerationAndTruncatedTailIsWithheld() {
        for bytes: [UInt8] in [[0xC0, 0xAF], [0xED, 0xA0, 0x80], [0xF4, 0x90, 0x80, 0x80], [0x80], [0xE2, 0x28]] {
            var decoder = CotypingUTF8TokenDecoder()
            XCTAssertNil(decoder.append(bytes))
            XCTAssertNil(decoder.append([0x61]))
        }
        var decoder = CotypingUTF8TokenDecoder()
        XCTAssertEqual(decoder.append([0x61, 0xE2, 0x82]), "a")
        XCTAssertEqual(decoder.append([]), "")
    }
}
