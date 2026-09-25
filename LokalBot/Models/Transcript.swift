import CryptoKit
import Foundation

/// Speaker-attributed transcript of a meeting. Persisted as `transcript.json`
/// next to the audio; rendered to `transcript.md` for human reading.
///
/// Lives in `Models/` (not `Engines/`) because the embedded `lokalbot-cli`
/// reads it without linking WhisperKit / FluidAudio. The transcription engines
/// fill it in, but it's just a data shape — no engine dependency.
struct Transcript: Codable {
    struct Segment: Codable, Equatable {
        enum TimingPrecision: String, Codable, Sendable {
            /// The text covers a fallback window or whole track; its words are
            /// not localized closely enough to support destructive filtering.
            case coarse
            /// The text was transcribed from a VAD/ASR speech span with real
            /// start and end boundaries.
            case span
            /// The boundaries were derived from timestamped ASR tokens.
            case token

            var isBleedFilterSafe: Bool { self == .span || self == .token }
        }

        var start: TimeInterval
        var end: TimeInterval
        var speaker: String      // "me" | "them" | diarized label
        var text: String
        var confidence: Double?
        /// Optional keeps older persisted transcripts source-compatible. A
        /// missing value is unknown and therefore never used for deletion.
        var timingPrecision: TimingPrecision?
        var attribution: SpeakerAttribution?

        var resolvedAttribution: SpeakerAttribution {
            (attribution ?? .legacy(speaker: speaker)).applyingMicrophoneDefault
        }
    }

    /// A bounded piece of one source segment used only for model prompts.
    /// Keeping its source boundary visible lets the model copy a quote and
    /// the exact ID that resolves that quote back to the transcript.
    struct PromptTurn: Equatable, Sendable {
        var start: TimeInterval
        var end: TimeInterval
        var speaker: String
        var text: String
        var sourceID: String
        var citationID: String
    }

    /// Immutable, UI-ready segment data. Building this value performs the
    /// control-token/whitespace normalization once when a transcript changes,
    /// instead of once per row on every playback timer tick.
    struct DisplaySegment: Equatable, Identifiable {
        let id: Int
        let segment: Segment
        let text: String
        let speakerLabel: String
        let speakerKey: String
        let hasSpeakerAlias: Bool
        let beginsSpeakerTurn: Bool
    }

    /// Cached transcript presentation plus a chronological interval index for
    /// playback highlighting. `segments` deliberately remains in source order;
    /// only the private lookup is sorted, so malformed/legacy files do not
    /// silently reorder what the user sees.
    struct DisplayIndex {
        let segments: [DisplaySegment]

        private struct Interval {
            let id: Int
            let start: TimeInterval
            let end: TimeInterval
        }

        private let intervals: [Interval]
        /// Maximum effective end among `intervals[0...index]`. This lets an
        /// active-segment query stop as soon as no earlier interval can overlap.
        private let prefixMaximumEnds: [TimeInterval]

        init(transcript: Transcript? = nil) {
            guard let transcript else {
                segments = []
                intervals = []
                prefixMaximumEnds = []
                return
            }

            let roster = transcript.speakerRoster
            var previousSpeaker: String?
            segments = transcript.segments.enumerated().compactMap { index, segment in
                let text = segment.displayText
                guard !text.isEmpty else { return nil }
                let speakerKey = Transcript.canonicalSpeakerKey(segment.speaker)
                let beginsSpeakerTurn = previousSpeaker != speakerKey
                previousSpeaker = speakerKey
                return DisplaySegment(
                    id: index,
                    segment: segment,
                    text: text,
                    speakerLabel: roster[speakerKey]?.name ?? Transcript.defaultSpeakerName(for: segment.speaker),
                    speakerKey: speakerKey,
                    hasSpeakerAlias: transcript.speakerAliases[speakerKey] != nil,
                    beginsSpeakerTurn: beginsSpeakerTurn)
            }

            intervals = segments.map { display in
                Interval(
                    id: display.id,
                    start: display.segment.start,
                    end: max(display.segment.end, display.segment.start + 0.5))
            }.sorted {
                if $0.start == $1.start { return $0.id < $1.id }
                return $0.start < $1.start
            }

            var maximumEnd = -TimeInterval.infinity
            prefixMaximumEnds = intervals.map { interval in
                maximumEnd = max(maximumEnd, interval.end)
                return maximumEnd
            }
        }

        /// IDs of all visible segments containing `time`. A binary search skips
        /// future segments, and the prefix maxima bound the backwards overlap
        /// scan. Returning every overlap preserves simultaneous-speaker
        /// highlighting from the previous per-row comparison.
        func activeSegmentIDs(at time: TimeInterval) -> Set<Int> {
            var lowerBound = 0
            var upperBound = intervals.count
            while lowerBound < upperBound {
                let middle = lowerBound + (upperBound - lowerBound) / 2
                if intervals[middle].start <= time {
                    lowerBound = middle + 1
                } else {
                    upperBound = middle
                }
            }

            var active: Set<Int> = []
            var index = lowerBound - 1
            while index >= 0, prefixMaximumEnds[index] > time {
                let interval = intervals[index]
                if time < interval.end {
                    active.insert(interval.id)
                }
                index -= 1
            }
            return active
        }
    }

    var segments: [Segment]
    var engine: String
    /// Per-meeting display-name overrides keyed by the stable speaker label
    /// stored on each segment, e.g. "them 2" -> "Ana".
    var speakerAliases: [String: String]
    /// Opaque calendar-participant IDs selected for speaker aliases. Email
    /// addresses remain in meeting metadata and never enter the transcript.
    var speakerCalendarIdentityIDs: [String: String]
    var echoReport: TranscriptEchoReport?

    init(
        segments: [Segment],
        engine: String,
        speakerAliases: [String: String] = [:],
        speakerCalendarIdentityIDs: [String: String] = [:],
        echoReport: TranscriptEchoReport? = nil
    ) {
        self.echoReport = echoReport
        self.segments = segments
        self.engine = engine
        self.speakerAliases = Self.normalizedAliases(speakerAliases)
        self.speakerCalendarIdentityIDs = Self.normalizedIdentityAssignments(
            speakerCalendarIdentityIDs)
    }

    private enum CodingKeys: String, CodingKey {
        case segments, engine, speakerAliases, speakerCalendarIdentityIDs, echoReport
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        echoReport = try container.decodeIfPresent(TranscriptEchoReport.self, forKey: .echoReport)
        segments = try container.decode([Segment].self, forKey: .segments)
        engine = try container.decode(String.self, forKey: .engine)
        let decodedAliases = try container.decodeIfPresent([String: String].self, forKey: .speakerAliases) ?? [:]
        speakerAliases = Self.normalizedAliases(decodedAliases)
        let decodedIdentityIDs = try container.decodeIfPresent(
            [String: String].self,
            forKey: .speakerCalendarIdentityIDs) ?? [:]
        speakerCalendarIdentityIDs = Self.normalizedIdentityAssignments(decodedIdentityIDs)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(segments, forKey: .segments)
        try container.encodeIfPresent(echoReport, forKey: .echoReport)
        try container.encode(engine, forKey: .engine)
        if !speakerAliases.isEmpty {
            try container.encode(speakerAliases, forKey: .speakerAliases)
        }
        if !speakerCalendarIdentityIDs.isEmpty {
            try container.encode(
                speakerCalendarIdentityIDs,
                forKey: .speakerCalendarIdentityIDs)
        }
    }

    /// Renders `transcript.md` — "[00:14:32] **Me:** …"
    var markdown: String {
        let roster = speakerRoster
        return segments.compactMap { seg in
            let text = seg.displayText
            guard !text.isEmpty else { return nil }
            let name = roster[Self.canonicalSpeakerKey(seg.speaker)]?.name ?? Self.defaultSpeakerName(for: seg.speaker)
            return "**[\(Self.stamp(seg.start))] \(name):** \(text)"
        }.joined(separator: "\n\n")
    }

    /// Stable source IDs used by outcome extraction and evidence links. The ID
    /// is derived from immutable source order and timing, so re-opening the same
    /// transcript resolves citations without adding migration-only fields to
    /// every legacy segment.
    func segmentID(at index: Int) -> String {
        guard segments.indices.contains(index) else { return "segment-invalid" }
        let segment = segments[index]
        return String(
            format: "segment-%04d-%010lld-%010lld",
            index,
            Int64((segment.start * 1_000).rounded()),
            Int64((segment.end * 1_000).rounded()))
    }

    var evidenceRevision: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(self)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    var segmentSourceMap: [String: Segment] {
        Dictionary(uniqueKeysWithValues: segments.indices.map { (segmentID(at: $0), segments[$0]) })
    }

    /// Short prompt references avoid asking a model to reproduce long timing
    /// IDs. Resolution always uses this exact transcript snapshot; persisted
    /// claims and audio links retain the original stable segment IDs.
    func summaryCitationID(at index: Int) -> String { "s\(index + 1)" }

    var summaryCitationSources: [String: String] {
        Dictionary(uniqueKeysWithValues: segments.indices.map { (summaryCitationID(at: $0), segmentID(at: $0)) })
    }

    /// Source-ready transcript for grounded extraction. IDs appear in the
    /// exact notation required by the schema so the model can only cite known
    /// segments that LokalBot can resolve back to audio.
    var evidenceMarkdown: String {
        let roster = speakerRoster
        return segments.enumerated().compactMap { index, segment in
            let text = segment.displayText
            guard !text.isEmpty else { return nil }
            return "[\(segmentID(at: index))] [\(Self.stamp(segment.start))] "
                + "\(promptSpeaker(for: segment.speaker, roster: roster)): \(text)"
        }.joined(separator: "\n\n")
    }

    /// Plain spoken text used for language detection and similar NLP passes.
    /// Keep timestamps, speaker labels, and Markdown out of the sample: Apple's
    /// language recognizer can over-weight that short formatting noise.
    var languageDetectionText: String {
        segments.compactMap { seg in
            let text = seg.displayText
            return text.isEmpty ? nil : text
        }.joined(separator: " ")
    }

    /// Preserve each source boundary even for consecutive same-speaker spans.
    /// A pathological/legacy span is split at word boundaries, retaining its
    /// source ID so downstream token-aware chunking has safe split points.
    func summaryPromptTurns(
        maxCharacters: Int = 1_200
    ) -> [PromptTurn] {
        let characterLimit = max(200, maxCharacters)
        var turns: [PromptTurn] = []

        for (segmentIndex, segment) in segments.enumerated() {
            let text = segment.displayText
            guard !text.isEmpty else { continue }
            for part in Self.summaryTextParts(text, maxCharacters: characterLimit) {
                turns.append(PromptTurn(
                    start: segment.start,
                    end: segment.end,
                    speaker: segment.speaker,
                    text: part, sourceID: segmentID(at: segmentIndex), citationID: summaryCitationID(at: segmentIndex)))
            }
        }
        return turns
    }

    var summaryPromptMarkdown: String {
        summaryPromptLines(summaryPromptTurns()).joined(separator: "\n\n")
    }

    func summaryPromptLines(_ turns: [PromptTurn]) -> [String] {
        let roster = speakerRoster
        return turns.map { summaryPromptLine($0, roster: roster) }
    }

    func summaryPromptLine(_ turn: PromptTurn) -> String { summaryPromptLine(turn, roster: speakerRoster) }

    func summaryPromptLine(_ turn: PromptTurn, roster: [String: SpeakerDescriptor]) -> String {
        "[\(turn.citationID)] **[\(Self.stamp(turn.start))] \(promptSpeaker(for: turn.speaker, roster: roster)):** \(turn.text)"
    }

    /// Merge per-track transcripts (mic = "me", system = "them") by timestamp.
    static func merged(_ tracks: [Transcript]) -> Transcript {
        Transcript(
            segments: tracks.flatMap(\.segments).compactMap { segment in
                var normalized = segment
                normalized.text = segment.displayText
                return normalized.text.isEmpty ? nil : normalized
            }.sorted { $0.start < $1.start },
            engine: tracks.first?.engine ?? "unknown",
            echoReport: tracks.compactMap(\.echoReport).first)
    }

    struct SpeakerDescriptor: Equatable, Sendable {
        var id: String
        var name: String
        var identity: SpeakerAttribution.Identity
    }

    var speakerRoster: [String: SpeakerDescriptor] {
        Dictionary(grouping: segments, by: { Self.canonicalSpeakerKey($0.speaker) }).mapValues { group in
            let key = Self.canonicalSpeakerKey(group[0].speaker)
            let identity = Self.speakerIdentity(of: group)
            return SpeakerDescriptor(id: key, name: speakerName(for: key, identity: identity), identity: identity)
        }
    }

    /// Mixed voices and suspected echo are not the labelled speaker's own
    /// voice, so they cannot outvote that speaker's identity. They remain
    /// unresolved individually and cannot prove ownership.
    static func speakerIdentity(of group: [Segment]) -> SpeakerAttribution.Identity {
        let identities = Set(group.map(\.resolvedAttribution)
            .filter { ![.overlappingSpeech, .suspectedEcho].contains($0.method) }
            .map(\.identity))
        return identities.count == 1 ? identities.first! : .unresolved
    }

    var confirmedUserSpeakerIDs: Set<String> {
        Set(speakerRoster.values.filter { $0.identity == .user }.map(\.id))
    }

    var userSpeakerLabel: String {
        let labels = confirmedUserSpeakerIDs.sorted()
        return labels.isEmpty ? "User identity not confirmed" : labels.joined(separator: ", ")
    }

    func promptSpeaker(for speaker: String, roster: [String: SpeakerDescriptor]? = nil) -> String {
        let key = Self.canonicalSpeakerKey(speaker)
        let person = (roster ?? speakerRoster)[key]
        return "[speaker_id=\(key); identity=\((person?.identity ?? .unresolved).rawValue)] \(person?.name ?? Self.defaultSpeakerName(for: speaker))"
    }

    mutating func confirmSpeaker(_ speaker: String, isUser: Bool?) {
        let key = Self.canonicalSpeakerKey(speaker)
        for index in segments.indices where Self.canonicalSpeakerKey(segments[index].speaker) == key {
            var value = segments[index].resolvedAttribution
            // The microphone default is correctable even without diarization.
            // Mixed voices and suspected echo still cannot name one person.
            guard value.canConfirmIdentity else { continue }
            value.identity = isUser.map { $0 ? .user : .other } ?? .unresolved
            value.method = isUser == nil ? .diarization : .confirmation
            segments[index].attribution = value
        }
    }

    func canConfirmSpeaker(_ speaker: String) -> Bool {
        let key = Self.canonicalSpeakerKey(speaker)
        let turns = segments.filter { Self.canonicalSpeakerKey($0.speaker) == key }
        return Self.canConfirmIdentity(in: turns)
    }

    static func canConfirmIdentity(in turns: [Segment]) -> Bool {
        return !turns.isEmpty && turns.allSatisfy {
            $0.resolvedAttribution.canConfirmIdentity
        }
    }

    static func isPlaceholderSpeakerName(_ name: String) -> Bool {
        name.range(of: #"^(?:Them(?: \d+)?|Speaker(?: \d+| unclear)?|Local speaker)$"#,
                   options: [.regularExpression, .caseInsensitive]) != nil
    }

    func displaySpeaker(for speaker: String) -> String {
        let key = Self.canonicalSpeakerKey(speaker)
        if let alias = speakerAliases[key] { return alias }
        return speakerName(for: key, identity: Self.speakerIdentity(
            of: segments.filter { Self.canonicalSpeakerKey($0.speaker) == key }))
    }

    private func speakerName(for key: String, identity: SpeakerAttribution.Identity) -> String {
        if let alias = speakerAliases[key] { return alias }
        if identity == .user { return "Me" }
        return key == "me" ? "Local speaker" : Self.defaultSpeakerName(for: key)
    }

    mutating func setSpeakerAlias(
        _ alias: String?,
        for speaker: String,
        calendarIdentityID: String? = nil
    ) {
        let key = Self.canonicalSpeakerKey(speaker)
        guard !key.isEmpty else { return }
        guard let alias = Self.normalizedAlias(alias ?? ""),
              alias.caseInsensitiveCompare(Self.defaultSpeakerName(for: speaker)) != .orderedSame
        else {
            speakerAliases.removeValue(forKey: key)
            speakerCalendarIdentityIDs.removeValue(forKey: key)
            return
        }
        speakerAliases[key] = alias
        if let identityID = Self.normalizedIdentityID(calendarIdentityID ?? "") {
            speakerCalendarIdentityIDs[key] = identityID
        } else {
            speakerCalendarIdentityIDs.removeValue(forKey: key)
        }
    }

    func speakerAlias(for speaker: String) -> String? {
        speakerAliases[Self.canonicalSpeakerKey(speaker)]
    }

    func calendarIdentityID(for speaker: String) -> String? {
        speakerCalendarIdentityIDs[Self.canonicalSpeakerKey(speaker)]
    }

    static func defaultSpeakerName(for speaker: String) -> String {
        let trimmed = speaker.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Speaker" }
        switch canonicalSpeakerKey(trimmed) {
        case "them": return "Them"
        case "me": return "Me"
        case "local": return "Local speaker"
        case "local unclear", "them unclear": return "Speaker unclear"
        default: return trimmed.capitalized
        }
    }

    static func canonicalSpeakerKey(_ speaker: String) -> String {
        speaker.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func normalizedAlias(_ alias: String) -> String? {
        let collapsed = alias.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return collapsed.isEmpty ? nil : collapsed
    }

    private static func normalizedIdentityAssignments(
        _ assignments: [String: String]
    ) -> [String: String] {
        var result: [String: String] = [:]
        for (speaker, identityID) in assignments {
            let key = canonicalSpeakerKey(speaker)
            guard !key.isEmpty, let identityID = normalizedIdentityID(identityID) else {
                continue
            }
            result[key] = identityID
        }
        return result
    }

    private static func normalizedIdentityID(_ identityID: String) -> String? {
        let trimmed = identityID.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func normalizedAliases(_ aliases: [String: String]) -> [String: String] {
        var result: [String: String] = [:]
        for (key, value) in aliases {
            let canonical = canonicalSpeakerKey(key)
            guard !canonical.isEmpty, let alias = normalizedAlias(value) else { continue }
            result[canonical] = alias
        }
        return result
    }

    private static func summaryTextParts(
        _ text: String,
        maxCharacters: Int
    ) -> [String] {
        let words = text.split(whereSeparator: { $0.isWhitespace })
        guard !words.isEmpty else { return [] }
        var parts: [String] = []
        var current = ""

        func appendCurrent() {
            guard !current.isEmpty else { return }
            parts.append(current)
            current = ""
        }

        for wordSlice in words {
            var word = String(wordSlice)
            while word.count > maxCharacters {
                appendCurrent()
                let splitIndex = word.index(word.startIndex, offsetBy: maxCharacters)
                parts.append(String(word[..<splitIndex]))
                word = String(word[splitIndex...])
            }
            let proposedCount = current.count + (current.isEmpty ? 0 : 1) + word.count
            if proposedCount > maxCharacters { appendCurrent() }
            current += (current.isEmpty ? "" : " ") + word
        }
        appendCurrent()
        return parts
    }

    static func stamp(_ t: TimeInterval) -> String {
        let s = Int(t)
        return String(format: "%02d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }

    /// Whisper-family models can emit control/timestamp tokens as plain text.
    /// Persist and render only the human transcript text.
    static func normalizedText(_ raw: String) -> String {
        let withoutControlTokens = raw.replacingOccurrences(
            of: #"<\|[^>]*\|>"#,
            with: " ",
            options: .regularExpression)
        let collapsedWhitespace = withoutControlTokens.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard collapsedWhitespace.rangeOfCharacter(from: .alphanumerics) != nil else {
            return ""
        }
        return collapsedWhitespace
    }
}

extension Transcript.Segment {
    var displayText: String {
        Transcript.normalizedText(text)
    }
}
