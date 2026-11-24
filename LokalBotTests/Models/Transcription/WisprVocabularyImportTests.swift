import XCTest
@testable import LokalBot

final class WisprVocabularyImportTests: XCTestCase {
    private typealias Entry = WisprFlowLibrary.DictionaryEntry
    private static let everyday: Set<String> = ["meeting", "invoice"]

    private func plan(_ entries: [Entry], existing: String = "") -> WisprVocabularyImport.Plan {
        WisprVocabularyImport.plan(entries, existing: existing, isEverydayWord: { Self.everyday.contains($0) })
    }

    func testWordsComeInMostUsedFirstWithStarredAhead() {
        let result = plan([
            Entry(phrase: "Acme", isSnippet: false, timesUsed: 2),
            Entry(phrase: "Orion Launch", isSnippet: false, timesUsed: 9),
            Entry(phrase: "Kubernetes", isSnippet: false, isStarred: true, timesUsed: 0),
            Entry(phrase: "Birch", isSnippet: false, timesUsed: 2, lastUsed: "2026-11-02"),
        ])
        XCTAssertEqual(result.terms, ["Kubernetes", "Orion Launch", "Birch", "Acme"])
    }

    func testSnippetsAndDeletedEntriesStayOut() {
        let result = plan([
            Entry(phrase: "addr", replacement: "12 Example Street", isSnippet: true),
            Entry(phrase: "sig", replacement: "Best, Mila", isSnippet: nil),
            Entry(phrase: "Old Term", isSnippet: false, isDeleted: true),
            Entry(phrase: "Orion", isSnippet: nil),
        ])
        XCTAssertEqual(result.terms, ["Orion"], "a missing snippet flag is fine without a replacement")
        XCTAssertEqual(result.snippets, 2, "a replacement with an unknown snippet flag is treated as a snippet")
        XCTAssertEqual(result.deleted, 1)
    }

    func testAShortReplacementIsTheWordThatComesIn() {
        let result = plan([
            Entry(phrase: "mila", replacement: "Mila Novak", isSnippet: false),
            Entry(phrase: "intro", replacement: "Thanks for the intro, looking forward to it", isSnippet: false),
        ])
        XCTAssertEqual(result.terms, ["Mila Novak"])
        XCTAssertEqual(result.unusable, 1, "a long replacement is a phrase, not vocabulary")
    }

    func testEverydayLowerCaseWordsStayOutButNamesAndJargonDoNot() {
        let result = plan([
            Entry(phrase: "meeting", isSnippet: false),
            Entry(phrase: "Invoice", isSnippet: false),
            Entry(phrase: "kubectl", isSnippet: false),
            Entry(phrase: "standup meeting", isSnippet: false),
        ])
        XCTAssertEqual(result.terms, ["Invoice", "kubectl", "standup meeting"])
        XCTAssertEqual(result.everydayWords, 1)
    }

    func testWordsAlreadyListedOrRepeatedAreSkipped() {
        let result = plan([
            Entry(phrase: "Orion Launch", isSnippet: false),
            Entry(phrase: "orion launch", isSnippet: false),
            Entry(phrase: "Mila Novák", isSnippet: false),
            Entry(phrase: "Birch", isSnippet: false),
        ], existing: "Mila Novak, Acme\nBirch.")
        XCTAssertEqual(result.terms, ["Orion Launch"])
        XCTAssertEqual(result.alreadyListed, 3, "case, accents and list punctuation don't make a new word")
    }

    func testUnusableTermsAreSkipped() {
        let result = plan([
            Entry(phrase: "x", isSnippet: false),
            Entry(phrase: "Smith, Jones", isSnippet: false),
            Entry(phrase: "  Orion   Launch. ", isSnippet: false),
            Entry(phrase: String(repeating: "a", count: 61), isSnippet: false),
            Entry(phrase: "!!!", isSnippet: false),
        ])
        XCTAssertEqual(result.terms, ["Orion Launch"])
        XCTAssertEqual(result.unusable, 4)
    }

    func testTheImportStaysWithinTheAutomaticVocabularyBudget() {
        let many = (1...60).map { Entry(phrase: String(format: "Term%02d", $0), isSnippet: false, timesUsed: 100 - $0) }
        let result = plan(many)
        XCTAssertEqual(result.terms.count, TranscriptionVocabulary.maximumTerms)
        XCTAssertEqual(result.overLimit, 60 - TranscriptionVocabulary.maximumTerms)
        XCTAssertEqual(result.terms.first, "Term01")

        let long = (1...20).map { Entry(phrase: String(format: "Project %02d ", $0) + String(repeating: "x", count: 40),
                                        isSnippet: false, timesUsed: 100 - $0) }
        let byCharacters = plan(long)
        let used = byCharacters.terms.reduce(0) { $0 + $1.count + 2 }
        XCTAssertLessThanOrEqual(used, TranscriptionVocabulary.maximumCharacters)
        XCTAssertEqual(byCharacters.terms.count + byCharacters.overLimit, 20)
    }

    func testAddingKeepsWhatIsAlreadyThere() {
        XCTAssertEqual(WisprVocabularyImport.vocabulary("", adding: ["Orion", "Acme"]), "Orion, Acme")
        XCTAssertEqual(WisprVocabularyImport.vocabulary("Birch, Mila Novak\n", adding: ["Orion"]), "Birch, Mila Novak\nOrion")
        XCTAssertEqual(WisprVocabularyImport.vocabulary("Birch", adding: []), "Birch")
    }

    @MainActor
    func testTheRealDictionaryCheck() throws {
        try XCTSkipUnless(NSSpellChecker.shared.availableLanguages.contains { $0.hasPrefix("en") },
                          "needs macOS's English dictionary")
        XCTAssertTrue(WisprVocabularyImport.isEverydayEnglishWord("meeting"))
        XCTAssertFalse(WisprVocabularyImport.isEverydayEnglishWord("kubectl"))
    }
}
