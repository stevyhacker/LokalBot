import Foundation

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
