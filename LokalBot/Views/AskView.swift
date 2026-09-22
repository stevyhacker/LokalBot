import SwiftUI

/// Explicit local Search and scoped Ask share their retained source context.
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
    /// Search flavor within keyword mode: exact words vs. semantic matching.
    /// Seeded from the persisted setting; selecting "Match by meaning" turns
    /// indexing on, while going back to exact words never turns it off.
    private var matchByMeaning: Bool {
        get { app.recallState.meaning }
        nonmutating set { app.recallState.meaning = newValue }
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
    @State private var sourceScopePresented = false
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
        .animation(nil, value: mode)
        .animation(nil, value: matchByMeaning)
    }

    private var searchContent: some View {
        layout
        .onChange(of: query) {
            model.preserveSelectionDuringHistoryLoad()
            selectedResult = 0
            if mode == .keyword { runSearch() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .retainedScreenTextChanged)) { _ in
            if mode == .keyword { runSearch() }
        }
        .onDisappear { searchTask?.cancel() }
        .onChange(of: mode) {
            model.preserveSelectionDuringHistoryLoad()
            if mode == .keyword { runSearch() }
        }
        .onChange(of: facet) { runSearch() }
        .onChange(of: screenDateScope) { runSearch() }
        .onChange(of: app.askDayScope) {
            reconcilePinnedScreenScope()
            if mode == .keyword { runSearch() }
        }
        .onChange(of: selectedScreenApp) { runSearch() }
        .onChange(of: sources) { if mode == .keyword { runSearch() } }
    }

    var body: some View {
        searchContent
        .onKeyPress(.downArrow) {
            guard mode == .keyword, resultCount > 0 else { return .ignored }
            selectedResult = min(selectedResult + 1, resultCount - 1)
            return .handled
        }
        .onKeyPress(.upArrow) {
            guard mode == .keyword, resultCount > 0 else { return .ignored }
            selectedResult = max(0, selectedResult - 1)
            return .handled
        }
        .onChange(of: app.navigationHandoff.revision) { consumeNavigationHandoff() }
        .onChange(of: model.currentID) {
            // A saved conversation selection is an explicit mode switch. An
            // old search query must not keep masking the selected transcript.
            query = ""
            mode = .ask
            if model.messages.isEmpty {
                resetAskScope()
            } else {
                restoreAskScope()
            }
        }
        .onAppear {
            if mode == .keyword || !query.isEmpty { model.preserveSelectionDuringHistoryLoad() }
            _ = consumeNavigationHandoff()
            if mode == .keyword { runSearch() }
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
        meetingScope = handoff.meetingIDs
        screenScope = handoff.screenSnapshotIDs.map { Set($0) }
        if meetingScope != nil { sources = [.meetings] }
        if screenScope != nil { sources = meetingScope == nil ? [.screen] : [.meetings, .screen] }
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

    @ViewBuilder
    private var retrievalBody: some View {
        Group {
            if mode == .keyword {
                if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    keywordEmptyState
                } else {
                    results
                }
            } else if model.messages.isEmpty {
                emptyState
            } else {
                ChatTranscriptView(model: model)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            topLevelModeControl
            composerPanel
            askScopeControls
            selectedEvidenceControl
            if mode == .keyword { searchControls }
            if mode == .ask, !pinnedScreens.isEmpty {
                pinnedContextRow
            } else if mode == .keyword, facet == .screen {
                screenFilterRow
            }
        }
        .padding(.horizontal, WorkspaceMetric.pagePadding)
        .padding(.vertical, 16)
        .workspaceReadingWidth()
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private var topLevelModeControl: some View {
        Picker("Mode", selection: Binding(get: { mode }, set: selectMode)) {
            ForEach(AskMode.allCases) { candidate in
                Text(candidate.displayName).tag(candidate)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 180)
        .accessibilityIdentifier("ask.retrieval")
    }

    private func selectMode(_ selection: AskMode) {
        mode = selection
        if selection == .keyword { runSearch() }
        inputFocused = true
    }

    private var composerPanel: some View {
        let canSubmit = !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !model.isResponding

        return HStack(alignment: .center, spacing: 10) {
            TextField(
                mode == .ask
                    ? (model.messages.isEmpty
                        ? "Ask LokalBot about your work…"
                        : "Ask a follow-up…")
                    : (matchByMeaning
                        ? "Search local memory by meaning…"
                        : "Search exact words in local memory…"),
                text: queryBinding,
                axis: .vertical)
                .textFieldStyle(.plain)
                .font(WorkspaceTypography.body)
                .lineLimit(1...3)
                .frame(minWidth: 60, maxWidth: .infinity)
                .focused($inputFocused)
                .onSubmit { submitQuery() }
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
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(minHeight: 56)
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
        guard mode == .keyword else { escalate(); return }
        if groupedMeetings.indices.contains(selectedResult) {
            app.openSearchHit(groupedMeetings[selectedResult].primary)
        } else {
            let index = selectedResult - groupedMeetings.count
            if screenGroups.indices.contains(index) { app.openScreenSnapshot(screenGroups[index].primary.snapshotID) }
        }
    }

    /// Review the complete visible source groups before explicitly submitting.
    private func prepareResultQuestion() {
        guard !isSearching, resultCount > 0 else { return }
        meetingScope = Set(groupedMeetings.map(\.id))
        screenScope = Set(screenGroups.flatMap(\.matches).map(\.snapshotID))
        sources = []
        if meetingScope?.isEmpty == false { sources.insert(.meetings) }
        if screenScope?.isEmpty == false { sources.insert(.screen) }
        if sources.isEmpty { sources = [.meetings] }
        mode = .ask
        inputFocused = true
    }

    private func submitButton(canSubmit: Bool) -> some View {
        Button {
            guard canSubmit else { return }
            if mode == .ask { escalate() } else { prepareResultQuestion() }
        } label: {
            Label(mode == .ask ? "Ask" : "Ask about these results", systemImage: mode == .ask ? "arrow.up" : "sparkles")
                .font(WorkspaceTypography.control)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.regular)
        .tint(Brand.teal)
        .disabled(!canSubmit || (mode == .keyword && (isSearching || resultCount == 0)))
        .keyboardShortcut(.return, modifiers: [.command])
        .accessibilityIdentifier(mode == .ask ? "ask.submit" : "ask.escalate")
        .accessibilityLabel(mode == .ask ? "Ask" : "Ask about these results")
        .help(mode == .ask
            ? "Ask (Return or Command-Return)"
            : "Review result scope (Command-Return)")
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

    @ViewBuilder private var processingDestination: some View {
        if mode == .ask {
            inferenceStatus.frame(minHeight: 28)
        } else {
            Label("Search stays on this Mac", systemImage: "desktopcomputer")
                .workspaceTextRole(.supporting)
                .frame(minHeight: 28)
                .accessibilityIdentifier("ask.searchDestination")
        }
    }

    @ViewBuilder private var selectedEvidenceControl: some View {
        if meetingScope != nil || screenScope != nil {
            Button {
                meetingScope = nil
                screenScope = nil
                clearPinnedScreens(restoringScope: true)
                if mode == .keyword { runSearch() }
            } label: {
                Label("\(meetingScope.map { "\($0.count) meetings" } ?? "All meetings") · \(screenScope.map { "\($0.count) screens" } ?? "All screens")",
                      systemImage: "xmark.circle")
            }
            .help("Clear the selected evidence boundary")
            .accessibilityIdentifier("ask.selectedEvidence")
        }
    }

    private var sourceScopeControl: some View {
        Button { sourceScopePresented.toggle() } label: {
            Label(sourceSummary, systemImage: "square.stack.3d.up")
        }
        .fixedSize()
        .help("Choose which local sources LokalBot may use")
        .accessibilityLabel("Sources")
        .accessibilityValue(sourceSummary)
        .accessibilityIdentifier("ask.sources")
        .popover(isPresented: $sourceScopePresented) { sourceScopePopover }
    }

    private var sourceScopePopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sources").font(WorkspaceTypography.sectionTitle)
            ForEach(AskSourceScope.allCases) { source in
                Toggle(isOn: Binding(
                    get: { sources.contains(source) },
                    set: { _ in toggleSource(source) })) {
                    Label(source.displayName, systemImage: source.icon)
                }
                .toggleStyle(.checkbox)
                .accessibilityLabel(source.displayName)
                .disabled(
                    (sources.contains(source) && sources.count == 1)
                        || (source == .screen && !pinnedScreens.isEmpty))
            }
            Divider()
            Button {
                sourceScopePresented = false
                app.openSettings(tab: .privacy)
            } label: {
                Label("Manage source permissions…", systemImage: "gearshape")
            }
        }
        .padding(16)
        .frame(width: 280)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Source selection")
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
        sources = selection
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
                    .foregroundStyle(inferenceState.isBlocked ? Brand.error : Brand.teal)
                Text(inferenceState.label)
                    .foregroundStyle(.primary)
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

    private var searchControls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                searchMatchingControl
                Divider().frame(height: 20)
                facetControls
                Spacer(minLength: 0)
            }
            HStack(spacing: 10) {
                searchMatchingControl
                compactFacetControl
                Spacer(minLength: 0)
            }
        }
    }

    private var compactFacetControl: some View {
        Menu {
            ForEach(AskFacet.allCases) { candidate in
                Button {
                    facet = candidate
                } label: {
                    Label(candidate.rawValue,
                          systemImage: facet == candidate
                            ? "checkmark"
                            : "line.3.horizontal.decrease")
                }
            }
        } label: {
            Label("Filter: \(facet.rawValue)",
                  systemImage: "line.3.horizontal.decrease.circle")
        }
        .fixedSize()
        .accessibilityIdentifier("ask.facet.compact")
    }

    private var searchMatchingControl: some View {
        Picker("Search matching", selection: Binding(get: { matchByMeaning }, set: setMatchByMeaning)) {
            Text("Words").tag(false)
            Text("Meaning").tag(true)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .help(matchByMeaning
            ? "Match concepts even when the words differ"
            : "Match the words you type")
        .accessibilityIdentifier("ask.searchMatching")
        .accessibilityLabel("Search matching")
    }

    private func setMatchByMeaning(_ enabled: Bool) {
        matchByMeaning = enabled
        if enabled && !app.settings.semanticSearchEnabled { enableSemanticIndexing() }
        runSearch()
    }

    private var screenFilterRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                ForEach([ScreenSearchDateScope.today, .yesterday, .sevenDays, .any]) { scope in
                    screenFilterChip(scope.rawValue, selected: screenDateScope == scope) {
                        screenDateScope = scope
                    }
                }
                Spacer()
                Text("Click to rewind · pin to ask with context")
                    .font(WorkspaceTypography.metadata)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    screenFilterChip("All apps", selected: selectedScreenApp == nil) {
                        selectedScreenApp = nil
                    }
                    ForEach(screenApps, id: \.self) { appName in
                        screenFilterChip(appName, selected: selectedScreenApp == appName) {
                            selectedScreenApp = appName
                        }
                    }
                }
            }
        }
        .accessibilityIdentifier("ask.screen.filters")
    }

    private func screenFilterChip(_ text: String, selected: Bool,
                                  action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text)
                .font(.system(size: 11, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? AnyShapeStyle(.white)
                                          : AnyShapeStyle(.secondary))
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(selected ? AnyShapeStyle(Brand.teal)
                                     : AnyShapeStyle(.quaternary.opacity(0.45)),
                            in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

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

    private var facetControls: some View {
        HStack(spacing: 10) {
            ForEach(AskFacet.allCases) { candidate in
                facetChip(candidate.rawValue,
                          on: facet == candidate,
                          id: "ask.facet.\(candidate.rawValue.lowercased())") {
                    facet = candidate
                }
            }
        }
    }

    private func facetChip(_ label: String, on: Bool, id: String,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(WorkspaceTypography.control)
                .foregroundStyle(on ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(on ? AnyShapeStyle(Brand.teal)
                               : AnyShapeStyle(.quaternary.opacity(0.42)),
                            in: Capsule())
                .overlay {
                    Capsule().strokeBorder(
                        on ? Brand.teal.opacity(0.32) : Color.primary.opacity(0.09))
                }
                .fixedSize()
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    /// First selection of "Match by meaning" turns semantic indexing on and
    /// kicks off the embedding backfill (which downloads the embedding model
    /// on first use) — same behavior the old toggle had. Switching back to
    /// exact words never turns indexing off.
    private func enableSemanticIndexing() {
        app.settings.semanticSearchEnabled = true
        Task {
            await app.embeddingIndex.reindexAll(app.meetings)
            await app.embeddingIndex.reindexScreenText()
        }
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

    private func resetAskScope() {
        sources = AskSourceScope.defaults
        meetingScope = nil
        screenScope = nil
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
        sources = scope.sources
        meetingScope = scope.meetingIDs
        screenScope = scope.screenSnapshotIDs
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
                Text("Showing \(resultCount) source groups · Return opens the selected result")
                    .font(WorkspaceTypography.metadata).foregroundStyle(.secondary)
                if matchByMeaning && !app.embeddingIndex.hasEmbeddings {
                    Text("Meaning search is unavailable for meetings. Showing exact word matches.")
                        .workspaceTextRole(.warning)
                }
                if resultCount == 0 && !isSearching {
                    noMatchesRow(sources == [.today]
                        ? "Activity totals are available in Ask. Enable Meetings or Screen to search source text."
                        : "No results for “\(query)” in this scope.")
                }
                ForEach(Array(groupedMeetings.enumerated()), id: \.element.id) { index, group in
                    VStack(alignment: .leading) {
                        meetingResult(group.primary)
                        if group.matches.count > 1 {
                            DisclosureGroup("\(group.matches.count - 1) more matches") {
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

    private var searchMeetingIDs: Set<UUID>? {
        guard let day = app.askDayScope else { return meetingScope }
        let dayIDs = Set(app.meetings.filter { Calendar.current.isDate($0.startedAt, inSameDayAs: day) }.map(\.id))
        return meetingScope.map { $0.intersection(dayIDs) } ?? dayIDs
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
        ContentUnavailableView {
            Label("Ask your work memory", systemImage: "sparkle.magnifyingglass")
        } description: {
            VStack(spacing: 10) {
                Text("Find an answer in indexed meetings and permitted screen text, with sources. Asking is read-only.")
                    .frame(maxWidth: 400)
                if inferenceState.isBlocked {
                    Label(inferenceStatusHelp, systemImage: inferenceState.icon)
                        .workspaceTextRole(.warning)
                        .frame(maxWidth: 400, alignment: .leading)
                } else {
                    InferenceDisclosure(
                        settings: app.settings,
                        localText: "Answers use your local Main LLM; retrieved evidence stays on this Mac.",
                        remoteText: "Answers use your approved remote Main LLM (\(app.settings.summarizerBackend.displayName)); retrieved evidence is sent to that server.")
                        .frame(maxWidth: 400, alignment: .leading)
                }
            }
        } actions: {
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
        .accessibilityIdentifier("chat.empty")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var keywordEmptyState: some View {
        ContentUnavailableView {
            Label(matchByMeaning ? "Match by meaning" : "Keyword search",
                  systemImage: matchByMeaning ? "atom" : "magnifyingglass")
        } description: {
            Text(matchByMeaning
                ? "Find meetings and permitted screen text that mean what you type, even when the words differ."
                : "Search meeting titles, transcripts, summaries, and permitted screen text without asking the model.")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func sendSuggestion(_ suggestion: String) {
        query = suggestion
        escalate()
    }
}
