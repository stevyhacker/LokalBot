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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: WorkspaceMetric.sectionGap) {
                header
                nowCard
                UpcomingMeetingSection(model: upcomingMeeting)
                NeedsAttentionSection(
                    threads: app.outcomeIndex.openUserActionThreads,
                    limit: 3)
                WorkspaceSection(title: "Day digest", icon: "sparkles") {
                    DayDigestCard(model: model, yesterday: dream, identifier: "today")
                    Button("Open timeline") { app.navSection = .timeline }
                        .buttonStyle(.link)
                }
            }
            .padding(WorkspaceMetric.pagePadding)
            .frame(maxWidth: WorkspaceMetric.contentMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .navigationTitle("Today")
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

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Today")
                    .font(WorkspaceTypography.display)
                    .accessibilityIdentifier("today.header")
                Text(Date().formatted(date: .complete, time: .omitted))
                    .font(WorkspaceTypography.metadata).foregroundStyle(.secondary)
            }
            Spacer()
            Menu {
                Button("Plan open actions in Agent") {
                    let threads = app.outcomeIndex.openUserActionThreads
                    let lines = threads.prefix(8).map { thread in
                        let sources = thread.meetingCount == 1
                            ? "" : " (mentioned in \(thread.meetingCount) meetings)"
                        return "- \(thread.text)\(sources)"
                    }
                    app.openAgent(.init(
                        title: "Today's action threads",
                        prompt: "Help me plan today's open meeting action threads:\n"
                            + lines.joined(separator: "\n"),
                        meetingID: threads.first?.latestReference.meetingID,
                        actionID: threads.first?.latestReference.action.id))
                }
                .disabled(app.outcomeIndex.openUserActionThreads.isEmpty)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel("More Today actions")
            .help("More Today actions")
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

    /// Recording status; the title bar owns the recording control.
    @ViewBuilder private var nowCard: some View {
        if let live = app.currentMeeting {
            HeroPanel(radius: Brand.Radius.panel) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        StatusDot(color: Brand.recording, size: 9)
                        Text("Recording — \(live.title)")
                            .font(.headline).foregroundStyle(.white)
                        Spacer()
                        LiveWaveform(barCount: 7, barWidth: 3, maxHeight: 14)
                    }
                    HStack(spacing: 8) {
                        Button {
                            app.showLiveMeeting()
                        } label: {
                            Label("Live transcript & notes", systemImage: "text.bubble")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
        } else {
            HStack(spacing: 10) {
                Label("Nothing recording right now", systemImage: "record.circle")
                    .font(WorkspaceTypography.body).foregroundStyle(.secondary)
                Spacer()
            }
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
