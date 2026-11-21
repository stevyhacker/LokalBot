import Foundation

enum DreamBriefPresentation {
    static let linkScheme = "lokalbot-dream"

    static func markdown(_ text: String, meetings: [Meeting]) -> String {
        let source = naturalOwnership(text)
        let pattern = #"`([0-9a-fA-F]{8}|[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})`"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return source }
        var result = source
        for match in regex.matches(in: source, range: NSRange(source.startIndex..., in: source)).reversed() {
            guard let range = Range(match.range, in: result),
                  let idRange = Range(match.range(at: 1), in: result) else { continue }
            let id = String(result[idRange]).lowercased()
            let candidates = meetings.filter {
                $0.id.uuidString.lowercased() == id || SessionLookup.shortID($0.id) == id
            }
            guard candidates.count == 1, let meeting = candidates.first else {
                result.replaceSubrange(range, with: candidates.isEmpty
                    ? "Unavailable meeting" : "Ambiguous meeting reference")
                continue
            }
            let title = meeting.displayTitle
            var replacementRange = range
            let prefix = String(result[..<range.lowerBound])
            let trimmed = prefix.trimmingCharacters(in: .whitespaces)
            if trimmed.lowercased().hasSuffix(title.lowercased()),
               let titleRange = prefix.range(of: title, options: [.backwards, .caseInsensitive]),
               prefix[titleRange.upperBound...].allSatisfy(\.isWhitespace),
               titleRange.lowerBound == prefix.startIndex
                    || prefix[prefix.index(before: titleRange.lowerBound)].isWhitespace {
                replacementRange = titleRange.lowerBound..<range.upperBound
            }
            let url = "\(linkScheme)://meeting/\(meeting.id.uuidString.lowercased())"
            result.replaceSubrange(replacementRange, with: "[\(escapedLabel(title))](\(url))")
        }
        return result
    }

    static func meetingID(for url: URL, meetings: [Meeting]) -> UUID? {
        guard url.scheme == linkScheme, url.host == "meeting",
              url.query == nil, url.fragment == nil,
              let id = UUID(uuidString: String(url.path.dropFirst())),
              meetings.contains(where: { $0.id == id }) else { return nil }
        return id
    }

    private static func escapedLabel(_ text: String) -> String {
        text.reduce(into: "") { result, character in
            if "\\`*_{}[]<>()!".contains(character) { result.append("\\") }
            result.append(character)
        }
    }

    private static func naturalOwnership(_ text: String) -> String {
        text.replacingOccurrences(
            of: #"(?i)`?\bowner:\s*me\b`?\s+(actions|tasks|commitments|items)\b"#,
            with: "$1 assigned to you", options: .regularExpression)
            .replacingOccurrences(
                of: #"(?i)`?\bowner:\s*me\b`?"#,
                with: "assigned to you", options: .regularExpression)
    }
}
