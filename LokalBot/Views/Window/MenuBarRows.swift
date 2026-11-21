import AppKit
import SwiftUI

private struct MenuBarRowHighlightedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var menuBarRowHighlighted: Bool {
        get { self[MenuBarRowHighlightedKey.self] }
        set { self[MenuBarRowHighlightedKey.self] = newValue }
    }
}

enum MenuBarMetric {
    static let panelWidth: CGFloat = 312
    static let rowHeight: CGFloat = 26
    static let rowInset: CGFloat = 5
    static let rowPadding: CGFloat = 10
    static let rowRadius: CGFloat = 5
    static let iconWidth: CGFloat = 16
    static let iconSpacing: CGFloat = 9
    static let separatorInset: CGFloat = 12
}

struct MenuBarRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        MenuBarRowChrome(configuration: configuration)
    }
}

private struct MenuBarRowChrome: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovered = false

    var body: some View {
        let highlighted = isEnabled && (hovered || configuration.isPressed)
        configuration.label
            .environment(\.menuBarRowHighlighted, highlighted)
            .foregroundStyle(highlighted
                ? AnyShapeStyle(Color(nsColor: .selectedMenuItemTextColor))
                : isEnabled ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
            .padding(.horizontal, MenuBarMetric.rowPadding)
            .padding(.vertical, 3)
            .frame(maxWidth: .infinity, minHeight: MenuBarMetric.rowHeight, alignment: .leading)
            .background(
                highlighted ? LBTokens.Palette.accentFill : Color.clear,
                in: RoundedRectangle(cornerRadius: MenuBarMetric.rowRadius, style: .continuous))
            .padding(.horizontal, MenuBarMetric.rowInset)
            .contentShape(Rectangle())
            .onHover { hovered = $0 }
            .onChange(of: isEnabled) { _, enabled in
                if !enabled { hovered = false }
            }
    }
}

struct MenuBarRowLabel<Trailing: View>: View {
    enum DetailTone {
        case quiet
        case attention
    }

    let title: Text
    let icon: String
    var detail: Text?
    var detailTone: DetailTone = .quiet
    @ViewBuilder var trailing: Trailing

    @Environment(\.menuBarRowHighlighted) private var highlighted
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        HStack(alignment: detail == nil ? .center : .top, spacing: MenuBarMetric.iconSpacing) {
            MenuBarRowIcon(name: icon)
                .padding(.top, detail == nil ? 0 : 1)
            VStack(alignment: .leading, spacing: 0) {
                title
                    .font(AppFont.scaled(.body))
                    .lineLimit(1)
                if let detail {
                    detail
                        .font(AppFont.scaled(.callout))
                        .foregroundStyle(detailStyle)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 12)
            trailing
                .font(AppFont.scaled(.callout).monospacedDigit())
                .foregroundStyle(trailingStyle)
                .lineLimit(1)
                .fixedSize()
        }
    }

    private var detailStyle: AnyShapeStyle {
        if highlighted { return AnyShapeStyle(Color(nsColor: .selectedMenuItemTextColor).opacity(0.85)) }
        if !isEnabled { return AnyShapeStyle(.quaternary) }
        switch detailTone {
        case .quiet: return AnyShapeStyle(.secondary)
        case .attention: return AnyShapeStyle(LBTokens.Palette.attentionText)
        }
    }

    private var trailingStyle: AnyShapeStyle {
        if highlighted { return AnyShapeStyle(Color(nsColor: .selectedMenuItemTextColor)) }
        return isEnabled ? AnyShapeStyle(.secondary) : AnyShapeStyle(.quaternary)
    }
}

extension MenuBarRowLabel where Trailing == EmptyView {
    init(title: Text, icon: String, detail: Text? = nil, detailTone: DetailTone = .quiet) {
        self.init(title: title, icon: icon, detail: detail, detailTone: detailTone) { EmptyView() }
    }
}

struct MenuBarRowIcon: View {
    let name: String
    @Environment(\.menuBarRowHighlighted) private var highlighted
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Image(systemName: name)
            .font(AppFont.scaled(.body))
            .foregroundStyle(highlighted
                ? AnyShapeStyle(Color(nsColor: .selectedMenuItemTextColor))
                : isEnabled ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
            .frame(width: MenuBarMetric.iconWidth)
            .accessibilityHidden(true)
    }
}

struct MenuBarShortcutText: View {
    let label: String

    var body: some View {
        Text(verbatim: label)
    }
}

struct MenuBarSeparator: View {
    var body: some View {
        Divider()
            .padding(.horizontal, MenuBarMetric.separatorInset)
            .padding(.vertical, 5)
    }
}

struct MenuBarGroupHeading: View {
    let title: LocalizedStringKey

    var body: some View {
        Text(title)
            .font(AppFont.scaled(.subheadline).weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, MenuBarMetric.rowInset + MenuBarMetric.rowPadding)
            .padding(.vertical, 3)
            .accessibilityAddTraits(.isHeader)
    }
}

struct MenuBarSwitchRow: View {
    let title: LocalizedStringKey
    let icon: String
    let help: LocalizedStringKey
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: MenuBarMetric.iconSpacing) {
            MenuBarRowIcon(name: icon)
            Text(title)
                .font(AppFont.scaled(.body))
                .lineLimit(1)
            Spacer(minLength: 12)
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .tint(LBTokens.Palette.accentFill)
                .help(help)
        }
        .padding(.horizontal, MenuBarMetric.rowInset + MenuBarMetric.rowPadding)
        .frame(maxWidth: .infinity, minHeight: MenuBarMetric.rowHeight, alignment: .leading)
    }
}

struct WindowVisibilityReader: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> Probe {
        let probe = Probe()
        probe.onChange = onChange
        return probe
    }

    func updateNSView(_ probe: Probe, context: Context) {
        probe.onChange = onChange
    }

    final class Probe: NSView {
        var onChange: (Bool) -> Void = { _ in }
        private var observer: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            guard let window else {
                reportCurrent()
                return
            }
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.reportCurrent() }
            }
            reportCurrent()
        }

        private func reportCurrent() {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.onChange(self.window?.occlusionState.contains(.visible) == true)
            }
        }

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
    }
}
