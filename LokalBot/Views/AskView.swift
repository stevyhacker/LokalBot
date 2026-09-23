import SwiftUI

/// Live recall and explicit questions share one input and retained source context.
struct AskView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        GeometryReader { geometry in
            AskContent(model: app.chat)
                .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }
}

private struct AskContent: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var model: ChatViewModel

    private var query: String {
        get { app.recallQuery }
        nonmutating set { app.recallQuery = newValue }
    }
    private var queryBinding: Binding<String> { Binding(get: { query }, set: { query = $0 }) }
    private var meetingScope: Set<UUID>? {
        get { app.recallState.meetingIDs }
        nonmutating set { app.recallState.meetingIDs = newValue }
    }
    private var screenScope: Set<Int64>? {
        get { app.recallState.screenIDs }
        nonmutating set { app.recallState.screenIDs = newValue }
    }
    private var selectedResult: Int {
        get { app.recallState.selectedResult }
        nonmutating set { app.recallState.selectedResult = newValue }
    }
    private var facet: AskFacet {
        get { app.recallState.facet }
        nonmutating set { app.recallState.facet = newValue }
    }
    @State private var hits: [SearchIndex.Hit] = []
    @State private var ocrHits: [ActivityStore.OCRHit] = []
    @State private var screenGroups: [ScreenRecallGroup] = []
    private var screenDateScope: ScreenSearchDateScope {
        get { app.recallState.screenDate }
        nonmutating set { app.recallState.screenDate = newValue }
    }
    private var selectedScreenApp: String? {
        get { app.recallState.screenApp }
        nonmutating set { app.recallState.screenApp = newValue }
    }
    @State private var screenApps: [String] = []
    private var pinnedScreens: [ScreenAskContext] {
        get { app.recallState.pins }
        nonmutating set { app.recallState.pins = newValue }
    }
    @State private var screenWasEnabledBeforePins: Bool?
    @State private var searchTask: Task<Void, Never>?
    @State private var isSearching = false
    @State private var showingTimeScope = false
    @FocusState private var inputFocused: Bool

    private var mode: AskMode {
        get { app.askMode }
        nonmutating set { app.askMode = newValue }
    }

    private var sources: Set<AskSourceScope> {
        get { app.recallState.sources }
        nonmutating set { app.recallState.sources = newValue }
    }

    private var layout: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.isLoadingHistory { LoadingStateLabel("Loading conversations…") }
            retrievalBody
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(nil, value: phase)
    }

    private var searchContent: some View {
        layout
        .onChange(of: query) {
            model.preserveSelectionDuringHistoryLoad()
            selectedResult = 0
            runSearch()
        }
        .onReceive(NotificationCenter.default.publisher(for: .retainedScreenTextChanged)) { _ in
            runSearch()
        }
        .onDisappear { searchTask?.cancel() }
        .onChange(of: facet) { runSearch() }
        .onChange(of: screenDateScope) { runSearch() }
        .onChange(of: app.askDayScope) {
            reconcilePinnedScreenScope()
            runSearch()
        }
        .onChange(of: selectedScreenApp) { runSearch() }
        .onChange(of: sources) { runSearch() }
    }

    var body: some View {
        searchContent
        .onKeyPress(.downArrow) {
            guard phase == .searching, resultCount > 0 else { return .ignored }
            selectedResult = min(selectedResult + 1, resultCount - 1)
            return .handled
        }
        .onKeyPress(.upArrow) {
            guard phase == .searching, resultCount > 0 else { return .ignored }
            selectedResult = max(0, selectedResult - 1)
            return .handled
        }
        .onChange(of: app.navigationHandoff.revision) { consumeNavigationHandoff() }
        .onChange(of: model.currentID) {
            // A saved conversation selection is an explicit mode switch. An
            // old search query must not keep masking the selected transcript.
            openSelectedConversation()
        }
        .onChange(of: model.navigationRevision) { openSelectedConversation() }
        .onAppear {
            if !query.isEmpty { model.preserveSelectionDuringHistoryLoad() }
            _ = consumeNavigationHandoff()
            runSearch()
            inputFocused = true
            #if LOKALBOT_UI_TEST_HOST
            if query.isEmpty,
               let q = ProcessInfo.processInfo.environment["LOKALBOT_INITIAL_SEARCH"],
               !q.isEmpty {
                query = q
            }
            #endif
        }
    }

    @discardableResult
    private func consumeNavigationHandoff() -> Bool {
        guard let handoff = app.navigationHandoff.consumeAsk() else { return false }
        app.askDayScope = handoff.dayScope.map(Calendar.current.startOfDay(for:))
        mode = handoff.mode
        app.recallState.selectEvidence(meetingIDs: handoff.meetingIDs,
                                       screenIDs: handoff.screenSnapshotIDs.map { Set($0) })
        if let handedQuery = handoff.query {
            query = handedQuery
        }
        pinnedScreens = []
        // A single moment is an attachment; a result/session collection is a
        // retrieval boundary. Do not eagerly copy an entire session into a prompt.
        let attachedIDs = handoff.screenSnapshotIDs?.count == 1 ? handoff.screenSnapshotIDs ?? [] : []
        if !attachedIDs.isEmpty {
            rememberScreenAccessBeforePinning()
        }
        for snapshotID in attachedIDs {
            guard !pinnedScreens.contains(where: { $0.snapshotID == snapshotID }),
                  let screenshot = app.activityStore.screenshot(id: snapshotID) else { continue }
            let ocr = app.activityStore.ocrText(snapshotID: snapshotID) ?? ""
            pinnedScreens.append(ScreenAskContext(screenshot: screenshot, ocrText: ocr))
        }
        if pinnedScreens.isEmpty {
            restoreScopeAfterRemovingPins()
        } else {
            reconcilePinnedScreenScope()
        }
        if handoff.submit { escalate() }
        return true
    }

    // MARK: - Input + facets

    private var phase: AskPhase { AskRouter.phase(query: query, hasMessages: !model.messages.isEmpty) }

    @ViewBuilder private var retrievalBody: some View {
        Group {
            switch phase {
            case .searching: results
            case .idle: emptyState
            case .conversation: ChatTranscriptView(model: model)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            composerPanel
            askScopeControls
            selectedEvidenceControl
            if !pinnedScreens.isEmpty {
                pinnedContextRow
            }
        }
        .padding(.horizontal, WorkspaceMetric.pagePadding)
        .padding(.vertical, 16)
        .workspaceReadingWidth()
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private var composerPanel: some View {
        let canSubmit = !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !model.isResponding

        return HStack(alignment: .top, spacing: 10) {
            TextField(
                "Search or ask about your work…",
                text: queryBinding,
                axis: .vertical)
                .textFieldStyle(.plain)
                .font(WorkspaceTypography.body)
                .lineLimit(1...3)
                .frame(minWidth: 60, maxWidth: .infinity, minHeight: 32, alignment: .topLeading)
                .focused($inputFocused)
                .onSubmit { submitQuery() }
                .accessibilityLabel("Question or search")
                .accessibilityIdentifier("search.field")
            if model.isResponding {
                Button(action: model.stop) {
                    Image(systemName: "stop.circle.fill")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .keyboardShortcut(.cancelAction)
                .help("Stop answering (Esc)")
                .accessibilityLabel("Stop answering")
                .accessibilityIdentifier("chat.stop")
            }
            submitButton(canSubmit: canSubmit)
                .frame(width: 184, height: 32, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(minHeight: 56, alignment: .top)
        .background(.quaternary.opacity(0.26),
                    in: RoundedRectangle(cornerRadius: Brand.Radius.panel,
                                         style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Brand.Radius.panel, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.11))
        }
    }

    private var groupedMeetings: [MeetingRecallGroup] { RecallSearch.groups(hits) }
    private var resultCount: Int { groupedMeetings.count + screenGroups.count }

    private func submitQuery() {
        guard phase == .searching else { return }
        if groupedMeetings.indices.contains(selectedResult) {
            app.openSearchHit(groupedMeetings[selectedResult].primary)
        } else {
            let index = selectedResult - groupedMeetings.count
            if screenGroups.indices.contains(index) { app.openScreenSnapshot(screenGroups[index].primary.snapshotID) }
        }
    }

    /// Command-Return sends explicitly, bounded to the displayed source groups.
    /// No matches leaves the chosen source/day scope available for a question.
    private func askAboutResults() {
        guard !isSearching else { return }
        if resultCount > 0 {
            app.recallState.selectEvidence(
                meetingIDs: Set(groupedMeetings.map(\.id)),
                screenIDs: Set(screenGroups.flatMap(\.matches).map(\.snapshotID)))
        }
        escalate()
    }

    private func submitButton(canSubmit: Bool) -> some View {
        Button(action: askAboutResults) {
            Label(resultCount > 0 ? "Ask about results" : "Ask", systemImage: "sparkles")
                .font(WorkspaceTypography.control)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.regular)
        .tint(Brand.teal)
        .disabled(!canSubmit || isSearching)
        .keyboardShortcut(.return, modifiers: [.command])
        .accessibilityIdentifier("ask.submit")
        .help("Ask using the displayed results (Command-Return)")
    }

    // MARK: - Ask and Search controls

    private var askScopeControls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                sourceScopeControl
                timeScopeControl
                Spacer(minLength: 8)
                processingDestination
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) { sourceScopeControl; timeScopeControl }
                    .frame(minHeight: 28)
                processingDestination
            }
        }
        .font(WorkspaceTypography.control)
        .controlSize(.small)
    }

    private var processingDestination: some View {
        inferenceStatus.frame(minHeight: 28)
    }

    @ViewBuilder private var selectedEvidenceControl: some View {
        if meetingScope != nil || screenScope != nil {
            Button {
                clearPinnedScreens(restoringScope: true)
                app.recallState.clearEvidence()
                runSearch()
            } label: {
                Label("\(meetingScope.map { "\($0.count) meetings" } ?? "All meetings") · \(screenScope.map { "\($0.count) screens" } ?? "All screens")",
                      systemImage: "xmark.circle")
            }
            .help("Clear the selected evidence boundary")
            .accessibilityIdentifier("ask.selectedEvidence")
        }
    }

    private var sourceScopeControl: some View {
        Menu {
            ForEach(AskSourceScope.allCases) { source in
                Toggle(source.displayName, isOn: Binding(
                    get: { sources.contains(source) },
                    set: { _ in toggleSource(source) }))
                    .disabled((sources.contains(source) && sources.count == 1)
                              || (source == .screen && !pinnedScreens.isEmpty))
            }
            Divider()
            Picker("Result type", selection: Binding(get: { facet }, set: { facet = $0 })) {
                ForEach(AskFacet.allCases) { Text($0.rawValue).tag($0) }
            }
            if sources.contains(.screen) {
                Picker("Screen dates", selection: Binding(get: { screenDateScope }, set: { screenDateScope = $0 })) {
                    ForEach([ScreenSearchDateScope.today, .yesterday, .sevenDays, .any]) { Text($0.rawValue).tag($0) }
                }
                Picker("Screen app", selection: Binding(get: { selectedScreenApp }, set: { selectedScreenApp = $0 })) {
                    Text("All apps").tag(nil as String?)
                    ForEach(screenApps, id: \.self) { Text($0).tag(Optional($0)) }
                }
            }
            Divider()
            Button("Manage source permissions…") { app.openSettings(tab: .privacy) }
        } label: {
            Label(sourceSummary, systemImage: "line.3.horizontal.decrease.circle")
        }
        .fixedSize()
        .help("Choose sources and result filters")
        .accessibilityLabel("Sources")
        .accessibilityValue(sourceSummary)
        .accessibilityIdentifier("ask.sources")
    }

    private var sourceSummary: String {
        if sources == AskSourceScope.defaults { return "All sources" }
        if let only = sources.first, sources.count == 1 { return only.displayName }
        return "\(sources.count) sources"
    }

    private func toggleSource(_ source: AskSourceScope) {
        var selection = sources
        if selection.contains(source) {
            if selection.count > 1 { selection.remove(source) }
        } else {
            selection.insert(source)
        }
        app.recallState.chooseSources(selection)
    }

    private var timeScopeControl: some View {
        Button {
            showingTimeScope.toggle()
        } label: {
            Label(timeScopeLabel, systemImage: "calendar")
        }
        .buttonStyle(.bordered)
        .fixedSize()
        .popover(isPresented: $showingTimeScope, arrowEdge: .bottom) {
            timeScopePopover
        }
        .help("Limit every enabled source to one calendar day")
        .accessibilityIdentifier("ask.timeScope")
    }

    private var timeScopePopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Time scope")
                .font(WorkspaceTypography.sectionTitle)
            Text("Applied to Meetings, Activity, and Screen independently of source access.")
                .workspaceTextRole(.supporting)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button {
                    app.askDayScope = nil
                    showingTimeScope = false
                } label: {
                    Label("Any time", systemImage: app.askDayScope == nil ? "checkmark" : "clock")
                }
                .buttonStyle(.bordered)
                Button {
                    app.askDayScope = Calendar.current.startOfDay(for: Date())
                    showingTimeScope = false
                } label: {
                    Label("Today", systemImage: isTodayScoped ? "checkmark" : "sun.max")
                }
                .buttonStyle(.bordered)
            }
            Divider()
            DatePicker("Specific date", selection: scopedDate, displayedComponents: .date)
                .datePickerStyle(.compact)
                .accessibilityIdentifier("ask.timeScope.date")
        }
        .padding(16)
        .frame(width: 300)
    }

    private var scopedDate: Binding<Date> {
        Binding(
            get: { app.askDayScope ?? Date() },
            set: { app.askDayScope = Calendar.current.startOfDay(for: $0) })
    }

    private var isTodayScoped: Bool {
        app.askDayScope.map(Calendar.current.isDateInToday) ?? false
    }

    private var timeScopeLabel: String {
        guard let day = app.askDayScope else { return "Any time" }
        if Calendar.current.isDateInToday(day) { return "Today" }
        return day.formatted(date: .abbreviated, time: .omitted)
    }

    private var inferenceStatus: some View {
        Button {
            app.openSettings(tab: .models)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: inferenceState.icon)
                    .foregroundStyle(inferenceState.isBlocked ? Brand.error : inferenceState.isRemote ? Brand.teal : .secondary)
                Text(inferenceState.label)
                    .foregroundStyle(inferenceState.isRemote || inferenceState.isBlocked ? .primary : .secondary)
            }
            .font(WorkspaceTypography.metadataEmphasis)
            .padding(.horizontal, 8)
            .frame(minHeight: 28)
            .background(.quaternary.opacity(0.18), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help("\(inferenceStatusHelp) Open model settings.")
        .accessibilityLabel(inferenceStatusHelp)
        .accessibilityHint("Opens model settings")
        .accessibilityIdentifier("ask.inferenceStatus")
    }

    private var inferenceStatusHelp: String {
        inferenceState.detail(local: "Answers and selected evidence are processed on this Mac.",
                              remote: "Answers send your question and selected evidence to the configured server.")
    }

    private var inferenceState: InferencePresentation { InferencePresentation(settings: app.settings) }

    private var pinnedContextRow: some View {
        HStack(spacing: 8) {
            Label("Context", systemImage: "pin.fill")
                .font(WorkspaceTypography.metadataEmphasis)
                .foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(pinnedScreens) { context in
                        HStack(spacing: 6) {
                            ScreenThumbnailView(snapshotID: context.snapshotID, height: 34)
                                .frame(width: 54)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(context.app).font(WorkspaceTypography.metadataEmphasis).lineLimit(1)
                                Text(context.timestamp.formatted(date: .omitted, time: .shortened))
                                    .font(WorkspaceTypography.metadata.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            Button {
                                removePinnedScreen(context.id)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Remove \(context.app) screen from context")
                        }
                        .padding(4)
                        .background(.quaternary.opacity(0.35),
                                    in: RoundedRectangle(cornerRadius: Brand.Radius.control))
                    }
                }
            }
            Button("Clear") { clearPinnedScreens(restoringScope: true) }
                .buttonStyle(.plain)
                .font(WorkspaceTypography.metadata)
                .foregroundStyle(.secondary)
        }
        .accessibilityIdentifier("ask.screen.context")
    }

    // MARK: - Escalation

    /// ↵ or the pinned row: hand the query to the assistant and switch the
    /// pane to the conversation (the send appends messages, which flips the
    /// router to `.conversation`; clearing the query keeps it there). A day
    /// scope from Capture is prepended so the agent reaches for its
    /// activity-summary tool with the right date.
    private func escalate() {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !model.isResponding else { return }
        reconcilePinnedScreenScope()
        let scope = AskEscalationScope.resolve(
            mode: mode,
            selectedSources: sources,
            selectedDay: app.askDayScope)
        let contextualQuestion = ScreenAskContext.prompt(question: q, contexts: pinnedScreens)
        let prompt: String
        if let day = scope.dayScope {
            prompt = "About my day on \(day.formatted(date: .long, time: .omitted)): \(contextualQuestion)"
        } else {
            prompt = contextualQuestion
        }
        mode = .ask
        model.send(
            prompt,
            displayText: q,
            sourceScopes: scope.sources,
            dayScope: scope.dayScope,
            attachedScreenDates: pinnedScreens.map(\.timestamp),
            meetingIDs: meetingScope, screenSnapshotIDs: screenScope)
        sources = scope.sources
        app.askDayScope = scope.dayScope
        clearPinnedScreens(restoringScope: false)
        query = ""
    }

    private func openSelectedConversation() {
        query = ""
        mode = .ask
        if model.messages.isEmpty { resetAskScope() } else { restoreAskScope() }
        inputFocused = true
    }

    private func resetAskScope() {
        app.recallState.clearEvidence()
        app.recallState.chooseSources(AskSourceScope.defaults)
        app.askDayScope = nil
        pinnedScreens = []
        screenWasEnabledBeforePins = nil
        showingTimeScope = false
    }

    private func restoreAskScope() {
        guard let scope = model.currentQuestionScope else {
            resetAskScope()
            return
        }
        app.recallState.selectEvidence(meetingIDs: scope.meetingIDs, screenIDs: scope.screenSnapshotIDs,
                                       sources: scope.sources)
        app.askDayScope = scope.dayScopeKey.flatMap { AskDayScope.date(for: $0) }
        pinnedScreens = []
        screenWasEnabledBeforePins = nil
        showingTimeScope = false
    }

    private func reconcilePinnedScreenScope() {
        guard !pinnedScreens.isEmpty else { return }
        pinnedScreens = ScreenAskContext.withinDay(pinnedScreens, day: app.askDayScope)
        sources.insert(.screen)
        screenScope = Set(pinnedScreens.map(\.snapshotID))
    }

    private func rememberScreenAccessBeforePinning() {
        guard screenWasEnabledBeforePins == nil else { return }
        screenWasEnabledBeforePins = sources.contains(.screen)
    }

    private func removePinnedScreen(_ id: Int64) {
        pinnedScreens.removeAll { $0.id == id }
        screenScope = Set(pinnedScreens.map(\.snapshotID))
        if pinnedScreens.isEmpty { restoreScopeAfterRemovingPins() }
    }

    private func clearPinnedScreens(restoringScope: Bool) {
        pinnedScreens = []
        if restoringScope {
            restoreScopeAfterRemovingPins()
        } else {
            screenWasEnabledBeforePins = nil
        }
    }

    private func restoreScopeAfterRemovingPins() {
        guard let wasEnabled = screenWasEnabledBeforePins else { return }
        if !wasEnabled, sources.contains(.screen), sources.count > 1 {
            var updated = sources
            updated.remove(.screen)
            sources = updated
        }
        screenWasEnabledBeforePins = nil
    }

    // MARK: - Results

    private var results: some View {
        ScrollViewReader { proxy in
            List {
                if isSearching { LoadingStateLabel("Searching local sources…") }
                Text("Showing \(resultCount) source \(resultCount == 1 ? "group" : "groups") · Return opens · ⌘Return asks")
                    .workspaceTextRole(.metadata)
                if resultCount == 0 && !isSearching {
                    noMatchesRow(sources == [.today]
                        ? "Activity totals are available in Ask. Enable Meetings or Screen to search source text."
                        : "No results for “\(query)” in this scope.")
                }
                ForEach(Array(groupedMeetings.enumerated()), id: \.element.id) { index, group in
                    VStack(alignment: .leading) {
                        meetingResult(group.primary)
                        if group.matches.count > 1 {
                            DisclosureGroup("\(group.matches.count - 1) more \(group.matches.count == 2 ? "match" : "matches")") {
                                ForEach(group.matches.filter { $0.id != group.primary.id }) { meetingResult($0) }
                            }
                        }
                    }
                    .id(index)
                    .listRowBackground(index == selectedResult ? Brand.teal.opacity(0.12) : Color.clear)
                }
                ForEach(Array(screenGroups.enumerated()), id: \.element.id) { index, group in
                    VStack(alignment: .leading) {
                        Text(group.primary.ts.formatted(date: .abbreviated, time: .omitted))
                            .font(WorkspaceTypography.metadata).foregroundStyle(.secondary)
                        screenResult(group.primary)
                        if group.matches.count > 1 {
                            DisclosureGroup("\(group.matches.count - 1) more moments in this session") {
                                ForEach(group.matches.dropFirst()) { screenResult($0) }
                            }
                        }
                    }
                    .id(groupedMeetings.count + index)
                    .listRowBackground(groupedMeetings.count + index == selectedResult ? Brand.teal.opacity(0.12) : Color.clear)
                }
            }
            .listStyle(.inset)
            .accessibilityIdentifier("search.results")
            .accessibilityLabel("Search results")
            .onChange(of: selectedResult) { proxy.scrollTo(selectedResult) }
            .onChange(of: resultCount) { proxy.scrollTo(selectedResult) }
        }
    }

    private func meetingResult(_ hit: SearchIndex.Hit) -> some View {
        Button { app.openSearchHit(hit) } label: {
            ResultRow(title: meetingTitle(hit.meetingID), kind: kindLabel(hit), snippet: hit.snippet,
                      timestamp: meetingDate(hit.meetingID)).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("search.hit.\(hit.meetingID.uuidString).\(hit.kind.rawValue)")
    }

    private func screenResult(_ hit: ActivityStore.OCRHit) -> some View {
        ScreenSearchResultRow(hit: hit, isPinned: pinnedScreens.contains { $0.snapshotID == hit.snapshotID },
                              open: { app.openScreenSnapshot(hit.snapshotID) }, togglePin: { togglePinned(hit) })
    }

    private func noMatchesRow(_ text: String) -> some View {
        Text(text)
            .font(.callout).foregroundStyle(.secondary)
            .padding(.vertical, 6)
    }

    private func meetingTitle(_ id: Meeting.ID) -> String {
        app.meetings.first { $0.id == id }?.title ?? "Unknown meeting"
    }

    private func meetingDate(_ id: Meeting.ID) -> String? {
        app.meetings.first { $0.id == id }?
            .startedAt.formatted(date: .abbreviated, time: .omitted)
    }

    private func kindLabel(_ hit: SearchIndex.Hit) -> String {
        switch hit.kind {
        case .title: "Title"
        case .summary: "Summary"
        case .segment: "▶ \(Transcript.stamp(hit.start))\(hit.speaker.isEmpty ? "" : " · \(hit.speaker)")"
        }
    }

    private func runSearch() {
        searchTask?.cancel()
        let q = query, request = app.recallState, day = app.askDayScope
        // Never leave rows from a previous query available to Return.
        hits = []; ocrHits = []; screenGroups = []
        isSearching = !q.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        searchTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(160))
            guard !Task.isCancelled else { return }
            let result = await RecallSearch.search(q, state: request, day: day, app: app) { lexical in
                guard !Task.isCancelled, q == query else { return }
                publishSearch(lexical)
            }
            guard !Task.isCancelled, q == query else { return }
            publishSearch(result)
            isSearching = false
        }
    }

    private func publishSearch(_ result: RecallSearch.Result) {
        hits = result.meetings.flatMap(\.matches)
        screenGroups = result.screens
        ocrHits = result.screens.flatMap(\.matches)
        screenApps = Array(Set(ocrHits.map(\.app))).sorted()
        selectedResult = min(selectedResult, max(0, resultCount - 1))
    }

    private func togglePinned(_ hit: ActivityStore.OCRHit) {
        if let index = pinnedScreens.firstIndex(where: { $0.snapshotID == hit.snapshotID }) {
            let id = pinnedScreens[index].id
            removePinnedScreen(id)
        } else {
            if pinnedScreens.isEmpty { rememberScreenAccessBeforePinning() }
            if let screenshot = app.activityStore.screenshot(id: hit.snapshotID) {
                let ocr = app.activityStore.ocrText(snapshotID: hit.snapshotID) ?? hit.snippet
                pinnedScreens.append(ScreenAskContext(screenshot: screenshot, ocrText: ocr))
            } else {
                pinnedScreens.append(ScreenAskContext(hit: hit))
            }
            reconcilePinnedScreenScope()
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "sparkle.magnifyingglass")
                .font(.system(size: 32))
                .accessibilityHidden(true)
            Text("Ask your work memory")
                .font(WorkspaceTypography.display)
                .foregroundStyle(.primary)
            VStack(spacing: 10) {
                Text("Type to find meetings and screen moments. Press Return to open a result, or ⌘Return to ask about what you found.")
                    .font(WorkspaceTypography.editorialBody)
                    .foregroundStyle(Color.primary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 400)
            }
            VStack(spacing: 8) {
                ForEach(model.suggestions, id: \.self) { suggestion in
                    Button { sendSuggestion(suggestion) } label: {
                        HStack {
                            Text(suggestion).foregroundStyle(.primary)
                            Spacer(minLength: 8)
                            Image(systemName: "arrow.up.circle.fill").foregroundStyle(.tint)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 9)
                        .frame(maxWidth: 400)
                        .background(.quaternary.opacity(0.5),
                                    in: RoundedRectangle(cornerRadius: Brand.Radius.control))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 4)
        }
        .padding(24)
        .accessibilityIdentifier("chat.empty")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func sendSuggestion(_ suggestion: String) {
        query = suggestion
        escalate()
    }
}
