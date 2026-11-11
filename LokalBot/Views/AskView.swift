import SwiftUI

/// One field, one flow: typing lists what matches, Return asks about it. A
/// new question has the field mid-page with its matches underneath; inside a
/// conversation the field is docked and the matches rise in a tray above it,
/// so the conversation stays on screen.
struct AskView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        GeometryReader { geometry in
            AskContent(model: app.chat, recall: app.recall, height: geometry.size.height)
                .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }
}

private struct AskContent: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var model: ChatViewModel
    @ObservedObject var recall: RecallWorkspace
    let height: CGFloat

    private var query: String {
        get { recall.query }
        nonmutating set { recall.query = newValue }
    }
    private var queryBinding: Binding<String> { Binding(get: { query }, set: { query = $0 }) }
    private var meetingScope: Set<UUID>? { recall.state.meetingIDs }
    private var screenScope: Set<Int64>? { recall.state.screenIDs }
    private var facet: AskFacet {
        get { recall.state.facet }
        nonmutating set { recall.state.facet = newValue }
    }
    private var selectedScreenApp: String? {
        get { recall.state.screenApp }
        nonmutating set { recall.state.screenApp = newValue }
    }
    private var pinnedScreens: [ScreenAskContext] {
        get { recall.state.pins }
        nonmutating set { recall.state.pins = newValue }
    }
    private var sources: Set<AskSourceScope> { recall.state.sources }

    /// What the field's text matches. A keyword's answer is limited to
    /// these; a full question reads the chosen sources (`AskAnswerScope`).
    @State private var matches = AskMatches()
    @State private var screenApps: [String] = []
    @State private var searchTask: Task<Void, Never>?
    @State private var isSearching = false
    @State private var searchedQuery = ""
    @State private var pendingQuestion: String?
    /// In the field, Return asks. Once the arrow keys move onto a match,
    /// Return opens that match.
    @State private var cursor = AskMatchCursor()
    /// Escape folds the tray to its heading so the conversation is clear.
    @State private var trayCollapsed = false
    /// Match rows whose folded lines are showing.
    @State private var expandedMatches: Set<String> = []
    @State private var choosingDate = false
    @FocusState private var inputFocused: Bool

    private var phase: AskPhase { AskRouter.phase(query: query, hasMessages: !model.messages.isEmpty) }
    private var localized: (String) -> String { app.settings.appLanguage.catalog }

    // MARK: - Page

    private var page: some View {
        VStack(spacing: 0) {
            if model.isLoadingHistory { LoadingStateLabel("Loading conversations…") }
            if let persistenceError = model.persistenceError {
                HStack {
                    Label(persistenceError, systemImage: "exclamationmark.triangle")
                    Spacer()
                    Button("Retry") { model.retryPersistence() }
                }
                .font(AppFont.scaled(.callout))
                .padding(12)
                .accessibilityIdentifier("ask.persistenceError")
            }
            aboveField
            // The field is the same view on both pages, so it keeps its text
            // and focus when the first answer turns the page into a thread.
            fieldColumn
            belowField
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(nil, value: phase)
    }

    @ViewBuilder private var aboveField: some View {
        switch phase.page {
        case .newQuestion:
            Text("Ask about your meetings, screen and files")
                .font(AppFont.scaledSystem(size: 22, weight: .bold))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, WorkspaceMetric.pagePadding)
                .padding(.top, max(28, min(150, height * 0.17)))
                .padding(.bottom, 18)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("ask.heading")
        case .conversation:
            ChatTranscriptView(model: model)
                .overlay(alignment: .bottom) { matchesTray }
        }
    }

    private var fieldColumn: some View {
        let docked = phase.page == .conversation
        return VStack(alignment: .leading, spacing: 8) {
            if !pinnedScreens.isEmpty { pinnedContextRow }
            composerPanel
            inferenceStatus
        }
        .padding(.horizontal, WorkspaceMetric.pagePadding)
        .padding(.top, docked ? 10 : 0)
        .padding(.bottom, docked ? 14 : 0)
        .workspaceReadingWidth()
        .frame(maxWidth: .infinity)
        .overlay(alignment: .top) {
            if docked {
                LinearGradient(colors: [.clear, Color(nsColor: .windowBackgroundColor).opacity(0.7)],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: 14).offset(y: -14).allowsHitTesting(false).accessibilityHidden(true)
            }
        }
    }

    @ViewBuilder private var belowField: some View {
        if phase.page == .newQuestion {
            ScrollViewReader { proxy in
                ScrollView {
                    Group {
                        if phase.isTyping { matchesUnderField } else { suggestionList }
                    }
                    .padding(.horizontal, WorkspaceMetric.pagePadding)
                    .padding(.bottom, WorkspaceMetric.pagePadding)
                    .workspaceReadingWidth()
                    .frame(maxWidth: .infinity)
                }
                .onChange(of: cursor) { scrollToCursor(proxy) }
            }
        }
    }

    private var searchContent: some View {
        page
        .onChange(of: query) {
            model.preserveSelectionDuringHistoryLoad()
            cursor.returnToField()
            if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { trayCollapsed = false }
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
        .onKeyPress(.downArrow) { moveCursor(.down) }
        .onKeyPress(.upArrow) { moveCursor(.up) }
        .onKeyPress(.escape) { leaveMatches() }
        .onChange(of: app.navigationHandoff.revision) { consumeNavigationHandoff() }
        .onChange(of: model.currentID) {
            // A saved conversation selection is an explicit mode switch. An
            // old search query must not stay in the selected conversation's field.
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
        app.askMode = handoff.mode
        recall.state.selectEvidence(meetingIDs: handoff.meetingIDs,
                                       screenIDs: handoff.screenSnapshotIDs.map { Set($0) },
                                       sources: handoff.sources)
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

    // MARK: - Keys

    /// Return asks. After the arrow keys moved onto a match it opens that
    /// match instead.
    private func submitQuery() {
        switch AskReturnAction.resolve(query: query, resultCount: matches.count,
                                       pickedWithKeyboard: cursor.isInMatches) {
        case .ask: askAboutResults()
        case .openResult: openSelectedResult()
        case .none: break
        }
    }

    private func moveCursor(_ direction: AskMatchCursor.Direction) -> KeyPress.Result {
        guard phase.isTyping, !matches.isEmpty else { return .ignored }
        var next = cursor
        guard next.move(direction, count: matches.count) else { return .ignored }
        if trayCollapsed { trayCollapsed = false }
        cursor = next
        pendingQuestion = nil
        return .handled
    }

    /// Escape first returns the keyboard to the field, then folds the tray.
    private func leaveMatches() -> KeyPress.Result {
        if cursor.isInMatches {
            cursor.returnToField()
            return .handled
        }
        guard phase.matchesPlacement == .trayAboveField, !matches.isEmpty, !trayCollapsed else { return .ignored }
        trayCollapsed = true
        return .handled
    }

    private func scrollToCursor(_ proxy: ScrollViewProxy) {
        guard let index = cursor.index else { return }
        proxy.scrollTo(AskMatchesList.rowID(index))
    }

    private func openSelectedResult() {
        guard let index = cursor.index, let row = matches.row(at: index) else { return }
        switch row {
        case .meeting(let group): app.openSearchHit(group.primary)
        case .screen(let group): app.openScreenSnapshot(group.primary.snapshotID)
        case .file(let hit): FileSearchOpener.open(hit, query: searchedQuery)
        case .agentNote(let hit): AgentNoteOpener.open(hit)
        }
    }

    // MARK: - Field

    private var composerPanel: some View {
        let canSubmit = !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !model.isResponding
        let placeholder: LocalizedStringKey = phase.page == .newQuestion
            ? "Ask a question, or type a word to find it" : "Ask a follow-up"

        return VStack(alignment: .leading, spacing: 10) {
            TextField(placeholder, text: queryBinding, axis: .vertical)
                .textFieldStyle(.plain)
                .font(AppFont.scaledSystem(size: 14))
                .lineLimit(1...4)
                .frame(minWidth: 60, maxWidth: .infinity, alignment: .topLeading)
                .focused($inputFocused)
                .onSubmit { submitQuery() }
                .accessibilityLabel("Question or search")
                .accessibilityHint("Return asks. Down Arrow moves into the matches.")
                .accessibilityIdentifier("search.field")
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    scopeControls
                    Spacer(minLength: 4)
                    sendControl(canSubmit: canSubmit)
                }
                VStack(alignment: .leading, spacing: 8) {
                    scopeControls
                    HStack { Spacer(); sendControl(canSubmit: canSubmit) }
                }
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 12)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .composerChrome(focused: inputFocused)
    }

    /// Ask, disabled while the field is empty. While an answer is being
    /// written the same place holds Stop.
    @ViewBuilder private func sendControl(canSubmit: Bool) -> some View {
        if model.isResponding {
            Button(action: model.stop) {
                Label("Stop", systemImage: "stop.fill")
                    .font(.scaledSystem(size: 13, weight: .semibold))
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .keyboardShortcut(.cancelAction)
            .help("Stop answering (Esc)")
            .accessibilityLabel("Stop answering")
            .accessibilityIdentifier("chat.stop")
        } else {
            Button(action: askAboutResults) {
                Label("Ask", systemImage: "arrow.up")
                    .font(.scaledSystem(size: 13, weight: .semibold))
            }
            .primaryActionButton()
            .controlSize(.large)
            .disabled(!canSubmit || pendingQuestion != nil)
            .accessibilityIdentifier("ask.submit")
        }
    }

    /// The screen moments a keyword's answer reads: the listed sessions and
    /// any attached screen.
    private var answerScreenIDs: Set<Int64> {
        matches.screenIDs.union(pinnedScreens.map(\.snapshotID))
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
        // A full question reads everything in the chosen sources and dates,
        // so the sources menu keeps saying what was chosen. A keyword is a
        // search being asked about: its answer is limited to the listed
        // matches, and the menu then names that limit. A "Remember …"
        // statement is saved as is and limits nothing. Scope set on purpose
        // before this (a handed-over meeting, an attached screen, the menu's
        // "Only …" state) stays in `recall.state` either way.
        let remembers = app.settings.askMemoryEnabled && RememberIntent.parse(query) != nil
        let scope = AskAnswerScope.resolve(query: query, hasMatches: !matches.isEmpty,
                                           isRememberStatement: remembers)
        if scope == .listedMatches {
            recall.state.selectResultEvidence(
                meetingIDs: Set(matches.meetings.map(\.id)),
                screenIDs: answerScreenIDs,
                hadFiles: !matches.files.isEmpty, hadAgentNotes: !matches.agentNotes.isEmpty)
        }
        escalate()
    }

    // MARK: - Scope: the two menus

    private var filesEnabled: Bool { app.settings.fileSearchEnabled }
    private var agentNotesEnabled: Bool { app.settings.codingAgentNotesEnabled }
    private var availableSources: [AskSourceScope] {
        AskSourceScope.available(filesEnabled: filesEnabled, agentNotesEnabled: agentNotesEnabled)
    }

    private var scopeControls: some View {
        HStack(spacing: 8) {
            sourcesMenu
            timeMenu
        }
    }

    private var scopeSummary: AskScopeSummary {
        AskScopeSummary.make(
            .init(sources: sources, available: availableSources,
                  meetingIDs: meetingScope, screenIDs: screenScope,
                  sourcesBeforeEvidence: recall.state.sourcesBeforeEvidence,
                  facet: facet, screenApp: selectedScreenApp),
            meetingTitle: { id in app.meetings.first { $0.id == id }?.displayTitle },
            localize: localized)
    }

    /// Sources, their finer filters and the way to source permissions. When
    /// the question is limited to earlier matches or to evidence another page
    /// handed over, the button names that limit and the menu offers to widen it.
    private var sourcesMenu: some View {
        let summary = scopeSummary
        return WorkspaceMenu(title: summary.title, label: localized("Sources"), identifier: "ask.sources",
                             items: sourceMenuItems(summary), font: .systemFont(ofSize: 13))
            .fixedSize()
            .modifier(AskMenuChrome(highlighted: summary.isNarrowed || summary.hasFilters))
            .help("Choose sources and result filters")
    }

    private func sourceMenuItems(_ summary: AskScopeSummary) -> [WorkspaceMenu.Item] {
        var items: [WorkspaceMenu.Item] = []
        if summary.isNarrowed, let narrowedTo = summary.narrowedTo, let widenTitle = summary.widenTitle {
            items += [
                .init(title: String(format: localized("Only %@"), narrowedTo),
                      identifier: "ask.sources.narrowed", selected: true),
                .init(title: widenTitle, identifier: "ask.sources.widen", action: widenSources),
                .separator,
            ]
        }
        let selectedAvailable = availableSources.filter(sources.contains)
        items += availableSources.map { source in
            WorkspaceMenu.Item(title: localized(source.displayName),
                enabled: !((sources.contains(source) && selectedAvailable.count == 1)
                           || (source == .screen && !pinnedScreens.isEmpty)),
                selected: sources.contains(source), action: { toggleSource(source) })
        }
        items += [.separator, .init(title: localized("Match type"), children: AskFacet.allCases.filter {
            ($0 != .files || filesEnabled) && ($0 != .agentNotes || agentNotesEnabled)
        }.map { option in
            .init(title: localized(option.rawValue), selected: facet == option, action: { facet = option })
        })]
        if sources.contains(.screen) {
            items.append(.init(title: localized("Screen app"), children:
                [.init(title: localized("All apps"), selected: selectedScreenApp == nil,
                       action: { selectedScreenApp = nil })]
                + screenApps.map { name in
                    .init(title: name, selected: selectedScreenApp == name, action: { selectedScreenApp = name })
                }))
        }
        items += [.separator, .init(title: localized("Source permissions…"),
                                    action: { app.openSettings(tab: .ask) })]
        return items
    }

    /// Lift the limit to particular meetings and screen moments, back to the
    /// sources that were chosen before it.
    private func widenSources() {
        clearPinnedScreens(restoringScope: true)
        recall.state.clearEvidence()
        runSearch()
    }

    private var hasSearchFilters: Bool {
        app.askDateScope != nil || facet != .all || selectedScreenApp != nil
    }

    private func clearSearchFilters() {
        facet = .all
        selectedScreenApp = nil
        app.askDateScope = nil
    }

    private func toggleSource(_ source: AskSourceScope) {
        var selection = sources
        if selection.contains(source) {
            // A source that is not offered (Files while it is off) never counts as the last one.
            if selection.intersection(availableSources).count > 1 { selection.remove(source) }
        } else {
            selection.insert(source)
        }
        recall.state.chooseSources(selection)
        if !selection.contains(.screen) { selectedScreenApp = nil }
    }

    /// One date scope for search and answers across every source.
    private var timeMenu: some View {
        WorkspaceMenu(title: timeScopeLabel, label: localized("Date"), identifier: "ask.timeScope",
                      items: timeMenuItems, font: .systemFont(ofSize: 13))
            .fixedSize()
            .modifier(AskMenuChrome(highlighted: app.askDateScope != nil))
            .popover(isPresented: $choosingDate, arrowEdge: .bottom) { datePopover }
            .help("One date scope for meeting, activity, and screen search and answers")
    }

    private var timeMenuItems: [WorkspaceMenu.Item] {
        let presets: [(title: String, scope: AskDateScope?, identifier: String)] = [
            ("Any time", nil, "any"),
            ("Today", AskDateScope(day: Date()), "today"),
            ("Yesterday", Calendar.current.date(byAdding: .day, value: -1, to: Date()).map { AskDateScope(day: $0) },
             "yesterday"),
            ("Last 7 days", AskDateScope.lastSevenDays(), "sevenDays"),
        ]
        var items = presets.map { preset in
            WorkspaceMenu.Item(title: localized(preset.title), identifier: "ask.timeScope.\(preset.identifier)",
                               selected: app.askDateScope == preset.scope,
                               action: { app.askDateScope = preset.scope })
        }
        if let scope = app.askDateScope, !presets.contains(where: { $0.scope == scope }) {
            items.append(.init(title: scope.label(), identifier: "ask.timeScope.custom", selected: true))
        }
        items += [.separator, .init(title: localized("Choose a date…"), identifier: "ask.timeScope.choose",
                                    action: { choosingDate = true })]
        return items
    }

    private var datePopover: some View {
        HStack {
            DatePicker("Specific date", selection: scopedDate, displayedComponents: .date)
                .datePickerStyle(.compact)
                .accessibilityIdentifier("ask.timeScope.date")
            Button("Use date") {
                app.askDateScope = AskDateScope(day: scopedDate.wrappedValue)
                choosingDate = false
            }
            .accessibilityIdentifier("ask.timeScope.useDate")
        }
        .padding(16)
    }

    private var scopedDate: Binding<Date> {
        Binding(
            get: { app.askDateScope.flatMap { AskDayScope.date(for: $0.firstDay) } ?? Date() },
            set: { app.askDateScope = AskDateScope(day: $0) })
    }

    private var timeScopeLabel: String { localized(app.askDateScope?.label() ?? "Any time") }

    /// Shown only when it changes where the question goes: a remote model,
    /// or a model connection that is blocked.
    @ViewBuilder private var inferenceStatus: some View {
        let state = InferencePresentation(settings: app.settings)
        if state.isRemote || state.isBlocked {
            let label = remoteOrBlockedLabel(state)
            let help = state.detail(local: "Answers and selected evidence are processed on this Mac.",
                                    remote: "Answers send your question and selected evidence to the configured server.")
            Button {
                app.openSettings(tab: .models)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: state.icon)
                        .accessibilityHidden(true)
                    Text(verbatim: label)
                }
                .font(AppFont.scaled(.callout))
                .foregroundStyle(state.isBlocked ? AnyShapeStyle(LBTokens.Palette.attentionText)
                                                 : AnyShapeStyle(.secondary))
                .frame(minHeight: 22)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .fixedSize()
            .padding(.leading, 6)
            .help("\(help) Open model settings.")
            .accessibilityLabel(Text(verbatim: "\(label). \(help)"))
            .accessibilityHint("Opens model settings")
            .accessibilityIdentifier("ask.inferenceStatus")
        }
    }

    private func remoteOrBlockedLabel(_ state: InferencePresentation) -> String {
        switch state {
        case .remote(let host): String(format: localized("Remote · %@"), host)
        case .blocked: localized("Model connection blocked")
        case .onDevice: ""
        }
    }

    private var pinnedContextRow: some View {
        HStack(spacing: 8) {
            Label("Context", systemImage: "pin.fill")
                .font(AppFont.scaled(.callout).weight(.semibold))
                .foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(pinnedScreens) { context in
                        HStack(spacing: 6) {
                            ScreenThumbnailView(snapshotID: context.snapshotID, height: 34)
                                .frame(width: 54)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(context.app).font(AppFont.scaled(.callout).weight(.semibold)).lineLimit(1)
                                Text(context.timestamp.formatted(date: .omitted, time: .shortened))
                                    .font(AppFont.scaled(.callout).monospacedDigit())
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
                .font(AppFont.scaled(.callout))
                .foregroundStyle(.secondary)
        }
        .accessibilityIdentifier("ask.screen.context")
    }

    // MARK: - Asking

    /// Hand the question to the assistant. The send appends messages, which
    /// turns the page into the conversation; clearing the field folds the
    /// matches away. A day scope from Capture is prepended so the agent
    /// reaches for its activity-summary tool with the right date.
    private func escalate() {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !model.isResponding else { return }
        let dateScope = app.askDateScope
        let contextualQuestion = ScreenAskContext.prompt(question: q, contexts: pinnedScreens)
        let prompt = dateScope.map { "About my work on \($0.dateLabel): \(contextualQuestion)" } ?? contextualQuestion
        app.askMode = .ask
        model.send(
            prompt,
            displayText: q,
            sourceScopes: sources,
            dateScope: dateScope,
            attachedScreenDates: pinnedScreens.map(\.timestamp),
            attachedScreenIDs: Set(pinnedScreens.map(\.snapshotID)),
            meetingIDs: meetingScope, screenSnapshotIDs: screenScope)
        clearPinnedScreens(restoringScope: false)
        query = ""
    }

    private func openSelectedConversation() {
        pendingQuestion = nil
        query = ""
        app.askMode = .ask
        if model.messages.isEmpty { resetAskScope() } else { restoreAskScope() }
        inputFocused = true
    }

    private func resetAskScope() {
        recall.state.clearEvidence()
        recall.state.chooseSources(AskSourceScope.defaults)
        app.askDateScope = nil
        pinnedScreens = []
        choosingDate = false
    }

    private func restoreAskScope() {
        guard let scope = model.currentQuestionScope else {
            resetAskScope()
            return
        }
        recall.state.selectEvidence(meetingIDs: scope.meetingIDs, screenIDs: scope.screenSnapshotIDs,
                                       sources: scope.sources)
        app.askDateScope = scope.dayScopeKey.flatMap { AskDateScope(storageKey: $0) }
        pinnedScreens = []
        choosingDate = false
    }

    private func reconcilePinnedScreenScope() {
        recall.state.reconcilePins(dateScope: app.askDateScope)
    }

    private func rememberScreenAccessBeforePinning() {
        recall.state.beginPinning()
    }

    private func removePinnedScreen(_ id: Int64) {
        recall.state.removePin(id)
    }

    private func clearPinnedScreens(restoringScope: Bool) {
        recall.state.clearPins(restoringScope: restoringScope)
    }

    private func restoreScopeAfterRemovingPins() {
        recall.state.clearPins(restoringScope: true)
    }

    // MARK: - Matches

    private var matchesList: AskMatchesList {
        AskMatchesList(matches: matches, query: searchedQuery,
                       style: phase.matchesPlacement == .trayAboveField ? .tray : .card,
                       selected: cursor.index,
                       pinnedScreenIDs: Set(pinnedScreens.map(\.snapshotID)),
                       togglePin: togglePinned,
                       expandedRows: $expandedMatches)
    }

    private func matchesHeader(hints: [AskMatchesHeader.KeyHint]) -> AskMatchesHeader {
        AskMatchesHeader(countLabel: matches.isEmpty ? nil : matches.countLabel(localize: localized),
                         isSearching: isSearching, isWaitingToAsk: pendingQuestion != nil,
                         hints: matches.isEmpty ? [] : hints)
    }

    /// A new question: the matches sit under the field.
    private var matchesUnderField: some View {
        VStack(alignment: .leading, spacing: 8) {
            matchesHeader(hints: [.init(key: "↓", action: "to open"), .init(key: "↩", action: "to ask")])
                .padding(.horizontal, 4)
            if !matches.isEmpty {
                matchesList.askCard()
            } else if !isSearching {
                noMatches
            }
        }
        .padding(.top, 20)
    }

    private var noMatches: some View {
        VStack(alignment: .leading, spacing: 8) {
            Group {
                if availableSources.filter(sources.contains) == [.today] {
                    Text("Activity totals are available in Ask. Enable Meetings or Screen to search source text.")
                } else {
                    Text("No matches for “\(query.trimmingCharacters(in: .whitespacesAndNewlines))”.")
                }
            }
            .font(AppFont.scaled(.callout))
            .workspaceSupportingForeground()
            .fixedSize(horizontal: false, vertical: true)
            if hasSearchFilters {
                Button("Clear search filters", action: clearSearchFilters)
                    .buttonStyle(.workspaceLink)
                    .font(AppFont.scaled(.callout))
                    .accessibilityIdentifier("ask.filters.clear")
            }
        }
        .padding(.horizontal, 4)
        .accessibilityIdentifier("ask.matches.none")
    }

    /// Inside a conversation: the matches rise above the docked field and
    /// the thread stays where it is. Nothing to list means no tray.
    @ViewBuilder private var matchesTray: some View {
        if phase.matchesPlacement == .trayAboveField, isSearching || !matches.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    matchesHeader(hints: trayCollapsed
                        ? [.init(key: "↓", action: "to open"), .init(key: "↩", action: "to ask")]
                        : [.init(key: "↓", action: "to open"), .init(key: "↩", action: "to ask"),
                           .init(key: "esc", action: "to hide")])
                    if !matches.isEmpty {
                        Button { trayCollapsed.toggle() } label: {
                            Image(systemName: trayCollapsed ? "chevron.up" : "chevron.down")
                                .font(.system(size: 10, weight: .semibold))
                                .frame(width: 20, height: 18)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(trayCollapsed ? "Expand" : "Collapse")
                        .accessibilityIdentifier("ask.matches.tray.toggle")
                    }
                }
                .padding(.horizontal, 10)
                if !trayCollapsed, !matches.isEmpty {
                    ViewThatFits(in: .vertical) {
                        matchesList
                        ScrollViewReader { proxy in
                            ScrollView { matchesList }
                                .onChange(of: cursor) { scrollToCursor(proxy) }
                        }
                    }
                    .frame(maxHeight: 320)
                }
            }
            .padding(.top, 12)
            .padding(.bottom, trayCollapsed || matches.isEmpty ? 12 : 6)
            .padding(.horizontal, 8)
            .modifier(AskTrayChrome())
            .padding(.horizontal, WorkspaceMetric.pagePadding)
            .workspaceReadingWidth()
            .frame(maxWidth: .infinity)
            .padding(.bottom, 2)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("ask.matches.tray")
        }
    }

    private func runSearch(cancelPendingQuestion: Bool = true) {
        if cancelPendingQuestion { pendingQuestion = nil }
        searchTask?.cancel()
        let q = query, request = recall.state, dateScope = app.askDateScope
        searchedQuery = q
        // Never leave rows from a previous query available to Return.
        matches = AskMatches()
        expandedMatches = []
        cursor.returnToField()
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
        matches = AskMatches(result)
        let apps = result.screens.flatMap(\.matches).map(\.app) + [selectedScreenApp].compactMap { $0 }
        screenApps = Array(Set(apps)).sorted()
        cursor.clamp(count: matches.count)
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

    // MARK: - An empty page

    /// Questions about the person's own latest meeting, a colleague and a
    /// project, read from what is already loaded, then one word to search.
    private var suggestions: [AskSuggestion] {
        let latest = app.meetings
            .filter { $0.isOwnWork && $0.endedAt != nil }
            .max { $0.startedAt < $1.startedAt }
        let projects = app.connections.projects
        return AskSuggestions.build(
            .init(latestMeetingTitle: latest?.displayTitle,
                  personName: app.connections.people.first?.name,
                  projectName: (projects.first(where: \.isTracked) ?? projects.first)?.name),
            fallback: model.suggestions,
            localize: localized)
    }

    private var suggestionList: some View {
        let all = suggestions
        return VStack(alignment: .leading, spacing: 1) {
            ForEach(all.filter { $0.kind != .keyword }) { suggestion in
                suggestionRow(suggestion, hint: nil) { sendSuggestion(suggestion.text) }
            }
            if let word = all.first(where: { $0.kind == .keyword }) {
                Divider().padding(.top, 6).padding(.bottom, 5)
                suggestionRow(word, hint: "Type a word to see where it came up") {
                    query = word.text
                    inputFocused = true
                }
            }
        }
        .padding(.top, 14)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.empty")
    }

    private func suggestionRow(_ suggestion: AskSuggestion, hint: LocalizedStringKey?,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Image(systemName: suggestion.symbol)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(LBTokens.Palette.accentText)
                    .frame(width: 18)
                    .accessibilityHidden(true)
                Text(verbatim: suggestion.text)
                    .font(AppFont.scaledSystem(size: 13.5))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                if let hint {
                    Text(hint)
                        .font(AppFont.scaled(.callout))
                        .workspaceSupportingForeground()
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 34)
            .contentShape(Rectangle())
        }
        .buttonStyle(AskLineButtonStyle(cornerRadius: 8))
        .accessibilityIdentifier("ask.suggestion.\(suggestion.kind)")
    }

    private func sendSuggestion(_ suggestion: String) {
        query = suggestion
        escalate()
    }
}

/// The bordered look of the composer's two menus. A menu that limits the
/// question (to earlier matches, a filter, or dates) is tinted.
private struct AskMenuChrome: ViewModifier {
    @Environment(\.colorSchemeContrast) private var contrast
    let highlighted: Bool

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        content
            .padding(.leading, 3)
            .background(highlighted ? AnyShapeStyle(LBTokens.Palette.accentFill.opacity(0.10))
                                    : AnyShapeStyle(Color(nsColor: .controlBackgroundColor)), in: shape)
            .overlay {
                shape.strokeBorder(highlighted ? LBTokens.Palette.accentFill.opacity(contrast == .increased ? 1 : 0.35)
                                               : Color.primary.opacity(contrast == .increased ? 0.5 : 0.14))
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
    }
}

/// The raised panel the matches tray sits on.
private struct AskTrayChrome: ViewModifier {
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        content
            .background(Color(nsColor: .controlBackgroundColor), in: shape)
            .overlay {
                shape.strokeBorder(Color.primary.opacity(contrast == .increased ? 0.5 : 0.14))
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .shadow(color: .black.opacity(0.14), radius: 16, y: 6)
    }
}
