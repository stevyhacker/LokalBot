import SwiftUI

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

struct SettingsHelp: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(LocalizedStringKey(text))
            .font(.scaled(.callout))
            .settingsSecondary()
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct SettingsLabel: View {
    let title: String
    let help: String?

    init(_ title: String, help: String? = nil) {
        self.title = title
        self.help = help
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(LocalizedStringKey(title))
            if let help { SettingsHelp(help) }
        }
    }
}

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
            Text(LocalizedStringKey(title)).font(.scaled(.callout).weight(.medium)).settingsSecondary()
        }
    }
}

struct SettingsMetricTile: View {
    let icon: String
    let title: String
    let value: String
    var detail: String?
    let identifier: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label {
                Text(LocalizedStringKey(title))
            } icon: {
                Image(systemName: icon).foregroundStyle(Brand.teal)
            }
            .font(AppFont.scaled(.callout))
            .settingsSecondary()
            .lineLimit(1)
            Text(value)
                .font(AppFont.scaled(.title2).weight(.semibold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(AppFont.scaled(.callout))
                    .settingsSecondary()
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(12)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: Brand.Radius.control))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(LocalizedStringKey(title)))
        .accessibilityValue(Text(verbatim: spokenValue))
        .accessibilityIdentifier(identifier)
    }

    private var spokenValue: String {
        let value = value.replacingOccurrences(of: "≈ ", with: "≈")
            .replacingOccurrences(of: "≈", with: "approximately ")
        guard let detail, !detail.isEmpty else { return value }
        return value + ", " + detail
    }
}

struct SettingsTileLayout: Layout {
    var minimumWidth: CGFloat = 150
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let count = CGFloat(subviews.count)
        let width = proposal.width ?? minimumWidth * count + spacing * max(count - 1, 0)
        let rows = rows(width: width, subviews: subviews)
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(width: bounds.width, subviews: subviews) {
            for (column, index) in row.indices.enumerated() {
                let x = bounds.minX + CGFloat(column) * (row.columnWidth + spacing)
                subviews[index].place(at: CGPoint(x: x, y: y),
                                      proposal: ProposedViewSize(width: row.columnWidth, height: row.height))
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: Range<Int>
        var columnWidth: CGFloat
        var height: CGFloat
    }

    private func rows(width: CGFloat, subviews: Subviews) -> [Row] {
        let count = subviews.count
        guard count > 0 else { return [] }
        let oneRow = (width - spacing * CGFloat(count - 1)) / CGFloat(count)
        let columns = count <= 2 || oneRow >= minimumWidth ? count : 2
        let columnWidth = max(0, (width - spacing * CGFloat(columns - 1)) / CGFloat(columns))
        return stride(from: 0, to: count, by: columns).map { start in
            let indices = start..<min(start + columns, count)
            let height = indices.map {
                subviews[$0].sizeThatFits(ProposedViewSize(width: columnWidth, height: nil)).height
            }.max() ?? 0
            return Row(indices: indices, columnWidth: columnWidth, height: height)
        }
    }
}
