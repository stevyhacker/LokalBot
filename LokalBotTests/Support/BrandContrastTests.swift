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

    func testSemanticTextMeetsAAOnStatusSurfaces() {
        let roles: [(String, Color, Color)] = [
            ("accent", LBTokens.Palette.accentText, LBTokens.Palette.accentText),
            ("attention", LBTokens.Palette.attentionText, LBTokens.Palette.attention),
            ("success", LBTokens.Palette.successText, LBTokens.Palette.success),
            ("recording", LBTokens.Palette.recordingText, LBTokens.Palette.recording),
        ]
        for (appearance, scheme) in schemes {
            for (role, text, tint) in roles {
                let foreground = resolve(NSColor(text), in: appearance)
                let fill = resolve(NSColor(tint), in: appearance)
                for (label, surface) in surfaces(for: scheme) {
                    let statusSurface = blend(fill, over: surface, alpha: LBTokens.Palette.statusFillOpacity)
                    XCTAssertGreaterThanOrEqual(contrast(foreground, statusSurface), 4.5,
                                               "\(role) status on \(label) (\(scheme))")
                }
            }
        }
    }

    /// Panels (Today's, and a meeting's) put small text on fills of their
    /// own: the count pill, the red overdue badge, the footer strip with its
    /// link, and the band over a group of rows. Each holds 4.5:1 on the
    /// raised card in light, dark and both Increase Contrast appearances,
    /// where supporting text is drawn in the label colour.
    func testTodayPanelTextMeetsAAInEveryAppearance() {
        let appearances: [(NSAppearance.Name, increased: Bool)] = [
            (.aqua, false), (.darkAqua, false),
            (.accessibilityHighContrastAqua, true), (.accessibilityHighContrastDarkAqua, true),
        ]
        for (appearance, increased) in appearances {
            let card = resolve(.controlBackgroundColor, in: appearance)
            func over(_ fill: Color, opacity: Double? = nil) -> NSColor {
                let color = resolve(NSColor(fill), in: appearance)
                return blend(color, over: card, alpha: opacity ?? Double(color.alphaComponent))
            }
            let supporting = resolve(increased ? .labelColor : WorkspaceTextColor.supporting, in: appearance)
            let pairs: [(String, NSColor, NSColor)] = [
                ("count pill", supporting, over(LBTokens.Palette.quietFill)),
                ("overdue badge", resolve(NSColor(LBTokens.Palette.recordingText), in: appearance),
                 over(LBTokens.Palette.recording, opacity: LBTokens.Palette.statusFillOpacity)),
                ("footer text", supporting, over(LBTokens.Palette.groupFill)),
                ("footer link", resolve(Brand.tealNSColor, in: appearance), over(LBTokens.Palette.groupFill)),
                ("now line", resolve(NSColor(LBTokens.Palette.recordingText), in: appearance), card),
                ("label on card", supporting, card),
                // A meeting's Actions panel: "For you · 2" on the band, and
                // the line under a band whose side has no actions.
                ("band label", supporting, over(LBTokens.Palette.groupFill)),
                ("empty group line", supporting, card),
                // Notes that could not be saved say so in the footer strip.
                ("footer warning", resolve(WorkspaceTextColor.warning, in: appearance),
                 over(LBTokens.Palette.groupFill)),
                // A play time and due dates on the card.
                ("play time", resolve(NSColor(LBTokens.Palette.accentText), in: appearance), card),
                ("due soon", resolve(NSColor(LBTokens.Palette.attentionText), in: appearance), card),
            ]
            for (label, text, surface) in pairs {
                XCTAssertGreaterThanOrEqual(contrast(text, surface), 4.5, "\(label) (\(appearance.rawValue))")
            }
        }
    }

    /// Timeline's rail is drawn on the content background, with its chosen
    /// row on the list's unfocused selection; the day's page adds the "All
    /// done" badge and the Done line to the panels. Small text in each holds
    /// 4.5:1 in light, dark and both Increase Contrast appearances.
    func testTimelineRailAndPanelTextMeetsAAInEveryAppearance() {
        let appearances: [(NSAppearance.Name, increased: Bool)] = [
            (.aqua, false), (.darkAqua, false),
            (.accessibilityHighContrastAqua, true), (.accessibilityHighContrastDarkAqua, true),
        ]
        for (appearance, increased) in appearances {
            let rail = resolve(.textBackgroundColor, in: appearance)
            let selection = resolve(.unemphasizedSelectedContentBackgroundColor, in: appearance)
            let card = resolve(.controlBackgroundColor, in: appearance)
            let supporting = resolve(increased ? .labelColor : WorkspaceTextColor.supporting, in: appearance)
            let accent = resolve(NSColor(LBTokens.Palette.accentText), in: appearance)
            let recording = resolve(NSColor(LBTokens.Palette.recordingText), in: appearance)
            let doneFill = resolve(NSColor(LBTokens.Palette.accentFill), in: appearance)
            let groupFill = resolve(NSColor(LBTokens.Palette.groupFill), in: appearance)
            let pairs: [(String, NSColor, NSColor)] = [
                // Times, second lines, durations, Away, the hour labels and the legend.
                ("rail supporting text", supporting, rail),
                ("chosen row supporting text", supporting, selection),
                ("meeting line", accent, rail),
                ("chosen meeting line", accent, selection),
                ("recording line", recording, rail),
                ("chosen recording line", recording, selection),
                ("all done badge", accent,
                 blend(doneFill, over: card, alpha: LBTokens.Palette.statusFillOpacity)),
                ("done line preview", supporting,
                 blend(groupFill, over: card, alpha: Double(groupFill.alphaComponent))),
            ]
            for (label, text, surface) in pairs {
                XCTAssertGreaterThanOrEqual(contrast(text, surface), 4.5, "\(label) (\(appearance.rawValue))")
            }
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
        let appearance: NSAppearance.Name = scheme == .dark ? .darkAqua : .aqua
        var result: [(String, NSColor)] = []
        let groupFill = resolve(NSColor(LBTokens.Palette.groupFill), in: appearance)
        // Native colors differ by macOS release. Keep a conservative reference
        // for macOS 15's window gray even when tests run on a newer system.
        let reference = scheme == .dark ? 0.20 : 0.92
        let referenceWindow = NSColor(srgbRed: reference, green: reference, blue: reference, alpha: 1)
        for (name, color) in [("window", NSColor.windowBackgroundColor),
                              ("content", NSColor.textBackgroundColor),
                              ("control", NSColor.controlBackgroundColor),
                              ("reference window", referenceWindow)] {
            let surface = resolve(color, in: appearance)
            result.append((name, surface))
            result.append(("grouped \(name)", blend(groupFill, over: surface,
                                                     alpha: Double(groupFill.alphaComponent))))
        }
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
