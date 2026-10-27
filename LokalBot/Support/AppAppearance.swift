import AppKit
import SwiftUI

/// The app's own light/dark preference, independent of the system setting.
enum AppTheme: String, Codable, CaseIterable, Identifiable, Sendable {
    case system, light, dark

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: "Match System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var appearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

/// App-wide text size. macOS text styles ignore SwiftUI's Dynamic Type, so
/// LokalBot scales its own text styles. Default reads one point larger than
/// macOS body text (14 pt); Small is the unscaled system size.
enum AppTextSize: String, Codable, CaseIterable, Identifiable, Sendable {
    case small, standard, large, larger, largest

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .small: "Small"
        case .standard: "Default"
        case .large: "Large"
        case .larger: "Larger"
        case .largest: "Largest"
        }
    }

    var scale: CGFloat {
        switch self {
        case .small: 1
        case .standard: 14.0 / 13.0
        case .large: 1.18
        case .larger: 1.3
        case .largest: 1.45
        }
    }

    /// The menu bar panel is a compact surface beside the system's own menu
    /// bar extras, which use the macOS sizes. Default and Small keep those
    /// sizes; larger settings grow relative to Default, so the panel no longer
    /// reads a point larger than every other menu bar item.
    var menuBarScale: CGFloat {
        max(1, scale / AppTextSize.standard.scale)
    }
}

/// The current scale for AppKit-drawn text and code that has no SwiftUI
/// environment. SwiftUI text reads `\.appTextScale` instead.
enum AppTextScale {
    nonisolated(unsafe) static var current: CGFloat = 1

    /// The unscaled macOS size, where text styles are used as they are.
    static func isSystemSize(_ scale: CGFloat) -> Bool { abs(scale - 1) < 0.001 }
}

private struct AppTextScaleKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1
}

extension EnvironmentValues {
    /// The user's text size. Window roots set it; `AppFont` reads it when a
    /// view renders, so a change redraws text without rebuilding windows.
    var appTextScale: CGFloat {
        get { self[AppTextScaleKey.self] }
        set { self[AppTextScaleKey.self] = newValue }
    }
}

/// A font description resolved against the environment's text scale at
/// render time. The unscaled size resolves to the system text style itself.
struct AppFont: Hashable, Sendable {
    enum Base: Hashable, Sendable {
        case style(Font.TextStyle, design: Font.Design?)
        case size(CGFloat, weight: Font.Weight, design: Font.Design)
    }

    enum Modifier: Hashable, Sendable {
        case weight(Font.Weight)
        case bold
        case monospaced
        case monospacedDigit
    }

    var base: Base
    var modifiers: [Modifier] = []

    /// A macOS text style at the user's text size.
    static func scaled(_ style: Font.TextStyle, design: Font.Design? = nil) -> AppFont {
        AppFont(base: .style(style, design: design))
    }

    /// A fixed-size text font that still follows the user's text size.
    static func scaledSystem(size: CGFloat, weight: Font.Weight = .regular,
                             design: Font.Design = .default) -> AppFont {
        AppFont(base: .size(size, weight: weight, design: design))
    }

    func weight(_ weight: Font.Weight) -> AppFont { adding(.weight(weight)) }
    func bold() -> AppFont { adding(.bold) }
    func monospaced() -> AppFont { adding(.monospaced) }
    func monospacedDigit() -> AppFont { adding(.monospacedDigit) }

    func resolved(scale: CGFloat) -> Font {
        var font: Font
        switch base {
        case let .style(style, design):
            if AppTextScale.isSystemSize(scale) {
                font = design.map { .system(style, design: $0) } ?? .system(style)
            } else {
                let metrics = Font.macTextStyleMetrics(style)
                font = .system(size: (metrics.size * scale).rounded(),
                               weight: metrics.weight, design: design ?? .default)
            }
        case let .size(size, weight, design):
            font = .system(size: (size * scale).rounded(), weight: weight, design: design)
        }
        for modifier in modifiers {
            switch modifier {
            case .weight(let weight): font = font.weight(weight)
            case .bold: font = font.bold()
            case .monospaced: font = font.monospaced()
            case .monospacedDigit: font = font.monospacedDigit()
            }
        }
        return font
    }

    /// For code without a SwiftUI environment (AppKit bridges, attributed text).
    var currentFont: Font { resolved(scale: AppTextScale.current) }

    private func adding(_ modifier: Modifier) -> AppFont {
        var copy = self
        copy.modifiers.append(modifier)
        return copy
    }
}

private struct AppFontModifier: ViewModifier {
    @Environment(\.appTextScale) private var scale
    let font: AppFont

    func body(content: Content) -> some View {
        content.font(font.resolved(scale: scale))
    }
}

extension View {
    /// Applies a font that follows the user's text size.
    func font(_ font: AppFont) -> some View {
        modifier(AppFontModifier(font: font))
    }
}

extension Font {
    /// Point sizes and weights of the macOS text styles.
    static func macTextStyleMetrics(_ style: Font.TextStyle) -> (size: CGFloat, weight: Font.Weight) {
        switch style {
        case .largeTitle: (26, .regular)
        case .title: (22, .regular)
        case .title2: (17, .regular)
        case .title3: (15, .regular)
        case .headline: (13, .bold)
        case .subheadline: (11, .regular)
        case .body: (13, .regular)
        case .callout: (12, .regular)
        case .footnote: (10, .regular)
        case .caption: (10, .regular)
        case .caption2: (10, .regular)
        @unknown default: (13, .regular)
        }
    }
}

enum AppAppearance {
    /// Applies the theme app-wide. Capture builds that pin an appearance
    /// through the environment keep it. Reassigning an unchanged appearance
    /// would make every window re-resolve its colors, so it is skipped.
    @MainActor
    static func apply(theme: AppTheme) {
        guard ProcessInfo.processInfo.environment["LOKALBOT_CAPTURE_APPEARANCE"] == nil,
              let app = NSApp, app.appearance?.name != theme.appearance?.name else { return }
        app.appearance = theme.appearance
    }

    /// Keeps AppKit-drawn text in step; SwiftUI text follows the environment.
    @MainActor
    static func apply(textSize: AppTextSize) {
        AppTextScale.current = textSize.scale
    }
}

extension View {
    /// Every hosting root observes the same preference, including AppKit panels
    /// whose content is created only once. Preserve child identity on changes.
    @MainActor
    func appLanguageRoot(_ settingsStore: SettingsStore) -> AppLanguageRoot<Self> {
        AppLanguageRoot(content: self, settingsStore: settingsStore)
    }

    /// Window roots publish the text size; only text redraws when it changes.
    func appTextSizeRoot(_ textSize: AppTextSize) -> some View {
        environment(\.appTextScale, textSize.scale)
    }

    func menuBarTextSizeRoot(_ textSize: AppTextSize) -> some View {
        environment(\.appTextScale, textSize.menuBarScale)
    }
}

@MainActor
struct AppLanguageRoot<Content: View>: View {
    let content: Content
    @ObservedObject var settingsStore: SettingsStore

    var body: some View {
        // Resolve the preference once; the direction comes from the same locale.
        let locale = settingsStore.current.appLanguage.locale
        content
            .environment(\.locale, locale)
            .environment(\.layoutDirection, AppLanguage.isRightToLeft(locale) ? .rightToLeft : .leftToRight)
    }
}

/// User content keeps the direction of its own text rather than the
/// interface's, so an English transcript stays left-aligned in an Arabic or
/// Urdu interface and an Arabic one stays right-aligned in English.
nonisolated enum ContentTextDirection {
    /// The first strong letter decides, as in Unicode bidi rule P2. Text with
    /// no letters returns nil and keeps the surrounding direction.
    static func layoutDirection(of text: String) -> LayoutDirection? {
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x0590...0x08FF, 0xFB1D...0xFDFF, 0xFE70...0xFEFF, 0x061C, 0x200F:
                return .rightToLeft
            case 0x200E:
                return .leftToRight
            default:
                if scalar.properties.isAlphabetic { return .leftToRight }
            }
        }
        return nil
    }
}

private struct ContentLayoutDirection: ViewModifier {
    let text: String
    @Environment(\.layoutDirection) private var interfaceDirection

    func body(content: Content) -> some View {
        content.environment(\.layoutDirection, ContentTextDirection.layoutDirection(of: text) ?? interfaceDirection)
    }
}

extension View {
    /// Apply after the content's frame so its leading alignment follows the text.
    func contentLayoutDirection(of text: String) -> some View {
        modifier(ContentLayoutDirection(text: text))
    }
}
