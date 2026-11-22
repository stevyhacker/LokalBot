import Combine
import SwiftUI

struct TodayView: View {
    @EnvironmentObject var app: AppState
    @StateObject private var model = CaptureModel()
    @StateObject private var upcomingMeeting = UpcomingMeetingPreparationModel()
    @State private var dream: DreamReport?
    @State private var recaps: [Meeting.ID: String] = [:]
    @State private var dayLoaded = false
    @AppStorage("lokalbotv3.gettingStartedDismissed")
    private var gettingStartedDismissed = false
    @Environment(\.appTextScale) private var textScale

    private static let attentionLimit = 3

    private var recordings: [Meeting] {
        (app.currentMeeting.map { [$0] } ?? []) + app.meetings
    }

    var body: some View {
        ScrollView {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                page(now: context.date)
                    .frame(maxWidth: .infinity, alignment: .top)
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
        .onReceive(model.$overviewLoading.removeDuplicates().dropFirst()) { loading in
            if !loading, !dayLoaded { dayLoaded = true }
        }
        .onChange(of: app.latestDreamReport) { _, _ in
            guard app.navSection == .today else { return }
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
        let hasLeading = layout.showsSections && (!threads.isEmpty || showsMeetings)
        let hasTrailing = layout.showsSections && (hasDay || dream != nil)

        TodayColumnsLayout(textScale: textScale) {
            TodayDefaultModelUpgradeCard(app: app, roles: app.modelRoles, setup: app.modelSetup)
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

    private var isSettled: Bool { dayLoaded && app.libraryReady }

    private var calendarIsOff: Bool {
        switch upcomingMeeting.status {
        case .disabled, .permissionRequired, .permissionDenied: true
        case .loading, .noMeetingsToday, .ready: false
        }
    }

    private var finishedRecordingIDs: [Meeting.ID] {
        let calendar = Calendar.current
        return app.meetings
            .filter { $0.endedAt != nil && calendar.isDateInToday($0.startedAt) }
            .map(\.id)
    }

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

    private func reloadCurrentDay(at date: Date) {
        model.selectDay(date, app: app)
        dream = TodayDreamSelection.report(
            referenceDate: date,
            latest: app.latestDreamReport,
            store: app.dreamStore)
    }
}

enum TodayType {
    static var cardTitle: AppFont { AppFont.scaledSystem(size: 20, weight: .bold) }
    static var cardTitleCompact: AppFont { AppFont.scaledSystem(size: 17, weight: .bold) }
}

extension View {
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
    static let lookbackDays = 5

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

    static func isCurrent(
        _ report: DreamReport,
        referenceDate: Date,
        calendar: Calendar = .current
    ) -> Bool {
        let yesterday = DreamScheduler.previousDay(of: referenceDate, calendar: calendar)
        return report.day == DreamDay.key(for: yesterday, calendar: calendar)
    }

    static func isRetryableFailure(
        _ report: DreamReport,
        referenceDate: Date,
        calendar: Calendar = .current
    ) -> Bool {
        guard report.isFallback,
              report.fallbackReason != .emptyDay else { return false }
        return isCurrent(report, referenceDate: referenceDate, calendar: calendar)
    }

    enum PrioritiesSource: Equatable {
        case today
        case day(String)
        case previousWorkday
    }

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
