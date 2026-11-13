import AppKit
import SwiftUI

// The menu bar panel's rows, shaped like a system status menu: an icon, the
// words, and a shortcut or a time at the far side. The pointer highlights
// the whole row, and the icon follows the text's colour in every state.

private struct MenuBarRowHighlightedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// The pointer is over the menu row this view sits in.
    var menuBarRowHighlighted: Bool {
        get { self[MenuBarRowHighlightedKey.self] }
        set { self[MenuBarRowHighlightedKey.self] = newValue }
    }
}

enum MenuBarMetric {
    /// The panel at the default text size. It widens with larger text.
    static let panelWidth: CGFloat = 312
    static let rowHeight: CGFloat = 26
    static let rowInset: CGFloat = 5
    static let rowPadding: CGFloat = 10
    static let rowRadius: CGFloat = 5
    static let iconWidth: CGFloat = 16
    static let iconSpacing: CGFloat = 9
    /// Where a separator and a group heading start and end.
    static let separatorInset: CGFloat = 12
}

/// A row that does something when clicked.
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
            // A row that turns disabled under the pointer gets no exit event.
            .onChange(of: isEnabled) { _, enabled in
                if !enabled { hovered = false }
            }
    }
}

/// What a row shows: icon, title, an optional second line, and what sits at
/// the far side. Also used by the rows that are not buttons.
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

/// A row's icon: quiet beside the text, and the text's colour when the row is
/// highlighted or disabled.
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

/// A keyboard shortcut at the far side of a row, such as "⌘,".
struct MenuBarShortcutText: View {
    let label: String

    var body: some View {
        Text(verbatim: label)
    }
}

/// The thin line between groups of rows.
struct MenuBarSeparator: View {
    var body: some View {
        Divider()
            .padding(.horizontal, MenuBarMetric.separatorInset)
            .padding(.vertical, 5)
    }
}

/// The small heading over a group of rows.
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

/// A row holding a switch. It is not a button, so the pointer does not
/// highlight it; the switch is the control.
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

/// Reports whether the window this view sits in is on screen. The menu bar
/// extra keeps its panel's views after the panel closes, so appearing and
/// disappearing do not say whether it is open; the window's own state does.
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

        /// On the next turn, with the state the window has by then: this
        /// can run inside the view update that moved the view.
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
