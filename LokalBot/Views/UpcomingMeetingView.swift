import AppKit
import SwiftUI

/// The next calendar meeting leads, with the rest of today's meetings listed
/// compactly below it. Calendar setup and permissions stay in Settings.
struct UpcomingMeetingSection: View {
    @EnvironmentObject private var app: AppState
    @ObservedObject var model: UpcomingMeetingPreparationModel

    var body: some View {
        if model.status == .ready {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                let upcoming = model.meetingsToday.filter { $0.endDate > context.date }
                if let next = upcoming.first {
                    WorkspaceSection(title: "Next meeting", icon: "calendar") {
                        TodayMeetingRow(event: next)
                        if let evidence = model.evidence,
                           evidence.event.externalID == next.externalID,
                           evidence.hasPreparationContext {
                            DisclosureGroup("Preparation context") {
                                UpcomingMeetingCard(model: model, evidence: evidence)
                            }
                        }
                        if upcoming.count > 1 {
                            LaterTodayList(events: Array(upcoming.dropFirst()), now: context.date)
                        }
                    }
                    .accessibilityIdentifier("today.meetings")
                }
            }
        }
    }
}

/// Later meetings stay visible without competing with the next meeting's
/// single primary action.
private struct LaterTodayList: View {
    let events: [CalendarMeetingCandidate]
    let now: Date
    @State private var showsAll = false

    private static let inlineLimit = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Later today")
                .font(WorkspaceTypography.metadataEmphasis)
                .foregroundStyle(.secondary)
            ForEach(showsAll ? events : Array(events.prefix(Self.inlineLimit)), id: \.externalID) { event in
                row(event)
            }
            if events.count > Self.inlineLimit {
                Button(showsAll ? "Show fewer" : "\(events.count - Self.inlineLimit) more today") {
                    showsAll.toggle()
                }
                .buttonStyle(.plain)
                .font(WorkspaceTypography.metadata)
                .foregroundStyle(Brand.teal)
                .accessibilityIdentifier("today.meetings.later.more")
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("today.meetings.later")
    }

    private func row(_ event: CalendarMeetingCandidate) -> some View {
        HStack(spacing: 12) {
            Text(UpcomingMeetingPresentation.timeRange(event))
                .font(WorkspaceTypography.metadata.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 118, alignment: .leading)
            Text(event.title)
                .font(WorkspaceTypography.body)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(UpcomingMeetingPresentation.statusLabel(event: event, now: now))
                .font(WorkspaceTypography.metadata)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("today.meeting.later.\(event.externalID)")
    }
}

private struct TodayMeetingRow: View {
    @EnvironmentObject private var app: AppState
    let event: CalendarMeetingCandidate

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            HStack(alignment: .center, spacing: 12) {
                Text(UpcomingMeetingPresentation.timeRange(event))
                    .font(WorkspaceTypography.metadataEmphasis.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 118, alignment: .leading)

                VStack(alignment: .leading, spacing: 2) {
                    Text(event.title)
                        .font(WorkspaceTypography.rowTitle)
                        .lineLimit(1)
                        .textSelection(.enabled)
                    if let participants = UpcomingMeetingPresentation.participantLabel(event) {
                        Text(participants)
                            .font(WorkspaceTypography.metadata)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 8)

                Text(UpcomingMeetingPresentation.statusLabel(event: event, now: context.date))
                    .font(WorkspaceTypography.metadataEmphasis)
                    .foregroundStyle(event.endDate < context.date ? .tertiary : .secondary)
                    .lineLimit(1)

                // A solo event without a link may not be a call at all; the
                // user can still record from the toolbar.
                if event.endDate >= context.date, UpcomingMeetingSelector.kind(of: event) == .meeting {
                    compactActions
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, WorkspaceMetric.rowVerticalPadding)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(.quaternary.opacity(0.25)))
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("today.meeting.\(event.externalID)")
    }

    private var compactActions: some View {
        HStack(spacing: 6) {
            if let meetingURL = event.meetingURL {
                Link(destination: meetingURL) {
                    Label("Join", systemImage: "video")
                }
                .primaryActionButton()
                .accessibilityIdentifier("today.meeting.\(event.externalID).join")
            }
            Button {
                app.startRecording(
                    context: app.recordingContext(for: event),
                    source: "today-schedule")
            } label: {
                Label(isCurrentRecording ? "Recording" : "Record", systemImage: "record.circle")
            }
            .buttonStyle(.bordered)
            .disabled(app.isRecording)
            .accessibilityIdentifier("today.meeting.\(event.externalID).record")
        }
        .controlSize(.small)
    }

    private var isCurrentRecording: Bool {
        app.currentMeeting?.calendarEventID == event.externalID
    }
}

private struct UpcomingMeetingCard: View {
    @EnvironmentObject private var app: AppState
    @ObservedObject var model: UpcomingMeetingPreparationModel
    let evidence: UpcomingMeetingEvidence

    private var event: CalendarMeetingCandidate { evidence.event }
    private var extraContextCount: Int {
        max(0, evidence.decisions.count - 1)
            + max(0, evidence.commitments.count - 1)
            + max(0, evidence.projects.count - 1)
    }

    var body: some View {
        // The meeting row above already shows the title, time, people, and
        // Join/Record, so preparation context starts with the brief.
        VStack(alignment: .leading, spacing: 13) {
            brief
            primaryContext
            if extraContextCount > 0 {
                DisclosureGroup("More context") {
                    additionalContext
                        .padding(.top, 7)
                }
                .font(.callout)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: Brand.Radius.panel, style: .continuous)
                .fill(.quaternary.opacity(0.42)))
        .overlay(
            RoundedRectangle(cornerRadius: Brand.Radius.panel, style: .continuous)
                .strokeBorder(Brand.teal.opacity(0.18)))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("today.upcomingMeeting")
    }

    private var brief: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text("Brief").font(.headline)
                Spacer()
                if model.isGenerating(evidence) {
                    LoadingStateLabel("Preparing…", font: .caption)
                } else if evidence.hasPreparationContext {
                    Button {
                        Task { await model.generate(app: app, evidence: evidence) }
                    } label: {
                        Label(model.generatedByModel(for: evidence) ? "Refresh" : "Generate brief",
                              systemImage: model.generatedByModel(for: evidence)
                                  ? "arrow.clockwise" : "sparkles")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Brand.teal)
                    .disabled(
                        model.generatingSignature != nil
                            || !UpcomingMeetingLocalGenerationPolicy.permitsLocalGeneration(
                                settings: app.settings))
                    .help("Generate from these sources using the Think model on this Mac")
                    .accessibilityIdentifier("today.upcomingMeeting.generateBrief")
                }
            }
            Text(model.brief(for: evidence))
                .font(.callout)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .accessibilityIdentifier("today.upcomingMeeting.brief")
            if let generationError = model.generationError(for: evidence) {
                Label(generationError, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(Brand.error)
            }
        }
    }

    @ViewBuilder private var primaryContext: some View {
        if evidence.hasPreparationContext {
            Divider()
            VStack(alignment: .leading, spacing: 9) {
                if let decision = evidence.decisions.first {
                    referenceRow(
                        title: "Prior decision",
                        icon: "checkmark.seal",
                        reference: decision)
                }
                if let commitment = evidence.commitments.first {
                    referenceRow(
                        title: "Commitment to revisit",
                        icon: "checklist",
                        reference: commitment)
                }
                if let project = evidence.projects.first {
                    projectRow(project)
                }
                if evidence.decisions.isEmpty,
                   evidence.commitments.isEmpty,
                   evidence.projects.isEmpty,
                   let related = evidence.relatedMeetings.first {
                    Button {
                        app.openMeeting(related.meeting.id)
                    } label: {
                        contextRow(
                            title: "Recent context",
                            icon: "clock.arrow.circlepath",
                            text: related.meeting.title,
                            source: related.meeting.startedAt.formatted(
                                date: .abbreviated, time: .omitted))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var additionalContext: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(Array(evidence.decisions.dropFirst())) { reference in
                referenceRow(title: "Decision", icon: "checkmark.seal", reference: reference)
            }
            ForEach(Array(evidence.commitments.dropFirst())) { reference in
                referenceRow(title: "Commitment", icon: "checklist", reference: reference)
            }
            ForEach(Array(evidence.projects.dropFirst())) { project in
                projectRow(project)
            }
        }
    }

    private func referenceRow(title: String, icon: String,
                              reference: UpcomingMeetingReference) -> some View {
        var metadata: [String] = []
        if let owner = reference.owner, !owner.isEmpty {
            metadata.append(SpeakerDisplayName.label(
                owner,
                identity: reference.isForUser ? .user : .unresolved))
        }
        if let due = reference.due, !due.isEmpty { metadata.append("due \(due)") }
        if reference.sourceMeetingCount > 1 {
            metadata.append("\(reference.sourceMeetingCount) meetings")
        }
        let source = reference.meetingTitle
            + (metadata.isEmpty ? "" : " · \(metadata.joined(separator: " · "))")
        return Button {
            app.openMeeting(reference.meetingID)
        } label: {
            contextRow(title: title, icon: icon, text: reference.text, source: source)
        }
        .buttonStyle(.plain)
        .help("Open \(reference.meetingTitle)")
    }

    private func projectRow(_ project: UpcomingMeetingProjectContext) -> some View {
        contextRow(
            title: "Project context",
            icon: "folder",
            text: "\(project.name) — \(project.status)",
            source: "Active \(UpcomingMeetingPresentation.projectRecency(project.lastActiveDay))")
    }

    private func contextRow(title: String, icon: String,
                            text: String, source: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: icon)
                .frame(width: 18)
                .foregroundStyle(Brand.teal)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(text)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Text(source)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }
}

enum UpcomingMeetingPresentation {
    static func timeRange(_ event: CalendarMeetingCandidate) -> String {
        event.startDate.formatted(date: .omitted, time: .shortened)
            + "–" + event.endDate.formatted(date: .omitted, time: .shortened)
    }

    static func statusLabel(event: CalendarMeetingCandidate, now: Date) -> String {
        if event.endDate < now { return "Ended" }
        if event.startDate <= now { return "In progress" }
        let minutes = max(0, Int(event.startDate.timeIntervalSince(now) / 60))
        if minutes < 1 { return "Starting now" }
        if minutes < 60 { return "In \(minutes) min" }
        let hours = minutes / 60
        let remainder = minutes % 60
        return remainder == 0 ? "In \(hours)h" : "In \(hours)h \(remainder)m"
    }

    static func timeLabel(event: CalendarMeetingCandidate, now: Date,
                          calendar: Calendar = .current) -> String {
        let range = timeRange(event)
        if event.endDate < now { return range + " · Ended" }
        let status = statusLabel(event: event, now: now)
        if calendar.isDate(event.startDate, inSameDayAs: now) {
            return range + " · " + status
        }
        return event.startDate.formatted(date: .abbreviated, time: .shortened) + " · " + status
    }

    static func participantLabel(_ event: CalendarMeetingCandidate) -> String? {
        guard !event.participantNames.isEmpty else { return nil }
        let visible = event.participantNames.prefix(4).joined(separator: ", ")
        let remaining = event.participantNames.count - min(4, event.participantNames.count)
        return remaining > 0 ? visible + " +\(remaining)" : visible
    }

    static func projectRecency(_ dayKey: String) -> String {
        DreamDay.date(fromKey: dayKey)?.formatted(date: .abbreviated, time: .omitted)
            ?? dayKey
    }
}
