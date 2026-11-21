import AppKit
import ScreenCaptureKit
import Vision

nonisolated enum CotypingVisualCaretLocator {
    struct RecognizedLine: Equatable {
        var text: String
        var minX: CGFloat
        var maxX: CGFloat
        var baseline: CGFloat?
        var box: CGRect
        var lastCharacterMinX: CGFloat?
        var characterBeforeLastMaxX: CGFloat?
        var tailMinX: CGFloat?
        var edgesAreMeasured = false
        var inkHasMoreWords = false
    }

    static let caretLookalikes: Set<Character> = ["|", "I", "l", "1", "!", "[", "]", "ǀ", "¦"]

    struct Calibration: Equatable {
        var precedingText: String
        var caretX: CGFloat
        var baseline: CGFloat
        var pointSize: CGFloat
        var lineMinX: CGFloat
        var lineMaxX: CGFloat
        var firstWordEndX: CGFloat?
        var sizeIsReliable = false
        var textStartX: CGFloat?
    }

    static let minimumSimilarity = 0.75
    static let comparedCharacters = 48
    static let maximumDrift = 40
    static let refindAfterCharacters = 12
    static let remeasureAfterCharacters = 4
    static let minimumLineCharacters = 3
    static let minimumMeasuringCharacters = 8
    static let minimumTailCharacters = 8
    static let smallestLikelyPointSize: CGFloat = 10
    static let minimumCharactersToCountAMiss = 8
    static let maximumMissingCharacters = 8
    static let maximumFailedFinds = 3

    static func caretLineIsCyrillic(_ precedingText: String) -> Bool {
        caretLine(of: precedingText).core.unicodeScalars.contains { (0x0400...0x052F).contains($0.value) }
    }

    static func missCounts(for precedingText: String) -> Bool {
        caretLine(of: precedingText).typed.count >= minimumCharactersToCountAMiss
    }

    static func hasEnoughText(_ precedingText: String) -> Bool {
        caretLine(of: precedingText).typed.count >= minimumLineCharacters
    }

    private static func caretLine(of precedingText: String) -> (typed: String, core: String, trailingSpaces: Int) {
        let paragraph = precedingText.split(separator: "\n", omittingEmptySubsequences: false).last.map(String.init) ?? ""
        let trailingSpaces = paragraph.reversed().prefix { $0 == " " || $0 == "\u{00A0}" }.count
        let core = String(paragraph.dropLast(trailingSpaces))
        return (normalized(core), core, trailingSpaces)
    }

    private struct TypedCharacter {
        let character: Character
        let index: String.Index
        let isUnreadable: Bool
    }

    private static func isUnreadable(_ character: Character) -> Bool {
        guard character.isLetter, !character.isASCII,
              let scalar = String(character).precomposedStringWithCanonicalMapping.unicodeScalars.first
        else { return false }
        return (0x00C0...0x024F).contains(scalar.value) || (0x1E00...0x1EFF).contains(scalar.value)
            || isCyrillicWithoutAModel(character, scalar: scalar)
    }

    private static func isCyrillicWithoutAModel(_ character: Character, scalar: Unicode.Scalar) -> Bool {
        (0x0400...0x052F).contains(scalar.value) && !russianAndUkrainianLetters.contains(character.lowercased())
    }

    private static let russianAndUkrainianLetters = Set("абвгдеёжзийклмнопрстуфхцчшщъыьэюяєіїґ".map(String.init))

    private static func typedCharacters(of core: String) -> [TypedCharacter] {
        normalizedCharacters(of: core).map {
            TypedCharacter(character: $0.character, index: $0.index, isUnreadable: isUnreadable(core[$0.index]))
        }
    }

    private static func recognizedCharacters(of text: String) -> [Character] {
        normalized(text).filter { $0 != " " }
    }

    static func locate(lines: [RecognizedLine], precedingText: String, fieldFrame: CGRect) -> Calibration? {
        let (typed, core, trailingSpaces) = caretLine(of: precedingText)
        guard typed.count >= minimumLineCharacters else { return nil }
        let typedCharacters = typedCharacters(of: core)
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
        let textMaxX = endsWithCaret ? line.characterBeforeLastMaxX ?? line.maxX : line.maxX
        let lineEnd = typedCharacters.count - best.alignment.missing
        let recognizedCount = best.alignment.recognizedCount
        let recognized = start(ofLast: recognizedCount, before: lineEnd, in: typedCharacters)
        let lost = typedCharacters[..<recognized.index].filter { $0.character != " " }.count
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
        var tail: (text: String, minX: CGFloat)?
        if startsParagraph, !countsAgree, recognizedCount >= minimumTailCharacters, let tailMinX = line.tailMinX {
            let start = start(ofLast: recognizedCount - 2, before: lineEnd, in: typedCharacters).index
            tail = (typedText(start), tailMinX)
        }
        var fitted = fittedPointSize(
            of: tail?.text ?? drawn, width: textMaxX - (tail?.minX ?? line.minX), height: line.box.height)
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
            let unseenStart = best.alignment.missing > 0 ? typedCharacters[lineEnd].index : core.endIndex
            let unseen = String(core[unseenStart...]) + String(repeating: " ", count: trailingSpaces)
            unseenLetters = unseen.contains { !$0.isWhitespace }
            let bearing = drawn.last.map { rightSideBearing(of: $0, font: font) } ?? 0
            caretX = line.maxX + bearing + advance(of: unseen, after: drawn, font: font)
        }
        let lineMaxX = fieldFrame.maxX - inset
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

    private struct Alignment {
        var score: Double
        var missing: Int
        var endsWithCaret: Bool
        var recognizedCount: Int
    }

    private static func alignment(
        of line: RecognizedLine, typed: [TypedCharacter], missingRange: ClosedRange<Int>
    ) -> Alignment? {
        var best: Alignment?
        let recognized = recognizedCharacters(of: line.text)
        let printed = typed.filter { $0.character != " " }
        let missingRange = line.inkHasMoreWords ? 0...0 : missingRange
        let extraReadings = line.edgesAreMeasured ? printed.filter(\.isUnreadable).count + 2 : 0
        if recognized.count >= 2, recognized.count <= printed.count + max(extraReadings, 2) {
            for missing in missingRange where missing < typed.count {
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

    static func advance(of text: String, after preceding: String, font: NSFont) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        let context = preceding.last.map(String.init) ?? ""
        return CotypingInlineGhostLayout.width(of: context + text, font: font)
            - CotypingInlineGhostLayout.width(of: context, font: font)
    }

    static func leftSideBearing(of character: Character?, font: NSFont) -> CGFloat {
        guard let character, !character.isWhitespace else { return 0 }
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: String(character), attributes: [.font: font]))
        let ink = CTLineGetImageBounds(line, nil)
        guard !ink.isNull, ink.width > 0 else { return 0 }
        return min(max(ink.minX, -1), 3)
    }

    static func rightSideBearing(of character: Character, font: NSFont) -> CGFloat {
        guard !character.isWhitespace else { return 0 }
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: String(character), attributes: [.font: font]))
        let advance = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        let ink = CTLineGetImageBounds(line, nil)
        guard !ink.isNull, ink.width > 0 else { return 0 }
        return min(max(advance - ink.maxX, -1), 3)
    }

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

    static func caretX(for calibration: Calibration, precedingText: String) -> CGFloat? {
        guard let change = change(from: calibration.precedingText, to: precedingText) else { return nil }
        guard change.text.count <= maximumDrift, !change.text.contains(where: \.isNewline) else { return nil }
        let shorter = change.isAddition ? calibration.precedingText : precedingText
        let width = advance(of: change.text, after: shorter, font: .systemFont(ofSize: calibration.pointSize))
        let x = calibration.caretX + (change.isAddition ? width : -width)
        let typedLetters = change.isAddition && change.text.contains { !$0.isWhitespace }
        let lineEnd = typedLetters ? calibration.lineMaxX - calibration.pointSize : calibration.lineMaxX
        guard x <= lineEnd, x >= calibration.lineMinX - 1 else { return nil }
        if !change.isAddition, let firstWordEnd = calibration.firstWordEndX, x <= firstWordEnd { return nil }
        return x
    }

    static func caretXFromLineStart(for calibration: Calibration, precedingText: String) -> CGFloat? {
        guard let start = calibration.textStartX, !precedingText.contains(where: \.isNewline) else { return nil }
        let width = CotypingInlineGhostLayout.width(of: precedingText, font: .systemFont(ofSize: calibration.pointSize))
        let x = start + width
        return x <= calibration.lineMaxX - calibration.pointSize ? x : nil
    }

    static func caretRect(for calibration: Calibration, caretX: CGFloat) -> CGRect {
        let font = NSFont.systemFont(ofSize: calibration.pointSize)
        let layout = NSLayoutManager()
        let height = layout.defaultLineHeight(for: font)
        let top = calibration.baseline + layout.defaultBaselineOffset(for: font)
        return CGRect(x: caretX, y: top - height, width: 0, height: height)
    }

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

    static func fittedPointSize(of line: RecognizedLine) -> CGFloat? {
        fittedPointSize(
            of: line.text.trimmingCharacters(in: .whitespaces), width: line.maxX - line.minX, height: line.box.height)
    }

    static func fittedPointSize(of text: String, width measured: CGFloat, height: CGFloat) -> CGFloat? {
        guard measured > 0, height > 0, !text.isEmpty else { return nil }
        var size = height
        for _ in 0..<3 {
            let natural = inkWidth(of: text, font: .systemFont(ofSize: size))
            guard natural > 0 else { return nil }
            size *= measured / natural
            guard (6...72).contains(size) else { return nil }
        }
        guard (0.5...1.6).contains(height / size) else { return nil }
        return size
    }

    static func inkWidth(of text: String, font: NSFont) -> CGFloat {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
        let ink = CTLineGetImageBounds(line, nil)
        return ink.isNull ? 0 : ink.width
    }

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

    static func normalized(_ text: String) -> String {
        String(normalizedCharacters(of: text).map(\.character))
    }

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

    private static let latinLookalikes: [Character: Character] = [
        "а": "a", "в": "b", "е": "e", "і": "i", "ј": "j", "к": "k", "м": "m", "н": "h",
        "о": "o", "р": "p", "с": "c", "т": "t", "у": "y", "х": "x", "ѕ": "s",
    ]

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

@MainActor
final class CotypingVisualCaret {
    private struct Entry {
        let key: String
        let frame: CGRect
        let calibration: CotypingVisualCaretLocator.Calibration
    }

    private var entry: Entry?
    private var measured: Entry?
    private var pending: (key: String, frame: CGRect, task: Task<Void, Never>)?
    private var permission: (key: String, permitted: Bool)?
    private var failedFinds: (key: String, frame: CGRect, count: Int)?

    private static let maximumFieldSize = CGSize(width: 2400, height: 900)

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
        if resolved.fieldStyle == nil {
            resolved.fieldStyle = CotypingFieldStyle(fontPointSize: calibration.pointSize)
        }
        return resolved
    }

    private func trackedCaretX(for field: CotypingField) -> CGFloat? {
        current(entry, for: field).flatMap {
            CotypingVisualCaretLocator.caretX(for: $0.calibration, precedingText: field.precedingText)
        }
    }

    private func current(_ candidate: Entry?, for field: CotypingField) -> Entry? {
        guard let candidate, candidate.key == Self.key(for: field),
              let frame = field.inputFrameRect, Self.isSameFrame(candidate.frame, frame) else { return nil }
        return candidate
    }

    func notePermission(_ permitted: Bool, for field: CotypingField) {
        permission = (Self.key(for: field), permitted)
    }

    func canFind(_ field: CotypingField, screenCaptureAllowed: () -> Bool = { CGPreflightScreenCaptureAccess() }) -> Bool {
        let key = Self.key(for: field)
        guard !field.caretIsExact, permission?.key == key, permission?.permitted == true,
              failedFindCount(key: key, frame: field.inputFrameRect) < CotypingVisualCaretLocator.maximumFailedFinds
        else { return false }
        return Self.isFindable(field) && screenCaptureAllowed()
    }

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

    func refreshIfNeeded(for field: CotypingField) {
        guard !field.caretIsExact, isDueForAFind(field),
              Self.isFindable(field), let frame = field.inputFrameRect,
              CotypingVisualCaretLocator.hasEnoughText(field.precedingText),
              CGPreflightScreenCaptureAccess() else { return }
        find(field, in: frame)
    }

    func refreshIfDrifted(for field: CotypingField) {
        guard canFind(field), current(entry, for: field) != nil, isDueForAFind(field),
              let frame = field.inputFrameRect else { return }
        find(field, in: frame)
    }

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

    private static func isFindable(_ field: CotypingField) -> Bool {
        guard let frame = field.inputFrameRect else { return false }
        return frame.width >= 40 && frame.height >= 12
            && frame.width <= maximumFieldSize.width && frame.height <= maximumFieldSize.height
            && CotypingRenderModePolicy.isCaretAtEndOfLine(trailingText: field.trailingText)
            && !CotypingTextDirectionDetector.isRightToLeft(field.precedingText)
    }

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

    private static func key(for field: CotypingField) -> String {
        "\(field.processID)|\(field.role)"
    }

    private static func isSameFrame(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.minX - rhs.minX) <= 0.5 && abs(lhs.minY - rhs.minY) <= 0.5
            && abs(lhs.width - rhs.width) <= 0.5 && abs(lhs.height - rhs.height) <= 0.5
    }

    private static func recognizeLines(
        in frame: CGRect, precedingText: String
    ) async -> [CotypingVisualCaretLocator.RecognizedLine]? {
        guard let image = await capture(frame) else { return nil }
        let input = CapturedField(image: image)
        return await TextRecognitionQueue.shared.run(
            "autocomplete caret", urgency: .interactive, within: recognitionLimit
        ) {
            CotypingVisualCaret.recognize(input.image, frame: frame, precedingText: precedingText)
        }
    }

    private static let recognitionLimit: TimeInterval = 5

    private struct CapturedField: @unchecked Sendable {
        let image: CGImage
    }

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
        let filter = SCContentFilter(display: display, excludingWindows: [])
        return try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    nonisolated static func captureConfiguration(
        for frame: CGRect, screenFrame: CGRect, backingScale: CGFloat
    ) -> SCStreamConfiguration {
        let scale = captureScale(for: frame, backingScale: backingScale)
        let config = SCStreamConfiguration()
        config.sourceRect = CGRect(
            x: frame.minX - screenFrame.minX, y: screenFrame.maxY - frame.maxY,
            width: frame.width, height: frame.height)
        config.width = Int((frame.width * scale).rounded())
        config.height = Int((frame.height * scale).rounded())
        config.scalesToFit = true
        config.showsCursor = false
        return config
    }

    nonisolated static func captureScale(for frame: CGRect, backingScale: CGFloat) -> CGFloat {
        guard backingScale < 2 else { return backingScale }
        return frame.width * frame.height * 9 <= 4_000_000 ? 3 : 2
    }

    nonisolated static func recognize(
        _ image: CGImage, frame: CGRect
    ) -> [CotypingVisualCaretLocator.RecognizedLine] {
        let request = VNRecognizeTextRequest()
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
