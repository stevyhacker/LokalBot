import Foundation

/// Friendlier labels for LokalBot's placeholder speaker names. Stored keys,
/// aliases, owners, prompts, and exports keep the canonical names ("Me",
/// "Them 2"); "Local speaker" stays because that voice is not yet confirmed
/// as the user.
enum SpeakerDisplayName {
    static func label(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        switch trimmed.lowercased() {
        case "me": return "You"
        case "them": return "Other speaker"
        default:
            if let match = trimmed.wholeMatch(of: /[Tt]hem (\d+)/) { return "Speaker \(match.1)" }
            return name
        }
    }
}

/// Display-only names for a combined meeting. Source-scoped keys, confirmed
/// identities, and persisted aliases remain untouched for edits and evidence.
struct MeetingSpeakerPresentation {
    private var names: [String: String] = [:]
    private var replacements: [String: String] = [:]

    init(transcript: Transcript?) {
        guard let transcript else { return }
        let roster = transcript.speakerRoster
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
            names[Transcript.canonicalSpeakerKey(key)] ?? transcript.displaySpeaker(for: key))
    }

    /// An action owner as people should read it ("You", "Other speaker").
    func owner(_ value: String) -> String {
        SpeakerDisplayName.label(text(value))
    }

    func text(_ value: String) -> String {
        // Longest first protects nested merges and source 1 versus source 10.
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
