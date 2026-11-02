import SwiftUI

/// Shares of a whole, folding everything past `cap` into "Other".
public enum ProportionBarMath {
    public struct Segment: Equatable, Sendable {
        public let label: String
        public let fraction: Double
        public let seconds: Double
    }

    public static func segments(_ shares: [TimeShare], cap: Int = 5) -> [Segment] {
        let positive = shares.filter { $0.seconds > 0 }
        let total = positive.reduce(0) { $0 + $1.seconds }
        guard total > 0 else { return [] }
        let named = positive.filter { !$0.isOther }.sorted { $0.seconds > $1.seconds }
        let top = named.prefix(cap).map { Segment(label: $0.name, fraction: $0.seconds / total, seconds: $0.seconds) }
        let rest = named.dropFirst(cap).reduce(0) { $0 + $1.seconds } + positive.filter(\.isOther).reduce(0) { $0 + $1.seconds }
        guard rest > 0 else { return Array(top) }
        return top + [Segment(label: "Other", fraction: rest / total, seconds: rest)]
    }
}

/// One rounded track whose segments show each project's or app's share of the
/// tracked day, colored by name like the Mac's Timeline.
public struct ProportionBar: View {
    let segments: [ProportionBarMath.Segment]
    var height: CGFloat
    var label: String

    public init(segments: [ProportionBarMath.Segment], height: CGFloat = 10, label: String = "Time by project") {
        self.segments = segments
        self.height = height
        self.label = label
    }

    public var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 1.5) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                    Rectangle()
                        .fill(NameColor.color(for: segment.label))
                        .frame(width: max(2, (geometry.size.width - 1.5 * CGFloat(segments.count - 1)) * segment.fraction))
                }
            }
        }
        .frame(height: height)
        .background(LBTokens.Palette.chipFill)
        .clipShape(Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(segments.map { "\($0.label) \(Int(($0.fraction * 100).rounded())) percent" }.joined(separator: ", "))
    }
}

/// Dots, names and times under a proportion bar.
public struct ProportionLegend: View {
    let segments: [ProportionBarMath.Segment]

    public init(segments: [ProportionBarMath.Segment]) { self.segments = segments }

    public var body: some View {
        FlowLayout(spacing: 12, lineSpacing: 6) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                HStack(spacing: 5) {
                    StatusDot(color: NameColor.color(for: segment.label), size: 7)
                    Text(segment.label).lineLimit(1)
                    Text(LBFormat.hm(segment.seconds)).monospacedDigit().foregroundStyle(LBTokens.Palette.supporting)
                }
                .font(LBTokens.Typography.caption)
                .accessibilityElement(children: .combine)
            }
        }
    }
}

/// Wraps children onto new lines, leading-aligned.
public struct FlowLayout: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat

    public init(spacing: CGFloat = 8, lineSpacing: CGFloat = 8) {
        self.spacing = spacing
        self.lineSpacing = lineSpacing
    }

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map { $0.width }.max() ?? 0
        let height = rows.reduce(0) { $0 + $1.height } + lineSpacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width.map { min($0, width) } ?? width, height: height)
    }

    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for (index, size) in zip(row.indices, row.sizes) {
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                                      proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var sizes: [CGSize] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for (index, subview) in subviews.enumerated() {
            var size = subview.sizeThatFits(.unspecified)
            if size.width > width {
                // Too wide for a line of its own: let it wrap at the available width.
                size = subview.sizeThatFits(ProposedViewSize(width: width, height: nil))
                size.width = min(size.width, width)
            }
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if needed > width, !current.indices.isEmpty {
                rows.append(current)
                current = Row()
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
            current.sizes.append(size)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}
