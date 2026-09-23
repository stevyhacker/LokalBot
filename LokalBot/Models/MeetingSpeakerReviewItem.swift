import Foundation

/// A local review projection, never an identity guess or an inference input.
struct MeetingSpeakerReviewItem: Identifiable {
    let id: String
    let name: String
    let isNamed: Bool
    let isUser: Bool
    let canConfirm: Bool
    let sample: Transcript.Segment?

    var status: String {
        if isUser { return "Attributed to you" }
        if !canConfirm { return "Mixed or unresolved audio" }
        return isNamed ? "Named in this meeting" : "Name not confirmed"
    }

    static func ownerSuggestions(from speakers: [Self]) -> [String] {
        speakers.filter { $0.isNamed && !$0.isUser }.map(\.name)
    }

    static func items(in transcript: Transcript?) -> [Self] {
        guard let transcript else { return [] }
        let roster = transcript.speakerRoster
        let presentation = MeetingSpeakerPresentation(transcript: transcript)
        let groups = Dictionary(grouping: transcript.segments) {
            Transcript.canonicalSpeakerKey($0.speaker)
        }
        var seen = Set<String>()
        return transcript.segments.compactMap { segment in
            let key = Transcript.canonicalSpeakerKey(segment.speaker)
            guard seen.insert(key).inserted else { return nil }
            let valid = (groups[key] ?? []).filter {
                $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end > $0.start
            }
            let name = presentation.speaker(key, in: transcript)
            let anonymous = Transcript.isPlaceholderSpeakerName(name)
            return Self(
                id: key,
                name: name,
                isNamed: transcript.speakerAliases[key]?.isEmpty == false && !anonymous,
                isUser: roster[key]?.identity == .user,
                canConfirm: Transcript.canConfirmIdentity(in: groups[key] ?? []),
                sample: valid.first { $0.end - $0.start >= 3 } ?? valid.first)
        }
    }
}
