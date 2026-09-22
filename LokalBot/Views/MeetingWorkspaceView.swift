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
    @State private var summary: String?
    @State private var partialNotes: MeetingNotesPartial?
    @State private var partialProjection: MeetingOutcomeProjection?
    @State private var notes: String?
    @State private var transcript: Transcript?
    @State private var transcriptDisplay = Transcript.DisplayIndex()
    @State private var speakerPresentation = MeetingSpeakerPresentation(transcript: nil)
    @State private var transcriptExpanded = false
    @State private var evidenceSegment: Int?
    @State private var evidenceRevision = 0
    @State private var correction: ActionCorrectionDraft?
    @State private var correctionError: String?
    @State private var reviewSpeakers: [MeetingSpeakerReviewItem] = []
    @State private var previousReviewProjection: MeetingOutcomeProjection?
    @State private var returningToReview = false
    @State private var speakerRenameDraft: WorkspaceSpeakerRenameDraft?
    @State private var speakerIdentityState: MeetingSpeakerIdentityState?
    @State private var observedParticipants: [MeetingParticipantName] = []
    @State private var speakerProfiles: [SpeakerVoiceProfile] = []
    @State private var speakerIdentityNotice: String?
    @State private var speakerObservationDiagnostics: SpeakerObservationDiagnostics?
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
    @State private var searchQuery = ""
    private var tab: MeetingWorkspaceTab {
        get { app.meetingWorkspaceTabs[meeting.id] ?? .overview }
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
    }

    private var folder: URL { meeting.folderURL(in: app.storage) }
    private var presentedSummary: String? {
        summary.map { speakerPresentation.text(SummaryPresentation.meetingBody($0, meeting: meeting)) }
    }
    private var projection: MeetingOutcomeProjection? { partialProjection ?? app.outcomeIndex.projection(for: meeting.id) }
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
                if isSearchPresented {
                    MeetingPageSearchBar(
                        query: $searchQuery,
                        focusRequest: app.meetingPageSearchRequestRevision,
                        statusText: searchStatusText,
                        hasMatches: !searchMatches.isEmpty,
                        onPrevious: { moveSearch(by: -1, using: scrollProxy) },
                        onNext: { moveSearch(by: 1, using: scrollProxy) },
                        onClose: dismissSearch)
                    .padding(.horizontal, WorkspaceMetric.pagePadding)
                    .padding(.vertical, 10)
                    Divider()
                }

                VStack(alignment: .leading, spacing: 12) {
                    meetingOverviewContent
                    if returningToReview && tab == .transcript {
                        Button("Back to speaker and action review") {
                            tab = .review
                            returningToReview = false
                        }
                        .accessibilityIdentifier("meeting.review.return")
                    }
                    ViewThatFits(in: .horizontal) {
                        contentTabPicker.pickerStyle(.segmented)
                            .fixedSize(horizontal: true, vertical: false)
                        contentTabPicker.pickerStyle(.menu)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, WorkspaceMetric.pagePadding)
                .padding(.vertical, 12)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: WorkspaceMetric.sectionGap) {
                        meetingStatusContent
                        switch tab {
                        case .overview: overviewContent
                        case .summary: summarySection
                        case .transcript: transcriptSection
                        case .review: speakerAndActionReview
                        case .notes:
                            MeetingNotesEditor(meeting: meeting, searchQuery: visibleSearchQuery, activeMatchIndex: activeOccurrence(at: .notes)) {
                                notes = $0
                                searchContentRevision += 1
                            }
                        }
                    }
                    .padding(WorkspaceMetric.pagePadding)
                    .frame(maxWidth: WorkspaceMetric.contentMaxWidth, alignment: .leading)
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
            .onChange(of: searchQuery) {
                updateSearch(using: scrollProxy)
            }
            .onChange(of: searchContentRevision) {
                if isSearchPresented {
                    updateSearch(using: scrollProxy)
                }
            }
            .onChange(of: projection) {
                reloadReviewProjection()
                if isSearchPresented {
                    updateSearch(using: scrollProxy)
                }
            }
        }
        .navigationTitle(meeting.displayTitle)
        .task(id: loadRevision) {
#if LOKALBOT_UI_TEST_HOST
            // Establish the requested capture route before asynchronous document
            // and speaker recovery; readiness must not race those operations.
            if ProcessInfo.processInfo.environment["LOKALBOT_DETAIL_TAB"] == "transcript" {
                transcriptExpanded = true
                tab = .transcript
            } else if ProcessInfo.processInfo.environment["LOKALBOT_DETAIL_TAB"] == "review" {
                tab = .review
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
                ownerSuggestions: reviewSpeakers.filter(\.isNamed).map(\.name),
                error: correctionError
            ) { text, owner, due in
                let saved = app.outcomeIndex.correctAction(
                    actionID: draft.actionID,
                    meetingID: meeting.id,
                    text: text == draft.originalText ? nil : text,
                    owner: owner,
                    due: due,
                    reviewing: tab == .review ? meeting : nil)
                if saved {
                    reloadReviewProjection()
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
                observedParticipants: observedParticipants,
                profiles: speakerProfiles,
                rememberingEnabled: app.settings.rememberSpeakersOnMac,
                notice: speakerIdentityNotice,
                busy: savingSpeakerIdentity,
                onPlay: { player.playExcerpt(from: $0, to: $0 + 12) },
                onAction: { action, name, remember, profileID in
                    performSpeakerChoice(.init(label: draft.speaker, name: name,
                        action: action, remember: remember, profileID: profileID,
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
                onSave: { name, identityID, remember, profileID in
                    saveSpeakerAlias(
                        name,
                        calendarIdentityID: identityID,
                        for: draft.speaker, remember: remember, profileID: profileID)
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
            app.meetingPlaybackPositions[meeting.id] = player.currentTime
            app.meetingPlaybackSpeeds[meeting.id] = player.speed
            player.stop()
            stopSpeech(clearError: false)
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                if let section = app.evidenceReturnSection {
                    Button(action: app.returnFromEvidence) {
                        Label(section == .today && app.showingActions ? "Back to Actions" : "Back", systemImage: "chevron.left")
                    }
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Ask this meeting") {
                    app.openAsk(query: "Help me understand this meeting", meetingIDs: [meeting.id])
                }.accessibilityIdentifier("meeting.ask")
            }
            ToolbarItem(placement: .primaryAction) {
                WorkspaceMenu(title: "Export", symbol: "square.and.arrow.up", label: "Export meeting",
                              identifier: "meeting.export", items: [
                    .init(title: "Copy Meeting as Markdown", action: { MeetingMarkdownActions.copy(meeting) }),
                    .init(title: "Export Meeting as Markdown…", action: { exportError = MeetingMarkdownActions.export(meeting) }),
                    .init(title: "Copy Summary", enabled: summary?.isEmpty == false, action: copySummary),
                    .init(title: "Copy Transcript", enabled: transcript?.segments.isEmpty == false, action: copyTranscript),
                ])
            }

            ToolbarItem(placement: .primaryAction) {
                Button(action: presentSearch) {
                    Label("Find in Meeting", systemImage: "magnifyingglass")
                }
                .help("Find on this meeting page (⌘F)")
                .accessibilityIdentifier("toolbar.meetingSearch")
            }
            ToolbarItem(placement: .primaryAction) {
                WorkspaceMenu(title: "More meeting actions", symbol: "ellipsis.circle",
                              identifier: "toolbar.meetingActions", items: meetingActionMenuItems)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Meeting workspace")
        .accessibilityIdentifier("meeting.detail.workspace")
        .sheet(isPresented: $editingBoundaries) {
            MeetingBoundaryEditor(meeting: meeting) { try app.setMeetingBoundaries($0, for: meeting) }
        }
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
        Picker("Meeting content", selection: Binding(get: { tab }, set: { tab = $0 })) {
            ForEach(MeetingWorkspaceTab.allCases) { Text($0.rawValue).tag($0) }
        }
        .labelsHidden()
        .accessibilityIdentifier("meeting.contentTabs")
    }

    private var meetingActionMenuItems: [WorkspaceMenu.Item] {
        var items: [WorkspaceMenu.Item] = [
            .init(title: isReadingSummary ? "Stop spoken summary" : "Read summary aloud",
                  enabled: summary?.isEmpty == false, action: { isReadingSummary ? stopSpeech() : readSummary() }),
            .init(title: isExportingSpeech ? "Exporting spoken summary..." : "Export spoken summary",
                  enabled: !isExportingSpeech && summary?.isEmpty == false, action: exportSpokenSummary),
            .separator,
            .init(title: "Meeting boundaries…", enabled: transcript != nil, action: { editingBoundaries = true }),
            .init(title: "Transcribe & Summarize", identifier: "toolbar.transcribeAndSummarize",
                  action: { app.reprocess(meeting, transcribe: true, summarize: true) }),
            .init(title: "Transcribe only", identifier: "toolbar.transcribeOnly",
                  action: { app.reprocess(meeting, transcribe: true, summarize: false) }),
            .init(title: "Summarize again", identifier: "toolbar.resummarize",
                  action: { app.reprocess(meeting, transcribe: false, summarize: true) }),
            .separator,
            .init(title: isExportingAudio ? "Exporting audio..." : "Export audio",
                  enabled: !isExportingAudio && player.isLoaded, action: exportAudio),
            .init(title: "Show in Finder", action: { NSWorkspace.shared.activateFileViewerSelecting([folder]) }),
        ]
        if meeting.isMergedMeeting {
            items += [.separator, .init(title: "Undo merge…", identifier: "toolbar.undoMerge",
                                       action: { undoMergeConfirmation = true })]
        }
        return items
    }

    @ViewBuilder private var meetingOverviewContent: some View {
        MeetingWorkspaceHeader(
            meeting: meeting,
            searchQuery: visibleSearchQuery,
            activeMatch: activeSearchMatch)

        if player.isLoaded {
            MeetingAudioBar(player: player, folder: folder)
        } else {
            HStack(spacing: 12) {
                Image(systemName: "play.circle.fill").font(.system(size: 28))
                Text(documentLoading ? "Loading recording…" : "No recording available")
                    .font(WorkspaceTypography.metadata)
                Spacer(minLength: 0)
            }
            .foregroundStyle(.secondary)
            .frame(height: 40)
            .padding(12).workspaceControl()
            .accessibilityIdentifier("meeting.audioPlaceholder")
        }
    }

    @ViewBuilder private var meetingStatusContent: some View {
        if let stage = app.pipeline.stages[meeting.id] {
            processingStageContent(stage)
        }
        if let partialNotes {
            VStack(alignment: .leading, spacing: 3) {
                Text(partialNotes.progressLabel).font(.caption.weight(.medium))
                    .accessibilityIdentifier("meeting.notes.partial")
                Text("Verified notes and actions are saved below. Actions become editable when the notes finish.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } else if notesNeedRefresh && tab != .review {
            VStack(alignment: .leading, spacing: 8) {
                Label("Transcript or speaker details changed", systemImage: "exclamationmark.triangle")
                    .font(WorkspaceTypography.bodyEmphasis)
                Text("Review speakers and action owners, then refresh the derived notes.")
                    .workspaceTextRole(.trust)
                Button("Review speakers and follow-ups") { tab = .review }
                    .accessibilityIdentifier("meeting.review.open")
            }
            .padding(12).workspaceControl()
            .accessibilityIdentifier("meeting.notes.stale")
        }
        if let unmatched = projection?.state.unmatchedActions, !unmatched.isEmpty {
            DisclosureGroup("Review \(unmatched.count) unmatched action edits") {
                Text("These saved edits did not match a single regenerated action. Apply them to the correct action after reviewing its source.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(unmatched.keys.sorted(), id: \.self) { id in
                    if let saved = unmatched[id] {
                        Text(saved.textCorrection ?? projection?.state.unmatchedActionText?[id] ?? "Previous action")
                            .textSelection(.enabled)
                        Text([saved.status.label, saved.ownerOverride, saved.dueOverride].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        if let speakerIdentityNotice {
            Text(speakerIdentityNotice).workspaceTextRole(.supporting)
        }
        if tab != .review, !calendarSpeakerCandidates.isEmpty, !unnamedRemoteSpeakers.isEmpty {
            HStack {
                Label("\(calendarSpeakerCandidates.count) calendar guests available as speaker suggestions", systemImage: "person.2")
                    .workspaceTextRole(.supporting)
                Spacer(minLength: 0)
                Menu("Name speakers") {
                    ForEach(unnamedRemoteSpeakers, id: \.self) { speaker in
                        Button(transcript?.displaySpeaker(for: speaker) ?? speaker) {
                            tab = .review
                            beginRenameSpeaker(speaker)
                        }
                    }
                }
                .controlSize(.small)
                .fixedSize()
                .accessibilityIdentifier("meeting.calendarSpeakerSuggestions")
            }
        }
        if let explanation = speakerObservationDiagnostics?.missingSpeakerNamesExplanation,
           let transcript, transcript.segments.contains(where: {
               $0.resolvedAttribution.source == .system && transcript.speakerAliases[Transcript.canonicalSpeakerKey($0.speaker)] == nil
           }) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Label("Speaker names weren’t captured", systemImage: "person.crop.circle.badge.questionmark")
                        .font(.caption.weight(.medium))
                    Text(explanation).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button("Review speakers") { tab = .review }
                    .controlSize(.small)
                    .accessibilityIdentifier("meeting.reviewSpeakers")
            }
            .accessibilityIdentifier("meeting.speakerCaptureUnavailable")
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

    private var notesNeedRefresh: Bool {
        speakerSummaryNeedsRefresh || MeetingAttributionArtifacts.needsRefresh(in: folder)
    }

    private var speakerAndActionReview: some View {
        VStack(alignment: .leading, spacing: WorkspaceMetric.sectionGap) {
            MeetingSpeakerReviewSection(
                speakers: reviewSpeakers, canPlay: player.isLoaded,
                onPlay: { player.playExcerpt(from: $0.start, to: min($0.end, $0.start + 12)) },
                onReview: beginRenameSpeaker)
            VStack(alignment: .leading, spacing: 8) {
                Text("2. Review action owners").font(WorkspaceTypography.sectionTitle)
                Text("These are all actions from this meeting. Only actions assigned to you appear in My actions. Select an owner to correct it; use a timestamp to inspect the source.")
                    .workspaceTextRole(.supporting)
                if projection == nil, previousReviewProjection != nil {
                    Text("These actions are from the previous notes. Review their owners, then refresh to regenerate notes from the corrected transcript.")
                        .workspaceTextRole(.warning)
                }
                actionItemsSection
            }
            MeetingNotesRefreshSection(
                needsRefresh: notesNeedRefresh,
                hasNotes: summary?.isEmpty == false,
                isProcessing: app.pipeline.stages[meeting.id].map { !$0.isFailure } ?? false,
                canRefresh: transcript?.segments.isEmpty == false && partialNotes == nil,
                settings: app.settings,
                onRefresh: { app.reprocess(meeting, transcribe: false, summarize: true) })
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Speakers, action owners, and notes")
        .accessibilityIdentifier("meeting.review")
    }

    private func processingStageContent(
        _ stage: ProcessingPipeline.Stage
    ) -> some View {
        HStack(spacing: 10) {
            Label {
                SearchHighlightedText(
                    stage.label,
                    query: visibleSearchQuery,
                    activeMatchIndex: activeOccurrence(at: .processingStatus))
                .id(MeetingPageSearchMatch.Location.processingStatus)
            } icon: {
                Image(systemName: stageIcon(stage))
            }
            .font(.callout)
            .foregroundStyle(stage.isFailure ? Brand.error : .secondary)
            if stage.isFailure {
                Button("Retry") { app.retryProcessing(meeting) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityIdentifier("meeting.workspace.retry")
            } else if stage.isWaitingForModels {
                Button("Download & process") { app.retryProcessing(meeting) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityIdentifier("meeting.workspace.downloadProcess")
            }
        }
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
        .font(.callout)
        .foregroundStyle(Brand.error)
    }

    @ViewBuilder private var overviewContent: some View {
        if let summary = presentedSummary, let recap = SummaryPresentation.recap(summary) {
            WorkspaceSection(title: "Recap", icon: "text.alignleft") {
                MeetingRecapView(text: recap)
            }
        }
        actionItemsSection
        if let projection, !projection.outcomes.isEmpty {
            decisionsSection
            if !projection.outcomes.openQuestions.isEmpty {
                WorkspaceSection(title: "Open questions", icon: "questionmark.bubble") {
                    ForEach(Array(projection.outcomes.openQuestions.enumerated()), id: \.offset) { _, question in
                        Text(speakerPresentation.text(question)).textSelection(.enabled)
                    }
                }
            }
        }
    }

    private var actionItemsSection: some View {
        let actions = (projection ?? (tab == .review ? previousReviewProjection : nil))?.actionReferences ?? []
        let speakerNames = speakerPresentation
        return WorkspaceSection(
            title: "Action items",
            icon: "checklist",
            searchQuery: visibleSearchQuery,
            activeMatchIndex: activeOccurrence(at: .sectionHeader(.actionItems)),
            searchLocation: .sectionHeader(.actionItems)) {
            if actions.isEmpty {
                EmptyWorkspaceRow(
                    text: "No action items were extracted from this meeting.",
                    searchQuery: visibleSearchQuery,
                    activeMatchIndex: activeOccurrence(at: .emptyState(.actionItems)))
                .id(MeetingPageSearchMatch.Location.emptyState(.actionItems))
            } else {
                VStack(spacing: 0) {
                    ForEach(actions) { reference in
                        OutcomeActionRow(
                            reference: reference,
                            displayOwner: reference.owner.map { speakerNames.text($0) },
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
                            onEvidence: { citation in
                                revealEvidence(at: citation.start)
                            }, isEditable: partialNotes == nil, canSetStatus: projection != nil)
                        if reference.id != actions.last?.id { Divider() }
                    }
                }
            }
        }
    }

    private var decisionsSection: some View {
        let decisions = projection?.outcomes.decisionRecords ?? []
        let speakerNames = speakerPresentation
        return WorkspaceSection(
            title: "Decisions",
            icon: "checkmark.seal",
            searchQuery: visibleSearchQuery,
            activeMatchIndex: activeOccurrence(at: .sectionHeader(.decisions)),
            searchLocation: .sectionHeader(.decisions)) {
            if decisions.isEmpty {
                EmptyWorkspaceRow(
                    text: "No cited decisions were extracted.",
                    searchQuery: visibleSearchQuery,
                    activeMatchIndex: activeOccurrence(at: .emptyState(.decisions)))
                .id(MeetingPageSearchMatch.Location.emptyState(.decisions))
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(decisions) { decision in
                        OutcomeDecisionRow(
                            decision: decision,
                            displayText: speakerNames.text(decision.displayText),
                            searchQuery: visibleSearchQuery,
                            activeMatch: activeSearchMatch) { citation in
                            revealEvidence(at: citation.start)
                        }
                    }
                }
            }
        }
    }

    private var summarySection: some View {
        WorkspaceSection(
            title: "Summary",
            icon: "text.alignleft",
            searchQuery: visibleSearchQuery,
            activeMatchIndex: activeOccurrence(at: .sectionHeader(.summary)),
            searchLocation: .sectionHeader(.summary)) {
            MeetingSummaryWorkspaceContent(
                notes: nil,
                summary: presentedSummary,
                searchQuery: visibleSearchQuery,
                activeMatch: activeSearchMatch)
        }
        .accessibilityIdentifier("meeting.summary")
    }

    private var transcriptSection: some View {
        TranscriptEvidenceList(
            transcript: transcript, display: transcriptDisplay, player: player,
            speakerPresentation: speakerPresentation,
            searchQuery: visibleSearchQuery, activeMatch: activeSearchMatch,
            evidenceSegment: evidenceSegment,
            onRenameSpeaker: { beginRenameSpeaker($0) })
            .id(MeetingPageSearchMatch.Location.sectionHeader(.transcript))
    }

    private func stageIcon(_ stage: ProcessingPipeline.Stage) -> String {
        if stage.isFailure { return "exclamationmark.triangle" }
        if stage.isWaitingForModels { return "arrow.down.circle" }
        return "sparkles"
    }

    private var visibleSearchQuery: String {
        isSearchPresented ? searchQuery : ""
    }

    private var isSearchPresented: Bool {
        app.presentedMeetingSearchID == meeting.id
    }

    private var activeSearchMatch: MeetingPageSearchMatch? {
        guard isSearchPresented,
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

    private func updateSearch(using scrollProxy: ScrollViewProxy) {
        let matches = MeetingPageSearch.matches(
            query: searchQuery,
            sources: searchSources)
        searchMatches = matches
        selectedSearchMatchIndex = 0
        if let first = matches.first {
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
        let needsTranscriptLayout: Bool
        if match.location.requiresTranscriptExpansion {
            needsTranscriptLayout = !transcriptExpanded
            transcriptExpanded = true
        } else {
            needsTranscriptLayout = false
        }

        let scroll = {
            withAnimation(WorkspaceMotion.animation(
                .autoScroll,
                reduceMotion: reduceMotion)) {
                scrollProxy.scrollTo(match.location, anchor: .center)
            }
        }
        // The target may live in another tab; scroll after SwiftUI mounts it.
        _ = needsTranscriptLayout
        DispatchQueue.main.async(execute: scroll)
    }

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
        for item in meetingWorkspaceMetadataItems(for: meeting) {
            append(item.text, at: .meetingMetadata(item.field))
        }
        if let stage = app.pipeline.stages[meeting.id] {
            append(stage.label, at: .processingStatus)
        }
        append(exportError, at: .exportError)
        append(speechError, at: .speechError)

        if !captureTranscriptOnly {
            append("Action items", at: .sectionHeader(.actionItems))
            let actions = projection?.actionReferences ?? []
            if actions.isEmpty {
                append(
                    "No action items were extracted from this meeting.",
                    at: .emptyState(.actionItems))
            } else {
                for reference in actions {
                    let id = reference.action.id
                    append(reference.text, at: .action(id: id, field: .text))
                    append(
                        reference.owner.map { speakerNames.text($0) } ?? "Owner unclear",
                        at: .action(id: id, field: .owner))
                    append(reference.due, at: .action(id: id, field: .due))
                    if let citation = reference.action.citations.first {
                        append(
                            Transcript.stamp(citation.start),
                            at: .action(id: id, field: .evidence))
                    }
                }
            }

            append("Decisions", at: .sectionHeader(.decisions))
            let decisions = projection?.outcomes.decisionRecords ?? []
            if decisions.isEmpty {
                append(
                    "No cited decisions were extracted.",
                    at: .emptyState(.decisions))
            } else {
                for decision in decisions {
                    append(
                        speakerNames.text(decision.displayText),
                        at: .decision(id: decision.id, field: .text))
                    if let citation = decision.citations.first {
                        append(
                            Transcript.stamp(citation.start),
                            at: .decision(id: decision.id, field: .evidence))
                    }
                }
            }

            append("Summary", at: .sectionHeader(.summary))
            if notes?.isEmpty == false || summary?.isEmpty == false {
                if let notes, !notes.isEmpty {
                    append("Your notes", at: .notesLabel)
                    append(
                        notes,
                        at: .notes)
                }
                if let summary = presentedSummary, !summary.isEmpty {
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
            } else {
                append("No summary yet.", at: .emptyState(.summary))
            }
        }

        append("Transcript", at: .sectionHeader(.transcript))
        if let transcript, !transcript.segments.isEmpty {
            if !transcript.engine.isEmpty && transcript.engine != "merged" {
                append(
                    transcriptEngineDescription(transcript.engine),
                    at: .transcriptEngine)
            }
            for (index, segment) in transcript.segments.enumerated() {
                append(
                    Transcript.stamp(segment.start),
                    at: .transcript(segmentIndex: index, field: .timestamp))
                append(
                    speakerNames.speaker(segment.speaker, in: transcript),
                    at: .transcript(segmentIndex: index, field: .speaker))
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
        reviewSpeakers = MeetingSpeakerReviewItem.items(in: document.transcript)
        partialNotes = document.partialNotes
        partialProjection = document.partialProjection
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
        reviewSpeakers = MeetingSpeakerReviewItem.items(in: value)
    }

    private func consumeMeetingSeek() {
        guard !documentLoading, app.selectedMeeting?.id == meeting.id else { return }
        guard let request = app.navigationHandoff.consumeMeetingEvidence(for: meeting.id) else { return }
        revealEvidence(at: request.seconds)
        if request.intent == .play { player.play(at: request.seconds) }
    }

    private func revealEvidence(at seconds: TimeInterval) {
        if tab == .review { returningToReview = true }
        transcriptExpanded = true
        tab = .transcript
        player.pause()
        player.seek(to: seconds)
        evidenceSegment = transcript?.segments.lastIndex(where: { $0.start <= seconds })
            ?? transcript?.segments.indices.first
        evidenceRevision &+= 1
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
            sampleStart: transcript.segments.first(where: {
                Transcript.canonicalSpeakerKey($0.speaker) == speaker && $0.end - $0.start >= 3
            })?.start ?? transcript.segments.first(where: { Transcript.canonicalSpeakerKey($0.speaker) == speaker })?.start,
            canConfirmIdentity: transcript.canConfirmSpeaker(speaker),
            microphoneIsUser: transcript.speakerRoster[speaker]?.identity == .user
                && transcript.segments.contains { Transcript.canonicalSpeakerKey($0.speaker) == speaker
                    && $0.resolvedAttribution.source == .microphone })
    }

    private var assignedCalendarIdentityIDs: Set<String> {
        Set(transcript?.speakerCalendarIdentityIDs.values.map { $0 } ?? [])
    }

    private var unnamedRemoteSpeakers: [String] {
        guard let transcript else { return [] }
        var seen = Set<String>()
        return transcript.segments.compactMap { segment in
            let speaker = Transcript.canonicalSpeakerKey(segment.speaker)
            guard segment.resolvedAttribution.source == .system || speaker.hasPrefix("them"),
                  transcript.speakerAliases[speaker] == nil, seen.insert(speaker).inserted else { return nil }
            return speaker
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
        let sidecar = folder.appendingPathComponent("speaker-evidence/identity.sealed")
        guard FileManager.default.fileExists(atPath: sidecar.path)
                || app.settings.identifySpeakersFromVisuals || app.settings.rememberSpeakersOnMac else { return }
        do {
            speakerObservationDiagnostics = try await app.speakerIdentity.observationDiagnostics(for: meeting)
            observedParticipants = try await app.speakerIdentity.participants(for: meeting)
            speakerIdentityState = try await app.speakerIdentity.state(for: meeting)
            speakerProfiles = try await app.speakerIdentity.profiles()
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
                                  remember: Bool = false, profileID: UUID? = nil) {
        performSpeakerChoice(.init(label: speaker, name: alias, calendarIdentityID: calendarIdentityID,
            action: alias == nil ? .reset : .assign, remember: remember, profileID: profileID,
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
                reloadReviewProjection()
                searchContentRevision += 1
                exportError = nil
                speakerIdentityNotice = app.speakerIdentity.notice
                await refreshSpeakerIdentity()
                if choice.action.changesAttribution {
                    speakerRenameDraft = nil
                }
            } catch { speakerIdentityNotice = "Could not save speaker name: \(error.localizedDescription)" }
        }
    }

    private func reloadReviewProjection() {
        previousReviewProjection = projection == nil ? app.outcomeIndex.projectionForReview(of: meeting) : nil
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
        isReadingSummary = true
        speechTask = Task {
            defer { stopSpeech(clearError: false) }
            do {
                let url = try await synthesize(text, outputURL: nil)
                try Task.checkCancellation()
                let player = try AVAudioPlayer(contentsOf: url)
                player.prepareToPlay()
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
        speechTask?.cancel()
        speechTask = nil
        speechPlayer?.stop()
        speechPlayer = nil
        isReadingSummary = false
        if clearError { speechError = nil }
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
            .font(WorkspaceTypography.metadataEmphasis)
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

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            MeetingSearchTextField(
                text: $query,
                focusRequest: focusRequest,
                onSubmit: onNext,
                onCancel: onClose)
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
                    .font(WorkspaceTypography.metadata)
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

            Button(action: onClose) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .help("Close search")
            .accessibilityIdentifier("meeting.search.close")
        }
        .onAppear {
            uiTestDiagnosticLog("meeting.search bar appear")
        }
        .font(WorkspaceTypography.control)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .workspaceControl()
        .frame(maxWidth: 720)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("meeting.search.bar")
    }
}

private struct MeetingWorkspaceMetadataItem {
    let field: MeetingPageSearchMatch.MeetingMetadataField
    let icon: String
    let text: String
}

private func meetingWorkspaceMetadataItems(
    for meeting: Meeting
) -> [MeetingWorkspaceMetadataItem] {
    let items: [MeetingWorkspaceMetadataItem] = [
        .init(
            field: .date,
            icon: "calendar",
            text: meeting.startedAt.formatted(date: .abbreviated, time: .shortened)),
        .init(field: .duration, icon: "clock", text: meeting.durationLabel),
        .init(field: .app, icon: "video", text: meeting.appName),
        .init(
            field: .audioSource,
            icon: meeting.hasSystemTrack ? "speaker.wave.2.fill" : "mic.fill",
            text: meeting.hasSystemTrack ? "Mic + system" : "Mic only"),
    ]
    return items.filter { !meeting.isMergedMeeting || $0.field != .app }
}

private func transcriptEngineDescription(_ engine: String) -> String {
    "Transcribed with \(engine)"
}

private struct MeetingWorkspaceHeader: View {
    let meeting: Meeting
    let searchQuery: String
    let activeMatch: MeetingPageSearchMatch?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SearchHighlightedText(
                meeting.displayTitle,
                query: searchQuery,
                activeMatchIndex: activeOccurrence(at: .title))
                .id(MeetingPageSearchMatch.Location.title)
                .font(WorkspaceTypography.display)
                .accessibilityIdentifier("detail.title")
            let items = meetingWorkspaceMetadataItems(for: meeting)
            ViewThatFits(in: .horizontal) {
                // Use a stable width threshold, so a longer app or date label
                // cannot move the player and tabs when selecting a meeting.
                metadataRow(items).frame(minWidth: 600, alignment: .leading)
                    .fixedSize(horizontal: true, vertical: false)
                VStack(alignment: .leading, spacing: 6) {
                    metadataRow(Array(items.prefix(2)))
                    metadataRow(Array(items.dropFirst(2)))
                }
            }
        }
    }

    private func metadataRow(_ items: [MeetingWorkspaceMetadataItem]) -> some View {
        HStack(spacing: 7) {
            ForEach(items, id: \.field) { item in
                MeetingSearchChip(
                    icon: item.icon, text: item.text, searchQuery: searchQuery,
                    activeMatchIndex: activeOccurrence(at: .meetingMetadata(item.field)),
                    location: .meetingMetadata(item.field))
            }
        }
    }

    private func activeOccurrence(
        at location: MeetingPageSearchMatch.Location
    ) -> Int? {
        guard activeMatch?.location == location else { return nil }
        return activeMatch?.occurrenceIndex
    }
}

private struct MeetingSearchChip: View {
    var icon: String?
    let text: String
    var size: ChipSize = .regular
    let searchQuery: String
    let activeMatchIndex: Int?
    let location: MeetingPageSearchMatch.Location

    var body: some View {
        Group {
            if let icon {
                Label {
                    highlightedText
                } icon: {
                    Image(systemName: icon)
                }
                .labelStyle(.titleAndIcon)
            } else {
                highlightedText
            }
        }
        .font(size.font.monospacedDigit())
        .foregroundStyle(Color(nsColor: WorkspaceTextColor.supporting))
        .chipChrome(size)
    }

    private var highlightedText: some View {
        SearchHighlightedText(
            text,
            query: searchQuery,
            activeMatchIndex: activeMatchIndex)
            .id(location)
    }
}

private struct MeetingAudioBar: View {
    @ObservedObject var player: MeetingPlayer
    @ObservedObject private var clock: MeetingPlaybackClock
    let folder: URL

    init(player: MeetingPlayer, folder: URL) {
        self.player = player
        self.clock = player.clock
        self.folder = folder
    }

    var body: some View {
        HStack(spacing: 12) {
            Button { player.playPause() } label: {
                Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 28))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.space, modifiers: [])
            .help("Play / pause (Space)")
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
            WaveformView(
                sources: player.waveformSources,
                currentTime: clock.currentTime,
                duration: player.duration,
                onSeek: { player.seek(to: $0) })
                .id(folder)
            Text("\(Transcript.stamp(clock.currentTime)) / \(Transcript.stamp(player.duration))")
                .font(WorkspaceTypography.metadata.monospacedDigit())
                .foregroundStyle(Color(nsColor: WorkspaceTextColor.supporting))
                .fixedSize()
            WorkspaceMenu(title: "\(player.speed.formatted())x", label: "Playback speed",
                          identifier: "meeting.playbackSpeed", items:
                [0.75, 1, 1.25, 1.5, 1.75, 2.0].map { speed in
                    .init(title: "\(speed.formatted())x", selected: player.speed == Float(speed),
                          action: { player.speed = Float(speed) })
                } + [.separator, .init(title: "Reset to 1x", action: { player.speed = 1 })])
        }
        .padding(12).workspaceControl()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Meeting playback")
        .accessibilityIdentifier("meeting.audioPlayer")
    }
}

private struct OutcomeActionRow: View {
    @EnvironmentObject var app: AppState
    let reference: OutcomeActionReference
    let displayOwner: String?
    let searchQuery: String
    let activeMatch: MeetingPageSearchMatch?
    let onStatus: (OutcomeStatus) -> Void
    let onCorrect: () -> Void
    let onEvidence: (OutcomeSourceCitation) -> Void
    var isEditable = true
    var canSetStatus = true

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button { onStatus(reference.status == .done ? .open : .done) } label: {
                Image(systemName: reference.status == .done ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(reference.status == .done ? Brand.teal : .secondary)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("meeting.action.toggle.\(reference.action.id)")
            .accessibilityLabel(reference.status == .done ? "Reopen action" : "Mark action done")
            .accessibilityValue(reference.text)
            .disabled(!isEditable || !canSetStatus)
            VStack(alignment: .leading, spacing: 5) {
                SearchHighlightedText(
                    reference.text,
                    query: searchQuery,
                    activeMatchIndex: activeOccurrence(for: .text))
                    .id(MeetingPageSearchMatch.Location.action(
                        id: reference.action.id,
                        field: .text))
                    .font(WorkspaceTypography.body)
                    .strikethrough(reference.status == .done)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("meeting.action.text.\(reference.action.id)")
                HStack(spacing: 7) {
                    Button(action: onCorrect) {
                        SearchHighlightedText(
                            displayOwner ?? "Owner unclear",
                            query: searchQuery,
                            activeMatchIndex: activeOccurrence(for: .owner))
                            .id(MeetingPageSearchMatch.Location.action(
                                id: reference.action.id,
                                field: .owner))
                    }
                        .buttonStyle(.plain)
                        .font(WorkspaceTypography.metadataEmphasis)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Correct owner: \(displayOwner ?? "Owner unclear")")
                        .accessibilityIdentifier("meeting.action.owner.\(reference.action.id)")
                        .disabled(!isEditable)
                    if let due = reference.due {
                        MeetingSearchChip(
                            icon: "calendar",
                            text: due,
                            size: .compact,
                            searchQuery: searchQuery,
                            activeMatchIndex: activeOccurrence(for: .due),
                            location: .action(
                                id: reference.action.id,
                                field: .due))
                    }
                    if let citation = reference.action.citations.first {
                        EvidencePill(
                            citation: citation,
                            searchQuery: searchQuery,
                            activeMatchIndex: activeOccurrence(for: .evidence),
                            searchLocation: .action(
                                id: reference.action.id,
                                field: .evidence)) {
                            onEvidence(citation)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            WorkspaceMenu(title: "Action options", symbol: "ellipsis",
                          label: "Options for action: \(reference.text)",
                          identifier: "meeting.action.status.\(reference.action.id)", items:
                OutcomeStatus.allCases.map { status in
                    .init(title: status.label, enabled: canSetStatus, selected: status == reference.status,
                          action: { onStatus(status) })
                } + [.separator, .init(title: "Correct owner or due date", action: onCorrect),
                     .init(title: "Open in Agent", action: {
                    app.openAgent(.init(
                        title: reference.text,
                        prompt: "Help me complete this action from \(reference.meetingTitle): \(reference.text)",
                        meetingID: reference.meetingID,
                        actionID: reference.action.id))
                })])
            .disabled(!isEditable)
        }
        .padding(.vertical, WorkspaceMetric.rowVerticalPadding)
    }

    private func activeOccurrence(
        for field: MeetingPageSearchMatch.ActionField
    ) -> Int? {
        let location = MeetingPageSearchMatch.Location.action(
            id: reference.action.id,
            field: field)
        guard activeMatch?.location == location else { return nil }
        return activeMatch?.occurrenceIndex
    }
}

private struct OutcomeDecisionRow: View {
    let decision: MeetingOutcomes.Decision
    let displayText: String
    let searchQuery: String
    let activeMatch: MeetingPageSearchMatch?
    let onEvidence: (OutcomeSourceCitation) -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "checkmark")
                .foregroundStyle(Brand.teal)
            SearchHighlightedText(
                displayText,
                query: searchQuery,
                activeMatchIndex: activeOccurrence(for: .text))
                .id(MeetingPageSearchMatch.Location.decision(
                    id: decision.id,
                    field: .text))
                .font(WorkspaceTypography.body)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            if let citation = decision.citations.first {
                EvidencePill(
                    citation: citation,
                    searchQuery: searchQuery,
                    activeMatchIndex: activeOccurrence(for: .evidence),
                    searchLocation: .decision(
                        id: decision.id,
                        field: .evidence)) {
                    onEvidence(citation)
                }
            }
        }
    }

    private func activeOccurrence(
        for field: MeetingPageSearchMatch.DecisionField
    ) -> Int? {
        let location = MeetingPageSearchMatch.Location.decision(
            id: decision.id,
            field: field)
        guard activeMatch?.location == location else { return nil }
        return activeMatch?.occurrenceIndex
    }
}

private struct ActionCorrectionDraft: Identifiable {
    let id = UUID()
    let actionID: String
    let originalText: String
    var text: String
    var owner: String
    var due: String

    init(reference: OutcomeActionReference) {
        actionID = reference.action.id
        originalText = reference.action.text
        text = reference.text
        owner = reference.owner ?? ""
        due = reference.due ?? ""
    }
}

private struct ActionCorrectionSheet: View {
    @State var draft: ActionCorrectionDraft
    var ownerSuggestions: [String] = []
    var error: String?
    let onSave: (String, String, String) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Correct action details").font(WorkspaceTypography.pageTitle)
            TextField("Corrected wording", text: $draft.text)
            HStack {
                Text("Owner")
                Spacer()
                Menu(draft.owner.isEmpty ? "Unassigned" : draft.owner) {
                    Button("Me") { draft.owner = "Me" }
                    ForEach(Array(Set(ownerSuggestions)).sorted(), id: \.self) { owner in
                        Button(owner) { draft.owner = owner }
                    }
                    Button("Unresolved speaker") { draft.owner = "Unresolved speaker" }
                    Button("Unassigned") { draft.owner = "" }
                }
            }
            TextField("Owner", text: $draft.owner)
                .accessibilityIdentifier("meeting.action.correction.owner")
            TextField("Due date as agreed", text: $draft.due)
            Text("This correction is stored separately from the extracted source.")
                .font(WorkspaceTypography.metadata).foregroundStyle(.secondary)
            if let error { Text(error).workspaceTextRole(.warning) }
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Save correction") { onSave(draft.text, draft.owner, draft.due) }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("meeting.action.correction.save")
            }
        }
        .padding(WorkspaceMetric.sectionGap)
        .frame(width: 460)
    }
}

private struct TranscriptEvidenceList: View {
    let transcript: Transcript?
    let display: Transcript.DisplayIndex
    @ObservedObject var player: MeetingPlayer
    let speakerPresentation: MeetingSpeakerPresentation
    let searchQuery: String
    let activeMatch: MeetingPageSearchMatch?
    let evidenceSegment: Int?
    let onRenameSpeaker: (String) -> Void

    var body: some View {
        if let transcript, !display.segments.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                if !transcript.engine.isEmpty && transcript.engine != "merged" {
                    HStack(spacing: 6) {
                        Image(systemName: "waveform.badge.magnifyingglass")
                            .foregroundStyle(.tint)
                        SearchHighlightedText(
                            transcriptEngineDescription(transcript.engine),
                            query: searchQuery,
                            activeMatchIndex: activeOccurrence(at: .transcriptEngine))
                            .id(MeetingPageSearchMatch.Location.transcriptEngine)
                    }
                    .font(WorkspaceTypography.metadata)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.24),
                                in: RoundedRectangle(cornerRadius: Brand.Radius.control))
                    .accessibilityIdentifier("transcript.model")
                }

                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(display.segments) { row in
                        let index = row.id
                        let segment = row.segment
                        HStack(alignment: .top, spacing: 10) {
                            Button {
                                player.play(at: segment.start)
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "play.fill")
                                        .font(.system(size: 8))
                                    SearchHighlightedText(
                                        Transcript.stamp(segment.start),
                                        query: searchQuery,
                                        activeMatchIndex: activeOccurrence(
                                            at: .transcript(
                                                segmentIndex: index,
                                                field: .timestamp)))
                                        .id(MeetingPageSearchMatch.Location.transcript(
                                            segmentIndex: index,
                                            field: .timestamp))
                                        .font(.caption.monospacedDigit())
                                }
                                .foregroundStyle(.tertiary)
                                .frame(width: 64, alignment: .trailing)
                            }
                            .buttonStyle(.plain)
                            .help("Play from \(Transcript.stamp(segment.start))")
                            .accessibilityIdentifier("transcript.segment.\(index).play")
                            Group {
                                if row.beginsSpeakerTurn {
                                    TranscriptSpeakerButton(
                                        title: speakerPresentation.speaker(segment.speaker, in: transcript),
                                        query: searchQuery,
                                        activeMatchIndex: activeOccurrence(
                                            at: .transcript(segmentIndex: index, field: .speaker)),
                                        identifier: "transcript.segment.\(index).speaker") {
                                        onRenameSpeaker(segment.speaker)
                                    }
                                } else {
                                    Color.clear.accessibilityHidden(true)
                                }
                            }
                            .id(MeetingPageSearchMatch.Location.transcript(segmentIndex: index, field: .speaker))
                            .frame(width: 128, height: 20, alignment: .leading)
                            .clipped()
                            SearchHighlightedText(
                                row.text,
                                query: searchQuery,
                                activeMatchIndex: activeOccurrence(
                                    at: .transcript(
                                        segmentIndex: index,
                                        field: .text)))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                                .help("Select text and press Command-C to copy")
                                .accessibilityIdentifier("transcript.segment.\(index).text")
                        }
                        .padding(.top, row.beginsSpeakerTurn ? 12 : 2)
                        .padding(.bottom, 3)
                        .padding(.horizontal, 6)
                        .background {
                            TranscriptPlaybackHighlight(clock: player.clock, isPlaying: player.isPlaying,
                                start: segment.start, end: segment.end, isEvidence: evidenceSegment == index)
                        }
                        .id(MeetingPageSearchMatch.Location.transcript(
                            segmentIndex: index,
                            field: .text))
                    }
                }
            }
        } else {
            EmptyWorkspaceRow(
                text: "No transcript yet.",
                searchQuery: searchQuery,
                activeMatchIndex: activeOccurrence(at: .emptyState(.transcript)))
            .id(MeetingPageSearchMatch.Location.emptyState(.transcript))
        }
    }

    private func activeOccurrence(
        at location: MeetingPageSearchMatch.Location
    ) -> Int? {
        guard activeMatch?.location == location else { return nil }
        return activeMatch?.occurrenceIndex
    }
}

private struct TranscriptPlaybackHighlight: View {
    let clock: MeetingPlaybackClock
    let isPlaying: Bool
    let start: TimeInterval
    let end: TimeInterval
    let isEvidence: Bool
    @State private var containsPlayhead = false

    var body: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(isEvidence || (isPlaying && containsPlayhead) ? Brand.teal.opacity(0.14) : Color.clear)
            .onReceive(clock.$currentTime.map { $0 >= start && $0 < max(end, start + 0.5) }.removeDuplicates()) {
                containsPlayhead = $0
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

private struct WorkspaceSpeakerRenameDraft: Identifiable {
    let id = UUID()
    let speaker: String
    let defaultName: String
    let currentName: String
    let currentCalendarIdentityID: String?
    var sampleStart: Double?
    var canConfirmIdentity = false
    var microphoneIsUser = false
}

private struct WorkspaceSpeakerRenameSheet: View {
    let draft: WorkspaceSpeakerRenameDraft
    let hints: [String]
    let calendarCandidates: [CalendarParticipantIdentity]
    let assignedCalendarIdentityIDs: Set<String>
    let identityState: MeetingSpeakerIdentityState?
    let observedParticipants: [MeetingParticipantName]
    let profiles: [SpeakerVoiceProfile]
    let rememberingEnabled: Bool
    let notice: String?
    let busy: Bool
    let onPlay: (Double) -> Void
    let onAction: (SpeakerAliasDecision.Action, String?, Bool, UUID?) -> Void
    let onDeleteEvidence: () -> Void
    let onSave: (String, String?, Bool, UUID?) -> Void
    let onReset: () -> Void
    let onCancel: () -> Void

    @State private var remember: Bool
    @State private var profileID: UUID?
    @State private var name: String
    @State private var selectedCalendarIdentityID: String?

    init(
        draft: WorkspaceSpeakerRenameDraft,
        hints: [String],
        calendarCandidates: [CalendarParticipantIdentity],
        assignedCalendarIdentityIDs: Set<String>,
        identityState: MeetingSpeakerIdentityState?,
        observedParticipants: [MeetingParticipantName],
        profiles: [SpeakerVoiceProfile],
        rememberingEnabled: Bool,
        notice: String?,
        busy: Bool,
        onPlay: @escaping (Double) -> Void,
        onAction: @escaping (SpeakerAliasDecision.Action, String?, Bool, UUID?) -> Void,
        onDeleteEvidence: @escaping () -> Void,
        onSave: @escaping (String, String?, Bool, UUID?) -> Void,
        onReset: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.draft = draft
        self.hints = hints
        self.calendarCandidates = calendarCandidates
        self.assignedCalendarIdentityIDs = assignedCalendarIdentityIDs
        self.identityState = identityState
        self.observedParticipants = observedParticipants
        self.profiles = profiles
        self.rememberingEnabled = rememberingEnabled
        self.notice = notice
        self.busy = busy
        self.onPlay = onPlay
        self.onAction = onAction
        self.onDeleteEvidence = onDeleteEvidence
        _remember = State(initialValue: false)
        self.onSave = onSave
        self.onReset = onReset
        self.onCancel = onCancel
        _name = State(initialValue: draft.currentName)
        _selectedCalendarIdentityID = State(
            initialValue: draft.currentCalendarIdentityID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Rename Speaker").font(.headline)
                Spacer()
                if let start = draft.sampleStart {
                    Button("Play voice") { onPlay(start) }
                        .accessibilityIdentifier("speaker.rename.playVoice")
                }
            }
            TextField("Speaker name", text: $name)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("speaker.rename.name")
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
            if !observedParticipants.isEmpty {
                Text("Seen in this meeting")
                    .font(.subheadline.weight(.semibold))
                ForEach(observedParticipants) { participant in
                    Button {
                        name = participant.name
                        selectedCalendarIdentityID = nil
                        profileID = nil
                    } label: {
                        HStack {
                            Label(participant.name, systemImage: normalizedName(name) == normalizedName(participant.name)
                                ? "checkmark.circle.fill" : "person.crop.circle")
                            Spacer()
                            Text(participant.isSelf ? "You" : (participant.source == .ocr ? "From screen" : "From Meet"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("speaker.rename.meetParticipant.\(participant.id)")
                }
            }
            if !calendarCandidates.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Suggestions from calendar guests")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    Text("Play the voice, choose a guest, then save. Names marked From email are editable suggestions.")
                        .font(.caption).foregroundStyle(.secondary)

                    ForEach(Array(calendarCandidates.enumerated()), id: \.element.id) { index, candidate in
                        calendarCandidateRow(candidate, index: index)
                    }

                    Text("Email addresses stay in this meeting's local metadata and are shown only to distinguish attendees.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .background(
                    .quaternary.opacity(0.22),
                    in: RoundedRectangle(cornerRadius: 8))
            }

            SpeakerIdentityReview(speaker: draft.speaker, state: identityState,
                profiles: profiles, rememberingEnabled: rememberingEnabled,
                name: $name, remember: $remember, profileID: $profileID,
                onPlay: onPlay, onAction: onAction, onDeleteEvidence: onDeleteEvidence,
                canConfirmIdentity: draft.canConfirmIdentity, microphoneIsUser: draft.microphoneIsUser)
            if let notice { Text(notice).font(.caption).foregroundStyle(.secondary) }

            if !otherHints.isEmpty {
                Text("Other suggestions")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(otherHints, id: \.self) { hint in
                            Button(hint) {
                                name = hint
                                selectedCalendarIdentityID = nil
                            }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                        }
                    }
                }
            }

                }
            }
            .frame(maxHeight: 440)

            HStack {
                Button("Reset to \(draft.defaultName)", action: onReset)
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Save") { onSave(name, selectedCalendarIdentityID, remember, profileID) }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("speaker.rename.save")
            }
        }
        .padding(18)
        .frame(width: 500)
        .disabled(busy)
        .onAppear {
            uiTestDiagnosticLog(
                "speaker.rename sheet appear candidates=\(calendarCandidates.count)")
        }
    }

    private var otherHints: [String] {
        let knownNames = Set((calendarCandidates.compactMap(\.suggestedSpeakerName)
            + observedParticipants.map(\.name)).map(normalizedName))
        return hints.filter { !knownNames.contains(normalizedName($0)) }
    }

    private func calendarCandidateRow(
        _ candidate: CalendarParticipantIdentity,
        index: Int
    ) -> some View {
        let assignedElsewhere = assignedCalendarIdentityIDs.contains(candidate.id)
            && candidate.id != draft.currentCalendarIdentityID
        let label = calendarCandidateAccessibilityLabel(
            candidate,
            assignedElsewhere: assignedElsewhere)
        return Button {
            selectCalendarCandidate(candidate)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Label(candidate.suggestedSpeakerName ?? "Enter a name for this guest",
                        systemImage: selectedCalendarIdentityID == candidate.id ? "checkmark.circle.fill" : "person.crop.circle")
                    Spacer()
                    if candidate.name == nil, candidate.suggestedSpeakerName != nil {
                        Text("From email").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let email = candidate.emailAddress {
                    Text(email).font(.caption).foregroundStyle(.secondary)
                }
                if assignedElsewhere { Text("Also assigned to another voice").font(.caption).foregroundStyle(.secondary) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // A standard SwiftUI bordered button supplies the native AXButton
        // role. Custom plain labels and NSViewRepresentable roots can be
        // flattened by SwiftUI when presented inside a sheet.
        .buttonStyle(.bordered)
        .tint(selectedCalendarIdentityID == candidate.id ? .accentColor : nil)
        .help(assignedElsewhere ? "Also assign this attendee to this speaker" : "Assign this attendee")
        .accessibilityLabel(label)
        .accessibilityIdentifier("speaker.rename.calendarCandidate.\(index)")
    }

    private func selectCalendarCandidate(_ candidate: CalendarParticipantIdentity) {
        selectedCalendarIdentityID = candidate.id
        profileID = nil
        name = candidate.suggestedSpeakerName ?? ""
    }

    private func calendarCandidateAccessibilityLabel(
        _ candidate: CalendarParticipantIdentity,
        assignedElsewhere: Bool
    ) -> String {
        [
            candidate.suggestedSpeakerName ?? "Enter a name for this guest",
            candidate.emailAddress,
            candidate.name == nil && candidate.suggestedSpeakerName != nil ? "Name suggested from email" : nil,
            assignedElsewhere ? "Assigned" : nil,
        ]
        .compactMap { $0 }
        .joined(separator: ", ")
    }

    private func normalizedName(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: .current)
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
            }
                .font(WorkspaceTypography.metadata.monospacedDigit())
        }
        .buttonStyle(.borderless)
        .help(citation.excerpt)
        .accessibilityLabel("Jump to evidence at \(Transcript.stamp(citation.start))")
    }
}

struct WorkspaceSection<Content: View>: View {
    let title: String
    let icon: String
    var searchQuery = ""
    var activeMatchIndex: Int?
    var searchLocation: MeetingPageSearchMatch.Location?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label {
                if let searchLocation {
                    SearchHighlightedText(
                        title,
                        query: searchQuery,
                        activeMatchIndex: activeMatchIndex)
                    .id(searchLocation)
                } else {
                    Text(title)
                }
            } icon: {
                Image(systemName: icon)
            }
            .font(WorkspaceTypography.sectionTitle)
            content
        }
        .workspacePanel()
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
            .font(WorkspaceTypography.body).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 10)
    }
}
