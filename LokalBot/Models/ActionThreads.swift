import Foundation

/// One continuing commitment assembled from compatible action mentions across
/// meetings. The references remain the source of truth; a thread is only a
/// derived presentation and never replaces or rewrites extracted evidence.
struct ActionThread: Identifiable, Equatable, Sendable {
    let id: String
    let references: [OutcomeActionReference]
    let text: String
    let owner: String?
    let due: String?
    let dueSourceMeetingDate: Date?

    var latestReference: OutcomeActionReference { references[0] }
    var meetingCount: Int { Set(references.map(\.meetingID)).count }
    var mentionCount: Int { references.count }
    var hasMultipleMeetings: Bool { meetingCount > 1 }
    var hasMixedStatus: Bool { Set(references.map(\.status)).count > 1 }
    var isForUser: Bool {
        let correction = references.filter(\.ownerWasCorrected).max {
            ($0.ownerCorrectedAt ?? $0.stateUpdatedAt) < ($1.ownerCorrectedAt ?? $1.stateUpdatedAt)
        }
        return correction?.isForUser ?? references.allSatisfy(\.isForUser)
    }
    var statusLabel: String { hasMixedStatus ? "Mixed" : status.label }

    /// A completed mention cannot hide unfinished work in another meeting.
    var status: OutcomeStatus {
        if references.contains(where: { $0.status == .open }) { return .open }
        if references.contains(where: { $0.status == .deferred }) { return .deferred }
        return .done
    }

    var dueHistory: [String] {
        references.compactMap(\.due).reduce(into: [String]()) { result, due in
            if !result.contains(where: {
                $0.caseInsensitiveCompare(due) == .orderedSame
            }) {
                result.append(due)
            }
        }
    }

    fileprivate init(references: [OutcomeActionReference]) {
        precondition(!references.isEmpty)
        let sorted = references.sorted {
            if $0.meetingStartedAt != $1.meetingStartedAt {
                return $0.meetingStartedAt > $1.meetingStartedAt
            }
            return $0.id < $1.id
        }
        self.references = sorted

        let correctedText = sorted
            .filter(\.textWasCorrected)
            .max { ($0.textCorrectedAt ?? $0.stateUpdatedAt) < ($1.textCorrectedAt ?? $1.stateUpdatedAt) }
        let descriptiveText = sorted.max {
            if $0.text.count != $1.text.count { return $0.text.count < $1.text.count }
            return $0.meetingStartedAt < $1.meetingStartedAt
        }
        text = (correctedText ?? descriptiveText ?? sorted[0]).text
        let correctedOwner = sorted
            .filter(\.ownerWasCorrected)
            .max { ($0.ownerCorrectedAt ?? $0.stateUpdatedAt) < ($1.ownerCorrectedAt ?? $1.stateUpdatedAt) }
        owner = correctedOwner.map(\.owner) ?? sorted.compactMap(\.owner).first
        let correctedDue = sorted
            .filter(\.dueWasCorrected)
            .max { ($0.dueCorrectedAt ?? $0.stateUpdatedAt) < ($1.dueCorrectedAt ?? $1.stateUpdatedAt) }
        let dueReference = correctedDue ?? sorted.first { $0.due != nil }
        due = dueReference?.due
        dueSourceMeetingDate = dueReference?.meetingStartedAt
        id = Self.stableID(for: sorted)
    }

    private static func stableID(for references: [OutcomeActionReference]) -> String {
        let value = references.map(\.id).sorted().joined(separator: "|")
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        return String(format: "thread-%016llx", hash)
    }
}

/// Only equal canonical source commitments form threads. Similar wording is
/// not sufficient authority to share status, ownership, or corrections.
enum ActionThreadClusterer {
    static let maximumMeetingSpan: TimeInterval = 30 * 86_400

    private struct SourceKey: Hashable {
        var text: String
        var owner: String
        var isForUser: Bool
    }

    private struct Group {
        var references: [OutcomeActionReference]
        var meetingIDs: Set<UUID>
        var latestDate: Date
    }

    static func cluster(_ references: [OutcomeActionReference]) -> [ActionThread] {
        let sorted = references.sorted {
            if $0.meetingStartedAt != $1.meetingStartedAt {
                return $0.meetingStartedAt > $1.meetingStartedAt
            }
            return $0.id < $1.id
        }
        var groups: [Group] = []
        var candidates: [SourceKey: [Int]] = [:]

        for reference in sorted {
            let key = sourceKey(reference)
            var matching = key.flatMap { candidates[$0] } ?? []
            // Input is newest first, so expired groups never become candidates
            // again. Normalize once per reference, never once per pair.
            matching.removeAll {
                groups[$0].latestDate.timeIntervalSince(reference.meetingStartedAt) > maximumMeetingSpan
            }
            if let index = matching.first(where: { !groups[$0].meetingIDs.contains(reference.meetingID) }) {
                groups[index].references.append(reference)
                groups[index].meetingIDs.insert(reference.meetingID)
            } else {
                matching.append(groups.count)
                groups.append(Group(references: [reference], meetingIDs: [reference.meetingID],
                                    latestDate: reference.meetingStartedAt))
            }
            if let key { candidates[key] = matching }
        }

        return groups.map { ActionThread(references: $0.references) }.sorted {
            if $0.latestReference.meetingStartedAt != $1.latestReference.meetingStartedAt {
                return $0.latestReference.meetingStartedAt > $1.latestReference.meetingStartedAt
            }
            return $0.id < $1.id
        }
    }

    private static func sourceKey(_ reference: OutcomeActionReference) -> SourceKey? {
        guard !reference.isThreadExcluded else { return nil }
        let text = canonicalSourceText(reference.action.displayText)
        // Short generic commitments recur naturally and are unsafe to merge.
        guard OutcomeTextSimilarity.significantTokens(text).count >= 3 else { return nil }
        if reference.action.isForUser { return SourceKey(text: text, owner: "", isForUser: true) }
        guard let owner = reference.action.owner.map(OutcomeTextSimilarity.normalized), !owner.isEmpty else {
            return nil
        }
        return SourceKey(text: text, owner: owner, isForUser: false)
    }

    private static func canonicalSourceText(_ text: String) -> String {
        let normalized = text.folding(options: [.caseInsensitive, .diacriticInsensitive],
                                      locale: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: "’", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".!?")))
        var words = normalized.split(whereSeparator: \.isWhitespace).map(String.init)
        // Remove only complete, harmless leading phrases; preserve verb,
        // negation, word order, names, and identifiers everywhere else.
        for prefix in [["i", "will"], ["i'll"], ["we", "will"], ["please"]]
            where words.starts(with: prefix) {
            words.removeFirst(prefix.count)
            break
        }
        return words.joined(separator: " ")
    }

}

/// Converts an editor's visible optional field back to persistence intent.
/// Untouched extracted values continue to inherit; an existing correction or
/// a user edit is written verbatim, including an empty explicit clear.
enum ActionCorrectionFieldIntent {
    static func persistedValue(
        _ value: String,
        wasCorrected: Bool,
        wasEdited: Bool
    ) -> String? {
        wasCorrected || wasEdited ? value : nil
    }
}

enum OutcomeTextSimilarity {
    private static let leadingNoise: Set<String> = [
        "a", "an", "i", "ill", "me", "my", "need", "please", "the", "to", "we", "will",
    ]

    static func normalized(_ text: String) -> String {
        text.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    static func tokens(_ text: String) -> Set<String> {
        Set(normalized(text).split(separator: " ").map(String.init))
    }

    static func significantTokens(_ text: String) -> Set<String> {
        tokens(text).subtracting(leadingNoise)
    }

    static func identifierTokens(_ text: String) -> Set<String> {
        Set(tokens(text).filter { token in token.contains(where: \.isNumber) })
    }

    static func isSimilar(_ lhs: String, _ rhs: String, threshold: Double) -> Bool {
        let left = tokens(lhs)
        let right = tokens(rhs)
        let union = left.union(right)
        guard !union.isEmpty else { return false }
        return Double(left.intersection(right).count) / Double(union.count) >= threshold
    }
}
