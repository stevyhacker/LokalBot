import CoreGraphics
import Foundation

enum TimelineRailMetric {
    static let idealWidth: CGFloat = 352
    static let minimumWidth: CGFloat = 300
    static let share: CGFloat = 0.30
    static let floorWidth: CGFloat = 260
    static let maximumWidth: CGFloat = 540
    static let pageMinimumWidth: CGFloat = 420
    static let dividerWidth: CGFloat = 1

    static var bodyMinimumWidth: CGFloat { pageMinimumWidth + dividerWidth + floorWidth }

    static func width(available: CGFloat, textScale: CGFloat) -> CGFloat {
        let factor = TodayColumns.factor(textScale: textScale)
        let ideal = (idealWidth * factor).rounded()
        let minimum = (minimumWidth * factor).rounded()
        let shared = min(ideal, max(minimum, (available * share).rounded()))
        let room = available - dividerWidth - pageMinimumWidth
        return max(floorWidth, min(shared, room.rounded(.down)))
    }
}

enum TimelinePageMetric {
    static let gutter: CGFloat = 24
    static let maximumWidth: CGFloat = 1_100
    static let panelGap: CGFloat = 16
}

struct TimelineTrackedSummary: Equatable {
    let tracked: TimeInterval
    let detail: String?
    let strip: TimelineDayStrip?
    let legend: [TimelineDayLegend.Entry]
    let meetingSeconds: TimeInterval

    init?(
        perApp: [(label: String, seconds: TimeInterval)],
        split: TimelineProjectAttribution.DaySplit,
        list: TimelineDayList,
        meetingCount: Int,
        outcomes: TimelineAgentOutcomes,
        day: Date,
        calendar: Calendar = .current,
        localize: (String) -> String = { $0 }
    ) {
        guard !perApp.isEmpty || meetingCount > 0 else { return nil }
        tracked = perApp.reduce(0) { $0 + $1.seconds }
        detail = Self.detail(meetingCount: meetingCount, outcomes: outcomes, localize: localize)
        strip = TimelineDayStrip(rows: list.rows, day: day, calendar: calendar)
        legend = TimelineDayLegend.entries(perApp: perApp, split: split)
        meetingSeconds = list.rows.filter(\.isMeeting).reduce(0) { $0 + $1.duration }
    }

    static func detail(
        meetingCount: Int,
        outcomes: TimelineAgentOutcomes,
        localize: (String) -> String = { $0 }
    ) -> String? {
        var parts: [String] = []
        if meetingCount > 0 {
            parts.append(String(format: localize(meetingCount == 1 ? "%lld meeting" : "%lld meetings"),
                                meetingCount))
        }
        parts += TimelineOutcomeWording.parts(outcomes, localize: localize)
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

extension TimelineDayStrip {
    static func hitFrame(
        of bar: Bar, in width: CGFloat, minimumWidth: CGFloat = 12
    ) -> (x: CGFloat, width: CGFloat) {
        let drawn = frame(of: bar, in: width)
        guard width > 0, drawn.width < minimumWidth else { return drawn }
        let hitWidth = min(width, minimumWidth)
        let x = drawn.x + drawn.width / 2 - hitWidth / 2
        return (min(max(0, x), width - hitWidth), hitWidth)
    }

    static func hitOrder(_ bars: [Bar]) -> [Bar] {
        bars.enumerated().sorted { left, right in
            let leftLength = left.element.end - left.element.start
            let rightLength = right.element.end - right.element.start
            return leftLength != rightLength ? leftLength > rightLength : left.offset < right.offset
        }.map(\.element)
    }
}

extension TimelineDayActions {
    enum Pill: Equatable {
        case open(Int)
        case allDone
    }

    static func pill(for summary: Summary) -> Pill {
        switch summary {
        case .open(let count): .open(count)
        case .allDone: .allDone
        case .noneOpen: .open(0)
        }
    }

    static func showsRows(_ summary: Summary, hadOpen: Bool) -> Bool {
        if case .open = summary { return true }
        return hadOpen
    }
}
