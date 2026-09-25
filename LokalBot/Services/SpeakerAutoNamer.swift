import Foundation

/// Calendar attendance supplies manual name suggestions, never voice identity.
/// Even one invitee and one mixed remote track do not prove who spoke.
enum SpeakerAutoNamer {

    /// Kept as a compatibility seam for processing callers. Confirmed aliases
    /// remain unchanged; the rename sheet exposes the calendar suggestions.
    static func applyingAliases(
        to transcript: Transcript,
        participants _: [CalendarParticipantIdentity]
    ) -> Transcript {
        transcript
    }
}
