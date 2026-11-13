import Foundation

/// A local review projection, never an identity guess or an inference input.
struct MeetingSpeakerReviewItem: Identifiable {
    let id: String
    let name: String
    let isNamed: Bool
    let isUser: Bool
    let canConfirm: Bool
    let sample: Transcript.Segment?
    var actionCount = 0

    var status: String {
        if isUser { return "Attributed to you" }
        if !canConfirm { return "Mixed or unresolved audio" }
        return isNamed ? "Named in this meeting" : "Name not confirmed"
    }

    static func ownerSuggestions(from speakers: [Self]) -> [String] {
        var seen = Set<String>()
        return speakers.filter { $0.isNamed && !$0.isUser }.map(\.name).filter {
            seen.insert($0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)).inserted
        }
    }

    static func bestSample(in segments: [Transcript.Segment]) -> Transcript.Segment? {
        let eligible = segments.filter {
            $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end > $0.start
                && RecallPassage.isUseful($0.text)
        }
        return eligible.max {
            let left = sampleScore($0), right = sampleScore($1)
            return left == right ? $0.start > $1.start : left < right
        }
    }

    private static func sampleScore(_ segment: Transcript.Segment) -> Double {
        let words = segment.text.split(whereSeparator: { $0.isWhitespace })
        // Prefer enough speech to recognize a voice, without rewarding long monologues.
        return Double(min(words.count, 25)) + min(segment.end - segment.start, 12)
    }

    static func prioritized(_ speakers: [Self], actions: [MeetingOutcomes.ActionItem]) -> [Self] {
        let order = Dictionary(uniqueKeysWithValues: speakers.enumerated().map { ($0.element.id, $0.offset) })
        return speakers.map { speaker in
            var item = speaker
            item.actionCount = actions.filter { action in
                action.owner.map { Transcript.canonicalSpeakerKey($0) == speaker.id || $0 == speaker.name } == true
                    || action.citations.contains { Transcript.canonicalSpeakerKey($0.speaker) == speaker.id }
            }.count
            return item
        }.sorted {
            if ($0.actionCount > 0) != ($1.actionCount > 0) { return $0.actionCount > 0 }
            if $0.actionCount != $1.actionCount { return $0.actionCount > $1.actionCount }
            return order[$0.id, default: 0] < order[$1.id, default: 0]
        }
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
                sample: bestSample(in: valid))
        }
    }
}
