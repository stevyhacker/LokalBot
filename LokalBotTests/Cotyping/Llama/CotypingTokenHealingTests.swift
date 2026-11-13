import XCTest
@testable import LokalBot

// MARK: - Token healing (mid-word prompt split)

final class CotypingTokenHealingTests: XCTestCase {
    func testSplitsTrailingFragmentAndKeepsSeparatorInRequiredPrefix() {
        XCTAssertEqual(
            CotypingTokenHealing.split(prompt: "I wanted to follo"),
            CotypingTokenHealing.Split(healedPrompt: "I wanted to", requiredPrefix: " follo"))
    }

    func testReplaysSpaceAfterCompletedWord() {
        XCTAssertEqual(CotypingTokenHealing.split(prompt: "I wanted to "),
                       .init(healedPrompt: "I wanted to", requiredPrefix: " "))
        XCTAssertNil(CotypingTokenHealing.split(prompt: "end."))
    }

    func testSplitsFragmentAfterPunctuationWithoutWhitespace() {
        XCTAssertEqual(
            CotypingTokenHealing.split(prompt: "(follo"),
            CotypingTokenHealing.Split(healedPrompt: "(", requiredPrefix: "follo"))
    }

    func testNewlineRemainsInContext() {
        XCTAssertEqual(
            CotypingTokenHealing.split(prompt: "line one\nfollo"),
            CotypingTokenHealing.Split(healedPrompt: "line one\n", requiredPrefix: "follo"))
        XCTAssertNil(CotypingTokenHealing.split(prompt: "line one\n"))
        XCTAssertEqual(CotypingTokenHealing.split(prompt: "line one\n  follo"),
                       .init(healedPrompt: "line one\n", requiredPrefix: "  follo"))
    }

    func testSeparatorHealingIsBoundedAndByteExact() {
        for separator in [" ", "\t", "  ", "\u{00a0}"] {
            let prompt = "word" + separator
            let split = CotypingTokenHealing.split(prompt: prompt)
            XCTAssertEqual(split?.healedPrompt, "word")
            XCTAssertEqual(split?.requiredPrefix, separator)
        }
        XCTAssertNil(CotypingTokenHealing.split(prompt: "word" + String(repeating: " ", count: 9)))
        XCTAssertNil(CotypingTokenHealing.split(prompt: "   "))
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
    @MainActor
    func testAppAutocompleteAlwaysUsesTheFastHybrid() {
        let runtime = LlamaCotypingRuntime.forAutocomplete()
        let engine = LocalLlamaCotypingEngine(runtime: runtime, modelPath: "/unused.gguf")
        XCTAssertTrue(runtime.selectiveOneWordHybrid)
        XCTAssertEqual(engine.healingMode, .prefixSearch)
        XCTAssertEqual(runtime.searchExperiment, .certified)
        XCTAssertEqual(runtime.replayThreadCount, 2)
        XCTAssertNil(runtime.replayBatchThreadCount, "Prefill inherits the two generation threads")
    }

    @MainActor
    func testNativePrefixSearchRetainsBaselineAndRestoresKVForSampling() async throws {
        guard let model = ProcessInfo.processInfo.environment["LOKALBOT_CANDIDATE_TEST_MODEL"] else {
            throw XCTSkip("Set LOKALBOT_CANDIDATE_TEST_MODEL for prefix-path parity.")
        }
        let runtime = LlamaCotypingRuntime(selectiveOneWordHybrid: true, healingTraceEnabled: true)
        let engine = LocalLlamaCotypingEngine(runtime: runtime, modelPath: model)
        // Test-only ablation: the same assertion must fail on the old decoder.
        let selectedMode: CotypingHealingMode = ProcessInfo.processInfo.environment["LOKALBOT_TEST_LEGACY_HEALING"] == "1"
            ? .wordBoundary : .prefixSearch
        try await engine.prewarm()
        let longPrefix = String(repeating: "The project notes mention testing and examples. ", count: 80)
            + "Mačka se stalno skriva iza kauča čim uključimo usi"
        for prefix in ["Mačka se stalno skriva iza kauča čim uključimo usi", "The delivery driver called because the numb",
                       "Dostavljač je zvao da kaže da ne mo", "Please review the ", longPrefix] {
            let request = CotypingRequest(
                prompt: prefix, prefixText: prefix, trailingText: "", isMultiLine: false,
                maxTokens: 6, maxWords: 4, temperature: 0.1, topP: 0.7, topK: 20, minP: 0.08,
                repeatPenalty: 1.05, seed: 0xC0FFEE, generation: 0,
                wordPrefixAtCaret: CotypingMidWord.currentPartialWord(in: prefix))
            engine.healingMode = .wordBoundary
            await engine.clearReplayCache()
            let baseline = try await engine.generate(request)
            engine.healingMode = selectedMode
            await engine.clearReplayCache()
            let selected = try await engine.generate(request)
            if prefix == "Mačka se stalno skriva iza kauča čim uključimo usi" {
                XCTAssertTrue(selected.text.hasPrefix("sivač"), "Complete usisivač instead of the malformed usig")
                XCTAssertFalse(baseline.text.hasPrefix("sivač"), "The escaped regression must reproduce with the fix disabled")
            }
            if let trace = engine.lastHealingTrace, let search = trace.search {
                XCTAssertGreaterThanOrEqual(search.selectedLogProbability, search.baselineLogProbability)
                if !search.changedPath { XCTAssertEqual(selected, baseline) }
                XCTAssertLessThanOrEqual(search.expansions, 32)
                let coldScore = try await runtime.coldScore(
                    promptTokens: trace.promptTokens, continuationTokens: trace.steps.map(\.token))
                XCTAssertEqual(coldScore, search.selectedLogProbability, accuracy: 0.015,
                               "Search rollback must preserve the cold probability of the chosen token path")
            } else { XCTAssertEqual(selected, baseline) }
            await engine.clearReplayCache()
            try await engine.prewarm(for: request)
            let warmed = try await engine.generate(request)
            XCTAssertEqual(warmed, selected)
        }
        await engine.unload()
    }

    @MainActor
    func testNativeSearchReusePreservesColdAndWarmUnicodeOutputs() async throws {
        guard let model = ProcessInfo.processInfo.environment["LOKALBOT_CANDIDATE_TEST_MODEL"] else {
            throw XCTSkip("Set LOKALBOT_CANDIDATE_TEST_MODEL for search-reuse parity.")
        }
        let prefixes = ["Mačka se stalno skriva iza kauča čim uključimo usi",
                        "Molim te sačekaj da pošaljem obaveš", "Račun je plaćen, proveri knjiž",
                        "The delivery driver called because the numb", "Please review the ",
                        "Pošalji mi ažurirani izveš".decomposedStringWithCanonicalMapping,
                        String(repeating: "The project notes mention testing and examples. ", count: 40)
                            + "Dogovorili smo sledeći sa"]
        var reference: [CotypingNormalizationResult] = []
        let configurations: [(CotypingSearchExperiment, Int32?, Int32?)] = [
            (.baseline, nil, nil), (.reuseRoot, nil, nil), (.memoized, nil, nil), (.certified, nil, nil),
            (.certified, 2, nil), (.certified, 2, 14)
        ]
        let runtimes = configurations.map { experiment, threads, batchThreads in
            LlamaCotypingRuntime(selectiveOneWordHybrid: true, searchExperiment: experiment,
                                 replayThreadCount: threads, replayBatchThreadCount: batchThreads)
        } + [.forAutocomplete()]
        for (runtimeIndex, runtime) in runtimes.enumerated() {
            let experiment = runtime.searchExperiment
            let engine = LocalLlamaCotypingEngine(runtime: runtime, modelPath: model)
            try await engine.prewarm()
            for (index, prefix) in prefixes.enumerated() {
                let request = CotypingRequest(
                    prompt: prefix, prefixText: prefix, trailingText: "", isMultiLine: false,
                    maxTokens: 6, maxWords: 4, temperature: 0.1, topP: 0.7, topK: 20, minP: 0.08,
                    repeatPenalty: 1.05, seed: 0xC0FFEE, generation: 0,
                    wordPrefixAtCaret: CotypingMidWord.currentPartialWord(in: prefix))
                await engine.clearReplayCache()
                let cold = try await engine.generate(request)
                if runtimeIndex == 0 { reference.append(cold) }
                XCTAssertEqual(cold, reference[index], "\(experiment): \(prefix)")
                await engine.clearReplayCache()
                try await engine.prewarm(for: request)
                let warmed = try await engine.generate(request)
                XCTAssertEqual(warmed, reference[index], "Warm \(experiment): \(prefix)")
            }
            await engine.unload()
        }
    }

    func testNativePrefillPoliciesPreserveColdAndWarmChunkBoundaryOutputs() async throws {
        guard let model = ProcessInfo.processInfo.environment["LOKALBOT_CANDIDATE_TEST_MODEL"] else {
            throw XCTSkip("Set LOKALBOT_CANDIDATE_TEST_MODEL for prefill policy parity.")
        }
        let runtimes = [LlamaCotypingRuntime.forAutocomplete(),
                        LlamaCotypingRuntime(replayThreadCount: 2, replayPrefillChunkSize: 64,
                                             replayFinalPrefillLogitsOnly: true, replaySynchronizePrefillChunks: true),
                        LlamaCotypingRuntime(replayThreadCount: 2, replayPrefillChunkSize: 2048,
                                             replayPrefillFirstChunkSize: 128, replayFinalPrefillLogitsOnly: true),
                        LlamaCotypingRuntime(replayThreadCount: 2, replayPrefillChunkSize: 2048,
                                             replayPrefillFirstChunkSize: 192, replayFinalPrefillLogitsOnly: true,
                                             replaySynchronizePrefillChunks: true)]
        let lengths = [255, 256, 257, 511, 512, 513]
        let specs = LlamaSamplerSpec.specs(from: .standard)
        var reference: [Int: String] = [:]
        for (index, runtime) in runtimes.enumerated() {
            try await runtime.loadIfNeeded(modelPath: model)
            let tokens = await runtime.tokenize(
                String(repeating: "The project notes contain clear examples and practical instructions. ", count: 80), addBOS: true)
            XCTAssertGreaterThan(tokens.count, 513)
            for length in lengths {
                let prompt = Array(tokens.prefix(length))
                await runtime.clearReplayCache()
                let cold = try await runtime.generate(promptTokens: prompt, maxTokens: 2, samplerSpecs: specs) { _ in true }
                let diagnostics = await runtime.lastReplayDiagnostics
                if length > 256 { XCTAssertGreaterThan(diagnostics.prefillChunks, 1) }
                if runtime.replayFinalPrefillLogitsOnly { XCTAssertEqual(diagnostics.prefillLogitRows, 1) }
                if index == 0 { reference[length] = cold }
                XCTAssertEqual(cold, reference[length], "Policy \(index), boundary \(length)")
                await runtime.clearReplayCache()
                try await runtime.prefill(promptTokens: prompt)
                let warm = try await runtime.generate(promptTokens: prompt, maxTokens: 2, samplerSpecs: specs) { _ in true }
                XCTAssertEqual(warm, reference[length], "Warm policy \(index), boundary \(length)")
            }
            await runtime.unload()
        }
    }

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
    func testCompletedWordCannotBeExtendedPastTypedSpace() {
        let healed = LocalLlamaCotypingEngine.healedGeneration(
            for: request(prompt: "I wanted to ", wordPrefix: ""))
        XCTAssertEqual(healed.prompt, "I wanted to")
        XCTAssertEqual(healed.requiredPrefixUTF8, Array(" ".utf8))
    }

    @MainActor
    func testParagraphBoundaryIsNotRemoved() {
        let healed = LocalLlamaCotypingEngine.healedGeneration(
            for: request(prompt: "Hi Ana,\n\n", wordPrefix: ""))
        XCTAssertEqual(healed.prompt, "Hi Ana,\n\n")
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
