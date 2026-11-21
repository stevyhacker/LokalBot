import Foundation

struct MeetingSpeakerNamingVoice: Identifiable, Equatable {
    let id: String
    let label: String
    let colorIndex: Int
    let sample: Transcript.Segment?
    let speechSeconds: TimeInterval
    let actionCount: Int
    var recognizedName: String?
}

struct MeetingSpeakerNamingKnown: Identifiable, Equatable {
    let id: String
    let name: String
    let colorIndex: Int
    let wasRecognized: Bool
}

struct MeetingSpeakerNamingChoice: Equatable {
    let speaker: String
    let name: String
    var calendarIdentityID: String?
}

enum MeetingSpeakerNaming {
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

struct MeetingSpeakerNamingDraft: Equatable {
    struct Pick: Equatable {
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
            if !picks.values.contains(where: { $0.id == pick.id }) { picks[voice.id] = pick }
        }
    }

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

    func isTakenElsewhere(_ id: String, for speaker: String) -> Bool {
        picks.contains { $0.key != speaker && $0.value.id == id }
    }

    mutating func toggle(_ pick: Pick, for speaker: String) {
        typing.remove(speaker)
        if picks[speaker]?.id == pick.id {
            picks[speaker] = nil
            return
        }
        for (other, existing) in picks where other != speaker && existing.id == pick.id { picks[other] = nil }
        picks[speaker] = pick
    }

    mutating func typeName(for speaker: String) {
        if typing.contains(speaker) {
            typing.remove(speaker)
        } else {
            typing.insert(speaker)
            picks[speaker] = nil
        }
    }

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
