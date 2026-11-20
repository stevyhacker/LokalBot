import Foundation

enum OutcomeEvidencePolicy {
    private static let commitmentPreamble =
        #"^(?:(?:yes|yeah|yep|okay|ok|sure|right|well|so|and|then|absolutely|after this|next|also|um|uh|"#
        + #"(?:on|from) my (?:side|end)|for my part|as for me)[,!.: ]+)*"#
    private static let firstPersonUndertaking =
        #"(?:i (?:will|shall|am going to|am gonna|commit to|agree to|(?:do )?(?:plan|intend) to|am (?:planning|intending) to)"#
        + #"|i['’]m (?:going to|gonna|planning to|intending to)|i['’]ll|my next step is"#
        + #"|(?:i think )?i (?:still )?(?:have to|need to|must))"#

    static func isBareAcceptance(_ raw: String) -> Bool {
        normalized(raw).range(of:
            commitmentPreamble + #"i can (?:do (?:that|it)|take (?:that|it)(?: on)?|handle (?:that|it))[.! ]*$"#,
            options: .regularExpression) != nil
    }

    static func isConversationManagement(_ raw: String) -> Bool {
        normalized(raw).range(of:
            commitmentPreamble + firstPersonUndertaking + " " + SpokenUndertaking.conversationRemark
                + #"(?: with (?:you|everyone|you all|you guys))?[.! ]*$"#,
            options: .regularExpression) != nil
    }

    private static func canonicalClauses(_ text: String) -> [String] {
        let regex = try? NSRegularExpression(pattern: #"[^.!?;]+[.!?;]*"#)
        return regex?.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard let range = Range(match.range, in: text) else { return nil }
            let quote = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            return quote.isEmpty || quote.count > 1_000 ? nil : quote
        } ?? []
    }

    static func resolveTarget(
        speakerID: String?, basis: String?, source: Transcript.Segment, visibleText: String,
        roster: [String: Transcript.SpeakerDescriptor], addressedToUser: Bool, quote: String?
    ) -> OutcomeAttribution {
        let supplied = quote.flatMap { normalized($0).isEmpty ? nil : $0 }
        let clauses = supplied.map { [$0] } ?? canonicalClauses(visibleText)
        if supplied == nil, clauses.filter({ expressesUndertaking($0) || isSecondPersonRequest($0) }).count > 1 {
            return .init(resolution: .unresolved, speakerID: speakerID.flatMap { roster[$0] == nil ? nil : $0 },
                         basis: .unclear, rejectionReason: .missingQuote)
        }
        var failure = resolve(speakerID: speakerID, basis: basis, quote: nil, sources: [source], roster: roster)
        var accepted: [OutcomeAttribution] = []
        for quote in clauses {
            let attribution = resolve(speakerID: speakerID, basis: basis, quote: quote, sources: [source],
                                      roster: roster, addressedToUser: addressedToUser)
            if attribution.resolution != .unresolved { accepted.append(attribution) }
            failure = attribution
        }
        if accepted.count > 1 {
            return .init(resolution: .unresolved, speakerID: speakerID, basis: .unclear, rejectionReason: .ambiguousQuote)
        }
        return accepted.first ?? failure
    }

    static func resolve(
        speakerID: String?, basis: String?, quote: String?,
        sources: [Transcript.Segment], roster: [String: Transcript.SpeakerDescriptor],
        addressedToUser: Bool = false
    ) -> OutcomeAttribution {
        func reject(_ reason: OutcomeAttribution.RejectionReason) -> OutcomeAttribution {
            OutcomeAttribution(resolution: .unresolved, speakerID: speakerID.flatMap { roster[$0] == nil ? nil : $0 },
                               basis: .unclear, rejectionReason: reason)
        }
        guard let speakerID else { return reject(.missingSpeaker) }
        guard let person = roster[speakerID] else { return reject(.unknownSpeaker) }
        guard person.identity != .unresolved else { return reject(.unconfirmedIdentity) }
        guard let basis = basis.flatMap(OutcomeAttribution.Basis.init(rawValue:)),
              [.commitment, .assignment, .request].contains(basis) else { return reject(.missingBasis) }
        guard let quote, !normalized(quote).isEmpty, quote.count <= 1_000 else { return reject(.missingQuote) }
        if basis == .commitment {
            let quoted = sources.filter { !SpokenUndertaking.occurrences(of: quote, in: SpokenUndertaking.words([$0.displayText])).isEmpty }
            guard !quoted.isEmpty else { return reject(.quoteNotFound) }
            guard quoted.allSatisfy({ undertakes(quote, in: $0.displayText) }) else { return reject(.unsupportedCommitment) }
            guard quoted.allSatisfy({
                Transcript.canonicalSpeakerKey($0.speaker) == speakerID
                    && $0.resolvedAttribution.identity == person.identity
                    && ![.overlappingSpeech, .suspectedEcho].contains($0.resolvedAttribution.method)
            }) else { return reject(.speakerMismatch) }
        } else {
            let quoted = sources.filter { normalized($0.displayText).contains(normalized(quote)) }
            guard !quoted.isEmpty else { return reject(.quoteNotFound) }
            let names = uniqueTargetNames(for: person, roster: roster)
            let named = names.contains(where: { name in
                hasExplicitTarget(name, in: quote, basis: basis) && quoted.allSatisfy { source in
                    evidenceClause(quote, in: source.displayText).map { hasExplicitTarget(name, in: $0, basis: basis) } == true
                }
            })
            let answeredByUser = addressedToUser && person.identity == .user
                && quoted.allSatisfy { source in
                    roster[Transcript.canonicalSpeakerKey(source.speaker)]?.identity == .other
                        && evidenceClause(quote, in: source.displayText).map(isSecondPersonRequest) == true
                }
            guard named || answeredByUser else {
                return reject(names.isEmpty && !addressedToUser ? .ambiguousName : .targetNotExplicit)
            }
        }
        return OutcomeAttribution(resolution: person.identity == .user ? .user : .other,
            speakerID: speakerID, basis: basis, quote: quote)
    }

    static func isCommitment(_ raw: String) -> Bool {
        SpokenUndertaking.cues(in: SpokenUndertaking.words([raw])).contains(where: \.isAccepted)
    }

    private static func undertakes(_ quote: String, in source: String) -> Bool {
        let words = SpokenUndertaking.words([source])
        guard let hit = SpokenUndertaking.occurrences(of: quote, in: words).first else { return false }
        let start = words[..<hit.lowerBound].lastIndex(where: \.endsSentence).map { $0 + 1 } ?? 0
        let end = words[(hit.upperBound - 1)...].firstIndex(where: \.endsSentence).map { $0 + 1 } ?? words.count
        return SpokenUndertaking.cues(in: words).contains { $0.isAccepted && (start..<end).contains($0.words.lowerBound) }
    }

    static func isNegatedOrQuestioned(_ raw: String) -> Bool {
        normalized(raw).range(of:
            #"\?|\b(?:not|never|cannot|can't|can’t|won't|won’t|don't|don’t|shouldn't|shouldn’t)\b"#,
            options: .regularExpression) != nil
    }

    static func undertakingIsNegatedOrQuestioned(_ raw: String) -> Bool {
        let sentences = canonicalClauses(raw).filter(expressesUndertaking)
        return !sentences.isEmpty && sentences.allSatisfy(isNegatedOrQuestioned)
    }

    static func expressesUndertaking(_ raw: String) -> Bool {
        normalized(raw).range(of:
            #"\b(?:will|shall|going to|gonna|need to|needs to|have to|has to|got to|should|must|can|could|let me|let['’]s|let us|plan to|want to)\b|['’]ll\b"#,
            options: .regularExpression) != nil
    }

    static func isSecondPersonRequest(_ raw: String) -> Bool {
        let text = normalized(raw).replacingOccurrences(of:
            #"\bif you (?:could|can|would|don['’]t mind)\b"#, with: "could you", options: .regularExpression)
        guard text.range(of: #"\b(?:if|unless|might|perhaps)\b"#, options: .regularExpression) == nil,
              text.range(of: #"\byou (?:all|guys|both|two)\b|\b(?:everyone|everybody|anyone|anybody|someone|somebody|y['’]all)\b"#,
                         options: .regularExpression) == nil else { return false }
        let patterns = [
            #"\b(?:can|could|would|will) you (?:please |maybe |also |just )*(?!not\b)\w"#,
            #"\byou (?:need to|have to|must|should|will need to|['’]ll need to)\s+(?!not\b|never\b)\w"#,
            #"\bi(?:['’]d| would)? (?:need|want|like) you to\b"#,
            #"\bmake sure (?:that )?you\b"#,
            #"(?:^|[.!?]\s*)please (?!note\b)\w"#,
        ]
        return patterns.contains { text.range(of: $0, options: .regularExpression) != nil }
    }

    private static func evidenceClause(_ quote: String, in source: String) -> String? {
        let text = normalized(source)
        guard let match = text.range(of: normalized(quote)) else { return nil }
        let prefix = text[..<match.lowerBound]
        let boundary = prefix.lastIndex(where: { ".!?;".contains($0) })
        let start = boundary.map { text.index(after: $0) } ?? text.startIndex
        let suffix = text[match.upperBound...]
        let quoteEndsClause = ".!?;".contains(text[text.index(before: match.upperBound)])
        let end = quoteEndsClause ? match.upperBound
            : suffix.firstIndex(where: { ".!?;".contains($0) }).map { text.index(after: $0) } ?? text.endIndex
        return String(text[start..<end])
    }

    private static func uniqueTargetNames(for person: Transcript.SpeakerDescriptor,
                                          roster: [String: Transcript.SpeakerDescriptor]) -> [String] {
        let name = normalized(person.name)
        guard !["me", "you", "them", "local speaker", "speaker unclear"].contains(name),
              name.range(of: #"^(?:them|local|speaker)(?:\s+\d+|\s+unclear)?$"#, options: .regularExpression) == nil else { return [] }
        let candidates = [name, name.split(separator: " ").first.map(String.init)].compactMap { $0 }
        return Array(Set(candidates)).filter { candidate in
            roster.values.filter { other in
                let otherName = normalized(other.name)
                return otherName == candidate || otherName.split(separator: " ").first.map(String.init) == candidate
            }.count == 1
        }
    }

    private static func hasExplicitTarget(_ name: String, in quote: String, basis: OutcomeAttribution.Basis) -> Bool {
        let subject = NSRegularExpression.escapedPattern(for: name)
        let text = normalized(quote)
        guard text.range(of: #"\b(?:if|unless|might|maybe|perhaps)\b"#, options: .regularExpression) == nil else { return false }
        let start = #"(?:^|[.!?]\s*)(?:(?:okay|ok|so|and|then|yes|yeah)[, ]+)*"#
        let patterns: [String]
        if basis == .request {
            patterns = [
                start + subject + #"[, :]+(?:please\b|(?:can|could|would|will) you\b)"#,
                start + #"(?:can|could|would|will) you,\s*"# + subject + #"[, :]"#,
                start + #"(?:please|can|could|would|will)\s+"# + subject + #"\s+(?!not\b)\w"#,
            ]
        } else {
            patterns = [start + subject + #"\s+(?:will\s+(?!not\b)|is responsible for\s+|owns\s+|to\s+)\w"#]
        }
        return patterns.contains { text.range(of: $0, options: .regularExpression) != nil }
    }

    private static func normalized(_ text: String) -> String {
        text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
