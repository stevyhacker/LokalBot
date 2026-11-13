import Foundation

/// Unknown dates stay last in either direction. Equal dates retain the
/// existing newest-meeting order and a stable identity tie-break.
struct ActionDueSort: SortComparator {
    var order: SortOrder = .forward

    func compare(_ lhs: OutcomeActionReference, _ rhs: OutcomeActionReference) -> ComparisonResult {
        let left = lhs.resolvedDueDate
        let right = rhs.resolvedDueDate
        switch (left, right) {
        case (.none, .some): return .orderedDescending
        case (.some, .none): return .orderedAscending
        case (.some(let left), .some(let right)) where left != right:
            return (left < right) == (order == .forward) ? .orderedAscending : .orderedDescending
        default:
            if lhs.meetingStartedAt != rhs.meetingStartedAt {
                return lhs.meetingStartedAt > rhs.meetingStartedAt ? .orderedAscending : .orderedDescending
            }
            if lhs.id == rhs.id { return .orderedSame }
            return lhs.id < rhs.id ? .orderedAscending : .orderedDescending
        }
    }
}
