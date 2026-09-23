import SwiftUI

/// Flat neutral surfaces, teal actions, and indigo remote model badges.
enum SettingsPalette {
    static func canvas(_ scheme: ColorScheme) -> Color { color(scheme, light: 0xF4F4F4, dark: 0x1C1C1E) }
    static func navigation(_ scheme: ColorScheme) -> Color { color(scheme, light: 0xE9E9E9, dark: 0x242426) }
    static func panel(_ scheme: ColorScheme) -> Color { color(scheme, light: 0xFFFFFF, dark: 0x2C2C2E) }
    static func hover(_ scheme: ColorScheme) -> Color { color(scheme, light: 0xECECEE, dark: 0x39393D) }
    /// The shared brand accent; kept as a palette entry so Settings call sites
    /// read uniformly.
    static func accent(_ scheme: ColorScheme) -> Color { Brand.teal }
    static func remote(_ scheme: ColorScheme) -> Color { color(scheme, light: 0x4D4B9C, dark: 0xB8B2FF) }
    static func warning(_ scheme: ColorScheme) -> Color { color(scheme, light: 0x8C4D06, dark: 0xFFD08A) }

    static func secondary(_ scheme: ColorScheme, contrast: ColorSchemeContrast) -> Color {
        contrast == .increased ? .primary : color(scheme, light: 0x545458, dark: 0xBABAC2)
    }

    static func border(_ scheme: ColorScheme, contrast: ColorSchemeContrast) -> Color {
        contrast == .increased
            ? color(scheme, light: 0x747478, dark: 0x96969C)
            : color(scheme, light: 0xD2D2D5, dark: 0x48484D)
    }

    private static func color(_ scheme: ColorScheme, light: UInt32, dark: UInt32) -> Color {
        let value = scheme == .dark ? dark : light
        return Color(.sRGB, red: Double((value >> 16) & 0xFF) / 255,
                     green: Double((value >> 8) & 0xFF) / 255,
                     blue: Double(value & 0xFF) / 255, opacity: 1)
    }
}

struct SettingsSeparator: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        SettingsPalette.border(scheme, contrast: contrast)
            .frame(height: contrast == .increased ? 2 : 1)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

private struct SettingsPanelModifier: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Brand.Radius.compactPanel, style: .continuous)
        content
            .background(SettingsPalette.panel(scheme), in: shape)
            .overlay {
                shape.strokeBorder(SettingsPalette.border(scheme, contrast: contrast),
                                   lineWidth: contrast == .increased ? 2 : 1)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
    }
}

private struct SettingsSecondaryModifier: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content.foregroundStyle(SettingsPalette.secondary(scheme, contrast: contrast))
    }
}

private struct SettingsModelLocationModifier: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    let destination: InferencePresentation

    @ViewBuilder func body(content: Content) -> some View {
        if case .remote = destination {
            content
                .foregroundStyle(SettingsPalette.remote(scheme))
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(SettingsPalette.remote(scheme).opacity(scheme == .dark ? 0.16 : 0.08), in: Capsule())
        } else {
            content.settingsSecondary()
        }
    }
}

private struct SettingsModelIconModifier: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    let destination: InferencePresentation

    func body(content: Content) -> some View {
        content.foregroundStyle(tint)
    }

    private var tint: Color {
        switch destination {
        case .onDevice: SettingsPalette.accent(scheme)
        case .remote: SettingsPalette.remote(scheme)
        case .blocked: SettingsPalette.warning(scheme)
        }
    }
}

/// Clear button edges and a strong primary fill, while retaining native
/// Button keyboard activation, focus, accessibility, and disabled semantics.
struct SettingsActionButtonStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        SettingsActionButton(configuration: configuration, prominent: prominent)
    }
}

private struct SettingsActionButton: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovered = false
    let configuration: ButtonStyleConfiguration
    let prominent: Bool

    var body: some View {
        let accent = SettingsPalette.accent(scheme)
        let shape = RoundedRectangle(cornerRadius: Brand.Radius.tab, style: .continuous)
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 12).padding(.vertical, 7)
            .foregroundStyle(prominent ? Color.white : accent)
            .background(background, in: shape)
            .overlay {
                shape.strokeBorder((prominent ? Brand.tealFill : accent).opacity(prominent || contrast == .increased ? 1 : 0.7), lineWidth: 1)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.45)
            .onHover { hovered = $0 }
    }

    private var background: Color {
        if prominent { return Brand.tealFill }
        return hovered || configuration.isPressed ? SettingsPalette.hover(scheme) : SettingsPalette.panel(scheme)
    }
}

extension View {
    func settingsPanel() -> some View {
        modifier(SettingsPanelModifier())
    }

    func settingsSecondary() -> some View {
        modifier(SettingsSecondaryModifier())
    }

    func settingsModelLocation(_ destination: InferencePresentation) -> some View {
        modifier(SettingsModelLocationModifier(destination: destination))
    }

    func settingsModelIcon(_ destination: InferencePresentation = .onDevice) -> some View {
        modifier(SettingsModelIconModifier(destination: destination))
    }
}
