import AppKit

nonisolated enum CotypingTextLeafCaret {
    struct Leaf {
        let frame: CGRect
        let text: String
    }

    private static let lineHeightBand: ClosedRange<CGFloat> = 4...64
    private static let containmentTolerance: CGFloat = 4
    private static let runHeightPerPointSize: CGFloat = 1.5
    private static let wrappedRunWidthRatio: CGFloat = 1.4

    static func caretIsAtTextEnd(fieldText: String, caretLocation: Int) -> Bool {
        caretLocation == trimmedUTF16Length(of: fieldText)
    }

    static func caretRect(
        elementFrame: CGRect,
        leaves: [Leaf],
        fieldText: String,
        caretLocation: Int,
        isRightToLeft: Bool
    ) -> CGRect? {
        guard caretIsAtTextEnd(fieldText: fieldText, caretLocation: caretLocation) else {
            return nil
        }
        guard let leaf = leaves.last(where: { !withoutTrailingSpaces(runText($0.text)).isEmpty }) else {
            return nil
        }
        let leafText = runText(leaf.text)
        let leafCore = withoutTrailingSpaces(leafText)
        let fieldTail = runText(fieldText)
        let missingSpaces = trailingSpaceCount(fieldTail) - trailingSpaceCount(leafText)
        guard missingSpaces >= 0, withoutTrailingSpaces(fieldTail).hasSuffix(leafCore) else { return nil }
        guard leaf.frame.width > 0,
              lineHeightBand.contains(leaf.frame.height),
              elementFrame
                  .insetBy(dx: -containmentTolerance, dy: -containmentTolerance)
                  .contains(leaf.frame),
              !isWrapped(leaf, text: leafCore) else {
            return nil
        }
        let gap = CGFloat(missingSpaces) * spaceWidth(in: leaf, text: leafCore)
        let x = isRightToLeft ? leaf.frame.minX - gap : leaf.frame.maxX + gap
        return CGRect(x: x, y: leaf.frame.minY, width: 1, height: leaf.frame.height)
    }

    private static func isWrapped(_ leaf: Leaf, text: String) -> Bool {
        let font = NSFont.systemFont(ofSize: leaf.frame.height / runHeightPerPointSize)
        return CotypingInlineGhostLayout.width(of: text, font: font) > leaf.frame.width * wrappedRunWidthRatio
    }

    private static func spaceWidth(in leaf: Leaf, text: String) -> CGFloat {
        let font = NSFont.systemFont(ofSize: 12)
        let textWidth = CotypingInlineGhostLayout.width(of: text, font: font)
        guard textWidth > 0 else { return 0 }
        return leaf.frame.width * CotypingInlineGhostLayout.width(of: " ", font: font) / textWidth
    }

    private static func runText(_ text: String) -> String {
        trimmedText(text).replacingOccurrences(of: "\u{00A0}", with: " ")
    }

    private static func trailingSpaceCount(_ text: String) -> Int {
        text.reversed().prefix { $0 == " " }.count
    }

    private static func withoutTrailingSpaces(_ text: String) -> String {
        String(text.dropLast(trailingSpaceCount(text)))
    }

    private static func trimmedText(_ text: String) -> String {
        var result = text
        while let last = result.unicodeScalars.last, CharacterSet.newlines.contains(last) {
            result.unicodeScalars.removeLast()
        }
        return result
    }

    private static func trimmedUTF16Length(of text: String) -> Int {
        (trimmedText(text) as NSString).length
    }
}
