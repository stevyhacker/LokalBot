import SwiftUI

/// The Day digest page: the highlights in larger type, when they were
/// written, where the time went, the day strip, the digest's decisions and
/// tasks, and one line that opens the day's actions in place.
struct TimelineDigestPage: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var model: CaptureModel
    /// Reflects every digest run for the day, a scheduled one included, so a
    /// manual request cannot start a competing generation.
    @ObservedObject var lifecycle: DayDigestLifecycle
    let list: TimelineDayList
    let meetings: [Meeting]
    let presentation: DayDigestPresentation?
    let onSelectRow: (String) -> Void
    @State private var actionsOpen = false

    static let maxWidth: CGFloat = 800
    static var lead: AppFont { AppFont.scaledSystem(size: 15) }

    private var scheduledRun: Bool { lifecycle.isGenerating(on: model.day) && !model.generating }

    var body: some View {
        let state = TodayDigestLine.state(
            hasDigest: model.digest != nil, writtenAt: model.digestUpdatedAt,
            isStale: model.digestIsStale, isWriting: model.generating || scheduledRun)
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                lead(state)
                overview
                if let presentation, presentation.hasBodyBelowHighlights {
                    DayDigestView(presentation, mode: .timeline)
                        .environment(\.dayDigestProjects, projects)
                        .environment(\.dayDigestTimeRangeAction, DayDigestTimeRangeAction { range in
                            list.workRow(inTimeRange: range, day: model.day).map { row in { onSelectRow(row.id) } }
                        })
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("capture.dayDigest.text")
                }
                TimelineDayActionsLine(
                    threads: TimelineDayActions.threads(app.outcomeIndex.userActionThreads, on: model.day),
                    isOpen: $actionsOpen)
            }
            .padding(.horizontal, 40)
            .padding(.top, 30)
            .padding(.bottom, 48)
            .frame(maxWidth: Self.maxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .onChange(of: scheduledRun) { wasRunning, isRunning in
            // Show the scheduled result as soon as it is saved.
            if wasRunning, !isRunning { model.refreshOverview(app: app) }
        }
        .onChange(of: model.day) { actionsOpen = false }
    }

    /// Project names of the day, by lowercased name, so a task's project tag
    /// takes the colour its sessions have.
    private var projects: [String: String] {
        Dictionary(model.projectSplit.projects.map { ($0.project.lowercased(), $0.project) },
                   uniquingKeysWith: { first, _ in first })
    }

    // MARK: Highlights, or what stands in for them

    @ViewBuilder private func lead(_ state: TodayDigestLine) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let presentation, !presentation.atAGlanceMarkdown.isEmpty {
                SelectableDigestText(presentation.atAGlanceMarkdown, font: Self.lead)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("timeline.dayDigest.highlights")
            }
            switch state {
            case .missing:
                noDigest
            case .writing where model.digest == nil:
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 9) {
                        ProgressView().controlSize(.small)
                        Text("Writing this day's digest…")
                            .font(Self.lead.weight(.semibold))
                    }
                    Text("The day below is already up to date.")
                        .workspaceTextRole(.supporting)
                }
            case .writing:
                freshness {
                    ProgressView().controlSize(.small)
                    Text("Updating the digest with new activity…")
                }
            case .current(let writtenAt):
                if let writtenAt { freshness { written(writtenAt) } }
            case .stale(let writtenAt):
                freshness {
                    staleText(writtenAt)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("capture.dayDigest.stale")
                    Button("Update") { Task { await model.generateDigest(app: app) } }
                        .buttonStyle(.workspaceLink)
                        .accessibilityIdentifier("timeline.dayDigest.update")
                }
            }
            if let error = model.digestError {
                Label(error, systemImage: "exclamationmark.triangle").workspaceTextRole(.warning)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var noDigest: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No digest for this day yet")
                .font(Self.lead.weight(.semibold))
            Text(app.settings.dayDigestAutoEnabled
                 ? "LokalBot writes one each evening from the day's meetings and work."
                 : "Your digest brings together this day's meetings and captured activity.")
                .workspaceTextRole(.supporting)
                .fixedSize(horizontal: false, vertical: true)
            Button("Write Digest") { Task { await model.generateDigest(app: app) } }
                .buttonStyle(.bordered)
                .padding(.top, 6)
                .accessibilityIdentifier("timeline.dayDigest.generate")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("timeline.dayDigest.missing")
    }

    private func freshness<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) { content() }
            .font(AppFont.scaled(.callout))
            .foregroundStyle(.secondary)
    }

    /// The time alone on the day itself; the date too once it was written later.
    private func written(_ date: Date) -> Text {
        let sameDay = Calendar.current.isDate(date, inSameDayAs: model.day)
        return Text("Digest written \(date.formatted(date: sameDay ? .omitted : .abbreviated, time: .shortened))")
    }

    private func staleText(_ date: Date?) -> Text {
        guard let date else { return Text("New activity since") }
        return written(date) + Text(verbatim: " · ") + Text("New activity since")
    }

    // MARK: Where the time went

    @ViewBuilder private var overview: some View {
        let perApp = DayActivityOverview.perApp(model.blocks)
        let strip = TimelineDayStrip(rows: list.rows, day: model.day)
        if !perApp.isEmpty || !meetings.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                statLine(tracked: perApp.reduce(0) { $0 + $1.seconds })
                if let strip {
                    TimelineDayStripView(strip: strip, rows: list.rows, onSelectRow: onSelectRow)
                }
                legend(TimelineDayLegend.entries(perApp: perApp, split: model.projectSplit))
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("capture.dayOverview")
        }
    }

    /// "7h 54m tracked · 4 meetings · 4 PRs opened · 1 merged".
    private func statLine(tracked: TimeInterval) -> some View {
        let localize = app.settings.appLanguage.catalog
        var rest: [String] = []
        if !meetings.isEmpty {
            rest.append(String(format: localize(meetings.count == 1 ? "%lld meeting" : "%lld meetings"),
                               meetings.count))
        }
        rest += TimelineOutcomeWording.parts(model.dayOutcomes, localize: localize)
        return HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(verbatim: CaptureStyle.hm(tracked))
                .font(Self.lead.weight(.bold).monospacedDigit())
                .foregroundStyle(.primary)
            Text("tracked")
            if !rest.isEmpty {
                Text(verbatim: "· " + rest.joined(separator: " · "))
                    .accessibilityIdentifier("timeline.dayOutcomes")
            }
        }
        .font(AppFont.scaled(.body))
        .foregroundStyle(.secondary)
    }

    /// Each project's time, or each app's on a day without projects, then
    /// the meetings' total. App and project names are shown as captured.
    private func legend(_ entries: [TimelineDayLegend.Entry]) -> some View {
        let meetingSeconds = list.rows.filter(\.isMeeting).reduce(0) { $0 + $1.duration }
        return MeetingWrappingRow(spacing: 18, lineSpacing: 4) {
            ForEach(entries) { entry in
                HStack(spacing: 6) {
                    StatusDot(color: TimelineRowColor.color(for: entry.colorKey), size: 8)
                        .accessibilityHidden(true)
                    label(entry).lineLimit(1)
                    Text(verbatim: CaptureStyle.hm(entry.seconds))
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                }
            }
            if meetingSeconds > 0 {
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(LBTokens.Palette.accentFill)
                        .frame(width: 12, height: 4)
                        .accessibilityHidden(true)
                    Text("Meetings")
                    Text(verbatim: CaptureStyle.hm(meetingSeconds))
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .font(AppFont.scaled(.callout))
    }

    private func label(_ entry: TimelineDayLegend.Entry) -> Text {
        switch entry.kind {
        case .app, .otherApps, .project: Text(verbatim: entry.label)
        case .otherProjects: Text("Other projects")
        case .otherActivity: Text("Other activity")
        }
    }
}

extension DayDigestPresentation {
    /// Anything Timeline shows under the day strip.
    var hasBodyBelowHighlights: Bool {
        !blockers.isEmpty || !decisions.isEmpty || !focusBlocks.isEmpty || !followUps.isEmpty
    }
}

/// The day strip: hour lines and labels, a thin lane of meetings above the
/// lane of work. A bar selects its row in the list.
struct TimelineDayStripView: View {
    @Environment(\.appTextScale) private var textScale
    let strip: TimelineDayStrip
    let rows: [TimelineDayList.Row]
    let onSelectRow: (String) -> Void

    private static let meetingLaneHeight: CGFloat = 9
    private static let workLaneTop: CGFloat = 13
    private static let workLaneHeight: CGFloat = 20
    private static let labelTop: CGFloat = 37

    /// The lanes, then one line of hour labels at the current text size.
    private var height: CGFloat { Self.labelTop + (15 * max(1, textScale)).rounded(.up) }

    var body: some View {
        let height = height
        GeometryReader { geometry in
            let width = geometry.size.width
            // About one label every 44 points keeps "12 PM" clear of its neighbours.
            let labelWidth: CGFloat = 44 * max(1, textScale)
            let labelled = strip.labelledTicks(fitting: max(1, Int(width / labelWidth)))
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.primary.opacity(0.04))
                    .frame(width: width, height: Self.workLaneHeight)
                    .offset(y: Self.workLaneTop)
                ForEach(strip.ticks, id: \.date) { tick in
                    Rectangle()
                        .fill(Color.primary.opacity(0.07))
                        .frame(width: 1, height: Self.workLaneTop + Self.workLaneHeight)
                        .offset(x: CGFloat(tick.position) * width)
                }
                ForEach(labelled, id: \.date) { tick in
                    Text(tick.date, format: Self.hourStyle(namesDayPeriod: tick.namesDayPeriod))
                        .font(AppFont.scaled(.subheadline).monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .fixedSize()
                        .offset(x: CGFloat(tick.position) * width + 3, y: Self.labelTop)
                }
                ForEach(strip.meetings) { bar in
                    segment(bar, width: width, top: 0, height: Self.meetingLaneHeight,
                            color: LBTokens.Palette.accentFill)
                }
                ForEach(strip.work) { bar in
                    segment(bar, width: width, top: Self.workLaneTop, height: Self.workLaneHeight,
                            color: TimelineRowColor.color(for: bar.colorKey))
                }
            }
            .frame(width: width, height: height, alignment: .topLeading)
        }
        .frame(height: height)
        // Hours run left to right in every language, like a clock's day; the
        // bars are placed by offset, which does not mirror.
        .environment(\.layoutDirection, .leftToRight)
        // The list beside the page has the same rows, each with its name and
        // times, so assistive technologies read the strip as one picture.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Day chronology")
        .accessibilityIdentifier("timeline.dayStrip")
    }

    /// "8 AM" for the first hour and noon, "9" for the rest; a 24-hour clock
    /// shows the hour either way.
    private static func hourStyle(namesDayPeriod: Bool) -> Date.FormatStyle {
        let style = Date.FormatStyle.dateTime
        return namesDayPeriod ? style.hour() : style.hour(.defaultDigits(amPM: .omitted))
    }

    @ViewBuilder
    private func segment(_ bar: TimelineDayStrip.Bar, width: CGFloat, top: CGFloat,
                         height: CGFloat, color: Color) -> some View {
        let frame = TimelineDayStrip.frame(of: bar, in: width)
        let row = rows.first { $0.id == bar.id }
        Button { onSelectRow(bar.id) } label: {
            RoundedRectangle(cornerRadius: 3)
                .fill(color)
                .frame(width: max(1, frame.width - 1), height: height)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .offset(x: frame.x, y: top)
        .help(row.map { "\($0.title) · \(CaptureStyle.hm($0.duration))" } ?? "")
    }
}

/// One line for the user's actions from the day's meetings. It opens them in
/// place, as the shared action rows.
struct TimelineDayActionsLine: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let threads: [ActionThread]
    @Binding var isOpen: Bool

    var body: some View {
        if let summary = TimelineDayActions.summary(of: threads) {
            VStack(alignment: .leading, spacing: 0) {
                Divider()
                Button {
                    withAnimation(WorkspaceMotion.animation(.disclosure, reduceMotion: reduceMotion)) {
                        isOpen.toggle()
                    }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.circle")
                            .foregroundStyle(LBTokens.Palette.accentText)
                            .frame(width: 16)
                            .accessibilityHidden(true)
                        Text(verbatim: TimelineDayActions.label(summary, localize: app.settings.appLanguage.catalog))
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: "chevron.right")
                            .font(.scaled(.caption).weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(isOpen ? 90 : 0))
                            .accessibilityHidden(true)
                    }
                    .font(AppFont.scaled(.body))
                    .padding(.top, 12)
                    .padding(.bottom, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityValue(isOpen ? "Expanded" : "Collapsed")
                .accessibilityIdentifier("timeline.dayActions")
                if isOpen {
                    VStack(spacing: 0) {
                        ForEach(threads) { thread in
                            ActionThreadRow(thread: thread)
                            if thread.id != threads.last?.id { Divider() }
                        }
                    }
                    .padding(.leading, 26)
                    .transition(WorkspaceMotion.disclosureTransition(reduceMotion: reduceMotion))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
