import SwiftUI

// MARK: - Surfaces

extension View {
    /// The grouped section surface behind Recap, Action Items, Decisions and
    /// details: a 10 pt rounded well with a hairline.
    public func lbGroupedSurface(radius: CGFloat = LBTokens.Radius.panel) -> some View {
        modifier(LBGroupedSurface(radius: radius))
    }

    /// A tinted status surface; keeps a visible boundary with Increase Contrast.
    public func lbStatusSurface(_ tint: Color, radius: CGFloat = LBTokens.Radius.panel) -> some View {
        modifier(LBGroupedSurface(radius: radius, tint: tint))
    }

    /// Liquid Glass on iOS 26, a material before it, and an opaque fill with
    /// Reduce Transparency, like the Mac's composer.
    public func lbFloatingComposer() -> some View {
        modifier(LBFloatingComposer())
    }

    /// The docked composer used by Ask, with a teal ring while focused.
    public func composerChrome(focused: Bool) -> some View {
        modifier(ComposerChromeModifier(focused: focused))
    }
}

private struct LBGroupedSurface: ViewModifier {
    @Environment(\.colorSchemeContrast) private var contrast
    var radius: CGFloat
    var tint: Color?

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .background(tint?.opacity(LBTokens.Palette.statusFillOpacity) ?? LBTokens.Palette.groupFill, in: shape)
            .overlay {
                shape.strokeBorder(
                    contrast == .increased ? Color.primary.opacity(0.5) : tint?.opacity(0.28) ?? LBTokens.Palette.groupStroke,
                    lineWidth: contrast == .increased ? 2 : 1)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
    }
}

private struct LBFloatingComposer: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: LBTokens.Radius.composer, style: .continuous)
        Group {
            if reduceTransparency {
                content.background(LBTokens.Palette.elevated, in: shape)
            } else if #available(iOS 26, macOS 26, *) {
                content.glassEffect(.regular.interactive(), in: shape)
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

private struct ComposerChromeModifier: ViewModifier {
    @Environment(\.colorSchemeContrast) private var contrast
    let focused: Bool

    func body(content: Content) -> some View {
        content
            .lbFloatingComposer()
            .overlay {
                if focused {
                    RoundedRectangle(cornerRadius: LBTokens.Radius.composer, style: .continuous)
                        .strokeBorder(Brand.teal.opacity(contrast == .increased ? 1 : 0.45))
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
    }
}

// MARK: - Text roles

/// Text importance independent of layout: metadata may be quiet, but trust and
/// warning text stays readable in every appearance and with Increase Contrast.
public enum WorkspaceTextRole: Sendable {
    case metadata
    case supporting
    case trust
    case warning
}

extension View {
    public func workspaceTextRole(_ role: WorkspaceTextRole) -> some View {
        modifier(WorkspaceTextRoleModifier(role: role))
    }

    /// The supporting color, keeping the caller's font; primary with Increase Contrast.
    public func workspaceSupportingForeground() -> some View {
        modifier(WorkspaceSupportingForegroundModifier())
    }
}

private struct WorkspaceTextRoleModifier: ViewModifier {
    @Environment(\.colorSchemeContrast) private var contrast
    let role: WorkspaceTextRole

    func body(content: Content) -> some View {
        switch role {
        case .metadata:
            content.font(LBTokens.Typography.secondary)
                .foregroundStyle(contrast == .increased ? Color.primary : LBTokens.Palette.supporting)
        case .supporting:
            content.font(LBTokens.Typography.body)
                .foregroundStyle(contrast == .increased ? Color.primary : LBTokens.Palette.supporting)
        case .trust:
            content.font(LBTokens.Typography.body).foregroundStyle(Color.primary)
        case .warning:
            content.font(LBTokens.Typography.body)
                .foregroundStyle(contrast == .increased ? Color.primary : LBTokens.Palette.attentionText)
        }
    }
}

private struct WorkspaceSupportingForegroundModifier: ViewModifier {
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content.foregroundStyle(contrast == .increased ? Color.primary : LBTokens.Palette.supporting)
    }
}

// MARK: - Buttons

extension View {
    /// The one filled call to action on a surface: white on the deep accent.
    public func primaryActionButton() -> some View {
        buttonStyle(.borderedProminent).tint(Brand.tealFill)
    }

    /// Pointer hover on iPad; nothing elsewhere.
    @ViewBuilder public func lbHoverEffect() -> some View {
        #if os(iOS)
        hoverEffect(.highlight)
        #else
        self
        #endif
    }
}

/// Inline navigation and utility actions as accent text, replacing `.link`.
public struct WorkspaceLinkButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        WorkspaceLinkButton(configuration: configuration)
    }
}

private struct WorkspaceLinkButton: View {
    @Environment(\.isEnabled) private var isEnabled
    let configuration: ButtonStyleConfiguration

    var body: some View {
        configuration.label
            .foregroundStyle(Brand.teal)
            .opacity(isEnabled ? (configuration.isPressed ? 0.6 : 1) : 0.45)
            .contentShape(Rectangle())
    }
}

extension ButtonStyle where Self == WorkspaceLinkButtonStyle {
    public static var workspaceLink: WorkspaceLinkButtonStyle { .init() }
}
