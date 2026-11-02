import Foundation

/// The order ffi.md gives `actions()`: overdue first, then by due date (none
/// last), then the newest meeting first.
public enum ActionOrdering {
    public static func isOverdue(_ action: ActionItem, today: DayKey) -> Bool {
        guard action.status == .open, let due = action.dueDate.flatMap(DayKey.init) else { return false }
        return due < today
    }

    public static func sorted(_ rows: [ActionRow], today: DayKey) -> [ActionRow] {
        rows.sorted { lhs, rhs in
            let lhsOverdue = isOverdue(lhs.action, today: today)
            let rhsOverdue = isOverdue(rhs.action, today: today)
            if lhsOverdue != rhsOverdue { return lhsOverdue }
            switch (lhs.action.dueDate, rhs.action.dueDate) {
            case let (l?, r?) where l != r: return l < r
            case (.some, nil): return true
            case (nil, .some): return false
            default: break
            }
            if lhs.meetingStartedAt != rhs.meetingStartedAt { return lhs.meetingStartedAt > rhs.meetingStartedAt }
            return lhs.id < rhs.id
        }
    }

    /// Whose action it is, for the Actions filters.
    public enum Owner: String, CaseIterable, Sendable, Hashable, Identifiable {
        case mine, others, unclear

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .mine: "Mine"
            case .others: "Others"
            case .unclear: "Owner unclear"
            }
        }

        public func matches(_ action: ActionItem) -> Bool {
            switch self {
            case .mine: action.ownerIsUser
            case .others: !action.ownerIsUser && !action.ownerUnclear
            case .unclear: action.ownerUnclear
            }
        }
    }

    /// Groups for a list already in `sorted` order.
    public enum Group: String, Sendable, Hashable, CaseIterable {
        case overdue, today, thisWeek, later, earlier, noDate

        public var title: String {
            switch self {
            case .overdue: "Overdue"
            case .today: "Today"
            case .thisWeek: "This week"
            case .later: "Later"
            case .earlier: "Earlier"
            case .noDate: "No due date"
            }
        }
    }

    public static func group(of action: ActionItem, today: DayKey, calendar: Calendar = .current) -> Group {
        guard let due = action.dueDate.flatMap(DayKey.init) else { return .noDate }
        if isOverdue(action, today: today) { return .overdue }
        let distance = today.days(until: due, calendar: calendar)
        switch distance {
        case ..<0: return .earlier
        case 0: return .today
        case 1...6: return .thisWeek
        default: return .later
        }
    }

    public static func grouped(_ rows: [ActionRow], today: DayKey, calendar: Calendar = .current) -> [(group: Group, rows: [ActionRow])] {
        var buckets: [Group: [ActionRow]] = [:]
        for row in rows { buckets[group(of: row.action, today: today, calendar: calendar), default: []].append(row) }
        return Group.allCases.compactMap { group in buckets[group].map { (group, $0) } }
    }
}
