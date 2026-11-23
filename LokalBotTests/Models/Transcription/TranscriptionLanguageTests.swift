import XCTest
@testable import LokalBot

final class TranscriptionLanguageTests: XCTestCase {
    func testTranscriptionPromptTrimsWhitespaceAndDropsEmptyValues() {
        XCTAssertEqual(
            TranscriptionPrompt.normalized("  LokalBot, QVAC  \n"),
            "LokalBot, QVAC")
        XCTAssertNil(TranscriptionPrompt.normalized(" \n\t "))
        XCTAssertNil(TranscriptionPrompt.normalized(nil))
    }

    func testAutoLanguageHasNoEngineCode() {
        XCTAssertNil(TranscriptionLanguage.auto.code)
    }

    func testConcreteLanguageUsesRawCode() {
        XCTAssertEqual(TranscriptionLanguage.de.code, "de")
    }

    func testLegacyHintMigrationNormalizesKnownCodes() {
        XCTAssertEqual(TranscriptionLanguage.fromLegacyHint(" DE "), .de)
    }

    func testSerbianCanBeChosenForTranscriptionAndNotes() {
        let serbian = try? XCTUnwrap(TranscriptionLanguage(rawValue: "sr"))
        XCTAssertEqual(serbian, .language(.sr))
        XCTAssertEqual(serbian?.code, "sr")
        XCTAssertEqual(serbian?.displayName, "Serbian")
        XCTAssertTrue(TranscriptionLanguage.allCases.contains(.language(.sr)))
        XCTAssertEqual(SummaryLanguage(rawValue: "sr"), .sr)
        XCTAssertNil(TranscriptionLanguage(rawValue: "hr"))
    }

    func testLegacyHintMigrationFallsBackToAutoForUnknownCodes() {
        XCTAssertEqual(TranscriptionLanguage.fromLegacyHint("klingon"), .auto)
        XCTAssertEqual(TranscriptionLanguage.fromLegacyHint(""), .auto)
    }
}

final class SummaryLanguageTests: XCTestCase {
    private func transcript(_ texts: [String]) -> Transcript {
        Transcript(
            segments: texts.enumerated().map { index, text in
                .init(start: Double(index) * 4, end: Double(index + 1) * 4, speaker: "them",
                      text: text, confidence: nil)
            },
            engine: "test")
    }

    func testSerbianCroatianMeetingIsNotRelabeledByAWeakRunnerUp() {
        let meeting = transcript([
            "Dobro jutro, drago mi je da smo se čuli danas prije podne.",
            "Ja radim kao softverski inženjer već desetak godina, uglavnom za strane firme.",
            "Projekat je trenutno u fazi testiranja i imamo prve korisnike na Linuxu i Windowsu.",
            "Mislim da bi trebalo prvo da završimo dokumentaciju, pa onda da pričamo o investiciji.",
            "neka alternativa.",
            "Ne znam da li si stigao da pogledaš tekst koji sam ti poslao prošle sedmice.",
            "Proces kod nas obično traje tri ili četiri sastanka prije konačne odluke.",
            "Ajde, čujemo se sljedeće nedjelje, pa ćemo vidjeti šta dalje.",
        ])

        let language = SummaryLanguage.resolvedForTranscript(.matchTranscript, transcript: meeting)

        XCTAssertEqual(language, .bcms)
        XCTAssertEqual(language.displayName, "Bosnian, Croatian, Montenegrin, Serbian")
        let prompt = PromptTemplates.meetingNotesSystem(template: .meeting, language: language)
        XCTAssertTrue(prompt.contains("Write note and action text in the transcript's own language "
            + "(Bosnian, Croatian, Montenegrin or Serbian), keeping its ijekavian or ekavian forms and its script."))
    }

    func testSerbianCyrillicMeetingIsNotReadAsUkrainianOrKazakh() {
        let meeting = transcript([
            "Видјећемо се сутра, па ћемо причати о пројекту и документацији.",
            "Мислим да ће тестирање бити готово до краја мјесеца.",
            "Ја ћу ти послати документацију чим је завршим.",
            "Шта ћемо са инвестицијом, то ћемо одлучити касније.",
        ])

        XCTAssertEqual(SummaryLanguage.resolvedForTranscript(.matchTranscript, transcript: meeting), .bcms)
    }

    func testLanguagesOutsideTheMenuKeepTheirOwnName() {
        let czech = transcript([
            "Myslím, že musíme dokončit projekt do pátku a poslat zprávu klientovi.",
            "Zítra se sejdeme znovu a probereme rozpočet na příští rok.",
        ])
        let ukrainian = transcript([
            "Думаю, нам потрібно завершити проєкт до п'ятниці та надіслати звіт клієнту.",
            "Завтра ми зустрінемося знову й обговоримо бюджет на наступний рік.",
        ])

        XCTAssertEqual(SummaryLanguage.resolvedForTranscript(.matchTranscript, transcript: czech), .custom("Czech"))
        XCTAssertEqual(SummaryLanguage.resolvedForTranscript(.matchTranscript, transcript: ukrainian), .uk)
    }

    func testNotesMenuOffersEachSerbianCroatianLanguageButNotTheSharedGroup() {
        for language in [SummaryLanguage.bs, .hr, .cnr, .sr, .uk] {
            XCTAssertTrue(SummaryLanguage.presets.contains(language), language.displayName)
            XCTAssertEqual(SummaryLanguage(rawValue: language.rawValue), language)
        }
        XCTAssertFalse(SummaryLanguage.presets.contains(.bcms))
        XCTAssertEqual(SummaryLanguage.hr.promptLanguageName, "Croatian")
        XCTAssertEqual(SummaryLanguage.sr.promptLanguageName,
                       "Serbian, in the script the source text uses (Latin or Cyrillic)")
        XCTAssertEqual(SummaryLanguage.cnr.displayName, "Montenegrin")
        XCTAssertEqual(DailySummaryLanguage(notes: .sr, interface: .english).fallbackLanguage, .serbianLatin)
        XCTAssertEqual(DailySummaryLanguage(notes: .hr, interface: .german).fallbackLanguage, .german)
    }

    func testMatchTranscriptDetectsMajorityLanguageFromRawSegmentText() {
        let transcript = Transcript(
            segments: [
                .init(start: 0, end: 4, speaker: "me",
                      text: "We reviewed the onboarding plan and agreed the first release should stay focused on search quality.",
                      confidence: nil),
                .init(start: 5, end: 9, speaker: "me",
                      text: "A few Portuguese words appeared in the call, obrigado and bom dia, but they were not the meeting language.",
                      confidence: nil),
                .init(start: 10, end: 14, speaker: "them",
                      text: "The next action item is to fix the language detection before regenerating summaries.",
                      confidence: nil),
                .init(start: 15, end: 20, speaker: "me",
                      text: "After that, we can rerun the summary and confirm the notes are written in English.",
                      confidence: nil),
            ],
            engine: "test"
        )

        XCTAssertEqual(SummaryLanguage.resolvedForTranscript(.matchTranscript, transcript: transcript), .en)
    }

    func testConcreteSummaryLanguageStillBypassesDetection() {
        let transcript = Transcript(
            segments: [
                .init(start: 0, end: 1, speaker: "me",
                      text: "This meeting is in English.",
                      confidence: nil),
            ],
            engine: "test"
        )

        XCTAssertEqual(SummaryLanguage.resolvedForTranscript(.pt, transcript: transcript), .pt)
    }

    func testMatchTranscriptIsNotHijackedByOneForeignOpeningSegment() {
        let opening = Transcript.Segment(
            start: 0,
            end: 3,
            speaker: "me",
            text: "Das ist eine kurze fehlerhafte deutsche Transkription am Anfang.",
            confidence: nil)
        let english = [
            "We reviewed the launch plan and agreed to keep the rollout focused on reliability and customer feedback.",
            "The engineering team explained the architecture, accounting changes, and validation strategy for the next release.",
            "Everyone discussed the remaining tests, ownership, documentation, and the timeline for publishing the completed work.",
            "The meeting continued in English with detailed decisions, open questions, and concrete follow-up tasks for each participant.",
            "We closed by confirming the next milestone and scheduling another review after the implementation was ready.",
        ]
        let englishSegments: [Transcript.Segment] = (0..<20).map { index in
            let start = Double(index + 1) * 4
            return Transcript.Segment(
                start: start,
                end: start + 4,
                speaker: "them",
                text: english[index % english.count],
                confidence: nil)
        }
        let segments = [opening] + englishSegments
        let transcript = Transcript(segments: segments, engine: "test")

        XCTAssertEqual(
            SummaryLanguage.resolvedForTranscript(.matchTranscript, transcript: transcript),
            .en)
    }

    func testDistributedDetectionStillSelectsDominantGerman() {
        let transcript = Transcript(
            segments: (0..<12).map { index in
                .init(
                    start: Double(index) * 4,
                    end: Double(index + 1) * 4,
                    speaker: "them",
                    text: "Wir besprechen den Projektplan, die offenen Aufgaben und den Termin für die nächste Veröffentlichung.",
                    confidence: nil)
            },
            engine: "test")

        XCTAssertEqual(
            SummaryLanguage.resolvedForTranscript(.matchTranscript, transcript: transcript),
            .de)
    }
}

final class SummaryPromptActionabilityTests: XCTestCase {
    func testFixedLanguageTranslatesTextButKeepsSourceQuotesAndSections() {
        let prompt = PromptTemplates.meetingNotesSystem(template: .meeting, language: .de)
        XCTAssertTrue(prompt.contains("German"))
        XCTAssertTrue(prompt.contains("preserves source quotes in their original language"))
        XCTAssertTrue(prompt.contains("Keep section values and source IDs unchanged"))
    }

    func testEveryTemplateExtractsNotesAndActionsTogether() {
        for template in NoteTemplate.allCases {
            let prompt = PromptTemplates.meetingNotesSystem(template: template, language: .matchTranscript)
            XCTAssertTrue(prompt.contains("JSON containing notes, actions"), template.rawValue)
            XCTAssertTrue(prompt.contains("Only identity=user denotes the user"), template.rawValue)
            XCTAssertTrue(prompt.contains("Display names are aliases, not identity evidence"), template.rawValue)
            XCTAssertFalse(prompt.contains("Action items are extracted separately"), template.rawValue)
            XCTAssertTrue(prompt.contains("Text must NEVER contain speaker IDs"), template.rawValue)
        }
    }

    func testMeetingPromptPreservesTentativeTermsAndOneRolePerOutcome() {
        let prompt = PromptTemplates.meetingNotesSystem(template: .meeting, language: .matchTranscript)
        for rule in ["explicitly settled", "Tentative", "never duplicate", "Open questions",
                     "A request is not", "exact ownership quote"] {
            XCTAssertTrue(prompt.contains(rule), rule)
        }
    }
}
