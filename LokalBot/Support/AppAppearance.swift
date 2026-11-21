import AppKit
import SwiftUI

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

    var menuBarScale: CGFloat {
        max(1, scale / AppTextSize.standard.scale)
    }
}

enum AppTextScale {
    nonisolated(unsafe) static var current: CGFloat = 1

    static func isSystemSize(_ scale: CGFloat) -> Bool { abs(scale - 1) < 0.001 }
}

private struct AppTextScaleKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1
}

extension EnvironmentValues {
    var appTextScale: CGFloat {
        get { self[AppTextScaleKey.self] }
        set { self[AppTextScaleKey.self] = newValue }
    }
}

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

    static func scaled(_ style: Font.TextStyle, design: Font.Design? = nil) -> AppFont {
        AppFont(base: .style(style, design: design))
    }

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
    func font(_ font: AppFont) -> some View {
        modifier(AppFontModifier(font: font))
    }
}

extension Font {
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
    @MainActor
    static func apply(theme: AppTheme) {
        guard ProcessInfo.processInfo.environment["LOKALBOT_CAPTURE_APPEARANCE"] == nil,
              let app = NSApp, app.appearance?.name != theme.appearance?.name else { return }
        app.appearance = theme.appearance
    }

    @MainActor
    static func apply(textSize: AppTextSize) {
        AppTextScale.current = textSize.scale
    }
}

extension View {
    @MainActor
    func appLanguageRoot(_ settingsStore: SettingsStore) -> AppLanguageRoot<Self> {
        AppLanguageRoot(content: self, settingsStore: settingsStore)
    }

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
        let locale = settingsStore.current.appLanguage.locale
        content
            .environment(\.locale, locale)
            .environment(\.layoutDirection, AppLanguage.isRightToLeft(locale) ? .rightToLeft : .leftToRight)
    }
}

nonisolated enum ContentTextDirection {
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
    func contentLayoutDirection(of text: String) -> some View {
        modifier(ContentLayoutDirection(text: text))
    }
}
