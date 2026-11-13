import XCTest
@testable import LokalBot

final class SerbianLatinScriptTests: XCTestCase {
    func testSpellsSerbianCyrillicInLatin() {
        XCTAssertEqual(SerbianLatinScript.latin("ово смо урадили мање више за један дан"),
                       "ovo smo uradili manje više za jedan dan")
        XCTAssertEqual(SerbianLatinScript.latin("Ђорђе, ћерка, џеп, љубав, њива, чаша, жаба"),
                       "Đorđe, ćerka, džep, ljubav, njiva, čaša, žaba")
    }

    func testDigraphCaseFollowsTheWord() {
        XCTAssertEqual(SerbianLatinScript.latin("Љубљана"), "Ljubljana")
        XCTAssertEqual(SerbianLatinScript.latin("ЉУБЉАНА"), "LJUBLJANA")
        XCTAssertEqual(SerbianLatinScript.latin("Џон"), "Džon")
    }

    /// A model drifting out of Serbian writes Russian or Macedonian letters.
    func testRussianAndMacedonianLettersTakeTheirClosestSerbianSpelling() {
        XCTAssertEqual(SerbianLatinScript.latin("Хорошо, такой план"), "Horošo, takoj plan")
        XCTAssertEqual(SerbianLatinScript.latin("Мој предлог е да се сретнеме утре"),
                       "Moj predlog e da se sretneme utre")
        XCTAssertEqual(SerbianLatinScript.latin("ѓ ќ ѕ я ю щ ъ ь"), "đ ć dz ja ju šč  ")
    }

    func testTranscriptsInThisLanguageAreWrittenInLatin() {
        let transcript = Transcript(segments: [
            .init(start: 0, end: 4, speaker: "them", text: "Projekat kasni dvije sedmice zbog problema sa dobavljačem."),
            .init(start: 4, end: 8, speaker: "them", text: "али мислим да ћемо рок ипак стићи ако почнемо одмах."),
            .init(start: 8, end: 12, speaker: "them", text: "Budžet za sljedeći kvartal još nije odobren, ali radimo na tome."),
        ], engine: "test")

        let auto = SerbianLatinScript.latinTranscript(transcript, language: nil)
        XCTAssertEqual(auto.changedSegments, 1)
        XCTAssertEqual(auto.transcript.segments[1].text, "ali mislim da ćemo rok ipak stići ako počnemo odmah.")
        XCTAssertEqual(auto.transcript.segments[0], transcript.segments[0])

        XCTAssertEqual(SerbianLatinScript.latinTranscript(transcript, language: "sr").changedSegments, 1)
        XCTAssertEqual(SerbianLatinScript.latinTranscript(transcript, language: "bs").changedSegments, 1)
    }

    func testOtherCyrillicLanguagesKeepTheirScript() {
        let russian = Transcript(segments: [
            .init(start: 0, end: 4, speaker: "them", text: "Мы перенесли встречу на следующую неделю, потому что коллеги заболели."),
            .init(start: 4, end: 8, speaker: "them", text: "Пожалуйста, пришлите мне документы до пятницы, чтобы всё подготовить."),
        ], engine: "test")
        XCTAssertEqual(SerbianLatinScript.latinTranscript(russian, language: nil).transcript.segments, russian.segments)
        XCTAssertEqual(SerbianLatinScript.latinTranscript(russian, language: "ru").transcript.segments, russian.segments)
        XCTAssertEqual(SerbianLatinScript.latinTranscript(russian, language: "en").changedSegments, 0)
    }

    /// Apple's recognizer reads Serbian Cyrillic as Kazakh or Ukrainian, so
    /// Serbian's own letters decide it.
    func testSerbianCyrillicIsRecognizedByItsOwnLetters() {
        XCTAssertTrue(SerbianLatinScript.isSerbianCyrillic("мислим да ћемо рок ипак стићи"))
        XCTAssertTrue(SerbianLatinScript.isSerbianCyrillic("Између нас, ђе си био?"))
        XCTAssertFalse(SerbianLatinScript.isSerbianCyrillic("ово смо урадили мање више"), "No ђ or ћ: undecided")
        XCTAssertFalse(SerbianLatinScript.isSerbianCyrillic("Ќе дојдам утре, ѓубре"), "Macedonian")
        XCTAssertFalse(SerbianLatinScript.isSerbianCyrillic("Такой ћу"), "A Russian й")
        XCTAssertFalse(SerbianLatinScript.isSerbianCyrillic("Ja ću doći sutra."), "Latin script")
    }

    func testLeavesLatinDigitsAndOtherScriptsAlone() {
        let mixed = "Plan za Q3, 40 korisnika, verzija 2.0 — 嗯"
        XCTAssertEqual(SerbianLatinScript.latin(mixed), mixed)
        XCTAssertEqual(SerbianLatinScript.latin("Hvala, Ana: мислим да"), "Hvala, Ana: mislim da")
        XCTAssertFalse(SerbianLatinScript.containsCyrillic(mixed))
        XCTAssertTrue(SerbianLatinScript.containsCyrillic("da да"))
    }
}
