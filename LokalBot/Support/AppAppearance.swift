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
/// LokalBot scales its own text styles; the default size is unchanged.
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
        case .small: 0.9
        case .standard: 1
        case .large: 1.12
        case .larger: 1.25
        case .largest: 1.4
        }
    }
}

/// The scale read while views build their fonts. Written only on the main
/// actor when the preference changes; windows then rebuild their content.
enum AppTextScale {
    nonisolated(unsafe) static var current: CGFloat = 1

    static var isDefault: Bool { abs(current - 1) < 0.001 }
}

extension Font {
    /// A macOS text style at the user's text size. The default size returns
    /// the system text style itself, so standard rendering is unchanged.
    static func scaled(_ style: Font.TextStyle, design: Font.Design? = nil) -> Font {
        guard !AppTextScale.isDefault else {
            return design.map { .system(style, design: $0) } ?? .system(style)
        }
        let metrics = macTextStyleMetrics(style)
        return .system(size: (metrics.size * AppTextScale.current).rounded(),
                       weight: metrics.weight, design: design ?? .default)
    }

    /// A fixed-size text font that still follows the user's text size.
    static func scaledSystem(size: CGFloat, weight: Font.Weight = .regular,
                             design: Font.Design = .default) -> Font {
        .system(size: (size * AppTextScale.current).rounded(), weight: weight, design: design)
    }

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

extension NSFont {
    /// AppKit-drawn text that should follow the user's text size.
    static func scaledSystemFont(ofSize size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        .systemFont(ofSize: (size * AppTextScale.current).rounded(), weight: weight)
    }
}

enum AppAppearance {
    /// Applies theme and text size app-wide. Capture builds that pin an
    /// appearance through the environment keep that pinned appearance.
    @MainActor
    static func apply(theme: AppTheme, textSize: AppTextSize) {
        AppTextScale.current = textSize.scale
        guard ProcessInfo.processInfo.environment["LOKALBOT_CAPTURE_APPEARANCE"] == nil else { return }
        NSApp?.appearance = theme.appearance
    }
}

extension View {
    /// Window roots rebuild when the text size changes so every view picks
    /// up fonts computed at the new scale.
    func appTextSizeRoot(_ textSize: AppTextSize) -> some View {
        id(textSize)
    }
}
