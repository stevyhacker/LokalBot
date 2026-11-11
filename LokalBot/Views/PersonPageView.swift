import SwiftUI

/// One person's page. The next calendar meeting with them leads when there
/// is one, then what is open between you, what the last meeting said, and
/// what you decided together. Projects, meetings and other names sit in a
/// side column, so a long history fits one screen and someone met once has a
/// short page. A section with nothing in it is not shown.
struct PersonDetailView: View {
    @EnvironmentObject var app: AppState
    let person: PersonProfile
    /// The next calendar meeting with the person in the coming week. Nil
    /// without Calendar access, and then the page starts with open work.
    var nextMeeting: PersonUpcomingMeeting?
    @State private var showsAllDecisions = false
    @State private var showsAllSeries = false

    private var localize: (String) -> String { app.settings.appLanguage.catalog }
    private var locale: Locale { PeopleWording.formattingLocale(app.settings.appLanguage.locale) }

    private var notes: PersonProfile.RecentNotes? {
        person.recentNotes.flatMap { $0.points.isEmpty ? nil : $0 }
    }

    private var hasMain: Bool {
        nextMeeting != nil || person.openCount > 0 || notes != nil || !person.decisions.isEmpty
    }

    private var hasSide: Bool {
        !person.projects.isEmpty || !person.series.isEmpty || !person.otherNames.isEmpty
    }

    var body: some View {
        PageWithSideColumn(hasMain: hasMain, hasSide: hasSide) {
            if let nextMeeting {
                PersonNextMeetingCard(meeting: nextMeeting, now: Date()) {
                    app.openAgent(PersonPreparation.launchContext(for: person))
                }
            }
            openWork
            lastTime
            decisions
        } side: {
            projects
            meetings
            names
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("person.detail")
    }

    /// "today", "yesterday", "3 days ago", then a date.
    static func relativeDay(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date),
                                           to: calendar.startOfDay(for: now)).day ?? 0
        switch days {
        case ..<1: return "today"
        case 1: return "yesterday"
        case 2...6: return "\(days) days ago"
        default: return date.formatted(.dateTime.month(.abbreviated).day())
        }
    }

    // MARK: - Open work

    /// One section, two labelled parts: what the user owes, then what the
    /// person owes. Stale work keeps its "Still open?" line.
    @ViewBuilder private var openWork: some View {
        if person.openCount > 0 {
            VStack(alignment: .leading, spacing: 0) {
                PageSectionHeading(title: "Open between you", count: person.openCount)
                    .padding(.bottom, 6)
                if !person.myActions.isEmpty {
                    owed(String(format: localize("You owe %@"), person.firstName), attention: true,
                         threads: person.myActions, identifier: "person.youOwe")
                }
                if !person.theirActions.isEmpty {
                    owed(String(format: localize("%@ owes you"), person.firstName), attention: false,
                         threads: person.theirActions, identifier: "person.owesYou")
                        .padding(.top, person.myActions.isEmpty ? 0 : 10)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("person.openWork")
        }
    }

    private func owed(_ label: String, attention: Bool, threads: [ActionThread], identifier: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            LabelChip(text: label, attention: attention)
                .padding(.vertical, 2)
                .accessibilityIdentifier(identifier)
            ForEach(threads) { thread in
                ActionThreadRow(thread: thread, showsStaleness: true, playsEvidence: true)
            }
        }
    }

    // MARK: - Last time

    @ViewBuilder private var lastTime: some View {
        if let notes {
            VStack(alignment: .leading, spacing: 9) {
                PageSectionHeading(title: notes.isLatestMeeting ? "Last time" : "Last mentioned") {
                    Button {
                        app.openMeeting(notes.meetingID)
                    } label: {
                        Text(verbatim: PeopleWording.meetingLink(
                            title: notes.meetingTitle, date: notes.meetingDate, locale: locale))
                            .lineLimit(1)
                    }
                    .buttonStyle(.workspaceLink)
                    .font(AppFont.scaled(.callout))
                    .accessibilityIdentifier("person.lastTime.meeting")
                }
                ForEach(notes.points.prefix(PersonNotes.maximumPoints)) { point in
                    NotePointRow(point: point) { seek in
                        app.openMeeting(point.meetingID, seek: seek, intent: .play)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("person.lastTime")
        }
    }

    // MARK: - Decisions

    @ViewBuilder private var decisions: some View {
        if !person.decisions.isEmpty {
            let hidden = PeopleWording.hiddenCount(
                total: person.decisions.count, visible: PeopleWording.visibleDecisions)
            let shown = showsAllDecisions
                ? person.decisions : Array(person.decisions.prefix(PeopleWording.visibleDecisions))
            VStack(alignment: .leading, spacing: 2) {
                PageSectionHeading(title: "Decided together", count: person.decisions.count)
                    .padding(.bottom, 4)
                ForEach(shown) { decision in
                    DecisionTogetherRow(decision: decision, locale: locale) {
                        app.openMeeting(decision.meetingID)
                    }
                }
                if hidden > 0 {
                    Button(showsAllDecisions ? "Show fewer" : "Show \(hidden) more") {
                        showsAllDecisions.toggle()
                    }
                    .buttonStyle(.workspaceLink)
                    .font(AppFont.scaled(.callout))
                    .padding(.leading, 24)
                    .padding(.top, 4)
                    .accessibilityIdentifier("person.decisions.more")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("person.decisions")
        }
    }

    // MARK: - Side column

    @ViewBuilder private var projects: some View {
        if !person.projects.isEmpty {
            SideColumnBlock(title: "Projects") {
                ForEach(person.projects) { project in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Button {
                            app.openProject(project.id)
                        } label: {
                            Text(verbatim: project.name).lineLimit(1)
                        }
                        .buttonStyle(.workspaceLink)
                        if !project.isTracked {
                            Text("suggested")
                                .font(AppFont.scaled(.callout))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .help("Named \(project.mentions) time\(project.mentions == 1 ? "" : "s") around \(person.firstName)")
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("person.projects")
        }
    }

    @ViewBuilder private var meetings: some View {
        let series = person.series
        if !series.isEmpty {
            let hidden = PeopleWording.hiddenCount(total: series.count, visible: PeopleWording.visibleSeries)
            let shown = showsAllSeries ? series : Array(series.prefix(PeopleWording.visibleSeries))
            SideColumnBlock(title: "Meetings", count: person.meetingCount) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(shown) { item in
                        MeetingSeriesRow(series: item, locale: locale, localize: localize) { app.openMeeting($0) }
                    }
                }
                if hidden > 0 {
                    Button(showsAllSeries ? "Show fewer" : "Show \(hidden) more") {
                        showsAllSeries.toggle()
                    }
                    .buttonStyle(.workspaceLink)
                    .font(AppFont.scaled(.callout))
                    .accessibilityIdentifier("person.meetings.more")
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("person.meetings")
        }
    }

    @ViewBuilder private var names: some View {
        if !person.otherNames.isEmpty {
            SideColumnBlock(title: "Names") {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Image(systemName: "person")
                        .font(.scaled(.callout))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text("Also appears as \(person.otherNames.joined(separator: ", "))")
                        .font(AppFont.scaled(.callout))
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("person.names")
        }
    }
}

/// The next calendar meeting with the person: when, its title, who else is
/// invited, and Prepare, which hands the person's notes and open work to
/// Agent.
private struct PersonNextMeetingCard: View {
    @EnvironmentObject private var app: AppState
    let meeting: PersonUpcomingMeeting
    let now: Date
    let onPrepare: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 16) {
                summary
                Spacer(minLength: 8)
                prepare.fixedSize()
            }
            VStack(alignment: .leading, spacing: 12) {
                summary
                prepare
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .todayCardSurface()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("person.nextMeeting")
    }

    private var summary: some View {
        let language = app.settings.appLanguage
        return VStack(alignment: .leading, spacing: 3) {
            Text(verbatim: PeopleWording.nextMeetingLine(
                meeting, now: now, locale: PeopleWording.formattingLocale(language.locale), localize: language.catalog))
                .font(AppFont.scaled(.callout).weight(.semibold).monospacedDigit())
                .foregroundStyle(LBTokens.Palette.accentText)
            Text(verbatim: meeting.title)
                .font(TodayType.cardTitleCompact)
                .lineLimit(1)
                .textSelection(.enabled)
            Text(verbatim: PeopleWording.invited(meeting.others, localize: language.catalog))
                .font(AppFont.scaled(.callout))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }

    private var prepare: some View {
        Button(action: onPrepare) {
            Label("Prepare", systemImage: "wand.and.sparkles")
        }
        .primaryActionButton()
        .controlSize(.large)
        .help("Prepare in Agent…")
        .accessibilityIdentifier("person.prepare")
    }
}

/// One line from meeting notes, with who said it when that is not the
/// person, and the moment in the call, which plays from there.
private struct NotePointRow: View {
    let point: PersonProfile.NotePoint
    let open: (TimeInterval?) -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Group {
                if let speaker = point.speaker {
                    Text("\(Text(speaker).fontWeight(.semibold)): \(point.text)")
                } else {
                    Text(point.text)
                }
            }
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            if let seek = point.seek {
                MeetingPlayTimeButton(time: seek) { open(seek) }
            }
        }
    }
}

/// A decision with the meeting it was made in.
private struct DecisionTogetherRow: View {
    let decision: PersonProfile.DecisionRef
    let locale: Locale
    let open: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "checkmark.circle")
                .foregroundStyle(LBTokens.Palette.successText)
                .frame(width: 16)
                .accessibilityHidden(true)
            Text(decision.text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: open) {
                Text(verbatim: decision.meetingTitle)
                    .font(AppFont.scaled(.callout))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .workspaceSupportingForeground()
            }
            .buttonStyle(.plain)
            // As wide as the title, up to a cap; the decision takes the rest.
            .frame(maxWidth: 200, alignment: .trailing)
            .fixedSize(horizontal: true, vertical: false)
            .help(PeopleWording.meetingLink(title: decision.meetingTitle, date: decision.meetingDate, locale: locale))
            .accessibilityLabel(Text(verbatim: PeopleWording.meetingLink(
                title: decision.meetingTitle, date: decision.meetingDate, locale: locale)))
        }
        .padding(.vertical, 4)
    }
}

/// A meeting title in the side column: a single meeting opens, and a series
/// opens to list each date. A call recorded in parts is one meeting that
/// opens its longest recording.
private struct MeetingSeriesRow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let series: PersonProfile.Series
    let locale: Locale
    let localize: (String) -> String
    let open: (UUID) -> Void
    @State private var expanded = false

    var body: some View {
        let detail = PeopleWording.seriesDetail(series, locale: locale, localize: localize)
        if series.occasions.count == 1 {
            MeetingLinkRow(title: series.title, detail: joined(detail, recordingsNote(series.latest))) {
                open(series.latest.primary.id)
            }
        } else {
            VStack(spacing: 0) {
                MeetingLinkRow(title: series.title, detail: detail,
                               disclosure: expanded ? .expanded : .collapsed) {
                    withAnimation(WorkspaceMotion.animation(.disclosure, reduceMotion: reduceMotion)) {
                        expanded.toggle()
                    }
                }
                .accessibilityValue(expanded ? "Expanded" : "Collapsed")
                .accessibilityHint(expanded ? "Hides the dates" : "Shows each date")
                if expanded {
                    ForEach(series.occasions) { occasion in
                        MeetingLinkRow(
                            title: occasion.startedAt.formatted(
                                Date.FormatStyle(locale: locale).weekday(.abbreviated).month(.abbreviated).day()),
                            detail: recordingsNote(occasion), indented: true) {
                            open(occasion.primary.id)
                        }
                    }
                }
            }
        }
    }

    private func recordingsNote(_ occasion: PersonProfile.Occasion) -> String? {
        occasion.recordings.count > 1 ? "\(occasion.recordings.count) recordings" : nil
    }

    private func joined(_ first: String, _ second: String?) -> String {
        second.map { first + " · " + $0 } ?? first
    }
}

private struct MeetingLinkRow: View {
    enum Disclosure { case none, collapsed, expanded }

    let title: String
    let detail: String?
    var disclosure: Disclosure = .none
    var indented = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: title).lineLimit(1)
                    if let detail {
                        Text(verbatim: detail)
                            .font(AppFont.scaled(.callout).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.forward")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(disclosure == .none ? .tertiary : .secondary)
                    .rotationEffect(.degrees(disclosure == .expanded ? 90 : 0))
                    .opacity(disclosure == .none && !hovering ? 0.6 : 1)
                    .accessibilityHidden(true)
            }
            .padding(.leading, indented ? 12 : 0)
            .padding(.vertical, 5)
            .padding(.horizontal, 6)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(hovering ? 0.06 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .padding(.horizontal, -6)
    }
}
