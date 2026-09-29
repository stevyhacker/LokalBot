import SwiftUI

/// Native form surfaces with shared accent and semantic status colors.
enum SettingsPalette {
    static func accent(_ scheme: ColorScheme) -> Color { Brand.teal }
    static func remote(_ scheme: ColorScheme) -> Color { LBTokens.Palette.attentionText }
    static func warning(_ scheme: ColorScheme) -> Color { LBTokens.Palette.attentionText }
    static func hover(_ scheme: ColorScheme) -> Color { Color.primary.opacity(0.06) }
    static func secondary(_ scheme: ColorScheme, contrast: ColorSchemeContrast) -> Color {
        contrast == .increased ? .primary : .secondary
    }
}

struct SettingsSeparator: View {
    var body: some View { Divider() }
}

private struct SettingsPanelModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.lbGroupedSurface()
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
            .font(.scaled(.callout))
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
            Text(title).font(.scaled(.callout).weight(.medium)).settingsSecondary()
        }
    }
}
