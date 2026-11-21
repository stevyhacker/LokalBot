// Contains code ported from Cotabby (https://github.com/FuJacob/cotabby),
// copyright the Cotabby authors, under the GNU AGPL v3.0
// (LICENSES/AGPL-3.0.txt). Modified for LokalBot since 23 June 2026.
// See THIRD_PARTY_NOTICES.md.

import AppKit
import Foundation

nonisolated struct CotypingFieldStyle: Equatable, Sendable {
    let fontName: String?
    let fontPointSize: CGFloat?
    let colorHex: String?
    let backgroundColorHex: String?

    var isEmpty: Bool { fontName == nil && fontPointSize == nil && colorHex == nil && backgroundColorHex == nil }

    init(fontName: String? = nil, fontPointSize: CGFloat? = nil,
         colorHex: String? = nil, backgroundColorHex: String? = nil) {
        self.fontName = fontName
        self.fontPointSize = fontPointSize
        self.colorHex = colorHex
        self.backgroundColorHex = backgroundColorHex
    }
}

enum CotypingTextColorCodec {
    static func nsColor(fromHex hex: String?) -> NSColor? {
        guard let hex else { return nil }
        let normalized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        let valid = CharacterSet(charactersIn: "0123456789ABCDEFabcdef")
        guard normalized.count == 6,
              normalized.unicodeScalars.allSatisfy({ valid.contains($0) }) else { return nil }
        var value: UInt64 = 0
        guard Scanner(string: normalized).scanHexInt64(&value) else { return nil }
        let red = CGFloat((value & 0xFF0000) >> 16) / 255
        let green = CGFloat((value & 0x00FF00) >> 8) / 255
        let blue = CGFloat(value & 0x0000FF) / 255
        return NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
    }

    static func hexString(from nsColor: NSColor) -> String? {
        guard let srgb = nsColor.usingColorSpace(.sRGB) else { return nil }
        let red = Int((srgb.redComponent * 255).rounded())
        let green = Int((srgb.greenComponent * 255).rounded())
        let blue = Int((srgb.blueComponent * 255).rounded())
        return String(format: "%02X%02X%02X", red, green, blue)
    }
}

enum CotypingGhostStyle {
    static let ghostOpacity: CGFloat = 0.4
    static let emphasisOpacity: CGFloat = 0.62

    static func ghostColor(from style: CotypingFieldStyle?) -> NSColor? {
        guard let style, let hex = style.colorHex,
              let host = CotypingTextColorCodec.nsColor(fromHex: hex) else { return nil }
        return host.withAlphaComponent(ghostOpacity)
    }

    static func relativeLuminance(of color: NSColor) -> CGFloat {
        guard let srgb = color.usingColorSpace(.sRGB) else { return 0.5 }
        return 0.299 * srgb.redComponent + 0.587 * srgb.greenComponent + 0.114 * srgb.blueComponent
    }

    static func contrastRatio(_ a: CGFloat, _ b: CGFloat) -> CGFloat {
        (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    static func contrastRatio(_ first: NSColor, _ second: NSColor) -> CGFloat {
        contrastRatio(relativeLuminance(of: first), relativeLuminance(of: second))
    }

    static let unreliableContrast: CGFloat = 2.0

    static let minLegibleContrast: CGFloat = 3.0

    static func dimHint(onDarkBackground dark: Bool) -> NSColor {
        let channel: CGFloat = dark ? 1 : 0
        return NSColor(srgbRed: channel, green: channel, blue: channel, alpha: ghostOpacity)
    }

    static func resolvedGhostColor(from style: CotypingFieldStyle?, isDarkEnvironment: Bool,
                                   measuredLuminance: CGFloat? = nil) -> NSColor {
        if let measuredLuminance {
            if let dimmedHost = ghostColor(from: style),
               contrastRatio(relativeLuminance(of: dimmedHost), measuredLuminance) >= minLegibleContrast {
                return dimmedHost
            }
            return dimHint(onDarkBackground: measuredLuminance < 0.5)
        }
        let background = style.flatMap { CotypingTextColorCodec.nsColor(fromHex: $0.backgroundColorHex) }
        if let dimmedHost = ghostColor(from: style) {
            if let background, contrastRatio(dimmedHost, background) < unreliableContrast {
                return dimHint(onDarkBackground: relativeLuminance(of: background) < 0.5)
            }
            return dimmedHost
        }
        if let background {
            return dimHint(onDarkBackground: relativeLuminance(of: background) < 0.5)
        }
        return dimHint(onDarkBackground: isDarkEnvironment)
    }
}
