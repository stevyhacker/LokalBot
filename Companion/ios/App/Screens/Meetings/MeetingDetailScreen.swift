import LokalBotCompanionKit
import SwiftUI

/// A meeting as the Mac's meeting page shows it: header chips, then Summary,
/// Transcript and Notes. Evidence pills jump to the cited transcript line.
struct MeetingDetailScreen: View {
    let meetingID: String
    let focus: Double?

    @Environment(CompanionSession.self) private var session
    @Environment(AppNavigator.self) private var navigator
    @Environment(\.openWindow) private var openWindow
    @Environment(\.supportsMultipleWindows) private var supportsMultipleWindows
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var model: MeetingDetailModel
    @State private var appliedFocus = false

    init(meetingID: String, focus: Double?) {
        self.meetingID = meetingID
        self.focus = focus
        _model = State(initialValue: MeetingDetailModel(meetingID: meetingID))
    }

    var body: some View {
        @Bindable var model = model
        ScrollViewReader { proxy in
            ScrollView {
                if let meeting = model.meeting {
                    VStack(alignment: .leading, spacing: 18) {
                        MeetingHeader(meeting: meeting)
                        if sizeClass == .compact {
                            tabs.frame(maxWidth: 380, alignment: .leading)
                        }
                        switch model.tab {
                        case .summary: summary(meeting)
                        case .transcript: transcript
                        case .notes: notes(meeting)
                        }
                    }
                    .pageColumn(maxWidth: 860)
                } else if model.loaded {
                    ContentUnavailableView("Meeting not on this device", systemImage: "waveform.circle",
                                           description: Text("It may have been deleted or merged on your Mac."))
                        .padding(.top, 80)
                }
            }
            .task(id: model.focusedSegment) {
                guard let index = model.focusedSegment else { return }
                try? await Task.sleep(for: .milliseconds(80))
                withAnimation(WorkspaceMotion.animation(.autoScroll, reduceMotion: reduceMotion)) {
                    proxy.scrollTo(Self.segmentID(index), anchor: .center)
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .refreshable { await session.syncNow() }
        .task(id: session.revision) {
            await model.load(session)
            applyFocusOnce()
        }
        .sheet(item: $model.focusedExcerpt) { citation in
            ExcerptSheet(citation: citation, meeting: model.meeting)
                .presentationDetents([.medium])
        }
    }

    private func applyFocusOnce() {
        guard !appliedFocus else { return }
        appliedFocus = true
        if let focus {
            model.focus(at: focus, citation: model.meeting.flatMap { meeting in
                (meeting.actions.flatMap(\.citations) + meeting.decisions.flatMap(\.citations))
                    .first { $0.start == focus }
            })
        }
        if let tab = navigator.demoMeetingTab.flatMap({ MeetingDetailModel.Tab(rawValue: $0.capitalized) }) {
            model.tab = tab
            navigator.demoMeetingTab = nil
        }
    }

    /// Summary, Transcript and Notes: in the toolbar where there is room, as
    /// on the Mac, otherwise under the header.
    private var tabs: some View {
        @Bindable var model = model
        return ToolbarTabs(label: "Meeting content", tabs: MeetingDetailModel.Tab.allCases,
                           selection: $model.tab, title: \.rawValue)
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        if sizeClass == .regular, model.meeting != nil {
            ToolbarItem(placement: .principal) { tabs.fixedSize() }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            if supportsMultipleWindows {
                Button {
                    openWindow(id: MeetingWindow.id, value: meetingID)
                } label: {
                    Label("Open in New Window", systemImage: "macwindow.badge.plus")
                }
            }
            Button {
                navigator.ask(about: .init(meetingId: meetingID))
            } label: {
                Label("Ask About This Meeting", systemImage: "sparkle.magnifyingglass")
            }
        }
    }

    // MARK: Summary

    @ViewBuilder private func summary(_ meeting: Meeting) -> some View {
        VStack(alignment: .leading, spacing: LBTokens.Spacing.sectionSpacing) {
            if let recap = SummaryPresentation.recap(meeting.summaryMarkdown) {
                WorkspaceSection("Recap", icon: "text.alignleft") {
                    MarkdownText(recap).padding(.vertical, 6)
                }
            }
            WorkspaceSection("Action Items", icon: "checklist") {
                if meeting.actions.isEmpty {
                    EmptyWorkspaceRow("No action items were extracted from this meeting.")
                } else {
                    VStack(spacing: 0) {
                        ForEach(meeting.actions) { action in
                            ActionRowView(action: action, meetingID: meeting.id,
                                          pending: model.pendingActionIDs.contains(action.id), today: session.today,
                                          evidence: .handle { model.focus(at: $0.start, citation: $0) }) {
                                Task { await model.setStatus(action.status == .done ? .open : .done, for: action, session: session) }
                            }
                            if action.id != meeting.actions.last?.id { Divider() }
                        }
                    }
                }
                if let error = model.actionError {
                    Text(error).workspaceTextRole(.warning).padding(.bottom, 6)
                }
            }
            if !meeting.decisions.isEmpty {
                WorkspaceSection("Decisions", icon: "checkmark.seal") {
                    outcomes(meeting.decisions, icon: "checkmark.circle", tint: LBTokens.Palette.successText)
                }
            }
            if !meeting.openQuestions.isEmpty {
                WorkspaceSection("Open Questions", icon: "questionmark.circle") {
                    outcomes(meeting.openQuestions, icon: "questionmark.circle", tint: LBTokens.Palette.attentionText)
                }
            }
        }
    }

    private func outcomes(_ items: [MeetingOutcome], icon: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(items) { item in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: icon).foregroundStyle(tint).accessibilityHidden(true)
                    Text(item.text)
                        .font(LBTokens.Typography.body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                    if let citation = item.citations.first {
                        EvidencePill(citation: citation) { model.focus(at: citation.start, citation: citation) }
                    }
                }
                .padding(.vertical, 6)
            }
        }
    }

    // MARK: Transcript

    static func segmentID(_ index: Int) -> String { "segment-\(index)" }

    @ViewBuilder private var transcript: some View {
        if let transcript = model.transcript, !transcript.segments.isEmpty {
            TranscriptList(transcript: transcript, focused: model.focusedSegment)
        } else {
            WorkspaceSection("Transcript", icon: "text.quote") {
                EmptyWorkspaceRow(model.meeting?.hasTranscript == true
                                  ? "The transcript hasn't synced yet."
                                  : "This meeting's transcript isn't shared with this device.")
            }
        }
    }

    // MARK: Notes

    @ViewBuilder private func notes(_ meeting: Meeting) -> some View {
        WorkspaceSection("Your Notes", icon: "note.text") {
            if let notes = meeting.notesMarkdown, !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                MarkdownText(notes).padding(.vertical, 6)
            } else {
                EmptyWorkspaceRow("No notes. Notes you write on your Mac show here.")
            }
        }
    }
}

/// Title and the meeting's facts as chips, in the Mac's time zone.
struct MeetingHeader: View {
    let meeting: Meeting

    var body: some View {
        let format = LBFormat.current
        VStack(alignment: .leading, spacing: 10) {
            Text(meeting.title)
                .font(LBTokens.Typography.pageTitle)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            FlowLayout(spacing: 7, lineSpacing: 7) {
                BrandChip(icon: "calendar", format.meetingDate(meeting))
                BrandChip(icon: "clock", LBFormat.meetingDuration(meeting.durationSeconds))
                if let app = meeting.appName { BrandChip(icon: "video", app) }
                ForEach(meeting.people) { person in
                    NavigationLink(value: PersonRoute(id: person.id)) {
                        BrandChip(icon: "person", person.displayName)
                    }
                    .buttonStyle(.plain)
                    .lbHoverEffect()
                }
                ForEach(meeting.projects) { project in
                    NavigationLink(value: ProjectRoute(id: project.id)) {
                        BrandChip(icon: "folder", project.name, tint: Brand.teal)
                    }
                    .buttonStyle(.plain)
                    .lbHoverEffect()
                }
            }
        }
    }
}

/// The transcript: time, speaker at each turn, and the words. Wide layouts
/// use the Mac's three columns; narrow ones put the speaker above the turn.
struct TranscriptList: View {
    let transcript: Transcript
    let focused: Int?
    @Environment(\.horizontalSizeClass) private var sizeClass
    @ScaledMetric(relativeTo: .subheadline) private var stampWidth: CGFloat = 70

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 2) {
            ForEach(Array(transcript.segments.enumerated()), id: \.offset) { index, segment in
                let beginsTurn = index == 0 || transcript.segments[index - 1].speaker != segment.speaker
                row(segment, beginsTurn: beginsTurn)
                    .padding(.top, beginsTurn ? 12 : 2)
                    .padding(.bottom, 4)
                    .padding(.horizontal, 6)
                    .background {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(focused == index ? LBTokens.Palette.accentWash : Color.clear)
                    }
                    .id(MeetingDetailScreen.segmentID(index))
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(segment.speaker), \(LBFormat.stamp(segment.start)): \(segment.text)")
            }
        }
    }

    @ViewBuilder private func row(_ segment: TranscriptSegment, beginsTurn: Bool) -> some View {
        if sizeClass == .regular {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                stamp(segment)
                Group {
                    if beginsTurn { speaker(segment) } else { Color.clear }
                }
                .frame(width: 140, alignment: .leading)
                text(segment)
            }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                stamp(segment)
                VStack(alignment: .leading, spacing: 3) {
                    if beginsTurn { speaker(segment) }
                    text(segment)
                }
            }
        }
    }

    private func stamp(_ segment: TranscriptSegment) -> some View {
        Text(LBFormat.stamp(segment.start))
            .font(LBTokens.Typography.timestamp)
            .foregroundStyle(LBTokens.Palette.accentText)
            .frame(width: stampWidth, alignment: .trailing)
    }

    private func speaker(_ segment: TranscriptSegment) -> some View {
        HStack(spacing: 6) {
            Circle().fill(LBTokens.Palette.speaker(at: segment.colorIndex)).frame(width: 7, height: 7)
            Text(segment.speaker)
                .font(LBTokens.Typography.secondary.weight(.semibold))
                .lineLimit(1)
        }
    }

    private func text(_ segment: TranscriptSegment) -> some View {
        Text(segment.text)
            .readingText()
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }
}

/// The quoted words behind an outcome when the transcript isn't on this device.
struct ExcerptSheet: View {
    let citation: Citation
    let meeting: Meeting?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    if let speaker = citation.speaker {
                        Text(speaker).font(LBTokens.Typography.secondary.weight(.semibold))
                    }
                    Text(meeting.map { LBFormat.current.time(in: $0, at: citation.start) } ?? LBFormat.stamp(citation.start))
                        .font(LBTokens.Typography.timestamp)
                        .foregroundStyle(Brand.teal)
                }
                HStack(alignment: .top, spacing: 10) {
                    Capsule().fill(Brand.teal.opacity(0.5)).frame(width: 3)
                    Text("“\(citation.excerpt)”").readingText().fixedSize(horizontal: false, vertical: true)
                }
                Text("This meeting's transcript isn't shared with this device, so only the quoted words are here.")
                    .font(LBTokens.Typography.caption)
                    .workspaceSupportingForeground()
                Spacer(minLength: 0)
            }
            .padding(20)
            .navigationTitle("Evidence")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}
