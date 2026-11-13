import Foundation

/// One block in the Capture day track: an app activity block, or a meeting
/// rendered as a first-class teal block (spec §2.2). Pure so the
/// interleaving and the in-progress-meeting end rule are unit-testable.
enum CaptureTrackItem: Identifiable {
    case activity(ActivityBlock)
    case meeting(Meeting, end: Date)

    var id: String {
        switch self {
        case .activity(let block): "block-\(block.id)"
        case .meeting(let meeting, _): "meeting-\(meeting.id.uuidString)"
        }
    }

    var start: Date {
        switch self {
        case .activity(let block): block.start
        case .meeting(let meeting, _): meeting.startedAt
        }
    }

    var end: Date {
        switch self {
        case .activity(let block): block.end
        case .meeting(_, let end): end
        }
    }

    /// Merge a day's activity blocks and meetings into one start-ordered
    /// track.
    static func items(blocks: [ActivityBlock], meetings: [Meeting],
                      now: Date) -> [CaptureTrackItem] {
        let meetingItems = meetings.map {
            CaptureTrackItem.meeting($0, end: meetingEnd($0, now: now))
        }
        return (blocks.map(CaptureTrackItem.activity) + meetingItems)
            .sorted { $0.start < $1.start }
    }

    /// A meeting's track end: `endedAt`, else the recorded audio length,
    /// else "now" for a live meeting — never less than a minute past start
    /// so a just-started meeting still gets a visible block.
    static func meetingEnd(_ meeting: Meeting, now: Date) -> Date {
        if let ended = meeting.endedAt { return ended }
        if let recorded = meeting.recordedDuration {
            return meeting.startedAt.addingTimeInterval(recorded)
        }
        return max(now, meeting.startedAt.addingTimeInterval(60))
    }
}
