import Foundation

/// One column or two. Today's panels sit side by side when the page is wide
/// enough for a readable leading column beside the fixed trailing one, and
/// stack in reading order otherwise. Widths are in points at the default
/// text size and grow with larger text.
enum TodayColumns {
    /// The trailing column (So far today, Yesterday) at the default text size.
    static let trailingWidth: CGFloat = 336
    /// The narrowest leading column (Needs attention, Meetings today) that
    /// still reads well beside the trailing one.
    static let leadingMinimumWidth: CGFloat = 480
    /// Space between the columns, and between panels in a column.
    static let gap: CGFloat = 16

    /// How much wider than at the default text size the columns are.
    static func factor(textScale: CGFloat) -> CGFloat {
        max(textScale, 0.5) / AppTextSize.standard.scale
    }

    static func trailingWidth(textScale: CGFloat) -> CGFloat {
        (trailingWidth * factor(textScale: textScale)).rounded()
    }

    /// The narrowest page content, inside its side padding, that shows two
    /// columns.
    static func twoColumnMinimumWidth(textScale: CGFloat) -> CGFloat {
        (leadingMinimumWidth * factor(textScale: textScale)).rounded()
            + gap + trailingWidth(textScale: textScale)
    }

    /// `width` is the page content's width inside its side padding. A side
    /// with no panels leaves no gutter: the page is one column.
    static func count(width: CGFloat, textScale: CGFloat,
                      hasLeading: Bool = true, hasTrailing: Bool = true) -> Int {
        guard hasLeading, hasTrailing else { return 1 }
        return width >= twoColumnMinimumWidth(textScale: textScale) ? 2 : 1
    }

    /// The page's widest, side padding included. Two columns and the cards
    /// that span them use the full width; panels that can only ever form one
    /// column keep the narrower reading width.
    static func pageMaximumWidth(hasLeading: Bool, hasTrailing: Bool,
                                 wide: CGFloat, reading: CGFloat) -> CGFloat {
        hasLeading != hasTrailing ? reading : wide
    }
}

/// So far today's bars: the same apps the page listed before, each with its
/// length as a share of the longest row.
enum TodayAppBars {
    struct Bar: Equatable, Identifiable {
        let label: String
        let seconds: TimeInterval
        /// 0...1, where the longest row is 1.
        let fraction: Double
        /// The folded long tail, which has no colour of its own.
        let isOther: Bool

        var id: String { (isOther ? "other:" : "app:") + label }
    }

    static func bars(perApp: [(label: String, seconds: TimeInterval)], cap: Int) -> [Bar] {
        let rows = AppTimePresentation.rows(perApp: perApp, cap: cap)
        let longest = rows.map(\.seconds).max() ?? 0
        return rows.map { row in
            Bar(label: row.label, seconds: row.seconds,
                fraction: longest > 0 ? min(1, max(0, row.seconds / longest)) : 0,
                isOther: row.isOther)
        }
    }
}

/// The numbers Needs attention says about itself: how many actions are open,
/// how many of those are overdue, and how many the panel leaves to Actions.
struct TodayAttentionSummary: Equatable {
    let open: Int
    let overdue: Int
    /// Rows on the page.
    let shown: Int
    /// Open actions the panel leaves to the Actions page.
    let remainder: Int

    /// The footer appears only when Actions holds more than the rows shown.
    var showsFooter: Bool { remainder > 0 }

    init(threads: [ActionThread], limit: Int, now: Date = Date(), calendar: Calendar = .current) {
        open = threads.count
        overdue = threads.filter { $0.isOverdue(now: now, calendar: calendar) }.count
        shown = min(threads.count, max(0, limit))
        remainder = threads.count - shown
    }
}
