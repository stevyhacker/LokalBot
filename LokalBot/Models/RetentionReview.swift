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
        var evidenceDates: [Date] {
            let calendar = Calendar.current
            var dates = [start, end]
            var cursor = calendar.startOfDay(for: start)
            while let next = calendar.date(byAdding: .day, value: 1, to: cursor), next < end, next > cursor {
                dates.append(next)
                cursor = next
            }
            return dates
        }
    }
    let id = UUID()
    let days: Int
    let keepTextForever: Bool
    let reviewedAt: Date
    let candidates: [Candidate]
    let savedCount: Int
    let bytes: Int64
    var activityTitles: [ActivityTitle] = []

    var pixelCount: Int { candidates.filter { !$0.path.isEmpty }.count }
    var textCount: Int { candidates.filter(\.removeText).count }
    var vectorCount: Int { candidates.filter(\.removeVector).count }
    var metadataCount: Int { candidates.filter(\.removeMetadata).count }
    var evidenceDates: [Date] { candidates.map(\.timestamp) + activityTitles.flatMap(\.evidenceDates) }
    var oldest: Date? { evidenceDates.min() }
    var newest: Date? { evidenceDates.max() }

    /// A disappearing file or newly saved moment may shrink a review safely.
    /// Additional data, changed paths or new text require a fresh review.
    func covers(_ current: RetentionReview) -> Bool {
        let approved = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0) })
        let approvedActivity = Set(activityTitles)
        return days == current.days && keepTextForever == current.keepTextForever
            && Set(current.activityTitles).isSubset(of: approvedActivity)
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
