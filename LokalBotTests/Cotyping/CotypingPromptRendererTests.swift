import AppKit
import XCTest
@testable import LokalBot

// MARK: - Prompt renderer

final class CotypingPromptRendererTests: XCTestCase {
    func testBarePrefixWhenNoPreface() {
        XCTAssertEqual(CotypingPromptRenderer.prompt(prefixText: "Hello wo"), "Hello wo")
        XCTAssertNil(CotypingPromptRenderer.render(prefixText: "Hello wo").conditioningPreface)
    }

    func testCaretWhitespaceIsPreserved() {
        XCTAssertEqual(CotypingPromptRenderer.prompt(prefixText: "Hello wo  \n\t"), "Hello wo  \n\t")
    }

    func testPersonaPreface() {
        XCTAssertEqual(
            CotypingPromptRenderer.prompt(prefixText: "x", userName: "Jacob"),
            "Written by Jacob.\n\nx")
    }

    func testFullPrefaceOrder() {
        let prompt = CotypingPromptRenderer.prompt(
            prefixText: "the caret text",
            userName: "Ada", styleNote: "concise", languageHint: "Writes in German.")
        XCTAssertEqual(prompt, "Written by Ada.\nWriting style: concise.\nWrites in German.\n\nthe caret text")
    }

    func testRenderExposesExactHiddenPreface() {
        let rendered = CotypingPromptRenderer.render(
            prefixText: "the caret text",
            surfaceLines: ["An email being written in Mail."],
            userName: "Ada",
            clipboardContext: "release plan")

        XCTAssertEqual(
            rendered.conditioningPreface,
            "An email being written in Mail.\nWritten by Ada.\nOn the clipboard: release plan")
        XCTAssertEqual(rendered.prompt, rendered.conditioningPreface! + "\n\nthe caret text")
    }

    func testBlankPersonaIgnored() {
        XCTAssertEqual(CotypingPromptRenderer.prompt(prefixText: "x", userName: "   "), "x")
    }

    func testLearnedExamplesEnterPrefaceBeforePrefix() {
        let prompt = CotypingPromptRenderer.prompt(
            prefixText: "Thanks for",
            learnedExamples: ["following up with the final numbers"])
        XCTAssertEqual(
            prompt,
            "Previously accepted completion: following up with the final numbers\n\nThanks for")
    }

    func testRendererHonorsAllProvidedLearnedExamples() {
        let examples = (1...5).map { "example \($0)" }
        let prompt = CotypingPromptRenderer.prompt(prefixText: "Thanks", learnedExamples: examples)
        for example in examples {
            XCTAssertTrue(prompt.contains("Previously accepted completion: \(example)"))
        }
    }
}

final class CotypingContextPromptTests: XCTestCase {
    func testLanguageAndNotesEnterPreface() {
        let prompt = CotypingPromptRenderer.prompt(
            prefixText: "Dear team",
            languageHint: "The text is usually written in German.",
            extendedContext: "Acme = our product")
        XCTAssertTrue(prompt.contains("The text is usually written in German."))
        XCTAssertTrue(prompt.contains("Notes the writer keeps in mind: Acme = our product"))
        XCTAssertTrue(prompt.hasSuffix("Dear team"))
    }

    func testPersonalizationDerivesLanguageAndNotes() {
        var settings = AppSettings()
        settings.cotypingLanguages = "English, German"
        settings.cotypingExtendedContext = "Acme = our product"
        let personalization = settings.cotypingPersonalization
        XCTAssertEqual(personalization.languageHint, "The text is usually written in English, German.")
        XCTAssertEqual(personalization.extendedContext, "Acme = our product")
    }
}
