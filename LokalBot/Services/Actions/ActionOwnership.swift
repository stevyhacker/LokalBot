import Foundation

/// Decides whose task an extracted action is, from the speech it cites.
///
/// Identity comes from the voice: the cited row's speaker, as attributed by
/// the transcript. The model's owner, basis and quote are claims to check,
/// never proof. A task belongs to a speaker when that speaker's own words
/// around the cited rows undertake it, and to nobody when those words are a
/// question, a negation, or someone else's job.
struct ActionOwnership {
    struct Claim {
        /// Speaker key the model named, nil when it said "source" or "unknown".
        var owner: String?
        /// The model said the cited speaker owns the task.
        var namesSource: Bool
        var basis: String
        var quote: String?
        var task: String
    }

    struct Finding {
        var attribution: OutcomeAttribution
        /// Transcript index of the cited row the ownership evidence belongs to.
        var anchor: Int
        /// The cited rows carry a speaker's own undertaking.
        var citesUndertaking = false
        /// The only undertakings in the cited rows are negated, questions,
        /// or reported speech.
        var citesOnlyRefusedUndertakings = false
        /// The speech around the cited rows looks forward at all.
        var looksForward = false
    }

    /// Echo-marked transcript: suspected echo cannot prove ownership.
    let transcript: Transcript
    let roster: [String: Transcript.SpeakerDescriptor]
    /// Wording checks read English; elsewhere the model's claim stands in.
    let isEnglish: Bool
    /// Text a row offers as evidence, nil when the row is outside this evidence.
    let text: (Int) -> String?

    private static let rowsBefore = 8
    private static let rowsAfter = 3
    private static let longestPause: TimeInterval = 4
    private static let carryOverSeconds: TimeInterval = 30
    private static let replySeconds: TimeInterval = 15

    /// One voice's consecutive rows around a cited row.
    private struct Turn {
        var rows: [Int]
        var words: [SpokenUndertaking.Word]
        var cues: [SpokenUndertaking.Cue]
        var actors: [SpokenUndertaking.Actor]

        func row(of word: Int) -> Int { rows[words[word].row] }
        func wordRange(inRow row: Int) -> Range<Int> {
            guard let position = rows.firstIndex(of: row),
                  let first = words.firstIndex(where: { $0.row == position }),
                  let last = words.lastIndex(where: { $0.row == position }) else { return 0..<0 }
            return first..<(last + 1)
        }
        /// Last word of a cue's sentence, across the rows it was cut over:
        /// "My side, I'll." / "Try to." / "update the tickets." is one
        /// sentence in three rows. Unpunctuated speech is followed for a
        /// dozen words.
        func sentenceEnd(of cue: SpokenUndertaking.Cue) -> Int {
            var end = cue.words.upperBound - 1
            var crossed = 0
            while end + 1 < words.count, crossed < 12 {
                if words[end].endsSentence, !SpokenUndertaking.isDangling(words[end].text) { break }
                end += 1
                crossed += 1
            }
            return end
        }
        func reach(of cue: SpokenUndertaking.Cue) -> Int { row(of: sentenceEnd(of: cue)) }
        /// The cue's sentence as transcribed, rows joined.
        func spoken(_ cue: SpokenUndertaking.Cue, text: (Int) -> String?) -> String {
            func closes(_ index: Int) -> Bool { words[index].endsSentence && !SpokenUndertaking.isDangling(words[index].text) }
            var start = cue.words.lowerBound
            while start > 0, words[start - 1].row == words[start].row, !closes(start - 1) { start -= 1 }
            var end = sentenceEnd(of: cue)
            // A cut reached mid-row is read to the end of that row.
            while end + 1 < words.count, words[end + 1].row == words[end].row, !closes(end) { end += 1 }
            var parts: [String] = []
            for position in Set(words[start...end].map(\.row)).sorted() {
                guard let source = text(rows[position]),
                      let first = words[start...end].first(where: { $0.row == position }),
                      let last = words[start...end].last(where: { $0.row == position }) else { continue }
                let upper = source[last.range.upperBound...].firstIndex(where: \.isWhitespace) ?? source.endIndex
                parts.append(String(source[first.range.lowerBound..<upper]))
            }
            return String(parts.joined(separator: " ").prefix(1_000))
        }
        /// Words from a subject to the next subject or the end of its
        /// sentence: the task that subject took.
        func clause(from start: Int) -> ArraySlice<SpokenUndertaking.Word> {
            let starts = cues.map(\.words.lowerBound) + actors.map(\.start)
            let next = starts.filter { $0 > start }.min() ?? words.count
            let close = words[start..<next].firstIndex { $0.endsSentence && !SpokenUndertaking.isDangling($0.text) }
            return words[start..<(close.map { $0 + 1 } ?? next)]
        }
        /// The sentence a row belongs to, across the cuts around it.
        func sentence(around row: Int) -> ArraySlice<SpokenUndertaking.Word> {
            let range = wordRange(inRow: row)
            guard !range.isEmpty else { return words[0..<0] }
            func closes(_ index: Int) -> Bool { words[index].endsSentence && !SpokenUndertaking.isDangling(words[index].text) }
            var start = range.lowerBound
            while start > 0, range.lowerBound - start < 12, !closes(start - 1) { start -= 1 }
            var end = range.upperBound
            while end < words.count, end - range.upperBound < 12, !closes(end - 1) { end += 1 }
            return words[start..<end]
        }
    }

    private struct Candidate {
        var turn: Turn
        var cue: SpokenUndertaking.Cue
        var row: Int
        var speaker: String
        var quoted = false
    }

    // MARK: - Voices

    private func key(_ index: Int) -> String { Transcript.canonicalSpeakerKey(transcript.segments[index].speaker) }

    private func isOwnVoice(_ index: Int) -> Bool {
        ![.overlappingSpeech, .suspectedEcho].contains(transcript.segments[index].resolvedAttribution.method)
    }

    /// Rows of one person. Every row confirmed as the user's is the user, even
    /// when diarization filed some under another microphone label.
    private func sameVoice(_ lhs: Int, _ rhs: Int) -> Bool {
        isOwnVoice(lhs) && isOwnVoice(rhs) && sameVoice(key(lhs), rhs)
    }

    private func sameVoice(_ speaker: String, _ index: Int) -> Bool {
        speaker == key(index) || (roster[speaker]?.identity == .user && roster[key(index)]?.identity == .user)
    }

    /// A short remark from someone else does not end a speaker's turn, and
    /// neither does text no one could have said in the time it spans.
    private func isInterjection(_ index: Int) -> Bool {
        let segment = transcript.segments[index]
        let duration = segment.end - segment.start
        let words = segment.displayText.split(whereSeparator: \.isWhitespace).count
        return duration <= 1 || words <= 3 || Double(words) / duration > 6
    }

    private func turn(around index: Int, rowsBefore: Int = ActionOwnership.rowsBefore,
                      rowsAfter: Int = ActionOwnership.rowsAfter) -> Turn {
        var rows = [index]
        var cursor = index - 1
        while cursor >= 0, rows.count <= rowsBefore {
            if sameVoice(cursor, index), text(cursor) != nil {
                guard transcript.segments[rows[0]].start - transcript.segments[cursor].end <= Self.longestPause else { break }
                rows.insert(cursor, at: 0)
            } else if !isInterjection(cursor) { break }
            cursor -= 1
        }
        var last = index
        cursor = index + 1
        var added = 0
        while cursor < transcript.segments.count, added < rowsAfter {
            if sameVoice(cursor, index), text(cursor) != nil {
                guard transcript.segments[cursor].start - transcript.segments[last].end <= Self.longestPause else { break }
                rows.append(cursor)
                last = cursor
                added += 1
            } else if !isInterjection(cursor) { break }
            cursor += 1
        }
        let words = SpokenUndertaking.words(rows.map { text($0) ?? "" })
        return Turn(rows: rows, words: words, cues: SpokenUndertaking.cues(in: words),
                    actors: SpokenUndertaking.otherActors(in: words))
    }

    // MARK: - Evidence

    /// The speaker's own unrefused commitment starts in this row.
    func statesCommitment(at index: Int) -> Bool {
        guard isOwnVoice(index), text(index) != nil else { return false }
        let turn = turn(around: index, rowsBefore: 1, rowsAfter: 2)
        return turn.cues.contains { $0.isAccepted && $0.grade == .commitment && turn.row(of: $0.words.lowerBound) == index }
    }

    func resolve(_ claim: Claim, primary: Int, context: [Int], quotedRow: Int?, userReply: String?) -> Finding {
        let cited = [primary] + context.filter { $0 != primary }
        let anchor = quotedRow ?? primary
        let anchorSpeaker = key(anchor)
        var targetFailure: OutcomeAttribution?
        if ["request", "assignment"].contains(claim.basis) {
            let target = OutcomeEvidencePolicy.resolveTarget(
                speakerID: claim.owner ?? userReply, basis: claim.basis, source: transcript.segments[anchor],
                visibleText: text(anchor) ?? "", roster: roster, addressedToUser: userReply != nil, quote: claim.quote)
            if target.resolution != .unresolved { return Finding(attribution: target, anchor: anchor) }
            targetFailure = target
        }

        var turns: [Turn] = []
        for row in cited where isOwnVoice(row) && !turns.contains(where: { $0.rows.contains(row) }) {
            turns.append(turn(around: row))
        }
        // Undertakings the cited rows carry: said in a cited row, or in a
        // sentence that runs into one.
        var candidates: [Candidate] = []
        var refused = false
        var looksForward = false
        var quoteHits = 0
        for turn in turns {
            for row in cited where turn.rows.contains(row) {
                let sentence = turn.sentence(around: row).map(\.text).joined(separator: " ")
                looksForward = looksForward || OutcomeEvidencePolicy.expressesUndertaking(sentence)
            }
            let quoted = claim.quote.map { SpokenUndertaking.occurrences(of: $0, in: turn.words) } ?? []
            quoteHits += quoted.count
            for cue in turn.cues {
                let row = turn.row(of: cue.words.lowerBound)
                let reach = turn.reach(of: cue)
                guard cited.contains(where: { $0 >= row && $0 <= reach && turn.rows.contains($0) }) else { continue }
                guard cue.isAccepted else {
                    if cited.contains(row), [.negated, .question, .reported, .unfulfilled].contains(cue.refusal) { refused = true }
                    continue
                }
                // An undertaking the model did not cite must plainly be about
                // this task before it can own it.
                let sentence = turn.words[cue.words.lowerBound..<max(cue.words.upperBound, turn.wordRange(inRow: reach).upperBound)]
                guard cited.contains(row) || SpokenUndertaking.alignment(task: claim.task, clause: sentence).isAboutTask else { continue }
                let isQuoted = row == quotedRow || quoted.contains { hit in
                    (turn.row(of: hit.lowerBound)...turn.row(of: hit.upperBound - 1)).overlaps(row...reach)
                }
                candidates.append(Candidate(turn: turn, cue: cue, row: row, speaker: key(row), quoted: isQuoted))
            }
        }
        // The quoted words choose among several undertakings.
        if candidates.contains(where: \.quoted) { candidates.removeAll { !$0.quoted } }
        if let quotedRow, candidates.contains(where: { $0.row == quotedRow }) { candidates.removeAll { $0.row != quotedRow } }
        var finding = Finding(attribution: unresolved(.missingBasis, speaker: claim.owner ?? anchorSpeaker), anchor: anchor,
                              citesUndertaking: !candidates.isEmpty,
                              citesOnlyRefusedUndertakings: candidates.isEmpty && refused, looksForward: looksForward)

        // Of one speaker's undertakings, the one that reads most like the
        // task; then the one nearest the row the model called its source.
        func alignment(_ candidate: Candidate) -> SpokenUndertaking.Alignment {
            SpokenUndertaking.alignment(task: claim.task, clause: candidate.turn.clause(from: candidate.cue.words.lowerBound))
        }
        let ranked = candidates.map { ($0, alignment($0)) }.min { lhs, rhs in
            if lhs.1.leads != rhs.1.leads { return lhs.1.leads }
            if lhs.1.matches != rhs.1.matches { return lhs.1.matches > rhs.1.matches }
            return abs(lhs.0.row - primary) < abs(rhs.0.row - primary)
        }
        if let chosen = ranked?.0 {
            // Two people undertaking something in the cited rows: only the
            // model's quote can say whose task this is.
            guard candidates.allSatisfy({ sameVoice($0.speaker, chosen.row) }) else {
                finding.attribution = unresolved(.ambiguousQuote, speaker: claim.owner ?? anchorSpeaker)
                return finding
            }
            finding.anchor = cited.contains(chosen.row) ? chosen.row
                : cited.first { $0 >= chosen.row && $0 <= chosen.turn.reach(of: chosen.cue) } ?? anchor
            finding.attribution = attribution(for: chosen, claim: claim, primary: primary, turns: turns, targetFailure: targetFailure)
            return finding
        }

        let claimsSource = claim.basis == "commitment" && (claim.namesSource || claim.owner.map { sameVoice($0, anchor) } == true)
        if claimsSource, isOwnVoice(anchor), let person = roster[anchorSpeaker] {
            if person.identity == .unresolved {
                finding.attribution = unresolved(.unconfirmedIdentity, speaker: anchorSpeaker)
                return finding
            }
            if isEnglish {
                // The speaker said "I'll…" a moment earlier and kept listing
                // their own work in fragments.
                if !refused, let carried = carriedUndertaking(into: anchor, cited: cited, task: claim.task, turns: turns) {
                    finding.attribution = OutcomeAttribution(resolution: person.identity == .user ? .user : .other,
                        speakerID: anchorSpeaker, basis: .commitment, quote: carried)
                    return finding
                }
            } else if text(anchor)?.contains("?") != true {
                finding.attribution = OutcomeAttribution(resolution: person.identity == .user ? .user : .other,
                    speakerID: anchorSpeaker, basis: .commitment, quote: exactQuote(claim.quote, in: anchor))
                return finding
            }
        }

        if let targetFailure {
            finding.attribution = targetFailure
        } else if let quote = claim.quote, !quote.isEmpty, quoteHits == 0, !cited.contains(where: { exactQuote(quote, in: $0) != nil }) {
            finding.attribution = unresolved(.quoteNotFound, speaker: claim.owner ?? anchorSpeaker)
        } else if refused {
            finding.attribution = unresolved(.unsupportedCommitment, speaker: claim.owner ?? anchorSpeaker)
        } else if claim.basis == "commitment", let owner = claim.owner, !sameVoice(owner, anchor) {
            finding.attribution = unresolved(.speakerMismatch, speaker: owner)
        }
        return finding
    }

    private func attribution(for chosen: Candidate, claim: Claim, primary: Int, turns: [Turn],
                             targetFailure: OutcomeAttribution?) -> OutcomeAttribution {
        guard let person = roster[chosen.speaker] else { return unresolved(.unknownSpeaker, speaker: nil) }
        guard person.identity != .unresolved else { return unresolved(.unconfirmedIdentity, speaker: chosen.speaker) }
        let turn = chosen.turn
        let own = SpokenUndertaking.alignment(task: claim.task, clause: turn.clause(from: chosen.cue.words.lowerBound))
        // The model named someone else, or called this a request. The voice
        // wins only when the task is plainly the one this speaker took on.
        let contradictsClaim = targetFailure != nil || claim.owner.map { !sameVoice($0, chosen.row) } == true
        if contradictsClaim, !own.isAboutTask {
            return targetFailure ?? unresolved(.speakerMismatch, speaker: claim.owner)
        }
        // Who the row the model called the source gives work to.
        let primaryTurn = turns.first { $0.rows.contains(primary) }
        let handedOver = primaryTurn.map { turn in
            turn.actors.filter { turn.row(of: $0.start) == primary }.map { turn.clause(from: $0.start) }
        } ?? []
        if chosen.row != primary {
            // The undertaking is not where the model said the task is. It
            // must share words with the task, answer the request, or be the
            // model's quoted choice when the source row is one person's ask.
            let ownsInPrimary = primaryTurn.map { turn in
                turn.cues.contains { $0.isAccepted && turn.row(of: $0.words.lowerBound) == primary }
            } ?? false
            let mixedSource = handedOver.count + (ownsInPrimary ? 1 : 0) > 1
            guard own.isAboutTask || (chosen.quoted && !mixedSource) || answersPrimary(chosen, primary: primary) else {
                return unresolved(.ambiguousQuote, speaker: chosen.speaker)
            }
        }
        // "I'll prepare the policy, and you will send the measurements":
        // sending the measurements is not this speaker's task.
        let inTurn = turn.rows.contains(primary)
        let last = max(turn.reach(of: chosen.cue), inTurn ? primary : chosen.row)
        let first = min(chosen.row, inTurn ? primary : chosen.row)
        let rivals = turn.actors.filter { (first...last).contains(turn.row(of: $0.start)) }.map { turn.clause(from: $0.start) }
            + (!inTurn && sameVoice(chosen.speaker, primary) ? handedOver : [])
        if !rivals.isEmpty {
            var theirs = SpokenUndertaking.Alignment()
            for rival in rivals {
                let alignment = SpokenUndertaking.alignment(task: claim.task, clause: rival)
                if alignment.leads != theirs.leads ? alignment.leads : alignment.matches > theirs.matches { theirs = alignment }
            }
            let mine = turn.cues.filter(\.isAccepted).map {
                SpokenUndertaking.alignment(task: claim.task, clause: turn.clause(from: $0.words.lowerBound))
            }.max { $0.leads != $1.leads ? !$0.leads : $0.matches < $1.matches } ?? own
            let wins = mine.leads != theirs.leads ? mine.leads : mine.matches > theirs.matches
            guard wins else { return unresolved(.ambiguousQuote, speaker: chosen.speaker) }
        }
        // The stored quote is what was said, whole: a model's quote can clip
        // a condition or tidy a stumble.
        return OutcomeAttribution(resolution: person.identity == .user ? .user : .other,
                                  speakerID: chosen.speaker, basis: .commitment, quote: turn.spoken(chosen.cue, text: text))
    }

    /// "Could you send the draft?" / "Yeah, I can do that", or "What I have
    /// left is the review." / "So I'll do that today": the undertaking takes
    /// on what the source row described, without naming it.
    private func answersPrimary(_ chosen: Candidate, primary: Int) -> Bool {
        guard chosen.cue.namesNoTask, chosen.row > primary else { return false }
        var end = transcript.segments[primary].end
        for row in (primary + 1)..<chosen.row {
            if sameVoice(key(primary), row) { end = max(end, transcript.segments[row].end); continue }
            guard !isOwnVoice(row) || isInterjection(row) || sameVoice(chosen.speaker, row) else { return false }
        }
        return transcript.segments[chosen.row].start - end <= Self.replySeconds
    }

    /// The nearest undertaking earlier in the same turn, when the cited row
    /// is a fragment of that speech and nothing in between is about anyone
    /// else. A whole sentence of its own ("The deck is already shared.")
    /// inherits nothing.
    private func carriedUndertaking(into anchor: Int, cited: [Int], task: String, turns: [Turn]) -> String? {
        guard let turn = turns.first(where: { $0.rows.contains(anchor) }),
              text(anchor)?.contains("?") != true else { return nil }
        let anchorWords = turn.wordRange(inRow: anchor)
        guard let last = turn.words[anchorWords].last,
              anchorWords.count <= 3 || !last.endsSentence || SpokenUndertaking.isDangling(last.text) else { return nil }
        // The cited rows must at least be about this task.
        let spoken = cited.filter(turn.rows.contains).flatMap { turn.words[turn.wordRange(inRow: $0)] }
        guard SpokenUndertaking.alignment(task: task, clause: spoken).isAboutTask,
              let cue = turn.cues.last(where: { $0.isAccepted && $0.words.upperBound <= anchorWords.lowerBound }) else { return nil }
        let row = turn.row(of: cue.words.lowerBound)
        let others: Set<String> = ["you", "your", "we", "us", "our", "they", "them", "their", "he", "she", "him", "her", "his"]
        guard transcript.segments[anchor].start - transcript.segments[row].start <= Self.carryOverSeconds,
              !turn.actors.contains(where: { $0.start > cue.words.lowerBound && $0.start < anchorWords.upperBound }),
              !turn.words[cue.words.upperBound..<anchorWords.upperBound].contains(where: { others.contains($0.text) }),
              !turn.cues.contains(where: { !$0.isAccepted && $0.words.lowerBound > cue.words.lowerBound
                  && $0.words.lowerBound < anchorWords.upperBound }),
              !OutcomeEvidencePolicy.isNegatedOrQuestioned(text(anchor) ?? "") else { return nil }
        return turn.spoken(cue, text: text)
    }

    /// The model's quote when the row holds it word for word.
    private func exactQuote(_ quote: String?, in row: Int) -> String? {
        guard let quote, !quote.isEmpty, let source = text(row) else { return nil }
        let collapsed = source.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return collapsed.contains(quote) ? quote : nil
    }

    private func unresolved(_ reason: OutcomeAttribution.RejectionReason, speaker: String?) -> OutcomeAttribution {
        .init(resolution: .unresolved, speakerID: speaker.flatMap { roster[$0] == nil ? nil : $0 },
              basis: .unclear, rejectionReason: reason)
    }
}
