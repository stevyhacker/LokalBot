import CoreGraphics

/// Pure placement math for the ghost overlay, split out from `show()` so the
/// frame geometry is deterministic and unit-testable. All rects are in global
/// Cocoa (bottom-left origin) coordinates.
nonisolated enum CotypingOverlayGeometry {
    /// Gap between the caret and the popup / screen edges.
    static let gap: CGFloat = 2
    /// Movement too small to see, or to be more than rounding between reads.
    static let reanchorDriftTolerance: CGFloat = 1.5
    static let backwardDriftHoldWindowMilliseconds = 300

    /// Whether an inline ghost stays where it is when the caret is read
    /// again. It moves to any other line, and whenever the caret is further
    /// along the line than the ghost starts, because then the ghost covers
    /// text just typed. A ghost ahead of the caret is held only right after
    /// an accept: hosts often publish inserted text before its caret moves.
    static func shouldHoldInlineReanchor(
        currentFrame: CGRect,
        targetFrame: CGRect,
        millisecondsSinceLastAcceptance: Int?,
        isRightToLeft: Bool = false
    ) -> Bool {
        let deltaY = targetFrame.origin.y - currentFrame.origin.y
        guard abs(deltaY) <= reanchorDriftTolerance else { return false }

        let deltaX = targetFrame.origin.x - currentFrame.origin.x
        // Positive when the caret is further along the line than the ghost.
        let caretAhead = isRightToLeft ? -deltaX : deltaX
        if abs(caretAhead) <= reanchorDriftTolerance {
            return true
        }
        guard caretAhead < 0 else { return false }
        return millisecondsSinceLastAcceptance
            .map { $0 <= backwardDriftHoldWindowMilliseconds } ?? false
    }

    /// Mirror (popup) frame: a chrome pill one line below the caret, flipped
    /// above when there is no room below. Used for mid-line carets where inline
    /// text would paint over the host's trailing characters.
    static func mirrorFrame(
        caret: CGRect, content: CGSize, visible: CGRect?
    ) -> CGRect {
        let width = max(content.width, 8)
        let height = max(content.height, 18)
        var x = min(caret.minX, (visible?.maxX ?? caret.minX) - width)
        if let visible { x = max(visible.minX + gap, x) }
        var y = caret.minY - height - gap
        if let visible, y < visible.minY { y = caret.maxY + gap }
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// Popup frame for a suggestion. An exact caret gets `mirrorFrame`. A caret
    /// estimated from the field's frame says nothing about where the text is,
    /// so the popup goes just outside the field, below it or else above it,
    /// and never covers the field's text. Nil when there is no such room.
    static func popupFrame(
        caret: CGRect, caretIsExact: Bool, field: CGRect?, content: CGSize, visible: CGRect?
    ) -> CGRect? {
        if caretIsExact { return mirrorFrame(caret: caret, content: content, visible: visible) }
        guard let field = field?.standardized else { return nil }
        let width = max(content.width, 8)
        let height = max(content.height, 18)
        var x = min(field.minX, (visible?.maxX ?? field.minX) - width)
        if let visible { x = max(visible.minX + gap, x) }
        let below = CGRect(x: x, y: field.minY - gap - height, width: width, height: height)
        guard let visible, below.minY < visible.minY else { return below }
        let above = CGRect(x: x, y: field.maxY + gap, width: width, height: height)
        return above.maxY <= visible.maxY ? above : nil
    }
}
