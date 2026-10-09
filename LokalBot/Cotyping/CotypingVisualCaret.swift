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
    }

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
    /// Recognition found no line shorter than this (one to three typed
    /// characters were never found, measured 2026-10-05).
    static let minimumLineCharacters = 3
    /// Characters at the end of the typed text that a recognized line may
    /// lack: the capture can be a frame behind the typing, and recognition
    /// can miss a final full stop or a short last word (in Viber, " te" after
    /// "Ima i dalje preklapanja", 2026-10-09).
    static let maximumMissingCharacters = 8
    /// After this many finds in a row came back empty, the field is treated
    /// as one whose caret cannot be found on screen.
    static let maximumFailedFinds = 3

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

    /// Finds the line that ends at the caret: the end of the caret's
    /// paragraph, as far as it is drawn on its last line.
    static func locate(lines: [RecognizedLine], precedingText: String, fieldFrame: CGRect) -> Calibration? {
        let (typed, core, trailingSpaces) = caretLine(of: precedingText)
        guard typed.count >= minimumLineCharacters else { return nil }
        // The end of a recognized line is aligned with the typed text: where
        // the two match best is where the line ends, and the typed text past
        // that point is drawn but was not recognized.
        let missingRange = 0...max(0, min(maximumMissingCharacters, typed.count - minimumLineCharacters))

        var best: (line: RecognizedLine, score: Double, missing: Int)?
        for line in lines {
            let recognized = normalized(line.text)
            // A line longer than the paragraph holds other text too.
            guard recognized.count >= 2, recognized.count <= typed.count + 2 else { continue }
            var lineBest: (score: Double, missing: Int)?
            for missing in missingRange {
                let drawn = typed.dropLast(missing)
                let length = min(recognized.count, drawn.count, comparedCharacters)
                let score = similarity(String(recognized.suffix(length)), String(drawn.suffix(length)))
                if score > (lineBest?.score ?? -1) { lineBest = (score, missing) }
            }
            guard let lineBest, lineBest.score >= minimumSimilarity else { continue }
            if let current = best, !isBetter(line, score: lineBest.score, than: current.line, score: current.score) {
                continue
            }
            best = (line, lineBest.score, lineBest.missing)
        }
        guard let best, best.line.maxX > best.line.minX else { return nil }
        let line = best.line
        // The typed characters drawn on this line: all of a paragraph that
        // fits on it, else about as many as were recognized, ending where
        // the line ends.
        let typedCharacters = normalizedCharacters(of: core)
        let lineEnd = typedCharacters.count - best.missing
        let recognizedCount = normalized(line.text).count
        let lineStart = lineEnd - recognizedCount <= 2 ? 0 : lineEnd - recognizedCount
        let drawn = String(core[typedCharacters[lineStart].index..<(
            lineEnd < typedCharacters.count ? typedCharacters[lineEnd].index : core.endIndex)])
            .trimmingCharacters(in: .whitespaces)
        // Sized from what was typed, not what was recognized: misreading a
        // few j as J, as fast recognition did in Viber (2026-10-09), made the
        // font 5% small, and every letter typed after it put the ghost a
        // little further behind the caret.
        guard let pointSize = fittedPointSize(of: drawn, width: line.maxX - line.minX, height: line.box.height)
            ?? fittedPointSize(of: line) else { return nil }
        let font = NSFont.systemFont(ofSize: pointSize)
        let inset = max(line.minX - fieldFrame.minX, 0)
        // What the capture lacks is drawn after the line's last letter.
        let unseenStart = best.missing > 0 ? typedCharacters[lineEnd].index : core.endIndex
        let unseen = String(core[unseenStart...]) + String(repeating: " ", count: trailingSpaces)
        let caretX = line.maxX + CotypingInlineGhostLayout.width(of: unseen, font: font)
        let lineMaxX = fieldFrame.maxX - inset
        // Unseen letters close to where the line wraps may be on the next line.
        let unseenLetters = unseen.contains { !$0.isWhitespace }
        guard caretX <= (unseenLetters ? lineMaxX - pointSize : lineMaxX) else { return nil }
        let firstWord = drawn.prefix { !$0.isWhitespace }
        let startsParagraph = lineStart == 0
        return Calibration(
            precedingText: precedingText,
            caretX: caretX,
            baseline: line.baseline ?? line.box.minY - font.descender,
            pointSize: pointSize,
            lineMinX: line.minX,
            lineMaxX: lineMaxX,
            firstWordEndX: startsParagraph
                ? nil : line.minX + CotypingInlineGhostLayout.width(of: String(firstWord), font: font))
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
        let width = CotypingInlineGhostLayout.width(
            of: change.text, font: .systemFont(ofSize: calibration.pointSize))
        let x = calibration.caretX + (change.isAddition ? width : -width)
        let typedLetters = change.isAddition && change.text.contains { !$0.isWhitespace }
        let lineEnd = typedLetters ? calibration.lineMaxX - calibration.pointSize : calibration.lineMaxX
        guard x <= lineEnd, x >= calibration.lineMinX - 1 else { return nil }
        if !change.isAddition, let firstWordEnd = calibration.firstWordEndX, x <= firstWordEnd { return nil }
        return x
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
            let natural = CotypingInlineGhostLayout.width(of: text, font: .systemFont(ofSize: size))
            guard natural > 0 else { return nil }
            size *= measured / natural
            guard (6...72).contains(size) else { return nil }
        }
        // Recognized lines are about as tall as the font's size.
        guard (0.5...1.6).contains(height / size) else { return nil }
        return size
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
            return folded.count == 1 ? Character(folded) : character
        }
    }

    /// 1 minus the edit distance per character.
    static func similarity(_ lhs: String, _ rhs: String) -> Double {
        let a = Array(lhs), b = Array(rhs)
        guard !a.isEmpty || !b.isEmpty else { return 1 }
        var previous = Array(0...b.count)
        for (i, x) in a.enumerated() {
            var current = [i + 1] + Array(repeating: 0, count: b.count)
            for (j, y) in b.enumerated() {
                current[j + 1] = min(previous[j + 1] + 1, current[j] + 1, previous[j] + (x == y ? 0 : 1))
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
    private var pending: (key: String, precedingText: String, task: Task<Void, Never>)?
    /// Whether the field last prepared may be captured, by app and kind of field.
    private var permission: (key: String, permitted: Bool)?
    /// Finds in a row that came back without the caret, for one field.
    private var failedFinds: (key: String, frame: CGRect, count: Int)?

    /// Larger fields are left alone: the caret could be anywhere in them.
    private static let maximumFieldSize = CGSize(width: 2400, height: 900)

    /// `field` with the caret found on screen, when its app reports none and
    /// the caret is still on the line it was found on.
    func resolve(_ field: CotypingField) -> CotypingField {
        guard !field.caretIsExact,
              let entry, entry.key == Self.key(for: field),
              let frame = field.inputFrameRect, Self.isSameFrame(entry.frame, frame),
              let x = CotypingVisualCaretLocator.caretX(for: entry.calibration, precedingText: field.precedingText)
        else { return field }
        var resolved = field
        resolved.caretRect = CotypingVisualCaretLocator.caretRect(for: entry.calibration, caretX: x)
        resolved.caretIsExact = true
        // Without a font from the app, the ghost uses the size measured on
        // screen, which is also what moves the caret along the line.
        if resolved.fieldStyle == nil {
            resolved.fieldStyle = CotypingFieldStyle(fontPointSize: entry.calibration.pointSize)
        }
        return resolved
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
    /// earlier find still places it. The caller has checked the privacy rules.
    func refreshIfNeeded(for field: CotypingField) {
        guard !field.caretIsExact, !resolve(field).caretIsExact,
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
        guard canFind(field), let entry, entry.key == Self.key(for: field),
              let frame = field.inputFrameRect, Self.isSameFrame(entry.frame, frame),
              let change = CotypingVisualCaretLocator.change(
                  from: entry.calibration.precedingText, to: field.precedingText),
              change.text.count >= CotypingVisualCaretLocator.refindAfterCharacters else { return }
        find(field, in: frame)
    }

    private func find(_ field: CotypingField, in frame: CGRect) {
        let key = Self.key(for: field)
        if let pending, pending.key == key, pending.precedingText == field.precedingText { return }
        pending?.task.cancel()
        let precedingText = field.precedingText
        let task = Task { [weak self] in
            let lines = await Self.recognizeLines(in: frame)
            guard let self, !Task.isCancelled else { return }
            if let lines, let calibration = CotypingVisualCaretLocator.locate(
                lines: lines, precedingText: precedingText, fieldFrame: frame) {
                self.remember(calibration, key: key, frame: frame)
            } else if lines != nil {
                self.noteFailedFind(key: key, frame: frame)
            }
            if self.pending?.key == key, self.pending?.precedingText == precedingText { self.pending = nil }
        }
        pending = (key, precedingText, task)
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

    private func remember(_ calibration: CotypingVisualCaretLocator.Calibration, key: String, frame: CGRect) {
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

    /// The field's frame captured at twice its point size, which keeps small
    /// text legible on a non-Retina display, with its lines recognized.
    private static func recognizeLines(in frame: CGRect) async -> [CotypingVisualCaretLocator.RecognizedLine]? {
        guard let image = await capture(frame) else { return nil }
        return await Task.detached(priority: .userInitiated) {
            CotypingVisualCaret.recognize(image, frame: frame)
        }.value
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

    /// The field's frame at twice its point size. Without `scalesToFit` a
    /// non-Retina display's pixels land unscaled in the image's top-left
    /// quarter (measured 2026-10-05 on a 1x display), and every recognized
    /// box comes out at half its size and place.
    nonisolated static func captureConfiguration(
        for frame: CGRect, screenFrame: CGRect, backingScale: CGFloat
    ) -> SCStreamConfiguration {
        let scale = max(2, backingScale)
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

    /// Recognized lines with their first and last characters' edges and
    /// baselines, mapped from the image onto `frame`.
    nonisolated static func recognize(
        _ image: CGImage, frame: CGRect
    ) -> [CotypingVisualCaretLocator.RecognizedLine] {
        let request = VNRecognizeTextRequest()
        // Fast recognition gives character boxes within half a point; the
        // accurate one gives only word boxes and takes far longer.
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
            // Letters without descenders sit on the baseline.
            let onBaseline = text.indices.filter { "acemnorsuvwxzABCDEFHIKLMNORSTUVWXZ".contains(text[$0]) }
            let bottoms = onBaseline.prefix(8).compactMap { box($0)?.minY }.sorted()
            return CotypingVisualCaretLocator.RecognizedLine(
                text: text, minX: firstBox.minX, maxX: lastBox.maxX,
                baseline: bottoms.isEmpty ? nil : bottoms[bottoms.count / 2],
                box: point(observation.boundingBox))
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
