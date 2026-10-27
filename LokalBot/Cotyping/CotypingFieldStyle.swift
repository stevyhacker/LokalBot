// Contains code ported from Cotabby (https://github.com/FuJacob/cotabby),
// copyright the Cotabby authors, under the GNU AGPL v3.0
// (LICENSES/AGPL-3.0.txt). Modified for LokalBot since 23 June 2026.
// See THIRD_PARTY_NOTICES.md.

import AppKit
import Foundation

/// The focused field's own font/color, resolved once per field session from AX
/// and carried as plain value types (no `NSFont`/`NSColor`) so the snapshot
/// stays `Equatable`/`Sendable` and cheap across async boundaries. Ported from
/// Cotabby's `ResolvedFieldStyle`. Empty / nil falls back to the overlay defaults.
nonisolated struct CotypingFieldStyle: Equatable, Sendable {
    /// PostScript font name suitable for `NSFont(name:size:)`.
    let fontName: String?
    /// Host-reported point size; used (clamped) so the ghost matches the field's scale.
    let fontPointSize: CGFloat?
    /// Foreground text color as a 6-digit hex string.
    let colorHex: String?
    /// Background (fill) color of the field as a 6-digit hex string, when the
    /// host exposes it. Lets the ghost pick a legible hint on dark fields even
    /// when no foreground color is reported.
    let backgroundColorHex: String?

    /// Chromium reports a size with no font name, which is still a style.
    var isEmpty: Bool { fontName == nil && fontPointSize == nil && colorHex == nil && backgroundColorHex == nil }

    init(fontName: String? = nil, fontPointSize: CGFloat? = nil,
         colorHex: String? = nil, backgroundColorHex: String? = nil) {
        self.fontName = fontName
        self.fontPointSize = fontPointSize
        self.colorHex = colorHex
        self.backgroundColorHex = backgroundColorHex
    }
}

/// Hex-string ↔ `NSColor` conversion for ghost-text colors. Ported from
/// Cotabby's `SuggestionTextColorCodec`: persistence (hex) and rendering
/// (`NSColor`) share one round-trip-correct path.
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

/// Derives the ghost text's font/color from the host field's resolved style, so
/// the suggestion reads as a continuation of what the user is typing instead of
/// always using the system font + a fixed gray. Ported in spirit from Cotabby's
/// overlay styling. Pure given AppKit; all fallbacks are explicit and testable.
enum CotypingGhostStyle {
    /// Ghost opacity relative to the host text color — reads as a suggestion, not typed text.
    static let ghostOpacity: CGFloat = 0.4
    /// The word the next accept takes is drawn a little stronger than the rest.
    static let emphasisOpacity: CGFloat = 0.62

    /// Dimmed host text color so the suggestion reads as a hint, or nil (caller
    /// falls back to the secondary label color).
    static func ghostColor(from style: CotypingFieldStyle?) -> NSColor? {
        guard let style, let hex = style.colorHex,
              let host = CotypingTextColorCodec.nsColor(fromHex: hex) else { return nil }
        return host.withAlphaComponent(ghostOpacity)
    }

    /// Perceived luminance (0…1) of a color in sRGB, for bucketing a field as
    /// light or dark. Rec. 601 weights; alpha is ignored.
    static func relativeLuminance(of color: NSColor) -> CGFloat {
        guard let srgb = color.usingColorSpace(.sRGB) else { return 0.5 }
        return 0.299 * srgb.redComponent + 0.587 * srgb.greenComponent + 0.114 * srgb.blueComponent
    }

    /// WCAG-style contrast ratio (1…21) between two relative luminances.
    static func contrastRatio(_ a: CGFloat, _ b: CGFloat) -> CGFloat {
        (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// Contrast ratio between two colors (alpha ignored).
    static func contrastRatio(_ first: NSColor, _ second: NSColor) -> CGFloat {
        contrastRatio(relativeLuminance(of: first), relativeLuminance(of: second))
    }

    /// Below this fg/bg contrast the host text color is almost always a dynamic
    /// color flattened against the wrong appearance, so we synthesize a hint.
    static let unreliableContrast: CGFloat = 2.0

    /// With a real (sampled) background luminance we hold the host color to a
    /// genuinely-legible contrast (WCAG ~AA, large text) before trusting it.
    static let minLegibleContrast: CGFloat = 3.0

    /// A concrete dim hint — light on a dark field, dark on a light one — never a
    /// dynamic catalog color, so it stays legible regardless of the overlay
    /// panel's resolved appearance.
    static func dimHint(onDarkBackground dark: Bool) -> NSColor {
        let channel: CGFloat = dark ? 1 : 0
        return NSColor(srgbRed: channel, green: channel, blue: channel, alpha: ghostOpacity)
    }

    /// The color actually painted for the ghost, as a concrete sRGB color
    /// (independent of the overlay panel's resolved appearance). `measuredLuminance`
    /// (real pixels sampled behind the ghost) is authoritative when present; the
    /// host color is kept only when legible against the background, otherwise a
    /// contrasting hint is synthesized.
    static func resolvedGhostColor(from style: CotypingFieldStyle?, isDarkEnvironment: Bool,
                                   measuredLuminance: CGFloat? = nil) -> NSColor {
        if let measuredLuminance {
            // Real pixels behind the ghost beat any AX/appearance guess: keep the
            // host color only if it's legible against them, else synthesize.
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
