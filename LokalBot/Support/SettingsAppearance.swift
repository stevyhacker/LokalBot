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

// MARK: - Row labels

/// One-sentence explanation shown under a settings control. It is smaller and
/// quieter than the control label so each row reads as one setting.
struct SettingsHelp: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .settingsSecondary()
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A settings control label: the title with its explanation attached, for use
/// as the label of a Toggle, Picker, Stepper, or LabeledContent.
struct SettingsLabel: View {
    let title: String
    let help: String?

    init(_ title: String, help: String? = nil) {
        self.title = title
        self.help = help
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
            if let help { SettingsHelp(help) }
        }
    }
}

/// Longer mechanics behind a collapsed disclosure, so the default view of a
/// section stays a list of controls.
struct SettingsDetails: View {
    let title: String
    let text: String

    init(_ title: String = "How this works", _ text: String) {
        self.title = title
        self.text = text
    }

    var body: some View {
        DisclosureGroup {
            SettingsHelp(text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
        } label: {
            Text(title).font(.system(size: 12, weight: .medium)).settingsSecondary()
        }
    }
}
