import Foundation

enum SpeakerObservationIssue: String, Codable, Sendable {
    case chromeUnavailable, unboundBackgroundWindow, screenUnavailable, accessibilityPermission
    case accessibilityBusy, accessibilityTimeout, accessibilityBudget, sourceUnavailable, sourceRejected
    case layoutUnavailable, screenPermission, windowChanged, waitingForFrame, frameUnavailable, sourceChanged
    case paused, settingsChanged, noActiveSpeaker, ambiguousSpeaker, noClockCoverage, providerUnavailable, evidenceUnavailable
    case selfIdentityUnavailable

    var explanation: String {
        switch self {
        case .chromeUnavailable: "The recorded Chrome meeting is unavailable"
        case .unboundBackgroundWindow: "Bring the recorded Meet tab forward once to identify its window"
        case .screenUnavailable: "Screen is locked or unavailable"
        case .accessibilityPermission: "Accessibility permission is needed to read participant names"
        case .accessibilityBusy, .accessibilityTimeout: "Chrome participant information is taking too long to respond"
        case .accessibilityBudget: "Chrome participant layout exceeded the observation budget"
        case .sourceUnavailable: "The recorded Meet document is not readable in the available Chrome windows"
        case .sourceRejected: "Meet source does not match the recording or its privacy settings"
        case .layoutUnavailable: "Participant names are unavailable in this Meet layout"
        case .screenPermission: "Screen Recording permission is needed for visual indicators"
        case .windowChanged, .sourceChanged: "Meet window or selected tab changed during observation"
        case .waitingForFrame: "Waiting for a fresh participant frame"
        case .frameUnavailable: "Participant frame capture is unavailable"
        case .paused: "Speaker observation paused"
        case .settingsChanged: "Speaker observation settings changed"
        case .noActiveSpeaker: "Waiting for a visible speaker"
        case .ambiguousSpeaker: "The visible speaking indicator is ambiguous"
        case .noClockCoverage: "Waiting for consecutive observations aligned to recorded audio"
        case .providerUnavailable: "Speaker observation is unavailable"
        case .evidenceUnavailable: "Speaker evidence storage is unavailable"
        case .selfIdentityUnavailable: "Names are available; your Meet tile must be identified before automatic naming"
        }
    }
}

/// Counts and fixed reason codes only; no names, URLs, window titles or pixels.
/// Stored in the same encrypted, expiring sidecar as observation evidence.
struct SpeakerObservationDiagnostics: Codable, Equatable, Sendable {
    var observations = 0
    var batchesWithTiles = 0
    var maximumTileCount = 0
    var intervals = 0
    var coveredSeconds: Double = 0
    var visualObservationAttempts: Int?
    var maximumParticipantCount: Int?
    var issues: [String: Int] = [:]
    var lastIssue: SpeakerObservationIssue?

    var missingSpeakerNamesExplanation: String? {
        // Older sessions did not record the toggle. Only visual-only failures
        // establish that naming was attempted in those sessions.
        let legacyAttempts = [SpeakerObservationIssue.layoutUnavailable, .screenPermission, .windowChanged,
                              .waitingForFrame, .frameUnavailable].reduce(0) { $0 + issues[$1.rawValue, default: 0] }
        guard (visualObservationAttempts ?? legacyAttempts) > 0, observations > 0,
              intervals == 0, coveredSeconds == 0 else { return nil }
        if (maximumParticipantCount ?? 0) > 0 {
            return "Participant names were captured, but speaking activity could not be matched to the audio. The names remain available for manual assignment."
        }
        return "No usable speaker observations were captured. You can name voices in the transcript; processing this recording again cannot recover the missing visual evidence."
    }

    mutating func record(_ issue: SpeakerObservationIssue) {
        issues[issue.rawValue, default: 0] += 1
        lastIssue = issue
    }

    mutating func record(_ batch: MeetingSpeakerObservationBatch, interval: SpeakerActivityInterval?, visual: Bool = true) {
        observations += 1
        visualObservationAttempts = (visualObservationAttempts ?? 0) + (visual ? 1 : 0)
        maximumTileCount = max(maximumTileCount, batch.observations.count)
        maximumParticipantCount = max(maximumParticipantCount ?? 0, batch.participants.count)
        if !batch.observations.isEmpty { batchesWithTiles += 1 }
        if let issue = batch.issue { record(issue) } else if batch.reason != nil { record(.providerUnavailable) } else if let interval {
            intervals += 1
            coveredSeconds += interval.range.duration
            lastIssue = nil
        } else {
            let active = batch.observations.filter { $0.active && !$0.isSelf }
            if active.isEmpty { record(.noActiveSpeaker) } else if active.count != 1 || active.contains(where: { $0.muted || !$0.unique }) {
                record(.ambiguousSpeaker)
            } else { record(.noClockCoverage) }
        }
    }
}
