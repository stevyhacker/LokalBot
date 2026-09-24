import SwiftUI

/// Searchable local history for Agent sessions that are no longer mounted as
/// live tabs. Selecting a row opens that exact pi session and workspace.
struct AgentSessionHistoryView: View {
    @ObservedObject var sessions: AgentSessionTabs

    @Environment(\.dismiss) private var dismiss
    @State private var savedSessions: [AgentSavedSession] = []
    @State private var selectedID: AgentSavedSession.ID?
    @State private var searchText = ""
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var openingID: AgentSavedSession.ID?
    @State private var openError: String?

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationTitle("Saved Sessions")
                .navigationSplitViewColumnWidth(min: 250, ideal: 300, max: 400)
                .splitPaneAccessibilityLabel("Saved Agent sessions")
        } detail: {
            detail
                .navigationTitle("Session Details")
                .splitPaneAccessibilityLabel("Session preview")
        }
        .searchable(text: $searchText, prompt: "Search sessions")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Close") { dismiss() }
            }
            ToolbarItem(placement: .primaryAction) {
                Button(action: reload) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(isLoading || openingID != nil)
                .accessibilityIdentifier("agent.history.refresh")
            }
        }
        .frame(minWidth: 760, minHeight: 500)
        .task { await loadSessions() }
        .onChange(of: searchText) {
            guard !filteredSessions.contains(where: { $0.id == selectedID }) else { return }
            selectedID = filteredSessions.first?.id
        }
        .alert("Couldn’t Open Session", isPresented: Binding(
            get: { openError != nil },
            set: { if !$0 { openError = nil } })) {
            Button("OK") { openError = nil }
        } message: {
            Text(openError ?? "Unknown error")
        }
        .accessibilityIdentifier("agent.history")
    }

    @ViewBuilder private var sidebar: some View {
        if isLoading && savedSessions.isEmpty {
            VStack(spacing: 10) {
                ProgressView()
                Text("Loading saved sessions…")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let loadError, savedSessions.isEmpty {
            ContentUnavailableView {
                Label("Couldn’t Load Sessions", systemImage: "exclamationmark.triangle")
            } description: {
                Text(loadError)
            } actions: {
                Button("Try Again", action: reload)
            }
        } else if filteredSessions.isEmpty {
            ContentUnavailableView(
                searchText.isEmpty ? "No Saved Sessions" : "No Matching Sessions",
                systemImage: searchText.isEmpty ? "clock.arrow.circlepath" : "magnifyingglass",
                description: Text(emptyDescription))
        } else {
            List(selection: $selectedID) {
                ForEach(filteredSessions) { session in
                    sessionRow(session)
                        .tag(session.id)
                }
            }
            .listStyle(.sidebar)
            .accessibilityIdentifier("agent.history.list")
        }
    }

    @ViewBuilder private var detail: some View {
        if let session = selectedSession {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(session.title)
                            .font(.title2.weight(.semibold))
                            .textSelection(.enabled)
                        Label(
                            sessions.workspaceDisplayName(for: session.workspace),
                            systemImage: "folder")
                            .foregroundStyle(.secondary)
                    }

                    Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 12) {
                        detailRow("Last active", value: formatted(session.modifiedAt))
                        detailRow("Created", value: formatted(session.createdAt))
                        detailRow("Messages", value: messageCount(session.messageCount))
                        detailRow("Workspace", value: session.workspace.path, selectable: true)
                    }

                    Divider()
                    if !session.preview.isEmpty {
                        Text("Last message preview").font(WorkspaceTypography.sectionTitle)
                        Text(session.preview).textSelection(.enabled)
                        Text("Preview only. The session starts when you choose Open.").workspaceTextRole(.supporting)
                    }
                    VStack(alignment: .leading, spacing: 9) {
                        Button {
                            open(session)
                        } label: {
                            if openingID == session.id {
                                HStack(spacing: 8) {
                                    ProgressView().controlSize(.small)
                                    Text("Opening Session…")
                                }
                            } else {
                                Label(openButtonTitle(for: session), systemImage: openButtonIcon(for: session))
                            }
                        }
                        .primaryActionButton()
                        .disabled(!canOpen(session) || openingID != nil)
                        .accessibilityIdentifier("agent.history.open")

                        Text(openExplanation(for: session))
                            .workspaceTextRole(.supporting)
                    }
                }
                .padding(28)
                .frame(maxWidth: 620, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        } else {
            ContentUnavailableView(
                "Select a Session",
                systemImage: "clock.arrow.circlepath",
                description: Text("Choose a saved session to see its workspace and reopen it."))
        }
    }

    private var filteredSessions: [AgentSavedSession] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return savedSessions }
        return savedSessions.filter { $0.searchableText.localizedCaseInsensitiveContains(query) }
    }

    private var selectedSession: AgentSavedSession? {
        savedSessions.first { $0.id == selectedID }
    }

    private var emptyDescription: String {
        if searchText.isEmpty {
            return "Sessions appear here after Agent Mode has created local history."
        }
        return "Try a session title or workspace name."
    }

    private func sessionRow(_ session: AgentSavedSession) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "text.bubble")
                .foregroundStyle(Brand.teal)
            VStack(alignment: .leading, spacing: 3) {
                Text(session.title)
                    .font(WorkspaceTypography.rowTitle)
                    .lineLimit(2)
                Text("\(sessions.workspaceDisplayName(for: session.workspace)) · \(formatted(session.modifiedAt))")
                    .font(WorkspaceTypography.metadata)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if sessions.isOpen(session) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .help("Open in a live Agent tab")
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("agent.history.session.\(session.sessionID)")
    }

    private func detailRow(_ label: String, value: String, selectable: Bool = false) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
            if selectable {
                Text(value).textSelection(.enabled)
            } else {
                Text(value)
            }
        }
    }

    private func formatted(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    private func messageCount(_ count: Int) -> String {
        "\(count) \(count == 1 ? "message" : "messages")"
    }

    private func canOpen(_ session: AgentSavedSession) -> Bool {
        !sessions.isOpen(session) && sessions.canOpenAnotherSavedSession
    }

    private func openButtonTitle(for session: AgentSavedSession) -> String {
        sessions.isOpen(session) ? "Already Open" : "Open Session"
    }

    private func openButtonIcon(for session: AgentSavedSession) -> String {
        sessions.isOpen(session) ? "checkmark.circle" : "arrow.up.forward.app"
    }

    private func openExplanation(for session: AgentSavedSession) -> String {
        if sessions.isOpen(session) {
            return "This session is already open in a live Agent tab."
        }
        if !sessions.canOpenAnotherSavedSession {
            return "Close one of the four live Agent tabs before opening this session."
        }
        return "The full conversation will reopen in its original working folder."
    }

    private func reload() {
        Task { await loadSessions() }
    }

    @MainActor
    private func loadSessions() async {
        isLoading = true
        loadError = nil
        do {
            let loaded = try await sessions.loadSavedSessions()
            savedSessions = loaded
            if !loaded.contains(where: { $0.id == selectedID }) {
                selectedID = loaded.first?.id
            }
        } catch {
            loadError = error.localizedDescription
        }
        isLoading = false
    }

    private func open(_ session: AgentSavedSession) {
        guard openingID == nil else { return }
        openingID = session.id
        Task {
            do {
                try await sessions.openSavedSession(session)
                dismiss()
            } catch {
                openError = error.localizedDescription
                openingID = nil
            }
        }
    }
}
