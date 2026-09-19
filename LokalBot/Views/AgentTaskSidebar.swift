import SwiftUI

struct AgentTaskSidebar: View {
    @ObservedObject var sessions: AgentSessionTabs
    @State private var query = ""
    @State private var showArchived = false
    @State private var renaming: UUID?
    @State private var name = ""
    @State private var confirmingClear = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Tasks").font(.headline)
                Spacer()
                Button { sessions.addSession() } label: { Image(systemName: "square.and.pencil").frame(width: 28, height: 28) }
                    .buttonStyle(.borderless).help("New task (⌘N)")
                    .accessibilityLabel("New Agent Task").accessibilityIdentifier("agent.newSession")
                Menu {
                    Button("Refresh tasks") { Task { await sessions.refreshHistory() } }
                    Toggle("Show archived tasks", isOn: $showArchived)
                    Divider()
                    Button("Clear saved Agent history…", role: .destructive) { confirmingClear = true }
                } label: { Image(systemName: "ellipsis").frame(width: 28, height: 28) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .accessibilityLabel("Task options")
            }.padding(.horizontal, 12).padding(.top, 10)
            TextField("Search tasks", text: $query)
                .textFieldStyle(.roundedBorder).focused($searchFocused)
                .padding(12).accessibilityIdentifier("agent.taskSearch")
            if showArchived {
                HStack {
                    Label("Archived", systemImage: "archivebox").font(.caption)
                    Spacer()
                    Button("Show active") { showArchived = false }.buttonStyle(.link)
                }.padding(.horizontal, 12).padding(.bottom, 8)
            }
            List(selection: Binding<UUID?>(get: { sessions.selectedID }, set: { if let id = $0 { sessions.select(id) } })) {
                if !pinned.isEmpty { Section("Pinned") { taskRows(pinned) } }
                Section(showArchived ? "Archived tasks" : "Recent") { taskRows(recent) }
            }
            .listStyle(.sidebar).accessibilityIdentifier("agent.tasks")
            .overlay {
                if filtered.isEmpty { ContentUnavailableView.search(text: query) }
            }
        }
        .onChange(of: sessions.searchRequest) { searchFocused = true }
        .alert("Rename task", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Task name", text: $name)
            Button("Save") { if let id = renaming { sessions.rename(id, to: name) }; renaming = nil }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        .confirmationDialog("Clear all saved Agent history?", isPresented: $confirmingClear) {
            Button("Clear History", role: .destructive) { Task { do { try await sessions.clearSavedHistory() } catch { sessions.error = error.localizedDescription } } }
        } message: { Text("This stops every Agent task and permanently removes its local conversation, draft, and task metadata. Your meeting library is not affected.") }
    }

    private var filtered: [AgentSessionTabs.Tab] {
        sessions.orderedTasks.filter {
            $0.record.isArchived == showArchived && (query.isEmpty ||
                "\($0.title) \($0.controller.workspaceDisplayName) \($0.saved?.preview ?? "")"
                    .localizedCaseInsensitiveContains(query))
        }
    }
    private var pinned: [AgentSessionTabs.Tab] { filtered.filter { $0.record.isPinned } }
    private var recent: [AgentSessionTabs.Tab] { filtered.filter { !$0.record.isPinned } }

    @ViewBuilder private func taskRows(_ tasks: [AgentSessionTabs.Tab]) -> some View {
        ForEach(tasks) { task in
            AgentTaskRow(task: task)
                .tag(task.id)
                .contextMenu {
                    Button("Rename…") { name = task.title; renaming = task.id }
                    Button(task.record.isPinned ? "Unpin" : "Pin") { sessions.togglePin(task.id) }
                    Button(task.record.isArchived ? "Restore task" : "Archive task") {
                        Task { await sessions.setArchived(task.id, !task.record.isArchived) }
                    }.disabled(task.controller.state == .running || task.controller.state == .starting)
                }
        }
    }
}

private struct AgentTaskRow: View {
    let task: AgentSessionTabs.Tab
    @ObservedObject private var controller: AgentSessionController
    init(task: AgentSessionTabs.Tab) { self.task = task; _controller = ObservedObject(wrappedValue: task.controller) }
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(controller.pendingApprovals.isEmpty ? Color.secondary : Color.orange)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 3) {
                Text(task.title).lineLimit(1).font(.callout.weight(.medium))
                Text("\(controller.workspaceDisplayName) · \(controller.taskStatus)")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.vertical, 5)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(task.title), \(controller.taskStatus)")
        .accessibilityIdentifier("agent.task.\(task.id.uuidString)")
    }
    private var icon: String {
        if !controller.pendingApprovals.isEmpty { return "hand.raised" }
        if controller.state == .running { return "ellipsis.circle" }
        if case .failed = controller.state { return "exclamationmark.circle" }
        return task.record.isArchived ? "archivebox" : "text.bubble"
    }
}
