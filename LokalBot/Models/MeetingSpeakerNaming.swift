import Foundation

/// One voice waiting for a name in the naming sheet.
struct MeetingSpeakerNamingVoice: Identifiable, Equatable {
    /// The transcript's canonical speaker key.
    let id: String
    let label: String
    let colorIndex: Int
    let sample: Transcript.Segment?
    let speechSeconds: TimeInterval
    let actionCount: Int
    /// A name this voice matched from earlier meetings. It is offered already
    /// picked, and still needs saving.
    var recognizedName: String?
}

/// A speaker who already has a name, listed so it can be changed.
struct MeetingSpeakerNamingKnown: Identifiable, Equatable {
    let id: String
    let name: String
    let colorIndex: Int
    /// Named by voice recognition, not by the person reading the meeting.
    let wasRecognized: Bool
}

/// A name to save for one voice.
struct MeetingSpeakerNamingChoice: Equatable {
    let speaker: String
    let name: String
    var calendarIdentityID: String?
}

enum MeetingSpeakerNaming {
    /// Voices to name, those with actions first, and the speakers already
    /// named. The user's own voice is in neither list.
    static func lists(
        speakers: [MeetingDetailPresentation.Speaker],
        reviewItems: [MeetingSpeakerReviewItem],
        speechSeconds: [String: TimeInterval],
        recognized: [String: String] = [:],
        recognizedSpeakers: Set<String> = []
    ) -> (voices: [MeetingSpeakerNamingVoice], known: [MeetingSpeakerNamingKnown]) {
        let byID = Dictionary(speakers.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let voices = reviewItems.compactMap { item -> MeetingSpeakerNamingVoice? in
            guard let speaker = byID[item.id], speaker.needsName else { return nil }
            return MeetingSpeakerNamingVoice(
                id: item.id, label: speaker.name, colorIndex: speaker.colorIndex, sample: item.sample,
                speechSeconds: speechSeconds[item.id] ?? 0, actionCount: item.actionCount,
                recognizedName: recognized[item.id])
        }
        let known = speakers.filter { !$0.needsName && !$0.isUser }.map {
            MeetingSpeakerNamingKnown(id: $0.id, name: $0.name, colorIndex: $0.colorIndex,
                                      wasRecognized: recognizedSpeakers.contains($0.id))
        }
        return (voices, known)
    }
}

/// What has been picked in the naming sheet before it is saved. One person is
/// one voice: picking a name for a second voice takes it from the first.
struct MeetingSpeakerNamingDraft: Equatable {
    struct Pick: Equatable {
        /// Identifies the chip: an invited guest, a suggested name, or the
        /// recognized name.
        var id: String
        var name: String
        var calendarIdentityID: String?
    }

    private(set) var picks: [String: Pick] = [:]
    private(set) var typing: Set<String> = []
    var typedNames: [String: String] = [:]

    init(voices: [MeetingSpeakerNamingVoice] = [], suggestions: [MeetingSpeakerSuggestion] = []) {
        for voice in voices {
            guard let name = voice.recognizedName else { continue }
            let pick = Self.recognizedPick(name, for: voice.id, among: suggestions)
            // Two voices cannot both start as the same guest.
            if !picks.values.contains(where: { $0.id == pick.id }) { picks[voice.id] = pick }
        }
    }

    /// The pick for a name recognized by voice. When that name is one of the
    /// suggestions (an invited guest), it is that suggestion's pick, so the
    /// guest's calendar identity is kept.
    static func recognizedPick(_ name: String, for speaker: String,
                               among suggestions: [MeetingSpeakerSuggestion] = []) -> Pick {
        let key = MeetingSpeakerSuggestion.nameKey(name)
        if let match = suggestions.first(where: { $0.name.map(MeetingSpeakerSuggestion.nameKey) == key }) {
            return Pick(id: match.id, name: match.name ?? name, calendarIdentityID: match.calendar?.id)
        }
        return Pick(id: "recognized:\(speaker)", name: name)
    }

    func isPicked(_ id: String, for speaker: String) -> Bool { picks[speaker]?.id == id }
    func isTyping(for speaker: String) -> Bool { typing.contains(speaker) }

    /// Another voice in this sheet already has that name.
    func isTakenElsewhere(_ id: String, for speaker: String) -> Bool {
        picks.contains { $0.key != speaker && $0.value.id == id }
    }

    /// Picks a name for a voice; picking the same name again clears it.
    mutating func toggle(_ pick: Pick, for speaker: String) {
        typing.remove(speaker)
        if picks[speaker]?.id == pick.id {
            picks[speaker] = nil
            return
        }
        for (other, existing) in picks where other != speaker && existing.id == pick.id { picks[other] = nil }
        picks[speaker] = pick
    }

    /// Switches a voice to a typed name ("Someone else…").
    mutating func typeName(for speaker: String) {
        if typing.contains(speaker) {
            typing.remove(speaker)
        } else {
            typing.insert(speaker)
            picks[speaker] = nil
        }
    }

    /// The names to save, in the sheet's order. Voices left alone are skipped.
    func choices(for speakers: [String]) -> [MeetingSpeakerNamingChoice] {
        speakers.compactMap { speaker in
            if typing.contains(speaker) {
                let name = (typedNames[speaker] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                return name.isEmpty ? nil : MeetingSpeakerNamingChoice(speaker: speaker, name: name)
            }
            guard let pick = picks[speaker] else { return nil }
            return MeetingSpeakerNamingChoice(speaker: speaker, name: pick.name,
                                              calendarIdentityID: pick.calendarIdentityID)
        }
    }
}
