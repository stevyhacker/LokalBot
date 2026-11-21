import SwiftUI

public enum NameColor {
    public static func djb2(_ name: String) -> UInt64 {
        var hash: UInt64 = 5381
        for byte in name.utf8 { hash = hash &* 33 &+ UInt64(byte) }
        return hash
    }

    public static func hueDegrees(for name: String) -> Int { Int(djb2(name) % 360) }

    public static func color(for name: String) -> Color {
        if name == "Other" { return LBTokens.Palette.supporting.opacity(0.55) }
        return Color(hue: Double(hueDegrees(for: name)) / 360,
                     saturation: LBTokens.nameColorSaturation,
                     brightness: LBTokens.nameColorBrightness)
    }
}
