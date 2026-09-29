import SwiftUI

/// The meeting library list — live recording first, then finished meetings
/// grouped by day. Capture's Library scope (spec §2.2: unchanged behavior —
/// multi-select, delete). The live row routes to `LiveMeetingDetailView`
/// via the shared selection. Deletion is confirmed by the host window's
/// dialog via `pendingDelete`.
struct MeetingListView: View {
    @EnvironmentObject var app: AppState
    @Binding var pendingDelete: Set<Meeting.ID>?
    @SceneStorage("meeting.library.query") private var query = ""
    @State private var contentMatches: Set<UUID> = []
    @State private var searchTask: Task<Void, Never>?
    @State private var mergeDraft: MeetingMergeDraft?

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Meetings").font(.scaled(.title3).bold())
                        Text("\(app.meetings.filter { !$0.isMergedSource }.count) meetings")
                            .font(.scaled(.callout)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    Button {
                        app.isRecording ? app.stopRecording()
                            : app.startRecording(context: app.recordingContext(for: app.detector.activeApp))
                    } label: {
                        Label(app.isRecording ? "Stop Recording" : "Record",
                              systemImage: app.isRecording ? "stop.circle.fill" : "record.circle.fill")
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                    .help(app.isRecording ? "Stop Recording" : "Record Now")
                    .accessibilityIdentifier("toolbar.record")
                }
                TextField("Search meetings", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .font(AppFont.scaled(.body))
                    .accessibilityLabel("Search meetings")
                    .accessibilityIdentifier("meeting.search")
                if app.evidenceMeetingID != nil, !query.isEmpty {
                    Text("The opened source remains visible outside these filters.")
                        .font(.scaled(.callout)).foregroundStyle(.secondary).lineLimit(1)
                }
                if !failedMeetings.isEmpty {
                    HStack {
                        Label("\(failedMeetings.count) failed", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(Brand.error)
                        Spacer()
                        Button("Retry") {
                            for meeting in failedMeetings { app.retryProcessing(meeting) }
                        }
                        .accessibilityIdentifier("meeting.retryFailed")
                    }
                    .accessibilityIdentifier("meeting.failures")
                }

            }
            .padding(WorkspaceMetric.cardPadding)

            List(selection: $app.selectedMeetingIDs) {
                ForEach(groupedMeetings, id: \.label) { group in
                    Group {
                        SectionHeader(text: group.label)
                            .selectionDisabled(true)
                        ForEach(group.items) { meeting in
                            MeetingRowView(meeting: meeting)
                                .tag(meeting.id)
                        }
                    }
                }
            }
            .listStyle(.inset)
            .tint(Brand.tealFill)
            .accessibilityIdentifier("meeting.list")
            .accessibilityLabel("Meeting library")
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if app.selectedMeetingIDs.count > 1 {
                    mergeSelectionBar
                        .padding(WorkspaceMetric.cardPadding)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.bar)
                }
            }
            .overlay {
                if !app.libraryReady {
                    LoadingStateLabel(
                        "Loading your meeting library…",
                        font: AppFont.scaled(.body))
                    .accessibilityIdentifier("meeting.libraryLoading")
                } else if groupedMeetings.isEmpty {
                    meetingEmptyState
                }
            }
        }
        .contextMenu(forSelectionType: Meeting.ID.self) { ids in
            Button("Merge \(ids.count) meetings…", systemImage: "rectangle.3.group") {
                let meetings = app.meetings.filter { ids.contains($0.id) }
                guard canMerge(meetings) else { return }
                mergeDraft = MeetingMergeDraft(meetings: meetings)
            }
            .disabled(ids.count < 2 || !canMerge(app.meetings.filter { ids.contains($0.id) }))
            Button("Delete \(ids.count > 1 ? "\(ids.count) meetings" : "meeting")…",
                   role: .destructive) {
                pendingDelete = ids
            }
        }
        .onDeleteCommand {
            if !app.selectedMeetingIDs.isEmpty { pendingDelete = app.selectedMeetingIDs }
        }
        .task { app.selectDefaultMeetingIfNeeded(); searchContent() }
        .onChange(of: query) { app.evidenceMeetingID = nil; searchContent() }
        .onDisappear { searchTask?.cancel() }
        .sheet(item: $mergeDraft) { draft in
            MeetingMergeSheet(meetings: draft.meetings, storage: app.storage)
                .environmentObject(app)
        }
        .onChange(of: app.libraryReady) { _, ready in
            if ready { app.selectDefaultMeetingIfNeeded() }
        }
    }

    private var mergeSelectionBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "rectangle.3.group")
                .foregroundStyle(Brand.teal)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(app.selectedMeetingIDs.count) meetings selected")
                    .font(AppFont.scaled(.body).weight(.semibold))
                Text(canMergeSelected
                     ? "Create one timeline and fold the originals into it"
                     : "Select completed meetings that are not processing")
                    .font(AppFont.scaled(.callout))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 6)
            Button("Merge…", systemImage: "rectangle.3.group") {
                mergeDraft = MeetingMergeDraft(meetings: selectedMeetings)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!canMergeSelected)
            .accessibilityIdentifier("meeting.merge")
        }
        .padding(.horizontal, WorkspaceMetric.cardPadding)
        .padding(.vertical, 9)
        .background(.quaternary.opacity(0.22), in: RoundedRectangle(cornerRadius: Brand.Radius.row))
        .overlay {
            RoundedRectangle(cornerRadius: Brand.Radius.row)
                .strokeBorder(Brand.teal.opacity(0.22))
        }
        .padding(.horizontal, WorkspaceMetric.cardPadding)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("meeting.mergeSelectionBar")
    }

    @ViewBuilder private var meetingEmptyState: some View {
        if libraryIsEmpty && query.isEmpty {
            ContentUnavailableView {
                Label("No meetings yet", systemImage: "waveform.circle")
            } description: {
                Text("LokalBot detects meeting apps automatically, or start a recording now.")
            }
        } else {
            ContentUnavailableView(
                "No matching meetings",
                systemImage: "waveform.circle",
                description: Text("Try different words, a meeting title, or app."))
        }
    }

    private var libraryIsEmpty: Bool {
        app.currentMeeting == nil && app.meetings.isEmpty
    }

    private var selectedMeetings: [Meeting] {
        app.meetings.filter { app.selectedMeetingIDs.contains($0.id) }
    }

    private var canMergeSelected: Bool { canMerge(selectedMeetings) }

    private func canMerge(_ meetings: [Meeting]) -> Bool {
        meetings.count >= 2 && meetings.allSatisfy { meeting in
            meeting.endedAt != nil
                && !(app.pipeline.stages[meeting.id].map { !$0.isFailure } ?? false)
        }
    }

    /// Live recording first, then finished meetings, grouped by day.
    private var groupedMeetings: [(label: String, items: [Meeting])] {
        let calendar = Calendar.current
        let all = app.meetings
            .filter { !$0.isMergedSource }
            .filter { matchesQuery($0) || $0.id == app.evidenceMeetingID }
        let groups = Dictionary(grouping: all) { calendar.startOfDay(for: $0.startedAt) }
        var result = groups.keys.sorted(by: >).map { day in
            (label: Self.dayLabel(day), items: groups[day]!.sorted { $0.startedAt > $1.startedAt })
        }
        if let live = app.currentMeeting, matchesQuery(live) || live.id == app.evidenceMeetingID {
            result.insert((label: "Recording Now", items: [live]), at: 0)
        }
        return result
    }

    private func matchesQuery(_ meeting: Meeting) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return true }
        return meeting.displayTitle.localizedCaseInsensitiveContains(needle)
            || meeting.appName.localizedCaseInsensitiveContains(needle)
            || contentMatches.contains(meeting.id)
    }

    private func searchContent() {
        searchTask?.cancel()
        let needle = query
        searchTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(160))
            guard !Task.isCancelled else { return }
            let allowed = Set(app.meetings.map(\.id))
            contentMatches = Set(RecallSearch.meetings(needle, index: app.searchIndex, meetingIDs: allowed).map(\.id))
            let visible = Set(groupedMeetings.flatMap(\.items).map(\.id))
            app.selectedMeetingIDs.formIntersection(visible)
        }
    }

    private var failedMeetings: [Meeting] {
        app.meetings.filter { !$0.isMergedSource && app.pipeline.stages[$0.id]?.isFailure == true }
    }

    private static func dayLabel(_ day: Date) -> String {
        if Calendar.current.isDateInToday(day) { return "Today" }
        if Calendar.current.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }

}

/// One meeting row — status dot, live waveform, metadata line, and the
/// processing/failed pipeline state. Shared by the Meetings list and the
/// Today home so the two surfaces can never drift.
struct MeetingRowView: View {
    @EnvironmentObject var app: AppState
    let meeting: Meeting
    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        if meeting.endedAt == nil {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                content(now: context.date)
            }
        } else {
            content(now: Date())
        }
    }

    private func content(now: Date) -> some View {
        let live = meeting.endedAt == nil
        let time = live ? "in progress"
                        : meeting.startedAt.formatted(date: .omitted, time: .shortened)
        let duration = live ? "\(max(1, Int(now.timeIntervalSince(meeting.startedAt) / 60))) min"
                            : meeting.displayDuration
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if live { StatusDot(color: Brand.recording, size: 9) }
                    Text(meeting.displayTitle).font(.scaled(.body).weight(.semibold)).lineLimit(1)
                    if live {
                        Spacer(minLength: 6)
                        LiveWaveform(barCount: 5, barWidth: 2.5, maxHeight: 10)
                    }
                }
                Text(meeting.isMergedMeeting ? "\(time) · \(duration)"
                     : "\(meeting.appName) · \(time) · \(duration)")
                    .font(.scaled(.callout)).foregroundStyle(prominence == .increased ? Color.white.opacity(0.85) : .secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(meeting.displayTitle)
            .accessibilityIdentifier("meeting.row.\(meeting.id.uuidString)")

            if !live, let stage = app.pipeline.stages[meeting.id] {
                status(stage)
            }
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func status(_ stage: ProcessingPipeline.Stage) -> some View {
        if stage.isFailure {
            VStack(alignment: .trailing, spacing: 2) {
                Label("Failed", systemImage: "exclamationmark.triangle.fill")
                    .font(AppFont.scaled(.callout))
                    .foregroundStyle(Brand.error)
                Button("Retry") {
                    app.retryProcessing(meeting)
                }
                .buttonStyle(.borderless)
                .font(AppFont.scaled(.callout))
            }
            .help(stage.label)
            .accessibilityIdentifier("meeting.retry.\(meeting.id.uuidString)")
        } else if stage.isWaitingForModels {
            // Parked, not in progress: no spinner. The action is explicit
            // about what it does — it starts the missing model downloads.
            VStack(alignment: .trailing, spacing: 2) {
                Label("Waiting for models", systemImage: "arrow.down.circle")
                    .font(AppFont.scaled(.callout))
                    .foregroundStyle(.secondary)
                Button("Download & process") {
                    app.retryProcessing(meeting)
                }
                .buttonStyle(.borderless)
                .font(AppFont.scaled(.callout))
            }
            .help(stage.label)
            .accessibilityIdentifier("meeting.waitingModels.\(meeting.id.uuidString)")
        } else {
            LoadingStateLabel(stage.rowLabel)
            .lineLimit(1)
            .help(stage.label)
            .accessibilityIdentifier("meeting.status.\(meeting.id.uuidString)")
        }
    }
}

// Expanded units are a visual presentation choice; exported summaries retain
// their existing compact duration format.
extension Meeting {
    var displayDuration: String {
        guard let seconds = recordedDuration ?? duration else { return "in progress" }
        let minutes = Int(seconds) / 60
        return minutes >= 60 ? "\(minutes / 60) hr \(minutes % 60) min" : "\(minutes) min"
    }
}
