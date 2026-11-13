import AppKit
import XCTest
@testable import LokalBot

// MARK: - Phrase acceptance, accept options, context prompt

final class CotypingWordAcceptanceTests: XCTestCase {
    func testLatinAcceptanceUnchangedBySpacelessBranch() {
        XCTAssertEqual(CotypingAcceptanceChunker.nextWord(in: "hello world"), "hello")
        XCTAssertEqual(CotypingAcceptanceChunker.nextWord(in: "don't stop now"), "don't")
        XCTAssertEqual(CotypingAcceptanceChunker.nextWord(in: "U.S.A today"), "U.S.A")
        XCTAssertEqual(CotypingAcceptanceChunker.nextWord(in: "1.5 times"), "1.5")
        XCTAssertEqual(CotypingAcceptanceChunker.nextWord(in: "caf\u{00e9} Ren\u{00e9}"), "caf\u{00e9}")
        XCTAssertEqual(CotypingAcceptanceChunker.nextWord(in: "world \u{4f60}\u{597d}"), "world")
    }

    func testSplitsTrailingPunctuationWhenAutoAcceptDisabled() {
        XCTAssertEqual(
            CotypingAcceptanceChunker.nextWord(in: "you?", autoAcceptTrailingPunctuation: false),
            "you")
        XCTAssertEqual(
            CotypingAcceptanceChunker.nextWord(in: "?!", autoAcceptTrailingPunctuation: false),
            "?!")
        XCTAssertEqual(
            CotypingAcceptanceChunker.nextWord(in: "U.S.A.", autoAcceptTrailingPunctuation: false),
            "U.S.A")
        XCTAssertEqual(
            CotypingAcceptanceChunker.nextWord(in: " don't!", autoAcceptTrailingPunctuation: false),
            " don't")
    }

    func testAddSpacePolicyConsumesModelWhitespaceOnlyWhenEnabled() {
        XCTAssertEqual(
            CotypingAcceptanceChunker.acceptanceChunkConsumingTrailingSpace(
                "hello",
                remainingText: "hello world"),
            "hello ")
        XCTAssertEqual(
            CotypingAcceptanceChunker.acceptanceChunkConsumingTrailingSpace(
                "hello",
                remainingText: "helloworld"),
            "hello")
        XCTAssertEqual(
            CotypingAcceptanceChunker.acceptanceChunkConsumingTrailingSpace(
                "\u{8cc7}\u{6599}",
                remainingText: "\u{8cc7}\u{6599} \u{5185}\u{5bb9}"),
            "\u{8cc7}\u{6599}")
    }

    func testInsertionChunkDropsLeadingSpaceWhenFieldAlreadyHasOne() {
        XCTAssertEqual(
            CotypingAcceptanceChunker.insertionChunk(
                forAcceptedChunk: " world",
                precedingText: "hello "),
            "world")
        XCTAssertEqual(
            CotypingAcceptanceChunker.insertionChunk(
                forAcceptedChunk: " world",
                precedingText: "hello"),
            " world")
    }

    func testInsertionChunkPrefixesMissingSpaceAfterSentencePunctuation() {
        XCTAssertEqual(
            CotypingAcceptanceChunker.insertionChunk(
                forAcceptedChunk: "Next",
                precedingText: "done."),
            " Next")
        XCTAssertEqual(
            CotypingAcceptanceChunker.insertionChunk(
                forAcceptedChunk: "Next",
                precedingText: "done!"),
            " Next")
        XCTAssertEqual(
            CotypingAcceptanceChunker.insertionChunk(
                forAcceptedChunk: "Next",
                precedingText: "done?"),
            " Next")
        XCTAssertEqual(
            CotypingAcceptanceChunker.insertionChunk(
                forAcceptedChunk: " Next",
                precedingText: "done."),
            " Next")
    }

    func testInsertionChunkKeepsCompactDotTokensAttached() {
        XCTAssertEqual(
            CotypingAcceptanceChunker.insertionChunk(
                forAcceptedChunk: "2",
                precedingText: "version 1."),
            "2")
        XCTAssertEqual(
            CotypingAcceptanceChunker.insertionChunk(
                forAcceptedChunk: "S",
                precedingText: "U."),
            "S")
        XCTAssertEqual(
            CotypingAcceptanceChunker.insertionChunk(
                forAcceptedChunk: "com",
                precedingText: "example."),
            "com")
        XCTAssertEqual(
            CotypingAcceptanceChunker.insertionChunk(
                forAcceptedChunk: "env",
                precedingText: "."),
            "env")
    }

    func testFinalAddSpaceAppendsOnlyAfterCompletedWords() {
        let session = CotypingSession(
            field: CotypingField(
                appName: "TextEdit", bundleID: "com.apple.TextEdit", processID: 1,
                role: "AXTextArea", precedingText: "hello", trailingText: "",
                selectionLength: 0, caretRect: .zero, isSecure: false, caretIsExact: true),
            fullText: " world")
        XCTAssertEqual(
            CotypingAcceptanceChunker.insertionTextApplyingAutoSpace(
                insertionChunk: " world",
                acceptedChunk: " world",
                session: session,
                addSpaceAfterAccept: true),
            " world ")
        XCTAssertEqual(
            CotypingAcceptanceChunker.insertionTextApplyingAutoSpace(
                insertionChunk: " world.",
                acceptedChunk: " world.",
                session: CotypingSession(field: session.field, fullText: " world."),
                addSpaceAfterAccept: true),
            " world.")
    }

    func testChineseRunSegmentsInsteadOfAcceptingWholeTail() {
        let run = "\u{4f60}\u{597d}\u{4e16}\u{754c}"
        let chunk = CotypingAcceptanceChunker.nextWord(in: run)
        XCTAssertFalse(chunk.isEmpty)
        XCTAssertTrue(run.hasPrefix(chunk))
        XCTAssertLessThan(chunk.count, run.count)
    }

    func testJapaneseRunSegmentsInsteadOfAcceptingWholeTail() {
        let run = "\u{4eca}\u{65e5}\u{306f}\u{3044}\u{3044}\u{5929}\u{6c17}\u{3067}\u{3059}"
        let chunk = CotypingAcceptanceChunker.nextWord(in: run)
        XCTAssertFalse(chunk.isEmpty)
        XCTAssertTrue(run.hasPrefix(chunk))
        XCTAssertLessThan(chunk.count, run.count)
    }

    func testThaiRunSegmentsInsteadOfAcceptingWholeTail() {
        let run = "\u{0e2a}\u{0e27}\u{0e31}\u{0e2a}\u{0e14}\u{0e35}\u{0e04}\u{0e23}\u{0e31}\u{0e1a}"
        let chunk = CotypingAcceptanceChunker.nextWord(in: run)
        XCTAssertFalse(chunk.isEmpty)
        XCTAssertTrue(run.hasPrefix(chunk))
        XCTAssertLessThan(chunk.count, run.count)
    }

    func testBindsTrailingCJKPunctuationToWord() {
        XCTAssertEqual(
            CotypingAcceptanceChunker.nextWord(in: "\u{8cc7}\u{6599}\u{3001}\u{5185}\u{5bb9}"),
            "\u{8cc7}\u{6599}\u{3001}")
    }

    func testPeelsLeadingCJKPunctuationRun() {
        XCTAssertEqual(
            CotypingAcceptanceChunker.nextWord(in: "\u{3001}\u{7406}\u{89e3}\u{3057}\u{3001}\u{305d}\u{306e}\u{5185}\u{5bb9}"),
            "\u{3001}")
        XCTAssertEqual(
            CotypingAcceptanceChunker.nextWord(in: "\u{3002}\u{300d}\u{6b21}\u{306e}\u{6587}"),
            "\u{3002}\u{300d}")
        XCTAssertEqual(
            CotypingAcceptanceChunker.nextWord(in: "\u{300c}\u{5206}\u{304b}\u{3063}\u{305f}\u{300d}\u{3068}\u{8a00}\u{3063}\u{305f}"),
            "\u{300c}")
    }
}

final class CotypingPhraseTests: XCTestCase {
    func testDoesNotStopAtAsciiComma() {
        XCTAssertEqual(CotypingAcceptanceChunker.nextPhrase(in: "Hi Sarah, thanks."), "Hi Sarah, thanks.")
    }
    func testWholeTextWhenNoBoundary() {
        XCTAssertEqual(CotypingAcceptanceChunker.nextPhrase(in: "the quick brown"), "the quick brown")
    }
    func testStopsAtSentenceEnd() {
        XCTAssertEqual(CotypingAcceptanceChunker.nextPhrase(in: "done. next thing"), "done.")
    }
    func testStopsAtNewline() {
        XCTAssertEqual(CotypingAcceptanceChunker.nextPhrase(in: "done\nnext thing"), "done\n")
    }
    func testCJKClauseBoundary() {
        XCTAssertEqual(
            CotypingAcceptanceChunker.nextPhrase(in: "\u{8cc7}\u{6599}\u{3092}\u{8aad}\u{307f}\u{3001}\u{6b21}\u{3078}"),
            "\u{8cc7}\u{6599}\u{3092}\u{8aad}\u{307f}\u{3001}")
        XCTAssertEqual(
            CotypingAcceptanceChunker.nextPhrase(in: "\u{4f60}\u{597d}\u{3002}\u{518d}\u{89c1}"),
            "\u{4f60}\u{597d}\u{3002}")
    }

    func testWalksPastDottedInitialsToRealSentenceEnd() {
        XCTAssertEqual(
            CotypingAcceptanceChunker.nextPhrase(in: "U.S.A. is great."),
            "U.S.A. is great.")
    }

    func testDoesNotStopPhraseAtDecimalListNumberOrAbbreviationPeriod() {
        XCTAssertEqual(
            CotypingAcceptanceChunker.nextPhrase(in: "version 1.2 is ready."),
            "version 1.2 is ready.")
        XCTAssertEqual(
            CotypingAcceptanceChunker.nextPhrase(in: "for example, e.g. this one."),
            "for example, e.g. this one.")
        XCTAssertEqual(
            CotypingAcceptanceChunker.nextPhrase(in: "item 1. next"),
            "item 1. next")
    }

    func testPhraseOutputInvariantToAutoAcceptTrailingPunctuationFlag() {
        XCTAssertEqual(
            CotypingAcceptanceChunker.nextPhrase(
                in: "you? Yes.",
                autoAcceptTrailingPunctuation: true),
            "you?")
        XCTAssertEqual(
            CotypingAcceptanceChunker.nextPhrase(
                in: "you? Yes.",
                autoAcceptTrailingPunctuation: false),
            "you?")
    }
}

final class CotypingAcceptOptionsTests: XCTestCase {
    func testDefaults() {
        let settings = AppSettings()
        XCTAssertEqual(settings.cotypingAcceptGranularity, .word)
        XCTAssertEqual(settings.cotypingAcceptKey, .tab)
        XCTAssertEqual(settings.cotypingFullAcceptKey, .backtick)
        // Cotypist's default: punctuation after a word takes its own press.
        XCTAssertFalse(settings.cotypingAutoAcceptTrailingPunctuation)
        XCTAssertEqual(settings.cotypingEscapeBehavior, .pause)
        XCTAssertFalse(settings.cotypingAddSpaceAfterAccept)
    }
    func testKeyCodes() {
        XCTAssertEqual(CotypingAcceptKey.tab.keyCode, 48)
        XCTAssertEqual(CotypingAcceptKey.rightArrow.keyCode, 124)
        XCTAssertEqual(CotypingFullAcceptKey.backtick.keyCode, 50)
        XCTAssertNil(CotypingFullAcceptKey.off.keyCode)
    }
}
