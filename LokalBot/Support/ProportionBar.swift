import SwiftUI

enum AppTimePresentation {
    struct Row: Equatable {
        let label: String
        let seconds: TimeInterval
        let appCount: Int
        let isOther: Bool
    }

    static func rows(
        perApp: [(label: String, seconds: TimeInterval)],
        cap: Int = 5,
        minimumVisibleSeconds: TimeInterval = 60
    ) -> [Row] {
        let sorted = perApp.filter { $0.seconds > 0 }
            .sorted { $0.seconds > $1.seconds }
        var visible: [Row] = []
        var otherSeconds: TimeInterval = 0
        var otherCount = 0
        for item in sorted {
            if item.seconds >= minimumVisibleSeconds && visible.count < max(0, cap) {
                visible.append(Row(
                    label: item.label,
                    seconds: item.seconds,
                    appCount: 1,
                    isOther: false))
            } else {
                otherSeconds += item.seconds
                otherCount += 1
            }
        }
        if otherCount > 0 {
            visible.append(Row(
                label: "Other",
                seconds: otherSeconds,
                appCount: otherCount,
                isOther: true))
        }
        return visible
    }
}

enum ProportionBarMath {
    struct Segment: Equatable {
        let label: String
        let fraction: Double
    }

    static func segments(perApp: [(label: String, seconds: TimeInterval)],
                         cap: Int = 5) -> [Segment] {
        let positive = perApp.filter { $0.seconds > 0 }
        let total = positive.reduce(0) { $0 + $1.seconds }
        guard total > 0 else { return [] }
        let sorted = positive.sorted { $0.seconds > $1.seconds }
        let top = sorted.prefix(cap).map {
            Segment(label: $0.label, fraction: $0.seconds / total)
        }
        let rest = sorted.dropFirst(cap).reduce(0) { $0 + $1.seconds }
        guard rest > 0 else { return top }
        return top + [Segment(label: "Other", fraction: rest / total)]
    }
}

struct ProportionBar: View {
    let segments: [(segment: ProportionBarMath.Segment, color: Color)]
    var height: CGFloat = 10

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                ForEach(Array(segments.enumerated()), id: \.offset) { pair in
                    Rectangle()
                        .fill(pair.element.color)
                        .frame(width: max(1, geo.size.width * pair.element.segment.fraction))
                }
            }
        }
        .frame(height: height)
        .background(.quaternary.opacity(0.4))
        .clipShape(Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Time by app")
        .accessibilityValue(segments.map {
            "\($0.segment.label) \(Int(($0.segment.fraction * 100).rounded())) percent"
        }.joined(separator: ", "))
    }
}
