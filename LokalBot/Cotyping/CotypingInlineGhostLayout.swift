import AppKit
import CoreText

nonisolated struct CotypingInlineGhostLayout: Equatable {
    struct Line: Equatable {
        let text: String
        let offset: Int
        let origin: CGPoint
        let width: CGFloat
    }

    let lines: [Line]
    let font: NSFont
    let isRightToLeft: Bool
    var isComplete = true
    var wrapEdge: CGFloat = 0

    static let fieldInset: CGFloat = 8
    static let screenMargin: CGFloat = 8
    static let maximumLines = 6
    static let fieldEdgeTolerance: CGFloat = 1

    var bounds: CGRect {
        let ascent = font.ascender
        let descent = -font.descender
        return lines.reduce(CGRect.null) { box, line in
            let minX = isRightToLeft ? line.origin.x - line.width : line.origin.x
            return box.union(CGRect(
                x: minX, y: line.origin.y - descent, width: max(line.width, 1), height: ascent + descent))
        }
    }

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
        let lowestBaseline = inputFrameRect.map { $0.standardized.minY - font.descender - fieldEdgeTolerance }
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

    static func firstBaseline(caretRect: CGRect, font: NSFont) -> CGFloat {
        let layoutManager = NSLayoutManager()
        if abs(caretRect.height - layoutManager.defaultLineHeight(for: font)) <= 0.75 {
            return caretRect.maxY - layoutManager.defaultBaselineOffset(for: font)
        }
        return caretRect.midY - (font.ascender + font.descender) / 2
    }

    static func linePitch(caretRect: CGRect, font: NSFont) -> CGFloat {
        max(caretRect.height, NSLayoutManager().defaultLineHeight(for: font))
    }

    static func width(of text: String, font: NSFont) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
        return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    static func displayText(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            let words = line.split(whereSeparator: \.isWhitespace)
            guard !words.isEmpty else { return "" }
            let joined = words.joined(separator: " ")
            return line.first?.isWhitespace == true ? " " + joined : joined
        }.joined(separator: "\n")
    }

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

    private static func fittingPrefix(
        of text: Substring, width available: CGFloat, font: NSFont, mustTakeSomething: Bool
    ) -> Substring {
        let paragraph = text.prefix { $0 != "\n" }
        guard !paragraph.isEmpty else { return paragraph }
        if width(of: String(paragraph), font: font) <= available { return paragraph }
        var fitted = paragraph.prefix(0)
        var index = paragraph.startIndex
        while index < paragraph.endIndex {
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
