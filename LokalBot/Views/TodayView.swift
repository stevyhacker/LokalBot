import Combine
import SwiftUI

/// The home screen answers three things: what is live, what is next, and what
/// needs you. A card leads only while it matters (a recording in progress, a
/// meeting within the hour); the rest is the day's actions, meetings and
/// activity, each in its own panel, in two columns when the window has room.
/// Timeline stays the hour-by-hour view of the same day.
struct TodayView: View {
    @EnvironmentObject var app: AppState
    @StateObject private var model = CaptureModel()
    @StateObject private var upcomingMeeting = UpcomingMeetingPreparationModel()
    @State private var dream: DreamReport?
    @State private var recaps: [Meeting.ID: String] = [:]
    /// False until the day's activity has loaded once, so an empty page is
    /// not mistaken for a first day while it loads.
    @State private var dayLoaded = false
    @AppStorage("lokalbotv3.gettingStartedDismissed")
    private var gettingStartedDismissed = false
    @Environment(\.appTextScale) private var textScale

    private static let attentionLimit = 3

    /// The recording in progress leads, so it is found even before the
    /// library lists it.
    private var recordings: [Meeting] {
        (app.currentMeeting.map { [$0] } ?? []) + app.meetings
    }

    var body: some View {
        ScrollView {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                page(now: context.date)
                    .frame(maxWidth: .infinity, alignment: .top)
                    // The marker tests wait for before they use the window.
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("today.header")
            }
        }
        .navigationTitle("Today")
        .navigationSubtitle(Date().formatted(date: .complete, time: .omitted))
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { app.openAsk(dayScope: model.day) } label: {
                    Label("Ask About Today", systemImage: "sparkle.magnifyingglass")
                }
                .labelStyle(.titleAndIcon)
                .accessibilityIdentifier("today.askDay")
                // The page has no recording bar: Record lives here, and the
                // live card holds the only Stop.
                Button {
                    app.startRecording(context: app.recordingContext(for: app.detector.activeApp))
                } label: {
                    Label {
                        Text("Record")
                    } icon: {
                        Image(systemName: "circle.fill")
                            .foregroundStyle(LBTokens.Palette.recording)
                    }
                }
                .labelStyle(.titleAndIcon)
                .disabled(app.isRecording)
                .help("Record Now")
                .accessibilityIdentifier("today.record")
            }
        }
        .overlay(alignment: .topTrailing) {
            if model.overviewLoading { ProgressView().controlSize(.small).padding(12) }
        }
        .task(id: app.navSection) {
            guard app.navSection == .today else { return }
            reloadCurrentDay(at: Date())
            app.refreshDreamMemory()
            while !Task.isCancelled {
                await upcomingMeeting.refresh(app: app)
                await refreshRecaps()
                do {
                    try await Task.sleep(for: .seconds(30))
                } catch {
                    return
                }
                if !Calendar.current.isDateInToday(model.day) {
                    reloadCurrentDay(at: Date())
                } else if !model.generating {
                    model.refreshOverview(app: app)
                }
            }
        }
        .task(id: app.outcomeIndex.openUserActionThreads.map(\.id)) {
            app.refreshActionCompletionHints()
        }
        .task(id: finishedRecordingIDs) {
            await refreshRecaps()
        }
        // The publisher reports every change, also when a fast load starts
        // and ends between two renders.
        .onReceive(model.$overviewLoading.removeDuplicates().dropFirst()) { loading in
            if !loading, !dayLoaded { dayLoaded = true }
        }
        .onChange(of: app.latestDreamReport) { _, _ in
            guard app.navSection == .today else { return }
            // A report normally arrives after midnight while this view may
            // have remained mounted since yesterday. Re-anchor every section,
            // not just the dream card, before selecting the new report.
            reloadCurrentDay(at: Date())
        }
        .onChange(of: app.libraryReady) { _, ready in
            guard ready, app.navSection == .today else { return }
            Task { await upcomingMeeting.refresh(app: app) }
        }
        .onChange(of: app.settings.calendarDetectionEnabled) { _, _ in
            guard app.navSection == .today else { return }
            Task { await upcomingMeeting.refresh(app: app) }
        }
        .onChange(of: app.calendar.authorizationStatus) { _, _ in
            guard app.navSection == .today else { return }
            Task { await upcomingMeeting.refresh(app: app) }
        }
        .onChange(of: app.currentMeeting?.calendarEventID) { _, _ in
            guard app.navSection == .today else { return }
            Task { await upcomingMeeting.refresh(app: app) }
        }
    }

    // MARK: Page

    @ViewBuilder private func page(now: Date) -> some View {
        let recordings = recordings
        let threads = ActionAttentionOrder.sorted(app.outcomeIndex.openUserActionThreads)
        let events = upcomingMeeting.status == .ready ? upcomingMeeting.meetingsToday : []
        let entries = TodayAgenda.entries(
            recordings: recordings, events: events, liveMeetingID: app.currentMeeting?.id, now: now)
        let next = TodayAgenda.nextMeeting(
            in: events, now: now, recordedEventIDs: TodayAgenda.recordedEventIDs(in: recordings))
        let hasDay = !model.blocks.isEmpty || model.digest != nil || model.generating
            || entries.contains { $0.status == .recorded }
        let hasContent = app.currentMeeting != nil || next != nil || !threads.isEmpty
            || !entries.isEmpty || hasDay || dream != nil
        let layout = TodayPageLayout.layout(
            hasContent: hasContent, gettingStartedDismissed: gettingStartedDismissed)

        let showsMeetings = !entries.isEmpty || calendarIsOff
        // The panels each column would hold. A side with none leaves the
        // page one column at its reading width.
        let hasLeading = layout.showsSections && (!threads.isEmpty || showsMeetings)
        let hasTrailing = layout.showsSections && (hasDay || dream != nil)

        TodayColumnsLayout(textScale: textScale) {
            switch layout {
            case .sections(let gettingStartedBelow):
                if app.currentMeeting != nil || next != nil {
                    VStack(spacing: 10) {
                        if let live = app.currentMeeting { TodayLiveCard(meeting: live) }
                        if let next { TodayNextMeetingCard(model: upcomingMeeting, event: next, now: now) }
                    }
                }
                if !threads.isEmpty {
                    NeedsAttentionSection(threads: threads, limit: Self.attentionLimit, now: now)
                        .todayColumn(.leading)
                }
                if showsMeetings {
                    TodayMeetingsSection(
                        rows: TodayAgenda.rows(entries, now: now),
                        count: entries.count,
                        recaps: recaps,
                        offersCalendar: calendarIsOff)
                        .todayColumn(.leading)
                }
                if hasDay {
                    TodaySoFarSection(model: model, lifecycle: app.dayDigest)
                        .todayColumn(.trailing)
                }
                if let dream {
                    YesterdayBriefPanel(report: dream, day: model.day)
                        .todayColumn(.trailing)
                }
                if gettingStartedBelow { GettingStartedCard() }
            case .gettingStarted:
                if isSettled { GettingStartedCard() }
            case .placeholder:
                if isSettled {
                    Text("Meetings, actions and your day show up here.")
                        .font(AppFont.scaled(.body))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 120)
                        .accessibilityIdentifier("today.empty")
                }
            }
        }
        .padding(.horizontal, LBTokens.Metric.detailPadding)
        .padding(.top, 16)
        .padding(.bottom, 32)
        .frame(
            maxWidth: TodayColumns.pageMaximumWidth(
                hasLeading: hasLeading, hasTrailing: hasTrailing,
                wide: WorkspaceMetric.todayMaxWidth, reading: WorkspaceMetric.todayReadingMaxWidth),
            alignment: .leading)
    }

    /// The library and the day's activity have both answered, so "nothing
    /// yet" is a fact and not a page still loading.
    private var isSettled: Bool { dayLoaded && app.libraryReady }

    /// Calendar use is off, or macOS has not granted access to it.
    private var calendarIsOff: Bool {
        switch upcomingMeeting.status {
        case .disabled, .permissionRequired, .permissionDenied: true
        case .loading, .noMeetingsToday, .ready: false
        }
    }

    // MARK: Loading

    private var finishedRecordingIDs: [Meeting.ID] {
        let calendar = Calendar.current
        return app.meetings
            .filter { $0.endedAt != nil && calendar.isDateInToday($0.startedAt) }
            .map(\.id)
    }

    /// One line per finished recording from the summary saved beside it.
    private func refreshRecaps() async {
        let calendar = Calendar.current
        let finished = app.meetings.filter {
            $0.isOwnWork && $0.endedAt != nil && calendar.isDateInToday($0.startedAt)
        }
        guard !finished.isEmpty else {
            if !recaps.isEmpty { recaps = [:] }
            return
        }
        let root = app.storage.rootURL
        let loaded = await Task.detached(priority: .utility) {
            TodayMeetingRecap.lines(for: finished, root: root)
        }.value
        guard !Task.isCancelled else { return }
        if loaded != recaps { recaps = loaded }
    }

    // Keep the previous-workday summary anchored to the selected date.
    private func reloadCurrentDay(at date: Date) {
        model.selectDay(date, app: app)
        dream = TodayDreamSelection.report(
            referenceDate: date,
            latest: app.latestDreamReport,
            store: app.dreamStore)
    }
}

/// Type sizes Today adds to the shared set: panel titles one step above the
/// 13 pt headline, and the title of the card at the top.
enum TodayType {
    static var panelTitle: AppFont { AppFont.scaledSystem(size: 14, weight: .bold) }
    static var cardTitle: AppFont { AppFont.scaledSystem(size: 20, weight: .bold) }
    /// The next meeting's title while another meeting is being recorded.
    static var cardTitleCompact: AppFont { AppFont.scaledSystem(size: 17, weight: .bold) }
}

extension View {
    /// The raised card at the top of Today and around the first-day steps.
    func todayCardSurface(tint: Color? = nil) -> some View {
        modifier(TodayCardSurface(tint: tint))
    }
}

private struct TodayCardSurface: ViewModifier {
    @Environment(\.colorSchemeContrast) private var contrast
    var tint: Color?

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Brand.Radius.panel, style: .continuous)
        content
            .background {
                shape.fill(Color(nsColor: .controlBackgroundColor))
                    .overlay { shape.fill((tint ?? .clear).opacity(tint == nil ? 0 : 0.06)) }
                    .shadow(color: .black.opacity(contrast == .increased ? 0 : 0.06), radius: 1.5, y: 1)
            }
            .overlay {
                shape.strokeBorder(
                    contrast == .increased ? Color.primary.opacity(0.5)
                        : tint?.opacity(0.28) ?? LBTokens.Palette.groupStroke,
                    lineWidth: contrast == .increased ? 2 : 1)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
    }
}

enum TodayDreamSelection {
    /// How many days back (yesterday included) the card will reach for a
    /// substantive brief before going quiet.
    static let lookbackDays = 5

    /// Yesterday's brief when there is one; otherwise the newest substantive
    /// brief within the lookback. Empty-day stubs exist only to mark their day
    /// dreamed — they are never surfaced, and a returning user sees their last
    /// real morning brief instead of "nothing was recorded".
    static func report(
        referenceDate: Date,
        latest: DreamReport?,
        store: DreamStore,
        calendar: Calendar = .current
    ) -> DreamReport? {
        var day = DreamScheduler.previousDay(of: referenceDate, calendar: calendar)
        for _ in 0..<lookbackDays {
            let key = DreamDay.key(for: day, calendar: calendar)
            let candidate = (latest?.day == key) ? latest : store.report(forDayKey: key)
            if let candidate, candidate.fallbackReason != .emptyDay { return candidate }
            guard let previous = calendar.date(byAdding: .day, value: -1, to: day) else {
                return nil
            }
            day = previous
        }
        return nil
    }

    /// False when the report covers an older day than yesterday, so the card
    /// can label it instead of presenting it as fresh.
    static func isCurrent(
        _ report: DreamReport,
        referenceDate: Date,
        calendar: Calendar = .current
    ) -> Bool {
        let yesterday = DreamScheduler.previousDay(of: referenceDate, calendar: calendar)
        return report.day == DreamDay.key(for: yesterday, calendar: calendar)
    }

    /// Only a current evidence-only brief caused by model generation deserves
    /// an inline retry. Empty days have nothing to regenerate, and retrying an
    /// older card would silently replace yesterday's report instead.
    static func isRetryableFailure(
        _ report: DreamReport,
        referenceDate: Date,
        calendar: Calendar = .current
    ) -> Bool {
        guard report.isFallback,
              report.fallbackReason != .emptyDay else { return false }
        return isCurrent(report, referenceDate: referenceDate, calendar: calendar)
    }

    /// Whose priorities a brief holds: today's when it covers yesterday, an
    /// older day's otherwise.
    enum PrioritiesSource: Equatable {
        case today
        /// The covered day by name: its weekday within the last week, its
        /// date beyond that.
        case day(String)
        /// The covered day is unreadable.
        case previousWorkday
    }

    /// A brief from yesterday earns "Priorities for today"; anything older is
    /// framed with its own day so a Friday brief on Monday never reads as
    /// current. Weekday alone within the lookback window, full date beyond it.
    static func prioritiesSource(
        for report: DreamReport,
        referenceDate: Date,
        calendar: Calendar = .current
    ) -> PrioritiesSource {
        if isCurrent(report, referenceDate: referenceDate, calendar: calendar) { return .today }
        guard let day = DreamDay.date(fromKey: report.day) else { return .previousWorkday }
        let daysAgo = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: day),
            to: calendar.startOfDay(for: referenceDate)).day ?? Int.max
        if daysAgo <= 6 { return .day(day.formatted(.dateTime.weekday(.wide))) }
        return .day(day.formatted(date: .abbreviated, time: .omitted))
    }

    /// `prioritiesSource` in English, for text that is not interface text.
    static func prioritiesHeading(
        for report: DreamReport,
        referenceDate: Date,
        calendar: Calendar = .current
    ) -> String {
        switch prioritiesSource(for: report, referenceDate: referenceDate, calendar: calendar) {
        case .today: "Priorities for today"
        case .day(let name): "Priorities from \(name)"
        case .previousWorkday: "Priorities from a previous workday"
        }
    }
}
