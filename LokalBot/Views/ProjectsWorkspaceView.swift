import SwiftUI

/// Active projects from the overnight review and topics that recur across
/// meetings, each joined to the meetings, open actions, decisions, people,
/// and tracked window time that name it.
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

    private var reviewed: [ProjectProfile] { connections.projects.filter { $0.source == .overnightReview } }
    private var topics: [ProjectProfile] { connections.projects.filter { $0.source == .recurringTopic } }

    private var countSummary: String {
        var parts: [String] = []
        if !reviewed.isEmpty { parts.append("\(reviewed.count) from review") }
        if !topics.isEmpty { parts.append("\(topics.count) recurring") }
        return parts.isEmpty ? "None yet" : parts.joined(separator: " · ")
    }

    private var list: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Projects").font(.scaled(.title3).bold())
                Text(connections.hasLoaded ? countSummary : "Loading…")
                    .font(.scaled(.callout)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(WorkspaceMetric.cardPadding)
            List(selection: $app.selectedProjectID) {
                if !reviewed.isEmpty {
                    Section("From Overnight Review") {
                        ForEach(reviewed) { ProjectRow(project: $0).tag($0.id) }
                    }
                }
                if !topics.isEmpty {
                    Section("Recurring in Meetings") {
                        ForEach(topics) { ProjectRow(project: $0).tag($0.id) }
                    }
                }
            }
            .listStyle(.inset)
            .tint(Brand.tealFill)
            .accessibilityIdentifier("projects.list")
            .overlay {
                if connections.hasLoaded && connections.projects.isEmpty {
                    VStack(spacing: 10) {
                        Text("Projects appear when the overnight review names active work, or when a product, client, or codename comes up in \(ProjectTopicDetector.minimumMeetings) or more meetings.")
                            .font(.scaled(.callout)).foregroundStyle(.secondary)
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
        HStack(spacing: 10) {
            ProjectMonogram(project: project, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(project.name).font(.scaled(.body).weight(.medium)).lineLimit(1)
                    if project.pinned {
                        Image(systemName: "pin.fill").font(.scaled(.caption)).foregroundStyle(.secondary)
                            .accessibilityLabel("Pinned")
                    }
                }
                Text(ProjectDetailView.summary(project))
                    .font(.scaled(.callout)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }
}

/// The project's first letter on a tint chosen from its name.
private struct ProjectMonogram: View {
    let project: ProjectProfile
    var size: CGFloat = 30

    var body: some View {
        let color = InitialsAvatar.color(for: project.name)
        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
            .fill(color.opacity(0.16))
            .overlay(RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                .strokeBorder(color.opacity(0.28), lineWidth: 0.5))
            .overlay {
                Text(project.name.first.map { String($0).uppercased() } ?? "")
                    .font(.system(size: size * 0.46, weight: .semibold, design: .rounded))
                    .foregroundStyle(color)
            }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

struct ProjectDetailView: View {
    @EnvironmentObject var app: AppState
    let project: ProjectProfile

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: WorkspaceMetric.sectionGap) {
                header

                if !project.openActions.isEmpty {
                    WorkspaceSection(title: "Open Actions", icon: "checklist") {
                        VStack(spacing: 0) {
                            ForEach(project.openActions) { thread in
                                ActionThreadRow(thread: thread)
                                if thread.id != project.openActions.last?.id { Divider() }
                            }
                        }
                    }
                }

                if !project.decisions.isEmpty {
                    WorkspaceSection(title: "Decisions", icon: "checkmark.seal") {
                        ForEach(project.decisions) { decision in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(decision.text).textSelection(.enabled)
                                Button("\(decision.meetingTitle) · \(decision.meetingDate.formatted(date: .abbreviated, time: .omitted))") {
                                    app.openMeeting(decision.meetingID)
                                }
                                .buttonStyle(.workspaceLink)
                                .font(.scaled(.callout))
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }

                if project.trackedSeconds >= 60 {
                    WorkspaceSection(title: "Time This Week", icon: "clock") {
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
                                    Text(window.app).font(.scaled(.callout)).foregroundStyle(.secondary)
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
                        VStack(spacing: 0) {
                            ForEach(project.meetings.prefix(20)) { meeting in
                                ProjectMeetingRow(meeting: meeting) { app.openMeeting(meeting.id) }
                                if meeting.id != project.meetings.prefix(20).last?.id { Divider() }
                            }
                        }
                    }
                }

                Text(provenance)
                    .font(.scaled(.caption)).foregroundStyle(.tertiary)
            }
            .padding(WorkspaceMetric.pagePadding)
            .frame(maxWidth: WorkspaceMetric.contentMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .navigationTitle(project.name)
        .accessibilityIdentifier("project.detail")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 14) {
                ProjectMonogram(project: project, size: 56)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(project.name).font(.scaled(.largeTitle).bold())
                        SourceBadge(source: project.source)
                    }
                    Text(Self.summary(project, long: true))
                        .font(.scaled(.callout)).foregroundStyle(.secondary)
                }
            }
            if project.source == .overnightReview, !project.status.isEmpty {
                Text(project.status).textSelection(.enabled)
            }
            HStack(spacing: 8) {
                Button {
                    app.openAsk(query: "What is the latest on \(project.name)?",
                                meetingIDs: project.meetings.isEmpty ? nil : project.meetingIDs)
                } label: {
                    Label("Ask About \(project.name)", systemImage: "sparkle.magnifyingglass")
                }
                .buttonStyle(.bordered)
                if project.source == .overnightReview {
                    Toggle(isOn: Binding(
                        get: { project.pinned },
                        set: { app.setDreamMemoryPinned($0, for: .project(name: project.name)) })) {
                        Label(project.pinned ? "Pinned" : "Pin", systemImage: project.pinned ? "pin.fill" : "pin")
                    }
                    .toggleStyle(.button)
                    .disabled(app.dreaming.isDreaming)
                    .help("Keep this project in future overnight reviews")
                }
            }
        }
    }

    private var provenance: String {
        switch project.source {
        case .overnightReview:
            "Named by the overnight review. Linked on this Mac wherever the project name appears in meeting titles and summaries, action text, and window titles."
        case .recurringTopic:
            "Found on this Mac because the name recurs in meeting titles, summaries, actions, and decisions. People, apps, and generic terms are left out."
        }
    }

    /// "13 meetings · 2 open · 3h 20m this week", plus decisions and the
    /// last mention in the detail header.
    static func summary(_ project: ProjectProfile, long: Bool = false) -> String {
        var parts: [String] = []
        if !project.meetings.isEmpty {
            parts.append("\(project.meetings.count) meeting\(project.meetings.count == 1 ? "" : "s")")
        }
        if !project.openActions.isEmpty { parts.append("\(project.openActions.count) open") }
        if long, !project.decisions.isEmpty {
            parts.append("\(project.decisions.count) decision\(project.decisions.count == 1 ? "" : "s")")
        }
        if project.trackedSeconds >= 60 { parts.append(duration(project.trackedSeconds) + " this week") }
        if long, let last = project.meetings.first?.startedAt ?? AskDayScope.date(for: project.lastActiveDay) {
            parts.append("last " + PersonDetailView.relativeDay(last))
        }
        return parts.isEmpty ? project.status : parts.joined(separator: " · ")
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(max(1, minutes))m"
    }

    static func dayLabel(_ key: String) -> String {
        AskDayScope.date(for: key)?.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()) ?? key
    }
}

/// Where a project came from, as a small label beside its name.
private struct SourceBadge: View {
    let source: ProjectProfile.Source

    var body: some View {
        Label(source == .overnightReview ? "Overnight review" : "Recurring topic",
              systemImage: source == .overnightReview ? "moon.stars" : "arrow.triangle.2.circlepath")
            .font(.scaled(.caption).weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(LBTokens.Palette.groupFill))
            .overlay(Capsule().strokeBorder(LBTokens.Palette.groupStroke, lineWidth: 0.5))
    }
}

/// A meeting that names the project, with the summary line that does.
private struct ProjectMeetingRow: View {
    let meeting: ProjectProfile.MeetingRef
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(meeting.title).lineLimit(1)
                    Spacer()
                    Text(meeting.startedAt.formatted(date: .abbreviated, time: .omitted))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                if let mention = meeting.mention {
                    Text(mention)
                        .font(.scaled(.callout))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 6)
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
