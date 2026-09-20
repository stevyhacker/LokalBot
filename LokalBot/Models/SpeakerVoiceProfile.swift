import Foundation

struct SpeakerVoiceSample: Codable, Equatable, Sendable {
    static let fingerprint = "FluidAudio-0.15.8-87a39df/pyannote-community-1/embedding256/16k-mono-v1"
    var speaker: String
    var range: SpeakerTurnAnchor
    var vector: [Float]
    var source: SpeakerAttribution.Source?
    var model = fingerprint
}

struct SpeakerVoiceProfile: Codable, Identifiable, Sendable {
    struct Contribution: Codable, Sendable {
        var meetingID: UUID
        var audioRevision: String
        var speakerID: UUID
        var decisionID: UUID
        var confirmedAt: Date
        var samples: [SpeakerVoiceSample]
    }
    var id = UUID()
    var name: String
    var isLocalUser: Bool?
    var confirmedNames: [String]
    var revision = 1
    var contributions: [Contribution]
    var model = SpeakerVoiceSample.fingerprint
}

struct SpeakerVoiceProfileDatabase: Codable, Sendable {
    var schemaVersion = 1
    var revision = 0
    var profiles: [SpeakerVoiceProfile] = []
    var forgottenProfiles: Set<UUID> = []
    var deletedMeetings: Set<UUID> = []
    var revokedDecisionIDs: Set<UUID> = []
}
