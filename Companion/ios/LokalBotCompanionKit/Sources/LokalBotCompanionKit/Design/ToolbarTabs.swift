import SwiftUI

/// Equal-width tabs with a sliding teal capsule, the Mac's meeting tabs.
public struct ToolbarTabs<Tab: Hashable & Identifiable>: View {
    let label: String
    let tabs: [Tab]
    @Binding var selection: Tab
    let title: (Tab) -> String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    public init(label: String, tabs: [Tab], selection: Binding<Tab>, title: @escaping (Tab) -> String) {
        self.label = label
        self.tabs = tabs
        self._selection = selection
        self.title = title
    }

    /// The capsule tabs where they fit; a menu at large text sizes.
    public var body: some View {
        ViewThatFits(in: .horizontal) {
            capsules
            Picker(label, selection: $selection) {
                ForEach(tabs) { Text(title($0)).tag($0) }
            }
            .pickerStyle(.menu)
            .tint(Brand.teal)
            .fixedSize()
        }
    }

    private var capsules: some View {
        EqualWidthHStack {
            ForEach(tabs) { segment($0) }
        }
        .background { knob }
        .animation(WorkspaceMotion.animation(.tabs, reduceMotion: reduceMotion), value: selection)
        .padding(3)
        .background(Capsule().fill(LBTokens.Palette.groupFill))
        .overlay(Capsule().strokeBorder(contrast == .increased ? Color.primary.opacity(0.5) : LBTokens.Palette.groupStroke))
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }

    private func segment(_ tab: Tab) -> some View {
        let selected = tab == selection
        return Button { selection = tab } label: {
            // The hidden semibold copy reserves the selected width, so the
            // control never changes size as the selection moves.
            ZStack {
                Text(title(tab)).font(LBTokens.Typography.secondary.weight(.semibold)).hidden()
                Text(title(tab))
                    .font(LBTokens.Typography.secondary.weight(selected ? .semibold : .medium))
                    .foregroundStyle(selected ? Color.white
                                     : contrast == .increased ? Color.primary : LBTokens.Palette.supporting)
            }
            .lineLimit(1)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, minHeight: 30)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .lbHoverEffect()
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }

    /// White on the deep accent (4.7:1).
    private var knob: some View {
        GeometryReader { proxy in
            let width = proxy.size.width / CGFloat(max(tabs.count, 1))
            Capsule()
                .fill(Brand.tealFill)
                .frame(width: width)
                .offset(x: CGFloat(tabs.firstIndex(of: selection) ?? 0) * width)
        }
        .accessibilityHidden(true)
    }
}

/// Places children side by side at the widest child's width, or shares the
/// offered width equally when that is smaller.
struct EqualWidthHStack: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let ideal = (sizes.map(\.width).max() ?? 0) * CGFloat(subviews.count)
        let width = proposal.width.map { min($0, ideal) } ?? ideal
        return CGSize(width: width, height: sizes.map(\.height).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let width = bounds.width / CGFloat(max(subviews.count, 1))
        for (index, subview) in subviews.enumerated() {
            subview.place(at: CGPoint(x: bounds.minX + width * CGFloat(index), y: bounds.midY),
                          anchor: .leading,
                          proposal: ProposedViewSize(width: width, height: bounds.height))
        }
    }
}
