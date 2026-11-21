import CoreGraphics

nonisolated enum CotypingOverlayGeometry {
    static let gap: CGFloat = 2
    static let reanchorDriftTolerance: CGFloat = 1.5
    static let backwardDriftHoldWindowMilliseconds = 300

    static func shouldHoldInlineReanchor(
        currentFrame: CGRect,
        targetFrame: CGRect,
        millisecondsSinceLastAcceptance: Int?,
        isRightToLeft: Bool = false
    ) -> Bool {
        let deltaY = targetFrame.origin.y - currentFrame.origin.y
        guard abs(deltaY) <= reanchorDriftTolerance else { return false }

        let deltaX = targetFrame.origin.x - currentFrame.origin.x
        let caretAhead = isRightToLeft ? -deltaX : deltaX
        if abs(caretAhead) <= reanchorDriftTolerance {
            return true
        }
        guard caretAhead < 0 else { return false }
        return millisecondsSinceLastAcceptance
            .map { $0 <= backwardDriftHoldWindowMilliseconds } ?? false
    }

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
