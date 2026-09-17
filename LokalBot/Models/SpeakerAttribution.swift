import Foundation

struct StatementAttribution: Codable, Equatable, Sendable {
    var speakerID: String
    var speakerLabel: String
    var identity: SpeakerAttribution.Identity
    var quote: String
}

/// Public, meeting-local provenance. Voice vectors and cross-meeting profile
/// identifiers remain in the encrypted identity store.
struct SpeakerAttribution: Codable, Equatable, Sendable {
    enum Source: String, Codable, Sendable { case microphone, system, unknown }
    enum Identity: String, Codable, Sendable { case user, other, unresolved }
    enum Method: String, Codable, Sendable {
        case track, diarization, overlappingSpeech, suspectedEcho, confirmation, profile, legacy
    }
    var source: Source
    var identity: Identity
    var method: Method

    /// A microphone identifies an input, not a person. Normalize old persisted
    /// defaults too, so reopening a recording cannot restore unsafe ownership.
    var applyingMicrophoneDefault: Self {
        guard source == .microphone,
              [.track, .diarization, .legacy].contains(method) else { return self }
        var result = self
        result.identity = .unresolved
        return result
    }

    var canConfirmIdentity: Bool {
        [.diarization, .confirmation, .profile].contains(method)
            || (source == .microphone && [.track, .legacy].contains(method))
    }

    var isConfirmedUser: Bool {
        identity == .user && [.confirmation, .profile].contains(method)
    }

    var hasIdentityDecision: Bool { [.confirmation, .profile].contains(method) }

    static func legacy(speaker: String) -> Self {
        let key = Transcript.canonicalSpeakerKey(speaker)
        return Self(source: key == "me" ? .microphone : .unknown,
                    identity: key == "me" ? .unresolved : .other, method: .legacy)
    }
}

struct TranscriptEchoReport: Codable, Equatable, Sendable {
    enum Status: String, Codable, Sendable {
        case disabled, noReference, applied, uncertain, failed
    }
    var status: Status
    var reductionDB: Double?
    var delaySeconds: Double?
    var alignmentVerified: Bool = false

    var explanation: String {
        switch status {
        case .disabled: "Echo removal is off. Unconfirmed microphone speakers remain unidentified."
        case .noReference: "Remote audio is unavailable for echo removal."
        case .applied: "Echo removal applied. Speaker identity is checked separately."
        case .uncertain: "Echo removal was uncertain. Original speech was preserved."
        case .failed: "Echo removal could not finish. Original speech was preserved."
        }
    }
}

struct OutcomeAttribution: Codable, Equatable, Sendable {
    enum Resolution: String, Codable, Sendable { case user, other, unresolved }
    enum Basis: String, Codable, Sendable { case commitment, assignment, request, unclear, legacy }
    enum RejectionReason: String, Codable, Sendable {
        case missingSpeaker, unknownSpeaker, unconfirmedIdentity, missingBasis, missingQuote, quoteNotFound
        case unsupportedCommitment, speakerMismatch, ambiguousName, targetNotExplicit, conflictingOwner
    }
    var resolution: Resolution
    var speakerID: String?
    var basis: Basis
    var quote: String?
    /// Content-free explanation retained even when ownership cannot be applied.
    var rejectionReason: RejectionReason?

    func consistent(with forUser: Bool?) -> Self {
        guard let forUser, forUser != (resolution == .user) else { return self }
        return Self(resolution: .unresolved, speakerID: speakerID, basis: .unclear, quote: quote,
                    rejectionReason: .conflictingOwner)
    }

    static func legacy(owner: String?, forUser: Bool?, userLabel: String = "Me") -> Self {
        let name = owner.flatMap { value -> String? in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        let user = name.map {
            $0.caseInsensitiveCompare("Me") == .orderedSame
                || $0.caseInsensitiveCompare(userLabel) == .orderedSame
        } ?? false
        let conflict = forUser.map { flag in
            flag ? (name != nil && !user) : user
        } ?? false
        let resolution: Resolution = conflict ? .unresolved
            : (forUser ?? user) ? .user : name == nil ? .unresolved : .other
        return Self(resolution: resolution, basis: .legacy)
    }
}
