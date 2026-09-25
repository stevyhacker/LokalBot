import SwiftUI

/// The detail pane for the meeting being recorded right now, shown when the
/// in-progress row is selected (and as the Meetings empty state while
/// recording). The rolling
/// transcript preview (chunked, undiarized — the full pipeline transcript
/// replaces it after the meeting) sits beside a full-height quick-notes pad;
/// notes are saved to `notes.md` in the meeting folder and folded into the
/// summary.
///
/// Starting preview is an explicit ASR opt-in. Opening a live meeting alone
/// does not load a model or start speech inference.
struct LiveMeetingDetailView: View {
    @EnvironmentObject var app: AppState
    let meeting: Meeting
    @ObservedObject var transcriber: LiveMeetingTranscriber

    @State private var notes = ""
    @State private var followingLive = true
    @State private var userIsScrolling = false
    @State private var notesSaveState = "Saved on this Mac"
    @State private var notesLoaded = false
    @State private var saveTask: Task<Void, Never>?

    private var folder: URL { meeting.folderURL(in: app.storage) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            HSplitView {
                transcriptColumn
                    .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
                    .layoutPriority(1)
                    .splitPaneAccessibilityLabel("Live transcript")
                notesColumn
                    .frame(minWidth: 240, idealWidth: 300, maxHeight: .infinity)
                    .splitPaneAccessibilityLabel("Meeting notes")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(WorkspaceMetric.sectionGap)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            loadNotes()
        }
        .onDisappear {
            saveTask?.cancel()
            saveNotes()
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(meeting.title).font(.title2.bold())
                    .accessibilityIdentifier("live.title")
                Spacer()
                Button {
                    app.stopRecording()
                } label: {
                    Label("Stop Recording", systemImage: "stop.circle.fill")
                }
                .tint(.red)
                .primaryActionButton()
                .accessibilityIdentifier("live.stop")
            }
            RecordingHealthStrip(recording: app.recording)
            previewControls
            HStack(spacing: 6) {
                HStack(spacing: 6) {
                    StatusDot(color: Brand.recording, size: 7, pulses: true)
                    Text("recording").font(.caption)
                    LiveWaveform(barCount: 5, barWidth: 2.5, maxHeight: 10)
                    MeetingRecordingTimerText(recording: app.recording)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10).padding(.vertical, 5)
                .hudCapsule(shadowed: false)
                BrandChip(icon: "calendar",
                          text: meeting.startedAt.formatted(date: .omitted, time: .shortened))
                BrandChip(icon: "video", text: meeting.appName)
                BrandChip(icon: meeting.hasSystemTrack ? "speaker.wave.2.fill" : "exclamationmark.triangle.fill",
                          text: meeting.hasSystemTrack ? "Mic + system" : "Mic only")
                    .help(meeting.hasSystemTrack ? "" : "Only your microphone is being recorded.")
            }
        }
    }

    // MARK: - Transcript

    private var previewControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                switch transcriber.state {
                case .running:
                    Button("Pause preview") { transcriber.pause() }
                        .accessibilityIdentifier("live.pausePreview")
                case .paused:
                    Button("Resume preview") { transcriber.activate() }
                        .accessibilityIdentifier("live.resumePreview")
                case .failed:
                    Button("Retry preview") { transcriber.activate() }
                        .accessibilityIdentifier("live.retryPreview")
                case .off:
                    Button("Start live transcript preview") { transcriber.activate() }
                        .accessibilityIdentifier("live.startPreview")
                    Button("From beginning") { transcriber.activate(from: .beginning) }
                        .accessibilityIdentifier("live.previewFromBeginning")
                }
            }
            .buttonStyle(.bordered)
            if transcriber.state == .off {
                Text("Preview starts with the latest 12 seconds. The full transcript covers the whole recording.")
                    .workspaceTextRole(.supporting)
            } else if transcriber.state == .paused {
                Text("Preview paused. Recording continues; resume picks up where you left off.")
                    .workspaceTextRole(.supporting)
            } else if let start = transcriber.previewStartTime, start > 0 {
                Text("Preview starts at \(Self.timestamp(start)). Earlier audio remains in the full recording.")
                    .workspaceTextRole(.supporting)
            }
        }
    }

    private var transcriptColumn: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Live transcript")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if let error = transcriber.errorMessage, !transcriber.lines.isEmpty {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(Brand.error)
                    .accessibilityIdentifier("live.previewError")
            }
            transcript
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 9))
            Text("Preview — the full transcript and summary arrive after the meeting.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.trailing, 12)
    }

    private var transcript: some View {
        Group {
            if transcriber.lines.isEmpty {
                Group {
                    switch transcriber.state {
                    case .off:
                        ContentUnavailableView("Preview is off", systemImage: "text.bubble",
                                               description: Text("Start live transcript preview to read along. Recording continues independently."))
                    case .paused:
                        ContentUnavailableView("Preview paused", systemImage: "pause.circle",
                                               description: Text("Resume preview when you want to read along. Recording continues."))
                    case .failed(let message):
                        ContentUnavailableView("Preview interrupted", systemImage: "exclamationmark.triangle",
                                               description: Text(message))
                            .accessibilityIdentifier("live.previewError")
                    case .running:
                        LoadingStateLabel(
                            transcriber.statusMessage ?? "Listening…",
                            font: .callout)
                    }
                }
                .multilineTextAlignment(.center)
                .padding(.horizontal)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            ForEach(transcriber.lines) { line in
                                lineView(line).id(line.id)
                            }
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .onScrollGeometryChange(for: Bool.self) {
                        $0.contentSize.height - $0.visibleRect.maxY < 80
                    } action: { _, nearEnd in
                        if userIsScrolling { followingLive = nearEnd }
                    }
                    .onScrollPhaseChange { _, phase in
                        switch phase {
                        case .tracking, .interacting, .decelerating: userIsScrolling = true
                        default: userIsScrolling = false
                        }
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if !followingLive {
                            Button("Follow live") {
                                followingLive = true
                                if let last = transcriber.lines.last { proxy.scrollTo(last.id, anchor: .bottom) }
                            }.buttonStyle(.bordered).padding(8)
                        }
                    }
                    .onChange(of: transcriber.lines.last?.id) {
                        if followingLive, let last = transcriber.lines.last {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                    .onAppear {
                        if let last = transcriber.lines.last {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }
        }
    }

    private func lineView(_ line: LiveMeetingTranscriber.Line) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(Self.timestamp(line.time))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
            Text(line.speaker == "local" || line.speaker == "me" ? "Me" : "Remote speaker")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(line.text)
                .font(.callout)
                .textSelection(.enabled)
        }
    }

    // MARK: - Notes

    private var notesColumn: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Notes")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            TextEditor(text: $notes)
                .font(.callout)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 9))
                .accessibilityLabel("Live meeting notes")
                .accessibilityIdentifier("live.notes")
                .onChange(of: notes) { scheduleSave() }
            Text(notesSaveState)
                .font(WorkspaceTypography.metadata)
                .foregroundStyle(notesSaveState.hasPrefix("Not saved:") ? Brand.error : .secondary)
        }
        .padding(.leading, 12)
    }

    private static func timestamp(_ time: TimeInterval) -> String {
        let total = max(0, Int(time))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    // MARK: - Notes persistence

    private func loadNotes() {
        guard !notesLoaded else { return }
        notesLoaded = true
        notes = app.meetingNoteDrafts[meeting.id] ?? MeetingNotes.load(from: folder) ?? ""
    }

    private func scheduleSave() {
        notesSaveState = "Saving…"
        app.meetingNoteDrafts[meeting.id] = notes
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            saveNotes()
        }
    }

    private func saveNotes() {
        guard notesLoaded else { return }
        do {
            try MeetingNotes.writeChecked(notes, to: folder)
            notesSaveState = "Saved on this Mac"
            app.meetingNoteDrafts.removeValue(forKey: meeting.id)
        } catch {
            notesSaveState = "Not saved: \(error.localizedDescription)"
        }
    }
}
