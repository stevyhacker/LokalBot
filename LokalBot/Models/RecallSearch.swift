import Foundation

struct MeetingRecallGroup: Identifiable, Sendable {
    let id: UUID
    let matches: [SearchIndex.Hit]
    var primary: SearchIndex.Hit { matches.first(where: { $0.kind == .segment }) ?? matches[0] }
}

/// Shared grouping and lexical retrieval for Ask, Quick Recall and the library.
/// Limits are applied to groups after ranking. The UI says "Showing" because
/// the index fetch is bounded; it never presents the sampled count as a total.
enum RecallSearch {
    static func groups(_ hits: [SearchIndex.Hit], limit: Int = 40) -> [MeetingRecallGroup] {
        var order: [UUID] = []
        var groups: [UUID: [SearchIndex.Hit]] = [:]
        for hit in hits {
            if groups[hit.meetingID] == nil { order.append(hit.meetingID) }
            groups[hit.meetingID, default: []].append(hit)
        }
        return order.prefix(limit).map { MeetingRecallGroup(id: $0, matches: groups[$0] ?? []) }
    }

    @MainActor
    static func meetings(_ query: String, index: SearchIndex, kind: SearchIndex.Kind? = nil,
                         meetingIDs: Set<UUID>? = nil) -> [MeetingRecallGroup] {
        groups(index.search(query, kind: kind, limit: 2_000, meetingIDs: meetingIDs))
    }
}
