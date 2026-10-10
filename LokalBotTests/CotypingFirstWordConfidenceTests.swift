import XCTest
@testable import LokalBot

/// The confidence gate keeps quiet when the model is unsure of a suggestion's
/// first word.
final class CotypingFirstWordConfidenceTests: XCTestCase {
    func testHybridKeepsCurrentWhenFallbackFailsAndNeverRevivesIt() {
        var gate = CotypingConfidenceDecision(minimum: 0.1, boundaryMode: .selectedToken, selectiveOneWordHybrid: true)
        XCTAssertTrue(gate.accept(piece: " word", probability: 0.2, boundaryProbability: nil))
        XCTAssertFalse(gate.fallbackPassed)
        XCTAssertTrue(gate.accept(piece: " next", probability: 0.8, boundaryProbability: 1))
        XCTAssertTrue(gate.primaryPassed)
        XCTAssertFalse(gate.usesFallback)
        XCTAssertFalse(gate.fallbackPassed)
    }

    func testHybridKeepsFallbackAfterCurrentFailsWithoutRevivingCurrent() {
        var gate = CotypingConfidenceDecision(minimum: 0.1, boundaryMode: .selectedToken, selectiveOneWordHybrid: true)
        XCTAssertTrue(gate.accept(piece: " store", probability: 0.8, boundaryProbability: nil))
        XCTAssertTrue(gate.needsBoundaryMass(for: " on"))
        XCTAssertTrue(gate.accept(piece: " on", probability: 0.01, boundaryProbability: 0.8))
        XCTAssertTrue(gate.usesFallback)
        XCTAssertTrue(gate.accept(piece: " my", probability: 1, boundaryProbability: 1))
        XCTAssertFalse(gate.primaryPassed)
        XCTAssertEqual(gate.fallback?.probability ?? 0, 0.64, accuracy: 0.0001)
    }

    func testHybridStopsOnlyWhenBothFailAndDoesNotGateMidword() {
        var gate = CotypingConfidenceDecision(minimum: 0.1, boundaryMode: .selectedToken, selectiveOneWordHybrid: true)
        XCTAssertFalse(gate.accept(piece: " uncertain", probability: 0.01, boundaryProbability: nil))
        XCTAssertFalse(gate.primaryPassed)
        XCTAssertFalse(gate.fallbackPassed)
        var midword = CotypingConfidenceDecision(minimum: 0, boundaryMode: .selectedToken, selectiveOneWordHybrid: true)
        XCTAssertFalse(midword.needsEvaluation)
        XCTAssertNil(midword.fallback)
        XCTAssertTrue(midword.accept(piece: "orrow", probability: 0, boundaryProbability: nil))
        XCTAssertFalse(midword.usesFallback)
    }

    func testHybridEOSNeverChangesLegacyCurrentDecision() {
        var gate = CotypingConfidenceDecision(minimum: 0.1, boundaryMode: .selectedToken, selectiveOneWordHybrid: true)
        XCTAssertTrue(gate.accept(piece: " word", probability: 0.8, boundaryProbability: nil))
        XCTAssertTrue(gate.needsEOGEvaluation)
        XCTAssertTrue(gate.accept(piece: " ", probability: 0.001, boundaryProbability: 0.001, isEOG: true))
        XCTAssertTrue(gate.primaryPassed)
        XCTAssertEqual(gate.primary.probability, 0.8)
        XCTAssertFalse(gate.fallbackPassed)
    }

    func testHybridCapPreservesSuppressionAndExactUnicodeWord() {
        for (text, expected) in [("the .", "the"), ("рока, чак и", "рока"), (" I'm here", " I'm"),
                                 ("next-generation test", "next-generation"), ("...", "")] {
            let result = LocalLlamaCotypingEngine.oneWordFallback(.init(text: text, suppression: nil))
            XCTAssertEqual(result.text, expected)
        }
        for reason in [CotypingSuppressionReason.questionContinuation, .promptContextLeak, .unsafeToInsert] {
            let result = CotypingNormalizationResult(text: "", suppression: reason)
            XCTAssertEqual(LocalLlamaCotypingEngine.oneWordFallback(result), result)
        }
    }

    func testHybridReplayRequiresLocalEngineAndCurrentConfidenceGate() throws {
        let local = CotypingQualityReplay.Engine.local(model: URL(fileURLWithPath: "/synthetic.gguf"))
        var input = try JSONDecoder().decode(CotypingQualityReplay.Input.self,
            from: Data(#"{"cases":[],"selectiveOneWordHybrid":true}"#.utf8))
        XCTAssertNoThrow(try CotypingQualityReplay.validateHybrid(input, engine: local))
        let remote = CotypingQualityReplay.Engine.remote(baseURL: URL(string: "https://example.com")!, model: "test", extraBodyJSON: nil)
        XCTAssertThrowsError(try CotypingQualityReplay.validateHybrid(input, engine: remote))
        input.confidenceGate = false
        XCTAssertThrowsError(try CotypingQualityReplay.validateHybrid(input, engine: local))
    }

    @MainActor
    func testNativeHybridMatchesCompositionAndNeverStreamsUncappedFallback() async throws {
        guard let model = ProcessInfo.processInfo.environment["LOKALBOT_CANDIDATE_TEST_MODEL"] else {
            throw XCTSkip("Set LOKALBOT_CANDIDATE_TEST_MODEL for native hybrid parity.")
        }
        let prefixes = ["Please review the attached draft and send ", "We're out of milk, so I'll stop by the ",
                        "The build failed again because someone forgot to update ",
                        "Customer: The application keeps crashing.\nSupport: Could you tell me ",
                        "Библиотека ради дуже током испитног ", "The meeting is scheduled for tomor"]
        let requests = try prefixes.map { prefix in
            let field = CotypingField(appName: "Notes", bundleID: "com.apple.Notes", processID: 0, role: "AXTextArea",
                                     precedingText: prefix, trailingText: "", selectionLength: 0, caretRect: .zero,
                                     isSecure: false, caretIsExact: true)
            return try XCTUnwrap(CotypingRequestBuilder.build(field: field, config: .standard, personalization: .none,
                                                              generation: 1, wordPrefixIsValidWord: !prefix.hasSuffix("tomor")))
        }
        var current: [CotypingNormalizationResult] = []
        var boundary: [CotypingNormalizationResult] = []
        for mode in 0...2 {
            let runtime = LlamaCotypingRuntime(confidenceBoundaryMode: mode == 1 ? .boundaryMass : .selectedToken,
                                              selectiveOneWordHybrid: mode == 2)
            let engine = LocalLlamaCotypingEngine(runtime: runtime, modelPath: model)
            if mode == 1 { engine.minimumFirstWordProbability = CotypingConfidenceDecision.hybridMinimum }
            try await engine.prewarm()
            for (index, request) in requests.enumerated() {
                if mode == 0 { current.append(try await engine.generate(request)); continue }
                if mode == 1 { boundary.append(try await engine.generate(request)); continue }
                let captured = HybridCapturedResults()
                let actual = try await engine.generateStreaming(request) { captured.values.append($0) }
                let expected = current[index].text.isEmpty
                    ? LocalLlamaCotypingEngine.oneWordFallback(boundary[index]) : current[index]
                XCTAssertEqual(actual.text, expected.text, prefixes[index])
                if !current[index].text.isEmpty { XCTAssertEqual(actual, current[index]) }
                XCTAssertEqual(captured.values, [actual], "No speculative full fallback may be published")
            }
            await engine.unload()
        }
    }

    func testBoundaryMassMarginalizesNextWordWithoutIgnoringTermination() {
        var gate = CotypingFirstWordConfidence(minimum: 0.2, boundaryMode: .boundaryMass)
        XCTAssertTrue(gate.accept(piece: " follow", probability: 0.5))
        XCTAssertTrue(gate.needsBoundaryMass(for: " up"))
        XCTAssertTrue(gate.accept(piece: " up", probability: 0.01, boundaryProbability: 0.6))
        XCTAssertEqual(gate.probability, 0.3, accuracy: 0.0001)
        XCTAssertTrue(gate.isSettled)
        XCTAssertTrue(gate.accept(piece: " later", probability: 0.001))
        XCTAssertEqual(gate.probability, 0.3, accuracy: 0.0001)
        var uncertain = CotypingFirstWordConfidence(minimum: 0.2, boundaryMode: .boundaryMass)
        XCTAssertTrue(uncertain.accept(piece: " follow", probability: 0.5))
        XCTAssertFalse(uncertain.accept(piece: " up", probability: 0.9, boundaryProbability: 0.1))
    }



    func testBoundaryMaskHandlesUnicodeAndNeverCountsIncompleteByteFragments() {
        for text in [" word", "\u{00A0}word", "\u{3000}word", ",next", ".", "🙂"] {
            XCTAssertTrue(CotypingFirstWordConfidence.tokenStartsBoundary(Array(text.utf8)), text)
        }
        for text in ["word", "č", "'s", "’s", "-known", "_name", "\u{0301}", "\u{200D}"] {
            XCTAssertFalse(CotypingFirstWordConfidence.tokenStartsBoundary(Array(text.utf8)), text)
        }
        XCTAssertFalse(CotypingFirstWordConfidence.tokenStartsBoundary([0xC3]))
        XCTAssertFalse(CotypingFirstWordConfidence.tokenStartsBoundary([0xA9]))
        XCTAssertTrue(CotypingFirstWordConfidence.tokenStartsBoundary([32, 0xC3]))
    }

    func testBoundaryMassUsesFullVocabularySoftmaxAndFailsClosed() {
        XCTAssertEqual(LlamaCotypingRuntime.boundaryMass(numerators: [1, 2, 3], mask: [0, 1, 1]), 5.0 / 6.0, accuracy: 0.0001)
        XCTAssertEqual(LlamaCotypingRuntime.boundaryMass(numerators: [0, 0], mask: [1, 1]), 0)
        XCTAssertEqual(LlamaCotypingRuntime.boundaryMass(numerators: [1], mask: []), 0)
        var gate = CotypingFirstWordConfidence(minimum: 0.1, boundaryMode: .boundaryMass)
        XCTAssertTrue(gate.accept(piece: " word", probability: 0.8))
        XCTAssertFalse(gate.accept(piece: " next", probability: 0.8))
    }

    func testAnUnsureFirstWordStopsGenerationAtOnce() {
        var gate = CotypingFirstWordConfidence(minimum: 0.1)
        XCTAssertFalse(gate.accept(piece: " maybe", probability: 0.05))
    }

    func testTheFirstWordIsWeighedUpToTheTokenThatEndsIt() {
        var gate = CotypingFirstWordConfidence(minimum: 0.1)
        XCTAssertTrue(gate.accept(piece: " fol", probability: 0.5))
        XCTAssertTrue(gate.accept(piece: "low", probability: 0.3))
        XCTAssertFalse(gate.isSettled, "the word could still go on")
        // The token that ends the word counts, as in the measurement the
        // threshold was chosen on: 0.5 × 0.3 × 0.5 = 0.075.
        XCTAssertFalse(gate.accept(piece: " up", probability: 0.5))
    }

    func testLaterWordsAreNotWeighed() {
        var gate = CotypingFirstWordConfidence(minimum: 0.1)
        XCTAssertTrue(gate.accept(piece: " follow", probability: 0.4))
        XCTAssertTrue(gate.accept(piece: " up", probability: 0.5))
        XCTAssertTrue(gate.isSettled)
        XCTAssertTrue(gate.accept(piece: " on", probability: 0.01))
        XCTAssertEqual(gate.probability, 0.2, accuracy: 0.0001)
    }

    func testAZeroMinimumTurnsTheGateOff() {
        var gate = CotypingFirstWordConfidence(minimum: 0)
        XCTAssertTrue(gate.isSettled)
        XCTAssertTrue(gate.accept(piece: " anything", probability: 0))
    }

    func testWhereTheFirstWordEnds() {
        XCTAssertTrue(CotypingFirstWordConfidence.endsFirstWord(" follow up"))
        XCTAssertTrue(CotypingFirstWordConfidence.endsFirstWord("42."))
        XCTAssertTrue(CotypingFirstWordConfidence.endsFirstWord("(maybe)"))
        XCTAssertTrue(CotypingFirstWordConfidence.endsFirstWord(" well-known,"))
        XCTAssertFalse(CotypingFirstWordConfidence.endsFirstWord(" follow"))
        XCTAssertFalse(CotypingFirstWordConfidence.endsFirstWord(" don't"))
        XCTAssertFalse(CotypingFirstWordConfidence.endsFirstWord("  ("))
        XCTAssertTrue(CotypingFirstWordConfidence.endsFirstWord(" šta je"))
    }

    func testTokenProbabilityIsTheSoftmaxOverTheVocabulary() {
        let logits: [Float] = [0, log(2), log(3)]
        var scratch = [Float](repeating: 0, count: logits.count)
        func probability(_ token: Int32) -> Float? {
            logits.withUnsafeBufferPointer { values in
                scratch.withUnsafeMutableBufferPointer { buffer in
                    LlamaCotypingRuntime.probability(of: token, in: values.baseAddress, scratch: buffer)
                }
            }
        }
        XCTAssertEqual(probability(2) ?? -1, 0.5, accuracy: 0.0001)
        XCTAssertEqual(probability(0) ?? -1, 1.0 / 6.0, accuracy: 0.0001)
        XCTAssertNil(probability(3), "a token outside the vocabulary has no probability")
    }
}

/// The runtime calls the callback serially; the test reads only after awaiting it.
private final class HybridCapturedResults: @unchecked Sendable {
    var values: [CotypingNormalizationResult] = []
}
