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

    /// Fuse at the source level so a meeting with many lexical rows cannot
    /// bury a relevant semantic-only meeting. Preserve lexical excerpts and
    /// deterministically deduplicate the same source passage across both lists.
    static func fusedMeetings(keyword: [SearchIndex.Hit], semantic: [SearchIndex.Hit],
                              limit: Int = 40) -> [MeetingRecallGroup] {
        guard limit > 0 else { return [] }
        let lexical = groups(keyword, limit: Int.max)
        let conceptual = groups(semantic, limit: Int.max)
        var scores: [UUID: Double] = [:]
        var firstRanks: [UUID: Int] = [:]
        for list in [lexical, conceptual] {
            for (rank, group) in list.enumerated() {
                scores[group.id, default: 0] += 1 / (60 + Double(rank + 1))
                firstRanks[group.id] = min(firstRanks[group.id] ?? .max, rank)
            }
        }
        let matches = Dictionary(grouping: keyword + semantic, by: \.meetingID)
        let order = scores.keys.sorted {
            if scores[$0] != scores[$1] { return scores[$0, default: 0] > scores[$1, default: 0] }
            if firstRanks[$0] != firstRanks[$1] { return firstRanks[$0, default: .max] < firstRanks[$1, default: .max] }
            return $0.uuidString < $1.uuidString
        }
        struct Passage: Hashable { let kind: String; let start: TimeInterval; let text: String }
        return order.prefix(limit).map { id in
            var seen = Set<Passage>()
            let unique = (matches[id] ?? []).filter {
                let text = $0.snippet.replacingOccurrences(of: "«", with: "")
                    .replacingOccurrences(of: "»", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
                return seen.insert(Passage(kind: $0.kind.rawValue, start: $0.start, text: text)).inserted
            }
            return MeetingRecallGroup(id: id, matches: unique)
        }
    }

    @MainActor
    static func meetings(_ query: String, index: SearchIndex, kind: SearchIndex.Kind? = nil,
                         meetingIDs: Set<UUID>? = nil) -> [MeetingRecallGroup] {
        groups(index.search(query, kind: kind, limit: 2_000, meetingIDs: meetingIDs))
    }
}
