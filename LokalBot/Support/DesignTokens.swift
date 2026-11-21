import AppKit
import SwiftUI

enum LBTokens {

    enum Palette {
        static let accentFill = Color(hex: 0x0C8275)

        static let accentText = Brand.teal

        static let attention = Color.orange
        static let attentionText = Color(light: 0x984C00, dark: 0xFFB84D)
        static let success = Color.green
        static let successText = Color(light: 0x176F2C, dark: 0x4BDC71)
        static let recording = Color.red
        static let recordingText = Color(light: 0xB60012, dark: 0xFF9C95)

        static let statusFillOpacity = 0.10
        static let groupFill = Color(nsColor: .adaptive(light: NSColor(white: 0, alpha: 0.035), dark: NSColor(white: 1, alpha: 0.05)))
        static let groupStroke = Color(nsColor: .adaptive(light: NSColor(white: 0, alpha: 0.07), dark: NSColor(white: 1, alpha: 0.06)))
        static let quietFill = Color(nsColor: .adaptive(light: NSColor(white: 0, alpha: 0.06), dark: NSColor(white: 1, alpha: 0.10)))

        static let speakers: [Color] = [accentText, .blue, .purple, .pink, Color(light: 0xD9A400, dark: 0xFFD60A), .indigo, .brown, .cyan]

        static func speaker(at index: Int) -> Color {
            speakers[((index % speakers.count) + speakers.count) % speakers.count]
        }
    }

    enum Typography {
        static var pageTitle: AppFont { AppFont.scaled(.largeTitle).bold() }
        static var question: AppFont { AppFont.scaled(.title2).weight(.semibold) }
        static var columnTitle: AppFont { AppFont.scaled(.title3).bold() }
        static var section: AppFont { AppFont.scaled(.headline) }
        static var body: AppFont { AppFont.scaled(.body) }
        static var reading: AppFont { AppFont.scaledSystem(size: 14) }
        static var secondary: AppFont { AppFont.scaled(.callout) }
        static var caption: AppFont { AppFont.scaled(.subheadline) }
        static var timestamp: AppFont { AppFont.scaled(.callout).monospacedDigit() }
        static var path: AppFont { AppFont.scaled(.callout, design: .monospaced) }
    }

    enum Metric {
        static let sidebarWidth: CGFloat = 216
        static let sidebarMinWidth: CGFloat = 200
        static let contentColumnWidth: CGFloat = 272
        static let contentColumnMinWidth: CGFloat = 240
        static let contentDetailMinWidth: CGFloat = 420
        static let settingsCategoriesWidth: CGFloat = 240
        static let detailsPaneWidth: CGFloat = 320
        static let detailPadding: CGFloat = 28
        static let sectionSpacing: CGFloat = 22
        static let headerToContent: CGFloat = 8
        static let groupRadius: CGFloat = 10
        static let sidebarRowHeight: CGFloat = 28
        static let tableRowHeight: CGFloat = 34
        static let readingMaxWidth: CGFloat = 720
        static let composerRadius: CGFloat = 18
        static let actionToggleSize: CGFloat = 18
    }
}

extension View {
    func lbGroupedSurface() -> some View {
        modifier(LBGroupedSurface())
    }

    func lbFloatingComposer() -> some View {
        modifier(LBFloatingComposer())
    }

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

struct LBAccentSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Toggle(configuration).toggleStyle(.switch).tint(LBTokens.Palette.accentFill)
    }
}

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
