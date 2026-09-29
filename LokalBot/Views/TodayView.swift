import SwiftUI

/// The default landing surface: one glanceable page composing today's
/// answers — what's capturing right now, what happened, where the time
/// went, and a way to ask about any of it. Today summarizes; the Timeline
/// stays the forensic, hour-indexed view of the same day.
struct TodayView: View {
    @EnvironmentObject var app: AppState
    @StateObject private var model = CaptureModel()
    @StateObject private var upcomingMeeting = UpcomingMeetingPreparationModel()
    @State private var dream: DreamReport?
    @AppStorage("lokalbotv3.gettingStartedDismissed")
    private var gettingStartedDismissed = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LBTokens.Metric.sectionSpacing) {
                nowCard
                UpcomingMeetingSection(model: upcomingMeeting)
                NeedsAttentionSection(
                    threads: ActionAttentionOrder.sorted(app.outcomeIndex.openUserActionThreads),
                    limit: 3,
                    showsPlanInAgent: true)
                digestSection
                if let dream { previousDayCard(dream) }
                if !gettingStartedDismissed { GettingStartedCard() }
            }
            .padding(.horizontal, LBTokens.Metric.detailPadding)
            .padding(.top, 8)
            .padding(.bottom, 28)
            .frame(maxWidth: WorkspaceMetric.todayMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .navigationTitle("Today")
        .navigationSubtitle(Date().formatted(date: .complete, time: .omitted))
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { app.openAsk(dayScope: model.day) } label: {
                    Label("Ask About Today", systemImage: "sparkle.magnifyingglass")
                }.accessibilityIdentifier("today.askDay")
                Button { app.navSection = .timeline } label: {
                    Label("Open Timeline", systemImage: "calendar.day.timeline.left")
                }.accessibilityIdentifier("today.header")
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

    // MARK: Digest

    /// The digest is the page's main content, so it sits directly on the
    /// canvas instead of inside a panel; its sessions carry their own cards.
    private var digestSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 12) {
                    digestTitle
                    Spacer(minLength: 12)
                    DayDigestControls(model: model, identifier: "today", showsAsk: false).fixedSize()
                }
                VStack(alignment: .leading, spacing: 10) {
                    digestTitle
                    DayDigestControls(model: model, identifier: "today", showsAsk: false)
                }
            }
            VStack(alignment: .leading, spacing: 18) {
                DayActivityOverview(model: model, title: "Day So Far", showsLegend: false)
                Divider()
                DayDigestCard(model: model, identifier: "today", showsControls: false, mode: .today)
                if !model.workSessions.isEmpty {
                    Divider()
                    TodaySessionsSection(model: model)
                }
            }
            .padding(16)
            .lbGroupedSurface()
        }
    }

    private var digestTitle: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles").foregroundStyle(Brand.teal).accessibilityHidden(true)
            Text("Day Digest").font(Font.headline)
        }
    }

    private func previousDayCard(_ report: DreamReport) -> some View {
        YesterdayDigestLine(report: report, day: model.day)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.24),
                        in: RoundedRectangle(cornerRadius: Brand.Radius.panel))
            .overlay {
                RoundedRectangle(cornerRadius: Brand.Radius.panel)
                    .strokeBorder(Color.primary.opacity(0.09))
            }
    }

    // Keep the previous-workday summary anchored to the selected date.
    private func reloadCurrentDay(at date: Date) {
        model.selectDay(date, app: app)
        dream = TodayDreamSelection.report(
            referenceDate: date,
            latest: app.latestDreamReport,
            store: app.dreamStore)
    }

    // MARK: Now

    /// Same recording actions as the menu bar and Meetings toolbar.
    @ViewBuilder private var nowCard: some View {
        if let live = app.currentMeeting {
            HStack(spacing: 10) {
                StatusDot(color: Brand.recording)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Recording — \(live.title)").font(.body.weight(.semibold))
                    MeetingRecordingTimerText(recording: app.recording).font(.callout.monospacedDigit())
                }
                Spacer()
                Button("Live Transcript & Notes") { app.showLiveMeeting() }.buttonStyle(.bordered)
                Button("Stop Recording") { app.stopRecording() }.buttonStyle(.bordered).tint(.red)
            }
            .padding(14)
            .lbStatusSurface(.red)
        } else {
            HStack(spacing: 10) {
                Image(systemName: "waveform.circle").foregroundStyle(.secondary)
                Text("Nothing recording right now")
                Spacer(minLength: 8)
                Button("Record Now") {
                    app.startRecording(context: app.recordingContext(for: app.detector.activeApp))
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("today.record")
            }
            .padding(14)
            .lbGroupedSurface()
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

    /// A brief from yesterday earns "Priorities for today"; anything older is
    /// framed with its own day so a Friday brief on Monday never reads as
    /// current. Weekday alone within the lookback window, full date beyond it.
    static func prioritiesHeading(
        for report: DreamReport,
        referenceDate: Date,
        calendar: Calendar = .current
    ) -> String {
        if isCurrent(report, referenceDate: referenceDate, calendar: calendar) {
            return "Priorities for today"
        }
        guard let day = DreamDay.date(fromKey: report.day) else {
            return "Priorities from a previous workday"
        }
        let daysAgo = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: day),
            to: calendar.startOfDay(for: referenceDate)).day ?? Int.max
        if daysAgo <= 6 {
            return "Priorities from \(day.formatted(.dateTime.weekday(.wide)))"
        }
        return "Priorities from \(day.formatted(date: .abbreviated, time: .omitted))"
    }
}
