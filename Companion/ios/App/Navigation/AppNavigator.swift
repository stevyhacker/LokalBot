import LokalBotCompanionKit
import Observation
import SwiftUI

enum AppSection: String, CaseIterable, Hashable, Identifiable, Codable {
    case today, actions, meetings, timeline, people, projects, ask, settings
    case more

    var id: String { rawValue }

    var title: String {
        switch self {
        case .today: "Today"
        case .actions: "Actions"
        case .meetings: "Meetings"
        case .timeline: "Timeline"
        case .people: "People"
        case .projects: "Projects"
        case .ask: "Ask"
        case .settings: "Settings"
        case .more: "More"
        }
    }

    var systemImage: String {
        switch self {
        case .today: "sun.max"
        case .actions: "checklist"
        case .meetings: "waveform.circle"
        case .timeline: "calendar.day.timeline.left"
        case .people: "person.2"
        case .projects: "folder"
        case .ask: "sparkle.magnifyingglass"
        case .settings: "gearshape"
        case .more: "ellipsis.circle"
        }
    }

    var livesUnderMore: Bool {
        [.timeline, .people, .projects, .settings].contains(self)
    }

    static let shortcutOrder: [AppSection] = [.today, .actions, .meetings, .timeline, .people, .projects, .ask]
}

@MainActor @Observable
final class AppNavigator {
    struct MeetingFocus: Equatable {
        let meetingID: String
        let offset: Double?
        let id = UUID()
    }

    var tab: AppSection = .today
    var isCompact = false
    var morePath = NavigationPath()
    private(set) var moreSection: AppSection?

    var meetingSelection: String?
    var meetingFocus: MeetingFocus?
    var actionSelection: String?
    var personSelection: String?
    var projectSelection: String?
    var timelineDay: DayKey?

    var searchRequest = 0
    var newQuestionRequest = 0
    var askScope: AskRequest.Scope?
    var askDraft: String?

    var demoQuestion: String?
    var demoMeetingTab: String?
    var demoPairingLink: String?

    var section: AppSection {
        tab == .more ? (morePath.isEmpty ? .more : moreSection ?? .more) : tab
    }

    func open(_ section: AppSection) {
        if isCompact && section.livesUnderMore {
            tab = .more
            moreSection = section
            morePath = NavigationPath([section])
            pushPendingUnderMore()
        } else if section == .more {
            tab = isCompact ? .more : .timeline
        } else {
            tab = section
        }
    }

    func adapt(compact: Bool) {
        guard compact != isCompact else { return }
        let current = section
        isCompact = compact
        if compact {
            open(current)
        } else {
            tab = current == .more ? .timeline : current
            morePath = NavigationPath()
        }
    }

    func showing(_ section: AppSection) {
        moreSection = section
    }

    private func pushPendingUnderMore() {
        if moreSection == .people, let id = personSelection {
            morePath.append(PersonRoute(id: id))
            personSelection = nil
        } else if moreSection == .projects, let id = projectSelection {
            morePath.append(ProjectRoute(id: id))
            projectSelection = nil
        }
    }

    func openMeeting(_ id: String, at offset: Double? = nil) {
        meetingSelection = id
        meetingFocus = MeetingFocus(meetingID: id, offset: offset)
        open(.meetings)
    }

    func openDay(_ day: DayKey) {
        timelineDay = day
        open(.timeline)
    }

    func ask(about scope: AskRequest.Scope?, draft: String? = nil) {
        askScope = scope
        askDraft = draft
        newQuestionRequest += 1
        open(.ask)
    }

    func search() {
        searchRequest += 1
        open(.meetings)
    }
}

extension FocusedValues {
    @Entry var navigator: AppNavigator?
}
