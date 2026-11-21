// Contains code ported from Cotabby (https://github.com/FuJacob/cotabby),
// copyright the Cotabby authors, under the GNU AGPL v3.0
// (LICENSES/AGPL-3.0.txt). Modified for LokalBot since 21 July 2026.
// See THIRD_PARTY_NOTICES.md.

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

enum CotypingAXGeometryResolver {
    private static func copyAttribute(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value
    }

    private static func stringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        copyAttribute(element, attribute) as? String
    }

    static func caretRect(
        _ element: AXUIElement,
        caretLocation: Int,
        fieldText: String,
        isRightToLeft: Bool,
        allowBoundsForRange: Bool = true
    ) -> (rect: CGRect, exact: Bool) {
        if allowBoundsForRange {
            if let caret = CotypingCaretGeometry.caret(
                emptyRangeRect: boundsForRange(element, location: caretLocation, length: 0),
                previousCharacterRect: previousCharacterRect(element, caretLocation: caretLocation, fieldText: fieldText),
                elementFrame: elementFrame(element),
                isRightToLeft: isRightToLeft) {
                return (cocoaRect(fromAX: caret), true)
            }
        }
        if let rect = textMarkerCaretRect(element), CotypingCaretGeometry.isCollapsedCaret(rect) {
            return (cocoaRect(fromAX: rect), true)
        }
        if CotypingTextLeafCaret.caretIsAtTextEnd(fieldText: fieldText, caretLocation: caretLocation),
           let frame = elementFrame(element),
           let rect = CotypingTextLeafCaret.caretRect(
               elementFrame: frame,
               leaves: staticTextLeaves(element),
               fieldText: fieldText,
               caretLocation: caretLocation,
               isRightToLeft: isRightToLeft) {
            return (cocoaRect(fromAX: rect), true)
        }
        if let frame = elementFrame(element) {
            let estimate = CGRect(x: frame.minX + 4, y: frame.minY,
                                  width: 1, height: min(max(frame.height, 8), 22))
            return (cocoaRect(fromAX: estimate), false)
        }
        return (.zero, false)
    }

    private static func staticTextLeaves(
        _ element: AXUIElement,
        maxNodes: Int = 200,
        maxDepth: Int = 8
    ) -> [CotypingTextLeafCaret.Leaf] {
        var leaves: [CotypingTextLeafCaret.Leaf] = []
        var budget = maxNodes
        func walk(_ node: AXUIElement, depth: Int) {
            guard depth < maxDepth, budget > 0,
                  let raw = copyAttribute(node, kAXChildrenAttribute as String),
                  let children = raw as? [AXUIElement] else { return }
            for child in children {
                guard budget > 0 else { return }
                budget -= 1
                if stringAttribute(child, kAXRoleAttribute as String) == kAXStaticTextRole as String {
                    guard let frame = elementFrame(child) else { continue }
                    let text = stringAttribute(child, kAXValueAttribute as String) ?? ""
                    leaves.append(CotypingTextLeafCaret.Leaf(frame: frame, text: text))
                } else {
                    walk(child, depth: depth + 1)
                }
            }
        }
        walk(element, depth: 0)
        return leaves
    }

    private static func previousCharacterRect(
        _ element: AXUIElement, caretLocation: Int, fieldText: String
    ) -> CGRect? {
        let text = fieldText as NSString
        guard caretLocation > 0, caretLocation <= text.length else { return nil }
        let range = text.rangeOfComposedCharacterSequence(at: caretLocation - 1)
        guard NSMaxRange(range) == caretLocation,
              text.substring(with: range).rangeOfCharacter(from: .newlines) == nil else { return nil }
        return boundsForRange(element, location: range.location, length: range.length)
    }

    private static func boundsForRange(_ element: AXUIElement, location: Int, length: Int) -> CGRect? {
        var cfRange = CFRange(location: location, length: length)
        guard let axRange = AXValueCreate(.cfRange, &cfRange) else { return nil }
        var raw: CFTypeRef?
        let err = AXUIElementCopyParameterizedAttributeValue(
            element, kAXBoundsForRangeParameterizedAttribute as CFString, axRange, &raw)
        guard err == .success, let value = raw, CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }
        var rect = CGRect.zero
        guard AXValueGetValue(value as! AXValue, .cgRect, &rect) else { return nil }
        return rect
    }

    private static func textMarkerCaretRect(_ element: AXUIElement) -> CGRect? {
        var markerRangeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, "AXSelectedTextMarkerRange" as CFString, &markerRangeValue) == .success,
              let markerRange = markerRangeValue else { return nil }
        var boundsValue: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, "AXBoundsForTextMarkerRange" as CFString, markerRange, &boundsValue) == .success,
              let bounds = boundsValue, CFGetTypeID(bounds) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(bounds as! AXValue, .cgRect, &rect) else { return nil }
        return rect
    }

    static func elementFrame(_ element: AXUIElement) -> CGRect? {
        guard let posRaw = copyAttribute(element, kAXPositionAttribute as String),
              CFGetTypeID(posRaw) == AXValueGetTypeID(),
              let sizeRaw = copyAttribute(element, kAXSizeAttribute as String),
              CFGetTypeID(sizeRaw) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(posRaw as! AXValue, .cgPoint, &origin),
              AXValueGetValue(sizeRaw as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    static func cocoaRect(fromAX axRect: CGRect) -> CGRect {
        let midpoint = CGPoint(x: axRect.midX, y: axRect.midY)
        if let displayID = displayID(containingAXPoint: midpoint),
           let screen = screen(forDisplayID: displayID) {
            return cocoaRect(fromAX: axRect,
                             displayBounds: CGDisplayBounds(displayID),
                             screenFrame: screen.frame)
        }
        let primaryBounds = CGDisplayBounds(CGMainDisplayID())
        let primaryFrame = NSScreen.main?.frame ?? CGRect(origin: .zero, size: primaryBounds.size)
        return cocoaRect(fromAX: axRect, displayBounds: primaryBounds, screenFrame: primaryFrame)
    }

    static func cocoaRect(fromAX axRect: CGRect,
                          displayBounds: CGRect,
                          screenFrame: CGRect) -> CGRect {
        let localX = axRect.origin.x - displayBounds.origin.x
        let localYFromTop = axRect.origin.y - displayBounds.origin.y
        return CGRect(x: screenFrame.origin.x + localX,
                      y: screenFrame.maxY - localYFromTop - axRect.height,
                      width: axRect.width, height: axRect.height)
    }

    private static func displayID(containingAXPoint point: CGPoint) -> CGDirectDisplayID? {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return nil }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &displays, &count) == .success else { return nil }
        return displays.prefix(Int(count)).first { CGDisplayBounds($0).contains(point) }
    }

    private static func screen(forDisplayID displayID: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { screen in
            let key = NSDeviceDescriptionKey("NSScreenNumber")
            return (screen.deviceDescription[key] as? NSNumber)?.uint32Value == displayID
        }
    }
}

nonisolated enum CotypingCaretGeometry {
    private static let containmentTolerance: CGFloat = 4

    static func isCollapsedCaret(_ rect: CGRect) -> Bool {
        rect.width.isFinite && rect.height.isFinite && rect.height > 0
            && rect.width <= max(2, rect.height / 4)
    }

    static func caret(
        emptyRangeRect: CGRect?,
        previousCharacterRect: CGRect?,
        elementFrame: @autoclosure () -> CGRect? = nil,
        isRightToLeft: Bool
    ) -> CGRect? {
        let emptyRange = emptyRangeRect.flatMap { rect in
            rect.width.isFinite && rect.height.isFinite && rect.height > 0 ? rect : nil
        }
        if let character = previousCharacterRect,
           character.width.isFinite, character.height.isFinite,
           character.width > 0, character.height > 0,
           character.width <= character.height * 3,
           emptyRange != nil || elementFrame().map({
               $0.insetBy(dx: -containmentTolerance, dy: -containmentTolerance).contains(character)
           }) == true {
            let x = isRightToLeft ? character.minX : character.maxX
            return CGRect(x: x, y: character.minY, width: 0, height: character.height)
        }
        return emptyRange
    }
}
