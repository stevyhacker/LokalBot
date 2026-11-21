import XCTest
@testable import LokalBot

final class LanguageVoteTests: XCTestCase {
    private let english = [
        "I dropped a question on Discord, so any time just check it out and let me know what you think.",
        "We are polishing the fee extraction pull request and I have a few conflicts to solve now.",
        "Hopefully I have something by next week that we can try integrating into the interface.",
    ]
    private let german = [
        "Wir haben gestern die neue Version veröffentlicht und die ersten Rückmeldungen sind sehr positiv.",
        "Könnten Sie mir bitte die Unterlagen bis Freitag schicken, damit wir alles vorbereiten können?",
    ]

    func testAMisdetectedOpeningDoesNotDecideTheTrack() throws {
        let texts = ["abytrował, czyli taki, czyli gadajmyśników."] + english
        let vote = try XCTUnwrap(TranscriptLanguageVote.dominant(in: texts))
        XCTAssertEqual(vote.code, "en")
        XCTAssertGreaterThanOrEqual(vote.share, 0.8)
        XCTAssertEqual(QwenASREngine.pinnedLanguage(for: texts), "en")
        XCTAssertEqual(QwenWordAligner.detectedLanguage(of: texts), "en")
    }

    func testMixedLanguageTracksStayOnPerWindowDetection() {
        let texts = [english[0], german[0], english[1], german[1]]
        XCTAssertNil(QwenASREngine.pinnedLanguage(for: texts))
        XCTAssertNotNil(QwenWordAligner.detectedLanguage(of: texts))
    }

    func testShortRepliesDoNotVote() {
        XCTAssertNil(TranscriptLanguageVote.dominant(in: ["Hahaha.", "呵呵呵。", "Okay yeah."]))
        XCTAssertNil(QwenASREngine.pinnedLanguage(for: ["Hahaha.", "呵呵呵。"]))
    }

    func testLanguagesQwenDoesNotSupportAreNotPinned() {
        let ukrainian = [
            "Зустріч перенесли на наступний тиждень, бо двоє колег захворіли.",
            "Будь ласка, надішліть мені документи до п'ятниці, щоб ми встигли все підготувати.",
        ]
        XCTAssertNil(QwenASREngine.pinnedLanguage(for: ukrainian))
        XCTAssertFalse(QwenASREngine.supportedLanguages.contains("sr"))
        XCTAssertTrue(QwenASREngine.supportedLanguages.isSuperset(of: ["en", "zh", "yue", "de", "ja", "mk"]))
    }

    func testSerbianCroatianAndBosnianTracksPinToCroatianInEitherScript() throws {
        let montenegrin = [
            "Sastanak smo pomjerili za sljedeću sedmicu jer su dvije koleginice bolesne.",
            "Projekat kasni dvije sedmice zbog problema sa dobavljačem.",
            "али мислим да ћемо рок ипак стићи ако почнемо одмах.",
        ]
        let croatian = [
            "Nakon sastanka ćemo poslati zapisnik i dogovoriti sljedeće korake s timom.",
            "Prijedlog je da proračun za idući kvartal odobrimo do petka.",
        ]
        XCTAssertEqual(QwenASREngine.pinnedLanguage(for: montenegrin), "hr")
        XCTAssertEqual(QwenASREngine.pinnedLanguage(for: croatian), "hr")
        let vote = try XCTUnwrap(TranscriptLanguageVote.dominant(
            in: montenegrin, aliases: TranscriptLanguageVote.serbianCroatianAliases))
        XCTAssertEqual(vote.code, "hr")
        XCTAssertEqual(vote.share, 1, accuracy: 0.001)
        XCTAssertLessThan(try XCTUnwrap(TranscriptLanguageVote.dominant(in: montenegrin)).share, 0.8)
        XCTAssertEqual(QwenASREngine.pinnedLanguage(for: english + [montenegrin[1]]), "en")
    }

    func testBaseCodes() {
        XCTAssertEqual(TranscriptLanguageVote.baseCode("zh-Hant"), "zh")
        XCTAssertEqual(TranscriptLanguageVote.baseCode("pt_PT"), "pt")
        XCTAssertEqual(TranscriptLanguageVote.baseCode("EN"), "en")
    }
}
