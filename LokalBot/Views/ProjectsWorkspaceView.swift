import SwiftUI

/// Active projects from the overnight review, each joined to the meetings,
/// open actions, people, and tracked window time that name it.
struct ProjectsWorkspaceView: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var connections: WorkMemoryConnections

    var body: some View {
        HSplitView {
            list
                .frame(minWidth: 240, idealWidth: LBTokens.Metric.contentColumnWidth, maxWidth: 340)
                .splitPaneAccessibilityLabel("Projects", autosaveName: "LokalBot.projects",
                                             initialWidth: LBTokens.Metric.contentColumnWidth)
            detail
                .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
                .splitPaneAccessibilityLabel("Project details")
        }
        .task {
            // Projects come from Dream memory, which other sections load lazily.
            app.refreshDreamMemory()
            app.refreshConnections()
        }
        .onReceive(app.outcomeIndex.$projections.dropFirst()) { _ in app.refreshConnections() }
        .onChange(of: app.dreamMemory) { app.refreshConnections() }
    }

    private var list: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Projects").font(.title3.bold())
                Text(connections.hasLoaded ? "\(connections.projects.count) active" : "Loading…")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(WorkspaceMetric.cardPadding)
            List(selection: $app.selectedProjectID) {
                ForEach(connections.projects) { project in
                    ProjectRow(project: project).tag(project.id)
                }
            }
            .listStyle(.inset)
            .tint(Brand.tealFill)
            .accessibilityIdentifier("projects.list")
            .overlay {
                if connections.hasLoaded && connections.projects.isEmpty {
                    VStack(spacing: 10) {
                        Text("Projects come from the overnight review of your work. They appear once a review has identified active projects.")
                            .font(.callout).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Button("Configure Overnight Review") { app.openSettings(tab: .dayMemory) }
                    }
                    .padding(24)
                }
            }
        }
    }

    @ViewBuilder private var detail: some View {
        if let project = connections.projects.first(where: { $0.id == app.selectedProjectID })
            ?? (app.selectedProjectID == nil ? connections.projects.first : nil) {
            ProjectDetailView(project: project).id(project.id)
        } else {
            Text(connections.hasLoaded ? "Select a project." : "Loading projects…")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct ProjectRow: View {
    let project: ProjectProfile

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(project.name).font(.body.weight(.medium))
                if project.pinned {
                    Image(systemName: "pin.fill").font(.caption).foregroundStyle(.secondary)
                        .accessibilityLabel("Pinned")
                }
            }
            Text(summary)
                .font(.callout).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }

    private var summary: String {
        var parts: [String] = []
        if !project.meetings.isEmpty {
            parts.append("\(project.meetings.count) meeting\(project.meetings.count == 1 ? "" : "s")")
        }
        if !project.openActions.isEmpty { parts.append("\(project.openActions.count) open") }
        if project.trackedSeconds >= 60 { parts.append(ProjectDetailView.duration(project.trackedSeconds) + " this week") }
        return parts.isEmpty ? project.status : parts.joined(separator: " · ")
    }
}

struct ProjectDetailView: View {
    @EnvironmentObject var app: AppState
    let project: ProjectProfile

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: WorkspaceMetric.sectionGap) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(project.name).font(.largeTitle.bold())
                    Text(project.status).textSelection(.enabled)
                    Text("Last active \(project.lastActiveDay)\(project.pinned ? " · Pinned" : "")")
                        .font(.callout).foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        Button {
                            app.openAsk(query: "What is the latest on \(project.name)?",
                                        meetingIDs: project.meetings.isEmpty ? nil : project.meetingIDs)
                        } label: {
                            Label("Ask About This Project", systemImage: "sparkle.magnifyingglass")
                        }
                        .buttonStyle(.bordered)
                        Toggle(project.pinned ? "Pinned" : "Pin", isOn: Binding(
                            get: { project.pinned },
                            set: { app.setDreamMemoryPinned($0, for: .project(name: project.name)) }))
                            .toggleStyle(.button)
                            .disabled(app.dreaming.isDreaming)
                            .help("Keep this project in future overnight reviews")
                    }
                    Text("Linked on this Mac by the project name appearing in meeting titles and summaries, action text, and window titles.")
                        .font(.callout).foregroundStyle(.secondary)
                }

                WorkspaceSection(title: "Open Actions", icon: "checklist") {
                    if project.openActions.isEmpty {
                        EmptyWorkspaceRow(text: "No open actions mention this project.")
                    } else {
                        VStack(spacing: 0) {
                            ForEach(project.openActions) { thread in
                                ActionThreadRow(thread: thread)
                                if thread.id != project.openActions.last?.id { Divider() }
                            }
                        }
                    }
                }

                WorkspaceSection(title: "Time This Week", icon: "clock") {
                    if project.trackedSeconds < 60 {
                        EmptyWorkspaceRow(text: "No tracked windows named this project in the last \(ProjectLinks.reviewDays) days.")
                    } else {
                        LabeledContent("Total", value: Self.duration(project.trackedSeconds))
                        ForEach(project.days) { day in
                            LabeledContent(Self.dayLabel(day.dayKey), value: Self.duration(day.seconds))
                                .foregroundStyle(.secondary)
                        }
                        Divider()
                        ForEach(project.windows) { window in
                            HStack {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(window.title).lineLimit(1)
                                    Text(window.app).font(.callout).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(Self.duration(window.seconds)).foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                if !project.people.isEmpty {
                    WorkspaceSection(title: "People", icon: "person.2") {
                        FlowingNames(names: project.people) { name in
                            if let person = app.connections.people.first(where: { $0.name == name }) {
                                app.openPerson(person.id)
                            }
                        }
                    }
                }

                WorkspaceSection(title: "Meetings", icon: "waveform.circle") {
                    if project.meetings.isEmpty {
                        EmptyWorkspaceRow(text: "No recent meeting titles or summaries name this project.")
                    } else {
                        ForEach(project.meetings.prefix(20)) { meeting in
                            Button { app.openMeeting(meeting.id) } label: {
                                HStack {
                                    Text(meeting.title).lineLimit(1)
                                    Spacer()
                                    Text(meeting.startedAt.formatted(date: .abbreviated, time: .omitted))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                            .padding(.vertical, 3)
                        }
                    }
                }
            }
            .padding(WorkspaceMetric.pagePadding)
            .frame(maxWidth: WorkspaceMetric.contentMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .navigationTitle(project.name)
        .accessibilityIdentifier("project.detail")
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(max(1, minutes))m"
    }

    static func dayLabel(_ key: String) -> String {
        AskDayScope.date(for: key)?.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()) ?? key
    }
}

/// Names as quiet link buttons that wrap to the available width.
private struct FlowingNames: View {
    let names: [String]
    let onSelect: (String) -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { buttons }
            VStack(alignment: .leading, spacing: 6) { buttons }
        }
    }

    @ViewBuilder private var buttons: some View {
        ForEach(names, id: \.self) { name in
            Button(name) { onSelect(name) }
                .buttonStyle(.workspaceLink)
        }
    }
}
