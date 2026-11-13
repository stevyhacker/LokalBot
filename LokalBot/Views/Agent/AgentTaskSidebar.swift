import SwiftUI

/// The task list: search and New on top, tasks grouped by day with their
/// status, and Archived at the bottom. Refresh, the runtime check and
/// clearing history are in the … menu here and in the app's Agent menu.
struct AgentTaskSidebar: View {
    @EnvironmentObject private var app: AppState
    @ObservedObject var sessions: AgentSessionTabs
    let verifyRuntime: () -> Void
    @State private var query = ""
    @State private var showArchived = false
    @State private var renaming: UUID?
    @State private var name = ""
    @State private var confirmingClear = false
    @FocusState private var searchFocused: Bool

    private var language: AppLanguage { app.settings.appLanguage }
    private var hasWorkingTask: Bool {
        sessions.tabs.contains { $0.controller.state == .running || $0.controller.state == .starting }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if showArchived {
                HStack {
                    Label("Archived", systemImage: "archivebox").font(.scaled(.callout))
                    Spacer()
                    Button("Show Active") { showArchived = false }.buttonStyle(.workspaceLink)
                }.padding(.horizontal, 14).padding(.bottom, 8)
            }
            List(selection: Binding<UUID?>(get: { sessions.selectedID }, set: { if let id = $0 { sessions.select(id) } })) {
                ForEach(sections) { section in
                    Section {
                        ForEach(section.ids.compactMap { id in filtered.first { $0.id == id } }) { task in
                            row(task, in: section)
                        }
                    } header: {
                        Text(verbatim: section.title(locale: language.locale, localize: language.catalog))
                    }
                }
            }
            .listStyle(.inset)
            .tint(Brand.tealFill)
            .accessibilityIdentifier("agent.tasks")
            .overlay {
                if filtered.isEmpty && !query.isEmpty { ContentUnavailableView.search(text: query) }
            }
            Divider()
            footer
        }
        .onChange(of: sessions.searchRequest) { searchFocused = true }
        .onChange(of: sessions.refreshRequest) { Task { await sessions.refreshHistory() } }
        .onChange(of: sessions.verifyRuntimeRequest) { if !hasWorkingTask { verifyRuntime() } }
        .onChange(of: sessions.clearHistoryRequest) { confirmingClear = true }
        .alert("Rename task", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Task name", text: $name)
            Button("Save") { if let id = renaming { sessions.rename(id, to: name) }; renaming = nil }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        .confirmationDialog("Clear all saved Agent history?", isPresented: $confirmingClear) {
            Button("Clear History", role: .destructive) { Task { do { try await sessions.clearSavedHistory() } catch { sessions.error = error.localizedDescription } } }
        } message: { Text("This stops every Agent task and permanently removes its local conversation, draft, and task metadata. Your meeting library is not affected.") }
    }

    private var header: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                TextField("Search tasks", text: $query)
                    .textFieldStyle(.plain).focused($searchFocused)
                    .accessibilityIdentifier("agent.taskSearch")
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless).foregroundStyle(.secondary).accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .workspaceControl()
            Button { sessions.addSession() } label: { Image(systemName: "square.and.pencil").frame(width: 28, height: 28) }
                .buttonStyle(.borderless).help("New task (⌘N)")
                .accessibilityLabel("New Agent Task").accessibilityIdentifier("agent.newSession")
        }
        .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 10)
    }

    private var footer: some View {
        HStack(spacing: 4) {
            Button { showArchived.toggle() } label: {
                HStack(spacing: 8) {
                    Image(systemName: "archivebox").frame(width: 16)
                    Text(showArchived ? "Show Active" : "Archived")
                    Spacer(minLength: 4)
                    if !showArchived && archivedCount > 0 {
                        Text(verbatim: "\(archivedCount)").monospacedDigit()
                    }
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("agent.archived")
            Menu {
                Button("Refresh tasks") { Task { await sessions.refreshHistory() } }
                Toggle("Show archived tasks", isOn: $showArchived)
                Divider()
                Button("Verify Agent runtime…", action: verifyRuntime)
                    .disabled(hasWorkingTask)
                    .accessibilityIdentifier("agent.verifyRuntime")
                Divider()
                Button("Clear saved Agent history…", role: .destructive) { confirmingClear = true }
            } label: { Image(systemName: "ellipsis").frame(width: 28, height: 28) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel("Task options")
        }
        .font(.scaled(.callout))
        .padding(.leading, 14).padding(.trailing, 8).padding(.vertical, 6)
    }

    private var archivedCount: Int { sessions.tabs.filter(\.record.isArchived).count }

    private var filtered: [AgentSessionTabs.Tab] {
        sessions.orderedTasks.filter {
            $0.record.isArchived == showArchived && (query.isEmpty ||
                "\($0.title) \($0.controller.workspaceDisplayName) \($0.saved?.preview ?? "")"
                    .localizedCaseInsensitiveContains(query))
        }
    }

    private var sections: [AgentTaskListSection] {
        AgentTaskListSection.make(
            filtered.map { .init(id: $0.id, modifiedAt: $0.record.modifiedAt, isPinned: $0.record.isPinned) },
            now: Date(), calendar: .current)
    }

    private func row(_ task: AgentSessionTabs.Tab, in section: AgentTaskListSection) -> some View {
        AgentTaskRow(task: task, time: time(of: task, in: section), language: language)
            .tag(task.id)
            .contextMenu {
                Button("Rename…") { name = task.title; renaming = task.id }
                Button(task.record.isPinned ? "Unpin" : "Pin") { sessions.togglePin(task.id) }
                Button(task.record.isArchived ? "Restore task" : "Archive task") {
                    Task { await sessions.setArchived(task.id, !task.record.isArchived) }
                }.disabled(task.controller.state == .running || task.controller.state == .starting)
            }
    }

    /// A day group already names the day, so its rows show the time. A pinned
    /// task from another day shows the date.
    private func time(of task: AgentSessionTabs.Tab, in section: AgentTaskListSection) -> String? {
        let date = task.record.modifiedAt
        guard date != .distantPast else { return nil }
        if section.kind == .pinned && !Calendar.current.isDateInToday(date) {
            return date.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(language.locale))
        }
        return date.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(language.locale))
    }
}

private struct AgentTaskRow: View {
    @Environment(\.backgroundProminence) private var prominence
    let task: AgentSessionTabs.Tab
    let time: String?
    let language: AppLanguage
    @ObservedObject private var controller: AgentSessionController

    init(task: AgentSessionTabs.Tab, time: String?, language: AppLanguage) {
        self.task = task; self.time = time; self.language = language
        _controller = ObservedObject(wrappedValue: task.controller)
    }

    private var status: AgentTaskStatus {
        controller.status(hasSavedConversation: task.saved != nil)
    }

    /// The status, or for a task that is doing nothing, where it works.
    private var line: String {
        if task.record.isArchived && status.tone == .quiet { return language.localized("Archived") }
        return status.line(localize: language.catalog) ?? controller.workspaceDisplayName
    }

    private var title: String {
        task.record.title ?? controller.sessionTitle ?? task.saved?.title ?? language.localized("New task")
    }

    /// On a selected row in a focused list the row's own colours read on the accent fill.
    private func tint(_ color: Color) -> AnyShapeStyle {
        prominence == .increased ? AnyShapeStyle(.primary) : AnyShapeStyle(color)
    }

    private var toneColor: Color {
        switch status.tone {
        case .attention: LBTokens.Palette.attentionText
        case .working: Brand.teal
        case .quiet, .done: .secondary
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Group {
                if status.tone == .working {
                    ProgressView().controlSize(.small).scaleEffect(0.75)
                } else {
                    Image(systemName: task.record.isArchived && status.tone == .quiet ? "archivebox" : status.symbol)
                        .foregroundStyle(tint(status.tone == .attention ? toneColor : .secondary))
                }
            }
            .frame(width: 16, height: 16).padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(verbatim: title).font(AppFont.scaled(.body).weight(.semibold)).lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    if let time {
                        Text(verbatim: time).font(.scaled(.caption)).monospacedDigit()
                            .foregroundStyle(.secondary).fixedSize()
                    }
                }
                Text(verbatim: line).font(.scaled(.callout)).foregroundStyle(tint(toneColor)).lineLimit(1)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: "\(title), \(line)"))
        .help("\(title)\n\(controller.workspaceDisplayName) · \(line)")
        .accessibilityIdentifier("agent.task.\(task.id.uuidString)")
    }
}
