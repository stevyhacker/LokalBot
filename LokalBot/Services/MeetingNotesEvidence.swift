import Foundation

/// Shared compact evidence for narrative facts and actionable outcomes. Model
/// IDs are local to this immutable snapshot; durable artifacts use stable IDs.
struct MeetingNotesEvidence {
    static let ownershipPolicyVersion = "action-evidence-v4"

    struct Unit: Codable, Equatable {
        var source: String
        var speaker: String
        var text: String
        var isUserCommitment = false
        var line: String { "\(source)|\(speaker)|\(text)" }
    }

    struct Rejection: Codable, Equatable {
        var sources: [String]
        var kind: String
        var reason: String
        var text: String?
        /// Identifies an unresolved action that must be replaced, not appended
        /// to, if a targeted ownership repair succeeds.
        var actionID: String?
    }

    /// Compact, source-bound ledger for paging. Text is data, never a new
    /// instruction or a substitute for the original evidence on the next page.
    struct Record: Codable, Equatable {
        var kind: String
        var source: String
        var text: String

        var key: String { "\(kind)|\(source)|\(OutcomeTextSimilarity.normalized(text))" }
    }

    struct Validated {
        var claims: [SummaryClaimEvidence.Claim] = []
        var outcomes = MeetingOutcomes()
        var rejected: [Rejection] = []
        var complete = false
        var hasMore: Bool?
        var records: [Record] = []
    }

    let transcript: Transcript
    let units: [Unit]
    let speakers: [String: Transcript.SpeakerDescriptor]
    let roster: String
    /// English-only wording checks may veto a task only when the meeting is
    /// mostly English.
    let isEnglishMeeting: Bool

    init(transcript: Transcript) {
        // Likely echo repeats a remote participant; the remote segment carries
        // those words, so the echo is never shown or cited as evidence.
        let transcript = transcript.markingSuspectedEcho()
        self.transcript = transcript
        // Sampled across the meeting: a foreign-language opening, or noise
        // transcribed as one, must not decide the language of the rest.
        let isEnglish = SummaryLanguage.isMostlyEnglish(transcript)
        isEnglishMeeting = isEnglish
        let roster = transcript.speakerRoster
        let entries = roster.keys.sorted().enumerated().map { index, key in ("p\(index + 1)", roster[key]!) }
        speakers = Dictionary(uniqueKeysWithValues: entries)
        let compactIDs = Dictionary(uniqueKeysWithValues: entries.map { ($0.1.id, $0.0) })
        let values = entries.map { key, person in
            ["id": key, "speaker_id": person.id, "name": person.name, "identity": person.identity.rawValue]
        }
        self.roster = String(decoding: (try? JSONSerialization.data(withJSONObject: values, options: [.sortedKeys])) ?? Data(), as: UTF8.self)
        let sources = transcript.segmentSourceMap
        var units = transcript.summaryPromptTurns(maxCharacters: 1_000).compactMap { turn -> Unit? in
            guard sources[turn.sourceID]?.resolvedAttribution.method != .suspectedEcho else { return nil }
            return Unit(source: turn.citationID, speaker: compactIDs[Transcript.canonicalSpeakerKey(turn.speaker)]!, text: turn.text)
        }
        // The user's own undertakings are listed for the model and re-read
        // once when no task cites them.
        let texts = Dictionary(grouping: units, by: \.source).mapValues { $0.map(\.text).joined(separator: " ") }
        let indices = Dictionary(uniqueKeysWithValues: transcript.segments.indices.map { (transcript.summaryCitationID(at: $0), $0) })
        let ownership = ActionOwnership(transcript: transcript, roster: roster, isEnglish: isEnglish,
                                        text: { texts[transcript.summaryCitationID(at: $0)] })
        var flagged = Set<String>()
        for index in units.indices where flagged.insert(units[index].source).inserted {
            guard let row = indices[units[index].source],
                  roster[Transcript.canonicalSpeakerKey(transcript.segments[row].speaker)]?.identity == .user else { continue }
            units[index].isUserCommitment = ownership.statesCommitment(at: row)
                || OutcomeEvidencePolicy.isBareAcceptance(texts[units[index].source] ?? "")
        }
        self.units = units
    }

    static func sections(_ template: NoteTemplate) -> [String] {
        var sections = SummaryClaimEvidence.sections(for: template)
        for name in ["Decisions", "Open questions"] where !sections.contains(name) { sections.append(name) }
        return sections
    }

    /// Every enum value in a schema, counted the way hosted servers limit
    /// them: once per occurrence.
    static func enumValueCount(in schema: Any) -> Int {
        if let object = schema as? [String: Any] {
            return (object["enum"] as? [Any])?.count ?? 0
                + object.filter { $0.key != "enum" }.values.reduce(0) { $0 + enumValueCount(in: $1) }
        }
        if let array = schema as? [Any] { return array.reduce(0) { $0 + enumValueCount(in: $1) } }
        return 0
    }

    static func schema(units: [Unit], speakers: [String], template: NoteTemplate,
                       maximumNotes: Int, maximumActions: Int, actionTexts: [String]? = nil) -> [String: Any] {
        let source: [String: Any] = ["type": "string", "enum": Array(Set(units.map(\.source))).sorted()]
        let text: [String: Any] = ["type": "string", "minLength": 1, "maxLength": 280]
        func object(_ properties: [String: Any]) -> [String: Any] {
            ["type": "object", "additionalProperties": false,
             "required": properties.keys.sorted(), "properties": properties]
        }
        return object([
            "notes": ["type": "array", "maxItems": maximumNotes, "items": object([
                "section": template == .freeform
                    ? ["type": "string", "minLength": 1, "maxLength": 80]
                    : ["type": "string", "enum": sections(template)],
                "text": text, "source": source,
            ])],
            "actions": ["type": "array", "maxItems": maximumActions, "items": object([
                "text": actionTexts.map { ["type": "string", "enum": Array(Set($0)).sorted()] } ?? text, "source": source,
                "context": ["type": "array", "maxItems": 2, "items": source],
                "owner": ["type": "string", "enum": ["source", "unknown"] + speakers.sorted()],
                "basis": ["type": "string", "enum": ["commitment", "assignment", "request", "unclear"]],
                "quote": ["type": "string", "maxLength": 1_000],
                "due": ["type": "string", "maxLength": 80],
                "importance": ["type": "integer", "enum": [1, 2, 3, 4, 5]],
            ])],
            "has_more": ["type": "boolean"],
        ])
    }

    /// Decisions a speaker stated outright that no finished part listed, as
    /// source-linked notes. Run once the whole meeting is scanned: a page or
    /// repair still in progress may yet list them.
    func statedDecisions(after claims: [SummaryClaimEvidence.Claim], template: NoteTemplate,
                         meetingID: UUID) -> Validated? {
        guard template == .meeting, isEnglishMeeting else { return nil }
        let listed = claims.filter { $0.section == "Decisions" }
        let citedSegments = Set(listed.map(\.segmentID))
        let citations = transcript.summaryCitationSources
        let rows = Dictionary(grouping: units, by: \.source)
            .filter { source, _ in citations[source].map { !citedSegments.contains($0) } ?? false }
            .mapValues { $0.map(\.text).joined(separator: " ") }
        let notes = ExplicitDecisions.missing(listedTexts: listed.map(\.text), in: rows)
        guard !notes.isEmpty, let data = try? JSONSerialization.data(withJSONObject: [
            "notes": notes, "actions": [[String: Any]](), "has_more": false,
        ] as [String: Any]) else { return nil }
        return validate(String(decoding: data, as: UTF8.self), units: units, template: template,
                        meetingID: meetingID, maximumNotes: notes.count, maximumActions: 0)
    }

    func validate(_ output: String, units: [Unit], template: NoteTemplate,
                  meetingID: UUID, maximumNotes: Int, maximumActions: Int) -> Validated {
        let parsed = CompleteJSONRecords.parse(output, keys: ["notes", "actions"])
        var result = Validated(complete: parsed.complete && parsed.malformedRecords == 0)
        let object = ChatPrompt.extractJSONObject(output).flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        // A bounded array must not silently represent a scan that had more work.
        result.hasMore = object?["has_more"] as? Bool
        if result.hasMore != false { result.complete = false }
        let notes = parsed.arrays["notes"] ?? []
        let actions = parsed.arrays["actions"] ?? []
        if notes.count > maximumNotes || actions.count > maximumActions { result.complete = false }
        let visible = Dictionary(grouping: units, by: \.source)
        let sources = transcript.segmentSourceMap
        let citationIDs = transcript.summaryCitationSources
        let roster = transcript.speakerRoster

        func evidence(_ item: [String: Any]) -> (String, Transcript.Segment, String)? {
            guard let id = item["source"] as? String, let parts = visible[id],
                  let stable = citationIDs[id], let segment = sources[stable] else { return nil }
            return (stable, segment, parts.map(\.text).joined(separator: " "))
        }
        func text(_ item: [String: Any], expectedSpeaker: String? = nil) -> String? {
            guard let value = item["text"] as? String,
                  !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  value.count <= 280 else { return nil }
            return prose(value, expectedSpeaker: expectedSpeaker)
        }
        func reject(_ item: [String: Any], _ reason: String, kind: String = "notes") {
            // The primary source anchors repair. Rejected model-selected
            // context may be the very reason an unrelated task was inferred.
            // Rebuild its neighborhood from the transcript instead of feeding
            // those untrusted context references back into the repair.
            let ids = (item["source"] as? String).map { [$0] } ?? []
            result.rejected.append(Rejection(sources: ids, kind: kind, reason: reason,
                text: kind == "actions" ? (item["text"] as? String).map { String($0.prefix(280)) } : nil))
        }
        func citation(_ id: String, _ segment: Transcript.Segment, _ visible: String) -> OutcomeSourceCitation {
            .init(meetingID: meetingID, segmentID: id, start: segment.start, end: segment.end,
                  speaker: segment.speaker, excerpt: String(visible.prefix(600)))
        }

        for item in notes.prefix(maximumNotes) {
            guard let (id, segment, visible) = evidence(item) else { reject(item, "unknown_source"); continue }
            guard let text = text(item, expectedSpeaker: units.first { $0.source == item["source"] as? String }?.speaker),
                  let section = item["section"] as? String,
                  validSection(section, template: template) else { reject(item, "invalid_note"); continue }
            if text.range(of: #"^none(?: explicitly)?(?: (?:settled|recorded|identified|mentioned|made))?(?: in (?:this|the) (?:segment|part|meeting))?[.!]?$"#,
                          options: [.regularExpression, .caseInsensitive]) != nil {
                reject(item, "empty_outcome"); continue
            }
            let speaker = Transcript.canonicalSpeakerKey(segment.speaker)
            guard let person = transcript.speakerRoster[speaker] else { reject(item, "unknown_speaker"); continue }
            let quote = String(visible.prefix(600))
            let claim = SummaryClaimEvidence.Claim(section: section, text: text, speakerID: speaker, segmentID: id, quote: quote)
            result.records.append(.init(kind: "notes", source: item["source"] as? String ?? "", text: text))
            if template == .freeform || SummaryClaimEvidence.sections(for: template).contains(section) { result.claims.append(claim) }
            let label = person.identity == .user ? "You" : person.name
            let suffix = person.identity == .unresolved ? " (identity unconfirmed)"
                : person.identity == .other && person.name.caseInsensitiveCompare("Me") == .orderedSame ? " (other speaker)" : ""
            let attribution = StatementAttribution(speakerID: speaker, speakerLabel: label + suffix,
                                                  identity: person.identity, quote: quote)
            if section == "Decisions" {
                result.outcomes.decisionRecords.append(.init(text: text, citations: [citation(id, segment, visible)], attribution: attribution))
            } else if section == "Open questions" {
                result.outcomes.openQuestions.append("\(attribution.speakerLabel): \(text)")
            }
        }
        for item in actions.prefix(maximumActions) {
            guard let primary = item["source"] as? String,
                  let context = item["context"] as? [String], context.count <= 2 else {
                reject(item, "invalid_action", kind: "actions"); continue
            }
            var seenIDs: Set<String> = []
            var ids = ([primary] + context).filter { seenIDs.insert($0).inserted }
            guard
                  ids.allSatisfy({ visible[$0] != nil && citationIDs[$0].flatMap { sources[$0] } != nil }) else {
                reject(item, "unknown_source", kind: "actions"); continue
            }
            guard let stable = citationIDs[primary], sources[stable] != nil else { continue }
            let primaryIndex = transcript.segments.indices.first { transcript.segmentID(at: $0) == stable }
            guard let primaryIndex, context.allSatisfy({ id in
                guard let contextStable = citationIDs[id],
                      let index = transcript.segments.indices.first(where: { transcript.segmentID(at: $0) == contextStable }) else { return false }
                return abs(index - primaryIndex) <= 8
            }) else { reject(item, "distant_action_context", kind: "actions"); continue }
            guard let rawText = item["text"] as? String, !normalized(rawText).isEmpty, rawText.count <= 280,
                  let rawDue = item["due"] as? String, rawDue.count <= 80,
                  let owner = item["owner"] as? String,
                  ["source", "unknown"].contains(owner) || speakers[owner] != nil,
                  let claimedBasis = item["basis"] as? String,
                  ["commitment", "assignment", "request", "unclear"].contains(claimedBasis),
                  let importance = item["importance"] as? Int, (1...5).contains(importance) else {
                reject(item, "invalid_action", kind: "actions"); continue
            }
            let citedText = ids.compactMap { visible[$0]?.map(\.text).joined(separator: " ") }.joined(separator: " ")
            let due = Self.spokenDue(rawDue, sourceIDs: Set(visible.keys), citedText: citedText)
            let quote = (item["quote"] as? String).map { raw -> String in
                var value = normalized(raw)
                // Some providers wrap a copied clause in quotation marks.
                // Removing one balanced wrapper cannot invent evidence.
                if value.count > 1, (value.first == "\"" && value.last == "\"") || (value.first == "“" && value.last == "”") {
                    value = String(value.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
                }
                return value
            }
            guard item["quote"] == nil || quote != nil, (quote?.count ?? 0) <= 1_000 else {
                reject(item, "invalid_action", kind: "actions"); continue
            }
            // A quote found word for word in one cited row re-anchors the task there.
            var anchor = primary
            if let quote, !quote.isEmpty {
                let matches = ids.filter { normalized((visible[$0] ?? []).map(\.text).joined(separator: " ")).contains(quote) }
                if matches.count == 1 {
                    anchor = matches[0]
                    let anchorStable = citationIDs[anchor]!
                    let anchorIndex = transcript.segments.indices.first { transcript.segmentID(at: $0) == anchorStable }!
                    // Two contexts eight rows either side of the old source
                    // must not become sixteen rows apart after re-anchoring.
                    guard ids.allSatisfy({ id in
                        let index = transcript.segments.indices.first { transcript.segmentID(at: $0) == citationIDs[id] }!
                        return abs(index - anchorIndex) <= 8
                    }) else { reject(item, "distant_action_context", kind: "actions"); continue }
                }
            }
            let visibleSource = (visible[anchor] ?? []).map(\.text).joined(separator: " ")
            if OutcomeEvidencePolicy.isBareAcceptance(visibleSource), ids.count == 1 {
                reject(item, "missing_task_context", kind: "actions"); continue
            }
            if OutcomeEvidencePolicy.isConversationManagement(visibleSource) {
                reject(item, "conversation_management", kind: "actions"); continue
            }
            func row(_ id: String) -> Int {
                transcript.segments.indices.first { transcript.segmentID(at: $0) == citationIDs[id] }!
            }
            let anchorRow = row(anchor)
            let ownership = ActionOwnership(transcript: transcript, roster: roster, isEnglish: isEnglishMeeting, text: { index in
                visible[transcript.summaryCitationID(at: index)].map { $0.map(\.text).joined(separator: " ") }
            })
            let requestAnswer = ["request", "assignment"].contains(claimedBasis) ? userReply(after: anchorRow, roster: roster) : nil
            let finding = ownership.resolve(
                .init(owner: speakers[owner]?.id, namesSource: owner == "source", basis: claimedBasis, quote: quote, task: rawText),
                primary: primaryIndex, context: context.map(row), quotedRow: anchor == primary ? nil : anchorRow,
                userReply: requestAnswer)
            let attribution = finding.attribution
            if claimedBasis == "commitment", attribution.resolution == .unresolved, attribution.rejectionReason != .quoteNotFound,
               !finding.citesUndertaking {
                // Unrecognized phrasing must not lose a task; it only loses
                // the ownership claim. A negated or questioned undertaking
                // and a status report are still not tasks. Those checks read
                // English wording, so elsewhere only a question mark can
                // veto; every quoted commitment would otherwise look like a
                // status report and be deleted.
                let contradicted = finding.citesOnlyRefusedUndertakings || (isEnglishMeeting
                    ? !finding.looksForward || OutcomeEvidencePolicy.undertakingIsNegatedOrQuestioned(visibleSource)
                    : visibleSource.contains("?"))
                if contradicted { reject(item, "unsupported_commitment", kind: "actions"); continue }
            }
            if let found = ids.first(where: { row($0) == finding.anchor }), found != ids[0] {
                ids = [found] + ids.filter { $0 != found }
            }
            anchor = ids[0]
            let ownerID = attribution.speakerID
            let compactOwner = speakers.first { $0.value.id == attribution.speakerID && attribution.resolution != .unresolved }?.key
            guard let text = prose(rawText, expectedSpeaker: compactOwner ?? visible[anchor]?.first?.speaker) else {
                reject(item, "speaker_reference", kind: "actions"); continue
            }
            // A past/status report is not a pending task. This catches the
            // explicit English failure mode without rewriting unknown prose.
            let statusPrefix = #"^(?:reported|completed|created|merged|updated|discussed|noted|confirmed|mentioned|stated|explained)\b"#
            if text.range(of: statusPrefix, options: [.regularExpression, .caseInsensitive]) != nil,
               text.range(of: #"\b(?:will|shall|going to|next|needs to|must)\b"#,
                          options: [.regularExpression, .caseInsensitive]) == nil {
                reject(item, "status_not_task", kind: "actions"); continue
            }
            let resolvedOwner = attribution.resolution == .user ? "Me"
                : attribution.resolution == .other ? ownerID.flatMap { roster[$0]?.name } : nil
            let citations = ids.compactMap { id -> OutcomeSourceCitation? in
                guard let stable = citationIDs[id], let segment = sources[stable] else { return nil }
                return citation(stable, segment, (visible[id] ?? []).map(\.text).joined(separator: " "))
            }
            let action = MeetingOutcomes.ActionItem(text: text, owner: resolvedOwner,
                due: due.isEmpty ? nil : due, isForUser: attribution.resolution == .user,
                importance: importance, citations: citations, attribution: attribution)
            result.outcomes.actionItems.append(action)
            result.records.append(.init(kind: "actions", source: anchor, text: text))
            let repairReasons: [OutcomeAttribution.RejectionReason: String] = [
                .missingQuote: "missing_ownership_evidence", .ambiguousQuote: "ambiguous_ownership_evidence",
                .quoteNotFound: "ownership_quote_not_found",
            ]
            if let reason = attribution.rejectionReason.flatMap({ repairReasons[$0] }) {
                result.rejected.append(.init(sources: [anchor], kind: "actions", reason: reason, text: text, actionID: action.id))
            }
        }
        return result
    }

    /// The user's speaker key when the user speaks the next turn after a
    /// request. Mixed or echoed speech is not a turn; a long pause ends the
    /// exchange, and any other participant's reply means it was not the user's.
    private func userReply(after index: Int, roster: [String: Transcript.SpeakerDescriptor]) -> String? {
        let segments = transcript.segments
        let requester = Transcript.canonicalSpeakerKey(segments[index].speaker)
        var end = segments[index].end
        for next in segments.dropFirst(index + 1) {
            let key = Transcript.canonicalSpeakerKey(next.speaker)
            if key == requester { end = max(end, next.end); continue }
            guard !next.displayText.isEmpty,
                  ![.overlappingSpeech, .suspectedEcho].contains(next.resolvedAttribution.method) else { continue }
            guard next.start - end <= 15 else { return nil }
            return roster[key]?.identity == .user ? key : nil
        }
        return nil
    }

    /// The due date as spoken, or "" when there is none. The built-in
    /// Qwen3.5 4B sometimes copied a cited source ID ("s268") into `due`,
    /// which rendered as "due s268".
    static func spokenDue(_ raw: String, sourceIDs: Set<String>, citedText: String? = nil) -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let bare = value.trimmingCharacters(in: CharacterSet(charactersIn: "[]()"))
        if sourceIDs.contains(bare) || bare.range(of: #"^[sS]\d+$"#, options: .regularExpression) != nil {
            return ""
        }
        // A year nobody said is the model's guess, not a deadline: an invented
        // "2024-01-01" resolved into the past and topped Today as overdue. The
        // action stays; only the unsupported due phrase goes.
        if let citedText, let years = try? NSRegularExpression(pattern: #"(?<!\d)(?:19|20)\d{2}(?!\d)"#) {
            for match in years.matches(in: value, range: NSRange(value.startIndex..., in: value)) {
                guard let range = Range(match.range, in: value) else { continue }
                if !citedText.contains(value[range]) { return "" }
            }
        }
        return value
    }

    private func normalized(_ text: String) -> String {
        text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func prose(_ text: String, expectedSpeaker: String?) -> String? {
        var value = normalized(text)
        if let expectedSpeaker, speakers[expectedSpeaker]?.identity != .user,
           value.range(of: #"\b(?:you|your|yours|yourself)\b"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return nil
        }
        // A redundant leading ID can be removed only when it exactly matches
        // the independently resolved speaker. A conflicting ID is rejected.
        if let expectedSpeaker,
           let prefix = value.range(of: #"^(?:(?:Speaker|User)\s+)?"#
                                    + NSRegularExpression.escapedPattern(for: expectedSpeaker) + #"\b[ :,-]*"#,
                                    options: [.regularExpression, .caseInsensitive]) {
            value.removeSubrange(prefix)
            if let first = value.first { value = String(first).uppercased() + value.dropFirst() }
        }
        let containsReference = speakers.keys.contains { id in
            value.range(of: #"\b"# + NSRegularExpression.escapedPattern(for: id) + #"\b"#,
                       options: .regularExpression) != nil
        }
        return value.isEmpty || containsReference ? nil : value
    }

    private func validSection(_ section: String, template: NoteTemplate) -> Bool {
        if template == .freeform {
            return !normalized(section).isEmpty && section.count <= 80
                && !section.contains(where: { $0.isNewline || $0 == "#" })
                && section.caseInsensitiveCompare("Action items") != .orderedSame
        }
        return Self.sections(template).contains(section)
    }
}

/// Decisions a speaker states outright ("Decision made: we shoot in the
/// studio", "we decided the launch stays on the 20th"). Small models can file
/// these under Key points, which leaves a meeting with no cited decisions, so
/// a stated decision the model did not list is taken from its row. English
/// only, like the other wording checks.
enum ExplicitDecisions {
    /// One note per stated decision that isn't already listed. `rows` holds
    /// the rows no Decisions note cites.
    static func missing(listedTexts: [String], in rows: [String: String]) -> [[String: Any]] {
        var known = listedTexts
        var added: [[String: Any]] = []
        for source in rows.keys.sorted() {
            for decision in statements(in: rows[source] ?? "") {
                guard !known.contains(where: { OutcomeTextSimilarity.isSimilar($0, decision, threshold: 0.5) }) else { continue }
                known.append(decision)
                added.append(["section": "Decisions", "text": decision, "source": source])
            }
        }
        return added
    }

    static func statements(in text: String) -> [String] {
        var found: [String] = []
        text.enumerateSubstrings(in: text.startIndex..., options: [.bySentences, .localized]) { sentence, _, _, _ in
            if let sentence, let decision = statement(in: sentence.trimmingCharacters(in: .whitespacesAndNewlines)) {
                found.append(decision)
            }
        }
        return found
    }

    private static func statement(in sentence: String) -> String? {
        // A request after the decision is an action, not part of it.
        let request = #",\s*(?:can|could|would|will) you\b.*$"#
        let clause = sentence.replacingOccurrences(of: request, with: "", options: [.regularExpression, .caseInsensitive])
        guard !clause.hasSuffix("?") else { return nil }
        let past = #"\b(?:last (?:year|quarter|month|week)|years? ago|months? ago|back then|previously)\b"#
        guard clause.range(of: past, options: [.regularExpression, .caseInsensitive]) == nil else { return nil }
        var decision: String?
        var opening = clause.startIndex..<clause.startIndex
        if let marker = clause.range(of: #"\bdecision(?: is| was)?(?: made)?\s*[:,–—-]\s*"#, options: [.regularExpression, .caseInsensitive]) {
            opening = clause.startIndex..<marker.lowerBound
            decision = String(clause[marker.upperBound...])
        } else if let subject = clause.range(of: #"\b(?:we|we've|we have|the team|the team has) (?:decided|agreed)\b"#, options: [.regularExpression, .caseInsensitive]) {
            opening = clause.startIndex..<subject.lowerBound
            decision = String(clause[subject.lowerBound...])
        }
        // "If we decided…", "what we decided…", "no decision, …" settle nothing.
        let unsettledOpening = #"\b(?:if|whether|once|when|unless|until|before|after|what|did|have|had|no)\b"#
        guard clause[opening].range(of: unsettledOpening, options: [.regularExpression, .caseInsensitive]) == nil else { return nil }
        guard var text = decision?.trimmingCharacters(in: CharacterSet.whitespaces.union(.punctuationCharacters)),
              text.split(whereSeparator: \.isWhitespace).count >= 3 else { return nil }
        text = text.prefix(1).uppercased() + text.dropFirst() + "."
        return text.count <= 280 ? text : nil
    }
}
