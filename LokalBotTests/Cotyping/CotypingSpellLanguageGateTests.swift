import XCTest
@testable import LokalBot

/// The stock macOS dictionary set (abridged): notably no sr/hr/bs — Serbian,
/// Croatian, Bosnian, and Montenegrin have no spell-check support at all.
private let stockLanguages = ["en", "en_GB", "en_CA", "de", "fr", "ru", "bg", "pt_BR", "pt_PT", "sl"]

final class CotypingSpellLanguageGateTests: XCTestCase {
    func testSerbianLatinContextStandsDown() {
        XCTAssertFalse(CotypingSpellLanguageGate.spellVerdictsApply(
            context: "Vidimo se sutra na sastanku, moramo da pričamo o izvještaju",
            availableLanguages: stockLanguages))
    }

    func testMontenegrinContextStandsDown() {
        XCTAssertFalse(CotypingSpellLanguageGate.spellVerdictsApply(
            context: "Đe si, šta ima? Hoćemo li se viđeti večeras u gradu",
            availableLanguages: stockLanguages))
    }

    func testEnglishContextKeepsVerdicts() {
        XCTAssertTrue(CotypingSpellLanguageGate.spellVerdictsApply(
            context: "See you tomorrow at the meeting, we need to talk about the report",
            availableLanguages: stockLanguages))
    }

    func testGermanContextKeepsVerdicts() {
        XCTAssertTrue(CotypingSpellLanguageGate.spellVerdictsApply(
            context: "Wir sehen uns morgen bei der Besprechung",
            availableLanguages: stockLanguages))
    }

    func testAmbiguousShortContextKeepsVerdicts() {
        // Recognizer confidence for one-word fragments varies by macOS model;
        // the gate must not stand down without multi-word language evidence.
        XCTAssertTrue(CotypingSpellLanguageGate.spellVerdictsApply(
            context: "sasta", availableLanguages: stockLanguages))
        XCTAssertTrue(CotypingSpellLanguageGate.spellVerdictsApply(
            context: "ok", availableLanguages: stockLanguages))
    }

    func testEmptyContextKeepsVerdicts() {
        XCTAssertTrue(CotypingSpellLanguageGate.spellVerdictsApply(
            context: "", availableLanguages: stockLanguages))
        XCTAssertTrue(CotypingSpellLanguageGate.spellVerdictsApply(
            context: "   \n", availableLanguages: stockLanguages))
    }

    func testIdentificationWindowsToCaretContext() {
        // An English preamble must not keep the gate armed once the text at
        // the caret is a full window of Serbian.
        let serbianTail = String(
            repeating: "Vidimo se sutra na sastanku i onda pričamo o izvještaju. ",
            count: 5)
        let context = "This document started in English a while ago. " + serbianTail
        XCTAssertFalse(CotypingSpellLanguageGate.spellVerdictsApply(
            context: context, availableLanguages: stockLanguages))
    }

    func testDictionaryLookupMatchesBaseCode() {
        XCTAssertTrue(CotypingSpellLanguageGate.hasDictionary(for: "en", in: ["en_GB"]))
        XCTAssertTrue(CotypingSpellLanguageGate.hasDictionary(for: "pt", in: ["pt_BR", "pt_PT"]))
        XCTAssertFalse(CotypingSpellLanguageGate.hasDictionary(for: "hr", in: stockLanguages))
        XCTAssertFalse(CotypingSpellLanguageGate.hasDictionary(for: "sr", in: stockLanguages))
    }
}
