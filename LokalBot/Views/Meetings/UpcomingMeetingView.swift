import AppKit
import SwiftUI

/// The meeting that starts within the hour, at the top of Today: when it is,
/// who is in it, Join and Record, and what to know before joining. Calendar
/// setup and permissions stay in Settings.
struct TodayNextMeetingCard: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var model: UpcomingMeetingPreparationModel
    let event: CalendarMeetingCandidate
    let now: Date
    /// The reader's own choice. Without one, preparation is open, and folds to
    /// a count while another meeting is being recorded.
    @State private var preparationChoice: Bool?
    @State private var showsMore = false

    private var evidence: UpcomingMeetingEvidence? {
        guard let evidence = model.evidence, evidence.event.externalID == event.externalID,
              evidence.hasPreparationContext else { return nil }
        return evidence
    }

    private var preparationOpen: Bool { preparationChoice ?? !app.isRecording }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 12) {
                    summary
                    Spacer(minLength: 8)
                    actions.fixedSize()
                }
                VStack(alignment: .leading, spacing: 12) {
                    summary
                    actions
                }
            }
            if let evidence {
                Divider()
                preparation(evidence)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .todayCardSurface()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("today.upcomingMeeting")
        .onChange(of: app.isRecording) { _, _ in preparationChoice = nil }
        .onChange(of: event.externalID) { _, _ in
            preparationChoice = nil
            showsMore = false
        }
    }

    // MARK: Heading

    private var summary: some View {
        VStack(alignment: .leading, spacing: 3) {
            (TodayMeetingStatusText.text(TodayAgenda.status(of: event, now: now))
                + Text(verbatim: " · " + UpcomingMeetingPresentation.interval(event)))
                .font(AppFont.scaled(.callout).weight(.semibold).monospacedDigit())
                .foregroundStyle(LBTokens.Palette.accentText)
            Text(verbatim: event.title)
                .font(app.isRecording ? TodayType.cardTitleCompact : TodayType.cardTitle)
                .lineLimit(1)
                .textSelection(.enabled)
            if let participants = UpcomingMeetingPresentation.participantLabel(event) {
                Text(verbatim: participants)
                    .font(AppFont.scaled(.callout))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("today.meeting.\(event.externalID)")
    }

    /// A solo event without a link may not be a call at all; the toolbar's
    /// Record is still there for it. Record leaves the card while something
    /// else is being recorded: the live card holds the only Stop.
    @ViewBuilder private var actions: some View {
        if UpcomingMeetingSelector.kind(of: event) == .meeting {
            HStack(spacing: 8) {
                if let meetingURL = event.meetingURL {
                    Link(destination: meetingURL) {
                        Label("Join", systemImage: "video")
                    }
                    .primaryActionButton()
                    .accessibilityIdentifier("today.meeting.\(event.externalID).join")
                }
                if !app.isRecording {
                    Button {
                        app.startRecording(
                            context: app.recordingContext(for: event),
                            source: "today-schedule")
                    } label: {
                        Label {
                            Text("Record")
                        } icon: {
                            Image(systemName: "circle.fill")
                                .foregroundStyle(LBTokens.Palette.recording)
                        }
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("today.meeting.\(event.externalID).record")
                }
            }
            .controlSize(.large)
        }
    }

    // MARK: Before you join

    private func preparation(_ evidence: UpcomingMeetingEvidence) -> some View {
        let rows = TodayPreparation.primaryRows(evidence)
        let more = TodayPreparation.moreRows(evidence)
        let count = rows.count + more.count
        return VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Button {
                    withAnimation(WorkspaceMotion.animation(.disclosure, reduceMotion: reduceMotion)) {
                        preparationChoice = !preparationOpen
                    }
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "chevron.forward")
                            .font(.system(size: 9, weight: .semibold))
                            .rotationEffect(.degrees(preparationOpen ? 90 : 0))
                            .accessibilityHidden(true)
                        Text("Before you join").fontWeight(.semibold)
                        if !preparationOpen, count > 0 {
                            Text(count == 1 ? "\(count) item" : "\(count) items")
                        }
                    }
                    .font(AppFont.scaled(.callout))
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityValue(preparationOpen ? "Expanded" : "Collapsed")
                .accessibilityIdentifier("today.upcomingMeeting.preparation")
                Spacer(minLength: 8)
                if preparationOpen { briefControl(evidence) }
            }
            if preparationOpen {
                if TodayPreparation.showsBrief(
                    generatedByModel: model.generatedByModel(for: evidence), rowCount: count) {
                    Text(verbatim: model.brief(for: evidence))
                        .font(AppFont.scaled(.body))
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("today.upcomingMeeting.brief")
                }
                if let generationError = model.generationError(for: evidence) {
                    Label(generationError, systemImage: "exclamationmark.triangle")
                        .font(AppFont.scaled(.callout))
                        .foregroundStyle(Brand.error)
                }
                if count > 0 {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(rows) { row in TodayPreparationRowView(row: row) }
                        if showsMore {
                            ForEach(more) { row in TodayPreparationRowView(row: row) }
                        }
                        if !more.isEmpty {
                            Button(showsMore ? "Show fewer" : "Show \(more.count) more") {
                                showsMore.toggle()
                            }
                            .buttonStyle(.workspaceLink)
                            .font(AppFont.scaled(.callout))
                            .padding(.top, 3)
                            .accessibilityIdentifier("today.upcomingMeeting.more")
                        }
                    }
                }
            }
        }
    }

    /// The model's brief is on request: it may load the Think model.
    @ViewBuilder private func briefControl(_ evidence: UpcomingMeetingEvidence) -> some View {
        if model.isGenerating(evidence) {
            LoadingStateLabel("Preparing…", font: AppFont.scaled(.callout))
        } else {
            Button(model.generatedByModel(for: evidence) ? "Rewrite brief" : "Write brief") {
                Task { await model.generate(app: app, evidence: evidence) }
            }
            .buttonStyle(.workspaceLink)
            .font(AppFont.scaled(.callout))
            .disabled(
                model.generatingSignature != nil
                    || !UpcomingMeetingLocalGenerationPolicy.permitsLocalGeneration(
                        settings: app.settings))
            .help("Generate from these sources using the Think model on this Mac")
            .accessibilityIdentifier("today.upcomingMeeting.generateBrief")
        }
    }
}

/// One thing to know before joining: what it is, the words, and where it
/// comes from. A source that can be opened opens on click.
private struct TodayPreparationRowView: View {
    @EnvironmentObject private var app: AppState
    let row: TodayPreparation.Row

    var body: some View {
        switch row.target {
        case .meeting(let id):
            Button { app.openMeeting(id) } label: { content }
                .buttonStyle(.plain)
        case .link(let url):
            // A conversation opens in Gmail, signed in as the account that holds it.
            Button { NSWorkspace.shared.open(url) } label: { content }
                .buttonStyle(.plain)
                .help("Open in \(Self.mailService)")
                .accessibilityIdentifier("today.upcomingMeeting.email")
        case nil:
            content
        }
    }

    private static let mailService = "Gmail"

    /// One line where it fits; a narrow card puts the source under the words.
    private var content: some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(LBTokens.Palette.accentText)
                .frame(width: 16)
                .accessibilityHidden(true)
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    words.lineLimit(1).fixedSize()
                    Spacer(minLength: 0)
                    source.fixedSize()
                }
                VStack(alignment: .leading, spacing: 1) {
                    words.lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    source
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var words: some View {
        (label.fontWeight(.semibold) + Text(verbatim: "  " + row.text))
            .font(AppFont.scaled(.body))
            .multilineTextAlignment(.leading)
    }

    private var source: some View {
        detail
            .font(AppFont.scaled(.callout))
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }

    private var label: Text {
        switch row.kind {
        case .decision: Text("Decided")
        case .commitment: Text("To revisit")
        case .project: Text("Project")
        case .email: Text("Email")
        case .recentMeeting: Text("Recent")
        }
    }

    private var icon: String {
        switch row.kind {
        case .decision: "checkmark"
        case .commitment: "clock"
        case .project: "folder"
        case .email: "envelope"
        case .recentMeeting: "clock.arrow.circlepath"
        }
    }

    /// "Design review · Nov 3", or for mail "Ana · yesterday · waiting on your reply".
    private var detail: Text {
        var parts: [String] = []
        if !row.source.isEmpty { parts.append(row.source) }
        if let date = row.date {
            parts.append(row.kind == .email
                ? date.formatted(.relative(presentation: .named))
                : date.formatted(.dateTime.month(.abbreviated).day()))
        }
        let base = Text(verbatim: parts.joined(separator: " · "))
        guard row.awaitingReply else { return base }
        return base + Text(verbatim: parts.isEmpty ? "" : " · ") + Text("waiting on your reply")
    }
}

/// A meeting's place in the day as words: "In 12 min", "Recording", "Ended".
enum TodayMeetingStatusText {
    static func text(_ status: TodayAgenda.Entry.Status) -> Text {
        switch status {
        case .recording: return Text("Recording")
        // A saved recording's row shows its app and length instead.
        case .recorded, .ended: return Text("Ended")
        case .inProgress: return Text("In progress")
        case .startingNow: return Text("Starting now")
        case .upcoming(let minutes):
            if minutes < 60 { return Text("In \(minutes) min") }
            let hours = minutes / 60, remainder = minutes % 60
            return remainder == 0 ? Text("In \(hours)h") : Text("In \(hours)h \(remainder)m")
        }
    }
}

enum UpcomingMeetingPresentation {
    /// "11:00 – 11:30 AM", in the reader's own time format.
    static func interval(_ event: CalendarMeetingCandidate) -> String {
        guard event.endDate > event.startDate else {
            return event.startDate.formatted(date: .omitted, time: .shortened)
        }
        return (event.startDate..<event.endDate).formatted(date: .omitted, time: .shortened)
    }

    static func participantLabel(_ event: CalendarMeetingCandidate) -> String? {
        guard !event.participantNames.isEmpty else { return nil }
        let visible = event.participantNames.prefix(4).joined(separator: ", ")
        let remaining = event.participantNames.count - min(4, event.participantNames.count)
        return remaining > 0 ? visible + " +\(remaining)" : visible
    }
}
