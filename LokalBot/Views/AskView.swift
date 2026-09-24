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
    @State private var searchedQuery = ""
    @State private var pendingQuestion: String?
    /// Arrow keys mean "open this result", so Return then opens even a question.
    @State private var pickedResultWithKeyboard = false
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
            if model.isLoadingHistory { LoadingStateLabel("Loading conversations…") }
            retrievalBody
            composerDock
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(nil, value: phase)
    }

    private var searchContent: some View {
        layout
        .onChange(of: query) {
            model.preserveSelectionDuringHistoryLoad()
            selectedResult = 0
            pickedResultWithKeyboard = false
            // Return can arrive before this observer. Preserve only a request
            // for this exact text; editing a queued question cancels it.
            if pendingQuestion != query { pendingQuestion = nil }
            runSearch(cancelPendingQuestion: false)
        }
        .onReceive(NotificationCenter.default.publisher(for: .retainedScreenTextChanged)) { _ in
            runSearch(cancelPendingQuestion: false)
        }
        .onDisappear {
            searchTask?.cancel()
            pendingQuestion = nil
        }
        .onChange(of: facet) { runSearch() }
        .onChange(of: meetingScope) { runSearch() }
        .onChange(of: screenScope) { runSearch() }
        .onChange(of: app.askDateScope) {
            reconcilePinnedScreenScope()
            runSearch()
        }
        .onChange(of: selectedScreenApp) { runSearch() }
        .onChange(of: sources) {
            if !sources.contains(.screen) { selectedScreenApp = nil }
            runSearch()
        }
    }

    var body: some View {
        searchContent
        .onKeyPress(.downArrow) {
            guard phase == .searching, resultCount > 0 else { return .ignored }
            selectedResult = min(selectedResult + 1, resultCount - 1)
            pickedResultWithKeyboard = true
            pendingQuestion = nil
            return .handled
        }
        .onKeyPress(.upArrow) {
            guard phase == .searching, resultCount > 0 else { return .ignored }
            selectedResult = max(0, selectedResult - 1)
            pickedResultWithKeyboard = true
            pendingQuestion = nil
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
        pendingQuestion = nil
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

    /// Docked at the bottom like Agent's composer. Rows that come and go with
    /// the query stack above the field, so arriving results never move it.
    private var composerDock: some View {
        VStack(alignment: .leading, spacing: 8) {
            activeSearchFilters
            selectedEvidenceControl
            if phase == .searching { answerScopePreview }
            if !pinnedScreens.isEmpty {
                pinnedContextRow
            }
            composerPanel
            inferenceStatus
        }
        .padding(.horizontal, WorkspaceMetric.pagePadding)
        .padding(.top, 10)
        .padding(.bottom, 14)
        .workspaceReadingWidth()
        .frame(maxWidth: .infinity)
    }

    private var composerPanel: some View {
        let canSubmit = !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !model.isResponding

        return VStack(alignment: .leading, spacing: 12) {
            TextField(
                "Search or ask about your work…",
                text: queryBinding,
                axis: .vertical)
                .textFieldStyle(.plain)
                .font(WorkspaceTypography.body)
                .lineLimit(1...4)
                .frame(minWidth: 60, maxWidth: .infinity, alignment: .topLeading)
                .focused($inputFocused)
                .onSubmit { submitQuery() }
                .accessibilityLabel("Question or search")
                .accessibilityIdentifier("search.field")
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    askScopeControls
                    Spacer(minLength: 4)
                    sendControls(canSubmit: canSubmit)
                }
                VStack(alignment: .leading, spacing: 10) {
                    askScopeControls
                    HStack { Spacer(); sendControls(canSubmit: canSubmit) }
                }
            }
        }
        .padding(14)
        .composerChrome(focused: inputFocused)
    }

    /// A fixed-width slot, so the changing Ask label never reflows the
    /// composer between its wide and stacked layouts.
    private func sendControls(canSubmit: Bool) -> some View {
        HStack(spacing: 8) {
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
        }
        .frame(width: 196, alignment: .trailing)
    }

    private var groupedMeetings: [MeetingRecallGroup] { RecallSearch.groups(hits) }
    private var resultCount: Int { groupedMeetings.count + screenGroups.count }

    /// Return: keywords open the highlighted result; a question asks through
    /// `askAboutResults`, the same scoped path as Command-Return.
    private func submitQuery() {
        guard phase == .searching else { return }
        switch returnAction {
        case .ask: askAboutResults()
        case .openResult: openSelectedResult()
        case .none: break
        }
    }

    private var returnAction: AskReturnAction {
        AskReturnAction.resolve(query: query, resultCount: resultCount,
                                pickedWithKeyboard: pickedResultWithKeyboard)
    }

    private func openSelectedResult() {
        if groupedMeetings.indices.contains(selectedResult) {
            app.openSearchHit(groupedMeetings[selectedResult].primary)
        } else {
            let index = selectedResult - groupedMeetings.count
            if screenGroups.indices.contains(index) { app.openScreenSnapshot(screenGroups[index].primary.snapshotID) }
        }
    }

    /// Command-Return sends explicitly, bounded to the displayed source groups.
    /// No matches leaves the chosen source/day scope available for a question.
    private var answerScreenIDs: Set<Int64> {
        Set(screenGroups.flatMap(\.matches).map(\.snapshotID)).union(pinnedScreens.map(\.snapshotID))
    }

    private var answerScopePreview: some View {
        DisclosureGroup {
            if resultCount > 0 {
                Text("The answer can retrieve passages from these meetings and screen moments, including collapsed matches. It may use only the passages relevant to your question.")
                    .workspaceTextRole(.supporting)
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(groupedMeetings) { group in
                            Text("Meeting · \(meetingTitle(group.id)) · \(meetingDate(group.id) ?? "")")
                        }
                        ForEach(screenGroups) { group in
                            Text("Screen · \(group.primary.app) · \(group.primary.ts.formatted(date: .abbreviated, time: .shortened)) · \(CountLabel.format(group.matches.count, "moment"))")
                        }
                        ForEach(pinnedScreens) { pin in
                            Text("Attached screen · \(pin.app) · \(pin.timestamp.formatted(date: .abbreviated, time: .shortened))")
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 160)
            } else {
                Text(meetingScope != nil || screenScope != nil
                     ? "Ask stays within the selected evidence shown above, even when this search has no matches."
                     : "Ask can search the selected sources within \(timeScopeLabel.lowercased()). Result-type and screen-app filters apply to search results only.")
            }
        } label: {
            Text(isSearching ? "Finding sources…" : resultCount > 0
                 ? "Answer sources: \(CountLabel.format(groupedMeetings.count, "meeting")) · \(CountLabel.format(answerScreenIDs.count, "screen moment"))"
                 : "Answer sources: \(sourceSummary) · \(timeScopeLabel)")
        }
        .font(WorkspaceTypography.metadata)
        .foregroundStyle(.secondary)
        .accessibilityIdentifier("ask.answerScope")
    }

    private func askAboutResults() {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !model.isResponding else { return }
        // Never submit rows belonging to the previous text if Return beats
        // onChange. Completion below uses the same scoped submission path.
        if searchedQuery != query { runSearch() }
        if isSearching {
            pendingQuestion = query
            return
        }
        pendingQuestion = nil
        if resultCount > 0 {
            app.recallState.selectEvidence(
                meetingIDs: Set(groupedMeetings.map(\.id)),
                screenIDs: answerScreenIDs)
        }
        escalate()
    }

    private func submitButton(canSubmit: Bool) -> some View {
        Button(action: askAboutResults) {
            Label(pendingQuestion != nil ? "Waiting for sources…"
                  : resultCount > 0 ? "Ask about results" : "Ask", systemImage: "sparkles")
                .font(.system(size: 13, weight: .semibold))
        }
        .primaryActionButton()
        .controlSize(.large)
        .disabled(!canSubmit || pendingQuestion != nil)
        .keyboardShortcut(.return, modifiers: [.command])
        .accessibilityIdentifier("ask.submit")
        .help("Ask using the displayed results (Command-Return)")
    }

    // MARK: - Ask and Search controls

    private var askScopeControls: some View {
        HStack(spacing: 10) {
            sourceScopeControl
            dateScopeControls
        }
        .font(WorkspaceTypography.metadataEmphasis)
        .controlSize(.small)
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
        WorkspaceMenu(title: sourceSummary, label: "Sources", identifier: "ask.sources", items: sourceMenuItems,
                      font: .systemFont(ofSize: 13, weight: .semibold))
            .fixedSize()
            .help("Choose sources and result filters")
    }

    private var sourceMenuItems: [WorkspaceMenu.Item] {
        var items = AskSourceScope.allCases.map { source in
            WorkspaceMenu.Item(title: source.displayName,
                enabled: !((sources.contains(source) && sources.count == 1)
                           || (source == .screen && !pinnedScreens.isEmpty)),
                selected: sources.contains(source), action: { toggleSource(source) })
        }
        items += [.separator, .init(title: "Result type", children: AskFacet.allCases.map { option in
            .init(title: option.rawValue, selected: facet == option, action: { facet = option })
        })]
        if sources.contains(.screen) {
            items.append(.init(title: "Screen app", children:
                [.init(title: "All apps", selected: selectedScreenApp == nil, action: { selectedScreenApp = nil })]
                + screenApps.map { name in
                    .init(title: name, selected: selectedScreenApp == name, action: { selectedScreenApp = name })
                }))
        }
        items += [.separator, .init(title: "Manage source permissions…", action: { app.openSettings(tab: .privacy) })]
        return items
    }

    private var sourceSummary: String {
        sources == AskSourceScope.defaults ? "All sources"
            : AskSourceScope.allCases.filter(sources.contains).map(\.displayName).joined(separator: ", ")
    }

    private var hasSearchFilters: Bool {
        app.askDateScope != nil || facet != .all || selectedScreenApp != nil
    }

    @ViewBuilder private var activeSearchFilters: some View {
        if facet != .all || selectedScreenApp != nil {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { searchFilterButtons }
                VStack(alignment: .leading, spacing: 6) { searchFilterButtons }
            }
            .font(WorkspaceTypography.control)
            .controlSize(.small)
            .accessibilityIdentifier("ask.activeFilters")
        }
    }

    @ViewBuilder private var searchFilterButtons: some View {
        if facet != .all {
            Button { facet = .all } label: {
                Label("Results: \(facet.rawValue)", systemImage: "xmark.circle")
            }
            .help("Clear the result-type filter")
            .accessibilityIdentifier("ask.filter.resultType")
        }
        if let selectedScreenApp {
            Button { self.selectedScreenApp = nil } label: {
                Label("Screen app: \(selectedScreenApp)", systemImage: "xmark.circle")
            }
            .help("Clear the screen-app filter; it does not filter meetings or activity")
            .accessibilityIdentifier("ask.filter.screenApp")
        }
    }

    private func clearSearchFilters() {
        facet = .all
        selectedScreenApp = nil
        app.askDateScope = nil
    }

    private func toggleSource(_ source: AskSourceScope) {
        var selection = sources
        if selection.contains(source) {
            if selection.count > 1 { selection.remove(source) }
        } else {
            selection.insert(source)
        }
        app.recallState.chooseSources(selection)
        if !selection.contains(.screen) { selectedScreenApp = nil }
    }

    private var dateScopeControls: some View {
        HStack(spacing: 4) {
            timeScopeControl
            if app.askDateScope != nil {
                Button { app.askDateScope = nil } label: { Image(systemName: "xmark.circle") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Clear date filter")
                    .accessibilityIdentifier("ask.filter.date.clear")
            }
        }
    }

    private var timeScopeControl: some View {
        Button { showingTimeScope.toggle() } label: {
            Label(timeScopeLabel, systemImage: "calendar")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.primary)
        .fixedSize()
        .popover(isPresented: $showingTimeScope, arrowEdge: .bottom) { timeScopePopover }
        .help("One date scope for meeting, activity, and screen search and answers")
        .accessibilityIdentifier("ask.timeScope")
    }

    private var timeScopePopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Date scope").font(WorkspaceTypography.sectionTitle)
            Text("Applies to search results and answers across all selected sources.")
                .workspaceTextRole(.supporting)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                datePreset("Any time", scope: nil, identifier: "any")
                datePreset("Today", scope: AskDateScope(day: Date()), identifier: "today")
            }
            HStack {
                datePreset("Yesterday", scope: Calendar.current.date(byAdding: .day, value: -1, to: Date())
                    .map { AskDateScope(day: $0) }, identifier: "yesterday")
                datePreset("Last 7 days", scope: .lastSevenDays(), identifier: "sevenDays")
            }
            Divider()
            HStack {
                DatePicker("Specific date", selection: scopedDate, displayedComponents: .date)
                    .datePickerStyle(.compact)
                    .accessibilityIdentifier("ask.timeScope.date")
                Button("Use date") { app.askDateScope = AskDateScope(day: scopedDate.wrappedValue); showingTimeScope = false }
                    .accessibilityIdentifier("ask.timeScope.useDate")
            }
        }
        .padding(16)
        .frame(width: 340)
    }

    private func datePreset(_ label: String, scope: AskDateScope?, identifier: String) -> some View {
        Button {
            app.askDateScope = scope
            showingTimeScope = false
        } label: {
            Label(label, systemImage: app.askDateScope == scope ? "checkmark" : "calendar")
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier("ask.timeScope.\(identifier)")
    }

    private var scopedDate: Binding<Date> {
        Binding(
            get: { app.askDateScope.flatMap { AskDayScope.date(for: $0.firstDay) } ?? Date() },
            set: { app.askDateScope = AskDateScope(day: $0) })
    }

    private var timeScopeLabel: String { app.askDateScope?.label() ?? "Any time" }

    private var inferenceStatus: some View {
        Button {
            app.openSettings(tab: .models)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: inferenceState.icon)
                    .foregroundStyle(inferenceState.isBlocked ? Brand.error : inferenceState.isRemote ? Brand.teal : .secondary)
                Text(inferenceState.label)
                    .foregroundStyle(inferenceState.isRemote || inferenceState.isBlocked ? .primary : .secondary)
            }
            .font(WorkspaceTypography.metadata)
            .frame(minHeight: 24)
            .contentShape(Rectangle())
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
        let dateScope = app.askDateScope
        let contextualQuestion = ScreenAskContext.prompt(question: q, contexts: pinnedScreens)
        let prompt = dateScope.map { "About my work on \($0.dateLabel): \(contextualQuestion)" } ?? contextualQuestion
        mode = .ask
        model.send(
            prompt,
            displayText: q,
            sourceScopes: sources,
            dateScope: dateScope,
            attachedScreenDates: pinnedScreens.map(\.timestamp),
            meetingIDs: meetingScope, screenSnapshotIDs: screenScope)
        clearPinnedScreens(restoringScope: false)
        query = ""
    }

    private func openSelectedConversation() {
        pendingQuestion = nil
        query = ""
        mode = .ask
        if model.messages.isEmpty { resetAskScope() } else { restoreAskScope() }
        inputFocused = true
    }

    private func resetAskScope() {
        app.recallState.clearEvidence()
        app.recallState.chooseSources(AskSourceScope.defaults)
        app.askDateScope = nil
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
        app.askDateScope = scope.dayScopeKey.flatMap { AskDateScope(storageKey: $0) }
        pinnedScreens = []
        screenWasEnabledBeforePins = nil
        showingTimeScope = false
    }

    private func reconcilePinnedScreenScope() {
        guard !pinnedScreens.isEmpty else { return }
        if let dateScope = app.askDateScope { pinnedScreens = pinnedScreens.filter { dateScope.contains($0.timestamp) } }
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
                Text(CountLabel.format(resultCount, "result") + (returnAction == .ask
                     ? " · Return asks · ↓ to pick a result"
                     : " · Return opens · ⌘Return asks"))
                    .workspaceTextRole(.metadata)
                if resultCount == 0 && !isSearching {
                    noMatchesRow(sources == [.today]
                        ? "Activity totals are available in Ask. Enable Meetings or Screen to search source text."
                        : "No results for “\(query)” in \(sourceSummary) · \(timeScopeLabel).")
                    if hasSearchFilters {
                        Button("Clear search filters", action: clearSearchFilters)
                            .accessibilityIdentifier("ask.filters.clear")
                    }
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
                        screenResult(group.primary)
                        if group.matches.count > 1 {
                            DisclosureGroup("\(CountLabel.format(group.matches.count - 1, "more moment")) in this session") {
                                ForEach(group.matches.dropFirst()) { screenResult($0) }
                            }
                        }
                    }
                    .id(groupedMeetings.count + index)
                    .listRowBackground(groupedMeetings.count + index == selectedResult ? Brand.teal.opacity(0.12) : Color.clear)
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            // Results share the composer's reading column.
            .frame(maxWidth: WorkspaceMetric.readingMaxWidth)
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier("search.results")
            .accessibilityLabel("Search results")
            .onChange(of: selectedResult) { proxy.scrollTo(selectedResult) }
            .onChange(of: resultCount) { proxy.scrollTo(selectedResult) }
        }
    }

    private func meetingResult(_ hit: SearchIndex.Hit) -> some View {
        Button { app.openSearchHit(hit) } label: {
            ResultRow(title: meetingTitle(hit.meetingID), kind: kindLabel(hit), snippet: hit.snippet,
                      timestamp: meetingDate(hit.meetingID),
                      matchLabel: hit.isSemantic ? "Related by meaning" : nil)
                .contentShape(Rectangle())
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
        case .segment: "▶ \(Transcript.stamp(hit.start))\(hit.speaker.isEmpty ? "" : " · \(SpeakerDisplayName.label(hit.speaker))")"
        }
    }

    private func runSearch(cancelPendingQuestion: Bool = true) {
        if cancelPendingQuestion { pendingQuestion = nil }
        searchTask?.cancel()
        let q = query, request = app.recallState, dateScope = app.askDateScope
        searchedQuery = q
        // Never leave rows from a previous query available to Return.
        hits = []; ocrHits = []; screenGroups = []
        isSearching = !q.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        searchTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(160))
            #if LOKALBOT_UI_TEST_HOST
            // Hold retrieval in flight for deterministic hosted Return tests.
            if let delay = Int(ProcessInfo.processInfo.environment["LOKALBOT_ASK_SEARCH_DELAY_MS"] ?? "") {
                try? await Task.sleep(for: .milliseconds(min(max(delay, 0), 10_000)))
            }
            #endif
            guard !Task.isCancelled else { return }
            let result = await RecallSearch.search(q, state: request, dateScope: dateScope, app: app) { lexical in
                guard !Task.isCancelled, q == query else { return }
                publishSearch(lexical)
            }
            guard !Task.isCancelled, q == query else { return }
            publishSearch(result)
            isSearching = false
            if pendingQuestion == q { askAboutResults() }
        }
    }

    private func publishSearch(_ result: RecallSearch.Result) {
        hits = result.meetings.flatMap(\.matches)
        screenGroups = result.screens
        ocrHits = result.screens.flatMap(\.matches)
        screenApps = Array(Set(ocrHits.map(\.app) + [selectedScreenApp].compactMap { $0 })).sorted()
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
                Text("Type keywords to find meetings and screen moments, or ask a question. Return opens a keyword result or asks a question; ⌘Return always asks.")
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
