import SwiftUI

// MARK: - Workspace section

/// A titled group on a grouped surface: Recap, Action Items, Decisions,
/// Open Work. The title sits above the surface, as on the Mac.
public struct WorkspaceSection<Content: View, Accessory: View>: View {
    let title: String
    let icon: String
    let accessory: Accessory
    let content: Content

    public init(_ title: String, icon: String, @ViewBuilder content: () -> Content) where Accessory == EmptyView {
        self.title = title
        self.icon = icon
        self.accessory = EmptyView()
        self.content = content()
    }

    public init(_ title: String, icon: String, @ViewBuilder content: () -> Content,
                @ViewBuilder accessory: () -> Accessory) {
        self.title = title
        self.icon = icon
        self.accessory = accessory()
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: LBTokens.Spacing.headerToContent) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title)
                    .font(LBTokens.Typography.section)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                accessory
            }
            VStack(alignment: .leading, spacing: 8) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, LBTokens.Spacing.panelPadding)
            .padding(.vertical, 6)
            .lbGroupedSurface()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A quiet line inside a section with nothing to list.
public struct EmptyWorkspaceRow: View {
    let text: String

    public init(_ text: String) { self.text = text }

    public var body: some View {
        Text(text)
            .font(LBTokens.Typography.body)
            .workspaceSupportingForeground()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 10)
    }
}

// MARK: - Section header

/// The caption header for list groupings: day labels in Meetings, groups in
/// Actions.
public struct SectionHeader: View {
    let text: String

    public init(_ text: String) { self.text = text }

    public var body: some View {
        Text(text)
            .font(LBTokens.Typography.caption.weight(.semibold))
            .workspaceSupportingForeground()
            .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Chips

public enum ChipSize: Sendable {
    case regular, compact

    var font: Font { self == .regular ? LBTokens.Typography.secondary : LBTokens.Typography.caption.weight(.medium) }
    var horizontalPadding: CGFloat { self == .regular ? 10 : 8 }
    var verticalPadding: CGFloat { self == .regular ? 5 : 3 }
}

extension View {
    /// The capsule chip chrome shared by metadata badges, stat pills and labels.
    public func chipChrome(_ size: ChipSize = .regular, fill: Color = LBTokens.Palette.chipFill) -> some View {
        padding(.horizontal, size.horizontalPadding)
            .padding(.vertical, size.verticalPadding)
            .background(fill, in: Capsule())
    }
}

/// A small capsule: optional SF Symbol and text in the supporting color.
public struct BrandChip: View {
    let icon: String?
    let text: String
    var size: ChipSize
    var tint: Color?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    public init(icon: String? = nil, _ text: String, size: ChipSize = .regular, tint: Color? = nil) {
        self.icon = icon
        self.text = text
        self.size = size
        self.tint = tint
    }

    public var body: some View {
        Group {
            if let icon {
                Label(text, systemImage: icon).labelStyle(.titleAndIcon)
            } else {
                Text(text)
            }
        }
        .font(size.font.monospacedDigit())
        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
        .foregroundStyle(tint ?? LBTokens.Palette.supporting)
        .chipChrome(size, fill: tint.map { $0.opacity(0.12) } ?? LBTokens.Palette.chipFill)
    }
}

/// A selectable capsule for filters. Selected chips use the filled accent.
public struct FilterChip: View {
    let title: String
    let count: Int?
    let isSelected: Bool
    let action: () -> Void

    public init(_ title: String, count: Int? = nil, isSelected: Bool, action: @escaping () -> Void) {
        self.title = title
        self.count = count
        self.isSelected = isSelected
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title)
                if let count {
                    Text(count, format: .number)
                        .monospacedDigit()
                        .foregroundStyle(isSelected ? Color.white.opacity(0.85) : LBTokens.Palette.supporting)
                }
            }
            .font(LBTokens.Typography.secondary.weight(isSelected ? .semibold : .medium))
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(isSelected ? Brand.tealFill : LBTokens.Palette.chipFill, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .lbHoverEffect()
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Status dot

/// A small state-colored dot; `pulses` adds an expanding ring, off under
/// Reduce Motion (the color alone still carries the state).
public struct StatusDot: View {
    var color: Color
    var size: CGFloat
    var pulses: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    public init(color: Color, size: CGFloat = 8, pulses: Bool = false) {
        self.color = color
        self.size = size
        self.pulses = pulses
    }

    private var animates: Bool { pulses && !reduceMotion }

    public var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .overlay {
                if animates {
                    Circle()
                        .stroke(color.opacity(0.55), lineWidth: 3)
                        .scaleEffect(pulse ? 2.4 : 1)
                        .opacity(pulse ? 0 : 0.7)
                        .animation(.easeOut(duration: 1.2).repeatForever(autoreverses: false), value: pulse)
                }
            }
            .onAppear { pulse = animates }
            .onChange(of: animates) { _, now in pulse = now }
            .accessibilityHidden(true)
    }
}

// MARK: - Evidence pill

/// The quoted moment behind an outcome, as a teal timestamp. Tapping it
/// jumps to that line of the transcript.
public struct EvidencePill: View {
    let start: Double
    let excerpt: String?
    let action: () -> Void

    public init(start: Double, excerpt: String? = nil, action: @escaping () -> Void) {
        self.start = start
        self.excerpt = excerpt
        self.action = action
    }

    public init(citation: Citation, action: @escaping () -> Void) {
        self.init(start: citation.start, excerpt: citation.excerpt, action: action)
    }

    public var body: some View {
        Button(action: action) {
            EvidencePillLabel(start: start)
        }
        .buttonStyle(.plain)
        .lbHoverEffect()
        .help(excerpt ?? "")
        .accessibilityLabel("Jump to evidence at \(LBFormat.stamp(start))")
        .accessibilityHint(excerpt ?? "")
    }
}

/// The pill's face, for use inside a navigation link.
public struct EvidencePillLabel: View {
    let start: Double

    public init(start: Double) { self.start = start }

    public var body: some View {
        Label {
            Text(LBFormat.stamp(start))
        } icon: {
            Image(systemName: "quote.bubble")
        }
        .font(LBTokens.Typography.timestamp)
        .foregroundStyle(Brand.teal)
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityLabel("Evidence at \(LBFormat.stamp(start))")
    }
}

// MARK: - Avatars

/// A person's initials on a tint chosen from their name, from the speaker
/// palette as on the Mac.
public struct InitialsAvatar: View {
    let name: String
    var size: CGFloat

    public init(name: String, size: CGFloat = 30) {
        self.name = name
        self.size = size
    }

    public var body: some View {
        let color = Self.color(for: name)
        Circle()
            .fill(color.opacity(0.16))
            .overlay(Circle().strokeBorder(color.opacity(0.28), lineWidth: 0.5))
            .overlay {
                Text(Self.initials(name))
                    .font(.system(size: size * 0.4, weight: .semibold, design: .rounded))
                    .foregroundStyle(color)
            }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }

    nonisolated public static func initials(_ name: String) -> String {
        let words = name.split(separator: " ").filter { $0.first?.isLetter == true }
        let letters = words.count >= 2 ? [words.first, words.last] : [words.first]
        return letters.compactMap { $0?.first.map { String($0).uppercased() } }.joined()
    }

    /// The Mac's `InitialsAvatar.color(for:)`.
    nonisolated public static func colorIndex(for name: String) -> Int {
        let hash = normalized(name).unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return hash % LBTokens.speakers.count
    }

    nonisolated public static func color(for name: String) -> Color {
        LBTokens.Palette.speakers[colorIndex(for: name)]
    }

    /// The Mac's `PeopleDirectory.normalized`.
    nonisolated static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .components(separatedBy: CharacterSet.letters.union(.decimalDigits).inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

/// A project's first letter on a tint chosen from its name.
public struct ProjectMonogram: View {
    let name: String
    var size: CGFloat

    public init(name: String, size: CGFloat = 30) {
        self.name = name
        self.size = size
    }

    public var body: some View {
        let color = InitialsAvatar.color(for: name)
        let shape = RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
        shape
            .fill(color.opacity(0.16))
            .overlay(shape.strokeBorder(color.opacity(0.28), lineWidth: 0.5))
            .overlay {
                Text(name.first.map { String($0).uppercased() } ?? "")
                    .font(.system(size: size * 0.46, weight: .semibold, design: .rounded))
                    .foregroundStyle(color)
            }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

// MARK: - Stat tile

/// Icon, value and label in a chip; the value keeps monospaced digits.
public struct StatTile: View {
    let icon: String
    let value: String
    let label: String

    public init(icon: String, value: String, label: String) {
        self.icon = icon
        self.value = value
        self.label = label
    }

    public var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon).foregroundStyle(LBTokens.Palette.supporting).accessibilityHidden(true)
            Text(value).fontWeight(.semibold).monospacedDigit()
            Text(label).foregroundStyle(LBTokens.Palette.supporting)
        }
        .font(LBTokens.Typography.secondary)
        .lineLimit(1)
        .fixedSize()
        .chipChrome()
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Icon tile

/// A quiet symbol well for feature surfaces (pairing, empty states).
public struct IconTile: View {
    let systemImage: String
    let tint: Color
    var size: CGFloat

    public init(systemImage: String, tint: Color = Brand.teal, size: CGFloat = 36) {
        self.systemImage = systemImage
        self.tint = tint
        self.size = size
    }

    public var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.26, style: .continuous).fill(tint.opacity(0.12))
            Image(systemName: systemImage)
                .font(.system(size: size * 0.46, weight: .medium))
                .foregroundStyle(tint)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

// MARK: - Loading

/// A compact spinner beside a quiet description of what's happening.
public struct LoadingStateLabel: View {
    let text: String

    public init(_ text: String) { self.text = text }

    public var body: some View {
        HStack(spacing: 7) {
            ProgressView().controlSize(.small)
            Text(text).font(LBTokens.Typography.secondary).workspaceSupportingForeground()
        }
        .accessibilityElement(children: .combine)
    }
}
