import Foundation

/// What the Timeline/Meetings detail pane shows, resolved from the two
/// selection sources (spec §2.2): meeting selection wins, then an activity
/// block, then the day overview. Multi-selected meetings keep the
/// bulk-delete card.
///
/// `allowsBlockSelection` is false on surfaces without a block list
/// (Meetings): the shared model keeps whatever block was last picked in
/// Timeline, and that leftover must not outrank the empty state there —
/// while still being selected again when the user returns to Timeline.
enum CaptureInspectorState: Equatable {
    case overview
    case meeting(Meeting.ID)
    case multiSelection(count: Int)
    case block(ActivityBlock.ID)

    static func resolve(meetingIDs: Set<Meeting.ID>,
                        blockSelection: ActivityBlock.ID?,
                        allowsBlockSelection: Bool) -> CaptureInspectorState {
        if meetingIDs.count == 1, let id = meetingIDs.first { return .meeting(id) }
        if meetingIDs.count > 1 { return .multiSelection(count: meetingIDs.count) }
        if allowsBlockSelection, let blockSelection { return .block(blockSelection) }
        return .overview
    }
}
