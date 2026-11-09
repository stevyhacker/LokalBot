import SwiftUI

/// Stable colors for apps and projects on the Timeline, identical to the Mac's
/// `CaptureStyle.color(for:)`: hue = djb2(name) % 360, saturation 0.55,
/// brightness 0.78.
public enum NameColor {
    /// djb2 over the UTF-8 bytes, wrapping in 64 bits like the Mac.
    public static func djb2(_ name: String) -> UInt64 {
        var hash: UInt64 = 5381
        for byte in name.utf8 { hash = hash &* 33 &+ UInt64(byte) }
        return hash
    }

    /// Hue in degrees, 0..<360.
    public static func hueDegrees(for name: String) -> Int { Int(djb2(name) % 360) }

    /// "Other" (time without an app or project) is the supporting color at 55%.
    public static func color(for name: String) -> Color {
        if name == "Other" { return LBTokens.Palette.supporting.opacity(0.55) }
        return Color(hue: Double(hueDegrees(for: name)) / 360,
                     saturation: LBTokens.nameColorSaturation,
                     brightness: LBTokens.nameColorBrightness)
    }
}
