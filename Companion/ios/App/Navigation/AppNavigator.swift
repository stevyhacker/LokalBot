import LokalBotCompanionKit
import Observation
import SwiftUI

/// Top-level destinations, in the Mac sidebar's order.
enum AppSection: String, CaseIterable, Hashable, Identifiable, Codable {
    case today, actions, meetings, timeline, people, projects, ask, settings
    /// iPhone and compact widths only: Timeline, People, Projects and Settings.
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

    /// Sections the tab bar reaches through More.
    var livesUnderMore: Bool {
        [.timeline, .people, .projects, .settings].contains(self)
    }

    /// ⌘1–⌘7, in sidebar order.
    static let shortcutOrder: [AppSection] = [.today, .actions, .meetings, .timeline, .people, .projects, .ask]
}

/// Where the app is and where a link asks it to go: meetings opened at a
/// moment, an action, a day, a person. Works the same in the tab bar and the
/// sidebar; More holds Timeline, People, Projects and Settings in compact width.
@MainActor @Observable
final class AppNavigator {
    struct MeetingFocus: Equatable {
        let meetingID: String
        let offset: Double?
        let id = UUID()
    }

    /// The selected tab.
    var tab: AppSection = .today
    var isCompact = false
    /// More's stack in compact width: a section, then what it opened.
    var morePath = NavigationPath()
    private(set) var moreSection: AppSection?

    var meetingSelection: String?
    var meetingFocus: MeetingFocus?
    var actionSelection: String?
    var personSelection: String?
    var projectSelection: String?
    var timelineDay: DayKey?

    /// Bumped to focus the meeting search (⌘F) or start a new question (⌘N).
    var searchRequest = 0
    var newQuestionRequest = 0
    var askScope: AskRequest.Scope?
    /// A question to put in the composer, ready to send.
    var askDraft: String?

    /// Debug launch arguments for screenshots (DemoLaunch).
    var demoQuestion: String?
    var demoMeetingTab: String?
    var demoPairingLink: String?

    /// The section on screen, whichever way it was reached.
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

    /// Size class changed: keep the same section on screen.
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

    /// A section reached by tapping its row under More.
    func showing(_ section: AppSection) {
        moreSection = section
    }

    /// In compact width People and Projects are stacks under More, so a
    /// chosen person or project is pushed rather than selected.
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

    func openAction(_ id: String) {
        actionSelection = id
        open(.actions)
    }

    func openDay(_ day: DayKey) {
        timelineDay = day
        open(.timeline)
    }

    func openPerson(_ id: String) {
        personSelection = id
        open(.people)
    }

    func openProject(_ id: String) {
        projectSelection = id
        open(.projects)
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
