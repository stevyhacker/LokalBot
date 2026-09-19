import Foundation

/// Display-only names for a combined meeting. Source-scoped keys, confirmed
/// identities, and persisted aliases remain untouched for edits and evidence.
struct MeetingSpeakerPresentation {
    private var names: [String: String] = [:]
    private var replacements: [String: String] = [:]

    init(transcript: Transcript?) {
        guard let transcript else { return }
        var nextSpeaker = 1
        for segment in transcript.segments {
            let key = Transcript.canonicalSpeakerKey(segment.speaker)
            guard names[key] == nil else { continue }
            let original = transcript.displaySpeaker(for: key)
            guard key.hasPrefix("source"), key.contains(":"),
                  original.range(of: #"(?: · source \d+)+$"#, options: .regularExpression) != nil else {
                names[key] = original
                continue
            }
            let clean = original.replacingOccurrences(
                of: #"(?: · source \d+)+$"#, with: "", options: .regularExpression)
            let isAnonymous = clean.range(
                of: #"^(?:Them(?: \d+)?|Speaker(?: \d+| unclear)?|Local speaker)$"#,
                options: [.regularExpression, .caseInsensitive]) != nil
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
        names[Transcript.canonicalSpeakerKey(key)] ?? transcript.displaySpeaker(for: key)
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
