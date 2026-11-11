import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers

/// Meetings inspector router. A completed selection opens the full workspace;
/// an active recording keeps its dedicated live surface.
struct MeetingLibraryDetailView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var pendingDelete: Set<Meeting.ID>?
    @State private var prepared: PreparedMeeting?
    @State private var selectionRequest: SelectionRequest?

    private struct SelectionRequest: Equatable {
        let meetingID: Meeting.ID?
        let animate: Bool
    }

    private struct PreparedMeeting {
        let meeting: Meeting
        let document: MeetingDocumentSnapshot
    }

    private var completedMeetingID: Meeting.ID? {
        guard let meeting = app.selectedMeeting, meeting.endedAt != nil else { return nil }
        return meeting.id
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                selectionContent
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
        .onChange(of: completedMeetingID, initial: true) {
            // Bind input intent to the load request so the async task cannot
            // capture the previous selection's animation policy.
            let event = NSApp.currentEvent?.type
            selectionRequest = SelectionRequest(meetingID: completedMeetingID,
                animate: prepared != nil && (event == .leftMouseDown || event == .leftMouseUp))
        }
        .task(id: selectionRequest) {
            guard let selectionRequest else { return }
            guard let meeting = app.selectedMeeting, meeting.endedAt != nil,
                  selectionRequest.meetingID == meeting.id else {
                prepared = nil
                return
            }
            guard prepared?.meeting.id != meeting.id else { return }
#if LOKALBOT_UI_TEST_HOST
            if ProcessInfo.processInfo.environment["LOKALBOT_SLOW_MEETING_LOAD"] == "1" {
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { return }
            }
#endif
            let root = app.storage.rootURL, template = app.settings.noteTemplate
            let databaseURL = app.activityStore.databaseURL
            let worker = Task.detached(priority: .userInitiated) {
                MeetingDocumentSnapshot.load(meeting: meeting, root: root, template: template, databaseURL: databaseURL)
            }
            let document = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            guard !Task.isCancelled else { return }
            await app.outcomeIndex.refreshInBackground(meeting: meeting)
            guard !Task.isCancelled, completedMeetingID == meeting.id else { return }
            uiTestDiagnosticLog("Prepared meeting presentation: pointer=\(selectionRequest.animate), reduceMotion=\(reduceMotion)")
            withAnimation(selectionRequest.animate ? WorkspaceMotion.animation(.selection, reduceMotion: reduceMotion) : nil) {
                prepared = PreparedMeeting(meeting: meeting, document: document)
            }
        }
    }

    @ViewBuilder private var selectionContent: some View {
        if app.selectedMeetingIDs.count > 1 {
            ContentUnavailableView {
                Label("\(app.selectedMeetingIDs.count) meetings selected", systemImage: "checklist")
            } description: {
                Text("Press Delete or use the list menu to remove them.")
            } actions: {
                Button("Delete \(app.selectedMeetingIDs.count) meetings", role: .destructive) {
                    pendingDelete = app.selectedMeetingIDs
                }
                .accessibilityIdentifier("meeting.multiSelect.delete")
            }
        } else if let meeting = app.selectedMeeting {
            if meeting.endedAt == nil {
                LiveMeetingDetailView(meeting: meeting, transcriber: app.liveTranscriber).id(meeting.id)
            } else if let prepared {
                let changing = prepared.meeting.id != meeting.id
                MeetingWorkspaceDetail(meeting: changing ? prepared.meeting : meeting, document: prepared.document)
                    .id(prepared.meeting.id)
                    .transition(.opacity)
                    .disabled(changing)
                    .overlay(alignment: .topTrailing) {
                        if changing {
                            ProgressView().controlSize(.small).padding(16)
                                .accessibilityLabel("Loading selected meeting")
                                .accessibilityIdentifier("meeting.selection.loading")
                        }
                    }
            } else {
                ProgressView("Loading meeting…")
                    .accessibilityIdentifier("meeting.selection.loading")
            }
        } else if !app.libraryReady {
            ProgressView("Loading your meeting library...")
        } else {
            ContentUnavailableView(
                "No meeting selected",
                systemImage: "waveform.circle",
                description: Text("Select a meeting to review its outcomes and evidence."))
        }
    }
}

private struct MeetingWorkspaceDetail: View {
    @EnvironmentObject var app: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let meeting: Meeting

    @StateObject private var player = MeetingPlayer()
    @State private var loadRevision = 0
    @State private var documentLoading = true
    @State private var captureNeedsAttention = false
    @State private var recoveryNeedsAttention = false
    // Begin with the narrow controls until the detail column is measured so
    // the toolbar cannot enlarge a compact window during its first layout.
    @State private var compactToolbar = true
    @State private var summary: String?
    @State private var partialNotes: MeetingNotesPartial?
    @State private var partialProjection: MeetingOutcomeProjection?
    @State private var notes: String?
    @State private var transcript: Transcript?
    @State private var transcriptDisplay = Transcript.DisplayIndex()
    @State private var speakerPresentation = MeetingSpeakerPresentation(transcript: nil)
    @State private var fullNotesExpanded = false
    @State private var evidenceSegment: Int?
    @State private var evidenceRevision = 0
    @State private var correction: ActionCorrectionDraft?
    @State private var correctionError: String?
    @State private var reviewSpeakers: [MeetingSpeakerReviewItem] = []
    @State private var previousReviewProjection: MeetingOutcomeProjection?
    @State private var reviewLoadTask: Task<Void, Never>?
    @State private var correctionReloadTask: Task<Void, Never>?
    @State private var attributionNeedsRefresh = false
    @State private var namingSpeakers = false
    /// A named speaker picked from the naming sheet, renamed once it closes.
    @State private var pendingRenameSpeaker: String?
    @State private var derived = MeetingTranscriptDerived()
    @State private var speakerRenameDraft: WorkspaceSpeakerRenameDraft?
    @State private var speakerIdentityState: MeetingSpeakerIdentityState?
    @State private var speakerIdentityNotice: String?
    @State private var savingSpeakerIdentity = false
    @State private var speakerSummaryNeedsRefresh = false
    @State private var speakerNameHints: [String] = []
    @State private var calendarSpeakerCandidates: [CalendarParticipantIdentity] = []
    @State private var exportError: String?
    @State private var editingBoundaries = false
    @State private var undoMergeConfirmation = false
    @State private var speechError: String?
    @State private var isExportingAudio = false
    @State private var isExportingSpeech = false
    @State private var isReadingSummary = false
    @State private var speechPlayer: AVAudioPlayer?
    @State private var speechTask: Task<Void, Never>?
    @State private var speechSessionID: UUID?
    @State private var searchQuery = ""
    @State private var screenContext = MeetingScreenContext()
    @State private var radar: MeetingRadarRecord?
    private var tab: MeetingWorkspaceTab {
        get { app.meetingWorkspaceTabs[meeting.id] ?? .summary }
        nonmutating set { app.meetingWorkspaceTabs[meeting.id] = newValue }
    }
    @State private var searchMatches: [MeetingPageSearchMatch] = []
    @State private var selectedSearchMatchIndex = 0
    @State private var searchContentRevision = 0

    init(meeting: Meeting, document: MeetingDocumentSnapshot) {
        self.meeting = meeting
        _notes = State(initialValue: document.notes)
        _transcript = State(initialValue: document.transcript)
        _transcriptDisplay = State(initialValue: document.transcriptDisplay)
        _speakerPresentation = State(initialValue: document.speakerPresentation)
        _reviewSpeakers = State(initialValue: MeetingSpeakerReviewItem.items(in: document.transcript))
        _summary = State(initialValue: document.summary)
        _partialNotes = State(initialValue: document.partialNotes)
        _partialProjection = State(initialValue: document.partialProjection)
        _speakerNameHints = State(initialValue: document.speakerNameHints)
        _calendarSpeakerCandidates = State(initialValue: meeting.resolvedCalendarParticipantIdentities)
        _attributionNeedsRefresh = State(initialValue: document.attributionNeedsRefresh)
        _captureNeedsAttention = State(initialValue: document.captureNeedsAttention)
        _recoveryNeedsAttention = State(initialValue: document.recoveryNeedsAttention)
        _screenContext = State(initialValue: document.screenContext)
        _radar = State(initialValue: document.radar)
        _derived = State(initialValue: MeetingTranscriptDerived(
            transcript: document.transcript, display: document.transcriptDisplay,
            presentation: document.speakerPresentation))
    }

    private var folder: URL { meeting.folderURL(in: app.storage) }
    private var presentedSummary: String? {
        summary.map { speakerPresentation.text(SummaryPresentation.meetingBody($0, meeting: meeting)) }
    }
    private var projection: MeetingOutcomeProjection? { partialProjection ?? app.outcomeIndex.projection(for: meeting.id) }
    /// What the summary shows. After speaker names change, the notes written
    /// before the change stay readable until a refresh replaces them.
    private var shownProjection: MeetingOutcomeProjection? { projection ?? previousReviewProjection }
    private var hasSummaryContent: Bool { summary?.isEmpty == false || shownProjection != nil }
    private var isProcessing: Bool { app.pipeline.stages[meeting.id].map { !$0.isFailure } ?? false }
    private var captureTranscriptOnly: Bool {
#if LOKALBOT_UI_TEST_HOST
        ProcessInfo.processInfo.environment["LOKALBOT_DETAIL_TAB"] == "transcript"
#else
        false
#endif
    }

    var body: some View {
        ScrollViewReader { scrollProxy in
            VStack(spacing: 0) {
                // The title, who spoke and the player stay put on every tab;
                // only the tab's content scrolls beneath them.
                VStack(alignment: .leading, spacing: 14) {
                    MeetingDetailHeader(
                        meeting: meeting,
                        speakers: derived.speakers,
                        searchQuery: visibleSearchQuery,
                        activeMatch: activeSearchMatch,
                        canNameSpeakers: !savingSpeakerIdentity,
                        onSpeaker: { speaker in
                            if speaker.needsName {
                                namingSpeakers = true
                            } else {
                                beginRenameSpeaker(speaker.id)
                            }
                        },
                        onNameSpeakers: { namingSpeakers = true })
                    playerBar
                    if isSearchPresented || tab == .transcript {
                        MeetingPageSearchBar(
                            query: $searchQuery,
                            focusRequest: app.meetingPageSearchRequestRevision,
                            statusText: searchStatusText,
                            hasMatches: !searchMatches.isEmpty,
                            onPrevious: { moveSearch(by: -1, using: scrollProxy) },
                            onNext: { moveSearch(by: 1, using: scrollProxy) },
                            onClose: dismissSearch,
                            isPresented: isSearchPresented)
                    }
                }
                .frame(maxWidth: MeetingDetailMetric.columnMaxWidth, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, WorkspaceMetric.pagePadding)
                .padding(.top, 14)
                .padding(.bottom, 12)
                ScrollView {
                    VStack(alignment: .leading, spacing: WorkspaceMetric.sectionGap) {
                        meetingStatusContent
                        switch tab {
                        case .summary: summaryTabContent
                        case .transcript: transcriptSection
                        case .notes:
                            MeetingNotesEditor(meeting: meeting, searchQuery: visibleSearchQuery, activeMatchIndex: activeOccurrence(at: .notes)) {
                                notes = $0
                                searchContentRevision += 1
                            }
                        }
                    }
                    .frame(maxWidth: MeetingDetailMetric.columnMaxWidth, alignment: .leading)
                    .padding(.horizontal, WorkspaceMetric.pagePadding)
                    .padding(.top, 4)
                    .padding(.bottom, WorkspaceMetric.pagePadding)
                    .frame(maxWidth: .infinity, alignment: .top)
                }
                .accessibilityIdentifier("meeting.content.scroll")
                .accessibilityLabel("Meeting content")
            }
            .onChange(of: evidenceRevision) {
                guard let index = evidenceSegment else { return }
                DispatchQueue.main.async {
                    scrollProxy.scrollTo(MeetingPageSearchMatch.Location.transcript(
                        segmentIndex: index, field: .text), anchor: .center)
                }
            }
            .onChange(of: tab) { previous, current in
                if previous == .transcript, current != .transcript, !isSearchPresented { dismissSearch() }
            }
            .onChange(of: isSearchPresented) { updateSearch(using: scrollProxy, revealFirst: false) }
            .onChange(of: searchQuery) {
                updateSearch(using: scrollProxy)
            }
            .onChange(of: searchContentRevision) {
                if isSearchPresented || tab == .transcript {
                    updateSearch(using: scrollProxy, revealFirst: false)
                }
            }
            .onChange(of: projection) {
                reloadReviewProjection()
                if isSearchPresented || tab == .transcript {
                    updateSearch(using: scrollProxy, revealFirst: false)
                }
            }
        }
        .navigationTitle("Meetings")
        // The header inside the page carries the meeting's one title.
        .toolbar(removing: .title)
        .task(id: loadRevision) {
#if LOKALBOT_UI_TEST_HOST
            // Establish the requested capture route before asynchronous document
            // and speaker recovery; readiness must not race those operations.
            if ProcessInfo.processInfo.environment["LOKALBOT_DETAIL_TAB"] == "transcript" {
                tab = .transcript
            } else if ProcessInfo.processInfo.environment["LOKALBOT_DETAIL_TAB"] == "review", loadRevision == 0 {
                // The Review tab's work now happens in the naming sheet.
                namingSpeakers = !derived.unnamed.isEmpty
            }
#endif
            await load()
            guard !Task.isCancelled else { return }
            await refreshSpeakerIdentity(recover: true)
        }
        .onChange(of: app.pipeline.stages[meeting.id]) { _, stage in
            if stage == nil || stage == .summarizing || stage == .waitingForModels || stage?.isFailure == true {
                loadRevision &+= 1
            }
        }
        .onChange(of: app.navigationHandoff.revision) { consumeMeetingSeek() }
        .onChange(of: app.selectedMeetingIDs) {
            if app.selectedMeeting?.id != meeting.id {
                player.pause()
                stopSpeech(clearError: false)
            }
        }
        .onChange(of: app.meetingPageSearchRequestRevision) {
            guard app.presentedMeetingSearchID == meeting.id else { return }
            uiTestDiagnosticLog(
                "meeting.search receive revision="
                    + "\(app.meetingPageSearchRequestRevision) id=\(meeting.id)")
        }
        .sheet(item: $correction) { draft in
            ActionCorrectionSheet(
                draft: draft,
                ownerSuggestions: MeetingSpeakerReviewItem.ownerSuggestions(from: reviewSpeakers),
                error: correctionError
            ) { text, owner, due in
                let saved = app.outcomeIndex.correctAction(
                    actionID: draft.actionID,
                    meetingID: meeting.id,
                    text: text == draft.originalText ? nil : text,
                    owner: owner,
                    due: due,
                    reviewing: projection == nil ? meeting : nil)
                if saved {
                    reloadReviewProjection()
                    // The correction also re-rendered the summary's action list.
                    correctionReloadTask?.cancel()
                    correctionReloadTask = Task { await reloadDocument() }
                    correction = nil
                    correctionError = nil
                } else {
                    correctionError = app.outcomeIndex.lastError ?? "The correction could not be saved. Please try again."
                }
            } onCancel: { correction = nil }
        }
        .sheet(item: $speakerRenameDraft) { draft in
            WorkspaceSpeakerRenameSheet(
                draft: draft,
                hints: speakerNameHints,
                calendarCandidates: calendarCandidates(for: draft.speaker),
                assignedCalendarIdentityIDs: assignedCalendarIdentityIDs,
                identityState: speakerIdentityState,
                notice: speakerIdentityNotice,
                busy: savingSpeakerIdentity,
                onPlay: { player.playExcerpt(from: $0.start, to: min($0.end, $0.start + 12)) },
                onPlayEvidence: { player.playExcerpt(from: $0, to: $0 + 12) },
                onAction: { action, name, profileID in
                    performSpeakerChoice(.init(label: draft.speaker, name: name,
                        action: action, profileID: profileID,
                        expectedRevision: speakerIdentityState?.revision))
                },
                onDeleteEvidence: {
                    Task {
                        do {
                            try await app.speakerIdentity.deleteEvidence(meeting: meeting)
                            await refreshSpeakerIdentity()
                        } catch { speakerIdentityNotice = error.localizedDescription }
                    }
                },
                onSave: { name, identityID, profileID in
                    saveSpeakerAlias(
                        name,
                        calendarIdentityID: identityID,
                        for: draft.speaker, profileID: profileID)
                },
                onReset: {
                    saveSpeakerAlias(
                        nil,
                        calendarIdentityID: nil,
                        for: draft.speaker)
                },
                onCancel: { speakerRenameDraft = nil })
        }
        .onDisappear {
            reviewLoadTask?.cancel()
            correctionReloadTask?.cancel()
            app.meetingPlaybackPositions[meeting.id] = player.currentTime
            app.meetingPlaybackSpeeds[meeting.id] = player.speed
            player.stop()
            stopSpeech(clearError: false)
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                contentTabPicker
                    .controlSize(compactToolbar ? .small : .regular)
            }
            ToolbarItem(placement: .navigation) {
                if let section = app.evidenceReturnSection {
                    Button(action: app.returnFromEvidence) {
                        Label(section == .actions ? "Back to Actions" : "Back", systemImage: "chevron.left")
                    }
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    app.openAsk(query: "Help me understand this meeting", meetingIDs: [meeting.id])
                } label: {
                    Label("Ask about this meeting", systemImage: "magnifyingglass")
                        .labelStyle(AskMeetingLabelStyle(compact: compactToolbar))
                }
                .help("Ask about this meeting")
                .accessibilityLabel("Ask about this meeting")
                .accessibilityIdentifier("meeting.ask")
            }
            ToolbarItem(placement: .primaryAction) {
                WorkspaceMenu(title: "Share", symbol: "square.and.arrow.up", label: "Share",
                              identifier: "meeting.export", items: shareMenuItems)
            }
            ToolbarItem(placement: .primaryAction) {
                WorkspaceMenu(title: "More meeting actions", symbol: "ellipsis",
                              identifier: "toolbar.meetingActions", items: meetingActionMenuItems)
            }
        }
        .onGeometryChange(for: Bool.self) { $0.size.width < 640 } action: { compactToolbar = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Meeting workspace")
        .accessibilityIdentifier("meeting.detail.workspace")
        .sheet(isPresented: $editingBoundaries) {
            MeetingBoundaryEditor(meeting: meeting) { try app.setMeetingBoundaries($0, for: meeting) }
        }
        .sheet(isPresented: $namingSpeakers, onDismiss: {
            guard let speaker = pendingRenameSpeaker else { return }
            pendingRenameSpeaker = nil
            beginRenameSpeaker(speaker)
        }, content: { namingSheet })
        .alert("Undo this merge?", isPresented: $undoMergeConfirmation) {
            Button("Undo merge", role: .destructive) {
                app.undoMerge(meeting)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            let count = meeting.mergedSourceMeetingIDs?.count ?? 0
            Text("Remove this merged meeting and restore \(count) original meetings? Their source folders will stay intact.")
        }
    }

    private var contentTabPicker: some View {
        ToolbarTabs(label: "Meeting content", tabs: MeetingWorkspaceTab.allCases,
                    selection: Binding(get: { tab }, set: { tab = $0 }), title: \.rawValue)
            .accessibilityIdentifier("meeting.contentTabs")
    }

    /// Everything that copies or exports the meeting.
    private var shareMenuItems: [WorkspaceMenu.Item] {
        [
            .init(title: "Copy as Markdown", action: { MeetingMarkdownActions.copy(meeting) }),
            .init(title: "Export as Markdown…", action: { exportError = MeetingMarkdownActions.export(meeting) }),
            .separator,
            .init(title: "Copy summary", enabled: summary?.isEmpty == false, action: copySummary),
            .init(title: "Copy transcript", enabled: transcript?.segments.isEmpty == false, action: copyTranscript),
            .separator,
            .init(title: isExportingAudio ? "Exporting audio…" : "Export audio…",
                  enabled: !isExportingAudio && player.isLoaded, action: exportAudio),
            .init(title: isExportingSpeech ? "Exporting spoken summary…" : "Export spoken summary…",
                  enabled: !isExportingSpeech && summary?.isEmpty == false, action: exportSpokenSummary),
            .separator,
            .init(title: "Copy meeting path", identifier: "toolbar.copyMeetingPath",
                  action: { MeetingMarkdownActions.copyText(folder.path(percentEncoded: false)) }),
        ]
    }

    private var meetingActionMenuItems: [WorkspaceMenu.Item] {
        let hasNotes = summary?.isEmpty == false || transcript?.segments.isEmpty == false
        var items: [WorkspaceMenu.Item] = [
            .init(title: "Draft follow-up…", identifier: "toolbar.followUp",
                  enabled: projection != nil && partialNotes == nil, action: { app.draftFollowUp(for: meeting) }),
            .init(title: "Hand off my actions to Agent", identifier: "toolbar.handOffActions",
                  enabled: partialNotes == nil && projection.map { !MeetingActionHandoff.actions(in: $0).isEmpty } == true,
                  action: { app.handOffActionsAndOpenAgent(of: meeting) }),
        ]
        let agents = ExternalAgentHandoff.installed
        if !agents.isEmpty {
            items.append(.init(title: "Open in", identifier: "toolbar.openIn", enabled: hasNotes, children: agents.map { target in
                .init(title: target.rawValue, identifier: "toolbar.openIn\(target.rawValue)",
                      enabled: hasNotes, action: { open(in: target) })
            }))
        }
        items += [
            .separator,
            .init(title: isReadingSummary ? "Stop spoken summary" : "Read summary aloud",
                  enabled: summary?.isEmpty == false, action: { isReadingSummary ? stopSpeech() : readSummary() }),
            .separator,
            .init(title: "Edit start and end…", identifier: "toolbar.meetingBoundaries", enabled: transcript != nil,
                  action: { editingBoundaries = true }),
            .init(title: "Reprocess", identifier: "toolbar.reprocess", children: [
                .init(title: "Transcribe & Summarize", identifier: "toolbar.transcribeAndSummarize",
                      action: { app.reprocess(meeting, transcribe: true, summarize: true) }),
                .init(title: "Transcribe only", identifier: "toolbar.transcribeOnly",
                      action: { app.reprocess(meeting, transcribe: true, summarize: false) }),
                .init(title: "Summarize again", identifier: "toolbar.resummarize",
                      action: { app.reprocess(meeting, transcribe: false, summarize: true) }),
            ]),
            .separator,
            .init(title: "Show in Finder", action: { NSWorkspace.shared.activateFileViewerSelecting([folder]) }),
        ]
        if meeting.isMergedMeeting {
            items += [.separator, .init(title: "Undo merge…", identifier: "toolbar.undoMerge",
                                       action: { undoMergeConfirmation = true })]
        }
        return items
    }

    private func open(in target: ExternalAgentHandoff) {
        exportError = target.open(prompt: ExternalAgentHandoff.prompt(for: meeting))
            ? nil : "Couldn't open \(target.rawValue)."
    }

    @ViewBuilder private var playerBar: some View {
        if player.isLoaded {
            MeetingPlayerBar(
                player: player,
                folder: folder,
                playhead: derived.playhead,
                speakerName: { key in transcript.map { speakerPresentation.speaker(key, in: $0) } ?? key },
                speakerColorIndex: { speakerPresentation.colorIndex(for: $0) },
                showsTranscriptLink: tab != .transcript,
                onShowInTranscript: showInTranscript)
        } else {
            HStack(spacing: 12) {
                Image(systemName: "play.circle.fill").font(.system(size: 28))
                Text(documentLoading ? "Loading recording…" : "No recording available")
                    .font(AppFont.scaled(.callout))
                Spacer(minLength: 0)
            }
            .foregroundStyle(.secondary)
            .frame(height: 30)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .lbGroupedSurface()
            .accessibilityIdentifier("meeting.audioPlaceholder")
        }
    }

    @ViewBuilder private var meetingStatusContent: some View {
        if meeting.isSample {
            SampleMeetingBanner(meeting: meeting,
                                hasTranscript: transcript?.segments.isEmpty == false,
                                hasNotes: summary?.isEmpty == false)
        }
        let hasOutsideAudio = meeting.additionalSavedAudioDuration > 0.1
        if captureNeedsAttention || hasOutsideAudio {
            MeetingStatusBanner(tone: .attention, symbol: "exclamationmark.triangle") {
                VStack(alignment: .leading, spacing: 2) {
                    if captureNeedsAttention {
                        Text("Audio capture was interrupted or saving reported an error. Review the saved recording for missing audio.")
                            .accessibilityIdentifier("meeting.captureWarning")
                    }
                    if hasOutsideAudio {
                        Text("Additional saved audio is outside the meeting boundaries.")
                    }
                }
            } trailing: {
                if hasOutsideAudio {
                    Button("Edit start and end…") { editingBoundaries = true }
                        .accessibilityIdentifier("meeting.reviewSavedAudio")
                }
            }
        }
        if recoveryNeedsAttention {
            MeetingStatusBanner(tone: .attention, symbol: "exclamationmark.triangle") {
                Text("Some recovery audio could not be verified. Saved audio and original checkpoints are retained.")
            }
        }
        if let stage = app.pipeline.stages[meeting.id] {
            processingStageContent(stage)
        }
        if transcript?.segments.isEmpty == true {
            Text("No speech detected. Saved audio remains available for playback and export.")
                .foregroundStyle(.secondary)
        }
        if let partialNotes {
            VStack(alignment: .leading, spacing: 3) {
                Text(partialNotes.progressLabel).font(.scaled(.caption).weight(.medium))
                    .accessibilityIdentifier("meeting.notes.partial")
                Text("Source-linked notes and actions are saved below. Actions become editable when the notes finish.")
                    .font(.scaled(.caption)).foregroundStyle(.secondary)
            }
        } else if notesNeedRefresh, tab == .summary, !isProcessing {
            summaryRefreshBanner
        }
        if let unmatched = projection?.state.unmatchedActions, !unmatched.isEmpty {
            DisclosureGroup("Review \(unmatched.count) unmatched action edits") {
                Text("These saved edits did not match a single regenerated action. Apply them to the correct action after reviewing its source.")
                    .font(.scaled(.caption)).foregroundStyle(.secondary)
                ForEach(unmatched.keys.sorted(), id: \.self) { id in
                    if let saved = unmatched[id] {
                        Text(saved.textCorrection ?? projection?.state.unmatchedActionText?[id] ?? "Previous action")
                            .textSelection(.enabled)
                        Text([saved.status.label, saved.ownerOverride, saved.dueOverride].compactMap { $0 }.joined(separator: " · "))
                            .font(.scaled(.caption)).foregroundStyle(.secondary)
                    }
                }
            }
        }
        if let speakerIdentityNotice {
            Text(speakerIdentityNotice).workspaceTextRole(.supporting)
        }
        if let exportError {
            workspaceErrorLabel(
                exportError,
                icon: "exclamationmark.triangle",
                location: .exportError)
        }
        if let speechError {
            workspaceErrorLabel(
                speechError,
                icon: "speaker.slash",
                location: .speechError)
        }
    }

    /// Offered only after speaker names changed. The summary written before
    /// the change stays on the page until the refresh finishes.
    private var summaryRefreshBanner: some View {
        let destination = InferencePresentation(settings: app.settings)
        return MeetingStatusBanner(tone: .info, symbol: "arrow.triangle.2.circlepath") {
            Text("Speaker names changed after this summary was written.")
        } trailing: {
            Group {
                if destination == .onDevice {
                    Text("Runs on this Mac")
                } else {
                    Text(verbatim: destination.label)
                }
            }
            .workspaceTextRole(destination.isBlocked ? .warning : .supporting)
            .lineLimit(1)
            .help(destination.detail(
                local: "Refreshing processes the transcript on this Mac.",
                remote: "Refreshing sends the transcript and confirmed names to your approved model server."))
            Button("Refresh summary") { app.reprocess(meeting, transcribe: false, summarize: true) }
                .disabled(transcript?.segments.isEmpty != false)
                .accessibilityIdentifier("meeting.review.refresh")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("meeting.notes.stale")
    }

    @ViewBuilder private func processingStageContent(_ stage: ProcessingPipeline.Stage) -> some View {
        let label = SearchHighlightedText(
            stage.label,
            query: visibleSearchQuery,
            activeMatchIndex: activeOccurrence(at: .processingStatus))
            .id(MeetingPageSearchMatch.Location.processingStatus)
        if stage.isFailure {
            MeetingStatusBanner(tone: .attention, symbol: "exclamationmark.triangle") {
                label.foregroundStyle(Brand.error)
            } trailing: {
                Button("Retry") { app.retryProcessing(meeting) }
                    .accessibilityIdentifier("meeting.workspace.retry")
            }
        } else if stage.isWaitingForModels {
            MeetingStatusBanner(tone: .info, symbol: "arrow.down.circle") {
                label
            } trailing: {
                Button("Download & process") { app.retryProcessing(meeting) }
                    .accessibilityIdentifier("meeting.workspace.downloadProcess")
            }
        } else {
            // With nothing written yet, say what will appear and offer the
            // transcript meanwhile. A refresh keeps the earlier summary below.
            let awaitsFirstSummary = tab == .summary && !hasSummaryContent
            MeetingStatusBanner(tone: .info, busy: true) {
                VStack(alignment: .leading, spacing: 2) {
                    label
                    if awaitsFirstSummary {
                        Text("Recap, decisions and actions appear here when it is done.")
                            .workspaceTextRole(.supporting)
                    }
                }
            } trailing: {
                if awaitsFirstSummary, transcript?.segments.isEmpty == false {
                    Button("Read the transcript") { tab = .transcript }
                        .accessibilityIdentifier("meeting.readTranscript")
                }
            }
        }
    }

    private var notesNeedRefresh: Bool {
        speakerSummaryNeedsRefresh || attributionNeedsRefresh
    }


    private func workspaceErrorLabel(
        _ text: String,
        icon: String,
        location: MeetingPageSearchMatch.Location
    ) -> some View {
        Label {
            SearchHighlightedText(
                text,
                query: visibleSearchQuery,
                activeMatchIndex: activeOccurrence(at: location))
            .id(location)
        } icon: {
            Image(systemName: icon)
        }
        .font(.scaled(.callout))
        .foregroundStyle(Brand.error)
    }

    /// The Summary tab leads with the outcome: recap, decisions, then actions
    /// split by whose they are, open questions, and the full summary on demand.
    @ViewBuilder private var summaryTabContent: some View {
        if hasSummaryContent {
            if let summary = presentedSummary, let recap = SummaryPresentation.recap(summary) {
                MeetingRecapView(text: recap)
                    .workspaceReadingWidth()
            }
            decisionsSection
            actionsSection
            openQuestionsSection
        } else if !isProcessing {
            EmptyWorkspaceRow(
                text: "No summary yet.",
                searchQuery: visibleSearchQuery,
                activeMatchIndex: activeOccurrence(at: .emptyState(.summary)))
            .id(MeetingPageSearchMatch.Location.emptyState(.summary))
        }
        if let radar, !radar.items.isEmpty {
            WorkspaceSection(title: "Live Radar", icon: "dot.radiowaves.left.and.right") {
                RadarItemList(items: radar.items,
                              followThrough: { app.followThrough($0, in: meeting) },
                              openSource: { revealEvidence(at: $0.time) },
                              folder: meeting.folderURL(in: app.storage),
                              scrolls: false)
                // The Think model reports no cost; a cost is shown where a
                // meeting has one from when the radar ran on Meta's models.
                Group {
                    if radar.cost > 0 {
                        Text("Caught live by \(MetaModelAPI.displayName(for: radar.model)) in \(radar.passes.count) passes · \(RadarItemList.costLabel(radar.cost))")
                    } else {
                        Text("Caught live by \(MetaModelAPI.displayName(for: radar.model)) in \(radar.passes.count) passes")
                    }
                }
                .font(.scaled(.caption)).foregroundStyle(.secondary)
            }
        }
        if !screenContext.materials.isEmpty {
            MeetingScreenMaterialsSection(
                context: screenContext,
                onPlay: { material in
                    player.seek(to: material.firstOffset)
                    player.play(at: material.firstOffset)
                },
                onOpen: { app.openScreenSnapshot($0.firstSnapshotID) })
        }
        if summary?.isEmpty == false {
            fullSummaryDisclosure
        }
    }

    @ViewBuilder private var decisionsSection: some View {
        let decisions = shownProjection?.outcomes.decisionRecords ?? []
        let speakerNames = speakerPresentation
        if !decisions.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                MeetingSectionHeading(
                    title: "Decisions",
                    count: decisions.count,
                    searchQuery: visibleSearchQuery,
                    activeMatchIndex: activeOccurrence(at: .sectionHeader(.decisions)),
                    searchLocation: .sectionHeader(.decisions))
                ForEach(decisions) { decision in
                    MeetingDecisionRow(
                        decision: decision,
                        displayText: speakerNames.text(decision.displayText),
                        searchQuery: visibleSearchQuery,
                        activeMatch: activeSearchMatch) { citation in
                        playInPlace(at: citation.start)
                    }
                }
            }
        }
    }

    private var actionsSection: some View {
        let actions = shownProjection?.actionReferences ?? []
        let groups = MeetingDetailPresentation.groups(actions)
        return VStack(alignment: .leading, spacing: 6) {
            MeetingSectionHeading(
                title: "Actions",
                count: actions.isEmpty ? nil : actions.count,
                searchQuery: visibleSearchQuery,
                activeMatchIndex: activeOccurrence(at: .sectionHeader(.actionItems)),
                searchLocation: .sectionHeader(.actionItems))
            if actions.isEmpty {
                EmptyWorkspaceRow(
                    text: "No action items were extracted from this meeting.",
                    searchQuery: visibleSearchQuery,
                    activeMatchIndex: activeOccurrence(at: .emptyState(.actionItems)))
                .id(MeetingPageSearchMatch.Location.emptyState(.actionItems))
            } else {
                HStack(alignment: .firstTextBaseline) {
                    Text("For you · \(groups.forYou.count)")
                        .font(AppFont.scaled(.subheadline).weight(.semibold))
                        .foregroundStyle(Color(nsColor: WorkspaceTextColor.supporting))
                    Spacer(minLength: 8)
                    // The Actions list holds your open work from real meetings.
                    if !groups.forYou.isEmpty, projection != nil, !meeting.isSample {
                        Button("Also in Actions") { app.openActions() }
                            .buttonStyle(.workspaceLink)
                            .font(AppFont.scaled(.callout))
                            .accessibilityIdentifier("meeting.actions.openAll")
                    }
                }
                .padding(.top, 2)
                if groups.forYou.isEmpty {
                    Text("Nothing for you from this meeting.")
                        .font(AppFont.scaled(.body))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 6)
                } else {
                    actionRows(groups.forYou, showsOwner: false)
                }
                if !groups.forOthers.isEmpty {
                    Text("For others · \(groups.forOthers.count)")
                        .font(AppFont.scaled(.subheadline).weight(.semibold))
                        .foregroundStyle(Color(nsColor: WorkspaceTextColor.supporting))
                        .padding(.top, 12)
                    actionRows(groups.forOthers, showsOwner: true)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("meeting.actions")
    }

    private func actionRows(_ actions: [OutcomeActionReference], showsOwner: Bool) -> some View {
        let speakerNames = speakerPresentation
        let invited = calendarSpeakerCandidates.compactMap(\.suggestedSpeakerName)
        return VStack(spacing: 0) {
            ForEach(actions) { reference in
                MeetingActionRow(
                    reference: reference,
                    displayOwner: reference.owner.map {
                        speakerNames.owner($0, isForUser: reference.isForUser)
                    },
                    showsOwner: showsOwner,
                    ownerOptions: MeetingDetailPresentation.ownerOptions(
                        owner: reference.owner, isForUser: reference.isForUser,
                        speakers: derived.speakers, storedNames: derived.storedNames, invited: invited),
                    canNameSpeakers: !derived.unnamed.isEmpty,
                    searchQuery: visibleSearchQuery,
                    activeMatch: activeSearchMatch,
                    onStatus: { status in
                        _ = app.outcomeIndex.setStatus(
                            status,
                            actionID: reference.action.id,
                            meetingID: meeting.id)
                    },
                    onCorrect: {
                        correctionError = nil
                        correction = ActionCorrectionDraft(reference: reference)
                    },
                    onOwner: { setOwner($0, for: reference) },
                    onNameSpeakers: { namingSpeakers = true },
                    onPlay: { citation in playInPlace(at: citation.start) },
                    isEditable: partialNotes == nil, canSetStatus: projection != nil)
                if reference.id != actions.last?.id { Divider() }
            }
        }
    }

    @ViewBuilder private var openQuestionsSection: some View {
        let questions = shownProjection?.outcomes.openQuestions ?? []
        if !questions.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                MeetingSectionHeading(title: "Open questions", count: questions.count)
                ForEach(Array(questions.enumerated()), id: \.offset) { _, question in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: "questionmark.circle")
                            .foregroundStyle(LBTokens.Palette.attentionText)
                            .accessibilityHidden(true)
                        Text(speakerPresentation.text(question)).textSelection(.enabled)
                            .font(AppFont.scaled(.body))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 3)
                }
            }
        }
    }

    private var fullSummaryDisclosure: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button { fullNotesExpanded.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: fullNotesExpanded ? "chevron.down" : "chevron.forward")
                        .font(.system(size: 9, weight: .semibold))
                        .frame(width: 10)
                        .accessibilityHidden(true)
                    if visibleSearchQuery.isEmpty {
                        Text("Full summary")
                    } else {
                        SearchHighlightedText(
                            Self.fullSummaryTitle,
                            query: visibleSearchQuery,
                            activeMatchIndex: activeOccurrence(at: .sectionHeader(.summary)))
                    }
                }
                .font(AppFont.scaled(.headline))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .id(MeetingPageSearchMatch.Location.sectionHeader(.summary))
            .accessibilityValue(fullNotesExpanded ? "Expanded" : "Collapsed")
            .accessibilityIdentifier("meeting.fullNotes")
            if fullNotesExpanded {
                MeetingSummaryWorkspaceContent(
                    notes: nil,
                    summary: presentedSummary,
                    searchQuery: visibleSearchQuery,
                    activeMatch: activeSearchMatch)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("meeting.summary")
            }
        }
    }

    private static let fullSummaryTitle = "Full summary"

    private var transcriptSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !screenContext.isEmpty {
                MeetingOnScreenNowBar(context: screenContext, player: player) {
                    app.openScreenSnapshot($0.snapshotID)
                }
            }
            MeetingTranscriptList(
                transcript: transcript, display: transcriptDisplay, player: player,
                speakerPresentation: speakerPresentation,
                unnamedSpeakers: derived.unnamed,
                searchQuery: transcriptSearchQuery, activeMatch: activeSearchMatch,
                evidenceSegment: evidenceSegment,
                onRenameSpeaker: { beginRenameSpeaker($0) })
                .id(MeetingPageSearchMatch.Location.sectionHeader(.transcript))
        }
    }

    private var visibleSearchQuery: String {
        isSearchPresented ? searchQuery : ""
    }

    private var transcriptSearchQuery: String {
        (isSearchPresented || tab == .transcript) ? searchQuery : ""
    }

    private var isSearchPresented: Bool {
        app.presentedMeetingSearchID == meeting.id
    }

    private var activeSearchMatch: MeetingPageSearchMatch? {
        guard isSearchPresented || tab == .transcript,
              searchMatches.indices.contains(selectedSearchMatchIndex) else { return nil }
        return searchMatches[selectedSearchMatchIndex]
    }

    private var searchStatusText: String? {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return nil }
        guard let match = activeSearchMatch else { return "No matches" }
        return "\(selectedSearchMatchIndex + 1) of \(searchMatches.count) · "
            + match.location.sectionLabel
    }

    private func activeOccurrence(
        at location: MeetingPageSearchMatch.Location
    ) -> Int? {
        guard let match = activeSearchMatch, match.location == location else { return nil }
        return match.occurrenceIndex
    }

    private func presentSearch() {
        app.requestSelectedMeetingSearch()
    }

    private func dismissSearch() {
        app.dismissMeetingSearch(for: meeting.id)
        searchQuery = ""
        searchMatches = []
        selectedSearchMatchIndex = 0
    }

    private func updateSearch(using scrollProxy: ScrollViewProxy, revealFirst: Bool = true) {
        let previousMatch = activeSearchMatch
        let matches = MeetingPageSearch.matches(
            query: searchQuery,
            sources: isSearchPresented ? searchSources : searchSources.filter {
                MeetingWorkspaceTab.containing($0.location) == .transcript
            })
        searchMatches = matches
        selectedSearchMatchIndex = revealFirst ? 0 : matches.firstIndex { $0 == previousMatch } ?? 0
        if revealFirst, let first = matches.first {
            reveal(first, using: scrollProxy)
        }
    }

    private func moveSearch(by offset: Int, using scrollProxy: ScrollViewProxy) {
        guard !searchMatches.isEmpty else { return }
        selectedSearchMatchIndex = (
            selectedSearchMatchIndex + offset + searchMatches.count
        ) % searchMatches.count
        reveal(searchMatches[selectedSearchMatchIndex], using: scrollProxy)
    }

    private func reveal(
        _ match: MeetingPageSearchMatch,
        using scrollProxy: ScrollViewProxy
    ) {
        tab = MeetingWorkspaceTab.containing(match.location)
        switch match.location {
        case .summary, .summaryMetadata, .sectionHeader(.summary), .emptyState(.summary):
            fullNotesExpanded = true
        default: break
        }
        let scroll = {
            withAnimation(WorkspaceMotion.animation(
                .autoScroll,
                reduceMotion: reduceMotion)) {
                scrollProxy.scrollTo(match.location, anchor: .center)
            }
        }
        // The target may live in another tab; scroll after SwiftUI mounts it.
        DispatchQueue.main.async(execute: scroll)
    }

    /// Everything a page search can find, in the order the page shows it.
    private var searchSources: [MeetingPageSearchSource] {
        var sources: [MeetingPageSearchSource] = []
        let speakerNames = speakerPresentation
        func append(
            _ text: String?,
            at location: MeetingPageSearchMatch.Location
        ) {
            guard let text, !text.isEmpty else { return }
            sources.append(.init(location: location, text: text))
        }

        append(meeting.displayTitle, at: .title)
        for item in MeetingDetailMetadataItem.items(for: meeting) {
            append(item.text, at: .meetingMetadata(item.field))
        }
        if let stage = app.pipeline.stages[meeting.id] {
            append(stage.label, at: .processingStatus)
        }
        append(exportError, at: .exportError)
        append(speechError, at: .speechError)

        if !captureTranscriptOnly {
            if hasSummaryContent {
                let decisions = shownProjection?.outcomes.decisionRecords ?? []
                if !decisions.isEmpty { append("Decisions", at: .sectionHeader(.decisions)) }
                for decision in decisions {
                    append(
                        speakerNames.text(decision.displayText),
                        at: .decision(id: decision.id, field: .text))
                    if let citation = decision.citations.first {
                        append(
                            Transcript.shortStamp(citation.start),
                            at: .decision(id: decision.id, field: .evidence))
                    }
                }

                append("Actions", at: .sectionHeader(.actionItems))
                let groups = MeetingDetailPresentation.groups(shownProjection?.actionReferences ?? [])
                if groups.forYou.isEmpty && groups.forOthers.isEmpty {
                    append(
                        "No action items were extracted from this meeting.",
                        at: .emptyState(.actionItems))
                }
                for reference in groups.forYou + groups.forOthers {
                    let id = reference.action.id
                    append(reference.text, at: .action(id: id, field: .text))
                    if !reference.isForUser {
                        append(
                            reference.owner.map {
                                speakerNames.owner($0, isForUser: reference.isForUser)
                            } ?? MeetingActionOwnerMenu.missingOwnerText,
                            at: .action(id: id, field: .owner))
                    }
                    if let due = reference.due {
                        append(
                            ActionDuePresentation.label(due, spokenAt: reference.dueReferenceDate),
                            at: .action(id: id, field: .due))
                    }
                    if let citation = reference.action.citations.first {
                        append(
                            Transcript.shortStamp(citation.start),
                            at: .action(id: id, field: .evidence))
                    }
                }
            } else if !isProcessing {
                append("No summary yet.", at: .emptyState(.summary))
            }

            if let notes, !notes.isEmpty {
                append("Your notes", at: .notesLabel)
                append(
                    notes,
                    at: .notes)
            }
            if let summary = presentedSummary, !summary.isEmpty {
                append(Self.fullSummaryTitle, at: .sectionHeader(.summary))
                let parts = SummaryPresentation.split(summary)
                if !parts.metadata.isEmpty {
                    append(
                        SummaryMetadataRow.displayText(for: parts.metadata),
                        at: .summaryMetadata)
                }
                append(
                    SelectableDigestText.searchableText(from: parts.body),
                    at: .summary)
            }
        }

        append("Transcript", at: .sectionHeader(.transcript))
        if let transcript, !transcript.segments.isEmpty {
            if !transcript.engine.isEmpty && transcript.engine != "merged" {
                append(
                    meetingTranscriptEngineDescription(transcript.engine),
                    at: .transcriptEngine)
            }
            for (index, segment) in transcript.segments.enumerated() {
                // A speaker's name is shown once, where the turn begins.
                if derived.turnStarts.contains(index) {
                    append(
                        speakerNames.speaker(segment.speaker, in: transcript),
                        at: .transcript(segmentIndex: index, field: .speaker))
                }
                append(
                    Transcript.shortStamp(segment.start),
                    at: .transcript(segmentIndex: index, field: .timestamp))
                append(
                    segment.displayText,
                    at: .transcript(segmentIndex: index, field: .text))
            }
        } else {
            append("No transcript yet.", at: .emptyState(.transcript))
        }

        return sources
    }

    private func load() async {
        documentLoading = true
        reloadReviewProjection()
        // The first document was prepared before this pane became visible.
        // Only pipeline updates need to read it again.
        if loadRevision > 0 {
            await reloadDocument()
            guard !Task.isCancelled else { return }
        }
        // A pipeline artifact refresh must not reset or re-prepare active audio.
        if !player.isLoaded {
            await player.loadInBackground(folder: folder, hasSystemTrack: meeting.hasSystemTrack)
            guard !Task.isCancelled else { return }
            player.speed = app.meetingPlaybackSpeeds[meeting.id] ?? 1
            player.seek(to: app.meetingPlaybackPositions[meeting.id] ?? 0)
        }
        documentLoading = false
        consumeMeetingSeek()
    }

    private func reloadDocument() async {
        let meeting = meeting, root = app.storage.rootURL, template = app.settings.noteTemplate
        let databaseURL = app.activityStore.databaseURL
        let worker = Task.detached(priority: .userInitiated) {
            MeetingDocumentSnapshot.load(meeting: meeting, root: root, template: template, databaseURL: databaseURL)
        }
        let document = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
        guard !Task.isCancelled else { return }
        notes = document.notes
        transcript = document.transcript
        transcriptDisplay = document.transcriptDisplay
        speakerPresentation = document.speakerPresentation
        derived = MeetingTranscriptDerived(
            transcript: document.transcript, display: document.transcriptDisplay,
            presentation: document.speakerPresentation)
        reviewSpeakers = MeetingSpeakerReviewItem.items(in: document.transcript)
        partialNotes = document.partialNotes
        partialProjection = document.partialProjection
        attributionNeedsRefresh = document.attributionNeedsRefresh
        captureNeedsAttention = document.captureNeedsAttention
        recoveryNeedsAttention = document.recoveryNeedsAttention
        screenContext = document.screenContext
        radar = document.radar
        summary = document.summary
        speakerNameHints = document.speakerNameHints
        calendarSpeakerCandidates = meeting.resolvedCalendarParticipantIdentities
        searchContentRevision += 1
        await app.outcomeIndex.refreshInBackground(meeting: meeting)
    }

    private func updateTranscript(_ value: Transcript?) {
        transcript = value
        transcriptDisplay = Transcript.DisplayIndex(transcript: value)
        speakerPresentation = MeetingSpeakerPresentation(transcript: value)
        derived = MeetingTranscriptDerived(
            transcript: value, display: transcriptDisplay, presentation: speakerPresentation)
        reviewSpeakers = MeetingSpeakerReviewItem.items(in: value)
        reloadReviewProjection()
    }

    private func consumeMeetingSeek() {
        guard !documentLoading, app.selectedMeeting?.id == meeting.id else { return }
        guard let request = app.navigationHandoff.consumeMeetingEvidence(for: meeting.id) else { return }
        revealEvidence(at: request.seconds)
        if request.intent == .play { player.play(at: request.seconds) }
    }

    /// Another screen opened this meeting at a moment: show that line in the
    /// transcript.
    private func revealEvidence(at seconds: TimeInterval) {
        tab = .transcript
        player.pause()
        player.seek(to: seconds)
        evidenceSegment = segmentIndex(at: seconds)
        evidenceRevision &+= 1
    }

    /// A ▶ time on a decision or action: play from there and stay on the page.
    private func playInPlace(at seconds: TimeInterval) {
        evidenceSegment = segmentIndex(at: seconds)
        player.play(at: seconds)
    }

    /// The player's "Show in transcript": go to the line being said, without
    /// interrupting playback.
    private func showInTranscript(_ caption: MeetingDetailPresentation.Caption) {
        evidenceSegment = caption.segmentIndex
        tab = .transcript
        evidenceRevision &+= 1
    }

    private func segmentIndex(at seconds: TimeInterval) -> Int? {
        transcript?.segments.lastIndex(where: { $0.start <= seconds }) ?? transcript?.segments.indices.first
    }

    private func setOwner(_ option: MeetingDetailPresentation.OwnerOption, for reference: OutcomeActionReference) {
        guard !option.isSelected else { return }
        let change = MeetingDetailPresentation.ownerCorrection(option, for: reference)
        let saved = app.outcomeIndex.correctAction(
            actionID: reference.action.id,
            meetingID: meeting.id,
            text: change.text,
            owner: change.owner,
            due: change.due,
            reviewing: projection == nil ? meeting : nil)
        if saved {
            reloadReviewProjection()
            // The correction also re-rendered the summary's action list.
            correctionReloadTask?.cancel()
            correctionReloadTask = Task { await reloadDocument() }
        } else {
            app.lastError = app.outcomeIndex.lastError ?? "The correction could not be saved. Please try again."
        }
    }

    private func copySummary() {
        guard let summary, !summary.isEmpty else { return }
        MeetingMarkdownActions.copyText(summary)
    }

    private func copyTranscript() {
        guard let transcript, !transcript.segments.isEmpty else { return }
        MeetingMarkdownActions.copyText(transcript.markdown)
    }

    private func beginRenameSpeaker(_ speaker: String) {
        guard let transcript else { return }
        uiTestDiagnosticLog(
            "beginRenameSpeaker speaker=\(speaker) "
                + "calendarCandidates=\(calendarSpeakerCandidates.count) "
                + "meetingCandidates=\(meeting.resolvedCalendarParticipantIdentities.count)")
        speakerRenameDraft = WorkspaceSpeakerRenameDraft(
            speaker: speaker,
            defaultName: Transcript.defaultSpeakerName(for: speaker),
            currentName: transcript.displaySpeaker(for: speaker),
            currentCalendarIdentityID: transcript.calendarIdentityID(for: speaker),
            sample: reviewSpeakers.first { $0.id == Transcript.canonicalSpeakerKey(speaker) }?.sample,
            canConfirmIdentity: transcript.canConfirmSpeaker(speaker),
            microphoneIsUser: transcript.speakerRoster[speaker]?.identity == .user
                && transcript.segments.contains { Transcript.canonicalSpeakerKey($0.speaker) == speaker
                    && $0.resolvedAttribution.source == .microphone })
    }

    private var assignedCalendarIdentityIDs: Set<String> {
        Set(transcript?.speakerCalendarIdentityIDs.values.map { $0 } ?? [])
    }

    /// Unnamed call speakers in a saved meeting that match people named before.
    private var recognizedSpeakers: [(label: String, match: SpeakerNameMatch)] {
        guard let transcript else { return [] }
        return MeetingSpeakerIdentityService.recognizedSpeakers(in: speakerIdentityState, transcript: transcript)
    }

    /// The one sheet that goes through this meeting's unnamed voices.
    private var namingSheet: some View {
        let actions = shownProjection?.actionReferences.map(\.effectiveAction) ?? []
        let recognized = Dictionary(recognizedSpeakers.map { ($0.label, $0.match.name) },
                                    uniquingKeysWith: { first, _ in first })
        let recognizedBefore = Set((speakerIdentityState?.assignments ?? [])
            .filter { $0.origin == .profileAutomatic && $0.name != nil }.map(\.label))
        let lists = MeetingSpeakerNaming.lists(
            speakers: derived.speakers,
            reviewItems: MeetingSpeakerReviewItem.prioritized(reviewSpeakers, actions: actions),
            speechSeconds: derived.speechSeconds,
            recognized: recognized,
            recognizedSpeakers: recognizedBefore)
        return MeetingSpeakerNamingSheet(
            voices: lists.voices,
            known: lists.known,
            suggestions: MeetingSpeakerSuggestion.choices(calendar: calendarSpeakerCandidates, hints: speakerNameHints),
            assignedCalendarIdentityIDs: assignedCalendarIdentityIDs,
            canPlay: player.isLoaded,
            busy: savingSpeakerIdentity,
            notice: speakerIdentityNotice,
            onPlay: { player.playExcerpt(from: $0.start, to: min($0.end, $0.start + 12)) },
            onChange: { speaker in
                pendingRenameSpeaker = speaker
                namingSpeakers = false
            },
            onSave: saveSpeakerNames,
            onCancel: { namingSpeakers = false })
    }

    /// Saves every name picked in the naming sheet, as if each speaker had
    /// been named on its own.
    private func saveSpeakerNames(_ choices: [MeetingSpeakerNamingChoice]) {
        guard !savingSpeakerIdentity, !choices.isEmpty, var current = transcript else { return }
        savingSpeakerIdentity = true
        Task {
            defer { savingSpeakerIdentity = false }
            do {
                for choice in choices {
                    current = try await app.speakerIdentity.choose(
                        .init(label: choice.speaker, name: choice.name, calendarIdentityID: choice.calendarIdentityID),
                        meeting: meeting, transcript: current)
                }
                try app.saveTranscript(current, for: meeting)
                updateTranscript(current)
                searchContentRevision += 1
                speakerIdentityNotice = app.speakerIdentity.notice
                await refreshSpeakerIdentity()
                namingSpeakers = false
                // A newly remembered voice can name speakers in other recent meetings.
                app.learnSpeakerVoices()
            } catch { speakerIdentityNotice = "Could not save speaker names: \(error.localizedDescription)" }
        }
    }

    private func calendarCandidates(
        for speaker: String
    ) -> [CalendarParticipantIdentity] {
        Transcript.canonicalSpeakerKey(speaker) == "me"
            ? []
            : calendarSpeakerCandidates
    }

    private func refreshSpeakerIdentity(recover: Bool = false) async {
        do {
            speakerIdentityState = try await app.speakerIdentity.state(for: meeting)
            let latestChoice = speakerIdentityState?.decisions.filter {
                $0.action.changesAttribution
            }.map(\.confirmedAt).max()
            let summaryDate = (try? FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent("summary.md").path))?[.modificationDate] as? Date
            speakerSummaryNeedsRefresh = latestChoice.map { choice in summaryDate.map { $0 < choice } ?? false } ?? false
            if recover, let current = transcript {
                let recoveredValue = try await app.speakerIdentity.recover(meeting: meeting, transcript: current)
                let recovered = app.speakerIdentity.applyingLatestDecision(to: recoveredValue, meetingID: meeting.id)
                if recovered.segments != current.segments || recovered.speakerAliases != current.speakerAliases
                    || recovered.speakerCalendarIdentityIDs != current.speakerCalendarIdentityIDs {
                    try app.saveTranscript(recovered, for: meeting)
                    updateTranscript(recovered)
                }
            }
        } catch { speakerIdentityNotice = error.localizedDescription }
    }

    private func saveSpeakerAlias(_ alias: String?, calendarIdentityID: String?, for speaker: String,
                                  profileID: UUID? = nil) {
        performSpeakerChoice(.init(label: speaker, name: alias, calendarIdentityID: calendarIdentityID,
            action: alias == nil ? .reset : .assign, profileID: profileID,
            expectedRevision: speakerIdentityState?.revision))
    }

    private func performSpeakerChoice(_ choice: MeetingSpeakerIdentityService.Choice) {
        guard !savingSpeakerIdentity, let current = transcript else { return }
        savingSpeakerIdentity = true
        Task {
            defer { savingSpeakerIdentity = false }
            do {
                let updated = try await app.speakerIdentity.choose(choice, meeting: meeting, transcript: current)
                try app.saveTranscript(updated, for: meeting)
                updateTranscript(updated)
                searchContentRevision += 1
                exportError = nil
                speakerIdentityNotice = app.speakerIdentity.notice
                await refreshSpeakerIdentity()
                if choice.action.changesAttribution {
                    speakerRenameDraft = nil
                    // A newly remembered voice can name speakers in other recent meetings.
                    app.learnSpeakerVoices()
                }
            } catch { speakerIdentityNotice = "Could not save speaker name: \(error.localizedDescription)" }
        }
    }

    private func reloadReviewProjection() {
        reviewLoadTask?.cancel()
        let meeting = meeting, root = app.storage.rootURL, folder = folder
        let includePrevious = projection == nil
        if !includePrevious { previousReviewProjection = nil }
        reviewLoadTask = Task { @MainActor in
            let worker = Task.detached(priority: .userInitiated) {
                let needsRefresh = MeetingAttributionArtifacts.needsRefresh(in: folder)
                let reviewed = includePrevious
                    ? MeetingOutcomeProjection.load(for: meeting, root: root, includingPrevious: true) : nil
                return (needsRefresh, reviewed)
            }
            let result = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            guard !Task.isCancelled else { return }
            attributionNeedsRefresh = result.0
            previousReviewProjection = projection == nil ? result.1 : nil
        }
    }

    private func exportAudio() {
        exportError = nil
        let panel = NSSavePanel()
        panel.title = "Export Audio Recording"
        panel.nameFieldStringValue = "\(StorageManager.slugify(meeting.displayTitle))-audio.m4a"
        panel.canCreateDirectories = true
        if let type = UTType(filenameExtension: "m4a") { panel.allowedContentTypes = [type] }
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        isExportingAudio = true
        Task {
            defer { isExportingAudio = false }
            do {
                try await MeetingAudioAsset.exportMixedRecording(
                    folder: folder,
                    hasSystemTrack: meeting.hasSystemTrack,
                    to: destination)
            } catch {
                exportError = error.localizedDescription
            }
        }
    }

    private func readSummary() {
        guard let text = summary?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return }
        stopSpeech(clearError: false)
        speechError = nil
        let sessionID = UUID()
        speechSessionID = sessionID
        isReadingSummary = true
        speechTask = Task {
            var temporaryOutputURL: URL?
            defer {
                SpeechTemporaryOutputCleanup.cleanup(
                    temporaryOutputURL,
                    afterPlaybackStops: { finishSpeech(sessionID) })
            }
            do {
                let url = try await synthesize(text, outputURL: nil)
                temporaryOutputURL = url
                try Task.checkCancellation()
                let player = try AVAudioPlayer(contentsOf: url)
                player.prepareToPlay()
                guard speechSessionID == sessionID else { return }
                speechPlayer = player
                guard player.play() else {
                    throw NSError(
                        domain: "LokalBot.SpeechPlayback", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Could not start speech playback."])
                }
                try await Task.sleep(
                    nanoseconds: UInt64(max(player.duration, 0.1) * 1_000_000_000))
            } catch is CancellationError {
            } catch {
                speechError = error.localizedDescription
            }
        }
    }

    private func exportSpokenSummary() {
        guard let text = summary?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return }
        speechError = nil
        let panel = NSSavePanel()
        panel.title = "Export Spoken Summary"
        panel.nameFieldStringValue = "\(StorageManager.slugify(meeting.displayTitle))-spoken-summary.wav"
        panel.canCreateDirectories = true
        if let type = UTType(filenameExtension: "wav") { panel.allowedContentTypes = [type] }
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        isExportingSpeech = true
        Task {
            defer { isExportingSpeech = false }
            do {
                _ = try await synthesize(text, outputURL: destination)
            } catch {
                speechError = error.localizedDescription
            }
        }
    }

    private func synthesize(_ text: String, outputURL: URL?) async throws -> URL {
        try await KokoroSpeechEngine.shared.synthesize(.init(
            text: text,
            voice: app.settings.speechVoice,
            speed: app.settings.speechSpeed,
            outputURL: outputURL))
    }

    private func stopSpeech(clearError: Bool = true) {
        speechSessionID = nil
        speechTask?.cancel()
        speechTask = nil
        speechPlayer?.stop()
        speechPlayer = nil
        isReadingSummary = false
        if clearError { speechError = nil }
    }

    private func finishSpeech(_ sessionID: UUID) {
        guard speechSessionID == sessionID else { return }
        speechSessionID = nil
        speechTask = nil
        speechPlayer?.stop()
        speechPlayer = nil
        isReadingSummary = false
    }
}

private struct MeetingSummaryWorkspaceContent: View {
    let notes: String?
    let summary: String?
    let searchQuery: String
    let activeMatch: MeetingPageSearchMatch?

    var body: some View {
        if notes?.isEmpty == false || summary?.isEmpty == false {
            VStack(alignment: .leading, spacing: 14) {
                if let notes, !notes.isEmpty {
                    notesContent(notes)
                }
                if let summary, !summary.isEmpty {
                    summaryContent(summary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .workspaceReadingWidth()
        } else {
            EmptyWorkspaceRow(
                text: "No summary yet.",
                searchQuery: searchQuery,
                activeMatchIndex: activeOccurrence(at: .emptyState(.summary)))
            .id(MeetingPageSearchMatch.Location.emptyState(.summary))
        }
    }

    private func notesContent(_ notes: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label {
                SearchHighlightedText(
                    "Your notes",
                    query: searchQuery,
                    activeMatchIndex: activeOccurrence(at: .notesLabel))
                .id(MeetingPageSearchMatch.Location.notesLabel)
            } icon: {
                Image(systemName: "square.and.pencil")
            }
            .font(AppFont.scaled(.callout).weight(.semibold))
            .foregroundStyle(.secondary)
            SelectableDigestText(
                notes,
                searchQuery: searchQuery,
                activeMatchIndex: activeOccurrence(at: .notes))
            .id(MeetingPageSearchMatch.Location.notes)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            .quaternary.opacity(0.24),
            in: RoundedRectangle(cornerRadius: Brand.Radius.control))
        .accessibilityIdentifier("detail.notes")
    }

    @ViewBuilder private func summaryContent(_ summary: String) -> some View {
        let parts = SummaryPresentation.split(summary)
        if !parts.metadata.isEmpty {
            SummaryMetadataRow(
                items: parts.metadata,
                searchQuery: searchQuery,
                activeMatchIndex: activeOccurrence(at: .summaryMetadata))
            .id(MeetingPageSearchMatch.Location.summaryMetadata)
        }
        SelectableDigestText(
            parts.body,
            searchQuery: searchQuery,
            activeMatchIndex: activeOccurrence(at: .summary))
        .id(MeetingPageSearchMatch.Location.summary)
    }

    private func activeOccurrence(
        at location: MeetingPageSearchMatch.Location
    ) -> Int? {
        guard activeMatch?.location == location else { return nil }
        return activeMatch?.occurrenceIndex
    }
}

private struct MeetingPageSearchBar: View {
    @Binding var query: String
    let focusRequest: Int
    let statusText: String?
    let hasMatches: Bool
    let onPrevious: () -> Void
    let onNext: () -> Void
    let onClose: () -> Void
    let isPresented: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            MeetingSearchTextField(
                text: $query,
                focusRequest: focusRequest,
                onSubmit: onNext,
                onCancel: onClose,
                placeholder: isPresented ? "Search this meeting" : "Find in transcript",
                focusesOnAppear: isPresented)
                .frame(maxWidth: .infinity)
                .frame(height: 20)

            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Clear search")
                .accessibilityIdentifier("meeting.search.clear")
            }

            if let statusText {
                Text(statusText)
                    .font(AppFont.scaled(.callout))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
                    .accessibilityIdentifier("meeting.search.status")
            }

            Divider().frame(height: 18)

            Button(action: onPrevious) {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.plain)
            .disabled(!hasMatches)
            .help("Previous match")
            .accessibilityIdentifier("meeting.search.previous")

            Button(action: onNext) {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.plain)
            .disabled(!hasMatches)
            .help("Next match")
            .accessibilityIdentifier("meeting.search.next")

            if isPresented {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .help("Close search")
                .accessibilityIdentifier("meeting.search.close")
            }
        }
        .onAppear {
            uiTestDiagnosticLog("meeting.search bar appear")
        }
        .font(AppFont.scaled(.body))
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .workspaceControl()
        .frame(maxWidth: isPresented ? 720 : 420)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("meeting.search.bar")
    }
}

enum MeetingDetailMetric {
    /// The header, player and tab content share one centered column.
    static let columnMaxWidth: CGFloat = 800
}

/// Values worked out once per transcript, not on every redraw of the page.
private struct MeetingTranscriptDerived {
    var speakers: [MeetingDetailPresentation.Speaker] = []
    var unnamed: Set<String> = []
    var speechSeconds: [String: TimeInterval] = [:]
    var storedNames: [String: String] = [:]
    var playhead = MeetingDetailPresentation.PlayheadIndex()
    /// Segments that open a speaker turn, where the speaker's name is shown.
    var turnStarts: Set<Int> = []

    init() {}

    init(transcript: Transcript?, display: Transcript.DisplayIndex, presentation: MeetingSpeakerPresentation) {
        speakers = MeetingDetailPresentation.speakers(in: transcript, presentation: presentation)
        unnamed = Set(speakers.filter(\.needsName).map(\.id))
        speechSeconds = MeetingDetailPresentation.speechSeconds(in: transcript)
        storedNames = MeetingDetailPresentation.storedSpeakerNames(in: transcript, speakers: speakers)
        playhead = .init(display: display)
        turnStarts = Set(display.segments.filter(\.beginsSpeakerTurn).map(\.id))
    }
}

/// Words and the icon when the toolbar has room, the icon alone when it does not.
private struct AskMeetingLabelStyle: LabelStyle {
    let compact: Bool

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon
            if !compact { configuration.title }
        }
    }
}

private struct ActionCorrectionDraft: Identifiable {
    let id = UUID()
    let actionID: String
    let originalText: String
    var text: String
    var owner: String
    var due: String
    let ownerWasCorrected: Bool
    let dueWasCorrected: Bool
    var ownerWasEdited = false
    var dueWasEdited = false

    init(reference: OutcomeActionReference) {
        actionID = reference.action.id
        originalText = reference.action.text
        text = reference.text
        owner = reference.owner ?? ""
        due = reference.due ?? ""
        ownerWasCorrected = reference.ownerWasCorrected
        dueWasCorrected = reference.dueWasCorrected
    }

    var persistedOwner: String? {
        ActionCorrectionFieldIntent.persistedValue(
            owner, wasCorrected: ownerWasCorrected, wasEdited: ownerWasEdited)
    }

    var persistedDue: String? {
        ActionCorrectionFieldIntent.persistedValue(
            due, wasCorrected: dueWasCorrected, wasEdited: dueWasEdited)
    }

    var ownerIsForUser: Bool {
        owner.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare("Me") == .orderedSame
    }
}

private struct ActionCorrectionSheet: View {
    @State var draft: ActionCorrectionDraft
    var ownerSuggestions: [String] = []
    var error: String?
    let onSave: (String, String?, String?) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Correct action details").font(AppFont.scaled(.largeTitle).bold())
            TextField("Corrected wording", text: $draft.text)
            HStack {
                Text("Owner")
                Spacer()
                Menu(draft.owner.isEmpty ? "Unassigned" : SpeakerDisplayName.label(
                    draft.owner,
                    identity: draft.ownerIsForUser ? .user : .unresolved)) {
                    Button("You") { draft.owner = "Me"; draft.ownerWasEdited = true }
                    ForEach(Array(Set(ownerSuggestions)).sorted(), id: \.self) { owner in
                        Button(owner) { draft.owner = owner; draft.ownerWasEdited = true }
                    }
                    Button("Unresolved speaker") {
                        draft.owner = "Unresolved speaker"
                        draft.ownerWasEdited = true
                    }
                    Button("Unassigned") { draft.owner = ""; draft.ownerWasEdited = true }
                }
            }
            TextField("Owner", text: Binding(
                get: { draft.owner },
                set: { draft.owner = $0; draft.ownerWasEdited = true }))
                .accessibilityIdentifier("meeting.action.correction.owner")
            TextField("Due date as agreed", text: Binding(
                get: { draft.due },
                set: { draft.due = $0; draft.dueWasEdited = true }))
            Text("This correction is stored separately from the extracted source.")
                .font(AppFont.scaled(.callout)).foregroundStyle(.secondary)
            if let error { Text(error).workspaceTextRole(.warning) }
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Save correction") {
                    onSave(draft.text, draft.persistedOwner, draft.persistedDue)
                }
                    .primaryActionButton()
                    .accessibilityIdentifier("meeting.action.correction.save")
            }
        }
        .padding(WorkspaceMetric.sectionGap)
        .frame(width: 460)
    }
}

private struct WorkspaceSpeakerRenameDraft: Identifiable {
    let id = UUID()
    let speaker: String
    let defaultName: String
    let currentName: String
    let currentCalendarIdentityID: String?
    var sample: Transcript.Segment?
    var canConfirmIdentity = false
    var microphoneIsUser = false
}

private struct WorkspaceSpeakerRenameSheet: View {
    let draft: WorkspaceSpeakerRenameDraft
    let hints: [String]
    let calendarCandidates: [CalendarParticipantIdentity]
    let assignedCalendarIdentityIDs: Set<String>
    let identityState: MeetingSpeakerIdentityState?
    let notice: String?
    let busy: Bool
    let onPlay: (Transcript.Segment) -> Void
    let onPlayEvidence: (Double) -> Void
    let onAction: (SpeakerAliasDecision.Action, String?, UUID?) -> Void
    let onDeleteEvidence: () -> Void
    let onSave: (String, String?, UUID?) -> Void
    let onReset: () -> Void
    let onCancel: () -> Void

    @State private var profileID: UUID?
    @State private var name: String
    @State private var selectedCalendarIdentityID: String?
    /// The name as last typed, which searches the suggestions.
    @State private var typedName = ""
    @State private var suggestionListHeight: CGFloat = 0
    @FocusState private var nameFocused: Bool

    init(
        draft: WorkspaceSpeakerRenameDraft,
        hints: [String],
        calendarCandidates: [CalendarParticipantIdentity],
        assignedCalendarIdentityIDs: Set<String>,
        identityState: MeetingSpeakerIdentityState?,
        notice: String?,
        busy: Bool,
        onPlay: @escaping (Transcript.Segment) -> Void,
        onPlayEvidence: @escaping (Double) -> Void,
        onAction: @escaping (SpeakerAliasDecision.Action, String?, UUID?) -> Void,
        onDeleteEvidence: @escaping () -> Void,
        onSave: @escaping (String, String?, UUID?) -> Void,
        onReset: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.draft = draft
        self.hints = hints
        self.calendarCandidates = calendarCandidates
        self.assignedCalendarIdentityIDs = assignedCalendarIdentityIDs
        self.identityState = identityState
        self.notice = notice
        self.busy = busy
        self.onPlay = onPlay
        self.onPlayEvidence = onPlayEvidence
        self.onAction = onAction
        self.onDeleteEvidence = onDeleteEvidence
        self.onSave = onSave
        self.onReset = onReset
        self.onCancel = onCancel
        // Placeholder labels ("Them", "Local speaker") are not names; start
        // empty so typing a name doesn't begin by deleting one.
        _name = State(initialValue: Transcript.isPlaceholderSpeakerName(draft.currentName) ? "" : draft.currentName)
        _selectedCalendarIdentityID = State(
            initialValue: draft.currentCalendarIdentityID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Name Speaker").font(.scaled(.title3).bold())
            if let sample = draft.sample {
                HStack(alignment: .top, spacing: 12) {
                    Button { onPlay(sample) } label: {
                        Image(systemName: "play.fill").frame(width: 20, height: 20)
                    }
                    .primaryActionButton()
                    .buttonBorderShape(.circle)
                    .help("Play Voice")
                    .accessibilityLabel("Play Voice")
                    .accessibilityIdentifier("speaker.rename.playVoice")
                    VStack(alignment: .leading, spacing: 6) {
                        Text("“\(sample.text)”").font(.scaled(.body))
                            .fixedSize(horizontal: false, vertical: true)
                            .lineLimit(5)
                        Text(Transcript.stamp(sample.start))
                            .font(LBTokens.Typography.timestamp).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14).lbGroupedSurface()
            } else {
                Text("No clear voice excerpt available. Check the transcript before confirming this speaker.")
                    .workspaceTextRole(.supporting)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Name").font(.scaled(.callout)).foregroundStyle(.secondary)
                TextField("Speaker name", text: nameBinding, prompt: Text("Name this speaker"))
                    .textFieldStyle(.roundedBorder)
                    .focused($nameFocused)
                    // A field with a submit action keeps Return from the
                    // default button, so Return saves from here as well.
                    .onSubmit {
                        if let match = returnSuggestion { choose(match) } else { save() }
                    }
                    .accessibilityIdentifier("speaker.rename.name")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if !suggestions.isEmpty {
                        Text("Suggested Names")
                            .font(.scaled(.headline))
                        Text("Listen, choose a name, then save. These sources suggest names; attendance does not identify a voice.")
                            .workspaceTextRole(.supporting)
                            .fixedSize(horizontal: false, vertical: true)
                        let returnID = returnSuggestion?.id
                        ForEach(visibleSuggestions) { suggestion in
                            suggestionRow(suggestion, isReturnTarget: suggestion.id == returnID)
                        }
                        if visibleSuggestions.isEmpty {
                            Text("No suggested names match this search.")
                                .workspaceTextRole(.supporting)
                                .accessibilityIdentifier("speaker.rename.noMatchingSuggestions")
                        }
                        if !calendarCandidates.isEmpty {
                            Text("Email addresses stay in this meeting's local metadata and help distinguish guests.")
                                .workspaceTextRole(.supporting)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    SpeakerIdentityReview(speaker: draft.speaker, state: identityState,
                        name: $name, profileID: $profileID,
                        onPlay: onPlayEvidence, onAction: onAction, onDeleteEvidence: onDeleteEvidence,
                        canConfirmIdentity: draft.canConfirmIdentity, microphoneIsUser: draft.microphoneIsUser)
                    if let notice { Text(notice).font(.scaled(.caption)).foregroundStyle(.secondary) }
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                    suggestionListHeight = max(suggestionListHeight, $0)
                }
            }
            // Keep the sheet from shrinking on every keystroke while filtering.
            .frame(minHeight: min(suggestionListHeight, 280), maxHeight: 280)

            Label("Names you save also teach LokalBot this voice, so it can name the person in later meetings. Voices stay encrypted on this Mac.",
                  systemImage: "lock.shield")
                .font(.scaled(.callout)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Leave Unidentified", action: onReset)
                    .help("Clear the saved name and return to \(SpeakerDisplayName.label(draft.defaultName))")
                    .accessibilityIdentifier("speaker.rename.leaveUnidentified")
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .primaryActionButton()
                    .disabled(nameIsBlank)
                    // Return fills in the top match first, then saves.
                    .keyboardShortcut(returnSuggestion == nil ? .defaultAction : nil)
                    .accessibilityIdentifier("speaker.rename.save")
            }
        }
        .padding(24)
        .frame(width: 560)
        .disabled(busy)
        .onAppear {
            nameFocused = true
            uiTestDiagnosticLog(
                "speaker.rename sheet appear candidates=\(calendarCandidates.count)")
        }
    }

    private var suggestions: [MeetingSpeakerSuggestion] {
        MeetingSpeakerSuggestion.choices(calendar: calendarCandidates, hints: hints)
    }

    /// Typing records the name as the search; a name filled in by a choice,
    /// here or in the voice review, doesn't filter.
    private var nameBinding: Binding<String> {
        Binding(get: { name }, set: { newValue in
            if newValue != name { typedName = newValue }
            name = newValue
        })
    }

    private var nameQuery: String {
        typedName == name ? name.trimmingCharacters(in: .whitespacesAndNewlines) : ""
    }

    private var visibleSuggestions: [MeetingSpeakerSuggestion] {
        let query = nameQuery
        guard !query.isEmpty else { return suggestions }
        // The chosen guest stays listed while its name is edited, since
        // saving keeps that guest.
        return suggestions.filter { $0.matches(query) || isChosen($0) }
    }

    /// The top match not already chosen, which Return fills in. With none,
    /// Return saves the name as typed.
    private var returnSuggestion: MeetingSpeakerSuggestion? {
        let query = nameQuery
        guard !query.isEmpty else { return nil }
        return suggestions.first { $0.matches(query) && !isChosen($0) }
    }

    private func isChosen(_ suggestion: MeetingSpeakerSuggestion) -> Bool {
        if let selectedCalendarIdentityID {
            return suggestion.calendar?.id == selectedCalendarIdentityID
        }
        return suggestion.calendar == nil && suggestion.name.map(MeetingSpeakerSuggestion.nameKey)
            == MeetingSpeakerSuggestion.nameKey(name)
    }

    private var nameIsBlank: Bool { name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private func save() {
        guard !nameIsBlank else { return }
        onSave(name, selectedCalendarIdentityID, profileID)
    }

    private func choose(_ suggestion: MeetingSpeakerSuggestion) {
        name = suggestion.name ?? ""
        typedName = ""
        selectedCalendarIdentityID = suggestion.calendar?.id
        profileID = nil
    }

    private func suggestionRow(
        _ suggestion: MeetingSpeakerSuggestion, isReturnTarget: Bool
    ) -> some View {
        let assignedElsewhere = suggestion.calendar.map {
            assignedCalendarIdentityIDs.contains($0.id) && $0.id != draft.currentCalendarIdentityID
        } ?? false
        let selected = isChosen(suggestion)
        let title = suggestion.name ?? "Enter a name for this guest"
        let label = ([title] + suggestion.sources + [suggestion.calendar?.emailAddress,
                      assignedElsewhere ? "Also assigned to another voice" : nil].compactMap { $0 })
            .joined(separator: ", ")
        return Button {
            choose(suggestion)
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline) {
                    Label(title, systemImage: selected ? "checkmark.circle.fill" : "person.crop.circle")
                        .font(AppFont.scaled(.body))
                    Spacer(minLength: 8)
                    if isReturnTarget {
                        Image(systemName: "return")
                            .font(AppFont.scaled(.callout))
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) { sourceBadges(suggestion) }
                    VStack(alignment: .leading, spacing: 4) { sourceBadges(suggestion) }
                }
                if let email = suggestion.calendar?.emailAddress {
                    Text(email).font(AppFont.scaled(.callout)).foregroundStyle(.secondary)
                }
                if assignedElsewhere {
                    Text("Also assigned to another voice")
                        .font(AppFont.scaled(.callout)).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // A plain button hit-tests only its drawn content; the whole card
            // chooses the suggestion.
            .padding(12)
            .lbGroupedSurface()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(selected ? LBTokens.Palette.accentText : .primary)
        .accessibilityLabel(label)
        .accessibilityIdentifier(suggestion.accessibilityID)
    }

    private func sourceBadges(_ suggestion: MeetingSpeakerSuggestion) -> some View {
        ForEach(suggestion.sources, id: \.self) { source in
            Text(source)
                .font(AppFont.scaled(.callout))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.quaternary, in: Capsule())
        }
    }
}

@MainActor
private enum MeetingMarkdownActions {
    static func copy(_ meeting: Meeting) {
        copyText(SessionFormatter.getMarkdown(meeting, options: .all))
    }

    static func copyText(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Returns an error message for inline presentation, or nil after either
    /// a successful export or a user-cancelled save panel.
    static func export(_ meeting: Meeting) -> String? {
        let panel = NSSavePanel()
        panel.title = "Export Meeting as Markdown"
        panel.nameFieldStringValue = "\(StorageManager.slugify(meeting.displayTitle)).md"
        panel.canCreateDirectories = true
        if let markdown = UTType(filenameExtension: "md") {
            panel.allowedContentTypes = [markdown]
        }
        guard panel.runModal() == .OK, let destination = panel.url else { return nil }
        do {
            try SessionFormatter.getMarkdown(meeting, options: .all)
                .write(to: destination, atomically: true, encoding: .utf8)
            return nil
        } catch {
            return "Meeting export failed: \(error.localizedDescription)"
        }
    }
}

struct EvidencePill: View {
    let citation: OutcomeSourceCitation
    var searchQuery = ""
    var activeMatchIndex: Int?
    var searchLocation: MeetingPageSearchMatch.Location?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label {
                if let searchLocation {
                    SearchHighlightedText(
                        Transcript.stamp(citation.start),
                        query: searchQuery,
                        activeMatchIndex: activeMatchIndex)
                    .id(searchLocation)
                } else {
                    Text(Transcript.stamp(citation.start))
                }
            } icon: {
                Image(systemName: "quote.bubble")
                    .foregroundStyle(.tint)
            }
                .font(AppFont.scaled(.callout).monospacedDigit())
                .foregroundStyle(Brand.teal)
                // A comfortable click target around the small timestamp.
                .padding(.horizontal, 4)
                .padding(.vertical, 3)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(citation.excerpt)
        .accessibilityLabel("Jump to evidence at \(Transcript.stamp(citation.start))")
    }
}

struct WorkspaceSection<Content: View>: View {
    let title: String
    let icon: String
    /// App copy looks the title up in the interface catalog. Titles that
    /// carry names or other content stay verbatim.
    var localizesTitle = false
    var searchQuery = ""
    var activeMatchIndex: Int?
    var searchLocation: MeetingPageSearchMatch.Location?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: LBTokens.Metric.headerToContent) {
            Label {
                if let searchLocation {
                    SearchHighlightedText(
                        title,
                        query: searchQuery,
                        activeMatchIndex: activeMatchIndex)
                    .id(searchLocation)
                } else if localizesTitle {
                    Text(LocalizedStringKey(title))
                } else {
                    Text(title)
                }
            } icon: {
                Image(systemName: icon)
            }
            .font(.scaled(.headline))
            .labelStyle(.titleOnly)
            VStack(alignment: .leading, spacing: 8) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .lbGroupedSurface()
        }
        // Sections share one width even when their content is short.
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct EmptyWorkspaceRow: View {
    let text: String
    var searchQuery = ""
    var activeMatchIndex: Int?

    var body: some View {
        SearchHighlightedText(
            text,
            query: searchQuery,
            activeMatchIndex: activeMatchIndex)
            .font(AppFont.scaled(.body)).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 10)
    }
}
