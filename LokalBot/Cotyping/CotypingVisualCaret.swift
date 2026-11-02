import AppKit
import ScreenCaptureKit
import Vision

/// Finds the caret from the field's own text as it appears on screen, for
/// fields whose app reports no caret position through Accessibility.
///
/// Chrome's text areas are the case that needs it. In a GitHub comment box
/// every range and text-marker query answered an empty box at the page's
/// corner, with Chrome's text metrics and screen-reader mode on or off
/// (measured 2026-10-05), so a suggestion could only be shown beside the
/// field. Recognizing the line that ends at the caret puts it back on the
/// line being typed. Pure geometry over plain values, so it is unit-testable
/// without the screen.
nonisolated enum CotypingVisualCaretLocator {
    /// One line of text recognized on screen. Global Cocoa coordinates.
    struct RecognizedLine: Equatable {
        var text: String
        /// Leading edge of its first character and trailing edge of its last.
        var minX: CGFloat
        var maxX: CGFloat
        /// Bottom of its letters that sit on the baseline, or nil when it has none.
        var baseline: CGFloat?
        var box: CGRect
        /// Edges of its last character, and the trailing edge of the one
        /// before, when recognition gave them: the last one may be the
        /// app's caret, read as a letter.
        var lastCharacterMinX: CGFloat?
        var characterBeforeLastMaxX: CGFloat?
        /// Leading edge of its third character after any spaces. Recognition
        /// garbles the start of a line more than the rest of it, so what
        /// follows still measures the font when the first letters are lost.
        var tailMinX: CGFloat?
        /// Its edges were measured from the image's pixels rather than from
        /// what recognition read, so they hold however its letters were read.
        var edgesAreMeasured = false
        /// Its ink has more words than were read. Recognition lost one ("Видимо
        /// се у" for "Видимо се у г"), so the typed text it lacks is drawn, not
        /// missing from the frame.
        var inkHasMoreWords = false
    }

    /// Characters recognition reads a text caret as.
    static let caretLookalikes: Set<Character> = ["|", "I", "l", "1", "!", "[", "]", "ǀ", "¦"]

    /// Where the caret was found for one field, and what moving along its
    /// line needs.
    struct Calibration: Equatable {
        /// The text before the caret when it was found there.
        var precedingText: String
        var caretX: CGFloat
        var baseline: CGFloat
        /// Size of the system font whose width matches the recognized line.
        var pointSize: CGFloat
        /// Where the caret's line starts, and where text on it wraps.
        var lineMinX: CGFloat
        var lineMaxX: CGFloat
        /// The end of the line's first word, when the line is not the first
        /// of its paragraph. Deleting back into that word can let the word
        /// return to the line above.
        var firstWordEndX: CGFloat?
        /// Recognition read as many characters as were typed on a line long
        /// enough to measure, so this size holds for the whole field. A line
        /// missing its first letters gave sizes from 11 to 15 pt for one 13.5 pt
        /// field (2026-11-02), and the ghost changed size from one find to the next.
        var sizeIsReliable = false
        /// Where the field's first line starts, when this is that line. Text
        /// typed there later starts here too, whatever it is.
        var textStartX: CGFloat?
    }

    /// Recognized text compared with the typed text, after normalizing both.
    static let minimumSimilarity = 0.75
    /// How much of the end of a line is compared.
    static let comparedCharacters = 48
    /// Typing this far from where the caret was found is measured again.
    static let maximumDrift = 40
    /// Typing this far starts measuring it again in the background, while the
    /// caret already found stays in use.
    static let refindAfterCharacters = 12
    /// The same while the field's font has not been measured from a whole
    /// line: a size fitted to a few letters can be far off, and the caret
    /// moves by it. And always on a Cyrillic line: there the system font
    /// follows the field's own font worst, 10 pt off Helvetica Neue within
    /// 12 letters (2026-11-02).
    static let remeasureAfterCharacters = 4
    /// Recognition found no line shorter than this (one to three typed
    /// characters were never found, measured 2026-10-05).
    static let minimumLineCharacters = 3
    /// Characters a line needs before the size fitted to it holds for the field.
    static let minimumMeasuringCharacters = 8
    /// Characters a line needs for what follows its first two to measure the font.
    static let minimumTailCharacters = 8
    /// Text in a field is rarely smaller than this.
    static let smallestLikelyPointSize: CGFloat = 10
    /// A find on less typed text than this comes back empty too often to say
    /// anything about the field: at 1x, 3 to 7 characters often gave no line.
    static let minimumCharactersToCountAMiss = 8
    /// Characters at the end of the typed text that a recognized line may
    /// lack: the capture can be a frame behind the typing, and recognition
    /// can miss a final full stop or a short last word (in Viber, " te" after
    /// "Ima i dalje preklapanja", 2026-10-09).
    static let maximumMissingCharacters = 8
    /// After this many finds in a row came back empty, the field is treated
    /// as one whose caret cannot be found on screen.
    static let maximumFailedFinds = 3

    /// Whether the caret's line is in Cyrillic, which fast recognition cannot
    /// read at all (its languages are Latin ones).
    static func caretLineIsCyrillic(_ precedingText: String) -> Bool {
        caretLine(of: precedingText).core.unicodeScalars.contains { (0x0400...0x052F).contains($0.value) }
    }

    /// Whether a find on this text that came back empty counts against the field.
    static func missCounts(for precedingText: String) -> Bool {
        caretLine(of: precedingText).typed.count >= minimumCharactersToCountAMiss
    }

    /// Whether the caret's line has enough text to be found on screen.
    static func hasEnoughText(_ precedingText: String) -> Bool {
        caretLine(of: precedingText).typed.count >= minimumLineCharacters
    }

    /// The caret's paragraph up to the caret without the spaces typed at its
    /// end, normalized and as typed, and how many of those spaces there are.
    private static func caretLine(of precedingText: String) -> (typed: String, core: String, trailingSpaces: Int) {
        let paragraph = precedingText.split(separator: "\n", omittingEmptySubsequences: false).last.map(String.init) ?? ""
        let trailingSpaces = paragraph.reversed().prefix { $0 == " " || $0 == "\u{00A0}" }.count
        let core = String(paragraph.dropLast(trailingSpaces))
        return (normalized(core), core, trailingSpaces)
    }

    /// One typed character as recognized text is compared with it.
    private struct TypedCharacter {
        let character: Character
        let index: String.Index
        /// `isUnreadable` for the character as it was typed.
        let isUnreadable: Bool
    }

    /// A Latin letter with an accent fast recognition has no way to read. It
    /// knows English, French, Italian, German, Spanish and Portuguese, without
    /// their accents in practice, so on a non-Retina display "Č" came back as
    /// "&", "Ž" as "2", "Đ" as "E)" and "Š" not at all (2026-11-02). What it
    /// reads there says nothing about whether the line is the typed one. Not
    /// whole scripts: a line of them would match any text, and the caret went
    /// up to 24 pt astray when all of Cyrillic was treated this way.
    private static func isUnreadable(_ character: Character) -> Bool {
        guard character.isLetter, !character.isASCII,
              let scalar = String(character).precomposedStringWithCanonicalMapping.unicodeScalars.first
        else { return false }
        return (0x00C0...0x024F).contains(scalar.value) || (0x1E00...0x1EFF).contains(scalar.value)
            || isCyrillicWithoutAModel(character, scalar: scalar)
    }

    /// The Cyrillic letters recognition has no model for: it reads Russian and
    /// Ukrainian only, so "ђ" comes back as "h" and "њ" as "н" or "нь". The
    /// rest of a Cyrillic line is compared as usual, which is what keeps a line
    /// of about the right length from matching.
    private static func isCyrillicWithoutAModel(_ character: Character, scalar: Unicode.Scalar) -> Bool {
        (0x0400...0x052F).contains(scalar.value) && !russianAndUkrainianLetters.contains(character.lowercased())
    }

    private static let russianAndUkrainianLetters = Set("абвгдеёжзийклмнопрстуфхцчшщъыьэюяєіїґ".map(String.init))

    private static func typedCharacters(of core: String) -> [TypedCharacter] {
        normalizedCharacters(of: core).map {
            TypedCharacter(character: $0.character, index: $0.index, isUnreadable: isUnreadable(core[$0.index]))
        }
    }

    /// The characters to compare: spaces say nothing, since recognition often
    /// runs words together ("Zaomij" for "Žao mi j").
    private static func recognizedCharacters(of text: String) -> [Character] {
        normalized(text).filter { $0 != " " }
    }

    /// Finds the line that ends at the caret: the end of the caret's
    /// paragraph, as far as it is drawn on its last line.
    static func locate(lines: [RecognizedLine], precedingText: String, fieldFrame: CGRect) -> Calibration? {
        let (typed, core, trailingSpaces) = caretLine(of: precedingText)
        guard typed.count >= minimumLineCharacters else { return nil }
        let typedCharacters = typedCharacters(of: core)
        // The end of a recognized line is aligned with the typed text: where
        // the two match best is where the line ends, and the typed text past
        // that point is drawn but was not recognized.
        let missingRange = 0...max(0, min(maximumMissingCharacters, typed.count - minimumLineCharacters))

        var best: (line: RecognizedLine, alignment: Alignment)?
        for line in lines {
            guard let alignment = alignment(of: line, typed: typedCharacters, missingRange: missingRange),
                  alignment.score >= minimumSimilarity else { continue }
            if let current = best,
               !isBetter(line, score: alignment.score, than: current.line, score: current.alignment.score) {
                continue
            }
            best = (line, alignment)
        }
        guard let best, best.line.maxX > best.line.minX else { return nil }
        let line = best.line
        let endsWithCaret = best.alignment.endsWithCaret
        // Where the line's text ends: before the caret when it was read as a
        // character.
        let textMaxX = endsWithCaret ? line.characterBeforeLastMaxX ?? line.maxX : line.maxX
        // The typed characters drawn on this line, counted back from where it
        // ends without spaces: all of a paragraph that fits on it, less any
        // first letters recognition lost.
        let lineEnd = typedCharacters.count - best.alignment.missing
        let recognizedCount = best.alignment.recognizedCount
        let recognized = start(ofLast: recognizedCount, before: lineEnd, in: typedCharacters)
        let lost = typedCharacters[..<recognized.index].filter { $0.character != " " }.count
        // A letter without a model can read as none, one or two ("ль" for "љ").
        let readingSlack = line.edgesAreMeasured ? max(2, typedCharacters.filter(\.isUnreadable).count) : 0
        let lineStart = lost <= max(2, readingSlack) ? 0 : recognized.index
        let startsParagraph = lineStart == 0
        let countsAgree = lost + recognized.unmatched <= readingSlack
        func typedText(_ start: Int) -> String {
            String(core[typedCharacters[start].index..<(
                lineEnd < typedCharacters.count ? typedCharacters[lineEnd].index : core.endIndex)])
                .trimmingCharacters(in: .whitespaces)
        }
        let drawn = typedText(lineStart)
        // With fewer characters than were typed, the first one read may stand
        // for two ("&" for "Če") or some may be lost before it ("a" for the "a"
        // of "Šta"), so the line's start says little. Past it, the line and
        // the typed text still agree.
        var tail: (text: String, minX: CGFloat)?
        if startsParagraph, !countsAgree, recognizedCount >= minimumTailCharacters, let tailMinX = line.tailMinX {
            let start = start(ofLast: recognizedCount - 2, before: lineEnd, in: typedCharacters).index
            tail = (typedText(start), tailMinX)
        }
        var fitted = fittedPointSize(
            of: tail?.text ?? drawn, width: textMaxX - (tail?.minX ?? line.minX), height: line.box.height)
        // Smaller than text in a field usually is: the width was shared out
        // over letters that are not in it ("ao" for "Ćao", 7.8 pt). It is the
        // rest that is drawn there.
        if let size = fitted, tail == nil, !countsAgree, size < smallestLikelyPointSize {
            fitted = fittedPointSize(
                of: typedText(recognized.index), width: textMaxX - line.minX, height: line.box.height) ?? size
        }
        guard let pointSize = fitted ?? fittedPointSize(of: line) else { return nil }
        let font = NSFont.systemFont(ofSize: pointSize)
        let inset = max(line.minX - fieldFrame.minX, 0)
        let caretX: CGFloat
        var unseenLetters = false
        if endsWithCaret, let caretMinX = line.lastCharacterMinX {
            // The app's caret was captured, read as a "|" or an "l": it is
            // where it is drawn, after any spaces typed. Adding those spaces
            // again put the ghost a space too far right in Viber. Only what
            // the frame predates moves it on: letters it lacks, or spaces when
            // the caret still touches the last letter.
            let spaces = String(repeating: " ", count: trailingSpaces)
            var sinceFrame = ""
            if best.alignment.missing > 0 {
                sinceFrame = String(core[typedCharacters[lineEnd].index...]) + spaces
            } else if line.edgesAreMeasured, trailingSpaces > 0,
                      caretMinX - textMaxX < CotypingInlineGhostLayout.width(of: " ", font: font) / 2 {
                sinceFrame = spaces
            }
            unseenLetters = sinceFrame.contains { !$0.isWhitespace }
            caretX = (caretMinX + line.maxX) / 2 + advance(of: sinceFrame, after: drawn, font: font)
        } else {
            // What the capture lacks is drawn after the line's last letter,
            // and the caret follows that letter's advance, a little past its
            // ink (0.6–0.8 pt at 13 pt, measured 2026-10-09).
            let unseenStart = best.alignment.missing > 0 ? typedCharacters[lineEnd].index : core.endIndex
            let unseen = String(core[unseenStart...]) + String(repeating: " ", count: trailingSpaces)
            unseenLetters = unseen.contains { !$0.isWhitespace }
            let bearing = drawn.last.map { rightSideBearing(of: $0, font: font) } ?? 0
            caretX = line.maxX + bearing + advance(of: unseen, after: drawn, font: font)
        }
        let lineMaxX = fieldFrame.maxX - inset
        // Unseen letters close to where the line wraps may be on the next line.
        guard caretX <= (unseenLetters ? lineMaxX - pointSize : lineMaxX) else { return nil }
        let firstWord = drawn.prefix { !$0.isWhitespace }
        return Calibration(
            precedingText: precedingText,
            caretX: caretX,
            baseline: line.baseline ?? line.box.minY - font.descender,
            pointSize: pointSize,
            lineMinX: line.minX,
            lineMaxX: lineMaxX,
            firstWordEndX: startsParagraph
                ? nil : line.minX + CotypingInlineGhostLayout.width(of: String(firstWord), font: font),
            sizeIsReliable: countsAgree && recognizedCount >= minimumMeasuringCharacters,
            textStartX: countsAgree && startsParagraph && !precedingText.contains(where: \.isNewline)
                ? line.minX - leftSideBearing(of: core.first, font: font)
                : nil)
    }

    /// Where in `characters` the last `count` characters before `end` start,
    /// not counting spaces, and how many of them there was no room for.
    private static func start(
        ofLast count: Int, before end: Int, in characters: [TypedCharacter]
    ) -> (index: Int, unmatched: Int) {
        var index = end
        var unmatched = count
        while index > 0, unmatched > 0 {
            index -= 1
            if characters[index].character != " " { unmatched -= 1 }
        }
        return (index, unmatched)
    }

    /// How the end of a recognized line lines up with the end of the typed text.
    private struct Alignment {
        var score: Double
        /// Typed characters past the line's end that recognition lacks.
        var missing: Int
        /// The line's last character is the app's caret, not text.
        var endsWithCaret: Bool
        /// Characters of text the line holds, without such a caret or spaces.
        var recognizedCount: Int
    }

    /// The best way the end of `line` matches the end of the typed text:
    /// over how many typed characters the line lacks, and whether its last
    /// character is the caret, read as a "|" or an "l". Without that caret
    /// the line has to end exactly where the typed text does, since the
    /// caret follows all of it; between equals, the plain reading wins.
    private static func alignment(
        of line: RecognizedLine, typed: [TypedCharacter], missingRange: ClosedRange<Int>
    ) -> Alignment? {
        var best: Alignment?
        let recognized = recognizedCharacters(of: line.text)
        let printed = typed.filter { $0.character != " " }
        let missingRange = line.inkHasMoreWords ? 0...0 : missingRange
        // A line longer than the paragraph holds other text too, past what
        // two characters read for one letter can explain.
        let extraReadings = line.edgesAreMeasured ? printed.filter(\.isUnreadable).count + 2 : 0
        if recognized.count >= 2, recognized.count <= printed.count + max(extraReadings, 2) {
            for missing in missingRange where missing < typed.count {
                // Spaces are not compared, so a line ends before one, not after.
                guard typed[typed.count - missing - 1].character != " " else { continue }
                let drawn = typed.dropLast(missing).filter { $0.character != " " }
                let length = min(recognized.count, drawn.count, comparedCharacters)
                let score = line.edgesAreMeasured
                    ? similarityToTheEnd(of: drawn.suffix(comparedCharacters), recognized: recognized.suffix(comparedCharacters))
                    : similarity(recognized: recognized.suffix(length), typed: drawn.suffix(length))
                if score > (best?.score ?? -1) {
                    best = Alignment(score: score, missing: missing, endsWithCaret: false,
                                     recognizedCount: recognized.count)
                }
            }
        }
        let trimmed = line.text.trimmingCharacters(in: .whitespaces)
        if line.lastCharacterMinX != nil, let last = trimmed.last, caretLookalikes.contains(last) {
            let text = recognizedCharacters(of: String(trimmed.dropLast()))
            if text.count >= 2, text.count <= printed.count + extraReadings {
                // A caret measured in a frame from before the last key is still
                // where it was drawn, and what it lacks follows it.
                for missing in line.edgesAreMeasured ? missingRange : 0...0 where missing < typed.count {
                    guard missing == 0 || typed[typed.count - missing - 1].character != " " else { continue }
                    let drawn = typed.dropLast(missing).filter { $0.character != " " }
                    let length = min(text.count, drawn.count, comparedCharacters)
                    let score = line.edgesAreMeasured
                        ? similarityToTheEnd(of: drawn.suffix(comparedCharacters), recognized: text.suffix(comparedCharacters))
                        : similarity(recognized: text.suffix(length), typed: drawn.suffix(length))
                    if score > (best?.score ?? -1) {
                        best = Alignment(score: score, missing: missing, endsWithCaret: true, recognizedCount: text.count)
                    }
                }
            }
        }
        return best
    }

    /// How far `text` moves the caret when it follows `preceding`: measured
    /// after the last letter of `preceding`, so the pair's kerning counts
    /// ("w." is a point narrower than "w" and "." apart).
    static func advance(of text: String, after preceding: String, font: NSFont) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        let context = preceding.last.map(String.init) ?? ""
        return CotypingInlineGhostLayout.width(of: context + text, font: font)
            - CotypingInlineGhostLayout.width(of: context, font: font)
    }

    /// How far `character`'s ink starts past where it is drawn from.
    static func leftSideBearing(of character: Character?, font: NSFont) -> CGFloat {
        guard let character, !character.isWhitespace else { return 0 }
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: String(character), attributes: [.font: font]))
        let ink = CTLineGetImageBounds(line, nil)
        guard !ink.isNull, ink.width > 0 else { return 0 }
        return min(max(ink.minX, -1), 3)
    }

    /// How far a caret after `character` sits past its ink: its advance less
    /// where its ink ends.
    static func rightSideBearing(of character: Character, font: NSFont) -> CGFloat {
        guard !character.isWhitespace else { return 0 }
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: String(character), attributes: [.font: font]))
        let advance = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        let ink = CTLineGetImageBounds(line, nil)
        guard !ink.isNull, ink.width > 0 else { return 0 }
        return min(max(advance - ink.maxX, -1), 3)
    }

    /// The better of two lines that both match the typed text: the closer
    /// match; between equals, the lowest line, which is where a paragraph's
    /// last line is drawn, or on one row (recognition can split a line into
    /// pieces) the longer piece, whose width sizes the font better.
    private static func isBetter(
        _ line: RecognizedLine, score: Double, than other: RecognizedLine, score otherScore: Double
    ) -> Bool {
        guard score == otherScore else { return score > otherScore }
        let overlap = min(line.box.maxY, other.box.maxY) - max(line.box.minY, other.box.minY)
        if overlap > min(line.box.height, other.box.height) / 2 {
            return line.text.count > other.text.count
        }
        return line.box.minY < other.box.minY
    }

    /// The caret's x for `precedingText`, moved along the line from where it
    /// was found by the width of what was typed or deleted since. Nil when
    /// that leaves the line, crosses a line break, strays too far, or may
    /// have moved a word to another line: letters typed close to where the
    /// line wraps, whose exact place is not known, or letters deleted from
    /// the first word of a line that is not its paragraph's first.
    static func caretX(for calibration: Calibration, precedingText: String) -> CGFloat? {
        guard let change = change(from: calibration.precedingText, to: precedingText) else { return nil }
        guard change.text.count <= maximumDrift, !change.text.contains(where: \.isNewline) else { return nil }
        // Measured after the text the change follows, with its kerning.
        let shorter = change.isAddition ? calibration.precedingText : precedingText
        let width = advance(of: change.text, after: shorter, font: .systemFont(ofSize: calibration.pointSize))
        let x = calibration.caretX + (change.isAddition ? width : -width)
        let typedLetters = change.isAddition && change.text.contains { !$0.isWhitespace }
        let lineEnd = typedLetters ? calibration.lineMaxX - calibration.pointSize : calibration.lineMaxX
        guard x <= lineEnd, x >= calibration.lineMinX - 1 else { return nil }
        if !change.isAddition, let firstWordEnd = calibration.firstWordEndX, x <= firstWordEnd { return nil }
        return x
    }

    /// The caret's x for text that took the place of what the caret was found
    /// after, such as the next message once one was sent: `calibration` knows
    /// where the field's first line starts. Nil once the text would leave that
    /// line. Recognition finds nothing in the first few letters of a message,
    /// so without this each one began with no suggestion, or a popup.
    static func caretXFromLineStart(for calibration: Calibration, precedingText: String) -> CGFloat? {
        guard let start = calibration.textStartX, !precedingText.contains(where: \.isNewline) else { return nil }
        let width = CotypingInlineGhostLayout.width(of: precedingText, font: .systemFont(ofSize: calibration.pointSize))
        let x = start + width
        return x <= calibration.lineMaxX - calibration.pointSize ? x : nil
    }

    /// A caret rect the inline ghost places on the found baseline: one
    /// default line of the system font at the fitted size, which the overlay
    /// reads as AppKit text, baseline a fixed distance below the top.
    static func caretRect(for calibration: Calibration, caretX: CGFloat) -> CGRect {
        let font = NSFont.systemFont(ofSize: calibration.pointSize)
        let layout = NSLayoutManager()
        let height = layout.defaultLineHeight(for: font)
        let top = calibration.baseline + layout.defaultBaselineOffset(for: font)
        return CGRect(x: caretX, y: top - height, width: 0, height: height)
    }

    /// Whether the field may be captured: never a secure field, an app
    /// excluded from screen capture or autocomplete, or, while any site is
    /// excluded, a browser page whose address is unknown or excluded.
    static func permitsCapture(
        appName: String, bundleID: String?, host: String?, isSecure: Bool,
        excludedApps: [String], excludedDomains: [String]
    ) -> Bool {
        guard !isSecure,
              !ScreenContextPrivacy.isExcluded(appName: appName, bundleIdentifier: bundleID, rules: excludedApps)
        else { return false }
        guard excludedDomains.contains(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
              ScreenContextPrivacy.isBrowser(.init(appName: appName, bundleIdentifier: bundleID)) else { return true }
        guard let host else { return false }
        return !ScreenContextPrivacy.isExcluded(sourceURL: "https://\(host)/", rules: excludedDomains)
    }

    /// The system font size whose width matches the recognized line's.
    static func fittedPointSize(of line: RecognizedLine) -> CGFloat? {
        fittedPointSize(
            of: line.text.trimmingCharacters(in: .whitespaces), width: line.maxX - line.minX, height: line.box.height)
    }

    /// The system font size at which `text` is `width` wide. The system font
    /// changes its spacing with size, so the width is compared near the size
    /// found, starting from the line's `height`.
    static func fittedPointSize(of text: String, width measured: CGFloat, height: CGFloat) -> CGFloat? {
        guard measured > 0, height > 0, !text.isEmpty else { return nil }
        var size = height
        for _ in 0..<3 {
            // Recognition measures ink, from the first letter's to the last's.
            let natural = inkWidth(of: text, font: .systemFont(ofSize: size))
            guard natural > 0 else { return nil }
            size *= measured / natural
            guard (6...72).contains(size) else { return nil }
        }
        // Recognized lines are about as tall as the font's size.
        guard (0.5...1.6).contains(height / size) else { return nil }
        return size
    }

    /// The width of `text`'s ink in `font`: from where its first letter's
    /// ink starts to where its last one's ends.
    static func inkWidth(of text: String, font: NSFont) -> CGFloat {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
        let ink = CTLineGetImageBounds(line, nil)
        return ink.isNull ? 0 : ink.width
    }

    /// What was typed after `old` to make `new`, or deleted from its end.
    /// Both may be windows that keep only the newest text, so they are
    /// aligned on the end of the shorter one when neither starts the other.
    static func change(from old: String, to new: String) -> (text: String, isAddition: Bool)? {
        if new.hasPrefix(old) { return (String(new.dropFirst(old.count)), true) }
        if old.hasPrefix(new) { return (String(old.dropFirst(new.count)), false) }
        let anchorLength = 32
        if old.count >= anchorLength, let range = new.range(of: String(old.suffix(anchorLength)), options: .backwards) {
            return (String(new[range.upperBound...]), true)
        }
        if new.count >= anchorLength, let range = old.range(of: String(new.suffix(anchorLength)), options: .backwards) {
            return (String(old[range.upperBound...]), false)
        }
        return nil
    }

    /// Lowercased, without accents, with typographic quotes and dashes plain
    /// and whitespace runs as one space, so recognition's small liberties do
    /// not count. Fast recognition often reads "š" as "s".
    static func normalized(_ text: String) -> String {
        String(normalizedCharacters(of: text).map(\.character))
    }

    /// `normalized(text)` one character at a time, with where in `text` each
    /// came from: a run of whitespace from its first character.
    static func normalizedCharacters(of text: String) -> [(character: Character, index: String.Index)] {
        var result: [(character: Character, index: String.Index)] = []
        var pendingSpace: String.Index?
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character.isWhitespace {
                if !result.isEmpty, pendingSpace == nil { pendingSpace = index }
            } else {
                if let space = pendingSpace {
                    result.append((" ", space))
                    pendingSpace = nil
                }
                result.append((plain(character), index))
            }
            index = text.index(after: index)
        }
        return result
    }

    private static func plain(_ character: Character) -> Character {
        switch character {
        case "\u{2018}", "\u{2019}", "`": return "'"
        case "\u{201C}", "\u{201D}": return "\""
        case "\u{2013}", "\u{2014}": return "-"
        default:
            let folded = String(character).lowercased().folding(options: .diacriticInsensitive, locale: nil)
            guard folded.count == 1, let plain = folded.first else { return character }
            return latinLookalikes[plain] ?? plain
        }
    }

    /// Cyrillic letters drawn like Latin ones, in either case. Recognition
    /// mixes the two within a word ("рекаo", "Бophe" for "Ђорђе"), and what it
    /// chose says nothing about which letter was typed.
    private static let latinLookalikes: [Character: Character] = [
        "а": "a", "в": "b", "е": "e", "і": "i", "ј": "j", "к": "k", "м": "m", "н": "h",
        "о": "o", "р": "p", "с": "c", "т": "t", "у": "y", "х": "x", "ѕ": "s",
    ]

    /// `similarity` for a line whose reading may have lost a letter anywhere:
    /// the typed text may start earlier than the line, and has to end where it
    /// does. Comparing equal lengths from the end instead counted one lost letter
    /// as every letter before it shifted, and taking the typed text as ending a
    /// word later looked better (13 pt astray, measured 2026-11-02).
    private static func similarityToTheEnd(of typed: some Collection<TypedCharacter>, recognized: some Collection<Character>) -> Double {
        let a = Array(recognized), b = Array(typed)
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        var previous = [Int](repeating: 0, count: b.count + 1)
        for (i, x) in a.enumerated() {
            var current = [i + 1] + Array(repeating: 0, count: b.count)
            for (j, y) in b.enumerated() {
                current[j + 1] = min(
                    previous[j + 1] + 1,
                    current[j] + (y.isUnreadable ? 0 : 1),
                    previous[j] + (x == y.character || y.isUnreadable ? 0 : 1))
            }
            previous = current
        }
        return 1 - Double(previous[b.count]) / Double(a.count)
    }

    /// 1 minus the edit distance per character. A typed letter recognition
    /// cannot read costs nothing, whether it was read as something else or lost.
    private static func similarity(recognized: some Collection<Character>, typed: some Collection<TypedCharacter>) -> Double {
        let a = Array(recognized), b = Array(typed)
        guard !a.isEmpty || !b.isEmpty else { return 1 }
        var previous = [0]
        for y in b { previous.append(previous[previous.count - 1] + (y.isUnreadable ? 0 : 1)) }
        for (i, x) in a.enumerated() {
            var current = [i + 1] + Array(repeating: 0, count: b.count)
            for (j, y) in b.enumerated() {
                current[j + 1] = min(
                    previous[j + 1] + 1,
                    current[j] + (y.isUnreadable ? 0 : 1),
                    previous[j] + (x == y.character || y.isUnreadable ? 0 : 1))
            }
            previous = current
        }
        return 1 - Double(previous[b.count]) / Double(max(a.count, b.count))
    }
}

/// Keeps the caret found on screen for the focused field, and finds it again
/// when typing leaves the line it was found on. The capture is the field's
/// own frame, held in memory only while its text is recognized; nothing but
/// the caret's position is kept.
@MainActor
final class CotypingVisualCaret {
    private struct Entry {
        let key: String
        let frame: CGRect
        let calibration: CotypingVisualCaretLocator.Calibration
    }

    private var entry: Entry?
    /// The last find for the field that measured a whole line. Its font size
    /// outlasts finds that could not measure one, and it places a new message.
    private var measured: Entry?
    private var pending: (key: String, frame: CGRect, task: Task<Void, Never>)?
    /// Whether the field last prepared may be captured, by app and kind of field.
    private var permission: (key: String, permitted: Bool)?
    /// Finds in a row that came back without the caret, for one field.
    private var failedFinds: (key: String, frame: CGRect, count: Int)?

    /// Larger fields are left alone: the caret could be anywhere in them.
    private static let maximumFieldSize = CGSize(width: 2400, height: 900)

    /// `field` with the caret found on screen, when its app reports none and
    /// the caret is still on the line it was found on.
    func resolve(_ field: CotypingField) -> CotypingField {
        guard !field.caretIsExact else { return field }
        let calibration: CotypingVisualCaretLocator.Calibration
        let x: CGFloat
        if let tracked = trackedCaretX(for: field), let entry {
            calibration = entry.calibration
            x = tracked
        } else if let measured = current(measured, for: field),
                  let fromLineStart = CotypingVisualCaretLocator.caretXFromLineStart(
                      for: measured.calibration, precedingText: field.precedingText) {
            calibration = measured.calibration
            x = fromLineStart
        } else {
            return field
        }
        var resolved = field
        resolved.caretRect = CotypingVisualCaretLocator.caretRect(for: calibration, caretX: x)
        resolved.caretIsExact = true
        // Without a font from the app, the ghost uses the size measured on
        // screen, which is also what moves the caret along the line.
        if resolved.fieldStyle == nil {
            resolved.fieldStyle = CotypingFieldStyle(fontPointSize: calibration.pointSize)
        }
        return resolved
    }

    /// The caret followed along the line it was found on.
    private func trackedCaretX(for field: CotypingField) -> CGFloat? {
        current(entry, for: field).flatMap {
            CotypingVisualCaretLocator.caretX(for: $0.calibration, precedingText: field.precedingText)
        }
    }

    /// `candidate` when it was found for `field`, as it is now.
    private func current(_ candidate: Entry?, for field: CotypingField) -> Entry? {
        guard let candidate, candidate.key == Self.key(for: field),
              let frame = field.inputFrameRect, Self.isSameFrame(candidate.frame, frame) else { return nil }
        return candidate
    }

    /// Records whether `field` may be captured, which the caller decides from
    /// the privacy rules before asking for a find.
    func notePermission(_ permitted: Bool, for field: CotypingField) {
        permission = (Self.key(for: field), permitted)
    }

    /// Whether the caret of `field`, which its app does not report, is found
    /// on screen: it may be captured, its field has a size and direction a
    /// find handles, and finds there have not kept failing. Its line may
    /// still be too short to find.
    func canFind(_ field: CotypingField, screenCaptureAllowed: () -> Bool = { CGPreflightScreenCaptureAccess() }) -> Bool {
        let key = Self.key(for: field)
        guard !field.caretIsExact, permission?.key == key, permission?.permitted == true,
              failedFindCount(key: key, frame: field.inputFrameRect) < CotypingVisualCaretLocator.maximumFailedFinds
        else { return false }
        return Self.isFindable(field) && screenCaptureAllowed()
    }

    /// Counts a find for `field` that came back without its caret.
    func noteFailedFind(for field: CotypingField) {
        guard let frame = field.inputFrameRect else { return }
        noteFailedFind(key: Self.key(for: field), frame: frame)
    }

    private func noteFailedFind(key: String, frame: CGRect) {
        failedFinds = (key, frame, failedFindCount(key: key, frame: frame) + 1)
    }

    private func failedFindCount(key: String, frame: CGRect?) -> Int {
        guard let failedFinds, failedFinds.key == key,
              let frame, Self.isSameFrame(failedFinds.frame, frame) else { return 0 }
        return failedFinds.count
    }

    /// Starts finding the caret on screen when `field` reports none and no
    /// earlier find still follows it. A caret worked out from where the line
    /// starts is only an estimate, so it is measured all the same. The caller
    /// has checked the privacy rules.
    func refreshIfNeeded(for field: CotypingField) {
        guard !field.caretIsExact, isDueForAFind(field),
              Self.isFindable(field), let frame = field.inputFrameRect,
              CotypingVisualCaretLocator.hasEnoughText(field.precedingText),
              CGPreflightScreenCaptureAccess() else { return }
        find(field, in: frame)
    }

    /// Starts finding the caret again once typing has moved it a fair way
    /// along its line from where it was found, so small differences between
    /// the app's font and the measured one never add up. The caret found
    /// earlier stays in use until the new one is in. Only for a field already
    /// cleared for capture (`notePermission`).
    func refreshIfDrifted(for field: CotypingField) {
        guard canFind(field), current(entry, for: field) != nil, isDueForAFind(field),
              let frame = field.inputFrameRect else { return }
        find(field, in: frame)
    }

    /// Whether the caret should be measured on screen: it is not being
    /// followed, or typing has moved it far enough from where it was found.
    func isDueForAFind(_ field: CotypingField) -> Bool {
        guard let entry = current(entry, for: field), trackedCaretX(for: field) != nil,
              let change = CotypingVisualCaretLocator.change(
                  from: entry.calibration.precedingText, to: field.precedingText) else { return true }
        let isSizeKnown = current(measured, for: field) != nil
            && !CotypingVisualCaretLocator.caretLineIsCyrillic(field.precedingText)
        return change.text.count >= (isSizeKnown
            ? CotypingVisualCaretLocator.refindAfterCharacters
            : CotypingVisualCaretLocator.remeasureAfterCharacters)
    }

    private func find(_ field: CotypingField, in frame: CGRect) {
        let key = Self.key(for: field)
        // One at a time per field: a find for text a little behind the typing
        // still places the caret, and restarting on each key could mean none
        // ever finished.
        if let pending, pending.key == key, Self.isSameFrame(pending.frame, frame) { return }
        pending?.task.cancel()
        let precedingText = field.precedingText
        let task = Task { [weak self] in
            let lines = await Self.recognizeLines(in: frame, precedingText: precedingText)
            guard let self, !Task.isCancelled else { return }
            if let lines, let calibration = CotypingVisualCaretLocator.locate(
                lines: lines, precedingText: precedingText, fieldFrame: frame) {
                self.remember(calibration, key: key, frame: frame)
            } else if lines != nil, CotypingVisualCaretLocator.missCounts(for: precedingText) {
                self.noteFailedFind(key: key, frame: frame)
            }
            if let pending = self.pending, pending.key == key, Self.isSameFrame(pending.frame, frame) { self.pending = nil }
        }
        pending = (key, frame, task)
    }

    /// A field whose caret a find can place: a size that holds a line but
    /// not a whole page, the caret at the end of its line, left-to-right.
    private static func isFindable(_ field: CotypingField) -> Bool {
        guard let frame = field.inputFrameRect else { return false }
        return frame.width >= 40 && frame.height >= 12
            && frame.width <= maximumFieldSize.width && frame.height <= maximumFieldSize.height
            && CotypingRenderModePolicy.isCaretAtEndOfLine(trailingText: field.trailingText)
            && !CotypingTextDirectionDetector.isRightToLeft(field.precedingText)
    }

    /// Keeps where the caret was found for `field`.
    func remember(_ calibration: CotypingVisualCaretLocator.Calibration, for field: CotypingField) {
        guard let frame = field.inputFrameRect else { return }
        remember(calibration, key: Self.key(for: field), frame: frame)
    }

    private func remember(_ found: CotypingVisualCaretLocator.Calibration, key: String, frame: CGRect) {
        var calibration = found
        if found.sizeIsReliable {
            measured = Entry(key: key, frame: frame, calibration: found)
        } else if let measured, measured.key == key, Self.isSameFrame(measured.frame, frame) {
            calibration.pointSize = measured.calibration.pointSize
        }
        entry = Entry(key: key, frame: frame, calibration: calibration)
        failedFinds = nil
    }

    /// Waits for a find in progress, for at most `milliseconds`. A find that
    /// takes longer keeps running and is kept for the next suggestion.
    func waitForPending(milliseconds: Int) async {
        guard let task = pending?.task else { return }
        await CotypingBoundedWait.wait(for: task, milliseconds: milliseconds)
    }

    func reset() {
        pending?.task.cancel()
        pending = nil
        entry = nil
        measured = nil
        permission = nil
        failedFinds = nil
    }

    /// The app and kind of field. Not the element's identity: Chrome hands
    /// out a new element on every read, which would find the caret again
    /// for every suggestion. The field's frame and its text pin it instead.
    private static func key(for field: CotypingField) -> String {
        "\(field.processID)|\(field.role)"
    }

    private static func isSameFrame(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.minX - rhs.minX) <= 0.5 && abs(lhs.minY - rhs.minY) <= 0.5
            && abs(lhs.width - rhs.width) <= 0.5 && abs(lhs.height - rhs.height) <= 0.5
    }

    // MARK: - Capture and recognition

    /// The field's frame captured larger than its point size, which keeps
    /// small text legible on a non-Retina display, with its lines recognized.
    private static func recognizeLines(
        in frame: CGRect, precedingText: String
    ) async -> [CotypingVisualCaretLocator.RecognizedLine]? {
        guard let image = await capture(frame) else { return nil }
        return await Task.detached(priority: .userInitiated) {
            CotypingVisualCaret.recognize(image, frame: frame, precedingText: precedingText)
        }.value
    }

    /// The field's lines, by the recognition that can read what was typed.
    nonisolated static func recognize(
        _ image: CGImage, frame: CGRect, precedingText: String
    ) -> [CotypingVisualCaretLocator.RecognizedLine] {
        CotypingVisualCaretLocator.caretLineIsCyrillic(precedingText)
            ? recognizeCyrillic(image, frame: frame, precedingText: precedingText)
            : recognize(image, frame: frame)
    }

    private static func capture(_ frame: CGRect) async -> CGImage? {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true) else { return nil }
        let center = CGPoint(x: frame.midX, y: frame.midY)
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(center) }),
              let screenNumber = (screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value,
              let display = content.displays.first(where: { $0.displayID == screenNumber }) else { return nil }
        let visible = frame.intersection(screen.frame)
        guard visible == frame else { return nil }
        let config = captureConfiguration(for: frame, screenFrame: screen.frame, backingScale: screen.backingScaleFactor)
        // The ghost panel is never shared, so it is not in the capture.
        let filter = SCContentFilter(display: display, excludingWindows: [])
        return try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    /// The field's frame at `captureScale` times its point size. Without
    /// `scalesToFit` a non-Retina display's pixels land unscaled in the
    /// image's top-left quarter (measured 2026-10-05 on a 1x display), and
    /// every recognized box comes out at half its size and place.
    nonisolated static func captureConfiguration(
        for frame: CGRect, screenFrame: CGRect, backingScale: CGFloat
    ) -> SCStreamConfiguration {
        let scale = captureScale(for: frame, backingScale: backingScale)
        let config = SCStreamConfiguration()
        // The display's top-left point space.
        config.sourceRect = CGRect(
            x: frame.minX - screenFrame.minX, y: screenFrame.maxY - frame.maxY,
            width: frame.width, height: frame.height)
        config.width = Int((frame.width * scale).rounded())
        config.height = Int((frame.height * scale).rounded())
        config.scalesToFit = true
        config.showsCursor = false
        return config
    }

    /// Pixels per point to capture at. A Retina display's own scale; on a
    /// non-Retina one, three times the points for a field small enough:
    /// recognition misread twice as many letters of rendered chat text at
    /// two times (9 of 371 against 5, measured 2026-10-09; Viber's "je" as
    /// "Je" throughout), in the same 6 ms per line.
    nonisolated static func captureScale(for frame: CGRect, backingScale: CGFloat) -> CGFloat {
        guard backingScale < 2 else { return backingScale }
        return frame.width * frame.height * 9 <= 4_000_000 ? 3 : 2
    }

    /// Recognized lines with their first and last characters' edges and
    /// baselines, mapped from the image onto `frame`.
    nonisolated static func recognize(
        _ image: CGImage, frame: CGRect
    ) -> [CotypingVisualCaretLocator.RecognizedLine] {
        let request = VNRecognizeTextRequest()
        // Fast recognition gives character boxes within half a point; the
        // accurate one gives only word boxes and takes several times longer.
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = false
        guard (try? VNImageRequestHandler(cgImage: image).perform([request])) != nil else { return [] }
        func point(_ box: CGRect) -> CGRect {
            CGRect(x: frame.minX + box.minX * frame.width, y: frame.minY + box.minY * frame.height,
                   width: box.width * frame.width, height: box.height * frame.height)
        }
        return (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let text = candidate.string
            func box(_ index: String.Index) -> CGRect? {
                (try? candidate.boundingBox(for: index..<text.index(after: index))).map { point($0.boundingBox) }
            }
            guard let first = text.firstIndex(where: { !$0.isWhitespace }),
                  let last = text.lastIndex(where: { !$0.isWhitespace }),
                  let firstBox = box(first), let lastBox = box(last) else { return nil }
            let beforeLast = text[..<last].lastIndex(where: { !$0.isWhitespace }).flatMap(box)
            let tail = text.indices.lazy.filter { !text[$0].isWhitespace }.dropFirst(2).first.flatMap(box)
            // Letters without descenders sit on the baseline.
            let onBaseline = text.indices.filter { "acemnorsuvwxzABCDEFHIKLMNORSTUVWXZ".contains(text[$0]) }
            let bottoms = onBaseline.prefix(8).compactMap { box($0)?.minY }.sorted()
            return CotypingVisualCaretLocator.RecognizedLine(
                text: text, minX: firstBox.minX, maxX: lastBox.maxX,
                baseline: bottoms.isEmpty ? nil : bottoms[bottoms.count / 2],
                box: point(observation.boundingBox),
                lastCharacterMinX: lastBox.minX, characterBeforeLastMaxX: beforeLast?.maxX,
                tailMinX: tail?.minX)
        }
    }

    /// Recognized lines for a field whose caret line is in Cyrillic. Accurate
    /// recognition reads it where fast recognition reads none of it (20 to 60 ms
    /// on a field's frame on an M4 Max, against 5), so that decides whether a
    /// line is the typed one. It gives only word boxes, so the line's edges,
    /// baseline and the app's caret come from its pixels.
    private nonisolated static func recognizeCyrillic(
        _ image: CGImage, frame: CGRect, precedingText: String
    ) -> [CotypingVisualCaretLocator.RecognizedLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["ru-RU", "uk-UA", "en-US"]
        request.usesLanguageCorrection = false
        guard (try? VNImageRequestHandler(cgImage: image).perform([request])) != nil,
              let bitmap = CotypingVisualCaretInk.Bitmap(image) else { return [] }
        let pixelsPerPoint = CGFloat(image.width) / frame.width
        let lastTypedLetter = precedingText.last { !$0.isWhitespace }
        func pointX(_ column: Int) -> CGFloat { frame.minX + CGFloat(column) / pixelsPerPoint }
        func pointY(_ row: Int) -> CGFloat { frame.minY + CGFloat(image.height - row) / pixelsPerPoint }
        return (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let read = candidate.string
            func box(_ index: String.Index) -> CGRect? {
                (try? candidate.boundingBox(for: index..<read.index(after: index)))?.boundingBox
            }
            guard let first = read.firstIndex(where: { !$0.isWhitespace }),
                  let last = read.lastIndex(where: { !$0.isWhitespace }),
                  let firstWord = box(first), let lastWord = box(last),
                  let ink = CotypingVisualCaretInk.measure(
                    bitmap, line: observation.boundingBox, firstWord: firstWord, lastWord: lastWord,
                    pixelsPerPoint: pixelsPerPoint, lastTypedLetter: lastTypedLetter) else { return nil }
            // What it read of the app's caret, the pixels say better. Only when
            // they show one: a last "г" can read as "/", and without it the
            // typed text looks a word longer than the line.
            var text = read.trimmingCharacters(in: .whitespaces)
            if ink.caretColumns != nil, let end = text.last, "|¦ǀ/[]".contains(end) {
                text = String(text.dropLast()).trimmingCharacters(in: .whitespaces)
            }
            let readWords = text.split(whereSeparator: \.isWhitespace).count
            if ink.caretColumns != nil { text += "|" }
            let bottom = pointY(ink.rows.upperBound), top = pointY(ink.rows.lowerBound)
            return CotypingVisualCaretLocator.RecognizedLine(
                text: text,
                minX: pointX(ink.columns.lowerBound),
                maxX: pointX(ink.caretColumns?.upperBound ?? ink.columns.upperBound),
                baseline: pointY(ink.baselineRow),
                box: CGRect(x: pointX(ink.columns.lowerBound), y: bottom,
                            width: pointX(ink.columns.upperBound) - pointX(ink.columns.lowerBound), height: top - bottom),
                lastCharacterMinX: ink.caretColumns.map { pointX($0.lowerBound) },
                characterBeforeLastMaxX: ink.caretColumns.map { _ in pointX(ink.columns.upperBound) },
                edgesAreMeasured: true,
                inkHasMoreWords: ink.wordCount > readWords)
        }
    }
}

/// Waits for a task to finish, for at most a deadline. A task group cannot do
/// this: leaving one waits for every child, and a child awaiting another task's
/// value is not stopped by cancellation, so the wait lasted as long as the
/// slowest find (a 150 ms budget waited for a 400 ms capture). The task is
/// never cancelled here; only the wait ends.
nonisolated enum CotypingBoundedWait {
    static func wait(for task: Task<Void, Never>, milliseconds: Int) async {
        let signal = FirstSignal()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                signal.install(continuation)
                let deadline = Task {
                    try? await Task.sleep(for: .milliseconds(milliseconds))
                    signal.fire()
                }
                Task {
                    await task.value
                    deadline.cancel()
                    signal.fire()
                }
            }
        } onCancel: {
            signal.fire()
        }
    }

    /// Resumes the waiter once, for whichever of the task, the deadline or
    /// the waiter's cancellation comes first. A cancellation can arrive
    /// before the waiter is installed.
    private final class FirstSignal: @unchecked Sendable {
        private let lock = NSLock()
        private var waiter: CheckedContinuation<Void, Never>?
        private var fired = false

        func install(_ continuation: CheckedContinuation<Void, Never>) {
            let resumeNow = lock.withLock {
                if fired { return true }
                waiter = continuation
                return false
            }
            if resumeNow { continuation.resume() }
        }

        func fire() {
            let pending: CheckedContinuation<Void, Never>? = lock.withLock {
                fired = true
                defer { waiter = nil }
                return waiter
            }
            pending?.resume()
        }
    }
}
