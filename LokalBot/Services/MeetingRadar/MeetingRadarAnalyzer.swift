import Foundation

/// The request and the checks for one Live Radar pass. Pure, so the prompt,
/// schema, and grounding rules are covered without a model or network.
///
/// A pass sends the lines that arrived since the previous pass, a little of
/// the conversation before them, what is already on the radar, and passages
/// from earlier meetings that local search found for the new lines. Whatever
/// comes back must quote one of the new lines; a contradiction must also name
/// a passage it was shown. Anything else is dropped, never shown.
enum MeetingRadarAnalyzer {
    struct Line: Equatable, Sendable {
        /// "L12": stable for the whole recording.
        let label: String
        let time: TimeInterval
        /// The live track: "local" (this Mac's microphone) or "them".
        let speaker: String
        let text: String

        var speakerName: String { speaker == "local" || speaker == "me" ? "Me" : "Others" }
    }

    struct Excerpt: Equatable, Sendable {
        /// "E1": numbered per pass.
        let label: String
        let evidence: RadarEvidence
    }

    struct Request: Equatable, Sendable {
        var meetingID: UUID
        var meetingTitle: String
        var meetingDate: Date
        var attendees: [String] = []
        var existing: [RadarItem] = []
        var earlierLines: [Line] = []
        var newLines: [Line]
        var excerpts: [Excerpt] = []
    }

    struct Outcome: Equatable, Sendable {
        var added: [RadarItem] = []
        var answeredIDs: [String] = []
        var rejected = 0
    }

    static let maximumItemsPerPass = 6
    static let maximumTextWords = 24

    static let system = """
    You watch a meeting while it happens, for the person using LokalBot, called "Me". The lines come \
    from live speech recognition, so expect small recognition errors. "Me" lines are the person's own \
    microphone. "Others" lines are everyone on the call audio, possibly several people; use a name only \
    when the meeting says it.

    Report only what the NEW LINES add:
    - commitment: someone promises or accepts a concrete next step ("I'll send the deck", "Ana will check \
    pricing"). owner: "Me", a name said in the meeting, or "Others". due: the deadline exactly as said, \
    or "".
    - decision: the group settles something.
    - question: a real question that is still open. Skip rhetorical and already answered questions.
    - contradiction: a new line conflicts with an EARLIER MEETINGS passage (a different date, number, \
    owner, or decision) or with an earlier line of this meeting. Put that passage's id (E1, E2, …) or \
    line id (L3, …) in evidence and say what changed in text. Agreement or a related topic is not a \
    contradiction.

    Rules:
    - line: the id of the new line the item comes from. quote: at least three words copied exactly from \
    that line.
    - Never repeat an item that is ALREADY ON THE RADAR. If a new line answers an open question there, \
    put its id (r1, …) in answered.
    - Skip greetings, small talk, filler, and anything you would have to guess.
    - text: one short sentence of at most 20 words, in the language the meeting is held in. For a \
    commitment, write only the task, as an instruction without its owner or deadline ("Book the venue \
    for the offsite", not "Me will book the venue by Monday"); owner and due carry the rest. Write a \
    question as the question itself ("What was trial-to-paid conversion last month?").
    - evidence is "" for everything except contradictions.
    - Most passes add nothing. Then return {"items": [], "answered": []}.
    """

    static var schema: [String: Any] {
        let string: [String: Any] = ["type": "string"]
        let item: [String: Any] = [
            "type": "object",
            "additionalProperties": false,
            "required": ["kind", "text", "owner", "due", "line", "quote", "evidence"],
            "properties": [
                "kind": ["type": "string", "enum": RadarItem.Kind.allCases.map(\.rawValue)],
                "text": string, "owner": string, "due": string,
                "line": string, "quote": string, "evidence": string,
            ],
        ]
        return [
            "type": "object",
            "additionalProperties": false,
            "required": ["items", "answered"],
            "properties": [
                "items": ["type": "array", "items": item],
                "answered": ["type": "array", "items": string],
            ],
        ]
    }

    static func prompt(_ request: Request) -> String {
        var sections: [String] = []
        var meeting = "MEETING: \(request.meetingTitle) · \(dateLabel(request.meetingDate))"
        if !request.attendees.isEmpty { meeting += " · invited: \(request.attendees.joined(separator: ", "))" }
        sections.append(meeting)

        let open = request.existing.filter { !$0.answered }
        sections.append("ALREADY ON THE RADAR:\n" + (open.isEmpty ? "(nothing yet)" : open.map { item in
            var details: [String] = []
            if let owner = item.owner { details.append(owner) }
            if let due = item.due { details.append(due) }
            let suffix = details.isEmpty ? "" : " (\(details.joined(separator: ", ")))"
            return "\(item.id) \(item.kind.rawValue)\(suffix): \(item.text)"
        }.joined(separator: "\n")))

        if !request.excerpts.isEmpty {
            sections.append("EARLIER MEETINGS (from the person's own library; often unrelated):\n"
                + request.excerpts.map { excerpt in
                    let evidence = excerpt.evidence
                    let stamp = evidence.time.map { " · \(timestamp($0))" } ?? ""
                    let who = evidence.speaker.map { " · \($0)" } ?? ""
                    return "\(excerpt.label) · \(evidence.meetingTitle) · \(dateLabel(evidence.meetingDate))"
                        + "\(stamp)\(who): \"\(evidence.text)\""
                }.joined(separator: "\n"))
        }
        if !request.earlierLines.isEmpty {
            sections.append("EARLIER IN THIS MEETING:\n" + request.earlierLines.map(render).joined(separator: "\n"))
        }
        sections.append("NEW LINES:\n" + request.newLines.map(render).joined(separator: "\n"))
        return sections.joined(separator: "\n\n")
    }

    /// Parses a reply and keeps only grounded, new items. `nextID` numbers the
    /// kept items r1, r2, … across the whole recording.
    static func apply(reply: String, to request: Request, nextID: inout Int,
                      model: String, now: Date = Date()) -> Outcome {
        guard let data = reply.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return Outcome(rejected: 1)
        }
        var outcome = Outcome()
        let openQuestions = Set(request.existing.filter { $0.kind == .question && !$0.answered }.map(\.id))
        outcome.answeredIDs = (object["answered"] as? [String] ?? []).filter { openQuestions.contains($0) }

        var kept = request.existing
        for raw in object["items"] as? [[String: Any]] ?? [] {
            guard outcome.added.count < maximumItemsPerPass,
                  let kind = (raw["kind"] as? String).flatMap(RadarItem.Kind.init(rawValue:)),
                  let text = clean(raw["text"]), !text.isEmpty,
                  let quote = clean(raw["quote"]), !quote.isEmpty,
                  let line = sourceLine(label: clean(raw["line"]), quote: quote, in: request.newLines) else {
                outcome.rejected += 1
                continue
            }
            var earlier: RadarEvidence?
            if kind == .contradiction {
                guard let found = evidence(clean(raw["evidence"]) ?? "", in: request) else {
                    outcome.rejected += 1
                    continue
                }
                earlier = found
            }
            nextID += 1
            let item = RadarItem(
                id: "r\(nextID)", kind: kind, text: shortened(text),
                owner: owner(clean(raw["owner"]), kind: kind), due: nonEmpty(clean(raw["due"])),
                quote: quote, time: line.time, speaker: line.speaker, earlier: earlier,
                foundAt: now, model: model)
            if isDuplicate(item, of: kept) {
                nextID -= 1
                outcome.rejected += 1
                continue
            }
            kept.append(item)
            outcome.added.append(item)
        }
        return outcome
    }

    // MARK: - Grounding

    /// The line an item quotes: the one it names, when the quote is really
    /// in it, else the only new line that contains the quote.
    static func sourceLine(label: String?, quote: String, in lines: [Line]) -> Line? {
        if let label, let named = lines.first(where: { $0.label == label }),
           quoteMatches(quote, line: named.text) {
            return named
        }
        let matches = lines.filter { quoteMatches(quote, line: $0.text) }
        return matches.count == 1 ? matches[0] : nil
    }

    /// Exact after normalization, or at least 80% of the quote's words in the
    /// line, so punctuation and a dropped filler word don't reject a real
    /// quote. A quote under three words only counts when it is the whole line.
    static func quoteMatches(_ quote: String, line: String) -> Bool {
        let quoteText = normalized(quote)
        let lineText = normalized(line)
        guard !quoteText.isEmpty else { return false }
        let quoteWords = quoteText.split(separator: " ")
        if quoteWords.count < 3 { return quoteText == lineText }
        if (" " + lineText + " ").contains(" " + quoteText + " ") { return true }
        let lineWords = Set(lineText.split(separator: " "))
        let found = quoteWords.filter { lineWords.contains($0) }.count
        return Double(found) / Double(quoteWords.count) >= 0.8
    }

    static func evidence(_ label: String, in request: Request) -> RadarEvidence? {
        let label = label.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if let excerpt = request.excerpts.first(where: { $0.label == label }) { return excerpt.evidence }
        guard let line = request.earlierLines.first(where: { $0.label == label }) else { return nil }
        return RadarEvidence(meetingID: request.meetingID, meetingTitle: request.meetingTitle,
                             meetingDate: request.meetingDate, time: line.time,
                             speaker: line.speakerName, text: line.text, isCurrentMeeting: true)
    }

    /// Same kind and the same quote, or mostly the same words.
    static func isDuplicate(_ item: RadarItem, of existing: [RadarItem]) -> Bool {
        let quote = normalized(item.quote)
        let words = Set(normalized(item.text).split(separator: " "))
        return existing.contains { other in
            guard other.kind == item.kind else { return false }
            if normalized(other.quote) == quote { return true }
            let otherWords = Set(normalized(other.text).split(separator: " "))
            let union = words.union(otherWords).count
            return union > 0 && Double(words.intersection(otherWords).count) / Double(union) >= 0.6
        }
    }

    static func normalized(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        let scalars = folded.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
        return String(scalars).split(separator: " ").joined(separator: " ")
    }

    // MARK: - Formatting

    static func render(_ line: Line) -> String {
        "[\(line.label) \(timestamp(line.time))] \(line.speakerName): \(line.text)"
    }

    static func timestamp(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return total >= 3_600
            ? String(format: "%d:%02d:%02d", total / 3_600, total / 60 % 60, total % 60)
            : String(format: "%02d:%02d", total / 60, total % 60)
    }

    private static func dateLabel(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).year())
    }

    private static func clean(_ value: Any?) -> String? {
        (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    private static func owner(_ value: String?, kind: RadarItem.Kind) -> String? {
        guard kind == .commitment, let value = nonEmpty(value) else { return nil }
        switch value.lowercased() {
        case "me", "i", "myself": return "Me"
        case "others", "other", "them", "unknown", "someone": return "Others"
        default: return value
        }
    }

    private static func shortened(_ text: String) -> String {
        let words = text.split(separator: " ")
        guard words.count > maximumTextWords else { return text }
        return words.prefix(maximumTextWords).joined(separator: " ") + "…"
    }
}
