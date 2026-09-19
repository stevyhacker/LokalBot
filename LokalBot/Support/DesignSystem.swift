import SwiftUI

// MARK: - Semantic brand roles

extension Brand {
    /// Live-capture indicator (recording, dictating): the icon's amber antenna
    /// dot, and the same convention as macOS's amber mic-in-use dot. Buttons
    /// that *stop* a capture stay `.red` — amber marks state, red marks the
    /// destructive action.
    static let recording = amber

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
        static let compactPanel: CGFloat = 12
        /// Panels, cards, toasts, and chat bubbles.
        static let panel: CGFloat = 14
        /// Hero surfaces (getting-started card, onboarding cards).
        static let card: CGFloat = 16
        /// Floating capsules (dictation HUD, banners, the recording pill).
        static let hud: CGFloat = 20
    }
}

// MARK: - Workspace typography and rhythm

/// A compact native-macOS hierarchy shared by every workspace surface.
/// Hierarchy comes primarily from weight and spacing rather than oversized
/// type, keeping dense meeting and evidence views comfortable by default.
enum WorkspaceTypography {
    static let display = Font.system(size: 22, weight: .bold)
    static let pageTitle = Font.system(size: 20, weight: .bold)
    static let sectionTitle = Font.system(size: 15, weight: .semibold)
    static let body = Font.system(size: 14, weight: .regular)
    static let bodyEmphasis = Font.system(size: 14, weight: .semibold)
    /// Ask is a dense reading surface rather than a presentation page. Its
    /// question and answer hierarchy stays compact without shrinking titles
    /// elsewhere in the app.
    static let conversationTitle = Font.system(size: 17, weight: .semibold)
    static let editorialSectionTitle = Font.system(size: 14, weight: .semibold)
    static let editorialBody = Font.system(size: 13, weight: .regular)
    static let editorialBodyEmphasis = Font.system(size: 13, weight: .semibold)
    static let rowTitle = Font.system(size: 14, weight: .semibold)
    static let control = Font.system(size: 13, weight: .medium)
    static let metadata = Font.system(size: 12, weight: .regular)
    static let metadataEmphasis = Font.system(size: 12, weight: .semibold)
    static let overline = Font.system(size: 10, weight: .semibold)
}

enum WorkspaceMetric {
    static let pagePadding: CGFloat = 24
    static let sectionGap: CGFloat = 22
    static let panelPadding: CGFloat = 18
    /// Inner padding of small rounded cards (morning brief, outcome card) —
    /// one step tighter than `panelPadding` panels.
    static let cardPadding: CGFloat = 14
    static let rowVerticalPadding: CGFloat = 11
    /// At the approved 1584-point window this leaves a compact outer gutter
    /// while allowing the outcome tables to use the same broad working area
    /// as the reference instead of collapsing into a narrow centered column.
    static let contentMaxWidth: CGFloat = 1360
    /// Long-form answers and summaries stay within a comfortable reading line.
    static let readingMaxWidth: CGFloat = 780
    /// Timeline context remains useful beside the chronology before it drawers.
    static let timelineContextMinWidth: CGFloat = 420
    static let timelineDrawerBreakpoint: CGFloat = 820
    static let timelineDrawerMaxWidth: CGFloat = 520
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
                .font(WorkspaceTypography.metadata)
                .foregroundStyle(Color.secondary)
        case .supporting:
            content
                .font(WorkspaceTypography.editorialBody)
                .foregroundStyle(contrast == .increased ? Color.primary : Color.secondary)
        case .trust:
            content
                .font(WorkspaceTypography.editorialBody)
                .foregroundStyle(Color.primary)
        case .warning:
            content
                .font(WorkspaceTypography.editorialBody)
                .foregroundStyle(Brand.error)
        }
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
                Text(destination.label).font(WorkspaceTypography.metadataEmphasis)
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
}

enum WorkspaceMotion {
    static func animation(_ kind: WorkspaceMotionKind, reduceMotion: Bool) -> Animation? {
        guard !reduceMotion else { return nil }
        switch kind {
        case .selection: return .easeOut(duration: 0.14)
        case .disclosure: return .easeInOut(duration: 0.16)
        case .drawer: return .easeOut(duration: 0.18)
        case .autoScroll: return .easeOut(duration: 0.15)
        }
    }

    static func disclosureTransition(reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top))
    }

    static func drawerTransition(reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .move(edge: .trailing).combined(with: .opacity)
    }
}

// MARK: - Workspace shell

/// Warm, low-contrast workspace colors inspired by focused writing tools.
/// Every role has a dark equivalent so LokalBot still follows the Mac's
/// appearance instead of forcing a fixed light theme.
enum WorkspacePalette {
    static func canvas(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color(red: 0.140, green: 0.145, blue: 0.150)
            : Color(red: 0.970, green: 0.968, blue: 0.958)
    }

    static func surface(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color(red: 0.180, green: 0.185, blue: 0.190)
            : Color(red: 0.995, green: 0.994, blue: 0.988)
    }

    /// The approved shell uses a cooler, deeper global rail than its content
    /// columns. Keeping this explicit avoids AppKit's brighter gray sidebar
    /// material changing the visual hierarchy between OS releases.
    static func sidebar(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color(red: 0.120, green: 0.130, blue: 0.135)
            : Color(red: 0.935, green: 0.946, blue: 0.944)
    }

    static func conversationColumn(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color(red: 0.165, green: 0.170, blue: 0.175)
            : Color(red: 0.950, green: 0.949, blue: 0.944)
    }

    static func control(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color(red: 0.210, green: 0.215, blue: 0.220)
            : Color(red: 0.945, green: 0.943, blue: 0.934)
    }

    static func border(
        for colorScheme: ColorScheme,
        contrast: ColorSchemeContrast
    ) -> Color {
        if colorScheme == .dark {
            return Color.white.opacity(contrast == .increased ? 0.18 : 0.09)
        }
        return Color.black.opacity(contrast == .increased ? 0.18 : 0.08)
    }
}

private struct WorkspaceSurfaceModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .background(WorkspacePalette.canvas(for: colorScheme))
    }
}

private struct WorkspaceControlModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Brand.Radius.control, style: .continuous)

        content
            .background(WorkspacePalette.control(for: colorScheme), in: shape)
            .overlay {
                shape.strokeBorder(
                    WorkspacePalette.border(for: colorScheme, contrast: contrast),
                    lineWidth: 1)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
    }
}

extension View {
    /// Insets a detail pane into the soft canvas used by the main workspace.
    func workspaceSurface() -> some View {
        modifier(WorkspaceSurfaceModifier())
    }

    /// Quiet control chrome for search and other shell-level fields.
    func workspaceControl() -> some View {
        modifier(WorkspaceControlModifier())
    }

    /// Applies a semantic foreground and minimum readable type size.
    func workspaceTextRole(_ role: WorkspaceTextRole) -> some View {
        modifier(WorkspaceTextRoleModifier(role: role))
    }

    /// Caps narrative prose without constraining tables, evidence, or controls.
    func workspaceReadingWidth(alignment: Alignment = .leading) -> some View {
        frame(maxWidth: WorkspaceMetric.readingMaxWidth, alignment: alignment)
    }

    /// Shared quiet panel chrome for outcome groups and disclosure sections.
    func workspacePanel() -> some View {
        padding(WorkspaceMetric.panelPadding)
            .background(.quaternary.opacity(0.24),
                        in: RoundedRectangle(cornerRadius: Brand.Radius.panel,
                                             style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Brand.Radius.panel, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.11))
            }
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
                        .font(.caption.weight(.semibold))
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

    var font: Font {
        self == .regular ? WorkspaceTypography.metadata : .system(size: 11, weight: .medium)
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
    var font: Font
    var controlSize: ControlSize

    init(
        _ text: String,
        font: Font = WorkspaceTypography.metadata,
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
            Text(message).font(.callout).lineLimit(2).help(message)
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

/// The gradient icon tile from onboarding, promoted app-wide so feature
/// headers and hero cards share one visual anchor.
struct IconTile: View {
    let systemImage: String
    let tint: Color
    var size: CGFloat = 36

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [tint.opacity(0.84), tint],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .shadow(color: tint.opacity(0.32), radius: size * 0.14, y: size * 0.06)

            Image(systemName: systemImage)
                .font(.system(size: size * 0.46, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Section header

/// Uppercase caption header for list groupings (meeting-list day labels,
/// menu-bar Recent, inspector headings) — one treatment everywhere.
struct SectionHeader: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(WorkspaceTypography.overline)
            .tracking(0.65)
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
            Image(systemName: icon).font(WorkspaceTypography.metadata).foregroundStyle(.secondary)
            Text(value).font(WorkspaceTypography.metadataEmphasis.monospacedDigit())
            Text(label).font(WorkspaceTypography.metadata).foregroundStyle(.secondary)
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
