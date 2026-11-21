import Foundation

enum SpeakerDisplayName {
    static func label(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        switch trimmed.lowercased() {
        case "me": return name
        case "them": return "Other speaker"
        default:
            if let match = trimmed.wholeMatch(of: /[Tt]hem (\d+)/) { return "Speaker \(match.1)" }
            return name
        }
    }

    static func label(_ name: String, identity: SpeakerAttribution.Identity) -> String {
        if identity == .user, name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "me" {
            return "You"
        }
        return label(name)
    }
}

struct MeetingSpeakerPresentation {
    private var names: [String: String] = [:]
    private var replacements: [String: String] = [:]
    private var ownerIdentities: [String: SpeakerAttribution.Identity] = [:]
    private var identities: [String: SpeakerAttribution.Identity] = [:]
    private var colorIndices: [String: Int] = [:]

    init(transcript: Transcript?) {
        guard let transcript else { return }
        let roster = transcript.speakerRoster
        identities = roster.mapValues(\.identity)
        var nextColor = 1
        for segment in transcript.segments {
            let key = Transcript.canonicalSpeakerKey(segment.speaker)
            guard colorIndices[key] == nil else { continue }
            if roster[key]?.identity == .user {
                colorIndices[key] = 0
            } else {
                colorIndices[key] = nextColor
                nextColor += 1
            }
        }
        for group in Dictionary(grouping: roster.values, by: { $0.name.lowercased() }).values {
            if let only = group.first, group.count == 1 { ownerIdentities[only.name.lowercased()] = only.identity }
        }
        var nextSpeaker = 1
        for segment in transcript.segments {
            let key = Transcript.canonicalSpeakerKey(segment.speaker)
            guard names[key] == nil else { continue }
            let original = roster[key]?.name ?? Transcript.defaultSpeakerName(for: key)
            guard key.hasPrefix("source"), key.contains(":"),
                  original.range(of: #"(?: · source \d+)+$"#, options: .regularExpression) != nil else {
                names[key] = original
                continue
            }
            let clean = original.replacingOccurrences(
                of: #"(?: · source \d+)+$"#, with: "", options: .regularExpression)
            let isAnonymous = Transcript.isPlaceholderSpeakerName(clean)
            let name: String
            if isAnonymous {
                name = "Speaker \(nextSpeaker)"
                nextSpeaker += 1
            } else {
                name = clean
            }
            names[key] = name
            replacements[original] = name
        }
    }

    func speaker(_ key: String, in transcript: Transcript) -> String {
        SpeakerDisplayName.label(
            names[Transcript.canonicalSpeakerKey(key)] ?? transcript.displaySpeaker(for: key),
            identity: identities[Transcript.canonicalSpeakerKey(key)] ?? .unresolved)
    }

    func colorIndex(for key: String) -> Int {
        colorIndices[Transcript.canonicalSpeakerKey(key)] ?? 1
    }

    func owner(_ value: String, isForUser: Bool) -> String {
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let identity = isForUser ? SpeakerAttribution.Identity.user : ownerIdentities[key] ?? .unresolved
        return SpeakerDisplayName.label(text(value), identity: identity)
    }

    func text(_ value: String) -> String {
        replacements.keys.sorted { $0.count > $1.count }.reduce(value) { text, original in
            guard let replacement = replacements[original],
                  let regex = try? NSRegularExpression(pattern:
                    #"(?<![\p{L}\p{N}])"# + NSRegularExpression.escapedPattern(for: original)
                    + #"(?![\p{L}\p{N}])"#) else { return text }
            return regex.stringByReplacingMatches(
                in: text, range: NSRange(text.startIndex..., in: text),
                withTemplate: NSRegularExpression.escapedTemplate(for: replacement))
        }
    }
}
