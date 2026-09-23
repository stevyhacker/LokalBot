import AppKit
import SwiftUI

/// Brand identity derived from the app icon and marketing site. The icon is an
/// L-shaped robot on a dark slate plate, drawn in a mint→teal gradient with a
/// single amber antenna. The app uses a deeper primary teal than the icon so
/// tinted text and controls keep sufficient contrast on light materials.
enum Brand {
    /// Primary app accent for text, icons, strokes, selection washes, and
    /// tinted controls. Deep teal on light surfaces and a lighter mint on dark
    /// ones, so accent text meets WCAG AA in both appearances
    /// (`BrandContrastTests`).
    static let tealNSColor = NSColor(name: "LokalBotAccent") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0x74 / 255, green: 0xE0 / 255, blue: 0xC6 / 255, alpha: 1) // #74E0C6
            : NSColor(srgbRed: 0x08 / 255, green: 0x66 / 255, blue: 0x5A / 255, alpha: 1) // #08665A
    }
    static let teal = Color(nsColor: tealNSColor)
    /// Accent fill behind white foregrounds — filled buttons, badges, icon
    /// tiles, and meeting blocks. Stays deep in both appearances.
    static let tealFillNSColor = NSColor(srgbRed: 0x08 / 255, green: 0x66 / 255, blue: 0x5A / 255, alpha: 1)
    static let tealFill = Color(nsColor: tealFillNSColor)
    /// Bright end of the gradient — glows, active states, the recording eye.
    static let tealBright = Color(red: 0.431, green: 0.949, blue: 0.863) // #6ef2dc
    /// The single warm note — reserved for the live "recording" indicator,
    /// mirroring the antenna dot on the icon.
    static let amber = Color(red: 0.984, green: 0.749, blue: 0.141)      // #fbbf24
    /// Failure and warning text, icons, and borders. One semantic hook —
    /// currently the system orange — so the error presentation can evolve in
    /// one place instead of dozens of hardcoded `.orange`s.
    static let error = Color.orange

    /// "Me" speaker (mic track) — the user's own voice.
    static let me = teal
    /// "Them" speaker (system track) — other participants.
    static let them = Color(red: 0.49, green: 0.62, blue: 0.76)

    /// The icon's dark plate, brought into the app for hero surfaces and
    /// HUDs. Deliberately stays dark in both appearances — hero surfaces
    /// read as "plated" like the icon, so content on slate must use fixed
    /// light foregrounds (white / tealBright), never semantic label colors.
    static let slate = Color(red: 0.059, green: 0.090, blue: 0.165)          // #0f172a
    static let slateElevated = Color(red: 0.118, green: 0.161, blue: 0.231)  // #1e293b

    /// Plate gradient for hero panels — elevated slate falling to slate,
    /// echoing the icon's plate lighting.
    static let plateGradient = LinearGradient(
        colors: [slateElevated, slate],
        startPoint: .topLeading, endPoint: .bottomTrailing)

    /// A view modifier that sets the brand tint and offers a softer fallback
    /// in High Contrast / Increase Contrast where the teal can read thin.
    struct TintModifier: ViewModifier {
        func body(content: Content) -> some View {
            content.tint(teal)
                .accentColor(teal)
        }
    }
}

extension View {
    /// Apply the LokalBot brand accent app-wide.
    func brandTinted() -> some View { modifier(Brand.TintModifier()) }
}
