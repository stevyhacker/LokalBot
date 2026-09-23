import AppKit
import SwiftUI
import XCTest
@testable import LokalBot

/// Accent text and filled accent controls must meet WCAG AA (4.5:1) on every
/// workspace surface in both appearances, including the translucent accent
/// wash behind tinted buttons and selected rows.
final class BrandContrastTests: XCTestCase {
    private let schemes: [(NSAppearance.Name, ColorScheme)] = [(.aqua, .light), (.darkAqua, .dark)]

    func testAccentTextMeetsAAOnEveryWorkspaceSurface() {
        for (appearance, scheme) in schemes {
            let accent = resolve(Brand.tealNSColor, in: appearance)
            for (label, surface) in surfaces(for: scheme) {
                XCTAssertGreaterThanOrEqual(
                    contrast(accent, surface), 4.5, "Accent on \(label) (\(scheme))")
                let wash = blend(accent, over: surface, alpha: scheme == .dark ? 0.18 : 0.15)
                XCTAssertGreaterThanOrEqual(
                    contrast(accent, wash), 4.5, "Accent on tinted \(label) (\(scheme))")
            }
        }
    }

    func testWhiteLabelsMeetAAOnFilledAccent() {
        for (appearance, scheme) in schemes {
            let fill = resolve(Brand.tealFillNSColor, in: appearance)
            XCTAssertGreaterThanOrEqual(contrast(.white, fill), 4.5, "White on filled accent (\(scheme))")
        }
    }

    func testSettingsAndAgentUseTheSharedAccent() {
        for (appearance, scheme) in schemes {
            let brand = resolve(Brand.tealNSColor, in: appearance)
            let settings = resolve(NSColor(SettingsPalette.accent(scheme)), in: appearance)
            XCTAssertEqual(hex(settings), hex(brand), "Settings accent (\(scheme))")
        }
    }

    // MARK: - Surfaces

    private func surfaces(for scheme: ColorScheme) -> [(String, NSColor)] {
        var result: [(String, NSColor)] = [
            ("canvas", NSColor(WorkspacePalette.canvas(for: scheme))),
            ("surface", NSColor(WorkspacePalette.surface(for: scheme))),
            ("conversation column", NSColor(WorkspacePalette.conversationColumn(for: scheme))),
            ("control", NSColor(WorkspacePalette.control(for: scheme))),
            ("settings canvas", NSColor(SettingsPalette.canvas(scheme))),
            ("settings panel", NSColor(SettingsPalette.panel(scheme))),
        ]
        // Nested quiet panels (`.quaternary` fills over the canvas) measured
        // from the 1440×900 design captures; they are the darkest light and
        // lightest dark surfaces accent text sits on.
        result.append(("nested panel", scheme == .dark
            ? NSColor(srgbRed: 0x2E / 255, green: 0x32 / 255, blue: 0x33 / 255, alpha: 1)
            : NSColor(srgbRed: 0xE6 / 255, green: 0xEC / 255, blue: 0xE8 / 255, alpha: 1)))
        return result
    }

    // MARK: - WCAG helpers

    private func resolve(_ color: NSColor, in name: NSAppearance.Name) -> NSColor {
        var resolved = color
        NSAppearance(named: name)!.performAsCurrentDrawingAppearance {
            resolved = color.usingColorSpace(.sRGB) ?? color
        }
        return resolved
    }

    private func srgb(_ color: NSColor) -> (Double, Double, Double) {
        let c = color.usingColorSpace(.sRGB)!
        return (Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent))
    }

    private func luminance(_ color: NSColor) -> Double {
        func channel(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        let (r, g, b) = srgb(color)
        return 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b)
    }

    private func contrast(_ a: NSColor, _ b: NSColor) -> Double {
        let (la, lb) = (luminance(a), luminance(b))
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    private func blend(_ top: NSColor, over bottom: NSColor, alpha: Double) -> NSColor {
        let (tr, tg, tb) = srgb(top), (br, bg, bb) = srgb(bottom)
        return NSColor(srgbRed: tr * alpha + br * (1 - alpha), green: tg * alpha + bg * (1 - alpha),
                       blue: tb * alpha + bb * (1 - alpha), alpha: 1)
    }

    private func hex(_ color: NSColor) -> String {
        let (r, g, b) = srgb(color)
        return String(format: "%02X%02X%02X", Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
    }
}
