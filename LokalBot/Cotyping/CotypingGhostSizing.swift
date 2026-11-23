import AppKit

nonisolated enum CotypingGhostFontSizing {
    static let minimumPointSize: CGFloat = 8
    static let maximumPointSize: CGFloat = 48
    static let maximumEstimatedPointSize: CGFloat = 16
    static let pointSizePerCaretHeight: CGFloat = 1 / 1.2

    static func font(for style: CotypingFieldStyle?, caretHeight: CGFloat, caretIsExact: Bool) -> NSFont {
        let size = min(maximumPointSize, max(minimumPointSize, pointSize(
            for: style, caretHeight: caretHeight, caretIsExact: caretIsExact)))
        return style?.fontName.flatMap { resolvedFont(named: $0, size: size) } ?? .systemFont(ofSize: size)
    }

    static func resolvedFont(named name: String, size: CGFloat) -> NSFont? {
        if let exact = NSFont(name: name, size: size) {
            return exact
        }
        for attribute in [NSFontDescriptor.AttributeName.visibleName, .family] {
            let descriptor = NSFontDescriptor(fontAttributes: [attribute: name])
            if let matched = descriptor.matchingFontDescriptor(withMandatoryKeys: [attribute]),
               let font = NSFont(descriptor: matched, size: size) {
                return font
            }
        }
        return nil
    }

    static func pointSize(for style: CotypingFieldStyle?, caretHeight: CGFloat, caretIsExact: Bool) -> CGFloat {
        guard let reported = style?.fontPointSize, reported.isFinite, reported > 0 else {
            guard caretHeight.isFinite, caretHeight > 0 else { return NSFont.systemFontSize }
            let estimate = caretHeight * pointSizePerCaretHeight
            return caretIsExact ? estimate : min(estimate, maximumEstimatedPointSize)
        }
        guard caretIsExact, caretHeight.isFinite, caretHeight > 0 else { return reported }
        let reference = style?.fontName.flatMap { resolvedFont(named: $0, size: reported) }
            ?? .systemFont(ofSize: reported)
        let glyphBox = reference.ascender - reference.descender
        guard glyphBox > 0 else { return reported }
        let ratio = caretHeight / glyphBox
        if ratio < 0.8 { return reported * ratio }
        if ratio > 2.4 { return reported * ratio / 1.2 }
        return reported
    }
}
