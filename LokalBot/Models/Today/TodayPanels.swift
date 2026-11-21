import Foundation

enum TodayColumns {
    static let trailingWidth: CGFloat = 336
    static let leadingMinimumWidth: CGFloat = 480
    static let gap: CGFloat = 16

    static func factor(textScale: CGFloat) -> CGFloat {
        max(textScale, 0.5) / AppTextSize.standard.scale
    }

    static func trailingWidth(textScale: CGFloat) -> CGFloat {
        (trailingWidth * factor(textScale: textScale)).rounded()
    }

    static func twoColumnMinimumWidth(textScale: CGFloat) -> CGFloat {
        (leadingMinimumWidth * factor(textScale: textScale)).rounded()
            + gap + trailingWidth(textScale: textScale)
    }

    static func count(width: CGFloat, textScale: CGFloat,
                      hasLeading: Bool = true, hasTrailing: Bool = true) -> Int {
        guard hasLeading, hasTrailing else { return 1 }
        return width >= twoColumnMinimumWidth(textScale: textScale) ? 2 : 1
    }

    static func pageMaximumWidth(hasLeading: Bool, hasTrailing: Bool,
                                 wide: CGFloat, reading: CGFloat) -> CGFloat {
        hasLeading != hasTrailing ? reading : wide
    }
}

enum TodayAppBars {
    struct Bar: Equatable, Identifiable {
        let label: String
        let seconds: TimeInterval
        let fraction: Double
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

struct TodayAttentionSummary: Equatable {
    let open: Int
    let overdue: Int
    let shown: Int
    let remainder: Int

    var showsFooter: Bool { remainder > 0 }

    init(threads: [ActionThread], limit: Int, now: Date = Date(), calendar: Calendar = .current) {
        open = threads.count
        overdue = threads.filter { $0.isOverdue(now: now, calendar: calendar) }.count
        shown = min(threads.count, max(0, limit))
        remainder = threads.count - shown
    }
}
