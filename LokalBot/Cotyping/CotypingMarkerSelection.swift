import Foundation

/// A selection synthesized from WebKit/Chromium AX text markers.
///
/// `text` is already windowed around the caret, and `selection` indexes into
/// that same text. Keeping those two values in the same coordinate space lets
/// the normal cotyping context split run without knowing whether the host used
/// native ranges or opaque text markers.
struct CotypingMarkerSelection: Equatable, Sendable {
    let text: String
    let selection: NSRange
    let context: CotypingTextContext?
}

enum CotypingMarkerSelectionSynthesizer {
    static let defaultWindow = CotypingAXHelper.maxPrecedingCharacters

    static func make(
        beforeCaret: String,
        selected: String,
        afterCaret: String,
        window: Int = defaultWindow
    ) -> CotypingMarkerSelection {
        let windowedBefore = suffix(of: beforeCaret, limit: window)
        let windowedAfter = prefix(of: afterCaret, limit: window)
        let text = windowedBefore + selected + windowedAfter

        return CotypingMarkerSelection(
            text: text,
            selection: NSRange(
                location: (windowedBefore as NSString).length,
                length: (selected as NSString).length),
            context: selected.isEmpty ? CotypingAcceptanceContentBounds.context(
                in: beforeCaret + afterCaret,
                selection: NSRange(location: (beforeCaret as NSString).length, length: 0)) : nil)
    }

    private static func suffix(of string: String, limit: Int) -> String {
        let ns = string as NSString
        guard ns.length > limit else { return string }
        let range = ns.rangeOfComposedCharacterSequences(
            for: NSRange(location: ns.length - limit, length: limit))
        return ns.substring(with: range)
    }

    private static func prefix(of string: String, limit: Int) -> String {
        let ns = string as NSString
        guard ns.length > limit else { return string }
        let range = ns.rangeOfComposedCharacterSequences(
            for: NSRange(location: 0, length: limit))
        return ns.substring(with: range)
    }
}

/// Moves a caret counted without paragraph breaks into a value that has them.
///
/// Chromium counts a rich-text field's selection, and the text it returns for
/// `AXStringForRange`, over the field's text without the line breaks it puts
/// between paragraphs, while the field's `AXValue` has them. Split at the
/// reported offset, the value put the caret one character early for every
/// paragraph above it: in a Reddit post on 2026-10-21, a suggestion after
/// "elabor" began "rate", and the "r" left after the caret made it look
/// mid-line, so the suggestion showed in a popup over the text.
enum CotypingParagraphBreakAlignment {
    private static let lineFeed: UInt16 = 0x0A
    private static let objectReplacement: UInt16 = 0xFFFC

    /// Where the caret is in `value`, given the text before it in the count
    /// the selection uses, or nil when the two do not line up that way.
    static func caretLocation(in value: String, textBeforeCaret: String) -> Int? {
        let value = Array(value.utf16)
        var location = 0
        for unit in textBeforeCaret.utf16 {
            while location < value.count, value[location] != unit, value[location] == lineFeed {
                location += 1
            }
            if location < value.count, value[location] == unit {
                location += 1
            } else if unit != objectReplacement {
                return nil
            }
        }
        return location
    }
}
