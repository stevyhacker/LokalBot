import Foundation

/// The model selects and paraphrases claims; the app resolves their speaker.
/// Source identity never comes from the model's prose or a display alias.
enum SummaryClaimEvidence {
    /// Safe to log or send as repair feedback: never contains model output,
    /// transcript text, speaker aliases, or other meeting content.
    struct ValidationError: LocalizedError, Equatable {
        enum Reason: String {
            case invalidJSON, tooManyClaims, unknownSource, sourceOutsidePart
            case speakerMismatch, invalidText, invalidQuote, quoteMismatch, invalidSection, staleTranscript

            var description: String {
                switch self {
                case .invalidJSON: "the model did not return the required claims JSON"
                case .tooManyClaims: "the model returned too many claims"
                case .unknownSource: "the cited transcript segment does not exist"
                case .sourceOutsidePart: "the citation refers to a segment outside the supplied evidence"
                case .speakerMismatch: "the speaker ID does not match the cited segment"
                case .invalidText: "the claim text is empty or too long"
                case .invalidQuote: "the supporting quote is empty or too long"
                case .quoteMismatch: "the quote does not exactly match words in the cited segment"
                case .invalidSection: "the section is not allowed by the selected notes template"
                case .staleTranscript: "the transcript changed while the summary was being generated"
                }
            }
        }

        var reason: Reason
        var claimNumber: Int?

        var errorDescription: String? {
            let subject = claimNumber.map { "Summary claim \($0)" } ?? "Summary"
            return "\(subject) did not pass its source-link check: \(reason.description)."
        }
    }

    struct Claim: Codable, Equatable {
        var section: String
        var text: String
        var speakerID: String
        var segmentID: String
        var quote: String

        enum CodingKeys: String, CodingKey {
            case section, text, quote
            case speakerID = "speaker_id"
            case segmentID = "source_segment_id"
        }
    }

    struct Envelope: Codable { var claims: [Claim] }
    struct Artifact: Codable {
        var version = 1
        var transcriptRevision: String
        var claims: [Claim]
    }
    private static let partialFileName = "summary.claims.partial.json"

    static func savePartial(_ claims: [Claim], transcript: Transcript, in folder: URL) throws {
        let artifact = Artifact(transcriptRevision: transcript.evidenceRevision, claims: claims)
        try JSONEncoder().encode(artifact).write(to: folder.appendingPathComponent(partialFileName), options: .atomic)
    }

    static func commit(transcript: Transcript, in folder: URL) throws {
        let temporary = folder.appendingPathComponent(partialFileName)
        let data = try Data(contentsOf: temporary)
        let artifact = try JSONDecoder().decode(Artifact.self, from: data)
        guard artifact.transcriptRevision == transcript.evidenceRevision else {
            throw ValidationError(reason: .staleTranscript)
        }
        try data.write(to: folder.appendingPathComponent("summary-claims.json"), options: .atomic)
        try? FileManager.default.removeItem(at: temporary)
    }

    static func decode(_ output: String, transcript: Transcript, allowedIDs: Set<String>? = nil,
                       template: NoteTemplate? = nil) throws -> [Claim] {
        let cleaned = ChatPrompt.extractJSONObject(output) ?? ""
        guard let data = cleaned.data(using: .utf8),
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else {
            throw ValidationError(reason: .invalidJSON)
        }
        guard envelope.claims.count <= 4_096 else { throw ValidationError(reason: .tooManyClaims) }
        let sources = transcript.segmentSourceMap
        let citationSources = transcript.summaryCitationSources
        var claims = envelope.claims
        for index in claims.indices {
            claims[index].segmentID = citationSources[claims[index].segmentID] ?? claims[index].segmentID
            let claim = claims[index]
            func failure(_ reason: ValidationError.Reason) -> ValidationError {
                ValidationError(reason: reason, claimNumber: index + 1)
            }
            guard let source = sources[claim.segmentID] else { throw failure(.unknownSource) }
            guard allowedIDs?.contains(claim.segmentID) != false else { throw failure(.sourceOutsidePart) }
            guard Transcript.canonicalSpeakerKey(source.speaker) == claim.speakerID else {
                throw failure(.speakerMismatch)
            }
            guard !normalized(claim.text).isEmpty, claim.text.count <= 1_400 else { throw failure(.invalidText) }
            guard !normalized(claim.quote).isEmpty, claim.quote.count <= 1_000 else { throw failure(.invalidQuote) }
            guard normalized(source.displayText).contains(normalized(claim.quote)) else { throw failure(.quoteMismatch) }
            guard validSection(claim.section, template: template) else { throw failure(.invalidSection) }
        }
        return claims
    }

    static func encode(_ claims: [Claim]) throws -> String {
        String(decoding: try JSONEncoder().encode(Envelope(claims: claims)), as: UTF8.self)
    }

    static func encodeForPrompt(_ claims: [Claim], transcript: Transcript) throws -> String {
        let citationIDs = Dictionary(uniqueKeysWithValues: transcript.summaryCitationSources.map { ($0.value, $0.key) })
        let compact = try claims.enumerated().map { index, claim in
            guard let citationID = citationIDs[claim.segmentID] else {
                throw ValidationError(reason: .unknownSource, claimNumber: index + 1)
            }
            var value = claim
            value.segmentID = citationID
            return value
        }
        return try encode(compact)
    }

    static func render(_ claims: [Claim], transcript: Transcript, template: NoteTemplate) -> String {
        let sources = transcript.segmentSourceMap
        let roster = transcript.speakerRoster
        var seen = Set<String>()
        let distinct = claims.filter { seen.insert("\($0.section)|\($0.segmentID)|\(normalized($0.text))").inserted }
        var seenSections = Set<String>()
        let headings = template == .freeform && !distinct.isEmpty
            ? distinct.map(\.section).filter { seenSections.insert($0).inserted } : sections(for: template)
        return headings.map { section in
            let lines = distinct.filter { $0.section == section }.compactMap { claim -> String? in
                guard let segment = sources[claim.segmentID], let person = roster[claim.speakerID] else { return nil }
                let suffix = person.identity == .unresolved ? " (identity unconfirmed)"
                    : person.identity == .other && person.name.caseInsensitiveCompare("Me") == .orderedSame ? " (other speaker)" : ""
                let name = person.identity == .user ? "You" : person.name
                // Every narrative claim remains explicitly reported speech.
                // First-person prose cannot silently become the reader's words.
                return "- **\(escaped(name + suffix)):** \(escaped(claim.text)) — [\(Transcript.stamp(segment.start))]"
            }
            return "## \(escaped(section))\n\n" + (lines.isEmpty ? "None" : lines.joined(separator: "\n"))
        }.joined(separator: "\n\n")
    }

    static func sections(for template: NoteTemplate) -> [String] {
        switch template {
        case .meeting: ["TL;DR", "Key points", "Decisions", "Open questions"]
        case .lecture: ["TL;DR", "Concepts", "Definitions", "Examples", "Questions to review"]
        case .studyGuide: ["TL;DR", "Key concepts", "Flashcards", "Practice questions"]
        case .podcast: ["TL;DR", "Topics", "Quotes", "Insights"]
        case .freeform: ["TL;DR", "Key points"]
        }
    }

    private static func validSection(_ section: String, template: NoteTemplate?) -> Bool {
        if template == .freeform {
            return !normalized(section).isEmpty && section.count <= 80
                && !section.contains(where: { $0.isNewline || $0 == "#" })
                && section.caseInsensitiveCompare("Action items") != .orderedSame
        }
        return template.map { sections(for: $0).contains(section) } ?? allSections.contains(section)
    }

    private static var allSections: Set<String> {
        Set(NoteTemplate.allCases.flatMap(sections))
    }
    private static func normalized(_ text: String) -> String {
        text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private static func escaped(_ text: String) -> String {
        normalized(text).replacingOccurrences(of: #"([\\`*_{}\[\]<>])"#, with: #"\$1"#, options: .regularExpression)
    }
}
