import CoreGraphics
import Foundation

/// Timeline's body: the day's page on the leading side and a rail on the
/// trailing one, with a hairline between them. The rail takes a share of the
/// width between its two sizes, and gives way before the page gets tighter
/// than its minimum. Widths are in points at the default text size; the
/// rail's two sizes grow with larger text.
enum TimelineRailMetric {
    /// The rail in a roomy window.
    static let idealWidth: CGFloat = 352
    /// The rail in the app's default 1,180-point window.
    static let minimumWidth: CGFloat = 300
    /// The rail's share of the body while it is between those two.
    static let share: CGFloat = 0.30
    /// The rail in the narrowest window: a time, a short title and a
    /// duration still fit a row.
    static let floorWidth: CGFloat = 260
    /// The page keeps the minimum every detail pane has.
    static let pageMinimumWidth: CGFloat = 420
    static let dividerWidth: CGFloat = 1

    /// The narrowest body: the page at its minimum beside the rail at its floor.
    static var bodyMinimumWidth: CGFloat { pageMinimumWidth + dividerWidth + floorWidth }

    /// The rail's width in a body `available` points wide.
    static func width(available: CGFloat, textScale: CGFloat) -> CGFloat {
        let factor = TodayColumns.factor(textScale: textScale)
        let ideal = (idealWidth * factor).rounded()
        let minimum = (minimumWidth * factor).rounded()
        let shared = min(ideal, max(minimum, (available * share).rounded()))
        // Larger text asks for a wider rail than a narrow window can give.
        let room = available - dividerWidth - pageMinimumWidth
        return max(floorWidth, min(shared, room.rounded(.down)))
    }
}

/// The day's page: panels that fill the main area inside their gutters, up
/// to a widest line in a very wide window.
enum TimelinePageMetric {
    static let gutter: CGFloat = 24
    /// The panels' widest, gutters not included.
    static let maximumWidth: CGFloat = 1_100
    /// Space between panels.
    static let panelGap: CGFloat = 16
}

/// What the rail's Tracked block says: the day's total, the line under it,
/// the hour strip and where the time went.
struct TimelineTrackedSummary: Equatable {
    let tracked: TimeInterval
    /// "4 meetings · 4 PRs opened · 1 merged", or nil on a day with neither.
    let detail: String?
    let strip: TimelineDayStrip?
    let legend: [TimelineDayLegend.Entry]
    /// The meetings' total, the legend's last row. Zero leaves the row out.
    let meetingSeconds: TimeInterval

    /// Nil for a day with no tracked time and no meetings: the block is left out.
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

    /// The meetings, then what the day's agents recorded, each count its own
    /// catalog entry.
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
    /// Where a click counts for a bar: its own place, widened to
    /// `minimumWidth` around its middle when it is drawn thinner, and kept
    /// inside the lane. The bar itself is drawn no wider than its time.
    static func hitFrame(
        of bar: Bar, in width: CGFloat, minimumWidth: CGFloat = 12
    ) -> (x: CGFloat, width: CGFloat) {
        let drawn = frame(of: bar, in: width)
        guard width > 0, drawn.width < minimumWidth else { return drawn }
        let hitWidth = min(width, minimumWidth)
        let x = drawn.x + drawn.width / 2 - hitWidth / 2
        return (min(max(0, x), width - hitWidth), hitWidth)
    }

    /// Bars in the order to draw them: the longest first, so a short bar's
    /// widened click area lies over its longer neighbour's edge.
    static func hitOrder(_ bars: [Bar]) -> [Bar] {
        bars.enumerated().sorted { left, right in
            let leftLength = left.element.end - left.element.start
            let rightLength = right.element.end - right.element.start
            return leftLength != rightLength ? leftLength > rightLength : left.offset < right.offset
        }.map(\.element)
    }
}

extension TimelineDayActions {
    /// The badge beside the panel's title.
    enum Pill: Equatable {
        case open(Int)
        case allDone
    }

    /// "2 open" while anything is; "All done" once every action is done.
    /// Deferred actions are neither, so a day with only those says "0 open".
    static func pill(for summary: Summary) -> Pill {
        switch summary {
        case .open(let count): .open(count)
        case .allDone: .allDone
        case .noneOpen: .open(0)
        }
    }

    /// The panel lists its actions while one is open. Once none is, it is a
    /// header alone, except that rows the reader was just shown stay, so
    /// ticking the last one does not take the list away.
    static func showsRows(_ summary: Summary, hadOpen: Bool) -> Bool {
        if case .open = summary { return true }
        return hadOpen
    }
}
