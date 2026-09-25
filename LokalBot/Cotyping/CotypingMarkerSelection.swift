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
