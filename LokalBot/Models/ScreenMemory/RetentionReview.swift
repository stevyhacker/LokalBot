import Foundation

struct RetentionReview: Identifiable {
    struct Candidate: Equatable, Hashable, Identifiable {
        let id: Int64
        let timestamp: Date
        let path: String
        let removeText: Bool
        let removeVector: Bool
        var removeMetadata: Bool = false
    }
    struct ActivityTitle: Equatable, Hashable, Identifiable {
        let id: Int64
        let start: Date
        let end: Date
        let title: String
        var evidenceDates: [Date] { evidenceDates(calendar: .current) }

        func evidenceDates(calendar: Calendar) -> [Date] {
            var dates = [start, end]
            var cursor = calendar.startOfDay(for: start)
            while let next = calendar.date(byAdding: .day, value: 1, to: cursor), next < end, next > cursor {
                dates.append(next)
                cursor = next
            }
            return dates
        }
    }
    /// A stored coding-agent burst. Its requests and reports are text, so
    /// they expire with screen text.
    struct CodingAgentBurst: Equatable, Hashable, Identifiable {
        let id: String
        let start: Date
    }
    let id = UUID()
    let days: Int
    let keepTextForever: Bool
    let reviewedAt: Date
    let candidates: [Candidate]
    let savedCount: Int
    let bytes: Int64
    var activityTitles: [ActivityTitle] = []
    var codingAgentBursts: [CodingAgentBurst] = []

    var pixelCount: Int { candidates.filter { !$0.path.isEmpty }.count }
    var textCount: Int { candidates.filter(\.removeText).count }
    var vectorCount: Int { candidates.filter(\.removeVector).count }
    var metadataCount: Int { candidates.filter(\.removeMetadata).count }
    var evidenceDates: [Date] {
        candidates.map(\.timestamp) + activityTitles.flatMap(\.evidenceDates) + codingAgentBursts.map(\.start)
    }
    var oldest: Date? { evidenceDates.min() }
    var newest: Date? { evidenceDates.max() }

    /// `evidenceDates` (plus `extra`) reduced to one date per distinct pair of
    /// local day and UTC day, sorted. Evidence consumers key only on those
    /// days: Dream invalidation by UTC day, digests and exports by local day.
    /// A pass after a long gap would otherwise hand them a date per row.
    func distinctEvidenceDays(adding extra: [Date] = [], calendar: Calendar = .current) -> [Date] {
        struct Day: Hashable { let utc: Int; let local: Int }
        func localDay(_ date: Date) -> Int {
            let seconds = date.timeIntervalSince1970 + Double(calendar.timeZone.secondsFromGMT(for: date))
            return Int((seconds / 86_400).rounded(.down))
        }
        var seen = Set<Day>()
        var dates: [Date] = []
        func add(_ date: Date) {
            let day = Day(utc: Int((date.timeIntervalSince1970 / 86_400).rounded(.down)), local: localDay(date))
            if seen.insert(day).inserted { dates.append(date) }
        }
        candidates.forEach { add($0.timestamp) }
        for title in activityTitles {
            // A title within one local day crosses no midnight to add.
            if localDay(title.start) == localDay(title.end) {
                add(title.start)
                add(title.end)
            } else {
                title.evidenceDates(calendar: calendar).forEach(add)
            }
        }
        codingAgentBursts.forEach { add($0.start) }
        extra.forEach(add)
        return dates.sorted()
    }

    /// A disappearing file or newly saved moment may shrink a review safely.
    /// Additional data, changed paths or new text require a fresh review.
    func covers(_ current: RetentionReview) -> Bool {
        let approved = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0) })
        let approvedActivity = Set(activityTitles)
        return days == current.days && keepTextForever == current.keepTextForever
            && Set(current.activityTitles).isSubset(of: approvedActivity)
            && Set(current.codingAgentBursts).isSubset(of: Set(codingAgentBursts))
            && current.candidates.allSatisfy { candidate in
                guard let old = approved[candidate.id] else { return false }
                return candidate.timestamp == old.timestamp
                    && (candidate.path.isEmpty || candidate.path == old.path)
                    && (!candidate.removeText || old.removeText)
                    && (!candidate.removeVector || old.removeVector)
                    && (!candidate.removeMetadata || old.removeMetadata)
            }
    }
}

enum RetentionReviewError: LocalizedError {
    case scopeChanged
    var errorDescription: String? {
        "The cleanup scope changed. Review the updated counts before applying it."
    }
}
