import SwiftUI

/// One project's page. A tracked project leads with "Where it stands", the
/// only block a model wrote, marked with the sparkle and one line saying
/// when, by which model and where. Everything outside that card is a fact
/// from the library: your actions, what is waiting on others, decisions, and
/// the meetings with the line that names the project. Window time, people
/// and names sit in a side column. A suggestion opens on the decision
/// instead, and a project nothing names yet is one message.
struct ProjectDetailView: View {
    @EnvironmentObject var app: AppState
    let project: ProjectProfile
    @ObservedObject var store: ProjectStore
    /// A provisional page for a project tracked a moment ago.
    var isSettling = false
    /// For a suggestion: the tracked project that already has at least half
    /// of its meetings.
    var home: ProjectSuggestionHome.Match?
    let commands: ProjectCommands
    @State private var showsAllOthersActions = false
    @State private var showsAllMeetings = false

    private var localize: (String) -> String { app.settings.appLanguage.catalog }
    private var locale: Locale { PeopleWording.formattingLocale(app.settings.appLanguage.locale) }

    private var showsTime: Bool { project.trackedSeconds >= ProjectTimePresentation.minimumSeconds }
    private var hasSide: Bool { showsTime || !project.people.isEmpty || project.isTracked }

    var body: some View {
        Group {
            if project.isTracked && ProjectPagePresentation.isEmpty(project) {
                emptyProject
            } else {
                PageWithSideColumn(hasMain: true, hasSide: hasSide) {
                    if project.isTracked {
                        WhereItStandsCard(project: project, store: store, isSettling: isSettling)
                        myActions
                        othersActions
                        decisions
                        meetings(title: "Meetings")
                    } else {
                        ProjectSuggestionCard(project: project, home: home, store: store, commands: commands)
                        meetings(title: "Where it came up")
                    }
                } side: {
                    time
                    people
                    if project.isTracked { names }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("project.detail")
        .onAppear { if !isSettling { app.writeProjectSummary(for: project, automatic: true) } }
        .onChange(of: project) { _, updated in
            if !isSettling { app.writeProjectSummary(for: updated, automatic: true) }
        }
    }

    // MARK: - Nothing linked yet

    private var emptyProject: some View {
        VStack(spacing: 8) {
            Image(systemName: "folder")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.secondary)
                .padding(.bottom, 6)
                .accessibilityHidden(true)
            Text("Nothing mentions \(project.name) yet")
                .font(AppFont.scaled(.title2).weight(.semibold))
                .multilineTextAlignment(.center)
            Text("Meetings, actions and window titles that say “\(project.name)” will show up here. If the work goes by another name, like a codename or a client, add it.")
                .workspaceSupportingForeground()
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 390)
            Button("Add other names…") { commands.editNames(project) }
                .controlSize(.large)
                .padding(.top, 8)
                .accessibilityIdentifier("project.addOtherNames")
        }
        .padding(.horizontal, 48)
        .padding(.bottom, 60)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("project.empty")
    }

    // MARK: - Facts

    @ViewBuilder private var myActions: some View {
        if !project.myActions.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                PageSectionHeading(title: "Your actions", count: project.myActions.count)
                threadList(project.myActions, showsOwner: false)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("project.myActions")
        }
    }

    /// Other people's open work, recent first: three rows, then the rest on
    /// request.
    @ViewBuilder private var othersActions: some View {
        let threads = ProjectPagePresentation.othersActions(project)
        if !threads.isEmpty {
            let hidden = PeopleWording.hiddenCount(
                total: threads.count, visible: ProjectPagePresentation.visibleOthersActions)
            let shown = showsAllOthersActions
                ? threads : Array(threads.prefix(ProjectPagePresentation.visibleOthersActions))
            VStack(alignment: .leading, spacing: 0) {
                PageSectionHeading(title: "Waiting on others", count: threads.count)
                threadList(shown, showsOwner: true)
                if hidden > 0 {
                    Button(showsAllOthersActions ? "Show fewer" : "Show \(hidden) more") {
                        showsAllOthersActions.toggle()
                    }
                    .buttonStyle(.workspaceLink)
                    .font(AppFont.scaled(.callout))
                    .padding(.top, 4)
                    .accessibilityIdentifier("project.othersActions.more")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("project.othersActions")
        }
    }

    private func threadList(_ threads: [ActionThread], showsOwner: Bool) -> some View {
        VStack(spacing: 0) {
            ForEach(threads) { thread in
                ActionThreadRow(thread: thread, showsOwner: showsOwner)
                if thread.id != threads.last?.id { Divider() }
            }
        }
    }

    @ViewBuilder private var decisions: some View {
        if !project.decisions.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                PageSectionHeading(title: "Decisions", count: project.decisions.count)
                    .padding(.bottom, 4)
                ForEach(project.decisions) { decision in
                    let link = PeopleWording.meetingLink(
                        title: decision.meetingTitle, date: decision.meetingDate, locale: locale)
                    PageDecisionRow(text: decision.text, link: link, linkDescription: link, accentLink: true) {
                        app.openMeeting(decision.meetingID)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("project.decisions")
        }
    }

    /// Each meeting with the line that names the project, so it is clear why
    /// it is linked. A line from the transcript plays from its moment.
    @ViewBuilder private func meetings(title: LocalizedStringKey) -> some View {
        if !project.meetings.isEmpty {
            let hidden = PeopleWording.hiddenCount(
                total: project.meetings.count, visible: ProjectPagePresentation.visibleMeetings)
            let shown = showsAllMeetings
                ? project.meetings : Array(project.meetings.prefix(ProjectPagePresentation.visibleMeetings))
            VStack(alignment: .leading, spacing: 0) {
                PageSectionHeading(title: title, count: project.meetings.count)
                    .padding(.bottom, 2)
                ForEach(shown) { meeting in
                    ProjectMeetingRow(
                        meeting: meeting, locale: locale,
                        open: { app.openMeeting(meeting.id, seek: meeting.mention?.seek) },
                        play: { seek in app.openMeeting(meeting.id, seek: seek, intent: .play) })
                    if meeting.id != shown.last?.id { Divider() }
                }
                if hidden > 0 {
                    Button(showsAllMeetings ? "Show fewer" : "Show all \(project.meetings.count)") {
                        showsAllMeetings.toggle()
                    }
                    .buttonStyle(.workspaceLink)
                    .font(AppFont.scaled(.callout))
                    .padding(.top, 6)
                    .accessibilityIdentifier("project.meetings.more")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("project.meetings")
        }
    }

    // MARK: - Side column

    /// Window time over the days `ProjectLinks` measures: the total, a bar a
    /// day, and the longest windows.
    @ViewBuilder private var time: some View {
        if showsTime {
            let days = ProjectTimePresentation.days(project.days)
            SideColumnBlock(title: "Last 7 days") {
                Text(verbatim: ProjectsWording.duration(project.trackedSeconds, locale: locale))
                    .font(AppFont.scaledSystem(size: 22, weight: .semibold).monospacedDigit())
                    .accessibilityIdentifier("project.time.total")
                ProjectDayBars(days: days, locale: locale)
                    .padding(.top, 4)
                VStack(spacing: 0) {
                    let windows = Array(project.windows.prefix(ProjectTimePresentation.visibleWindows))
                    let rest = ProjectTimePresentation.rest(of: project)
                    ForEach(windows) { window in
                        ProjectTimeRow(title: window.app, detail: window.title,
                                       time: ProjectsWording.duration(window.seconds, locale: locale))
                        if window.id != windows.last?.id || rest != nil { Divider() }
                    }
                    if let rest {
                        ProjectTimeRow(title: ProjectsWording.moreWindows(rest.count, localize: localize), detail: "",
                                       time: ProjectsWording.duration(rest.seconds, locale: locale), isQuiet: true)
                    }
                }
            }
            .help(ProjectsWording.timeSource(for: project, localize: localize))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("project.time")
        }
    }

    @ViewBuilder private var people: some View {
        if !project.people.isEmpty {
            SideColumnBlock(title: "People") {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(project.people, id: \.self) { name in
                        ProjectPersonLink(name: name) {
                            if let person = app.connections.people.first(where: { $0.name == name }) {
                                app.openPerson(person.id)
                            }
                        }
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("project.people")
        }
    }

    /// The name and other names the project is matched by.
    private var names: some View {
        SideColumnBlock(title: "Names") {
            MeetingWrappingRow(spacing: 6, lineSpacing: 6) {
                ForEach([project.name] + project.otherNames, id: \.self) { name in
                    LabelChip(text: name, size: .small)
                }
            }
            Button("Edit names…") { commands.editNames(project) }
                .buttonStyle(.workspaceLink)
                .font(AppFont.scaled(.callout))
                .disabled(isSettling)
                .accessibilityIdentifier("project.editNames")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("project.names")
    }
}

/// The tracked project's "Where it stands" note, the only model-written
/// text on the page: overview, points with the meeting each comes from, and
/// open questions. Its heading says when it was written, by which model and
/// where that ran. A note whose evidence has changed stays, marked, until
/// the person updates it or an approved automatic update replaces it.
private struct WhereItStandsCard: View {
    @EnvironmentObject var app: AppState
    let project: ProjectProfile
    @ObservedObject var store: ProjectStore
    var isSettling = false

    private var trackedID: UUID? { project.trackedID }
    private var summary: ProjectStatusSummary? { trackedID.flatMap { store.summaries[$0] } }
    private var error: String? { trackedID.flatMap { store.errors[$0] } }
    private var evidence: ProjectStatusGenerator.Evidence { ProjectStatusGenerator.evidence(for: project) }
    private var localize: (String) -> String { app.settings.appLanguage.catalog }
    private var locale: Locale { PeopleWording.formattingLocale(app.settings.appLanguage.locale) }

    var body: some View {
        let evidence = self.evidence
        let isWriting = trackedID.map { store.writing.contains($0) } ?? false
        // A project tracked a moment ago starts its note as soon as its
        // evidence arrives, when automatic writing is allowed.
        let writing = isWriting || (isSettling && !evidence.isEmpty && app.writesProjectSummariesAutomatically)
        VStack(alignment: .leading, spacing: 10) {
            heading(writing: writing, canWrite: !evidence.isEmpty && !isSettling)
            if let summary {
                if store.summaryState(for: project) == .outdated {
                    Text("Newer evidence since this was written.")
                        .font(AppFont.scaled(.callout))
                        .foregroundStyle(LBTokens.Palette.attentionText)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("project.summary.stale")
                }
                // The note being replaced stays readable while the new one
                // is written.
                ProjectNoteText(summary: summary, locale: locale, localize: localize)
                    .opacity(writing ? 0.5 : 1)
            } else if writing {
                LoadingStateLabel(
                    ProjectsWording.writing(meetings: evidence.meetings.count,
                                            hasReviewNotes: !evidence.reviewNotes.isEmpty, localize: localize),
                    font: AppFont.scaled(.body))
            } else if !evidence.isEmpty {
                Text("No note yet.")
                    .workspaceSupportingForeground()
            } else {
                Text("Nothing names this project yet. A note can be written once meetings or overnight reviews mention it.")
                    .workspaceSupportingForeground()
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error {
                Text(verbatim: error)
                    .font(AppFont.scaled(.callout))
                    .foregroundStyle(LBTokens.Palette.attentionText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 13)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .todayCardSurface()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("project.summary")
    }

    /// The sparkle and title, then who wrote the note and the button. The
    /// provenance moves under the title when the card is too narrow for one
    /// line.
    private func heading(writing: Bool, canWrite: Bool) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                title
                Spacer(minLength: 12)
                provenance.lineLimit(1)
                control(writing: writing, canWrite: canWrite)
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    title
                    Spacer(minLength: 12)
                    control(writing: writing, canWrite: canWrite)
                }
                provenance.fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(minHeight: 24)
    }

    private var title: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: "sparkles")
                .font(.scaled(.callout))
                .foregroundStyle(LBTokens.Palette.accentText)
                .accessibilityLabel("Written by a model")
            Text("Where it stands")
                .font(LBTokens.Typography.section)
                .fixedSize()
        }
    }

    /// Always from the saved note: when it was written, the model's name,
    /// and this Mac or the server it ran on.
    @ViewBuilder private var provenance: some View {
        if let summary {
            Text(verbatim: ProjectsWording.provenance(summary, locale: locale, localize: localize))
                .font(AppFont.scaled(.callout).monospacedDigit())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .accessibilityIdentifier("project.summary.provenance")
        }
    }

    @ViewBuilder private func control(writing: Bool, canWrite: Bool) -> some View {
        if writing {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                if summary != nil {
                    Text("Updating…")
                        .font(AppFont.scaled(.callout))
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
            }
        } else if isSettling {
            ProgressView().controlSize(.small)
        } else if canWrite {
            Button(summary == nil ? "Write note" : "Update") {
                app.writeProjectSummary(for: project, automatic: false)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .fixedSize()
            .accessibilityIdentifier("project.summary.write")
        }
    }
}

/// The note's text. Each point ends with the meeting it comes from as a
/// link; a point from the overnight review says so and links nowhere.
private struct ProjectNoteText: View {
    @EnvironmentObject var app: AppState
    let summary: ProjectStatusSummary
    let locale: Locale
    let localize: (String) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(verbatim: summary.overview)
                .font(AppFont.scaledSystem(size: 15))
                .lineSpacing(3)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 2)
            ForEach(summary.points) { point in
                bulleted(Text(pointText(point)))
            }
            if !summary.openQuestions.isEmpty {
                Text(summary.openQuestions.count == 1 ? "Open question" : "Open questions")
                    .font(AppFont.scaled(.callout).weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
                ForEach(summary.openQuestions, id: \.self) { question in
                    bulleted(Text(verbatim: question))
                }
            }
        }
        .tint(LBTokens.Palette.accentText)
        .environment(\.openURL, OpenURLAction { url in
            guard let meetingID = ProjectNoteLink.meetingID(from: url) else { return .systemAction }
            app.openMeeting(meetingID)
            return .handled
        })
    }

    private func bulleted(_ text: Text) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verbatim: "•")
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            text
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func pointText(_ point: ProjectStatusSummary.Point) -> AttributedString {
        var text = AttributedString(point.text + "  ")
        if let meetingID = point.meetingID, let title = point.meetingTitle {
            var citation = AttributedString(point.meetingDate.map {
                PeopleWording.meetingLink(title: title, date: $0, locale: locale)
            } ?? title)
            citation.link = ProjectNoteLink.url(meetingID: meetingID)
            text.append(citation)
        } else {
            var citation = AttributedString(localize("Overnight review"))
            citation.swiftUI.foregroundColor = .secondary
            text.append(citation)
        }
        return text
    }
}

/// A suggestion's page opens on the decision: where it came up, then the
/// answers. When a tracked project already has at least half of its
/// meetings, adding it there is the first answer; otherwise tracking is.
private struct ProjectSuggestionCard: View {
    @EnvironmentObject var app: AppState
    let project: ProjectProfile
    let home: ProjectSuggestionHome.Match?
    @ObservedObject var store: ProjectStore
    let commands: ProjectCommands

    private var localize: (String) -> String { app.settings.appLanguage.catalog }
    private var locale: Locale { PeopleWording.formattingLocale(app.settings.appLanguage.locale) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(verbatim: ProjectsWording.suggestionTitle(for: project, locale: locale, localize: localize))
                .font(AppFont.scaled(.title3).weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            if project.kind == .suggestedReview {
                ForEach(project.reviewNotes) { note in
                    reviewNote(note)
                }
            }
            Text(verbatim: ProjectsWording.suggestionReason(home: home, localize: localize))
                .workspaceSupportingForeground()
                .fixedSize(horizontal: false, vertical: true)
            MeetingWrappingRow(spacing: 8, lineSpacing: 8) {
                answers
            }
            .controlSize(.large)
            .padding(.top, 4)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .todayCardSurface()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("project.suggestion")
    }

    /// The overnight review's own words, which a model wrote, so they carry
    /// the sparkle too.
    private func reviewNote(_ note: ProjectProfile.ReviewNote) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "sparkles")
                .font(.scaled(.callout))
                .foregroundStyle(LBTokens.Palette.accentText)
                .accessibilityLabel("Written by a model")
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: note.status)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Text(verbatim: ProjectsWording.reviewCitation(
                    dayKey: note.lastActiveDay, locale: locale, localize: localize))
                    .font(AppFont.scaled(.callout))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LBTokens.Palette.groupFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    @ViewBuilder private var answers: some View {
        if let home {
            Button("Add to \(home.name)") { commands.add(project, home.trackedID) }
                .primaryActionButton()
                .accessibilityIdentifier("project.addToHome")
            Button("Track as its own project") { commands.track(project) }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("project.track")
        } else {
            Button("Track") { commands.track(project) }
                .primaryActionButton()
                .accessibilityIdentifier("project.track")
            if !store.curation.tracked.isEmpty {
                Menu("Add to a project") {
                    ForEach(store.curation.tracked) { target in
                        Button {
                            commands.add(project, target.id)
                        } label: {
                            Text(verbatim: target.name)
                        }
                    }
                }
                .fixedSize()
                .accessibilityIdentifier("project.addTo")
            }
        }
        Button("Not a project") { commands.hide(project) }
            .buttonStyle(.borderless)
            .accessibilityIdentifier("project.hide")
    }
}

/// A meeting that names the project, with the line that does. The row opens
/// the meeting; a line from the transcript also plays from its moment.
private struct ProjectMeetingRow: View {
    let meeting: ProjectProfile.MeetingRef
    let locale: Locale
    let open: () -> Void
    let play: (TimeInterval) -> Void
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button(action: open) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: meeting.title)
                        .lineLimit(1)
                        .underline(hovering)
                    if let mention = meeting.mention {
                        Text(verbatim: mention.text)
                            .font(AppFont.scaled(.callout))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help(meeting.mention?.text ?? meeting.title)
            VStack(alignment: .trailing, spacing: 0) {
                Text(verbatim: PeopleWording.shortDate(meeting.startedAt, locale: locale))
                    .font(AppFont.scaled(.callout).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let mention = meeting.mention, let seek = mention.seek {
                    MeetingPlayTimeButton(time: seek, excerpt: mention.text) { play(seek) }
                        .padding(.trailing, -4)
                }
            }
            .fixedSize()
        }
        .padding(.vertical, 7)
    }
}

/// A bar for each of the last seven days, today's in the full accent. A day
/// without time keeps a hairline, so the week reads as seven days.
private struct ProjectDayBars: View {
    let days: [ProjectTimePresentation.Day]
    let locale: Locale

    private static let barHeight: CGFloat = 46

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            ForEach(days) { day in
                VStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(Brand.teal.opacity(day.isToday ? 1 : 0.4))
                        .frame(height: max(2, Self.barHeight * ProjectTimePresentation.fraction(day, in: days)))
                        .frame(maxWidth: 20)
                    Text(verbatim: ProjectsWording.weekdayLetter(day.date, locale: locale))
                        .font(AppFont.scaled(.caption2))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .help(ProjectsWording.dayTime(day, locale: locale))
            }
        }
        .frame(maxWidth: .infinity, alignment: .bottom)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Last 7 days")
        .accessibilityValue(Text(verbatim: days.map { ProjectsWording.dayTime($0, locale: locale) }
            .joined(separator: ", ")))
        .accessibilityIdentifier("project.time.days")
    }
}

/// A window and its time, or the line that sums the windows not listed.
private struct ProjectTimeRow: View {
    let title: String
    let detail: String
    let time: String
    var isQuiet = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: title)
                    .font(AppFont.scaled(isQuiet ? .callout : .body))
                    .foregroundStyle(isQuiet ? .secondary : .primary)
                    .lineLimit(1)
                if !detail.isEmpty {
                    Text(verbatim: detail)
                        .font(AppFont.scaled(.callout))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(verbatim: time)
                .font(AppFont.scaled(.callout).monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .layoutPriority(1)
        }
        .padding(.vertical, 5)
        .accessibilityElement(children: .combine)
    }
}

/// Someone from the project's meetings, opening their page.
private struct ProjectPersonLink: View {
    let name: String
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 8) {
                InitialsAvatar(name: name, size: 22)
                Text(verbatim: name)
                    .lineLimit(1)
                    .underline(hovering)
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
