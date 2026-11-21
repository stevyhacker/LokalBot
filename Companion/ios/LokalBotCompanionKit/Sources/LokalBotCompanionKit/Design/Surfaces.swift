import SwiftUI

extension View {
    public func lbGroupedSurface(radius: CGFloat = LBTokens.Radius.panel) -> some View {
        modifier(LBGroupedSurface(radius: radius))
    }

    public func lbStatusSurface(_ tint: Color, radius: CGFloat = LBTokens.Radius.panel) -> some View {
        modifier(LBGroupedSurface(radius: radius, tint: tint))
    }

    public func lbFloatingComposer() -> some View {
        modifier(LBFloatingComposer())
    }

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

extension View {
    public func primaryActionButton() -> some View {
        buttonStyle(.borderedProminent).tint(Brand.tealFill)
    }

    @ViewBuilder public func lbHoverEffect() -> some View {
        #if os(iOS)
        hoverEffect(.highlight)
        #else
        self
        #endif
    }
}

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
