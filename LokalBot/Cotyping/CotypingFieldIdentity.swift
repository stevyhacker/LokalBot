import CoreGraphics
import Foundation

enum CotypingFieldIdentity {

    static func suggestionAnchor(for field: CotypingField) -> String {
        fieldIdentity(for: field)
    }

    static func prewarm(for field: CotypingField) -> String {
        fieldIdentity(for: field)
    }

    static func background(for field: CotypingField) -> String {
        [
            String(field.processID),
            field.role,
            field.windowTitle ?? "",
            field.inputFrameRect.map(roundedRectIdentity) ?? field.fieldPlaceholder ?? "",
        ].joined(separator: "\u{1f}")
    }

    private static func fieldIdentity(for field: CotypingField) -> String {
        let fieldPart: String
        if let focusIdentityKey = field.focusIdentityKey, !focusIdentityKey.isEmpty {
            fieldPart = "focus:\(focusIdentityKey)"
        } else if let frame = field.inputFrameRect {
            fieldPart = "frame:\(roundedRectIdentity(frame))"
        } else {
            fieldPart = [
                field.windowTitle ?? "",
                field.fieldPlaceholder ?? "",
            ].joined(separator: "\u{1f}")
        }
        return [
            String(field.processID),
            field.bundleID ?? "",
            field.appName,
            field.role,
            fieldPart,
        ].joined(separator: "\u{1f}")
    }

    private static func roundedRectIdentity(_ rect: CGRect) -> String {
        [
            rect.origin.x,
            rect.origin.y,
            rect.size.width,
            rect.size.height,
        ]
            .map { String(Int($0.rounded())) }
            .joined(separator: ",")
    }
}
