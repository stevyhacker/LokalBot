import Foundation

enum SpeakerVoiceMatcher {
    /// Call audio arrives codec-compressed, so a single 3–10 s chunk varies too
    /// much to compare on its own. A speaker's average over many turns is
    /// stable: on real Google Meet standups the same person scored 0.77–0.94
    /// across meetings and different people at most 0.57.
    enum Call {
        static let sampleLimit = 16
        /// Median sample-to-average similarity. A label that mixes voices falls below it.
        static let minimumConsistency = 0.75
        static let suggestedScore = 0.60
        static let automaticScore = 0.70
        /// Over the best remembered person with a different name.
        static let automaticMargin = 0.15
        static let policyVersion = "call-voiceprint-1"
    }

    struct Voiceprint: Equatable {
        var vector: [Float]
        var consistency: Double
    }

    static func normalized(_ vector: [Float]) -> [Float]? {
        guard vector.count == 256, vector.allSatisfy(\.isFinite) else { return nil }
        let norm = sqrt(vector.reduce(Double(0)) { $0 + Double($1) * Double($1) })
        guard norm > 0.00001, norm.isFinite else { return nil }
        return vector.map { Float(Double($0) / norm) }
    }

    static func cosine(_ lhs: [Float], _ rhs: [Float]) -> Double {
        guard let a = normalized(lhs), let b = normalized(rhs) else { return -1 }
        return zip(a, b).reduce(0) { $0 + Double($1.0) * Double($1.1) }
    }

    /// The normalized average of `vectors` and how closely the vectors agree with it.
    static func voiceprint(_ vectors: [[Float]]) -> Voiceprint? {
        let unit = vectors.compactMap(normalized)
        guard !unit.isEmpty, unit.count == vectors.count else { return nil }
        var sum = [Double](repeating: 0, count: 256)
        for vector in unit { for index in sum.indices { sum[index] += Double(vector[index]) } }
        guard let average = normalized(sum.map { Float($0) }) else { return nil }
        let agreement = unit.map { cosine($0, average) }.sorted()
        let middle = agreement.count / 2
        let median = agreement.count % 2 == 0 ? (agreement[middle - 1] + agreement[middle]) / 2 : agreement[middle]
        return Voiceprint(vector: average, consistency: median)
    }

    static func voiceprint(_ samples: [SpeakerVoiceSample]) -> Voiceprint? {
        guard samples.allSatisfy({ $0.model == SpeakerVoiceSample.fingerprint }) else { return nil }
        return voiceprint(samples.map(\.vector))
    }

    /// A remembered person's call voice: each confirmed meeting counts once.
    static func callVoiceprint(_ profile: SpeakerVoiceProfile) -> Voiceprint? {
        guard profile.model == SpeakerVoiceSample.fingerprint else { return nil }
        let meetings = profile.contributions.compactMap { contribution -> [Float]? in
            let samples = contribution.samples.filter { ($0.source ?? .system) == .system }
            guard !samples.isEmpty else { return nil }
            return contribution.voiceprint ?? voiceprint(samples)?.vector
        }
        return voiceprint(meetings)
    }

    /// Select at most one disjoint chunk from each independent, uncontaminated
    /// speaking turn. Overlapping diarizer windows are never extra votes.
    static func eligible(_ samples: [SpeakerVoiceSample], turns: [SpeakerAudioTurn], speaker: String) -> [SpeakerVoiceSample] {
        if turns.first(where: { $0.speaker == speaker })?.resolvedSource == .system {
            return callEligible(samples, turns: turns, speaker: speaker)
        }
        let cleanTurns = VisualSpeakerMatcher.mergedTurns(turns).filter {
            $0.speaker == speaker && $0.range.duration >= 3
        }
        var selected: [SpeakerVoiceSample] = []
        for turn in cleanTurns {
            let candidates = samples.filter { sample in
                sample.speaker == speaker && sample.model == SpeakerVoiceSample.fingerprint
                    && sample.range.isValid && sample.range.duration >= 3
                    && sample.range.overlap(turn.range) >= sample.range.duration * 0.95
                    && !turns.contains {
                        $0.speaker != speaker && $0.resolvedSource == (sample.source ?? .system)
                            && $0.range.overlap(sample.range) > 0.02
                    }
                    && !selected.contains { $0.range.overlap(sample.range) > 0 }
                    && normalized(sample.vector) != nil
            }.sorted { $0.range.duration > $1.range.duration }
            if var best = candidates.first, let normalized = normalized(best.vector) {
                best.vector = normalized
                selected.append(best)
            }
            if selected.count == 8 { break }
        }
        // A mixed cluster is unsafe to enroll, even if some of its samples agree.
        guard selected.allSatisfy({ a in selected.allSatisfy { cosine(a.vector, $0.vector) >= 0.75 } }) else { return [] }
        return selected
    }

    /// Call speakers: the longest disjoint chunks that no other speaker
    /// overlaps, wherever they fall. The diarizer splits call speech into short
    /// turns, so one chunk per turn left most people with a single sample.
    /// Their average is checked for a mixed voice instead of every pair.
    private static func callEligible(_ samples: [SpeakerVoiceSample], turns: [SpeakerAudioTurn], speaker: String) -> [SpeakerVoiceSample] {
        let others = turns.filter { $0.speaker != speaker && $0.resolvedSource == .system }
        let candidates = samples.filter { sample in
            sample.speaker == speaker && sample.model == SpeakerVoiceSample.fingerprint
                && (sample.source ?? .system) == .system && sample.range.isValid && sample.range.duration >= 3
                && !others.contains { $0.range.overlap(sample.range) > 0.02 }
        }.sorted { $0.range.duration > $1.range.duration }
        var selected: [SpeakerVoiceSample] = []
        for var sample in candidates where !selected.contains(where: { $0.range.overlap(sample.range) > 0 }) {
            guard let vector = normalized(sample.vector) else { continue }
            sample.vector = vector
            selected.append(sample)
            if selected.count == Call.sampleLimit { break }
        }
        return selected.sorted { $0.range.start < $1.range.start }
    }

    static func canEnroll(_ samples: [SpeakerVoiceSample]) -> Bool {
        let call = samples.first.map { ($0.source ?? .system) == .system } ?? false
        guard samples.count >= 3, samples.count <= (call ? Call.sampleLimit : 8),
              samples.allSatisfy({ $0.model == SpeakerVoiceSample.fingerprint && $0.range.isValid && normalized($0.vector) != nil }),
              Set(samples.map(\.speaker)).count == 1,
              Set(samples.map { $0.source ?? .system }).count == 1,
              samples.reduce(0, { $0 + $1.range.duration }) >= 15 else { return false }
        for index in samples.indices {
            for other in samples.indices where other > index {
                if samples[index].range.overlap(samples[other].range) > 0
                    || (!call && cosine(samples[index].vector, samples[other].vector) < 0.75) { return false }
            }
        }
        return !call || (voiceprint(samples)?.consistency ?? 0) >= Call.minimumConsistency
    }

    static func matches(samples: [SpeakerVoiceSample], profiles: [SpeakerVoiceProfile]) -> [SpeakerNameMatch] {
        guard !samples.isEmpty,
              samples.allSatisfy({ $0.model == SpeakerVoiceSample.fingerprint && $0.range.isValid && normalized($0.vector) != nil }) else { return [] }
        let domain = samples[0].source ?? .system
        guard samples.allSatisfy({ ($0.source ?? .system) == domain }) else { return [] }
        if domain == .system { return callMatches(samples: samples, profiles: profiles) }
        var scored: [(SpeakerVoiceProfile, Double, Double)] = []
        for profile in profiles where profile.model == SpeakerVoiceSample.fingerprint {
            let exemplars = profile.contributions.flatMap(\.samples).filter {
                $0.model == SpeakerVoiceSample.fingerprint && normalized($0.vector) != nil
                    && ($0.source ?? .system) == domain
            }
            guard exemplars.count >= 3 else { continue }
            let scores = samples.map { sample in
                exemplars.map { cosine(sample.vector, $0.vector) }.max() ?? -1
            }
            scored.append((profile, scores.reduce(0, +) / Double(scores.count), scores.min() ?? -1))
        }
        scored.sort { $0.1 > $1.1 }
        return Array(scored.prefix(3)).compactMap { profile, mean, minimum in
            guard mean >= 0.72, minimum >= 0.65 else { return nil } // unknown, including the single-profile case
            // Microphone recognition requires its own held-out calibration.
            return SpeakerNameMatch(name: profile.name, participantReference: profile.id.uuidString,
                tier: .suggested, source: .profile,
                supportSeconds: samples.reduce(0) { $0 + $1.range.duration }, independentTurns: samples.count,
                supportFraction: mean, contradictionSeconds: 0, evidence: Array(samples.map(\.range).prefix(8)),
                profileID: profile.id, profileRevision: profile.revision)
        }
    }

    /// One average per call speaker against each remembered person's average.
    /// Remembered people who share a name never block each other.
    private static func callMatches(samples: [SpeakerVoiceSample], profiles: [SpeakerVoiceProfile]) -> [SpeakerNameMatch] {
        guard samples.count >= 2, let query = voiceprint(samples), query.consistency >= Call.minimumConsistency else { return [] }
        let scored = profiles.compactMap { profile -> (SpeakerVoiceProfile, Double)? in
            guard let remembered = callVoiceprint(profile) else { return nil }
            return (profile, cosine(query.vector, remembered.vector))
        }.sorted { $0.1 > $1.1 }
        let seconds = samples.reduce(0) { $0 + $1.range.duration }
        return Array(scored.prefix(3)).compactMap { profile, score in
            guard score >= Call.suggestedScore else { return nil }
            let name = ParticipantObservation.nameKey(profile.name)
            let next = scored.filter { ParticipantObservation.nameKey($0.0.name) != name }.map(\.1).max() ?? -1
            let automatic = samples.count >= 3 && seconds >= 15
                && score >= Call.automaticScore && score - next >= Call.automaticMargin
            var match = SpeakerNameMatch(name: profile.name, participantReference: profile.id.uuidString,
                tier: automatic ? .automatic : .suggested, source: .profile,
                supportSeconds: seconds, independentTurns: samples.count,
                supportFraction: score, contradictionSeconds: 0, evidence: Array(samples.map(\.range).prefix(8)),
                profileID: profile.id, profileRevision: profile.revision)
            match.policyVersion = Call.policyVersion
            return match
        }
    }
}
