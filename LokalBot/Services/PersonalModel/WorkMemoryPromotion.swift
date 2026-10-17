import Foundation

/// Suggests long-running work as About you items. The overnight review keeps
/// short-lived work memory (projects and goals that age out after 30–45
/// days); a goal or project it keeps seeing for two weeks or more, and saw in
/// the last week, says something durable about the person. No model call:
/// the review already distilled the day's meetings, digest, and timeline.
/// Every promotion waits for review and depends on the review's evidence.
enum WorkMemoryPromotion {
    static let minimumDays = 14
    static let recentDays = 7

    struct Result: Equatable {
        var sightings: [PersonalModel.WorkSighting]
        var candidates: [PersonalModel.LearningCandidate]
    }

    /// Records when each current goal and project was first seen, forgets
    /// ones the memory no longer holds, and returns those that qualify.
    static func evaluate(memory: DreamMemory, sightings: [PersonalModel.WorkSighting], dayKey: String,
                         calendar: Calendar = .current) -> Result {
        var firstSeen: [String: String] = [:]
        for sighting in sightings { firstSeen[sighting.key] = sighting.firstDayKey }
        var kept: [PersonalModel.WorkSighting] = []
        var candidates: [PersonalModel.LearningCandidate] = []

        func consider(key: String, kind: PersonalClaimKind, text: String, lastActiveDay: String,
                      provenance: DreamEvidenceProvenance?) {
            let first = firstSeen[key] ?? dayKey
            kept.append(.init(key: key, firstDayKey: first))
            guard let provenance, !provenance.includesUnattributedContext,
                  days(from: first, to: dayKey, calendar: calendar) >= minimumDays,
                  days(from: lastActiveDay, to: dayKey, calendar: calendar) <= recentDays else { return }
            candidates.append(PersonalModel.LearningCandidate(
                kind: kind, text: text, quote: nil, origin: .workMemory(dayKey: first),
                evidence: provenance, needsReview: true))
        }

        for goal in memory.workGoals {
            consider(key: "goal:" + PersonalModel.tombstoneKey(goal.text), kind: .goal, text: goal.text,
                     lastActiveDay: goal.lastReinforcedDay, provenance: goal.provenance)
        }
        for project in memory.activeProjects {
            consider(key: "project:" + PersonalModel.tombstoneKey(project.name), kind: .fact,
                     text: "I work on \(project.name).", lastActiveDay: project.lastActiveDay,
                     provenance: project.provenance)
        }
        return Result(sightings: kept, candidates: candidates)
    }

    static func days(from start: String, to end: String, calendar: Calendar) -> Int {
        guard let from = DreamDay.date(fromKey: start, calendar: calendar),
              let to = DreamDay.date(fromKey: end, calendar: calendar) else { return 0 }
        return calendar.dateComponents([.day], from: from, to: to).day ?? 0
    }
}
