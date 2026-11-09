import LokalBotCompanionKit
import SwiftUI

/// Values pushed onto navigation stacks. Links inside a screen push in place
/// (an evidence pill opens the meeting right there, Back returns), so every
/// stack registers all of them with `companionDestinations()`.
struct MeetingRoute: Hashable {
    let id: String
    var offset: Double?
}

struct ActionRoute: Hashable {
    let meetingID: String
    let actionID: String

    init(meetingID: String, actionID: String) {
        self.meetingID = meetingID
        self.actionID = actionID
    }

    init(_ row: ActionRow) {
        self.init(meetingID: row.meetingId, actionID: row.action.id)
    }
}

struct PersonRoute: Hashable {
    let id: String
}

struct ProjectRoute: Hashable {
    let id: String
}

struct DayRoute: Hashable {
    let day: DayKey
}

extension View {
    func companionDestinations() -> some View {
        navigationDestination(for: MeetingRoute.self) { MeetingDetailScreen(meetingID: $0.id, focus: $0.offset) }
            .navigationDestination(for: ActionRoute.self) { ActionDetailScreen(route: $0) }
            .navigationDestination(for: PersonRoute.self) { PersonDetailScreen(personID: $0.id) }
            .navigationDestination(for: ProjectRoute.self) { ProjectDetailScreen(projectID: $0.id) }
            .navigationDestination(for: DayRoute.self) { DayDigestScreen(day: $0.day) }
    }
}
