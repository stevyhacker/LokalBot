import AppKit
import XCTest
@testable import LokalBot

// MARK: - Text normalizer

final class CotypingTextNormalizerTests: XCTestCase {
    private func request(
        prefix: String,
        trailing: String = "",
        multiLine: Bool = false,
        maxWords: Int = 6
    ) -> CotypingRequest {
        CotypingRequest(
            prompt: CotypingPromptRenderer.prompt(prefixText: prefix),
            prefixText: prefix, trailingText: trailing, isMultiLine: multiLine,
            maxTokens: 24, maxWords: maxWords, temperature: 0.1, topP: 0.7, topK: 20, minP: 0.08,
            repeatPenalty: 1.05, seed: 0, generation: 0)
    }

    private func contextualRequest(prefix: String = "Thanks for ") -> CotypingRequest {
        let rendered = CotypingPromptRenderer.render(
            prefixText: prefix,
            surfaceLines: [
                "An email being written in Mail.",
                "The window is titled \"Q3 planning\".",
                "The text field is labeled \"Reply\".",
            ],
            userName: "Sam",
            styleNote: "concise",
            languageHint: "The text is usually written in German.",
            extendedContext: "Acme = our product",
            clipboardContext: "secret release plan",
            learnedExamples: ["following up with the final numbers"])
        return CotypingRequest(
            prompt: rendered.prompt,
            prefixText: prefix,
            trailingText: "",
            isMultiLine: false,
            maxTokens: 24,
            maxWords: 20,
            temperature: 0.1,
            topP: 0.7,
            topK: 20,
            minP: 0.08,
            repeatPenalty: 1.05,
            seed: 0,
            generation: 0,
            conditioningPreface: rendered.conditioningPreface)
    }

    func testSingleLineCollapse() {
        let result = CotypingTextNormalizer.normalize("brown fox\nand more", for: request(prefix: "The quick "))
        XCTAssertEqual(result, "brown fox")
    }

    func testStripsPromptEcho() {
        let result = CotypingTextNormalizer.normalize("The quick brown fox", for: request(prefix: "The quick "))
        XCTAssertEqual(result, "brown fox")
    }

    func testTruncatesAtControlToken() {
        let result = CotypingTextNormalizer.normalize("brown<|im_end|> trailing junk", for: request(prefix: "The quick "))
        XCTAssertEqual(result, "brown")
    }

    func testSuppressesStandaloneEllipsisSuggestions() {
        let ascii = CotypingTextNormalizer.normalizeDetailed(
            "...",
            for: request(prefix: "I think"))
        XCTAssertEqual(ascii.text, "")
        XCTAssertEqual(ascii.suppression, .normalizedToEmpty)

        let unicode = CotypingTextNormalizer.normalizeDetailed(
            "…",
            for: request(prefix: "I think"))
        XCTAssertEqual(unicode.text, "")
        XCTAssertEqual(unicode.suppression, .normalizedToEmpty)
    }

    func testStripsStylisticEllipsesFromUsefulSuggestion() {
        XCTAssertEqual(
            CotypingTextNormalizer.normalize(
                "… probably fine",
                for: request(prefix: "This is ")),
            "probably fine")
        XCTAssertEqual(
            CotypingTextNormalizer.normalize(
                " probably fine...",
                for: request(prefix: "This is")),
            " probably fine")
        XCTAssertEqual(
            CotypingTextNormalizer.normalize(
                "probably fine…",
                for: request(prefix: "This is ")),
            "probably fine")
    }

    func testEllipsisStrippingPreservesInternalDotRuns() {
        let result = CotypingTextNormalizer.normalize(
            "version 1...5 stays compact",
            for: request(prefix: "Use ", maxWords: 8))
        XCTAssertEqual(result, "version 1...5 stays compact")
    }

    func testStripsThinkBlock() {
        let result = CotypingTextNormalizer.normalize("<think>reasoning here</think>delicious", for: request(prefix: "It tastes "))
        XCTAssertEqual(result, "delicious")
    }

    func testSuppressesTrailingDuplication() {
        let detailed = CotypingTextNormalizer.normalizeDetailed(
            "tomorrow", for: request(prefix: "See you ", trailing: "tomorrow at noon"))
        XCTAssertEqual(detailed.text, "")
        XCTAssertEqual(detailed.suppression, .duplicatesTrailingText)
    }

    func testStripsEchoedPrecedingWords() {
        let result = CotypingTextNormalizer.normalize("like to eat", for: request(prefix: "i like "))
        XCTAssertEqual(result, "to eat")
    }

    func testStripsLeadingScaffoldingLabel() {
        let result = CotypingTextNormalizer.normalize("Continuation: hello there", for: request(prefix: "x "))
        XCTAssertEqual(result, "hello there")
    }

    func testSuppressesEveryRenderedPromptContextLine() {
        let request = contextualRequest()
        let leakedLines = [
            "An email being written in Mail.",
            "The window is titled \"Q3 planning\".",
            "The text field is labeled \"Reply\".",
            "Written by Sam.",
            "Writing style: concise.",
            "The text is usually written in German.",
            "Notes the writer keeps in mind: Acme = our product",
            "Previously accepted completion: following up with the final numbers",
            "On the clipboard: secret release plan",
        ]

        for leakedLine in leakedLines {
            let detailed = CotypingTextNormalizer.normalizeDetailed(leakedLine, for: request)
            XCTAssertEqual(detailed.text, "", leakedLine)
            XCTAssertEqual(detailed.suppression, .promptContextLeak, leakedLine)
        }
    }

    func testSuppressesPromptLeakPunctuationAndCaseVariants() {
        let detailed = CotypingTextNormalizer.normalizeDetailed(
            "ON THE CLIPBOARD — secret release plan",
            for: contextualRequest())

        XCTAssertEqual(detailed.text, "")
        XCTAssertEqual(detailed.suppression, .promptContextLeak)
    }

    func testSuppressesStreamedPromptPrefixesBeforeTheyBecomeVisible() {
        let request = contextualRequest()
        for partial in ["An", "The window", "Previously accepted", "On the clip"] {
            let detailed = CotypingTextNormalizer.normalizeDetailed(partial, for: request)
            XCTAssertEqual(detailed.text, "", partial)
            XCTAssertEqual(detailed.suppression, .promptContextLeak, partial)
        }
    }

    func testSuppressesPromptPrefixAfterLegacyWrapperIsRemoved() {
        let detailed = CotypingTextNormalizer.normalizeDetailed(
            "Continuation: On the clip",
            for: contextualRequest())

        XCTAssertEqual(detailed.text, "")
        XCTAssertEqual(detailed.suppression, .promptContextLeak)
    }

    func testAllowsContextInformedContinuationThatIsNotScaffolding() {
        let detailed = CotypingTextNormalizer.normalizeDetailed(
            "the release plan tomorrow",
            for: contextualRequest())

        XCTAssertEqual(detailed.text, "the release plan tomorrow")
        XCTAssertNil(detailed.suppression)
    }

    func testWholePromptEchoIsRemovedWithoutDiscardingItsContinuation() {
        let request = contextualRequest()
        let detailed = CotypingTextNormalizer.normalizeDetailed(
            request.prompt + " the release plan tomorrow",
            for: request)

        XCTAssertEqual(detailed.text, "the release plan tomorrow")
        XCTAssertNil(detailed.suppression)
    }

    func testStripsBenignInlineMarkupInsteadOfSuppressingSuggestion() {
        let result = CotypingTextNormalizer.normalize(
            "that you can't use the same <code>.env</code> file for both development and production",
            for: request(prefix: "The main tradeoff is "))
        XCTAssertEqual(result, "that you can't use the same")
    }

    func testRejectsWhitespaceOnly() {
        let detailed = CotypingTextNormalizer.normalizeDetailed("   \n  ", for: request(prefix: "Hello "))
        XCTAssertEqual(detailed.text, "")
        XCTAssertEqual(detailed.suppression, .emptyGeneration)
    }

    func testMultilinePreservesRequiredSeparatorAfterAWord() {
        XCTAssertEqual(CotypingTextNormalizer.normalize(
            " world", for: request(prefix: "Hello", multiLine: true)), " world")
        XCTAssertEqual(CotypingTextNormalizer.normalize(
            " world\nnext line ", for: request(prefix: "hello", multiLine: true)), " world\nnext line")
        XCTAssertEqual(CotypingTextNormalizer.normalize(
            " world", for: request(prefix: "Hello ", multiLine: true)), "world")
    }

    func testKeepsMultipleLinesInMultiLineMode() {
        let result = CotypingTextNormalizer.normalize(
            "line one\nline two\n\nignored", for: request(prefix: "Start ", multiLine: true))
        XCTAssertEqual(result, "line one\nline two")
    }

    func testSuppressesBracketPlaceholderSuggestions() {
        let detailed = CotypingTextNormalizer.normalizeDetailed(
            "up on [the project/your email]",
            for: request(prefix: "I wanted to follow "))
        XCTAssertEqual(detailed.text, "")
        XCTAssertEqual(detailed.suppression, .placeholderText)
    }

    func testSuppressesUnicodePlaceholderSuggestions() {
        let detailed = CotypingTextNormalizer.normalizeDetailed(
            "up on [пројекат]",
            for: request(prefix: "I wanted to follow "))
        XCTAssertEqual(detailed.text, "")
        XCTAssertEqual(detailed.suppression, .placeholderText)
    }

    func testTruncatesBeforeSecondSentenceQuestion() {
        let result = CotypingTextNormalizer.normalize(
            "care of that. What would you like me to do next?",
            for: request(prefix: "I can take "))
        XCTAssertEqual(result, "care of that.")
    }

    func testInsertsMissingSpaceAfterSentencePeriod() {
        let result = CotypingTextNormalizer.normalize(
            "care of that.Next step is review",
            for: request(prefix: "I can take ", maxWords: 8))
        XCTAssertEqual(result, "care of that.")
    }

    func testInsertsMissingSpaceAfterSentencePunctuationInsideSuggestion() {
        let result = CotypingTextNormalizer.normalize(
            "done.Next",
            for: request(prefix: "Status: ", maxWords: 8))
        XCTAssertEqual(result, "done.")
    }

    func testMissingSentenceSpaceRepairPreservesNonProseDots() {
        XCTAssertEqual(
            CotypingTextNormalizer.normalize(
                "version 1.2 ships",
                for: request(prefix: "Use ", maxWords: 8)),
            "version 1.2 ships")
        XCTAssertEqual(
            CotypingTextNormalizer.normalize(
                "example.com works",
                for: request(prefix: "Open ", maxWords: 8)),
            "example.com works")
        XCTAssertEqual(
            CotypingTextNormalizer.normalize(
                "e.g.this case",
                for: request(prefix: "For example ", maxWords: 8)),
            "e.g. this case")
    }

    func testSuppressesNewQuestionContinuation() {
        let detailed = CotypingTextNormalizer.normalizeDetailed(
            "What would you like me to do next?",
            for: request(prefix: "I can take "))
        XCTAssertEqual(detailed.text, "")
        XCTAssertEqual(detailed.suppression, .questionContinuation)
    }

    func testAllowsHowToContinuationWithoutQuestionMark() {
        let result = CotypingTextNormalizer.normalize(
            "how to fix it",
            for: request(prefix: "I'll show you "))
        XCTAssertEqual(result, "how to fix it")
    }

    func testCapsSingleLineSuggestionsToShortPhrase() {
        let result = CotypingTextNormalizer.normalize(
            "one two three four five six seven eight",
            for: request(prefix: "Let's "))
        XCTAssertEqual(result, "one two three four five six")
    }

    func testSingleLineWordCapUsesRequestMaxWords() {
        let result = CotypingTextNormalizer.normalize(
            "one two three four five six seven eight",
            for: request(prefix: "Let's ", maxWords: 8))
        XCTAssertEqual(result, "one two three four five six seven eight")
    }

    private func wordPrefixRequest(
        prefix: String,
        trailing: String = "",
        wordPrefix: String,
        isValidWord: Bool,
        force: Bool = false
    ) -> CotypingRequest {
        CotypingRequest(
            prompt: CotypingPromptRenderer.prompt(prefixText: prefix),
            prefixText: prefix, trailingText: trailing, isMultiLine: false,
            maxTokens: 24, maxWords: 6, temperature: 0.1, topP: 0.7, topK: 20, minP: 0.08,
            repeatPenalty: 1.05, seed: 0, generation: 0, forceWordContinuation: force,
            wordPrefixAtCaret: wordPrefix, wordPrefixIsValidWord: isValidWord)
    }

    func testSuppressesWhitespaceLeadingCompletionAfterInvalidFragment() {
        // "follo" is not a standalone word; " up on that" would insert
        // "follo up on that" — broken text the guard must reject.
        let detailed = CotypingTextNormalizer.normalizeDetailed(
            " up on that",
            for: wordPrefixRequest(prefix: "I wanted to follo", wordPrefix: "follo", isValidWord: false))
        XCTAssertEqual(detailed.text, "")
        XCTAssertEqual(detailed.suppression, .wordCompletionMismatch)
    }

    func testKeepsCompletionThatExtendsTheFragment() {
        let detailed = CotypingTextNormalizer.normalizeDetailed(
            "w up on that",
            for: wordPrefixRequest(prefix: "I wanted to follo", wordPrefix: "follo", isValidWord: false))
        XCTAssertEqual(detailed.text, "w up on that")
        XCTAssertNil(detailed.suppression)
    }

    func testValidWordFragmentMayBeFollowedBySpace() {
        // "the" is a complete word in its own right — the model may legitimately
        // treat it as finished and continue with a new word.
        let detailed = CotypingTextNormalizer.normalizeDetailed(
            " meeting",
            for: wordPrefixRequest(prefix: "I will attend the", wordPrefix: "the", isValidWord: true))
        XCTAssertEqual(detailed.text, " meeting")
        XCTAssertNil(detailed.suppression)
    }

    func testGuardNeverFiresWithoutFragmentAtCaret() {
        let detailed = CotypingTextNormalizer.normalizeDetailed(
            " up on that",
            for: wordPrefixRequest(prefix: "I wanted to ", wordPrefix: "", isValidWord: false))
        XCTAssertEqual(detailed.text, "up on that")
        XCTAssertNil(detailed.suppression)
    }

    func testForceWordContinuationPathUnchangedByWordPrefixFields() {
        // Strictly inside a word the force path already strips the leading
        // space and validates the tail; the new guard must stay out of its way.
        let detailed = CotypingTextNormalizer.normalizeDetailed(
            " ord",
            for: wordPrefixRequest(
                prefix: "rec", trailing: "ord", wordPrefix: "rec", isValidWord: false, force: true))
        XCTAssertEqual(detailed.text, "ord")
        XCTAssertNil(detailed.suppression)
    }
}

// MARK: - Trailing duplication filter

final class CotypingTrailingDuplicationFilterTests: XCTestCase {
    func testCompletionIsPrefixOfTrailing() {
        XCTAssertTrue(CotypingTrailingDuplicationFilter.duplicatesTrailingText("tomor", trailingText: "tomorrow"))
    }

    func testShortOverlapNotSuppressed() {
        XCTAssertFalse(CotypingTrailingDuplicationFilter.duplicatesTrailingText("a", trailingText: "apple"))
    }

    func testIgnoresLeadingPunctuationWhenFolding() {
        XCTAssertTrue(CotypingTrailingDuplicationFilter.duplicatesTrailingText("- world", trailingText: "world peace"))
    }

    func testUnrelatedTextNotSuppressed() {
        XCTAssertFalse(CotypingTrailingDuplicationFilter.duplicatesTrailingText("brand new idea", trailingText: "old plan"))
    }
}
