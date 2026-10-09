import AppKit
import CoreText

/// Where each line of an inline suggestion is drawn. The first line continues
/// the caret's line on the field's own baseline, starting exactly at the caret,
/// so the suggestion reads as the next characters of the text. What does not
/// fit before the field's trailing edge wraps onto the following lines at the
/// field's text edge, where the host will put it once accepted, but only onto
/// lines that hold no text and lie inside the field. Coordinates are global
/// Cocoa points (bottom-left origin).
nonisolated struct CotypingInlineGhostLayout: Equatable {
    struct Line: Equatable {
        let text: String
        /// Where `text` starts in the displayed suggestion, in characters.
        let offset: Int
        /// The baseline's leading end: its left end, or its right end for
        /// right-to-left text.
        let origin: CGPoint
        let width: CGFloat
    }

    let lines: [Line]
    let font: NSFont
    let isRightToLeft: Bool
    /// Every character of the text has a place. When false, the lines hold
    /// only its start, or nothing: what is left over had nowhere to go that
    /// covers no text.
    var isComplete = true
    /// Where wrapped lines start: the field's text edge.
    var wrapEdge: CGFloat = 0

    /// Kept clear inside the field's edges, where most fields pad their text.
    static let fieldInset: CGFloat = 8
    static let screenMargin: CGFloat = 8
    /// A suggestion never needs more lines than this.
    static let maximumLines = 6
    /// Slack for a wrapped line's glyphs against the field's bottom edge.
    static let fieldEdgeTolerance: CGFloat = 1

    /// The glyph boxes of every line together.
    var bounds: CGRect {
        let ascent = font.ascender
        let descent = -font.descender
        return lines.reduce(CGRect.null) { box, line in
            let minX = isRightToLeft ? line.origin.x - line.width : line.origin.x
            return box.union(CGRect(
                x: minX, y: line.origin.y - descent, width: max(line.width, 1), height: ascent + descent))
        }
    }

    /// - Parameters:
    ///   - precedingLine: the field's text from the start of the caret's
    ///     paragraph to the caret. When it fits on one line it shows where the
    ///     field's text starts, which wrapped lines then line up with.
    ///   - linesBelowAreFree: no text follows the caret, so the lines under
    ///     it are empty. Otherwise nothing wraps onto them.
    ///   - knownWrapEdge: where wrapped lines start, when an earlier layout
    ///     for the same paragraph already found it.
    static func make(
        text: String,
        font: NSFont,
        caretRect: CGRect,
        inputFrameRect: CGRect?,
        precedingLine: String = "",
        visible: CGRect?,
        isRightToLeft: Bool,
        linesBelowAreFree: Bool = true,
        wrapEdge knownWrapEdge: CGFloat? = nil
    ) -> CotypingInlineGhostLayout {
        let display = displayText(text)
        let span = textSpan(caretRect: caretRect, inputFrameRect: inputFrameRect, visible: visible)
        let anchor = isRightToLeft ? caretRect.minX : caretRect.maxX
        let wrapEdge = knownWrapEdge ?? wrapEdge(
            precedingLine: precedingLine, anchor: anchor, font: font,
            inputFrameRect: inputFrameRect, span: span, isRightToLeft: isRightToLeft)
        let pitch = linePitch(caretRect: caretRect, font: font)
        var baseline = firstBaseline(caretRect: caretRect, font: font)
        // A wrapped line's glyphs stay inside the field: below it is other
        // interface, such as a toolbar under a chat box that grows.
        let lowestBaseline = inputFrameRect.map { $0.standardized.minY - font.descender - fieldEdgeTolerance }
        // Text that goes on with the word at the caret moves with that word
        // when it wraps.
        let continuesWord = precedingLine.last.map { !$0.isWhitespace } == true
            && display.first.map { !$0.isWhitespace } == true

        var lines: [Line] = []
        var remaining = Substring(display)
        var offset = 0
        var lineStart = anchor
        var budget = isRightToLeft ? anchor - span.lowerBound : span.upperBound - anchor
        var isFirstLine = true
        while !remaining.isEmpty, lines.count < maximumLines {
            if !isFirstLine {
                guard linesBelowAreFree, lowestBaseline.map({ baseline >= $0 }) ?? true else { break }
            }
            let piece = fittingPrefix(of: remaining, width: budget, font: font, mustTakeSomething: !isFirstLine)
            if isFirstLine, piece.isEmpty, continuesWord {
                // The rest of the word at the caret does not fit after it, so
                // the app will move the whole word to the next line, and no
                // place on screen shows where this text will go.
                return CotypingInlineGhostLayout(
                    lines: [], font: font, isRightToLeft: isRightToLeft, isComplete: false, wrapEdge: wrapEdge)
            }
            if !piece.isEmpty {
                let pieceText = String(piece)
                lines.append(Line(
                    text: pieceText, offset: offset, origin: CGPoint(x: lineStart, y: baseline),
                    width: width(of: pieceText, font: font)))
                offset += piece.count
                remaining = remaining.dropFirst(piece.count)
            }
            // A line break or the space the host wraps at is not drawn.
            let skipped = remaining.prefix { $0 == " " || $0 == "\n" }
            offset += skipped.count
            remaining = remaining.dropFirst(skipped.count)
            baseline -= pitch
            lineStart = wrapEdge
            budget = isRightToLeft ? wrapEdge - span.lowerBound : span.upperBound - wrapEdge
            isFirstLine = false
        }
        return CotypingInlineGhostLayout(
            lines: lines, font: font, isRightToLeft: isRightToLeft, isComplete: remaining.isEmpty, wrapEdge: wrapEdge)
    }

    /// The longest start of `text` that can be drawn whole, ending after a
    /// word, with its layout. `layout` lays out a candidate at the caret.
    /// Nil when nothing can be drawn, or when `allowsPartial` is off and the
    /// whole of `text` cannot.
    static func longestDrawable(
        _ text: String,
        allowsPartial: Bool,
        layout: (String) -> CotypingInlineGhostLayout
    ) -> (text: String, layout: CotypingInlineGhostLayout)? {
        let whole = layout(text)
        if whole.isComplete, !whole.lines.isEmpty { return (text, whole) }
        guard allowsPartial else { return nil }
        for prefix in wordPrefixes(of: text).reversed() where prefix.count < text.count {
            let candidate = layout(prefix)
            if candidate.isComplete, !candidate.lines.isEmpty { return (prefix, candidate) }
        }
        return nil
    }

    /// Every start of `text` that ends after a word, shortest first.
    static func wordPrefixes(of text: String) -> [String] {
        var prefixes: [String] = []
        var index = text.startIndex
        while index < text.endIndex {
            while index < text.endIndex, text[index].isWhitespace { index = text.index(after: index) }
            guard index < text.endIndex else { break }
            while index < text.endIndex, !text[index].isWhitespace { index = text.index(after: index) }
            prefixes.append(String(text[..<index]))
        }
        return prefixes
    }

    /// Where the caret is once `typed` is in the field: at the end of
    /// `typed` laid out from the caret, which is where the app puts it, since
    /// the app wraps it by the same rule. Nil when that is only known once
    /// the app shows it: text with a line break, or the rest of a word that
    /// does not fit on the caret's line, which the app moves to the next line
    /// together with the start of the word.
    ///
    /// The arguments are those the ghost on screen was laid out with.
    static func caretRect(
        afterTyping typed: String,
        font: NSFont,
        caretRect: CGRect,
        inputFrameRect: CGRect?,
        precedingLine: String,
        visible: CGRect?,
        isRightToLeft: Bool,
        linesBelowAreFree: Bool,
        wrapEdge: CGFloat?
    ) -> CGRect? {
        guard !typed.isEmpty, !typed.contains(where: \.isNewline) else { return nil }
        let typedLayout = make(
            text: typed, font: font, caretRect: caretRect, inputFrameRect: inputFrameRect,
            precedingLine: precedingLine, visible: visible, isRightToLeft: isRightToLeft,
            linesBelowAreFree: linesBelowAreFree, wrapEdge: wrapEdge)
        guard typedLayout.isComplete else { return nil }
        let anchor = isRightToLeft ? caretRect.minX : caretRect.maxX
        let firstLineBaseline = firstBaseline(caretRect: caretRect, font: font)
        // Spaces are never drawn at the end of a line, but the app puts the
        // caret after every one typed.
        let spaces = width(of: String(typed.reversed().prefix { $0.isWhitespace }), font: font)
        let end: CGPoint
        if let last = typedLayout.lines.last {
            let lineEnd = isRightToLeft ? last.origin.x - last.width : last.origin.x + last.width
            end = CGPoint(x: lineEnd, y: last.origin.y)
        } else {
            end = CGPoint(x: anchor, y: firstLineBaseline)
        }
        let x = isRightToLeft ? end.x - spaces : end.x + spaces
        return caretRect.offsetBy(dx: x - anchor, dy: end.y - firstLineBaseline)
    }

    /// The baseline of the caret's line. AppKit text reports a caret exactly
    /// one default line tall, with the baseline a fixed distance below its top;
    /// web engines report about the glyph box, which is centered instead.
    static func firstBaseline(caretRect: CGRect, font: NSFont) -> CGFloat {
        let layoutManager = NSLayoutManager()
        if abs(caretRect.height - layoutManager.defaultLineHeight(for: font)) <= 0.75 {
            return caretRect.maxY - layoutManager.defaultBaselineOffset(for: font)
        }
        return caretRect.midY - (font.ascender + font.descender) / 2
    }

    /// Distance between wrapped lines: the caret's own line when it spans one,
    /// else the font's default line.
    static func linePitch(caretRect: CGRect, font: NSFont) -> CGFloat {
        max(caretRect.height, NSLayoutManager().defaultLineHeight(for: font))
    }

    static func width(of text: String, font: NSFont) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
        return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    /// Whitespace runs drawn as one space, keeping a leading space and line breaks.
    static func displayText(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            let words = line.split(whereSeparator: \.isWhitespace)
            guard !words.isEmpty else { return "" }
            let joined = words.joined(separator: " ")
            return line.first?.isWhitespace == true ? " " + joined : joined
        }.joined(separator: "\n")
    }

    /// Horizontal room for text: inside the field when it reports a frame wide
    /// enough to hold a line, and always on screen.
    private static func textSpan(caretRect: CGRect, inputFrameRect: CGRect?, visible: CGRect?) -> ClosedRange<CGFloat> {
        let screen = visible ?? CGRect(x: caretRect.minX - 400, y: caretRect.minY - 300, width: 1200, height: 600)
        var minX = screen.minX + screenMargin
        var maxX = screen.maxX - screenMargin
        if let input = inputFrameRect?.standardized, input.width > fieldInset * 2 + 48 {
            minX = max(minX, input.minX + fieldInset)
            maxX = min(maxX, input.maxX - fieldInset)
        }
        return minX...max(minX, maxX)
    }

    /// Where wrapped lines start. A paragraph that fits on one line ends at
    /// the caret, so its width back from the caret finds the field's text edge.
    private static func wrapEdge(
        precedingLine: String, anchor: CGFloat, font: NSFont,
        inputFrameRect: CGRect?, span: ClosedRange<CGFloat>, isRightToLeft: Bool
    ) -> CGFloat {
        let paragraph = precedingLine.split(separator: "\n", omittingEmptySubsequences: false).last.map(String.init) ?? ""
        if let input = inputFrameRect?.standardized, !paragraph.isEmpty {
            let lineWidth = width(of: paragraph, font: font)
            if isRightToLeft {
                let edge = anchor + lineWidth
                if edge <= input.maxX + 1, edge >= input.maxX - 40 { return edge }
            } else {
                let edge = anchor - lineWidth
                if edge >= input.minX - 1, edge <= input.minX + 40 { return edge }
            }
        }
        return isRightToLeft ? span.upperBound : span.lowerBound
    }

    /// The longest run of whole words from the start of `text` that fits in
    /// `width`, stopping at a line break. A word wider than a whole line is
    /// split between characters when `mustTakeSomething` is set.
    private static func fittingPrefix(
        of text: Substring, width available: CGFloat, font: NSFont, mustTakeSomething: Bool
    ) -> Substring {
        let paragraph = text.prefix { $0 != "\n" }
        guard !paragraph.isEmpty else { return paragraph }
        if width(of: String(paragraph), font: font) <= available { return paragraph }
        var fitted = paragraph.prefix(0)
        var index = paragraph.startIndex
        while index < paragraph.endIndex {
            // One word, with the spaces before it.
            var end = index
            while end < paragraph.endIndex, paragraph[end] == " " { end = paragraph.index(after: end) }
            while end < paragraph.endIndex, paragraph[end] != " " { end = paragraph.index(after: end) }
            let candidate = paragraph[paragraph.startIndex..<end]
            guard width(of: String(candidate), font: font) <= available else { break }
            fitted = candidate
            index = end
        }
        if fitted.isEmpty, mustTakeSomething {
            let characters = paragraph.drop { $0 == " " }
            var taken = characters.prefix(1)
            for count in 2...max(2, characters.count) where count <= characters.count {
                let candidate = characters.prefix(count)
                guard width(of: String(candidate), font: font) <= available else { break }
                taken = candidate
            }
            return paragraph[paragraph.startIndex..<taken.endIndex]
        }
        return fitted
    }
}
