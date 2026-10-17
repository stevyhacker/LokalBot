import CryptoKit
import Foundation

/// One thing LokalBot knows about the person: a fact about them, how they want
/// help, a goal, or a principle they decide by
/// (Docs/personal-world-model-rfc-2026-10-14.md). Stated claims are the
/// person's own words. Learned claims come from what the person said in a
/// meeting; they carry that meeting as evidence and retract with it.
/// Principles are never learned.
struct PersonalClaim: Codable, Identifiable, Equatable, Sendable, PersonalContextItem {
    typealias Kind = PersonalClaimKind

    enum Origin: Codable, Equatable, Sendable {
        /// "Remember …" typed in Ask or Quick Recall.
        case said(conversationID: UUID, messageID: UUID)
        /// Added in Settings → Day Memory → About you.
        case added
        /// Picked up overnight from the person's own line in this meeting.
        case learned(meetingID: UUID, dayKey: String)
        /// Picked up overnight from something the person typed that day.
        case typed(source: TypedSource, dayKey: String)
        /// A goal or project the overnight review kept for weeks; the day
        /// is when it was first seen.
        case workMemory(dayKey: String)
    }

    /// Where the person typed the words a claim was learned from.
    enum TypedSource: Codable, Equatable, Sendable {
        /// A request to Claude Code or Codex, saved by Read coding agent sessions.
        case codingAgent(name: String)
        /// A question asked in Ask or Quick Recall.
        case ask(conversationID: UUID)
        /// Words dictated into another app, kept by Learn from my dictation
        /// only until the night's pass read them.
        case dictation(app: String)
    }

    /// Who may read the claim besides LokalBot itself.
    enum Sharing: String, Codable, Sendable {
        /// Ask and Quick Recall only. The default for every claim.
        case lokalBotOnly
        /// Also external agents, while the Personal context grant is on.
        case agents
    }

    enum Status: String, Codable, Sendable {
        /// In use by Ask and, if shared, agents.
        case confirmed
        /// A learned preference waiting for the person's review; never used.
        case proposed
    }

    enum Authority: String, Codable, Sendable {
        /// The person stated it or kept it as their own statement.
        case stated
        /// Saved automatically from what the person said in a meeting.
        case learned
        /// Learned, then confirmed by the person in review.
        case confirmed
    }

    let id: UUID
    var kind: Kind
    var text: String
    let origin: Origin
    /// Included first in every eligible prompt, ahead of relevance ranking.
    var alwaysUse: Bool
    var sharing: Sharing
    var status: Status
    var authority: Authority
    /// The meeting a learned claim came from. Nil means no evidence
    /// dependency (stated claims, or a learned one the person kept).
    var evidence: DreamEvidenceProvenance?
    /// The person's own line the claim was learned from, shown in review.
    var quote: String?
    let createdAt: Date
    var updatedAt: Date
    var lastUsedAt: Date?

    init(id: UUID = UUID(), kind: Kind, text: String, origin: Origin,
         alwaysUse: Bool = false, sharing: Sharing = .lokalBotOnly,
         status: Status = .confirmed, authority: Authority = .stated,
         evidence: DreamEvidenceProvenance? = nil, quote: String? = nil, createdAt: Date,
         updatedAt: Date? = nil, lastUsedAt: Date? = nil) {
        self.id = id
        self.kind = kind
        self.text = text
        self.origin = origin
        self.alwaysUse = alwaysUse
        self.sharing = sharing
        self.status = status
        self.authority = authority
        self.evidence = evidence
        self.quote = quote
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.lastUsedAt = lastUsedAt
    }

    /// Learned automatically rather than stated (it may since have been
    /// kept or restated, which `authority` records).
    var isLearned: Bool {
        switch origin {
        case .learned, .typed, .workMemory: true
        case .said, .added: false
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, text, origin, alwaysUse, sharing, status, authority, evidence, quote
        case createdAt, updatedAt, lastUsedAt
    }

    /// Fields added after Phase 1 decode with defaults that keep earlier
    /// behavior: an older claim is a confirmed, stated, LokalBot-only one.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        kind = try c.decode(Kind.self, forKey: .kind)
        text = try c.decode(String.self, forKey: .text)
        origin = try c.decode(Origin.self, forKey: .origin)
        alwaysUse = try c.decodeIfPresent(Bool.self, forKey: .alwaysUse) ?? false
        sharing = try c.decodeIfPresent(Sharing.self, forKey: .sharing) ?? .lokalBotOnly
        status = try c.decodeIfPresent(Status.self, forKey: .status) ?? .confirmed
        authority = try c.decodeIfPresent(Authority.self, forKey: .authority) ?? .stated
        evidence = try c.decodeIfPresent(DreamEvidenceProvenance.self, forKey: .evidence)
        quote = try c.decodeIfPresent(String.self, forKey: .quote)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        lastUsedAt = try c.decodeIfPresent(Date.self, forKey: .lastUsedAt)
    }
}

extension PersonalClaimKind {
    var displayName: String {
        switch self {
        case .fact: "Fact"
        case .preference: "Preference"
        case .goal: "Goal"
        case .principle: "Principle"
        }
    }

    var systemImage: String {
        switch self {
        case .fact: "person.text.rectangle"
        case .preference: "slider.horizontal.3"
        case .goal: "flag"
        case .principle: "scale.3d"
        }
    }

    /// A starting kind for a statement typed in Ask. Only obvious English
    /// openings are recognized; principles are never guessed, because the
    /// person decides what counts as one of their values.
    static func suggested(for text: String) -> PersonalClaimKind {
        let lowered = text.lowercased()
        let preferenceOpenings = ["i prefer", "i like", "i don't like", "i do not like", "i dislike",
                                  "answer in", "reply in", "respond in", "always answer", "use "]
        if preferenceOpenings.contains(where: lowered.hasPrefix) { return .preference }
        let goalOpenings = ["my goal", "i want to", "i'm working toward", "i am working toward",
                            "i'm trying to", "i am trying to", "i plan to"]
        if goalOpenings.contains(where: lowered.hasPrefix) { return .goal }
        return .fact
    }
}

extension PersonalContextProjection.Claim {
    init(_ claim: PersonalClaim) {
        let source: Source
        switch claim.origin {
        case .said: source = .askedToRemember
        case .added: source = .addedInSettings
        case .learned: source = claim.authority == .stated ? .addedInSettings : .learnedFromMeeting
        case .typed(.dictation, _): source = claim.authority == .stated ? .addedInSettings : .learnedFromDictation
        case .typed: source = claim.authority == .stated ? .addedInSettings : .learnedFromTyping
        case .workMemory: source = claim.authority == .stated ? .addedInSettings : .learnedFromWorkMemory
        }
        self.init(id: claim.id, kind: claim.kind, text: claim.text, alwaysUse: claim.alwaysUse,
                  source: source, createdAt: claim.createdAt, updatedAt: claim.updatedAt)
    }
}

/// The person's claims plus the rules every edit goes through. Pure value
/// type: the store persists it and the controller publishes it.
struct PersonalModel: Codable, Equatable, Sendable {
    static let currentVersion = 1
    static let maxClaims = 300
    static let maxCharacters = 280

    enum EditError: Error, Equatable, LocalizedError {
        case empty
        case tooLong(Int)
        case full
        case looksSecret
        case notFound
        case unavailable

        var errorDescription: String? {
            switch self {
            case .empty:
                "There's nothing to remember."
            case .tooLong(let count):
                "That's \(count) characters. LokalBot remembers up to \(PersonalModel.maxCharacters); shorten it and try again."
            case .full:
                "LokalBot already remembers \(PersonalModel.maxClaims) things about you. Forget some in Settings → Day Memory first."
            case .looksSecret:
                "This looks like a password, key, or card number. LokalBot doesn't remember those."
            case .notFound:
                "That item was already forgotten."
            case .unavailable:
                "LokalBot couldn't open what it remembers about you, so it won't change it now."
            }
        }
    }

    /// A forgotten learned claim or a dismissed suggestion, kept only as a
    /// one-way hash so the same text isn't learned again.
    struct Tombstone: Codable, Equatable, Sendable {
        var key: String
        var createdAt: Date
    }

    static let maxProposals = 20
    static let proposalLifetime: TimeInterval = 14 * 24 * 60 * 60
    static let tombstoneLifetime: TimeInterval = 180 * 24 * 60 * 60

    /// When a work-memory goal or project was first seen, as a hash of its
    /// text, so one that lasts for weeks can be suggested.
    struct WorkSighting: Codable, Equatable, Sendable {
        var key: String
        var firstDayKey: String
    }

    var version = PersonalModel.currentVersion
    var claims: [PersonalClaim] = []
    var tombstones: [Tombstone] = []
    var workSightings: [WorkSighting] = []

    init(version: Int = PersonalModel.currentVersion, claims: [PersonalClaim] = [],
         tombstones: [Tombstone] = [], workSightings: [WorkSighting] = []) {
        self.version = version
        self.claims = claims
        self.tombstones = tombstones
        self.workSightings = workSightings
    }

    private enum CodingKeys: String, CodingKey { case version, claims, tombstones, workSightings }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? PersonalModel.currentVersion
        claims = try c.decodeIfPresent([PersonalClaim].self, forKey: .claims) ?? []
        tombstones = try c.decodeIfPresent([Tombstone].self, forKey: .tombstones) ?? []
        workSightings = try c.decodeIfPresent([WorkSighting].self, forKey: .workSightings) ?? []
    }

    static func tombstoneKey(_ text: String) -> String {
        SHA256.hash(data: Data(duplicateKey(text).utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Prompt-safe text, or why it can't be kept. Over-long text is refused
    /// rather than truncated: a cut sentence can drop a negation.
    static func validatedText(_ raw: String) -> Result<String, EditError> {
        let text = PromptContextSanitizer.sanitize(raw)
        guard !text.isEmpty else { return .failure(.empty) }
        guard text.count <= maxCharacters else { return .failure(.tooLong(text.count)) }
        guard ScreenContextPrivacy.redact(text).count == 0 else { return .failure(.looksSecret) }
        return .success(text)
    }

    /// Case-, width- and diacritic-insensitive key used to merge duplicates.
    static func duplicateKey(_ text: String) -> String {
        var key = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                               locale: nil)
        key = key.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        while key.hasSuffix(".") { key.removeLast() }
        return key
    }

    /// Adds a claim, or refreshes the existing one when the same text is
    /// already remembered. Saved claims are never evicted to make room.
    @discardableResult
    mutating func add(_ raw: String, kind: PersonalClaim.Kind, origin: PersonalClaim.Origin,
                      now: Date) -> Result<PersonalClaim, EditError> {
        let text: String
        switch Self.validatedText(raw) {
        case .success(let valid): text = valid
        case .failure(let error): return .failure(error)
        }
        let key = Self.duplicateKey(text)
        if let index = claims.firstIndex(where: { Self.duplicateKey($0.text) == key }) {
            // Saying what LokalBot learned makes it the person's statement.
            if claims[index].isLearned {
                claims[index].status = .confirmed
                claims[index].authority = .stated
                claims[index].evidence = nil
            }
            claims[index].updatedAt = now
            return .success(claims[index])
        }
        guard claims.filter({ $0.status == .confirmed }).count < Self.maxClaims else { return .failure(.full) }
        let claim = PersonalClaim(kind: kind, text: text, origin: origin, createdAt: now)
        claims.append(claim)
        return .success(claim)
    }

    @discardableResult
    mutating func update(id: UUID, text raw: String? = nil, kind: PersonalClaim.Kind? = nil,
                         alwaysUse: Bool? = nil, sharing: PersonalClaim.Sharing? = nil,
                         now: Date) -> Result<PersonalClaim, EditError> {
        guard let index = claims.firstIndex(where: { $0.id == id }) else { return .failure(.notFound) }
        var claim = claims[index]
        if let raw {
            switch Self.validatedText(raw) {
            case .success(let valid): claim.text = valid
            case .failure(let error): return .failure(error)
            }
            let key = Self.duplicateKey(claim.text)
            if claims.contains(where: { $0.id != id && Self.duplicateKey($0.text) == key }) {
                // Editing into an existing claim merges them: keep the edited
                // one, drop the older duplicate.
                claims.removeAll { $0.id != id && Self.duplicateKey($0.text) == key }
            }
        }
        if let kind { claim.kind = kind }
        if let alwaysUse { claim.alwaysUse = alwaysUse }
        if let sharing { claim.sharing = sharing }
        claim.updatedAt = now
        guard let current = claims.firstIndex(where: { $0.id == id }) else { return .failure(.notFound) }
        claims[current] = claim
        return .success(claim)
    }

    /// Forgetting a learned claim leaves a tombstone so tomorrow's review
    /// doesn't learn it again; stated claims leave nothing behind.
    mutating func remove(ids: Set<UUID>, now: Date = Date()) {
        for claim in claims where ids.contains(claim.id) && claim.isLearned && claim.authority != .stated {
            tombstones.append(Tombstone(key: Self.tombstoneKey(claim.text), createdAt: now))
        }
        claims.removeAll { ids.contains($0.id) }
    }

    /// Source deletion or correction: the claim goes, with no tombstone, so
    /// it can be learned again from evidence that still exists.
    mutating func retract(ids: Set<UUID>) {
        claims.removeAll { ids.contains($0.id) }
    }

    /// Deleting an Ask conversation takes back what was learned from the
    /// questions in it, unless the person kept it as their own statement.
    mutating func retract(learnedFromConversation conversationID: UUID) {
        claims.removeAll { claim in
            guard claim.authority != .stated,
                  case .typed(.ask(let id), _) = claim.origin else { return false }
            return id == conversationID
        }
    }

    struct LearningCandidate: Equatable, Sendable {
        var kind: PersonalClaim.Kind
        var text: String
        /// The person's own words it came from; nil for work memory.
        var quote: String?
        var origin: PersonalClaim.Origin
        /// Nil only for Ask questions, which retract with their conversation.
        var evidence: DreamEvidenceProvenance?
        /// From typing, from work memory, or grounded only by meaning across
        /// languages: even a fact or goal waits for the person's review.
        var needsReview = false

        init(kind: PersonalClaim.Kind, text: String, quote: String?, origin: PersonalClaim.Origin,
             evidence: DreamEvidenceProvenance?, needsReview: Bool = false) {
            self.kind = kind
            self.text = text
            self.quote = quote
            self.origin = origin
            self.evidence = evidence
            self.needsReview = needsReview
        }

        /// A line the person said in a meeting.
        init(kind: PersonalClaim.Kind, text: String, quote: String, meetingID: UUID, dayKey: String,
             evidence: DreamEvidenceProvenance, needsReview: Bool = false) {
            self.init(kind: kind, text: text, quote: quote, origin: .learned(meetingID: meetingID, dayKey: dayKey),
                      evidence: evidence, needsReview: needsReview)
        }
    }

    struct LearningOutcome: Equatable, Sendable {
        var saved: [PersonalClaim] = []
        var proposed: [PersonalClaim] = []
        var skipped = 0
    }

    /// Facts and goals are saved and used at once; preferences, and items
    /// grounded only by meaning across languages, wait for review;
    /// principles are never learned. Duplicates, forgotten or
    /// dismissed text, invalid text, and anything past the limits are skipped.
    @discardableResult
    mutating func learn(_ candidates: [LearningCandidate], now: Date) -> LearningOutcome {
        var outcome = LearningOutcome()
        for candidate in candidates {
            guard candidate.kind != .principle,
                  case .success(let text) = Self.validatedText(candidate.text) else {
                outcome.skipped += 1
                continue
            }
            let key = Self.duplicateKey(text)
            let tombstone = Self.tombstoneKey(text)
            guard !claims.contains(where: { Self.duplicateKey($0.text) == key || Self.isNearDuplicate($0.text, text) }),
                  !tombstones.contains(where: { $0.key == tombstone }) else {
                outcome.skipped += 1
                continue
            }
            let proposes = candidate.kind == .preference || candidate.needsReview
            let limitReached = proposes
                ? claims.filter { $0.status == .proposed }.count >= Self.maxProposals
                : claims.filter { $0.status == .confirmed }.count >= Self.maxClaims
            guard !limitReached else {
                outcome.skipped += 1
                continue
            }
            let claim = PersonalClaim(
                kind: candidate.kind, text: text, origin: candidate.origin,
                status: proposes ? .proposed : .confirmed, authority: .learned,
                evidence: candidate.evidence,
                quote: candidate.quote.map { String(PromptContextSanitizer.sanitize($0).prefix(400)) },
                createdAt: now)
            claims.append(claim)
            if proposes { outcome.proposed.append(claim) } else { outcome.saved.append(claim) }
        }
        return outcome
    }

    /// The same thing reworded: most content words of the shorter text appear
    /// in the other. Models restate known items despite being told not to.
    static func isNearDuplicate(_ lhs: String, _ rhs: String) -> Bool {
        let left = PersonalContextSelection.contentWords(lhs)
        let right = PersonalContextSelection.contentWords(rhs)
        let smaller = min(left.count, right.count)
        guard smaller > 0 else { return false }
        return Double(left.intersection(right).count) / Double(smaller) >= 0.7
    }

    /// Review of a learned suggestion: keep it as confirmed.
    @discardableResult
    mutating func confirm(id: UUID, now: Date) -> Result<PersonalClaim, EditError> {
        guard let index = claims.firstIndex(where: { $0.id == id }) else { return .failure(.notFound) }
        claims[index].status = .confirmed
        claims[index].authority = .confirmed
        claims[index].updatedAt = now
        return .success(claims[index])
    }

    /// Dismissing a suggestion: it goes and won't be suggested again.
    mutating func dismiss(id: UUID, now: Date) {
        remove(ids: [id], now: now)
    }

    /// The person vouches for a learned claim: it no longer depends on the
    /// meeting, so deleting that meeting keeps it.
    @discardableResult
    mutating func keepAsStatement(id: UUID, now: Date) -> Result<PersonalClaim, EditError> {
        guard let index = claims.firstIndex(where: { $0.id == id }) else { return .failure(.notFound) }
        claims[index].status = .confirmed
        claims[index].authority = .stated
        claims[index].evidence = nil
        claims[index].updatedAt = now
        return .success(claims[index])
    }

    /// Drops suggestions nobody reviewed and old tombstones.
    mutating func prune(now: Date) {
        claims.removeAll { $0.status == .proposed && now.timeIntervalSince($0.createdAt) > Self.proposalLifetime }
        tombstones.removeAll { now.timeIntervalSince($0.createdAt) > Self.tombstoneLifetime }
    }

    mutating func markUsed(ids: Set<UUID>, at date: Date) {
        for index in claims.indices where ids.contains(claims[index].id) {
            claims[index].lastUsedAt = date
        }
    }
}

/// Recognizes "Remember …" messages typed in Ask, in English and Serbian
/// (Latin and Cyrillic). Pure; Settings → Add works in any language.
enum RememberIntent {
    private static let triggers = [
        "please remember that ", "please remember: ", "please remember ",
        "remember that ", "remember: ", "remember:", "remember ",
        "molim te zapamti da ", "molim te zapamti ", "zapamti da ", "zapamti: ", "zapamti:", "zapamti ",
        "молим те запамти да ", "молим те запамти ", "запамти да ", "запамти: ", "запамти:", "запамти ",
    ]
    /// After these triggers a question word means the message asks about
    /// the past ("remember when …", "zapamti da li …") rather than stating
    /// something to keep.
    private static let questionCheckedTriggers: Set<String> = [
        "please remember ", "remember ",
        "molim te zapamti da ", "molim te zapamti ", "zapamti da ", "zapamti ",
        "молим те запамти да ", "молим те запамти ", "запамти да ", "запамти ",
    ]
    private static let questionOpenings: Set<String> = [
        "when", "what", "who", "whom", "whose", "where", "how", "why", "if", "whether", "which",
        "kad", "kada", "šta", "sta", "ko", "koga", "gde", "kako", "zašto", "zasto", "li", "koji", "koja",
        "кад", "када", "шта", "ко", "кога", "где", "како", "зашто", "ли", "који", "која",
    ]

    /// The statement to remember, or nil when the message is not a request
    /// to remember something (including every question about the past).
    static func parse(_ message: String) -> String? {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.hasSuffix("?") else { return nil }
        let lowered = trimmed.lowercased()
        guard let trigger = triggers.first(where: { lowered.hasPrefix($0) }) else { return nil }
        let remainder = String(trimmed.dropFirst(trigger.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !remainder.isEmpty else { return nil }
        if questionCheckedTriggers.contains(trigger) {
            let firstWord = remainder.split(whereSeparator: { !$0.isLetter }).first?.lowercased() ?? ""
            if questionOpenings.contains(firstWord) { return nil }
        }
        return remainder.prefix(1).uppercased() + remainder.dropFirst()
    }
}
