import SwiftUI

struct QuickRecallView: View {
    static let size = CGSize(width: 660, height: 512)

    @EnvironmentObject private var app: AppState

    var body: some View {
        QuickRecallContent(model: app.chat)
            .background(HiddenWindowButtons())
    }
}

private struct QuickRecallContent: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.appTextScale) private var textScale
    @ObservedObject var model: ChatViewModel

#if LOKALBOT_UI_TEST_HOST
    @State private var query = ProcessInfo.processInfo
        .environment["LOKALBOT_QUICK_RECALL_QUERY"] ?? ""
#else
    @State private var query = ""
#endif
    @State private var meetingHits: [SearchIndex.Hit] = []
    @State private var screenGroups: [ScreenRecallGroup] = []
    @State private var fileHits: [FileSearchHit] = []
    @State private var noteHits: [AgentNoteHit] = []
    @State private var isTruncated = false
    @State private var savedMoments: [ActivityStore.SavedMoment] = []
    @State private var cursor = QuickRecallCursor()
    @State private var expanded: Set<QuickRecallGroup.Kind> = []
    @State private var showingConversation = false
    @State private var recalledQuery = ""
    @State private var isSearching = false
    @State private var searchTask: Task<Void, Never>?
    @State private var pendingQuestion: String?
    @State private var focusRequest = 0
    @State private var titleBar: CGFloat = 0

    var body: some View {
        let groups = showingConversation ? [] : groups
        let rows = groups.flatMap(\.rows)
        VStack(spacing: 0) {
            field(rows)
                .padding(.top, -titleBar)
            Divider()
            if showingConversation {
                ChatTranscriptView(model: model, style: .compact, onOpenSource: sourceOpened)
                Divider()
                QuickRecallAnswerFoot(model: model, continueInMainWindow: continueInMainWindow)
            } else {
                resultList(groups, rows: rows)
                if hasAskRow {
                    Divider()
                    askRow(rowCount: rows.count)
                }
            }
        }
        .frame(width: QuickRecallView.size.width, height: QuickRecallView.size.height - titleBar)
        .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.top } action: { titleBar = $0 }
        .background {
            Group {
                if reduceTransparency {
                    Color(nsColor: .windowBackgroundColor)
                } else {
                    Rectangle().fill(.regularMaterial)
                }
            }
            .ignoresSafeArea()
        }
        .onAppear {
            savedMoments = app.activityStore.savedMoments(limit: 200)
            if model.isResponding {
                showingConversation = true
            }
            if trimmedQuery.isEmpty {
                cursor.reset(rowCount: rows.count)
            } else if !showingConversation {
                search()
            }
            focusRequest &+= 1
        }
        .onDisappear {
            searchTask?.cancel()
            pendingQuestion = nil
        }
        .onChange(of: model.messages.isEmpty) {
            if model.messages.isEmpty, showingConversation { showRecall() }
        }
        .onChange(of: query) {
            guard !showingConversation else { return }
            if pendingQuestion != trimmedQuery { pendingQuestion = nil }
            expanded = []
            search()
        }
        .onChange(of: app.quickRecallOpenedFromMainWindow) {
            if trimmedQuery.isEmpty, !showingConversation { cursor.reset(rowCount: rowCount) }
        }
        .onKeyPress(.escape) {
            dismiss()
            return .handled
        }
    }

    private func field(_ rows: [QuickRecallRowModel]) -> some View {
        HStack(spacing: 12) {
            if showingConversation {
                Button(action: showRecall) {
                    Image(systemName: "chevron.left")
                        .font(.scaled(.title2))
                        .frame(width: 24, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(LBTokens.Palette.accentText)
                .help("Back to results")
                .accessibilityLabel("Back to results")
                .accessibilityIdentifier("quickRecall.back")
            } else {
                Image(systemName: "magnifyingglass")
                    .font(.scaled(.title2))
                    .foregroundStyle(LBTokens.Palette.accentText)
                    .frame(width: 24, height: 30)
                    .accessibilityHidden(true)
            }
            QuickRecallTextField(
                text: $query,
                placeholder: showingConversation ? "Ask a follow-up" : "Search, ask, or run a command",
                hint: showingConversation ? nil : "Return opens the selected result. Command-Return asks.",
                fontSize: 22 * min(textScale, 1.3),
                focusRequest: focusRequest,
                onSubmit: { submit(rows) },
                onCommandSubmit: { ask(trimmedQuery) },
                onMove: { move(by: $0, rowCount: rows.count) },
                onCancel: { dismiss() })
                .frame(maxWidth: .infinity)
                .frame(height: 30 * min(textScale, 1.3))
            if showingConversation && model.isResponding {
                Button(action: model.stop) {
                    Image(systemName: "stop.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Stop")
                .accessibilityLabel("Stop answer")
                .accessibilityIdentifier("quickRecall.stop")
            } else if !query.isEmpty {
                Button {
                    query = ""
                    focusRequest &+= 1
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Clear")
            }
        }
        .padding(.leading, 18)
        .padding(.trailing, 16)
        .frame(height: 58 * min(textScale, 1.3))
    }

    @ViewBuilder
    private func resultList(_ groups: [QuickRecallGroup], rows: [QuickRecallRowModel]) -> some View {
        let indices = Dictionary(rows.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        let selected = cursor.target(rowCount: rows.count, hasAsk: hasAskRow)
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(groups) { group in
                        QuickRecallGroupHeader(group: group) { showAll(group) }
                        ForEach(group.rows) { row in
                            rowButton(row, selected: indices[row.id].map { selected == .row($0) } ?? false)
                                .id(row.id)
                        }
                    }
                    if isSearching {
                        LoadingStateLabel(app.settings.appLanguage.localized("Searching your local memory…"),
                                          font: .scaled(.callout))
                            .padding(.horizontal, 20)
                            .padding(.vertical, 12)
                            .accessibilityIdentifier("quickRecall.searching")
                    } else if !trimmedQuery.isEmpty, !hasMemoryMatches {
                        noMatchesState(besideCommands: !rows.isEmpty)
                    }
                }
                .padding(.bottom, 6)
            }
            .onChange(of: selectedRowID(rows)) { _, id in
                if let id { proxy.scrollTo(id) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func selectedRowID(_ rows: [QuickRecallRowModel]) -> String? {
        guard case .row(let index) = cursor.target(rowCount: rows.count, hasAsk: hasAskRow),
              rows.indices.contains(index) else { return nil }
        return rows[index].id
    }

    private func rowButton(_ row: QuickRecallRowModel, selected: Bool) -> some View {
        Button {
            run(row)
        } label: {
            QuickRecallRow(row: row, selected: selected)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .accessibilityIdentifier("quickRecall.row.\(row.id)")
        .accessibilityLabel(row.title)
        .accessibilityValue(row.accessibilityValue)
    }

    private func askRow(rowCount: Int) -> some View {
        let language = app.settings.appLanguage
        let detail = QuickRecallAskScope.askRowDetail(
            inference: InferencePresentation(settings: app.settings),
            readsListedMatches: QuickRecallAskScope.readsListedMatches(
                query: trimmedQuery, hasMatches: !meetingHits.isEmpty || !screenGroups.isEmpty,
                isSearching: isSearching, isRememberStatement: isRememberStatement(trimmedQuery)),
            localize: language.catalog)
        return Button {
            ask(trimmedQuery)
        } label: {
            QuickRecallAskRow(query: trimmedQuery, detail: detail,
                              selected: cursor.target(rowCount: rowCount, hasAsk: true) == .ask)
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.return, modifiers: .command)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .accessibilityIdentifier("quickRecall.ask")
        .accessibilityValue(Text(verbatim: detail))
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasAskRow: Bool { !showingConversation && !trimmedQuery.isEmpty }

    private var rowCount: Int { groups.reduce(0) { $0 + $1.rows.count } }

    private var hasMemoryMatches: Bool {
        !meetingHits.isEmpty || !screenGroups.isEmpty || !fileHits.isEmpty || !noteHits.isEmpty
    }

    private var matchingScreenIDs: Set<Int64> {
        Set(screenGroups.flatMap(\.matches).map(\.snapshotID))
    }

    private var commands: [PaletteCommand] {
        PaletteCommandCatalog.commands(app: app, source: "quick-recall",
                                       inWorkspace: app.quickRecallOpenedFromMainWindow)
    }

    private var recentMeetings: [QuickRecallRecent.MeetingItem] {
        var items: [QuickRecallRecent.MeetingItem] = []
        for meeting in app.meetings where !meeting.isMergedSource {
            items.append(QuickRecallRecent.MeetingItem(
                id: meeting.id, title: meeting.displayTitle,
                duration: meeting.endedAt == nil ? nil : meeting.displayDuration,
                startedAt: meeting.startedAt))
            if items.count == QuickRecallGrouping.recentLimit { break }
        }
        return items
    }

    private var groups: [QuickRecallGroup] {
        let language = app.settings.appLanguage
        guard !trimmedQuery.isEmpty else {
            return QuickRecallGrouping.idle(
                recent: QuickRecallRecent.rows(meetings: recentMeetings, savedMoments: savedMoments),
                commands: PaletteCommandFilter.idleOrder(commands).map(QuickRecallRowModel.command))
        }
        var found = QuickRecallGrouping.Found()
        let matched = PaletteCommandFilter.split(commands, query: trimmedQuery)
        found.commands = matched.leading.map(QuickRecallRowModel.command)
        found.looseCommands = matched.loose.map(QuickRecallRowModel.command)
        found.meetings = meetingHits.map { hit in
            let meeting = app.meetings.first(where: { $0.id == hit.meetingID })
            return QuickRecallRowModel.meeting(
                hit: hit,
                title: meeting?.displayTitle ?? language.localized("Meeting"),
                speaker: QuickRecallRowModel.meetingLead(hit, localize: language.catalog),
                timestamp: meeting?.startedAt)
        }
        found.screens = QuickRecallRowModel.screens(groups: screenGroups, savedMoments: savedMoments, hasQuery: true)
        found.screenSourceCount = screenGroups.count
        found.files = fileHits.map { QuickRecallRowModel.file($0, localize: language.catalog) }
        found.agentNotes = noteHits.map(QuickRecallRowModel.agentNote)
        found.isTruncated = isTruncated
        return QuickRecallGrouping.groups(found, expanded: expanded,
                                          showsAgentNotes: app.settings.codingAgentNotesEnabled)
    }

    private func noMatchesState(besideCommands: Bool) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .accessibilityHidden(true)
                Text("No local matches")
                    .font(besideCommands ? .scaled(.callout) : .scaled(.headline))
                    .accessibilityIdentifier("quickRecall.noMatches")
            }
            .foregroundStyle(besideCommands ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
            if !besideCommands {
                Text("Nothing in saved moments, captured screens, or meetings matches this search.")
                    .font(.scaled(.callout))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, alignment: besideCommands ? .leading : .center)
        .padding(.vertical, besideCommands ? 12 : 24)
        .padding(.horizontal, 20)
    }

    private func search() {
        searchTask?.cancel()
        let currentQuery = trimmedQuery
        meetingHits = []
        screenGroups = []
        fileHits = []
        noteHits = []
        isTruncated = false
        guard !showingConversation, !currentQuery.isEmpty else {
            isSearching = false
            pendingQuestion = nil
            cursor.reset(rowCount: rowCount)
            return
        }
        isSearching = true
        cursor.reset(rowCount: rowCount)
        searchTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled, currentQuery == trimmedQuery else { return }
            let result = await RecallSearch.search(currentQuery, state: RecallWorkspaceState(), dateScope: nil, app: app)
            guard !Task.isCancelled, currentQuery == trimmedQuery else { return }
            screenGroups = result.screens
            meetingHits = result.meetings.map(\.primary)
            fileHits = result.files
            noteHits = result.agentNotes
            isTruncated = result.isTruncated
            isSearching = false
            cursor.reset(rowCount: rowCount)
            if pendingQuestion == currentQuery { ask(currentQuery) }
        }
    }

    private func move(by offset: Int, rowCount: Int) -> Bool {
        guard !showingConversation else { return false }
        cursor.move(by: offset, rowCount: rowCount, hasAsk: hasAskRow)
        return true
    }

    private func submit(_ rows: [QuickRecallRowModel]) {
        if showingConversation {
            ask(trimmedQuery)
            return
        }
        switch cursor.target(rowCount: rows.count, hasAsk: hasAskRow) {
        case .row(let index):
            if rows.indices.contains(index) { run(rows[index]) }
        case .ask:
            ask(trimmedQuery)
        case nil:
            break
        }
    }

    private func run(_ row: QuickRecallRowModel) {
        switch row.destination {
        case .screen(let snapshotID):
            app.openScreenSnapshot(snapshotID)
        case .meeting(let hit):
            app.openSearchHit(hit)
        case .recentMeeting(let id):
            app.openMeeting(id)
        case .file(let hit):
            FileSearchOpener.open(hit, query: trimmedQuery)
            dismiss()
            return
        case .agentNote(let hit):
            AgentNoteOpener.open(hit)
            dismiss()
            return
        case .command(let id):
            runCommand(id)
            return
        }
        WindowAccess.shared.open("main")
        dismiss()
    }

    private func runCommand(_ id: String) {
        guard let command = commands.first(where: { $0.id == id }) else { return }
        dismiss()
        switch command.placement {
        case .workspace:
            command.action()
            WindowAccess.shared.open("main")
        case .background:
            app.returnFocusToShortcutSource(then: command.action)
        }
    }

    private func showAll(_ group: QuickRecallGroup) {
        guard let source = group.kind.askSource else {
            let wasOnAsk = cursor.target(rowCount: rowCount, hasAsk: hasAskRow) == .ask
            expanded.insert(group.kind)
            if wasOnAsk { cursor.select(.ask, rowCount: rowCount) }
            return
        }
        app.openAsk(query: trimmedQuery, dayScope: nil, mode: .keyword, sources: [source])
        WindowAccess.shared.open("main")
        dismiss()
    }

    private func isRememberStatement(_ text: String) -> Bool {
        app.settings.askMemoryEnabled && RememberIntent.parse(text) != nil
    }

    private func ask(_ question: String) {
        let value = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        guard !model.isResponding else {
            if !showingConversation { showConversation(recalling: value) }
            return
        }
        if showingConversation {
            query = ""
            let scope = model.currentQuestionScope
            model.send(value,
                       sourceScopes: scope?.sources ?? AskSourceScope.defaults,
                       dateScope: scope?.dayScopeKey.flatMap { AskDateScope(storageKey: $0) },
                       meetingIDs: scope?.meetingIDs, screenSnapshotIDs: scope?.screenSnapshotIDs)
            focusRequest &+= 1
            return
        }
        let remembers = isRememberStatement(value)
        if isSearching, !remembers, !AskAnswerScope.isFullQuestion(value) {
            pendingQuestion = value
            cursor.select(.ask, rowCount: rowCount)
            return
        }
        pendingQuestion = nil
        let scope = QuickRecallAskScope.resolve(
            query: value, meetingIDs: Set(meetingHits.map(\.meetingID)), screenIDs: matchingScreenIDs,
            isRememberStatement: remembers)
        showConversation(recalling: value)
        model.newConversation()
        model.send(value, sourceScopes: scope.sources,
                   meetingIDs: scope.meetingIDs, screenSnapshotIDs: scope.screenSnapshotIDs)
    }

    private func showConversation(recalling value: String) {
        searchTask?.cancel()
        isSearching = false
        pendingQuestion = nil
        recalledQuery = value
        showingConversation = true
        query = ""
        focusRequest &+= 1
    }

    private func showRecall() {
        showingConversation = false
        query = recalledQuery
        savedMoments = app.activityStore.savedMoments(limit: 200)
        search()
        focusRequest &+= 1
    }

    private func continueInMainWindow() {
        app.continueQuickRecallConversationInAsk()
        WindowAccess.shared.open("main")
        dismiss()
    }

    private func sourceOpened(_ kind: ChatCitation.Kind) {
        if kind == .meeting || kind == .screen { WindowAccess.shared.open("main") }
        dismiss()
    }
}
