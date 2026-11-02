import AppKit
import XCTest
@testable import LokalBot

/// The caret found from a field's text on screen, for Chrome text areas that
/// report no caret position. Global Cocoa coordinates (y up).
final class CotypingVisualCaretTests: XCTestCase {
    private typealias Locator = CotypingVisualCaretLocator
    /// A GitHub comment box: 797×103 with 14 pt text inset 13 pt.
    private let field = CGRect(x: 1170, y: 300, width: 797, height: 103)

    /// A line as recognition reports it: from where the ink of its first
    /// letter starts to where the ink of its last one ends, for text drawn
    /// from `origin`.
    private func line(_ text: String, minX origin: CGFloat = 1183, baseline: CGFloat, size: CGFloat = 14) -> Locator.RecognizedLine {
        let font = NSFont.systemFont(ofSize: size)
        let width = CotypingInlineGhostLayout.width(of: text, font: font)
        let ink = CTLineGetImageBounds(CTLineCreateWithAttributedString(NSAttributedString(
            string: text, attributes: [.font: font])), nil)
        return Locator.RecognizedLine(
            text: text, minX: origin + ink.minX, maxX: origin + ink.maxX, baseline: baseline,
            box: CGRect(x: origin, y: baseline - 3, width: width, height: 13))
    }

    /// Where the caret is after `text` drawn from `origin`: where its last
    /// letter's advance ends.
    private func end(of text: String, from origin: CGFloat = 1183, size: CGFloat = 14) -> CGFloat {
        origin + CotypingInlineGhostLayout.width(of: text, font: .systemFont(ofSize: size))
    }

    func testTheCaretIsAtTheEndOfTheLineThatEndsTheTypedText() throws {
        let first = line("Thanks for the quick review, I will push the fixes", baseline: 375)
        let second = line("in a follow-up later", baseline: 354)
        let found = try XCTUnwrap(Locator.locate(
            lines: [first, second],
            precedingText: "Thanks for the quick review, I will push the fixes in a follow-up later",
            fieldFrame: field))
        XCTAssertEqual(found.caretX, end(of: "in a follow-up later"), accuracy: 0.05)
        XCTAssertEqual(found.baseline, 354)
        XCTAssertEqual(found.pointSize, 14, accuracy: 0.05)
        XCTAssertEqual(found.lineMinX, second.minX)
        XCTAssertEqual(found.lineMaxX, field.maxX - (second.minX - field.minX), accuracy: 0.01)
    }

    /// Recognition ends a line where its last letter's ink ends; the caret is
    /// that letter's side bearing further on. Taking the ink's end put the
    /// ghost 0.6–0.8 pt over the last letter (measured 2026-10-09).
    func testTheCaretFollowsTheLastLettersAdvanceNotItsInk() throws {
        let recognized = line("Looks good", baseline: 375)
        let found = try XCTUnwrap(Locator.locate(lines: [recognized], precedingText: "Looks good", fieldFrame: field))
        XCTAssertGreaterThan(found.caretX, recognized.maxX + 0.3)
        XCTAssertEqual(found.caretX, end(of: "Looks good"), accuracy: 0.05)
    }

    func testATypedSpaceMovesTheCaretOneSpacePastTheLastLetter() throws {
        let typed = line("Looks good, just a", baseline: 375)
        let found = try XCTUnwrap(Locator.locate(lines: [typed], precedingText: "Looks good, just a ", fieldFrame: field))
        XCTAssertEqual(found.caretX, end(of: "Looks good, just a "), accuracy: 0.05)
    }

    /// Viber's caret is a bar that recognition reads as "|" (2026-10-09). The
    /// caret is where that bar is drawn, already past the space typed before
    /// it; adding the space again put the ghost a space too far right.
    func testTheAppsCaretReadAsABarIsTheCaret() throws {
        func withCaret(_ text: String, recognizedAs reading: String, caretAt caretX: CGFloat) -> Locator.RecognizedLine {
            var recognized = line(text, baseline: 375)
            recognized.text = reading
            recognized.characterBeforeLastMaxX = recognized.maxX
            recognized.lastCharacterMinX = caretX - 0.7
            recognized.maxX = caretX + 0.7
            return recognized
        }
        let afterSpace = end(of: "Looks good, just a ")
        let spaced = try XCTUnwrap(Locator.locate(
            lines: [withCaret("Looks good, just a", recognizedAs: "Looks good, just a |", caretAt: afterSpace)],
            precedingText: "Looks good, just a ", fieldFrame: field))
        XCTAssertEqual(spaced.caretX, afterSpace, accuracy: 0.05)
        XCTAssertEqual(spaced.pointSize, 14, accuracy: 0.05)

        let afterWord = end(of: "Looks good, just to")
        let joined = try XCTUnwrap(Locator.locate(
            lines: [withCaret("Looks good, just to", recognizedAs: "Looks good, just tol", caretAt: afterWord)],
            precedingText: "Looks good, just to", fieldFrame: field))
        XCTAssertEqual(joined.caretX, afterWord, accuracy: 0.05)

        // A word that really ends in "l" is text, not a caret.
        let stol = line("Looks good, the stol", baseline: 375)
        let typedL = try XCTUnwrap(Locator.locate(
            lines: [{ var l = stol; l.lastCharacterMinX = l.maxX - 2; l.characterBeforeLastMaxX = l.maxX - 3; return l }()],
            precedingText: "Looks good, the stol", fieldFrame: field))
        XCTAssertEqual(typedL.caretX, end(of: "Looks good, the stol"), accuracy: 0.05)
    }

    func testSmallRecognitionMistakesStillMatch() {
        let recognized = line("Looks g0od, just a few rninor things", baseline: 375)
        XCTAssertNotNil(Locator.locate(
            lines: [recognized], precedingText: "Looks good, just a few minor things", fieldFrame: field))
    }

    func testOtherTextOnScreenIsNotTakenForTheCaretsLine() {
        let unrelated = line("Paste, drop, or click to add files", baseline: 375)
        XCTAssertNil(Locator.locate(
            lines: [unrelated], precedingText: "Looks good, just a few minor things", fieldFrame: field))
        // A line that holds more than the paragraph has text after the caret.
        let longer = line("Looks good, just a few minor things and more after it", baseline: 375)
        XCTAssertNil(Locator.locate(lines: [longer], precedingText: "Looks good, just a", fieldFrame: field))
    }

    func testAnEmptyNewLineHasNothingToFind() {
        let previous = line("Looks good", baseline: 375)
        XCTAssertNil(Locator.locate(lines: [previous], precedingText: "Looks good\n", fieldFrame: field))
        XCTAssertNil(Locator.locate(lines: [previous], precedingText: "Looks good\na", fieldFrame: field))
        // Too little on the caret's line to be found: not looked for at all.
        XCTAssertFalse(Locator.hasEnoughText("Looks good\nab"))
        XCTAssertFalse(Locator.hasEnoughText("Looks good\nab   "))
        XCTAssertTrue(Locator.hasEnoughText("Looks good\nabc"))
    }

    func testTypingMovesTheCaretAlongItsLineUntilTheLineEnds() throws {
        let found = try XCTUnwrap(Locator.locate(
            lines: [line("Looks good", baseline: 375)], precedingText: "Looks good", fieldFrame: field))
        let font = NSFont.systemFont(ofSize: found.pointSize)
        XCTAssertEqual(Locator.caretX(for: found, precedingText: "Looks good"), found.caretX)
        XCTAssertEqual(
            try XCTUnwrap(Locator.caretX(for: found, precedingText: "Looks good, just")),
            found.caretX + CotypingInlineGhostLayout.width(of: ", just", font: font), accuracy: 0.01)
        XCTAssertEqual(
            try XCTUnwrap(Locator.caretX(for: found, precedingText: "Looks go")),
            found.caretX - CotypingInlineGhostLayout.width(of: "od", font: font), accuracy: 0.01)
        // A line break, a long way from where the caret was found, or other
        // text: look again.
        XCTAssertNil(Locator.caretX(for: found, precedingText: "Looks good\n"))
        XCTAssertNil(Locator.caretX(for: found, precedingText: "Looks good" + String(repeating: " more", count: 9)))
        XCTAssertNil(Locator.caretX(for: found, precedingText: "Something else entirely"))
        // A word past the field's edge wraps onto the next line.
        let narrow = CGRect(x: 1170, y: 300, width: 160, height: 60)
        let short = try XCTUnwrap(Locator.locate(
            lines: [line("Looks good", baseline: 340)], precedingText: "Looks good", fieldFrame: narrow))
        XCTAssertNotNil(Locator.caretX(for: short, precedingText: "Looks good, ok"))
        XCTAssertNil(Locator.caretX(for: short, precedingText: "Looks good, just wonderful"))
    }

    /// A capture can be a frame behind the typing, and recognition can miss
    /// a final full stop. Taking the end of what was recognized for the
    /// caret put the ghost over the last letters typed.
    func testACaptureThatLacksTheLastLettersStillPutsTheCaretAfterThem() throws {
        let behind = line("Looks goo", baseline: 375)
        let found = try XCTUnwrap(Locator.locate(lines: [behind], precedingText: "Looks good", fieldFrame: field))
        XCTAssertEqual(found.caretX, end(of: "Looks good"), accuracy: 0.1)
        XCTAssertEqual(found.precedingText, "Looks good")

        let noStop = line("Thanks, see you tomorrow", baseline: 375)
        let stopped = try XCTUnwrap(Locator.locate(
            lines: [noStop], precedingText: "Thanks, see you tomorrow. ", fieldFrame: field))
        XCTAssertEqual(stopped.caretX, end(of: "Thanks, see you tomorrow. "), accuracy: 0.1)
        // A line that shows everything is taken as it is.
        let whole = line("Looks good", baseline: 375)
        XCTAssertEqual(
            try XCTUnwrap(Locator.locate(lines: [whole], precedingText: "Looks good", fieldFrame: field)).caretX,
            end(of: "Looks good"), accuracy: 0.05)
    }

    /// The 2026-10-09 report from Viber: after "Ima i dalje preklapanja te"
    /// the ghost "lefonskih brojeva, ali" began a letter or two early, over
    /// "te". Recognition had returned the line without its short last word,
    /// which still matched well enough, and the caret was put at the end of
    /// what was recognized.
    func testALineWithoutItsLastWordPutsTheCaretAfterThatWord() throws {
        let typed = "Ima i dalje preklapanja te"
        let recognized = line("Ima i dalje preklapanja", baseline: 375)
        let found = try XCTUnwrap(Locator.locate(lines: [recognized], precedingText: typed, fieldFrame: field))
        XCTAssertEqual(found.caretX, end(of: typed), accuracy: 0.1)

        // Recognition split the row in two: the longer piece sizes the font.
        let start = line("Ima i dalje preklapanja", baseline: 375)
        let lastWord = line("te", minX: end(of: "Ima i dalje preklapanja "), baseline: 375)
        let split = try XCTUnwrap(Locator.locate(lines: [lastWord, start], precedingText: typed, fieldFrame: field))
        XCTAssertEqual(split.caretX, end(of: typed), accuracy: 0.5)
        XCTAssertEqual(split.pointSize, 14, accuracy: 0.05)

        // Unseen words that would pass the end of the line went to the next one.
        let narrow = CGRect(x: 1170, y: 300, width: 160, height: 60)
        XCTAssertNil(Locator.locate(
            lines: [line("Looks good, okay", baseline: 340)], precedingText: "Looks good, okay then", fieldFrame: narrow))
    }

    /// Measured in Viber on 2026-10-09: at LokalBot's 2× capture, recognition
    /// read "bolje ali i dalje nije" as "bolJe all I dalJe nlJe". Sizing the
    /// font from that text made it 12.8 pt instead of 13.5 pt, so every
    /// letter typed afterwards put the ghost a little further behind the
    /// caret; after "uvS" it began over the "S".
    func testTheFontIsSizedFromTheTypedTextNotTheMisreadOne() throws {
        let typed = "Sad je sve puno bolje ali i dalje nije skroz kako treba uvS"
        let viberField = CGRect(x: 2561, y: 180, width: 499, height: 17)
        var misread = line(typed, minX: 2561.5, baseline: 184, size: 13.5)
        misread.text = "Sad Je sve puno bolJe all I dalJe nlJe skroz kako treba uvS"
        let found = try XCTUnwrap(Locator.locate(lines: [misread], precedingText: typed, fieldFrame: viberField))
        XCTAssertEqual(found.pointSize, 13.5, accuracy: 0.05)
        let next = try XCTUnwrap(Locator.caretX(for: found, precedingText: typed + " te lefonskih"))
        XCTAssertEqual(next, end(of: typed + " te lefonskih", from: 2561.5, size: 13.5), accuracy: 0.3)
    }

    /// Fast recognition often drops accents, as on Serbian text.
    func testAccentsDoNotStopAMatch() throws {
        let recognized = line("Vidimo se sutra, hvala sto", baseline: 375)
        let found = try XCTUnwrap(Locator.locate(
            lines: [recognized], precedingText: "Vidimo se sutra, hvala što", fieldFrame: field))
        XCTAssertEqual(found.caretX, end(of: "Vidimo se sutra, hvala sto"), accuracy: 0.05)
        XCTAssertEqual(Locator.normalized("  Šta  ćeš\u{00A0}raditi “Đoko” — "), "sta ces raditi \"đoko\" -")
    }

    /// The field's right text edge is only estimated, so a word typed close
    /// to it may already be on the next line. Following the caret along the
    /// line put the ghost on the line above, and its wrapped words on the
    /// word just typed. Spaces never wrap.
    func testLettersTypedNearTheLineEndAreFoundAgain() throws {
        let narrow = CGRect(x: 1170, y: 300, width: 160, height: 60)
        let short = try XCTUnwrap(Locator.locate(
            lines: [line("Looks good", baseline: 340)], precedingText: "Looks good", fieldFrame: narrow))
        XCTAssertNotNil(Locator.caretX(for: short, precedingText: "Looks good, okay"))
        XCTAssertNil(Locator.caretX(for: short, precedingText: "Looks good, ok then"))

        let full = try XCTUnwrap(Locator.locate(
            lines: [line("Looks good, okay", baseline: 340)], precedingText: "Looks good, okay", fieldFrame: narrow))
        XCTAssertNotNil(Locator.caretX(for: full, precedingText: "Looks good, okay  "))
        XCTAssertNil(Locator.caretX(for: full, precedingText: "Looks good, okay t"))
    }

    /// Deleting back into the first word of a wrapped line can let that
    /// word fit on the line above again.
    func testDeletingIntoTheFirstWordOfAWrappedLineIsFoundAgain() throws {
        let first = "Thanks for the quick review, I will push the fixes"
        let found = try XCTUnwrap(Locator.locate(
            lines: [line(first, baseline: 375), line("in a follow-up later", baseline: 354)],
            precedingText: first + " in a follow-up later", fieldFrame: field))
        XCTAssertNotNil(Locator.caretX(for: found, precedingText: first + " in a "))
        XCTAssertNil(Locator.caretX(for: found, precedingText: first + " i"))
        // A paragraph's first line has no line above to go back to.
        let single = try XCTUnwrap(Locator.locate(
            lines: [line("Looks good", baseline: 375)], precedingText: "Looks good", fieldFrame: field))
        XCTAssertNil(single.firstWordEndX)
        XCTAssertNotNil(Locator.caretX(for: single, precedingText: "Lo"))
    }

    /// A field whose caret is found on screen waits for it instead of a
    /// popup outside the field, unless finds there keep failing.
    @MainActor
    func testAFieldWhoseCaretIsFoundOnScreenIsKnown() {
        let visualCaret = CotypingVisualCaret()
        var viber = CotypingField(
            appName: "Viber", bundleID: "com.viber.osx", processID: 7, role: "AXTextField",
            precedingText: "Hey, are we", trailingText: "", selectionLength: 0,
            caretRect: CGRect(x: 2565, y: 180, width: 1, height: 17), inputFrameRect: CGRect(x: 2561, y: 180, width: 499, height: 17),
            isSecure: false, caretIsExact: false)
        XCTAssertFalse(visualCaret.canFind(viber, screenCaptureAllowed: { true }), "privacy not checked yet")
        visualCaret.notePermission(false, for: viber)
        XCTAssertFalse(visualCaret.canFind(viber, screenCaptureAllowed: { true }))
        visualCaret.notePermission(true, for: viber)
        XCTAssertTrue(visualCaret.canFind(viber, screenCaptureAllowed: { true }))
        XCTAssertFalse(visualCaret.canFind(viber, screenCaptureAllowed: { false }), "no Screen Recording")
        var midLine = viber
        midLine.trailingText = " later"
        XCTAssertFalse(visualCaret.canFind(midLine, screenCaptureAllowed: { true }))
        for _ in 0..<CotypingVisualCaretLocator.maximumFailedFinds { visualCaret.noteFailedFind(for: viber) }
        XCTAssertFalse(visualCaret.canFind(viber, screenCaptureAllowed: { true }), "finds keep failing")
        // Another field starts afresh, and a find that works clears the count.
        viber.inputFrameRect = CGRect(x: 2561, y: 180, width: 499, height: 34)
        XCTAssertTrue(visualCaret.canFind(viber, screenCaptureAllowed: { true }))
    }

    func testTypingIsFollowedWhenOnlyTheNewestTextIsKept() throws {
        let old = String(repeating: "a", count: 10) + " the earlier part of a long draft that keeps going"
        let new = String(old.dropFirst(3)) + " on"
        let change = try XCTUnwrap(Locator.change(from: old, to: new))
        XCTAssertEqual(change.text, " on")
        XCTAssertTrue(change.isAddition)
        let back = try XCTUnwrap(Locator.change(from: new, to: String(new.dropLast(2))))
        XCTAssertEqual(back.text, "on")
        XCTAssertFalse(back.isAddition)
    }

    /// The rect handed to the overlay puts the ghost's baseline on the line
    /// found, whichever way the overlay reads it.
    func testTheGhostIsDrawnOnTheBaselineFound() throws {
        let found = try XCTUnwrap(Locator.locate(
            lines: [line("Looks good, just a", baseline: 375)], precedingText: "Looks good, just a ", fieldFrame: field))
        let caret = Locator.caretRect(for: found, caretX: found.caretX)
        let font = CotypingGhostFontSizing.font(for: nil, caretHeight: caret.height, caretIsExact: true)
        XCTAssertEqual(font.pointSize, found.pointSize, accuracy: 0.3)
        XCTAssertEqual(CotypingInlineGhostLayout.firstBaseline(caretRect: caret, font: font), 375, accuracy: 0.5)
        // Also in the field's own font, when the field reports it.
        let reported = NSFont.systemFont(ofSize: 14)
        XCTAssertEqual(CotypingInlineGhostLayout.firstBaseline(caretRect: caret, font: reported), 375, accuracy: 0.5)
    }

    func testCaptureFollowsTheScreenCaptureExclusions() {
        func permits(app: String = "Google Chrome", bundle: String? = "com.google.Chrome", host: String? = nil,
                     secure: Bool = false, apps: [String] = [], domains: [String] = []) -> Bool {
            Locator.permitsCapture(appName: app, bundleID: bundle, host: host, isSecure: secure,
                                   excludedApps: apps, excludedDomains: domains)
        }
        XCTAssertTrue(permits())
        XCTAssertFalse(permits(secure: true))
        XCTAssertFalse(permits(apps: ["Google Chrome"]))
        // With a site excluded, a page must be known to be another site.
        XCTAssertFalse(permits(domains: ["bank.example"]))
        XCTAssertFalse(permits(host: "bank.example", domains: ["bank.example"]))
        XCTAssertTrue(permits(host: "github.com", domains: ["bank.example"]))
        XCTAssertTrue(permits(app: "TextEdit", bundle: "com.apple.TextEdit", domains: ["bank.example"]))
    }

    /// Chrome hands out a new element for the same field on every read; the
    /// caret found for it still applies, so it is not looked for again.
    @MainActor
    func testTheCaretFoundIsReusedWhenChromeHandsOutANewElement() throws {
        func chromeField(_ identity: String, text: String) -> CotypingField {
            CotypingField(
                appName: "Google Chrome", bundleID: "com.google.Chrome", processID: 42, role: "AXTextArea",
                focusIdentityKey: identity, precedingText: text, trailingText: "", selectionLength: 0,
                caretRect: CGRect(x: 1174, y: 381, width: 1, height: 22), inputFrameRect: self.field,
                isSecure: false, caretIsExact: false)
        }
        let found = try XCTUnwrap(Locator.locate(
            lines: [line("Looks good", baseline: 375)], precedingText: "Looks good", fieldFrame: self.field))
        let visualCaret = CotypingVisualCaret()
        visualCaret.remember(found, for: chromeField("element-1", text: "Looks good"))

        let next = visualCaret.resolve(chromeField("element-2", text: "Looks good, just"))
        XCTAssertTrue(next.caretIsExact)
        XCTAssertGreaterThan(next.caretRect.minX, found.caretX)
        XCTAssertEqual(next.fieldStyle?.fontPointSize, found.pointSize,
                       "the ghost is drawn at the size the caret moves by")
        // Another field of the same kind elsewhere: not reused.
        var moved = chromeField("element-3", text: "Looks good")
        moved.inputFrameRect = self.field.offsetBy(dx: 0, dy: -200)
        XCTAssertFalse(visualCaret.resolve(moved).caretIsExact)
    }

    /// Measured at 1x on 2026-11-02: fast recognition cannot read "č", "ž" or
    /// "đ". Capitals with them came back as other characters, so a short
    /// Serbian message never matched and the suggestion went to a popup.
    func testLettersRecognitionCannotReadDoNotStopAMatch() throws {
        for (reading, typed) in [
            ("&kam te ispred", "Čekam te ispred"),
            ("2ao mi je", "Žao mi je"),
            ("E)orde je dosao kuci", "Đorđe je došao kući"),
            ("tso, sta ima", "Ćao, šta ima"),
            ("setir curetina", "šećer ćuretina"),
        ] {
            let found = try XCTUnwrap(Locator.locate(
                lines: [line(reading, baseline: 375)], precedingText: typed, fieldFrame: field), reading)
            XCTAssertEqual(found.caretX, line(reading, baseline: 375).maxX, accuracy: 3, reading)
        }
        // Without such letters the same mistakes still rule a line out.
        XCTAssertNil(Locator.locate(
            lines: [line("&kam xx 1spxxd", baseline: 375)], precedingText: "Pekam te ispred", fieldFrame: field))
    }

    /// Recognition ran these words together. Counting the spaces it lost took
    /// the line for the end of a longer paragraph, and sized the font from
    /// part of the text: 21 pt for 13.5 pt text.
    func testWordsRunTogetherStillMatchAndMeasureTheWholeLine() throws {
        let typed = "Thanks for the quick reply to me"
        var together = line(typed, baseline: 375)
        together.text = "Thanksforthequickreplytome"
        let found = try XCTUnwrap(Locator.locate(lines: [together], precedingText: typed, fieldFrame: field))
        XCTAssertEqual(found.pointSize, 14, accuracy: 0.05)
        XCTAssertEqual(found.caretX, end(of: typed), accuracy: 0.05)
        XCTAssertTrue(found.sizeIsReliable)
        XCTAssertNil(found.firstWordEndX, "it is the paragraph's first line")
    }

    /// "Šta ćeš da radiš večeras" came back as "a ces da radis veceras". All
    /// of the typed text was then fitted to a line without its first letters.
    func testALineMissingItsFirstLettersStillMeasuresTheFont() throws {
        let typed = "Šta ćeš da radiš večeras"
        let origin = end(of: "Št")
        var recognized = line("a ćeš da radiš večeras", minX: origin, baseline: 375)
        recognized.text = "a ces da radis veceras"
        recognized.tailMinX = end(of: "Šta ć", from: 1183)
        let found = try XCTUnwrap(Locator.locate(lines: [recognized], precedingText: typed, fieldFrame: field))
        XCTAssertEqual(found.pointSize, 14, accuracy: 0.5)
        XCTAssertEqual(found.caretX, end(of: typed), accuracy: 1)
        XCTAssertFalse(found.sizeIsReliable, "the counts differ")
        XCTAssertNil(found.textStartX, "where the line starts is not known")

        // Too short to measure past its start: fitting all of the typed text
        // to it would be far smaller than text in a field.
        var short = line("a c", minX: origin, baseline: 375)
        short.box.size.height = 13
        let few = try XCTUnwrap(Locator.locate(lines: [short], precedingText: "Šta c", fieldFrame: field))
        XCTAssertEqual(few.pointSize, 14, accuracy: 1)
    }

    /// Fitting all of "Čekam" to what is read as "&kam" is right: "&" stands
    /// for two letters. Measuring only the letters that line up gave 18 pt.
    func testAShortLineThatReadsTwoLettersAsOneIsMeasuredWhole() throws {
        var recognized = line("Čekam", baseline: 375)
        recognized.text = "&kam"
        let found = try XCTUnwrap(Locator.locate(lines: [recognized], precedingText: "Čekam", fieldFrame: field))
        XCTAssertEqual(found.pointSize, 14, accuracy: 0.05)
    }

    /// Other scripts are not excused: any line of the right length would pass.
    func testOtherScriptsAreNotMatchedOnLengthAlone() {
        XCTAssertNil(Locator.locate(
            lines: [line("Paste files", baseline: 375)], precedingText: "Чекам те овдје", fieldFrame: field))
    }

    /// One size for one field. It changed from find to find with how much of
    /// the line recognition could read, and the caret moves by it.
    @MainActor
    func testAFontMeasuredFromAWholeLineOutlastsFindsThatCouldNot() throws {
        let visualCaret = CotypingVisualCaret()
        let typed = "Dobro je, vidimo se"
        let whole = try XCTUnwrap(Locator.locate(
            lines: [line(typed, baseline: 375)], precedingText: typed, fieldFrame: field))
        XCTAssertTrue(whole.sizeIsReliable)
        visualCaret.remember(whole, for: viberField(typed))

        var poor = whole
        poor.precedingText = typed + " sutra"
        poor.caretX += 30
        poor.pointSize = 18
        poor.sizeIsReliable = false
        visualCaret.remember(poor, for: viberField(poor.precedingText))
        let resolved = visualCaret.resolve(viberField(poor.precedingText))
        XCTAssertEqual(try XCTUnwrap(resolved.fieldStyle?.fontPointSize), 14, accuracy: 0.05)
        XCTAssertEqual(resolved.caretRect.minX, poor.caretX, accuracy: 0.01, "its caret is still used")
    }

    /// The next message after one was sent: no text to follow on from, and
    /// too few letters to find, yet the field's first line is known.
    @MainActor
    func testANewMessageStartsWhereTheFieldsFirstLineStarts() throws {
        let visualCaret = CotypingVisualCaret()
        let typed = "Dobro je, vidimo se"
        let whole = try XCTUnwrap(Locator.locate(
            lines: [line(typed, baseline: 375)], precedingText: typed, fieldFrame: field))
        visualCaret.remember(whole, for: viberField(typed))

        let next = visualCaret.resolve(viberField("Ćao"))
        XCTAssertTrue(next.caretIsExact)
        XCTAssertEqual(next.caretRect.minX, end(of: "Ćao"), accuracy: 0.6)
        // On a line of its own, or once it would wrap, its place is not known.
        XCTAssertFalse(visualCaret.resolve(viberField("Ćao\nkako si")).caretIsExact)
        XCTAssertFalse(visualCaret.resolve(viberField(String(repeating: "dugacka poruka ", count: 12))).caretIsExact)
        // Nor in a field of another size, which may hold another font.
        var taller = viberField("Ćao")
        taller.inputFrameRect = field.insetBy(dx: 0, dy: -10)
        XCTAssertFalse(visualCaret.resolve(taller).caretIsExact)
        // A line that wrapped from the one before says nothing about the first.
        let first = "Thanks for the quick review, I will push the fixes"
        let wrapped = try XCTUnwrap(Locator.locate(
            lines: [line(first, baseline: 375), line("in a follow-up later", baseline: 354)],
            precedingText: first + " in a follow-up later", fieldFrame: field))
        XCTAssertNil(wrapped.textStartX)
    }

    @MainActor
    func testTheCaretIsMeasuredAgainSoonerUntilTheFontIsKnown() throws {
        let visualCaret = CotypingVisualCaret()
        XCTAssertTrue(visualCaret.isDueForAFind(viberField("Dobro")), "nothing found yet")

        let short = try XCTUnwrap(Locator.locate(
            lines: [line("Dobro", baseline: 375)], precedingText: "Dobro", fieldFrame: field))
        XCTAssertFalse(short.sizeIsReliable, "too short to measure")
        visualCaret.remember(short, for: viberField("Dobro"))
        XCTAssertFalse(visualCaret.isDueForAFind(viberField("Dobro j")))
        XCTAssertTrue(visualCaret.isDueForAFind(viberField("Dobro je, ")))

        let typed = "Dobro je, vidimo se"
        let whole = try XCTUnwrap(Locator.locate(
            lines: [line(typed, baseline: 375)], precedingText: typed, fieldFrame: field))
        visualCaret.remember(whole, for: viberField(typed))
        XCTAssertFalse(visualCaret.isDueForAFind(viberField(typed + " sutra u")))
        XCTAssertTrue(visualCaret.isDueForAFind(viberField(typed + " sutra u gradu")))
    }

    func testAMissOnAFewLettersSaysNothingAboutTheField() {
        XCTAssertFalse(Locator.missCounts(for: "Ćao"))
        XCTAssertFalse(Locator.missCounts(for: "Ćao ti\nŠta"))
        XCTAssertTrue(Locator.missCounts(for: "Ćao, šta ima"))
    }

    private func viberField(_ text: String) -> CotypingField {
        CotypingField(
            appName: "Viber", bundleID: "com.viber.osx", processID: 7, role: "AXTextField",
            precedingText: text, trailingText: "", selectionLength: 0,
            caretRect: CGRect(x: 1174, y: 381, width: 1, height: 22), inputFrameRect: field,
            isSecure: false, caretIsExact: false)
    }

    /// On a non-Retina display the capture is scaled up to three times its
    /// point size, not left at its own pixels in a corner of a larger image;
    /// at two times recognition misread Viber's "je" as "Je" throughout.
    /// A field too big for that is captured at two times.
    func testTheCaptureIsScaledUpOnANonRetinaDisplay() {
        let display = CGRect(x: 0, y: 0, width: 3440, height: 1440)
        let config = CotypingVisualCaret.captureConfiguration(
            for: CGRect(x: 725, y: 279, width: 796, height: 103), screenFrame: display, backingScale: 1)
        XCTAssertTrue(config.scalesToFit)
        XCTAssertEqual(config.width, 2388)
        XCTAssertEqual(config.height, 309)
        XCTAssertEqual(config.sourceRect, CGRect(x: 725, y: 1058, width: 796, height: 103))
        let page = CotypingVisualCaret.captureConfiguration(
            for: CGRect(x: 100, y: 100, width: 2000, height: 800), screenFrame: display, backingScale: 1)
        XCTAssertEqual(page.width, 4000)
        let retina = CotypingVisualCaret.captureConfiguration(
            for: CGRect(x: -1500, y: -900, width: 400, height: 50),
            screenFrame: CGRect(x: -1728, y: -1117, width: 1728, height: 1117), backingScale: 2)
        XCTAssertEqual(retina.width, 800)
        XCTAssertEqual(retina.sourceRect, CGRect(x: 228, y: 850, width: 400, height: 50))
    }

    /// Renders a field like GitHub's and runs the real recognizer on it.
    func testRecognitionFindsTheCaretInARenderedField() throws {
        let size = CGSize(width: 797, height: 103)
        let font = NSFont.systemFont(ofSize: 14)
        let lines = ["Thanks for the quick review, I will push the fixes", "in a follow-up later today"]
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        var baselines: [CGFloat] = []
        for (index, text) in lines.enumerated() {
            let baseline = size.height - 12 - 21 * CGFloat(index) - 3.3 - font.ascender
            baselines.append(baseline)
            NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor(white: 0.12, alpha: 1)])
                .draw(at: CGPoint(x: 13, y: baseline + font.descender))
        }
        NSGraphicsContext.restoreGraphicsState()
        let image = try XCTUnwrap(rep.cgImage)

        let recognized = CotypingVisualCaret.recognize(image, frame: field)
        let found = try XCTUnwrap(Locator.locate(
            lines: recognized, precedingText: lines.joined(separator: " "), fieldFrame: field))
        let lastLineEnd = field.minX + 13 + CotypingInlineGhostLayout.width(of: lines[1], font: font)
        XCTAssertEqual(found.caretX, lastLineEnd, accuracy: 1.5)
        XCTAssertEqual(found.baseline, field.minY + baselines[1], accuracy: 1)
        XCTAssertEqual(found.pointSize, 14, accuracy: 0.7)
    }

    // MARK: - Cyrillic

    /// A Cyrillic line as measured from its pixels and read by accurate recognition.
    private func measuredLine(
        _ typed: String, read: String? = nil, caretAt caretX: CGFloat? = nil, baseline: CGFloat = 375, size: CGFloat = 14
    ) -> Locator.RecognizedLine {
        var measured = line(typed, baseline: baseline, size: size)
        measured.edgesAreMeasured = true
        measured.text = read ?? typed
        if let caretX {
            measured.text += "|"
            measured.characterBeforeLastMaxX = measured.maxX
            measured.lastCharacterMinX = caretX - 0.5
            measured.maxX = caretX + 0.5
        }
        return measured
    }

    func testOnlyACaretLineInCyrillicIsReadAsCyrillic() {
        XCTAssertTrue(Locator.caretLineIsCyrillic("Здраво"))
        XCTAssertTrue(Locator.caretLineIsCyrillic("Hello\nЗдраво"))
        XCTAssertTrue(Locator.caretLineIsCyrillic("Погледај PR 422"))
        XCTAssertFalse(Locator.caretLineIsCyrillic("Čekam te, šta ćeš"))
        XCTAssertFalse(Locator.caretLineIsCyrillic("Здраво\nHello"))
    }

    /// Recognition mixes Latin letters into a word, as it does not know Serbian's.
    func testACyrillicLineMatchesHoweverItsLettersWereRead() throws {
        for (typed, read) in [
            ("Сегодня вечером будет", "Сегодня вечером будет"),
            ("Ђорђе је рекао", "Бophe je рекао"),
            ("Хвала вам на помоћи", "Хвaлa вам на пoмohи"),
            ("Љиљана је данас", "Льильана je данас"),
            ("Њима је љубав", "НБима je льубав")
        ] {
            let found = try XCTUnwrap(Locator.locate(
                lines: [measuredLine(typed, read: read)], precedingText: typed, fieldFrame: field), read)
            XCTAssertEqual(found.caretX, end(of: typed), accuracy: 0.05, read)
            XCTAssertTrue(found.sizeIsReliable, read)
            XCTAssertNotNil(found.textStartX, read)
        }
    }

    /// Other text of about the same length is not the typed text. Taking any
    /// Cyrillic line for it put the caret up to 24 pt off.
    func testACyrillicLineWithOtherTextDoesNotMatch() {
        for (typed, shown) in [
            ("Сегодня вечером будет", "Спасибо большое за по"),
            ("Здраво, стижем за пет", "Шта ћеш да радиш вечер"),
            ("Ђорђе је рекао да ће", "Сегодня вечером будет")
        ] {
            XCTAssertNil(Locator.locate(lines: [measuredLine(shown)], precedingText: typed, fieldFrame: field), shown)
        }
    }

    /// With one letter lost, the typed text looked a closer match ending a word
    /// earlier, so that word was added after the line's real end: 13 pt off.
    func testALetterLostFromAMeasuredLineDoesNotMoveTheCaretOn() throws {
        let typed = "Здраво, стижем за п"
        let found = try XCTUnwrap(Locator.locate(
            lines: [measuredLine(typed, read: "здраво, стижем з п")], precedingText: typed, fieldFrame: field))
        XCTAssertEqual(found.caretX, end(of: typed), accuracy: 0.05)
        XCTAssertEqual(found.pointSize, 14, accuracy: 0.05)
    }

    /// Recognition lost the last word, and the ink past what it read holds it:
    /// that word is on screen, so the caret does not move by it again.
    func testAWordLostInReadingIsNotAddedAfterTheInk() throws {
        let typed = "Видимо се у г"
        var read = measuredLine(typed, read: "Видимо се у")
        read.inkHasMoreWords = true
        let found = try XCTUnwrap(Locator.locate(lines: [read], precedingText: typed, fieldFrame: field))
        XCTAssertEqual(found.caretX, end(of: typed), accuracy: 0.05)
        XCTAssertEqual(found.pointSize, 14, accuracy: 0.05)
    }

    func testAMeasuredCaretIsWhereItIsDrawnWhenOneLetterReadsAsTwo() throws {
        let typed = "Да ли можеш да ми пошаљеш"
        let found = try XCTUnwrap(Locator.locate(
            lines: [measuredLine(typed, read: "Да ли можеш да ми пошальеш", caretAt: end(of: typed) + 0.5)],
            precedingText: typed, fieldFrame: field))
        XCTAssertEqual(found.caretX, end(of: typed) + 0.5, accuracy: 0.05)
    }

    /// The capture can be from before the last key, with the caret drawn where
    /// it was. Stale by a letter the caret was a letter behind, for four keys.
    func testAMeasuredCaretInAFrameFromBeforeTheLastKeyMovesOn() throws {
        let typed = "Привет, как дела"
        let shown = "Привет, как дел"
        let found = try XCTUnwrap(Locator.locate(
            lines: [measuredLine(shown, caretAt: end(of: shown))], precedingText: typed, fieldFrame: field))
        XCTAssertEqual(found.caretX, end(of: typed), accuracy: 0.6)
    }

    func testAMeasuredCaretTouchingTheLastLetterHasNotSeenASpaceTyped() throws {
        let word = "Привет, как"
        let spaced = word + " "
        let stale = try XCTUnwrap(Locator.locate(
            lines: [measuredLine(word, caretAt: end(of: word))], precedingText: spaced, fieldFrame: field))
        XCTAssertEqual(stale.caretX, end(of: spaced), accuracy: 0.6)
        let current = try XCTUnwrap(Locator.locate(
            lines: [measuredLine(word, caretAt: end(of: spaced))], precedingText: spaced, fieldFrame: field))
        XCTAssertEqual(current.caretX, end(of: spaced), accuracy: 0.05, "the space is not added twice")
    }

    /// Latin keeps the matching it had: a line read a letter short still counts
    /// as a line whose last word was missed.
    func testAFastRecognitionLineKeepsItsOwnMatching() throws {
        let typed = "Looks good, just a smal"
        let found = try XCTUnwrap(Locator.locate(
            lines: [line("Looks good, just a", baseline: 375)], precedingText: typed, fieldFrame: field))
        XCTAssertEqual(found.caretX, end(of: typed), accuracy: 1)
    }

    @MainActor
    func testACyrillicLineIsMeasuredAgainEveryFewLetters() throws {
        let visualCaret = CotypingVisualCaret()
        let typed = "Сегодня вечером"
        let whole = try XCTUnwrap(Locator.locate(
            lines: [measuredLine(typed)], precedingText: typed, fieldFrame: field))
        XCTAssertTrue(whole.sizeIsReliable)
        visualCaret.remember(whole, for: viberField(typed))
        XCTAssertFalse(visualCaret.isDueForAFind(viberField(typed + " бу")))
        XCTAssertTrue(visualCaret.isDueForAFind(viberField(typed + " буде")))
    }

    /// Runs the real recognizer on Cyrillic drawn at a display's own pixels and
    /// scaled up as the capture does: drawing directly at 3x hid the Serbian bug.
    /// With fast recognition, none of these has a line to match.
    func testRecognitionFindsTheCaretInRenderedCyrillic() throws {
        let frame = CGRect(x: 1170, y: 300, width: 640, height: 40)
        let font = try XCTUnwrap(NSFont(name: "HelveticaNeue", size: 13.5))
        let inset: CGFloat = 6, baseline: CGFloat = 16
        let messages = [
            "Сегодня вечером будет встреча", "Привет, как дела, увидимся завтра",
            "Здраво, стижем за пет минута", "Хвала вам на помоћи", "Ђорђе је рекао да ће доћи сутра",
            "Морам да завршим ово до петка "
        ]
        for scale in [CGFloat(1), 2] {
            for showsCaret in [false, true] {
                for typed in messages {
                    let caretX = inset + CotypingInlineGhostLayout.width(of: typed, font: font)
                    let image = try XCTUnwrap(Self.renderedField(
                        typed, font: font, size: frame.size, origin: CGPoint(x: inset, y: baseline),
                        displayScale: scale, captureScale: CotypingVisualCaret.captureScale(for: frame, backingScale: scale),
                        caretX: showsCaret ? caretX : nil))
                    let lines = CotypingVisualCaret.recognize(image, frame: frame, precedingText: typed)
                    let label = "\(typed) at \(scale)x, caret \(showsCaret)"
                    let found = try XCTUnwrap(Locator.locate(lines: lines, precedingText: typed, fieldFrame: frame), label)
                    XCTAssertEqual(found.caretX, frame.minX + caretX, accuracy: 2.5, label)
                    XCTAssertEqual(found.baseline, frame.minY + baseline, accuracy: 1, label)
                    XCTAssertEqual(found.pointSize, 13.5, accuracy: 1, label)
                }
            }
        }
    }

    /// One line of text drawn at the display's own pixels, then scaled up to
    /// what the capture asks for.
    private static func renderedField(
        _ text: String, font: NSFont, size: CGSize, origin: CGPoint,
        displayScale: CGFloat, captureScale: CGFloat, caretX: CGFloat?
    ) -> CGImage? {
        func bitmap(scale: CGFloat) -> CGContext? {
            CGContext(
                data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8,
                bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        }
        guard let display = bitmap(scale: displayScale) else { return nil }
        display.scaleBy(x: displayScale, y: displayScale)
        display.setFillColor(.white)
        display.fill(CGRect(origin: .zero, size: size))
        let ink = NSColor(white: 0.1, alpha: 1)
        display.textPosition = origin
        CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(
            string: text, attributes: [.font: font, .foregroundColor: ink])), display)
        if let caretX {
            display.setFillColor(ink.cgColor)
            display.fill(CGRect(x: caretX, y: origin.y + font.descender, width: 1, height: font.ascender - font.descender))
        }
        guard let drawn = display.makeImage() else { return nil }
        guard captureScale != displayScale else { return drawn }
        guard let capture = bitmap(scale: captureScale) else { return nil }
        capture.interpolationQuality = .high
        capture.draw(drawn, in: CGRect(x: 0, y: 0, width: capture.width, height: capture.height))
        return capture.makeImage()
    }

    // MARK: - Waiting for a find

    /// A finished suggestion waits at most its budget for the caret, then is
    /// shown beside the field. The slow find is left running for next time.
    func testTheWaitForASlowFindEndsAtItsDeadline() async {
        let find = Task { _ = try? await Task.sleep(for: .seconds(5)) }
        defer { find.cancel() }
        let start = ContinuousClock.now
        await CotypingBoundedWait.wait(for: find, milliseconds: 50)
        XCTAssertLessThan(start.duration(to: .now), .seconds(2))
        XCTAssertFalse(find.isCancelled, "only the wait ends; the find keeps running")
    }

    func testAFindThatFinishesFirstEndsTheWaitAtOnce() async {
        let find = Task { _ = try? await Task.sleep(for: .milliseconds(10)) }
        let start = ContinuousClock.now
        await CotypingBoundedWait.wait(for: find, milliseconds: 5_000)
        XCTAssertLessThan(start.duration(to: .now), .seconds(2))
    }

    func testCancellingTheWaiterEndsTheWait() async {
        let find = Task { _ = try? await Task.sleep(for: .seconds(5)) }
        defer { find.cancel() }
        let start = ContinuousClock.now
        let waiter = Task { await CotypingBoundedWait.wait(for: find, milliseconds: 5_000) }
        waiter.cancel()
        await waiter.value
        XCTAssertLessThan(start.duration(to: .now), .seconds(2))
    }

    @MainActor
    func testWithNoFindRunningThereIsNothingToWaitFor() async {
        let start = ContinuousClock.now
        await CotypingVisualCaret().waitForPending(milliseconds: 5_000)
        XCTAssertLessThan(start.duration(to: .now), .seconds(2))
    }
}
