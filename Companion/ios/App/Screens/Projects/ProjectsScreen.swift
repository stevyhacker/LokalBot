import LokalBotCompanionKit
import SwiftUI

struct ProjectsSplit: View {
    @Environment(AppNavigator.self) private var navigator
    @State private var selection: ProjectRoute?

    var body: some View {
        NavigationSplitView {
            ProjectsList(selection: $selection)
        } detail: {
            NavigationStack {
                if let selection {
                    ProjectDetailScreen(projectID: selection.id).companionDestinations()
                } else {
                    ContentUnavailableView("Choose a project", systemImage: "folder",
                                           description: Text("Where it stands, your actions and what you're waiting on."))
                }
            }
            .id(selection)
        }
        .onAppear(perform: consumeSelection)
        .onChange(of: navigator.projectSelection) { consumeSelection() }
    }

    private func consumeSelection() {
        guard let id = navigator.projectSelection else { return }
        selection = ProjectRoute(id: id)
        navigator.projectSelection = nil
    }
}

struct ProjectsList: View {
    @Environment(CompanionSession.self) private var session
    let selection: Binding<ProjectRoute?>?
    @State private var model = ProjectsModel()

    var body: some View {
        Group {
            if let selection {
                List(selection: selection) { rows }
            } else {
                List { rows }
            }
        }
        .listStyle(.plain)
        .tint(Brand.tealFill)
        .overlay {
            if model.loaded && model.projects.isEmpty {
                ContentUnavailableView("No projects yet", systemImage: "folder",
                                       description: Text("Projects you track on your Mac appear here."))
            }
        }
        .navigationTitle("Projects")
        .refreshable { await session.syncNow() }
        .task(id: session.revision) { await model.load(session) }
    }

    private var rows: some View {
        ForEach(model.projects) { project in
            NavigationLink(value: ProjectRoute(id: project.id)) {
                HStack(spacing: 12) {
                    ProjectMonogram(name: project.name, size: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(project.name).font(LBTokens.Typography.body.weight(.medium)).lineLimit(1)
                        Text(summary(project))
                            .font(LBTokens.Typography.secondary)
                            .foregroundStyle(LBTokens.Palette.supporting)
                            .lineLimit(1)
                    }
                }
                .padding(.vertical, 3)
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func summary(_ project: Project) -> String {
        let open = project.yourActions.filter { $0.status == .open }.count
        var parts: [String] = []
        if open > 0 { parts.append("\(open) yours open") }
        if !project.waitingOnOthers.isEmpty { parts.append("\(project.waitingOnOthers.count) waiting on others") }
        if project.timeThisWeekSeconds > 0 { parts.append("\(LBFormat.hm(project.timeThisWeekSeconds)) this week") }
        return parts.isEmpty ? "\(project.meetingIds.count) meetings" : parts.joined(separator: " · ")
    }
}

struct ProjectDetailScreen: View {
    let projectID: String
    @Environment(CompanionSession.self) private var session
    @Environment(AppNavigator.self) private var navigator
    @State private var model: ProjectDetailModel

    init(projectID: String) {
        self.projectID = projectID
        _model = State(initialValue: ProjectDetailModel(projectID: projectID))
    }

    var body: some View {
        ScrollView {
            if let project = model.project {
                VStack(alignment: .leading, spacing: LBTokens.Spacing.sectionSpacing) {
                    HStack(spacing: 14) {
                        ProjectMonogram(name: project.name, size: 56)
                        Text(project.name).font(LBTokens.Typography.pageTitle).lineLimit(2)
                    }
                    .accessibilityElement(children: .combine)
                    if let stands = project.whereItStands, !stands.isEmpty {
                        WorkspaceSection("Where It Stands", icon: "text.alignleft") {
                            MarkdownText(stands).padding(.vertical, 6)
                        }
                    }
                    if !project.yourActions.isEmpty {
                        WorkspaceSection("Your Actions", icon: "checklist") {
                            OpenWorkList(items: project.yourActions.map {
                                OpenWorkItem(meetingID: $0.meetingId, actionID: $0.actionId, text: $0.text,
                                             dueDate: $0.dueDate, owner: nil, status: $0.status)
                            }, meetings: model.meetings)
                        }
                    }
                    if !project.waitingOnOthers.isEmpty {
                        WorkspaceSection("Waiting on Others", icon: "person.2.badge.gearshape") {
                            OpenWorkList(items: project.waitingOnOthers.map {
                                OpenWorkItem(meetingID: $0.meetingId, actionID: $0.actionId, text: $0.text,
                                             dueDate: $0.dueDate, owner: $0.owner, status: .open)
                            }, meetings: model.meetings)
                        }
                    }
                    if !project.decisions.isEmpty {
                        WorkspaceSection("Decisions", icon: "checkmark.seal") {
                            ForEach(Array(project.decisions.enumerated()), id: \.offset) { _, decision in
                                LinkedTextRow(text: decision.text, meeting: model.meetings[decision.meetingId],
                                              meetingID: decision.meetingId)
                            }
                        }
                    }
                    WorkspaceSection("Time This Week", icon: "clock") {
                        HStack {
                            StatTile(icon: "clock", value: LBFormat.hm(project.timeThisWeekSeconds), label: "tracked")
                            Spacer()
                        }
                        .padding(.vertical, 6)
                    }
                    if !project.people.isEmpty {
                        WorkspaceSection("People", icon: "person.2") {
                            FlowLayout(spacing: 8, lineSpacing: 8) {
                                ForEach(project.people) { person in
                                    NavigationLink(value: PersonRoute(id: person.id)) {
                                        HStack(spacing: 6) {
                                            InitialsAvatar(name: person.displayName, size: 22)
                                            Text(person.displayName).font(LBTokens.Typography.secondary)
                                        }
                                        .padding(.leading, 3)
                                        .padding(.trailing, 10)
                                        .padding(.vertical, 3)
                                        .background(LBTokens.Palette.chipFill, in: Capsule())
                                    }
                                    .buttonStyle(.plain)
                                    .lbHoverEffect()
                                }
                            }
                            .padding(.vertical, 6)
                        }
                    }
                    if !model.projectMeetings.isEmpty {
                        WorkspaceSection("Meetings", icon: "waveform.circle") {
                            MeetingLinkList(meetings: model.projectMeetings)
                        }
                    }
                }
                .pageColumn(maxWidth: 760)
            } else if model.loaded {
                ContentUnavailableView("Not on this device", systemImage: "folder")
                    .padding(.top, 80)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let project = model.project {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        navigator.ask(about: nil, draft: "What is the latest on \(project.name)?")
                    } label: {
                        Label("Ask About \(project.name)", systemImage: "sparkle.magnifyingglass")
                    }
                }
            }
        }
        .refreshable { await session.syncNow() }
        .task(id: session.revision) { await model.load(session) }
    }
}
