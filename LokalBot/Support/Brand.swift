import AppKit
import SwiftUI

enum Brand {
    static let tealNSColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0x6E / 255, green: 0xF2 / 255, blue: 0xDC / 255, alpha: 1)
            : NSColor(srgbRed: 0x07 / 255, green: 0x5F / 255, blue: 0x55 / 255, alpha: 1)
    }
    static let teal = Color(nsColor: tealNSColor)
    static let tealFillNSColor = NSColor(srgbRed: 0x0C / 255, green: 0x82 / 255, blue: 0x75 / 255, alpha: 1)
    static let tealFill = Color(nsColor: tealFillNSColor)
    static let amber = LBTokens.Palette.attention
    static let error = LBTokens.Palette.attentionText

    static let me = teal
    static let them = Color(red: 0.49, green: 0.62, blue: 0.76)

    struct TintModifier: ViewModifier {
        func body(content: Content) -> some View {
            content.tint(teal)
        }
    }
}

extension View {
    func brandTinted() -> some View { modifier(Brand.TintModifier()) }
}
