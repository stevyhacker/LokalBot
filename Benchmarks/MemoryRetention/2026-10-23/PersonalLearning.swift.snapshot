import CryptoKit
import Foundation
import NaturalLanguage

/// The overnight learning pass (personal world model, Phase 3). After the
/// day's review, it reads only the person's own words from that day: their
/// lines in meetings, what they typed to coding agents or in Ask, and, when
/// Learn from my dictation is on, what they dictated into other apps. It asks
/// the Think model for at most three durable things about them. Every result
/// must point at one of those lines and be grounded in it; anything else is
/// dropped. Facts and goals from meetings are saved; preferences, and
/// anything learned from typing, wait for review; principles are never
/// learned (`PersonalModel.learn`).
enum PersonalLearning {
    /// One line of the person's own words. `handle` is what the model cites.
    struct Utterance: Equatable, Sendable {
        enum Source: Equatable, Sendable {
            /// Consecutive microphone segments of one meeting, joined.
            case meeting(UUID)
            case typed(PersonalClaim.TypedSource)
        }

        var handle: String
        var source: Source
        /// The meeting title or "typed to Claude Code", shown to the model.
        var label: String
        var dayKey: String
        var text: String

        init(handle: String, source: Source, label: String, dayKey: String, text: String) {
            self.handle = handle
            self.source = source
            self.label = label
            self.dayKey = dayKey
            self.text = text
        }

        init(handle: String, meetingID: UUID, meetingTitle: String, dayKey: String, text: String) {
            self.init(handle: handle, source: .meeting(meetingID), label: meetingTitle, dayKey: dayKey, text: text)
        }

        var meetingID: UUID? {
            if case .meeting(let id) = source { return id }
            return nil
        }
    }

    /// Something the person typed or dictated that day, gathered by the app.
    struct TypedLine: Equatable, Sendable {
        var source: PersonalClaim.TypedSource
        var text: String

        var label: String {
            switch source {
            case .codingAgent(let name): "typed to \(name)"
            case .ask: "typed in Ask"
            case .dictation(let app): app.isEmpty ? "dictated" : "dictated in \(app)"
            }
        }
    }

    static let maxPerNight = 3
    static let maxUtterances = 40
    /// Typed lines share the budget but never crowd meetings out.
    static let maxTypedUtterances = 15
    static let utteranceCharacterBudget = 6_000
    static let maxTurnCharacters = 400
    static let minimumWords = 5
    static let maxOutputTokens = 1_024

    // MARK: - The person's lines

    /// The person's turns from `day`'s meetings, most self-descriptive first
    /// within the budget, then put back in meeting order with handles. A
    /// meeting whose microphone was shared by several diarized local voices is
    /// skipped: there is no telling which of them is the person.
    static func utterances(day: Date, storageRoot: URL, typed: [TypedLine] = [],
                           calendar: Calendar = .current) throws -> [Utterance] {
        let start = calendar.startOfDay(for: day)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        let meetings = try SessionLookup.loadAllMeetings(root: storageRoot)
            .filter { !$0.isSample && $0.startedAt >= start && $0.startedAt < end }
            .sorted { $0.startedAt < $1.startedAt }
        let dayKey = DreamDay.key(for: start, calendar: calendar)
        var turns: [(order: Int, score: Int, utterance: Utterance)] = []
        for meeting in meetings {
            let url = storageRoot.appendingPathComponent(meeting.relativePath, isDirectory: true)
                .appendingPathComponent("transcript.json")
            guard let data = try? Data(contentsOf: url),
                  let transcript = try? JSONDecoder().decode(Transcript.self, from: data) else { continue }
            for text in ownTurns(in: transcript.segments) {
                let utterance = Utterance(handle: "", meetingID: meeting.id, meetingTitle: meeting.title,
                                          dayKey: dayKey, text: text)
                turns.append((turns.count, selfReferenceScore(text), utterance))
            }
        }
        for line in typed {
            let text = PromptContextSanitizer.sanitize(line.text, maxCharacters: maxTurnCharacters)
            guard text.split(whereSeparator: \.isWhitespace).count >= minimumWords else { continue }
            let utterance = Utterance(handle: "", source: .typed(line.source), label: line.label,
                                      dayKey: dayKey, text: text)
            turns.append((turns.count, selfReferenceScore(text), utterance))
        }
        let ranked = turns.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.order < rhs.order
        }
        var chosen: [(order: Int, utterance: Utterance)] = []
        var used = 0
        var typedCount = 0
        for turn in ranked where turn.score > 0 {
            let isTyped = turn.utterance.meetingID == nil
            guard chosen.count < maxUtterances, used + turn.utterance.text.count <= utteranceCharacterBudget,
                  !isTyped || typedCount < maxTypedUtterances else { continue }
            used += turn.utterance.text.count
            if isTyped { typedCount += 1 }
            chosen.append((turn.order, turn.utterance))
        }
        var result: [Utterance] = []
        for (index, turn) in chosen.sorted(by: { $0.order < $1.order }).enumerated() {
            var utterance = turn.utterance
            utterance.handle = "U\(index + 1)"
            result.append(utterance)
        }
        return result
    }

    /// The day's typed lines: requests the person sent to coding agents
    /// (scheduled runs excluded), questions asked in Ask, and dictation kept
    /// for learning. A "Remember …" message is already saved, so it is
    /// skipped, and a dictation that became one of those requests is read
    /// once, from the request.
    static func typedLines(bursts: [CodingAgentBurst], conversations: [Conversation],
                           dictations: [DictationLearningLog.Entry] = [], day: Date,
                           calendar: Calendar = .current) -> [TypedLine] {
        var lines: [TypedLine] = []
        for burst in bursts where !burst.isScheduledRun && calendar.isDate(burst.start, inSameDayAs: day) {
            for prompt in burst.prompts {
                lines.append(TypedLine(source: .codingAgent(name: burst.agent.displayName), text: prompt))
            }
        }
        for conversation in conversations {
            let messages = conversation.messages
            for (index, message) in messages.enumerated()
            where message.role == .user && !message.createdAtIsEstimated
                && calendar.isDate(message.createdAt, inSameDayAs: day) {
                let next = messages.index(after: index)
                if next < messages.endIndex, messages[next].rememberReceipt != nil { continue }
                lines.append(TypedLine(source: .ask(conversationID: conversation.id), text: message.text))
            }
        }
        let typedSoFar = lines.map { foldedForDuplicate($0.text) }
        for entry in dictations where calendar.isDate(entry.dictatedAt, inSameDayAs: day) {
            let folded = foldedForDuplicate(entry.text)
            guard !folded.isEmpty, !typedSoFar.contains(where: { $0.contains(folded) || folded.contains($0) })
            else { continue }
            lines.append(TypedLine(source: .dictation(app: entry.appName), text: entry.text))
        }
        return lines
    }

    /// "meeting=4 typed=2 dictated=0" for the log: where a day's lines came from.
    static func lineCounts(_ lines: [Utterance]) -> String {
        var meeting = 0, typed = 0, dictated = 0
        for line in lines {
            switch line.source {
            case .meeting: meeting += 1
            case .typed(.dictation): dictated += 1
            case .typed: typed += 1
            }
        }
        return "lines=meeting:\(meeting),typed:\(typed),dictated:\(dictated)"
    }

    /// What the pass read for a day, independent of order and handles.
    /// Dictated lines are left out: they are deleted once read, so a later
    /// review of the same day would otherwise always look changed.
    static func fingerprint(_ lines: [Utterance]) -> String {
        let material = lines.compactMap { line -> String? in
            if case .typed(.dictation) = line.source { return nil }
            return "\(line.label)\u{1f}\(line.text)"
        }.sorted().joined(separator: "\u{1e}")
        return SHA256.hash(data: Data(material.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Whether `lines` still contain the line a learned claim quotes, ignoring
    /// case, accents, punctuation, and where a long line was cut off.
    static func quoteStillSaid(_ quote: String?, in lines: [String]) -> Bool {
        guard let quote else { return false }
        let needle = foldedForDuplicate(quote.replacingOccurrences(of: "…", with: ""))
        guard needle.count >= 12 else { return false }
        return lines.contains { line in
            let haystack = foldedForDuplicate(line.replacingOccurrences(of: "…", with: ""))
            return haystack.contains(needle) || (haystack.count >= 12 && needle.contains(haystack))
        }
    }

    /// Letters and digits only, case- and accent-folded, so a dictation and
    /// the request it was pasted into compare equal despite punctuation.
    private static func foldedForDuplicate(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        return String(folded.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }

    /// Joins consecutive segments of the person's own speech into turns.
    ///
    /// Own speech is microphone speech ("me", "local", "local N", also behind
    /// a merged recording's "source:" prefix) whose attribution is the user:
    /// echo, overlapping voices, and voices corrected to someone else are
    /// left out. Diarization labels the person "local 1" and leaves some of
    /// their segments as plain "local", so those are one voice. A voice the
    /// person confirmed as theirs wins. Otherwise, when diarization found
    /// several voices on the microphone, the meeting counts only if one of
    /// them clearly dominates (four times the next), and then only that
    /// voice is used; with no clear winner the microphone was shared and the
    /// meeting is skipped, since there is no telling which voice is the person.
    static func ownTurns(in segments: [Transcript.Segment]) -> [String] {
        let keys = segments.map { Transcript.canonicalSpeakerKey($0.speaker) }
        let mine = segments.indices.filter { isOwnSpeech(segments[$0], key: keys[$0]) }
        let confirmed = Set(mine.filter { segments[$0].attribution?.isConfirmedUser == true }.map { keys[$0] })
        var voices: [String: Int] = [:]
        for index in mine where isNumberedVoice(keys[index]) { voices[keys[index], default: 0] += 1 }
        let ranked = voices.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
        let accepted: Set<Int>
        if !confirmed.isEmpty {
            accepted = Set(mine.filter { confirmed.contains(keys[$0]) })
        } else if ranked.count >= 2 {
            guard ranked[0].value >= 4 * ranked[1].value else { return [] }
            accepted = Set(mine.filter { keys[$0] == ranked[0].key })
        } else {
            accepted = Set(mine)
        }
        var turns: [String] = []
        var current = ""
        func flush() {
            let text = PromptContextSanitizer.sanitize(current, maxCharacters: maxTurnCharacters)
            if text.split(whereSeparator: \.isWhitespace).count >= minimumWords { turns.append(text) }
            current = ""
        }
        for index in segments.indices {
            if accepted.contains(index) {
                current += (current.isEmpty ? "" : " ") + segments[index].text
            } else if !current.isEmpty {
                flush()
            }
        }
        if !current.isEmpty { flush() }
        return turns
    }

    /// Microphone speech attributed to the user. Older transcripts carry no
    /// attribution; their microphone labels follow "My microphone is me".
    private static func isOwnSpeech(_ segment: Transcript.Segment, key: String) -> Bool {
        guard MeetingOutcomes.isMicrophoneSpeaker(segment.speaker), !key.hasSuffix("unclear") else { return false }
        guard segment.attribution != nil else { return SpeakerAttribution.microphoneIsUser }
        return segment.resolvedAttribution.identity == .user
    }

    /// "local 1", "source2:local 3": one voice diarization told apart.
    private static func isNumberedVoice(_ key: String) -> Bool {
        let local = key.split(separator: ":").last.map(String.init) ?? key
        return local.range(of: #"^local \d+$"#, options: .regularExpression) != nil
    }

    private static let selfReferences: Set<String> = [
        "i", "i'm", "im", "i've", "i'd", "i'll", "my", "me", "mine", "myself",
        "ja", "moj", "moja", "moje", "moji", "mene", "meni", "sam", "imam", "zivim", "radim",
        "zelim", "planiram", "hocu",
        "ја", "мој", "моја", "моје", "мене", "мени", "сам", "имам", "живим", "радим", "желим", "планирам", "хоћу",
    ]

    /// How many first-person words a line has (English and Serbian). Lines
    /// without any are not about the person and are never sent.
    static func selfReferenceScore(_ text: String) -> Int {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        var score = 0
        for raw in folded.split(whereSeparator: { !$0.isLetter && $0 != "'" }) {
            let word = raw.trimmingCharacters(in: CharacterSet(charactersIn: "'"))
            if selfReferences.contains(word) { score += 1 }
        }
        return score
    }

    // MARK: - Prompt

    static let system = """
        You keep a small private profile of the user from things they said about themselves. \
        You read only the user's own words: lines they said in meetings and things they typed or dictated. \
        Nobody else's words are included. Reply with JSON only.
        """

    static func prompt(utterances: [Utterance], known: [PersonalClaim]) -> String {
        var lines: [String] = []
        lines.append("""
            From the user's lines below, pick at most \(maxPerNight) things about the user that will still be \
            true and useful in a month:
            - fact: their life, role, work, circumstances, or relationships ("I live in Belgrade", \
            "I lead the platform team", "I have two kids").
            - goal: a longer-term goal they set for themselves ("I want to run a marathon next year").
            - preference: how they like to work or be helped ("I prefer written updates to calls").

            Rules:
            - Use only what the line clearly says about the user. Never guess, never turn one remark into \
            a trait, and never infer their values, beliefs, or personality.
            - Skip project status, tasks, deadlines, meeting logistics, small talk, jokes, hypotheticals, \
            quotes of other people, and anything about other people's private lives.
            - Skip health, money, religion, politics, and sexuality.
            - Typed lines are usually requests or questions. Look inside them too: the user often mentions \
            a fact or preference about themselves while asking for something. Keep only that part.
            - Dictated lines are often messages to someone else. Keep only what they say about the user.
            - Skip anything already in the known list, even if worded differently.
            - Write each item as one short first-person sentence under 200 characters, built from the \
            line's own words: shorten it rather than rephrase it, and never translate it (a Serbian line stays \
            Serbian, an English line stays English). Drop filler \
            ("honestly", "so", "haha"). Turn a relative time into the year it means ("next year" becomes \
            "in 2027"); never invent a day or month.
            - Consider every line on its own, typed and dictated lines included.
            - Return {"items": []} when nothing qualifies. That is the usual answer.

            Reply as {"items": [{"line": "U3", "kind": "fact", "text": "I live in Belgrade."}]}.
            """)
        if !known.isEmpty {
            lines.append("")
            lines.append("Already known (do not repeat):")
            for claim in known.prefix(40) {
                lines.append("- \(PromptContextSanitizer.sanitize(claim.text, maxCharacters: PersonalModel.maxCharacters))")
            }
        }
        lines.append("")
        lines.append("The user's lines from \(utterances.first?.dayKey ?? "the reviewed day"), each with where they said, typed, or dictated it:")
        for utterance in utterances {
            let title = PromptContextSanitizer.sanitize(utterance.label, maxCharacters: 80)
            lines.append("\(utterance.handle) (\(title)): \(utterance.text)")
        }
        return lines.joined(separator: "\n")
    }

    static var schema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "items": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "properties": [
                            "line": ["type": "string"],
                            "kind": ["type": "string", "enum": ["fact", "goal", "preference"]],
                            "text": ["type": "string"],
                        ],
                        "required": ["line", "kind", "text"],
                    ],
                ],
            ],
            "required": ["items"],
        ]
    }

    // MARK: - Reading the reply

    private struct Reply: Decodable {
        struct Item: Decodable {
            var line: String
            var kind: String
            var text: String
        }
        var items: [Item]
    }

    /// An item the model proposed, tied to the line it cites.
    struct Proposal: Equatable, Sendable {
        var kind: PersonalClaimKind
        var text: String
        var utterance: Utterance
    }

    /// Every item that cites a real line with a learnable kind, in reply
    /// order. Grounding happens after this.
    static func proposals(from output: String, utterances: [Utterance]) -> [Proposal] {
        guard let start = output.firstIndex(of: "{"), let end = output.lastIndex(of: "}"),
              let reply = try? JSONDecoder().decode(Reply.self, from: Data(output[start...end].utf8)) else {
            return []
        }
        var byHandle: [String: Utterance] = [:]
        for utterance in utterances where byHandle[utterance.handle.uppercased()] == nil {
            byHandle[utterance.handle.uppercased()] = utterance
        }
        var result: [Proposal] = []
        for item in reply.items {
            guard let utterance = byHandle[item.line.trimmingCharacters(in: .whitespaces).uppercased()],
                  let kind = PersonalClaimKind(rawValue: item.kind.lowercased()), kind != .principle else { continue }
            result.append(Proposal(kind: kind, text: item.text, utterance: utterance))
        }
        return result
    }

    /// Word-overlap grounding only: what `run` falls back to without an
    /// embedder. At most `maxPerNight`.
    static func candidates(from output: String, utterances: [Utterance],
                           evidence: (Utterance) -> DreamEvidenceProvenance?) -> [PersonalModel.LearningCandidate] {
        var result: [PersonalModel.LearningCandidate] = []
        for proposal in proposals(from: output, utterances: utterances) where result.count < maxPerNight {
            guard isGrounded(proposal.text, in: proposal.utterance.text) else { continue }
            result.append(candidate(proposal, needsReview: false, evidence: evidence))
        }
        return result
    }

    static func isGrounded(_ claim: String, in line: String) -> Bool {
        let claimWords = PersonalContextSelection.contentWords(claim)
        guard !claimWords.isEmpty else { return false }
        let shared = claimWords.intersection(PersonalContextSelection.contentWords(line)).count
        return shared >= max(1, Int((Double(claimWords.count) / 3).rounded(.up)))
    }

    // MARK: - Grounding across languages

    /// Vectors for texts, L2-normalized, or nil when no embedder is available.
    typealias Embed = ([String]) async -> [[Float]]?

    /// EmbeddingGemma 2 with the sentence-similarity prompt, measured on
    /// Serbian lines against English items (2026-10-14): correct
    /// translations 0.83–0.95, unrelated claims 0.73–0.79, and a wrong
    /// detail ("doctor" for engineer, the wrong city) 0.80–0.90. Below the
    /// floor an item is dropped. Above it, a fact or goal is saved only with a
    /// shared word root or a very high score; otherwise it waits for review,
    /// because embeddings alone can't tell a wrong detail from a right one.
    /// Recalibrate whenever the embedding model changes.
    static let crossLanguageFloor: Float = 0.82
    static let confidentSimilarity: Float = 0.90

    enum Grounding: Equatable {
        case grounded
        case needsReview
        case rejected
    }

    /// Word overlap for items in the line's language. An item the model
    /// translated (the line is Serbian, the item English) can't share words,
    /// so it is compared by meaning instead, when an embedder is available.
    static func groundedCandidates(
        from output: String, utterances: [Utterance], embed: Embed?,
        evidence: (Utterance) -> DreamEvidenceProvenance?
    ) async -> [PersonalModel.LearningCandidate] {
        let all = proposals(from: output, utterances: utterances)
        var verdicts = all.map { proposal -> Grounding? in
            if isGrounded(proposal.text, in: proposal.utterance.text) { return .grounded }
            return isCrossLanguage(proposal.text, proposal.utterance.text) ? nil : .rejected
        }
        let pending = verdicts.indices.filter { verdicts[$0] == nil }
        if !pending.isEmpty {
            var texts: [String] = []
            for index in pending {
                texts.append(all[index].text)
                texts.append(all[index].utterance.text)
            }
            let vectors = await embed?(texts)
            for (offset, index) in pending.enumerated() {
                guard let vectors, vectors.count == texts.count else {
                    verdicts[index] = .rejected
                    continue
                }
                let similarity = dot(vectors[offset * 2], vectors[offset * 2 + 1])
                verdicts[index] = crossLanguageVerdict(
                    similarity: similarity, claim: all[index].text, line: all[index].utterance.text)
            }
        }
        var result: [PersonalModel.LearningCandidate] = []
        for (proposal, verdict) in zip(all, verdicts) where result.count < maxPerNight {
            switch verdict {
            case .grounded: result.append(candidate(proposal, needsReview: false, evidence: evidence))
            case .needsReview: result.append(candidate(proposal, needsReview: true, evidence: evidence))
            case .rejected, nil: continue
            }
        }
        return result
    }

    static func crossLanguageVerdict(similarity: Float, claim: String, line: String) -> Grounding {
        guard similarity >= crossLanguageFloor else { return .rejected }
        if similarity >= confidentSimilarity || sharesWordRoot(claim, line) { return .grounded }
        return .needsReview
    }

    /// True when the two texts' dominant languages differ, so word overlap
    /// can't apply. Unknown counts as the same language: the stricter path.
    static func isCrossLanguage(_ claim: String, _ line: String) -> Bool {
        guard let claimLanguage = NLLanguageRecognizer.dominantLanguage(for: claim),
              let lineLanguage = NLLanguageRecognizer.dominantLanguage(for: line) else { return false }
        return claimLanguage != lineLanguage
    }

    /// A content word of the item and of the line (Cyrillic transliterated)
    /// start the same way: "platform" in "platformu", "marathon" in
    /// "maraton", "sad" in "sadu".
    static func sharesWordRoot(_ claim: String, _ line: String) -> Bool {
        let latinLine = line.applyingTransform(.toLatin, reverse: false) ?? line
        let lineWords = PersonalContextSelection.contentWords(latinLine)
        for word in PersonalContextSelection.contentWords(claim) {
            for other in lineWords {
                let shared = zip(word, other).prefix { $0 == $1 }.count
                if shared >= 4 || (shared >= 3 && shared == min(word.count, other.count)) { return true }
            }
        }
        return false
    }

    private static func dot(_ lhs: [Float], _ rhs: [Float]) -> Float {
        var sum: Float = 0
        for index in 0..<min(lhs.count, rhs.count) { sum += lhs[index] * rhs[index] }
        return sum
    }

    private static func candidate(_ proposal: Proposal, needsReview: Bool,
                                  evidence: (Utterance) -> DreamEvidenceProvenance?) -> PersonalModel.LearningCandidate {
        let utterance = proposal.utterance
        let origin: PersonalClaim.Origin
        switch utterance.source {
        case .meeting(let id): origin = .learned(meetingID: id, dayKey: utterance.dayKey)
        case .typed(let source): origin = .typed(source: source, dayKey: utterance.dayKey)
        }
        return PersonalModel.LearningCandidate(
            kind: proposal.kind, text: proposal.text, quote: utterance.text, origin: origin,
            evidence: evidence(utterance), needsReview: needsReview || utterance.meetingID == nil)
    }

    /// What a learned item depends on: its meeting, or the day's activity
    /// evidence for a coding-agent request (deleting saved agent sessions
    /// retracts it). An Ask question has none; deleting its conversation
    /// retracts the item instead.
    static func provenance(for utterance: Utterance, revision: UInt64) -> DreamEvidenceProvenance? {
        switch utterance.source {
        case .meeting(let id):
            return DreamEvidenceProvenance(
                sources: [DreamEvidenceSource(kind: .meeting, id: id.uuidString, dayKey: utterance.dayKey)],
                revision: revision)
        case .typed(.codingAgent):
            return DreamEvidenceProvenance(
                sources: [DreamEvidenceSource(kind: .screenDay, id: utterance.dayKey, dayKey: utterance.dayKey)],
                revision: revision)
        case .typed(.ask), .typed(.dictation):
            return nil
        }
    }

    // MARK: - Run

    /// One night's pass. Returns no candidates without calling the model when
    /// the day has none of the person's own lines.
    static func run(day: Date, storageRoot: URL, known: [PersonalClaim], revision: UInt64,
                    engine: TextEngine, embed: Embed? = nil, typed: [TypedLine] = [],
                    calendar: Calendar = .current) async throws -> [PersonalModel.LearningCandidate] {
        let lines = try utterances(day: day, storageRoot: storageRoot, typed: typed, calendar: calendar)
        return try await run(lines: lines, known: known, revision: revision, engine: engine, embed: embed)
    }

    /// The pass over lines already gathered (`utterances`), so the caller can
    /// first check `fingerprint` against the days already read.
    static func run(lines: [Utterance], known: [PersonalClaim], revision: UInt64,
                    engine: TextEngine, embed: Embed? = nil) async throws -> [PersonalModel.LearningCandidate] {
        guard !lines.isEmpty else { return [] }
        let output = try await engine.generate(
            system: system, prompt: prompt(utterances: lines, known: known), context: [],
            schema: schema,
            options: TextGenerationOptions(maxTokens: maxOutputTokens, reasoningBudgetTokens: 0, temperature: 0))
        return await groundedCandidates(from: output, utterances: lines, embed: embed) { utterance in
            provenance(for: utterance, revision: revision)
        }
    }
}
