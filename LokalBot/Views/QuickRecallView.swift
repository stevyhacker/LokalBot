import SwiftUI

/// Compact system-wide search and assistant surface. Typing keeps local recall
/// explicit Ask opens a reviewed draft, while Return reveals the selected source.
struct QuickRecallView: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        QuickRecallContent(model: app.chat)
    }
}

private struct QuickRecallContent: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: ChatViewModel

#if LOKALBOT_UI_TEST_HOST
    @State private var query = ProcessInfo.processInfo
        .environment["LOKALBOT_QUICK_RECALL_QUERY"] ?? ""
#else
    @State private var query = ""
#endif
    @State private var meetingHits: [SearchIndex.Hit] = []
    @State private var screenGroups: [ScreenRecallGroup] = []
    @State private var savedMoments: [ActivityStore.SavedMoment] = []
    @State private var selection = 0
    @State private var showingConversation = false
    @State private var recalledQuery = ""
    @State private var isSearching = false
    @State private var searchTask: Task<Void, Never>?
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Divider()
            content
            if !showingConversation {
                Divider()
                QuickRecallFooter(
                    query: trimmedQuery,
                    inference: InferencePresentation(settings: app.settings),
                    hasResults: !rows.isEmpty,
                    isSearching: isSearching,
                    ask: { ask(trimmedQuery) })
            }
        }
        .frame(width: 660, height: 480)
        .background(.regularMaterial)
        .onAppear {
            inputFocused = true
            savedMoments = app.activityStore.savedMoments(limit: 200)
            if model.isResponding {
                showingConversation = true
            }
            if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                search()
            }
        }
        .onDisappear { searchTask?.cancel() }
        .onChange(of: model.currentID) {
            showingConversation = !model.messages.isEmpty && model.isResponding
            if !showingConversation { search() }
        }
        .onChange(of: model.messages.isEmpty) {
            if model.messages.isEmpty { showingConversation = false; search() }
        }
        .onChange(of: query) {
            selection = 0
            if !showingConversation {
                search()
            }
        }
        .onKeyPress(.upArrow) {
            guard !showingConversation else { return .ignored }
            moveSelection(by: -1)
            return .handled
        }
        .onKeyPress(.downArrow) {
            guard !showingConversation else { return .ignored }
            moveSelection(by: 1)
            return .handled
        }
        .onKeyPress(.escape) {
            dismiss()
            return .handled
        }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            if showingConversation {
                Button(action: showRecall) {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.plain)
                .font(.title2)
                .foregroundStyle(.tint)
                .accessibilityLabel("Back to recall")
            } else {
                Image(systemName: "sparkle.magnifyingglass")
                    .font(.title2)
                    .foregroundStyle(.tint)
            }
            TextField(
                showingConversation ? "Ask a follow-up…" : "Search your memory…",
                text: $query)
                .textFieldStyle(.plain)
                .font(.title3)
                .focused($inputFocused)
                .onSubmit { runSelectedResult() }
                .accessibilityIdentifier("quickRecall.input")
            if showingConversation && model.isResponding {
                Button(action: model.stop) {
                    Image(systemName: "stop.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Stop")
                .accessibilityLabel("Stop answer")
            } else if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Clear")
            }
            Button(action: openFullAsk) {
                Image(systemName: "arrow.up.right.square")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Open full Ask")
            .accessibilityLabel("Open full Ask")
        }
        .padding(.horizontal, WorkspaceMetric.panelPadding)
        .padding(.vertical, 16)
    }

    @ViewBuilder private var content: some View {
        if showingConversation {
            ChatTranscriptView(model: model)
        } else {
            resultList
        }
    }

    @ViewBuilder private var resultList: some View {
        if trimmedQuery.isEmpty, sections.isEmpty {
            ContentUnavailableView {
                Label("Ask anything", systemImage: "sparkle.magnifyingglass")
            } description: {
                Text("Type to search meetings, screens, and saved moments. Return opens a result; Ask is a separate action.")
                    .frame(maxWidth: 420)
            } actions: {
                VStack(spacing: 7) {
                    ForEach(Array(model.suggestions.prefix(3).enumerated()), id: \.offset) { index, suggestion in
                        Button { ask(suggestion, usingResults: false) } label: {
                            HStack {
                                Text(suggestion)
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                Spacer(minLength: 8)
                                Image(systemName: "arrow.up.circle.fill")
                                    .foregroundStyle(.tint)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .frame(maxWidth: 420)
                            .background(.quaternary.opacity(0.5),
                                        in: RoundedRectangle(cornerRadius: Brand.Radius.control))
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("quickRecall.suggestion.\(index)")
                    }
                }
                .padding(.top, 4)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if isSearching {
                            LoadingStateLabel("Searching your local memory…", font: .callout)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                                .accessibilityIdentifier("quickRecall.searching")
                        } else if !trimmedQuery.isEmpty, sections.isEmpty {
                            noMatchesState
                        }

                        ForEach(sections) { section in
                            Text(section.title)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 12)
                                .padding(.top, 12)
                                .padding(.bottom, 6)
                                .accessibilityAddTraits(.isHeader)
                            ForEach(section.rows) { row in
                                displayedRow(row)
                                    .id(row.id)
                                Divider()
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 2)
                                    .accessibilityHidden(true)
                            }
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
                }
                .onChange(of: selectedRowID) { _, id in
                    if let id { proxy.scrollTo(id) }
                }
            }
        }
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var matchingScreenIDs: Set<Int64> {
        Set(screenGroups.flatMap(\.matches).map(\.snapshotID))
    }

    private var sections: [QuickRecallSection] {
        let screens = QuickRecallRowModel.screens(
            groups: screenGroups, savedMoments: savedMoments, hasQuery: !trimmedQuery.isEmpty)
        let meetings = meetingHits.map { hit in
            let meeting = app.meetings.first(where: { $0.id == hit.meetingID })
            let kind = hit.kind == .segment ? "Transcript" : hit.kind.rawValue.capitalized
            let appName = meeting?.appName ?? "Meeting"
            return QuickRecallRowModel.meeting(
                hit: hit,
                appName: appName,
                title: meeting?.title ?? "Meeting",
                subtitle: "\(appName) · \(kind)",
                snippet: hit.snippet,
                timestamp: meeting?.startedAt)
        }

        return [
            QuickRecallSection(id: "screen", title: "Screens", rows: screens),
            QuickRecallSection(id: "meetings", title: "Meetings", rows: meetings),
        ].filter { !$0.rows.isEmpty }
    }

    private var rows: [QuickRecallRowModel] {
        sections.flatMap(\.rows)
    }

    private var selectedRowID: String? {
        rows.indices.contains(selection) ? rows[selection].id : nil
    }

    private func displayedRow(_ row: QuickRecallRowModel) -> some View {
        let index = rows.firstIndex(where: { $0.id == row.id }) ?? 0
        return Button {
            run(row)
        } label: {
            QuickRecallRow(row: row, selected: selection == index)
                .contentShape(Rectangle())
        }
            .buttonStyle(.plain)
            .accessibilityAddTraits(selection == index ? [.isSelected] : [])
            .accessibilityIdentifier("quickRecall.row.\(row.id)")
            .accessibilityLabel(row.title)
            .accessibilityValue(row.accessibilityValue)
    }

    private var noMatchesState: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .accessibilityHidden(true)
                Text("No local matches")
                    .font(.headline)
                    .accessibilityIdentifier("quickRecall.noMatches")
            }
            Text("Nothing in saved moments, captured screens, or meetings matches this search.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .padding(.horizontal, 20)
    }

    private func search() {
        searchTask?.cancel()
        let currentQuery = trimmedQuery
        guard !showingConversation, !currentQuery.isEmpty else {
            meetingHits = []
            screenGroups = []
            isSearching = false
            return
        }
        meetingHits = []
        screenGroups = []
        isSearching = true
        searchTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled, currentQuery == trimmedQuery else { return }
            let result = await RecallSearch.search(currentQuery, state: RecallWorkspaceState(), dateScope: nil, app: app)
            guard !Task.isCancelled, currentQuery == trimmedQuery else { return }
            screenGroups = result.screens
            meetingHits = result.meetings.map(\.primary)
            selection = 0
            isSearching = false
        }
    }

    private func moveSelection(by offset: Int) {
        guard !showingConversation, !rows.isEmpty else { return }
        selection = (selection + offset + rows.count) % rows.count
    }

    private func runSelectedResult() {
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if showingConversation {
            ask(value)
            return
        }
        if rows.indices.contains(selection) {
            run(rows[selection])
        }
    }

    private func run(_ row: QuickRecallRowModel) {
        switch row.destination {
        case .screen(let snapshotID):
            app.openScreenSnapshot(snapshotID)
        case .meeting(let hit):
            app.openSearchHit(hit)
        }
        WindowAccess.shared.open("main")
        dismiss()
    }

    private func ask(_ question: String, usingResults: Bool = true) {
        let value = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !model.isResponding else { return }
        if !showingConversation {
            app.openAsk(query: value, dayScope: nil,
                        screenSnapshotIDs: usingResults ? Array(matchingScreenIDs) : nil,
                        meetingIDs: usingResults ? Set(meetingHits.map(\.meetingID)) : nil)
            WindowAccess.shared.open("main")
            dismiss()
            return
        }
        searchTask?.cancel()
        isSearching = false
        showingConversation = true
        query = ""
        selection = 0
        let scope = model.currentQuestionScope
        model.send(value,
                   sourceScopes: scope?.sources ?? AskSourceScope.defaults,
                   dateScope: scope?.dayScopeKey.flatMap { AskDateScope(storageKey: $0) },
                   meetingIDs: scope?.meetingIDs, screenSnapshotIDs: scope?.screenSnapshotIDs)
        inputFocused = true
    }

    private func showRecall() {
        showingConversation = false
        query = recalledQuery
        selection = 0
        savedMoments = app.activityStore.savedMoments(limit: 200)
        search()
        inputFocused = true
    }

    private func openFullAsk() {
        // Both surfaces share this conversation; opening it never re-submits.
        if showingConversation {
            app.askMode = .ask
            app.navSection = .ask
        } else {
            app.openAsk(query: query, dayScope: nil, mode: .keyword)
        }
        WindowAccess.shared.open("main")
        dismiss()
    }
}
