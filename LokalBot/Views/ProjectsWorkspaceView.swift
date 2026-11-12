import SwiftUI

/// Projects the person tracks, plus suggestions: names that recur across
/// meetings and overnight review projects nobody tracks yet. The list shows
/// tracked projects by last activity, then suggestions with where each came
/// from. The page beside it leads with "Where it stands", the one block a
/// model wrote, and lists the facts that name the project under it: actions,
/// decisions, meetings, and, in a side column, window time, people and names.
/// Tracked projects, their names, and hidden suggestions live in
/// `ProjectStore`.
struct ProjectsWorkspaceView: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var connections: WorkMemoryConnections
    @ObservedObject var store: ProjectStore
    @SceneStorage("projects.query") private var query = ""
    @State private var addingProject = false
    @State private var editingNames: ProjectProfile?
    @State private var compactToolbar = false

    var body: some View {
        let language = app.settings.appLanguage
        let settling = Self.settlingProfile(selection: app.selectedProjectID, curation: store.curation,
                                            projects: connections.projects)
        let projects = Self.listProjects(connections.projects, settling: settling)
        let content = ProjectsListContent.build(
            projects: projects, query: query, now: Date(),
            locale: PeopleWording.formattingLocale(language.locale), localize: language.catalog)
        let selected = selectedProject(content, in: projects)
        let commands = commands(content: content, selectedID: selected?.id)
        return HSplitView {
            ProjectsListColumn(
                content: content, projects: projects, hasLoaded: connections.hasLoaded, store: store,
                query: $query,
                selection: Binding(get: { app.selectedProjectID ?? selected?.id },
                                   set: { app.selectedProjectID = $0 }),
                selectedID: selected?.id, commands: commands, onAdd: { addingProject = true })
                .frame(minWidth: LBTokens.Metric.contentColumnMinWidth,
                       idealWidth: LBTokens.Metric.contentColumnWidth, maxWidth: 340)
                .splitPaneAccessibilityLabel("Projects", autosaveName: "LokalBot.projects",
                                             initialWidth: LBTokens.Metric.contentColumnWidth)
            detail(selected, isSettling: settling != nil && settling?.id == selected?.id,
                   projects: projects, commands: commands)
                .frame(minWidth: LBTokens.Metric.contentDetailMinWidth, maxWidth: .infinity, maxHeight: .infinity)
                .splitPaneAccessibilityLabel("Project details")
        }
        .detailSplitMinimumWidth([LBTokens.Metric.contentColumnMinWidth, LBTokens.Metric.contentDetailMinWidth])
        // The selected project is the window's title; the toolbar draws it
        // with its monogram and when it was last active.
        .navigationTitle(selected.map { Text(verbatim: $0.name) } ?? Text("Projects"))
        .toolbar(removing: .title)
        .toolbar { toolbar(selected, commands: commands) }
        .onGeometryChange(for: Bool.self) { $0.size.width < 720 } action: { compactToolbar = $0 }
        .task {
            // Review notes come from Dream memory, which other sections load lazily.
            app.refreshDreamMemory()
            app.refreshConnections()
        }
        .onReceive(app.outcomeIndex.$projections.dropFirst()) { _ in app.refreshConnections() }
        .onChange(of: app.dreamMemory) { app.refreshConnections() }
        .onChange(of: store.curation) { app.refreshConnections() }
        .sheet(isPresented: $addingProject) {
            ProjectNameSheet(title: Text("Track a project"), actionTitle: "Track", name: "", otherNames: []) { name, others in
                if let id = store.track(name: name, otherNames: others) {
                    app.selectedProjectID = ProjectsWorkspaceView.trackedSelectionID(id)
                }
            }
        }
        .sheet(item: $editingNames) { project in
            ProjectNameSheet(title: Text("Names for \(project.name)"), actionTitle: "Save", name: project.name,
                             otherNames: project.otherNames, startsOnOtherNames: true) { name, others in
                if let id = project.trackedID { store.update(id, name: name, otherNames: others) }
            }
        }
    }

    static func trackedSelectionID(_ id: UUID) -> String { "tracked:" + id.uuidString }

    /// With nothing chosen, the page opens on the first row: the most
    /// recently active tracked project, else the first suggestion.
    private func selectedProject(_ content: ProjectsListContent, in projects: [ProjectProfile]) -> ProjectProfile? {
        guard let id = app.selectedProjectID else {
            return content.projectIDs.first.flatMap { first in projects.first { $0.id == first } }
        }
        return projects.first { $0.id == id }
    }

    /// A suggestion that was just tracked stays on screen, already marked as
    /// tracked, until the next refresh delivers its tracked profile. Nothing is
    /// written from this copy: its evidence is about to be replaced.
    static func settlingProfile(selection: String?, curation: ProjectCuration,
                                projects: [ProjectProfile]) -> ProjectProfile? {
        guard let selection, !projects.contains(where: { $0.id == selection }),
              let tracked = curation.tracked.first(where: { trackedSelectionID($0.id) == selection }),
              let suggestion = projects.first(where: {
                  !$0.isTracked && PeopleDirectory.normalized($0.name) == PeopleDirectory.normalized(tracked.name)
              }) else { return nil }
        return suggestion.tracked(as: tracked.id, selectionID: selection)
    }

    /// The projects the list and the page draw: while a just-tracked
    /// suggestion settles, its tracked copy stands in for the suggestion, so
    /// the row moves under Tracked at once and stays selected.
    static func listProjects(_ projects: [ProjectProfile], settling: ProjectProfile?) -> [ProjectProfile] {
        guard let settling else { return projects }
        let name = PeopleDirectory.normalized(settling.name)
        return [settling] + projects.filter { $0.isTracked || PeopleDirectory.normalized($0.name) != name }
    }

    /// Tracking, adding a name, hiding, merging and stopping, as the list's
    /// context menus, the page and the toolbar menu all run them.
    private func commands(content: ProjectsListContent, selectedID: String?) -> ProjectCommands {
        ProjectCommands(
            track: { project in
                if let id = store.track(name: project.name) {
                    app.selectedProjectID = Self.trackedSelectionID(id)
                }
            },
            add: { project, targetID in
                store.addName(project.name, to: targetID)
                app.selectedProjectID = Self.trackedSelectionID(targetID)
            },
            hide: { project in
                store.hideSuggestion(named: project.name)
                // The open suggestion makes way for the next one; hiding
                // another row from its menu leaves the page where it is.
                if selectedID == project.id { app.selectedProjectID = content.selection(afterRemoving: project.id) }
            },
            editNames: { editingNames = $0 },
            merge: { sourceID, targetID in
                store.merge(sourceID, into: targetID)
                app.selectedProjectID = Self.trackedSelectionID(targetID)
            },
            stopTracking: { id in
                store.stopTracking(id)
                app.selectedProjectID = nil
            })
    }

    // MARK: - Page

    @ViewBuilder private func detail(_ project: ProjectProfile?, isSettling: Bool, projects: [ProjectProfile],
                                     commands: ProjectCommands) -> some View {
        if let project {
            ProjectDetailView(project: project, store: store, isSettling: isSettling,
                              home: ProjectSuggestionHome.match(for: project, among: projects),
                              commands: commands)
                .id(project.id)
        } else if !connections.hasLoaded || app.selectedProjectID?.hasPrefix("tracked:") == true {
            // A project tracked a moment ago appears after the next refresh.
            LoadingStateLabel(app.settings.appLanguage.localized("Loading projects…"), font: AppFont.scaled(.body))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Text("Select a project.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder private func toolbar(_ project: ProjectProfile?,
                                                commands: ProjectCommands) -> some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            if let project {
                let language = app.settings.appLanguage
                HStack(spacing: 8) {
                    ProjectMonogram(name: project.name, size: 26, isSuggestion: !project.isTracked)
                    Text(verbatim: project.name)
                        .font(LBTokens.Typography.columnTitle)
                        .lineLimit(1)
                    if !compactToolbar {
                        Text(verbatim: ProjectsWording.subtitle(
                            for: project,
                            trackedSince: project.trackedID.flatMap { store.curation.tracked($0)?.createdAt },
                            locale: PeopleWording.formattingLocale(language.locale), localize: language.catalog))
                            .font(AppFont.scaled(.callout).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("project.title")
            } else {
                Text("Projects").font(LBTokens.Typography.columnTitle)
            }
        }
        if let project {
            ToolbarItemGroup(placement: .primaryAction) {
                // A project nothing names yet has nothing to ask about.
                if !ProjectPagePresentation.isEmpty(project) {
                    // Words and the icon while the toolbar has room, the icon
                    // alone when it does not.
                    if compactToolbar {
                        askButton(project).labelStyle(.iconOnly)
                    } else {
                        askButton(project).labelStyle(.titleAndIcon)
                    }
                }
                if let trackedID = project.trackedID {
                    WorkspaceMenu(title: app.settings.appLanguage.localized("More"), symbol: "ellipsis",
                                  identifier: "project.menu",
                                  items: menuItems(project, trackedID: trackedID, commands: commands))
                }
            }
        }
    }

    private func askButton(_ project: ProjectProfile) -> some View {
        Button {
            app.openAsk(query: "What is the latest on \(project.name)?",
                        meetingIDs: project.meetings.isEmpty ? nil : project.meetingIDs)
        } label: {
            Label("Ask about \(project.name)", systemImage: "magnifyingglass")
        }
        .help("Ask about \(project.name)")
        .accessibilityIdentifier("project.ask")
    }

    /// Edit names, merge into another tracked project, stop tracking.
    private func menuItems(_ project: ProjectProfile, trackedID: UUID,
                           commands: ProjectCommands) -> [WorkspaceMenu.Item] {
        let language = app.settings.appLanguage
        var items: [WorkspaceMenu.Item] = [
            .init(title: language.localized("Edit names…"), identifier: "project.menu.editNames",
                  action: { commands.editNames(project) }),
        ]
        let others = store.curation.tracked.filter { $0.id != trackedID }
        if !others.isEmpty {
            items.append(.init(
                title: language.localized("Merge into"), identifier: "project.menu.merge",
                children: others.map { target in
                    .init(title: target.name, action: { commands.merge(trackedID, target.id) })
                }))
        }
        items += [
            .separator,
            .init(title: language.localized("Stop tracking"), identifier: "project.menu.stopTracking",
                  action: { commands.stopTracking(trackedID) }),
        ]
        return items
    }
}

/// What can be done to a project, run the same way from a row's menu, the
/// page and the toolbar.
struct ProjectCommands {
    /// Starts tracking a suggestion and opens it.
    var track: (ProjectProfile) -> Void
    /// Adds a suggestion's name to a tracked project and opens that project.
    var add: (ProjectProfile, UUID) -> Void
    /// "Not a project": the name is no longer suggested.
    var hide: (ProjectProfile) -> Void
    var editNames: (ProjectProfile) -> Void
    /// Folds the first tracked project into the second.
    var merge: (UUID, UUID) -> Void
    var stopTracking: (UUID) -> Void
}

/// The list column: a search field and the add button as its header, then
/// tracked projects and suggestions. Hidden suggestions are shown again from
/// its foot.
struct ProjectsListColumn: View {
    @EnvironmentObject var app: AppState
    let content: ProjectsListContent
    let projects: [ProjectProfile]
    let hasLoaded: Bool
    @ObservedObject var store: ProjectStore
    @Binding var query: String
    let selection: Binding<String?>
    /// The project the page shows, which is the first row before any choice.
    let selectedID: String?
    let commands: ProjectCommands
    let onAdd: () -> Void

    private var hasNoProjects: Bool { projects.isEmpty && store.curation.tracked.isEmpty }

    var body: some View {
        let language = app.settings.appLanguage
        let projectsByID = Dictionary(projects.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return VStack(spacing: 0) {
            HStack(spacing: 6) {
                ListColumnSearchField(prompt: "Search projects", text: $query, identifier: "projects.search")
                Button(action: onAdd) {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("Track a project")
                .accessibilityLabel("Track a project")
                .accessibilityIdentifier("projects.add")
            }
            .padding(.horizontal, 10)
            .padding(.top, 10)
            .padding(.bottom, 8)
            ScrollViewReader { proxy in
                List(selection: selection) {
                    if !content.tracked.isEmpty {
                        heading("Tracked", identifier: "projects.group.tracked")
                        rows(content.tracked, projectsByID: projectsByID, localize: language.catalog)
                    }
                    if !content.suggested.isEmpty {
                        heading("Suggested", identifier: "projects.group.suggested")
                        rows(content.suggested, projectsByID: projectsByID, localize: language.catalog)
                    }
                    if !store.curation.hiddenNames.isEmpty {
                        Button {
                            store.restoreHiddenSuggestions()
                        } label: {
                            Text(verbatim: ProjectsWording.showHidden(
                                store.curation.hiddenNames.count, localize: language.catalog))
                        }
                        .buttonStyle(.workspaceLink)
                        .font(.scaled(.callout))
                        .padding(.top, 6)
                        .selectionDisabled(true)
                        .listRowSeparator(.hidden)
                        .accessibilityIdentifier("projects.restoreHidden")
                    }
                }
                .listStyle(.inset)
                .tint(Brand.tealFill)
                .accessibilityIdentifier("projects.list")
                // A project opened from Actions, People or Timeline may sit
                // below the fold.
                .onChange(of: selectedID) { _, id in
                    if let id { proxy.scrollTo(id) }
                }
                .onAppear {
                    guard let id = app.selectedProjectID else { return }
                    DispatchQueue.main.async { proxy.scrollTo(id) }
                }
            }
            .overlay {
                if !hasLoaded && projects.isEmpty {
                    LoadingStateLabel(language.localized("Loading…"), font: AppFont.scaled(.body))
                } else if hasLoaded && hasNoProjects {
                    VStack(spacing: 10) {
                        Text("Add the projects you work on, and LokalBot gathers their meetings, actions, and decisions. It also suggests names that come up in \(ProjectTopicDetector.minimumMeetings) or more meetings.")
                            .font(.scaled(.callout)).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Button("Track a project", action: onAdd)
                    }
                    .padding(24)
                } else if content.isEmpty && !projects.isEmpty {
                    Text("No matches")
                        .font(.scaled(.callout)).foregroundStyle(.secondary)
                        .padding(24)
                }
            }
        }
    }

    /// A heading row, as in the People and Meetings lists: it scrolls with
    /// its projects and arrow keys pass over it.
    private func heading(_ title: LocalizedStringKey, identifier: String) -> some View {
        SectionHeader(text: title)
            .padding(.top, 6)
            .selectionDisabled(true)
            .listRowSeparator(.hidden)
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier(identifier)
    }

    private func rows(_ rows: [ProjectsListContent.Row], projectsByID: [String: ProjectProfile],
                      localize: @escaping (String) -> String) -> some View {
        ForEach(rows) { row in
            ProjectRow(row: row, isSelected: row.id == selectedID, localize: localize)
                .tag(row.id)
                .listRowSeparator(.hidden)
                .contextMenu {
                    if let project = projectsByID[row.id] {
                        ProjectMenuItems(project: project, store: store, commands: commands)
                    }
                }
        }
    }
}

/// One project in the list: its monogram and name, when it was last active
/// or where the suggestion came from, and the user's open actions.
private struct ProjectRow: View {
    let row: ProjectsListContent.Row
    /// From the list's selection, like the meeting and people rows: the
    /// supporting grey does not read on the highlight.
    var isSelected = false
    let localize: (String) -> String

    private var supporting: AnyShapeStyle {
        isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(Color(nsColor: WorkspaceTextColor.supporting))
    }

    var body: some View {
        HStack(spacing: 10) {
            ProjectMonogram(name: row.name, size: 28, isSuggestion: row.isSuggestion)
                .opacity(row.isQuiet ? 0.5 : 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: row.name)
                    .font(.scaled(.body).weight(row.isSuggestion || row.isQuiet ? .medium : .semibold))
                    .foregroundStyle(row.isQuiet ? supporting : AnyShapeStyle(.primary))
                    .lineLimit(1)
                Text(verbatim: row.detail)
                    .font(.scaled(.callout))
                    .foregroundStyle(supporting)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if row.openActions > 0 {
                Text(row.openActions, format: .number)
                    .font(AppFont.scaled(.callout).monospacedDigit())
                    .foregroundStyle(supporting)
                    .help(ProjectsWording.openActions(row.openActions, localize: localize))
                    .accessibilityLabel(Text(verbatim: ProjectsWording.openActions(row.openActions, localize: localize)))
                    .layoutPriority(1)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("projects.row.\(row.id)")
    }
}

/// The project's first letter on a tint chosen from its name. A suggestion,
/// which nobody tracks yet, is a dashed outline.
struct ProjectMonogram: View {
    let name: String
    var size: CGFloat = 28
    var isSuggestion = false

    var body: some View {
        let color = InitialsAvatar.color(for: name)
        let shape = RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
        Group {
            if isSuggestion {
                shape.strokeBorder(Color.secondary.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [3, 2.5]))
            } else {
                shape.fill(color.opacity(0.16))
                    .overlay(shape.strokeBorder(color.opacity(0.28), lineWidth: 0.5))
            }
        }
        .overlay {
            Text(verbatim: name.first.map { String($0).uppercased() } ?? "")
                .font(.system(size: size * 0.46, weight: .semibold, design: .rounded))
                .foregroundStyle(isSuggestion ? AnyShapeStyle(.secondary) : AnyShapeStyle(color))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// A row's context menu: names, merge and stop for a tracked project; the
/// three answers for a suggestion. The page and the toolbar offer the same.
private struct ProjectMenuItems: View {
    let project: ProjectProfile
    @ObservedObject var store: ProjectStore
    let commands: ProjectCommands

    var body: some View {
        if let id = project.trackedID {
            let others = store.curation.tracked.filter { $0.id != id }
            Button("Edit names…") { commands.editNames(project) }
            if !others.isEmpty {
                Menu("Merge into") {
                    ForEach(others) { target in
                        Button {
                            commands.merge(id, target.id)
                        } label: {
                            Text(verbatim: target.name)
                        }
                    }
                }
            }
            Divider()
            Button("Stop tracking") { commands.stopTracking(id) }
        } else {
            Button("Track") { commands.track(project) }
            if !store.curation.tracked.isEmpty {
                Menu("Add to a project") {
                    ForEach(store.curation.tracked) { target in
                        Button {
                            commands.add(project, target.id)
                        } label: {
                            Text(verbatim: target.name)
                        }
                    }
                }
            }
            Divider()
            Button("Not a project") { commands.hide(project) }
        }
    }
}

/// Names a tracked project: its main name and other names for the same work.
private struct ProjectNameSheet: View {
    private enum Field { case name, otherNames }

    @Environment(\.dismiss) private var dismiss
    let title: Text
    let actionTitle: LocalizedStringKey
    /// Opened to add another name, so typing starts there.
    let startsOnOtherNames: Bool
    @State private var name: String
    @State private var otherNamesText: String
    @FocusState private var focus: Field?
    let onSave: (String, [String]) -> Void

    init(title: Text, actionTitle: LocalizedStringKey, name: String, otherNames: [String],
         startsOnOtherNames: Bool = false, onSave: @escaping (String, [String]) -> Void) {
        self.title = title
        self.actionTitle = actionTitle
        self.startsOnOtherNames = startsOnOtherNames
        _name = State(initialValue: name)
        _otherNamesText = State(initialValue: otherNames.joined(separator: ", "))
        self.onSave = onSave
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            title.font(.scaled(.title3).bold())
            Form {
                TextField("Name", text: $name)
                    .focused($focus, equals: .name)
                    .accessibilityIdentifier("project.name")
                TextField("Other names", text: $otherNamesText,
                          prompt: Text("Codenames or clients, separated by commas"))
                    .focused($focus, equals: .otherNames)
                    .accessibilityIdentifier("project.otherNames")
            }
            .formStyle(.columns)
            Text("Meetings, actions, and window titles that use any of these names are linked to the project.")
                .font(.scaled(.callout)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(actionTitle) {
                    let others: [String] = otherNamesText.split(separator: ",").map { String($0) }
                    onSave(trimmedName, others)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(trimmedName.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 440)
        .onAppear { focus = startsOnOtherNames ? .otherNames : .name }
    }
}
