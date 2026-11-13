import Foundation

enum SpeakerIdentityResolver {
    /// Match by retained turns in the SAME audio revision. A clean split can
    /// inherit; a merge of different people or any ambiguous overlap cannot.
    static func remap(_ previous: [SpeakerIdentityAssignment], turns: [SpeakerAudioTurn], audioRevision: String) -> [SpeakerIdentityAssignment] {
        var output: [SpeakerIdentityAssignment] = []
        for (label, newTurns) in Dictionary(grouping: turns, by: \.speaker) {
            let anchors = VisualSpeakerMatcher.union(newTurns.map(\.range))
            let duration = anchors.reduce(0) { $0 + $1.duration }
            guard duration > 0 else { continue }
            let candidates = previous.filter {
                $0.audioRevision == audioRevision
                    && ($0.source ?? SpeakerAudioTurn.legacySource($0.label)) == newTurns.first?.resolvedSource
            }.map { assignment in
                let overlap = anchors.reduce(0) { sum, anchor in
                    sum + VisualSpeakerMatcher.union(assignment.anchors).reduce(0) { $0 + anchor.overlap($1) }
                }
                return (assignment, overlap / duration)
            }.filter { $0.1 * duration > 0.25 }.sorted { $0.1 > $1.1 }
            guard var match = candidates.first, match.1 >= 0.8,
                  candidates.dropFirst().allSatisfy({ $0.0.id == match.0.id }) else { continue }
            match.0.label = label
            match.0.anchors = anchors
            output.append(match.0)
        }
        return output
    }

    static func apply(candidates: [SpeakerNameMatch], to assignment: inout SpeakerIdentityAssignment,
                      profiles: [SpeakerVoiceProfile]) -> [SpeakerNameMatch] {
        let allowed = candidates.filter { !assignment.suppressedNames.contains(ParticipantObservation.nameKey($0.name)) }
        guard !assignment.origin.isProtected, !assignment.automaticDisabled else { return [] }
        let visual = allowed.first { $0.source == .visual }
        let voice = allowed.first { $0.source == .profile }
        var conflict = false
        if let visual, let voice, visual.supportSeconds >= 2 {
            let linked = profiles.first { $0.id == voice.profileID }?.confirmedNames ?? [voice.name]
            conflict = !linked.contains { ParticipantObservation.nameKey($0) == ParticipantObservation.nameKey(visual.name) }
        }
        let winner = conflict ? nil : allowed.first { $0.tier == .automatic }
        if let existing = assignment.name, let winner,
           ParticipantObservation.nameKey(existing) != ParticipantObservation.nameKey(winner.name) {
            // Withdraw into review; never silently replace one displayed person with another.
            assignment.name = nil
            assignment.match = nil
            assignment.supportingMatches = nil
            assignment.automaticDisabled = true
            return Array(allowed.prefix(3))
        }
        if let winner {
            assignment.name = winner.name
            assignment.origin = winner.source == .visual ? .visualAutomatic : .profileAutomatic
            assignment.match = winner
            assignment.supportingMatches = [visual, voice].compactMap { $0 }
            assignment.profileID = winner.profileID
        } else if conflict || visual.map({ ParticipantObservation.nameKey($0.name) != ParticipantObservation.nameKey(assignment.name ?? "") }) == true {
            assignment.name = nil
            assignment.match = nil
            assignment.supportingMatches = nil
        }
        return Array(allowed.prefix(3))
    }
}
