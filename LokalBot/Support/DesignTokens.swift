import AppKit
import SwiftUI

// Tokens for the macOS-native UI refresh. See DESIGN-SPEC.md, section 3.
//
// Prefer system semantic colors (.primary, .secondary, .separator) and text
// styles (.body, .headline); these tokens cover only what the system does not
// provide. Shared by all app surfaces in both system appearances.

enum LBTokens {

    // MARK: - Color

    enum Palette {
        /// Set the AccentColor asset to this value in both appearances. White
        /// text on it meets 4.5:1, so it is safe for selected rows in a focused
        /// list, prominent buttons, switches and checkboxes.
        static let accentFill = Color(hex: 0x0C8275)

        /// Accent for links, timestamps, sidebar symbols and evidence chips.
        /// The bright teal only appears on dark backgrounds.
        static let accentText = Brand.teal

        /// Needs attention (speakers banner, remote dot, approvals): fills,
        /// tints and dots. Use `attentionText` for words.
        static let attention = Color.orange
        /// "Owner unclear", "Download required". The system orange is too
        /// light for text on white, so light appearance uses a darker orange.
        static let attentionText = Color(light: 0x984C00, dark: 0xFFB84D)
        static let success = Color.green
        static let successText = Color(light: 0x176F2C, dark: 0x4BDC71)
        /// Recording, destructive actions and overdue dates.
        static let recording = Color.red
        static let recordingText = Color(light: 0xB60012, dark: 0xFF9C95)

        /// Fill and stroke for grouped sections (10 pt rounded rectangles):
        /// a light gray well on white, a faint white lift on dark.
        static let statusFillOpacity = 0.10
        static let groupFill = Color(nsColor: .adaptive(light: NSColor(white: 0, alpha: 0.035), dark: NSColor(white: 1, alpha: 0.05)))
        static let groupStroke = Color(nsColor: .adaptive(light: NSColor(white: 0, alpha: 0.07), dark: NSColor(white: 1, alpha: 0.06)))

        /// Speakers in order of first appearance. Index 0 is always "You".
        /// Always show the name next to the color.
        static let speakers: [Color] = [accentText, .blue, .purple, .pink, Color(light: 0xD9A400, dark: 0xFFD60A), .indigo, .brown, .cyan]
        /// The collapsed group of brief voices ("5 others").
        static let groupedSpeakers = Color.gray

        static func speaker(at index: Int) -> Color {
            speakers[((index % speakers.count) + speakers.count) % speakers.count]
        }
    }

    // MARK: - Typography (macOS default sizes in comments)

    enum Typography {
        static var pageTitle: Font { Font.scaled(.largeTitle).bold() }           // 26 bold
        static var question: Font { Font.scaled(.title2).weight(.semibold) }     // 17 semibold, Ask
        static var digestLead: Font { Font.scaled(.title3) }                     // 15, Day Digest highlights
        static var columnTitle: Font { Font.scaled(.title3).bold() }             // 15 bold, toolbar column titles
        static var section: Font { Font.scaled(.headline) }                      // 13 bold
        static var body: Font { Font.scaled(.body) }                             // 13
        static var reading: Font { Font.scaledSystem(size: 14) }              // transcript lines
        static var secondary: Font { Font.scaled(.callout) }                     // 12
        static var caption: Font { Font.scaled(.subheadline) }                   // 11
        static var sidebarSection: Font { Font.scaled(.subheadline).bold() }     // 11 bold
        static var timestamp: Font { Font.scaled(.callout).monospacedDigit() }
        static var path: Font { Font.scaled(.callout, design: .monospaced) }
    }

    // MARK: - Metrics

    enum Metric {
        static let sidebarWidth: CGFloat = 216
        static let sidebarMinWidth: CGFloat = 200
        static let contentColumnWidth: CGFloat = 272
        static let settingsCategoriesWidth: CGFloat = 240
        static let detailsPaneWidth: CGFloat = 320
        static let contentColumnRange: ClosedRange<CGFloat> = 240...340
        static let detailPadding: CGFloat = 28
        static let sectionSpacing: CGFloat = 22
        static let headerToContent: CGFloat = 8
        static let groupRadius: CGFloat = 10
        static let rowSelectionRadius: CGFloat = 8
        static let sidebarRowHeight: CGFloat = 28
        static let tableRowHeight: CGFloat = 34
        static let readingMaxWidth: CGFloat = 720
        static let composerRadius: CGFloat = 18
        static let actionToggleSize: CGFloat = 18
        static let minimumWindow = CGSize(width: 1000, height: 700)
    }
}

// MARK: - Surfaces

extension View {
    /// The grouped section surface behind Recap, Action Items, Decisions,
    /// Evidence and details panes.
    func lbGroupedSurface() -> some View {
        modifier(LBGroupedSurface())
    }

    /// Glass on macOS 26, with an opaque fallback for Reduce Transparency.
    func lbFloatingComposer() -> some View {
        modifier(LBFloatingComposer())
    }

    /// Status surfaces retain a visible boundary with Increase Contrast.
    func lbStatusSurface(_ color: Color) -> some View {
        modifier(LBGroupedSurface(tint: color))
    }
}

private struct LBGroupedSurface: ViewModifier {
    @Environment(\.colorSchemeContrast) private var contrast
    var tint: Color?

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: LBTokens.Metric.groupRadius, style: .continuous)
        content
            .background(tint?.opacity(LBTokens.Palette.statusFillOpacity) ?? LBTokens.Palette.groupFill, in: shape)
            .overlay {
                shape.strokeBorder(
                    contrast == .increased ? Color.primary.opacity(0.5)
                        : tint?.opacity(0.28) ?? LBTokens.Palette.groupStroke,
                    lineWidth: contrast == .increased ? 2 : 1)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
    }
}

private struct LBFloatingComposer: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    @ViewBuilder func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: LBTokens.Metric.composerRadius, style: .continuous)
        Group {
            if reduceTransparency {
                content.background(Color(nsColor: .controlBackgroundColor), in: shape)
            } else if #available(macOS 26, *) {
                content.glassEffect(.regular, in: shape)
            } else {
                content.background(.regularMaterial, in: shape)
            }
        }
        .overlay {
            shape.strokeBorder(Color.primary.opacity(contrast == .increased ? 0.5 : 0.10),
                               lineWidth: contrast == .increased ? 2 : 1)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

}

// MARK: - Action item toggle

/// Native switches keep the filled accent even when nearby bordered buttons
/// use the brighter text accent in dark appearance.
struct LBAccentSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Toggle(configuration).toggleStyle(.switch).tint(LBTokens.Palette.accentFill)
    }
}

/// Round Reminders-style toggle used for action items everywhere they appear.
struct ActionItemToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Button {
                configuration.isOn.toggle()
            } label: {
                Image(systemName: configuration.isOn ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: LBTokens.Metric.actionToggleSize - 1))
                    .foregroundStyle(configuration.isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(configuration.isOn ? "Mark as Open" : "Mark as Done")
            configuration.label
        }
    }
}

// MARK: - Helpers

private extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255)
    }

    init(light: UInt32, dark: UInt32) {
        self.init(nsColor: .adaptive(light: NSColor(Color(hex: light)), dark: NSColor(Color(hex: dark))))
    }
}

private extension NSColor {
    static func adaptive(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        }
    }
}
