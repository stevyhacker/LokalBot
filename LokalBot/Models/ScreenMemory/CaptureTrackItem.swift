import Foundation

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

    static func items(blocks: [ActivityBlock], meetings: [Meeting],
                      now: Date) -> [CaptureTrackItem] {
        let meetingItems = meetings.map {
            CaptureTrackItem.meeting($0, end: meetingEnd($0, now: now))
        }
        return (blocks.map(CaptureTrackItem.activity) + meetingItems)
            .sorted { $0.start < $1.start }
    }

    static func meetingEnd(_ meeting: Meeting, now: Date) -> Date {
        if let ended = meeting.endedAt { return ended }
        if let recorded = meeting.recordedDuration {
            return meeting.startedAt.addingTimeInterval(recorded)
        }
        return max(now, meeting.startedAt.addingTimeInterval(60))
    }
}
