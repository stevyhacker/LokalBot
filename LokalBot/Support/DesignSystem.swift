import SwiftUI

// MARK: - Semantic brand roles

extension Brand {
    /// Recording state uses the same red role on every capture surface.
    static let recording = LBTokens.Palette.recording

    /// Shared corner radii. Chips are capsules; everything rectangular snaps
    /// to one of these instead of a per-view magic number.
    enum Radius {
        /// Compact desktop tabs whose height cannot accommodate `control`.
        static let tab: CGFloat = 7
        /// Selectable rows and compact inline cards.
        static let row: CGFloat = 8
        /// Inline wells and small controls (text areas, thumbnails).
        static let control: CGFloat = 10
        /// Dense content cards that need one step less rounding than panels.
        static let compactPanel: CGFloat = 10
        /// Panels, cards, toasts, and chat bubbles.
        static let panel: CGFloat = 10
        /// Hero surfaces (getting-started card, onboarding cards).
        static let card: CGFloat = 10
    }
}

// MARK: - Workspace typography and rhythm

/// A compact native-macOS hierarchy shared by every workspace surface.
/// Hierarchy comes primarily from weight and spacing rather than oversized
/// type, keeping dense meeting and evidence views comfortable by default.

enum WorkspaceMetric {
    static let pagePadding: CGFloat = LBTokens.Metric.detailPadding
    static let sectionGap: CGFloat = 22
    static let panelPadding: CGFloat = 14
    /// Inner padding of small rounded cards (morning brief, outcome card) —
    /// one step tighter than `panelPadding` panels.
    static let cardPadding: CGFloat = 14
    static let rowVerticalPadding: CGFloat = 10
    /// At the approved 1584-point window this leaves a compact outer gutter
    /// while allowing the outcome tables to use the same broad working area
    /// as the reference instead of collapsing into a narrow centered column.
    static let contentMaxWidth: CGFloat = 1360
    /// Long-form answers and summaries stay within a comfortable reading line.
    static let readingMaxWidth: CGFloat = LBTokens.Metric.readingMaxWidth
    /// Today is a glanceable page: wide enough for a row of session cards,
    /// with prose still held to `readingMaxWidth`.
    static let todayMaxWidth: CGFloat = 956
    /// Keep the day readable beside the work-session rail, then use a drawer.
    static let timelineDayMinWidth: CGFloat = 440
    static let timelineRailMinWidth: CGFloat = 260
    static let timelineRailIdealWidth: CGFloat = 360
    static let timelineRailMaxWidth: CGFloat = 640
    static let timelineDrawerBreakpoint: CGFloat = 820
    static let timelineDrawerMaxWidth: CGFloat = 520
    /// The main window's titlebar and unified toolbar.
    static let toolbarHeight: CGFloat = 52

    /// The rail may widen until the day column reaches its readable minimum.
    static func timelineRailMaxWidth(in paneWidth: CGFloat) -> CGFloat {
        min(timelineRailMaxWidth, max(timelineRailMinWidth, paneWidth - timelineDayMinWidth))
    }

}

// MARK: - Semantic text and inference roles

/// Text importance is independent from layout hierarchy. Metadata may be
/// visually quiet; privacy, permissions, egress, and recovery explanations
/// must remain readable in every appearance and Increase Contrast.
enum WorkspaceTextRole {
    case metadata
    case supporting
    case trust
    case warning
}

private struct WorkspaceTextRoleModifier: ViewModifier {
    @Environment(\.colorSchemeContrast) private var contrast
    let role: WorkspaceTextRole

    @ViewBuilder
    func body(content: Content) -> some View {
        switch role {
        case .metadata:
            content
                .font(AppFont.scaled(.callout))
                .foregroundStyle(contrast == .increased ? Color.primary : Color(nsColor: WorkspaceTextColor.supporting))
        case .supporting:
            content
                .font(AppFont.scaled(.body))
                .foregroundStyle(contrast == .increased ? Color.primary : Color(nsColor: WorkspaceTextColor.supporting))
        case .trust:
            content
                .font(AppFont.scaled(.body))
                .foregroundStyle(Color.primary)
        case .warning:
            content
                .font(AppFont.scaled(.body))
                .foregroundStyle(contrast == .increased ? Color.primary : Color(nsColor: WorkspaceTextColor.warning))
        }
    }
}

/// Opaque supporting text stays legible on both window and inset surfaces.
/// Unlike tertiary/opacity-based labels, it does not fade with nested styling.
/// The supporting color without the role's type size, for captions and
/// metadata. The system secondary label drops below 4.5:1 on grouped fills
/// and unfocused list selections; this color stays above it.
private struct WorkspaceSupportingForegroundModifier: ViewModifier {
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content.foregroundStyle(contrast == .increased ? Color.primary : Color(nsColor: WorkspaceTextColor.supporting))
    }
}

enum WorkspaceTextColor {
    static let supporting = NSColor(name: nil) { appearance in
        let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return NSColor(srgbRed: dark ? 0.76 : 0.34,
                       green: dark ? 0.76 : 0.34,
                       blue: dark ? 0.76 : 0.34, alpha: 1)
    }

    static let warning = NSColor(name: nil) { appearance in
        let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return dark ? NSColor(srgbRed: 0.95, green: 0.70, blue: 0.34, alpha: 1)
                    : NSColor(srgbRed: 0.50, green: 0.25, blue: 0.06, alpha: 1)
    }
}

/// One honest local/remote inference disclosure. Callers provide copy tailored
/// to the surface while this view owns readable type and semantic icon color.
struct InferenceDisclosure: View {
    let destination: InferencePresentation
    let localText: String
    let remoteText: String

    init(settings: AppSettings, localText: String, remoteText: String) {
        destination = InferencePresentation(settings: settings)
        self.localText = localText
        self.remoteText = remoteText
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: destination.icon)
                .foregroundStyle(destination == .onDevice ? Brand.teal : Brand.amber)
            VStack(alignment: .leading, spacing: 3) {
                Text(destination.label).font(AppFont.scaled(.callout).weight(.semibold))
                Text(destination.detail(local: localText, remote: remoteText))
                    .workspaceTextRole(destination.isBlocked ? .warning : .trust)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Motion policy

enum WorkspaceMotionKind {
    case selection
    case disclosure
    case drawer
    case autoScroll
    /// Rare setup moments: a permission granted, a model ready, an
    /// onboarding step. Infrequent enough to afford a little spring.
    case milestone
}

enum WorkspaceMotion {
    static func animation(_ kind: WorkspaceMotionKind, reduceMotion: Bool) -> Animation? {
        guard !reduceMotion else { return nil }
        switch kind {
        case .selection: return .easeOut(duration: 0.14)
        case .disclosure: return .easeInOut(duration: 0.16)
        case .drawer: return .easeOut(duration: 0.18)
        case .autoScroll: return .easeOut(duration: 0.15)
        case .milestone: return .snappy(duration: 0.25)
        }
    }

    static func disclosureTransition(reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top))
    }

    static func drawerTransition(reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .move(edge: .trailing).combined(with: .opacity)
    }

    /// Feedback pinned to the window's bottom edge enters and leaves through
    /// that same edge.
    static func bottomEdgeTransition(reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity)
    }

    /// Paged setup steps arrive a short distance from the direction of travel.
    static func stepTransition(forward: Bool, reduceMotion: Bool) -> AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .opacity.combined(with: .offset(x: forward ? 24 : -24)),
            removal: .opacity)
    }
}

// MARK: - Workspace shell

/// Only inset control surfaces supply their own fill. The window and sidebar
/// retain the platform's native background and materials.
private struct WorkspaceControlModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.lbGroupedSurface()
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
                    RoundedRectangle(cornerRadius: LBTokens.Metric.composerRadius, style: .continuous)
                        .strokeBorder(Brand.teal.opacity(contrast == .increased ? 1 : 0.45))
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
    }
}

extension View {
    /// A main-window workspace's minimum height. NavigationSplitView counts the
    /// 52 pt titlebar and toolbar in its own minimum, and the full-size-content
    /// window's root hosting view adds it again, so a 600 pt minimum kept the
    /// window at least 704 pt tall. Subtracting the second count makes the
    /// window's minimum the workspace plus one toolbar.
    func workspaceMinimumHeight(_ height: CGFloat) -> some View {
        frame(minHeight: max(height - WorkspaceMetric.toolbarHeight, 0))
    }
}

extension View {
    /// Quiet control chrome for search and other shell-level fields.
    func workspaceControl() -> some View {
        modifier(WorkspaceControlModifier())
    }

    /// The docked composer surface used by Agent and Ask.
    func composerChrome(focused: Bool) -> some View {
        modifier(ComposerChromeModifier(focused: focused))
    }

    /// Applies a semantic foreground and minimum readable type size.
    func workspaceTextRole(_ role: WorkspaceTextRole) -> some View {
        modifier(WorkspaceTextRoleModifier(role: role))
    }

    /// Readable supporting foreground that keeps the caller's font.
    func workspaceSupportingForeground() -> some View {
        modifier(WorkspaceSupportingForegroundModifier())
    }

    /// Caps narrative prose without constraining tables, evidence, or controls.
    func workspaceReadingWidth(alignment: Alignment = .leading) -> some View {
        frame(maxWidth: WorkspaceMetric.readingMaxWidth, alignment: alignment)
    }

    /// Shared quiet panel chrome for outcome groups and disclosure sections.
    func workspacePanel() -> some View {
        padding(WorkspaceMetric.panelPadding)
            .lbGroupedSurface()
    }
}

/// An explicit workspace disclosure with a full-width hit target. SwiftUI's
/// native macOS DisclosureGroup can expose a large accessibility frame whose
/// activation point does not toggle reliably; this component keeps the same
/// visual hierarchy while making mouse, keyboard, and UI-test activation
/// deterministic.
enum WorkspaceDisclosureStyle {
    case standard
    case compact
}

struct WorkspaceDisclosure<Label: View, Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding private var isExpanded: Bool
    private let identifier: String
    private let style: WorkspaceDisclosureStyle
    private let label: () -> Label
    private let content: () -> Content

    init(
        isExpanded: Binding<Bool>,
        identifier: String,
        style: WorkspaceDisclosureStyle = .standard,
        @ViewBuilder content: @escaping () -> Content,
        @ViewBuilder label: @escaping () -> Label
    ) {
        _isExpanded = isExpanded
        self.identifier = identifier
        self.style = style
        self.content = content
        self.label = label
    }

    @ViewBuilder
    var body: some View {
        switch style {
        case .standard:
            disclosureContent.workspacePanel()
        case .compact:
            disclosureContent
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(
                    .quaternary.opacity(0.16),
                    in: RoundedRectangle(
                        cornerRadius: Brand.Radius.control,
                        style: .continuous))
                .overlay {
                    RoundedRectangle(
                        cornerRadius: Brand.Radius.control,
                        style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.09))
                }
        }
    }

    private var disclosureContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(WorkspaceMotion.animation(
                    .disclosure, reduceMotion: reduceMotion)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 10) {
                    label()
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.scaled(.caption).weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(identifier)
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")

            if isExpanded {
                content()
                    .padding(.top, 10)
                    .transition(WorkspaceMotion.disclosureTransition(
                        reduceMotion: reduceMotion))
            }
        }
    }
}

// MARK: - Chips

enum ChipSize {
    case regular, compact

    var font: AppFont {
        self == .regular ? AppFont.scaled(.callout) : .scaledSystem(size: 11, weight: .medium)
    }
    var horizontalPadding: CGFloat { self == .regular ? 10 : 8 }
    var verticalPadding: CGFloat { self == .regular ? 5 : 3 }
}

extension View {
    /// The one capsule-chip chrome (padding + quiet fill) shared by metadata
    /// badges, stat pills, kind chips, and activity labels. Apply to composite
    /// content; use `BrandChip` for the plain icon+text case.
    func chipChrome(_ size: ChipSize = .regular) -> some View {
        padding(.horizontal, size.horizontalPadding)
            .padding(.vertical, size.verticalPadding)
            .background(.quaternary.opacity(0.5), in: Capsule())
    }
}

/// A small capsule chip: optional SF Symbol + text, secondary foreground.
struct BrandChip: View {
    var icon: String?
    let text: String
    var size: ChipSize = .regular

    var body: some View {
        Group {
            if let icon {
                Label(text, systemImage: icon).labelStyle(.titleAndIcon)
            } else {
                Text(text)
            }
        }
        .font(size.font.monospacedDigit())
        .foregroundStyle(.secondary)
        .chipChrome(size)
    }
}

// MARK: - Status dot

/// A small state-colored dot; `pulses` adds the expanding ring used by live
/// recording indicators. The ring respects Reduce Motion — the dot's color
/// alone still communicates the live state.
struct StatusDot: View {
    var color: Color
    var size: CGFloat = 8
    var pulses: Bool = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    private var animates: Bool { pulses && !reduceMotion }

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .overlay {
                if animates {
                    Circle()
                        .stroke(color.opacity(0.55), lineWidth: 3)
                        .scaleEffect(pulse ? 2.4 : 1)
                        .opacity(pulse ? 0 : 0.7)
                        .animation(.easeOut(duration: 1.2).repeatForever(autoreverses: false),
                                   value: pulse)
                }
            }
            .onAppear { pulse = animates }
            .onChange(of: animates) { _, now in pulse = now }
    }
}

// MARK: - Loading state

/// The one in-flow loading vocabulary: a compact spinner beside a quiet
/// description of what's happening. Determinate progress keeps using
/// `ProgressView(value:)`; bare spinners with no message stay bare.
struct LoadingStateLabel: View {
    let text: String
    var font: AppFont
    var controlSize: ControlSize

    init(
        _ text: String,
        font: AppFont = AppFont.scaled(.callout),
        controlSize: ControlSize = .small
    ) {
        self.text = text
        self.font = font
        self.controlSize = controlSize
    }

    var body: some View {
        HStack(spacing: 7) {
            ProgressView().controlSize(controlSize)
            Text(text)
                .font(font)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Error toast

/// The one transient-error presentation: a dismissible material capsule pinned
/// to a window edge via `.overlay(alignment: .bottom)`. Persistent per-item
/// failures stay inline next to their rows; conversational errors stay in
/// their bubbles.
struct ErrorToast: View {
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Brand.error)
                .accessibilityHidden(true)
            Text(message).font(.scaled(.callout)).lineLimit(2).help(message)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            Button(action: dismiss) { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .accessibilityLabel("Dismiss error")
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Brand.Radius.panel))
        .overlay {
            RoundedRectangle(cornerRadius: Brand.Radius.panel).strokeBorder(Brand.error.opacity(0.4))
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .padding(12)
    }
}

// MARK: - Icon tile

/// A quiet symbol well for secondary feature surfaces.
struct IconTile: View {
    let systemImage: String
    let tint: Color
    var size: CGFloat = 36

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                .fill(tint.opacity(0.10))

            Image(systemName: systemImage)
                .font(.system(size: size * 0.46, weight: .medium))
                .foregroundStyle(tint)
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Section header

/// Native caption header for list groupings (meeting-list day labels,
/// menu-bar Recent, inspector headings) — one treatment everywhere.
struct SectionHeader: View {
    let text: Text

    init(text: LocalizedStringKey) {
        self.text = Text(text)
    }

    @_disfavoredOverload
    init(text: String) {
        self.text = Text(verbatim: text)
    }

    var body: some View {
        text
            .font(AppFont.scaled(.subheadline).weight(.semibold))
            .foregroundStyle(.secondary)
    }
}

// MARK: - Stat tile

/// Icon + value + label stat chip (timeline header stats, Type stats,
/// Settings metrics). The value keeps monospaced digits so rows align.
struct StatTile: View {
    let icon: String
    let value: String
    let label: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(AppFont.scaled(.callout)).foregroundStyle(.secondary)
            Text(value).font(AppFont.scaled(.callout).weight(.semibold).monospacedDigit())
            Text(label).font(AppFont.scaled(.callout)).foregroundStyle(.secondary)
        }
        .fixedSize()
        .chipChrome()
    }
}

extension View {
    /// Search scrolls to the exact editable control, then leaves a visible
    /// highlight until another setting/category is chosen.
    func settingTarget(_ id: String, selected: String?) -> some View {
        self.id(id)
            .padding(selected == id ? 6 : 0)
            .background(selected == id ? Brand.teal.opacity(0.14) : Color.clear,
                        in: RoundedRectangle(cornerRadius: Brand.Radius.control))
    }
}

// MARK: - Toolbar tabs

/// Equal-width tabs with a sliding accent capsule, for a toolbar's principal
/// item. A segmented picker there drew a square selection inside the
/// toolbar's capsule and spread its segments unevenly at a fixed width. From
/// macOS 26 the toolbar's own glass is the track; earlier systems draw one.
struct ToolbarTabs<Tab: Hashable & Identifiable>: View {
    let label: String
    let tabs: [Tab]
    @Binding var selection: Tab
    let title: (Tab) -> String

    @Environment(\.controlSize) private var controlSize
    @Environment(\.appearsActive) private var appearsActive
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var hovered: Tab?

    private var compact: Bool { controlSize == .small || controlSize == .mini }

    var body: some View {
        EqualWidthHStack {
            ForEach(tabs) { segment($0) }
        }
        .background { knob }
        .animation(reduceMotion ? nil : .snappy(duration: 0.22), value: selection)
        .padding(3)
        .background { track }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }

    private func segment(_ tab: Tab) -> some View {
        let selected = tab == selection
        let font = Font.system(size: NSFont.systemFontSize(for: compact ? .small : .regular))
        return Button { selection = tab } label: {
            // The hidden semibold copy reserves the selected width, so the
            // control never changes size as the selection moves.
            ZStack {
                Text(title(tab)).font(font.weight(.semibold)).hidden()
                Text(title(tab))
                    .font(font.weight(selected ? .semibold : .medium))
                    .foregroundStyle(foreground(selected: selected, hovered: hovered == tab))
            }
            .lineLimit(1)
            .padding(.horizontal, compact ? 7 : 10)
            .padding(.vertical, compact ? 3 : 5)
            .frame(maxWidth: .infinity)
            .background {
                if !selected && hovered == tab {
                    Capsule().fill(Color.primary.opacity(0.06))
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { inside in hovered = inside ? tab : (hovered == tab ? nil : hovered) }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// White on the deep accent while the window is active (4.7:1); an
    /// inactive window gets AppKit's unemphasized selection, like list rows.
    private var knob: some View {
        GeometryReader { proxy in
            let width = proxy.size.width / CGFloat(max(tabs.count, 1))
            Capsule()
                .fill(appearsActive ? Brand.tealFill
                                    : Color(nsColor: .unemphasizedSelectedContentBackgroundColor))
                .frame(width: width)
                .offset(x: CGFloat(tabs.firstIndex(of: selection) ?? 0) * width)
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder private var track: some View {
        if #available(macOS 26, *) {
            Color.clear
        } else {
            Capsule().fill(LBTokens.Palette.groupFill)
        }
    }

    private func foreground(selected: Bool, hovered: Bool) -> Color {
        if selected { return appearsActive ? .white : .primary }
        if hovered || contrast == .increased { return .primary }
        return Color(nsColor: WorkspaceTextColor.supporting)
    }
}

/// Places children side by side, each at the widest child's ideal width.
private struct EqualWidthHStack: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let width = sizes.map(\.width).max() ?? 0
        return CGSize(width: width * CGFloat(subviews.count), height: sizes.map(\.height).max() ?? 0)
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

// MARK: - Button roles

/// Three button weights: `primaryActionButton()` for the one filled call to
/// action on a surface, `.bordered` for secondary actions, and
/// `.workspaceLink` for quiet inline actions.
extension View {
    /// The one filled call to action on a surface: white on the deep accent
    /// fill in both appearances.
    func primaryActionButton() -> some View {
        buttonStyle(.borderedProminent).tint(Brand.tealFill)
    }
}

/// Inline navigation and utility actions rendered as accent text. Replaces
/// `.link`, whose system-blue color ignores the app accent.
struct WorkspaceLinkButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        WorkspaceLinkButton(configuration: configuration)
    }
}

private struct WorkspaceLinkButton: View {
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovered = false
    let configuration: ButtonStyleConfiguration

    var body: some View {
        configuration.label
            .foregroundStyle(Brand.teal)
            .underline(hovered && isEnabled)
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.45)
            .contentShape(Rectangle())
            .onHover { hovered = $0 }
    }
}

extension ButtonStyle where Self == WorkspaceLinkButtonStyle {
    static var workspaceLink: WorkspaceLinkButtonStyle { .init() }
}
