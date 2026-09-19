import SwiftUI

/// The default landing surface: one glanceable page composing today's
/// answers — what's capturing right now, what happened, where the time
/// went, and a way to ask about any of it. Today summarizes; the Timeline
/// stays the forensic, hour-indexed view of the same day.
struct TodayView: View {
    @EnvironmentObject var app: AppState
    @StateObject private var model = CaptureModel()
    @StateObject private var upcomingMeeting = UpcomingMeetingPreparationModel()
    @AppStorage("lokalbotv3.gettingStartedDismissed")
    private var gettingStartedDismissed = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: WorkspaceMetric.sectionGap) {
                header
                nowCard
                TodayMemoryStatus(sampler: app.sampler)
                UpcomingMeetingSection(model: upcomingMeeting)
                NeedsAttentionSection(
                    threads: app.outcomeIndex.openUserActionThreads,
                    limit: 3)
                dreamCard
                summarySection
                capturedSection
                BriefContextView()
                if !gettingStartedDismissed { GettingStartedCard() }
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
            Button {
                app.openActions()
            } label: {
                Label("Review actions", systemImage: "checklist")
            }
            Button {
                app.openAsk(dayScope: model.day)
            } label: {
                Label("Ask about today", systemImage: "sparkle.magnifyingglass")
            }
            .buttonStyle(.borderedProminent)
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

    // MARK: Dream (morning brief)

    @State private var dream: DreamReport?
    @State private var showingDreamInfo = false

    /// The overnight brief covers yesterday relative to the page's day; an
    /// older leftover report is not shown as if it were fresh.
    private func reloadCurrentDay(at date: Date) {
        model.selectDay(date, app: app)
        dream = TodayDreamSelection.report(
            referenceDate: date,
            latest: app.latestDreamReport,
            store: app.dreamStore)
    }

    @ViewBuilder private var dreamCard: some View {
        if let dream {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "moon.zzz.fill")
                        .foregroundStyle(Brand.teal)
                    Text(dreamDayLabel(dream))
                        .font(WorkspaceTypography.sectionTitle)
                        .accessibilityIdentifier("today.dream")
                    Spacer()
                    Text("Morning brief")
                        .font(WorkspaceTypography.metadataEmphasis)
                        .foregroundStyle(.secondary)
                    Button {
                        showingDreamInfo = true
                    } label: {
                        Image(systemName: "info.circle")
                    }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("About this morning brief")
                        .accessibilityLabel("About this morning brief")
                        .popover(isPresented: $showingDreamInfo) {
                            Text(dream.provenanceDescription)
                                .font(.callout)
                                .padding(WorkspaceMetric.cardPadding)
                                .frame(width: 300, alignment: .leading)
                        }
                }
                if !dream.topActions.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(TodayDreamSelection.prioritiesHeading(
                            for: dream, referenceDate: model.day))
                            .font(.system(size: 16, weight: .semibold))
                        ForEach(Array(dream.topActions.enumerated()), id: \.offset) { index, action in
                            DreamBriefText(text: "\(index + 1). \(action)", font: .system(size: 15))
                        }
                    }
                }
                if !dream.narrative.isEmpty {
                    DreamBriefText(text: displayedNarrative(dream))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                if let retrospective = retrospectiveMarkdown(dream) {
                    DreamBriefText(text: retrospective)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                dreamInferenceNotice(dream)
            }
            .padding(WorkspaceMetric.cardPadding)
            .background(
                RoundedRectangle(cornerRadius: Brand.Radius.compactPanel)
                    .fill(.quaternary.opacity(0.4)))
        }
    }

    private func displayedNarrative(_ dream: DreamReport) -> String {
        let dateReference: String
        if TodayDreamSelection.isCurrent(dream, referenceDate: model.day) {
            dateReference = "yesterday"
        } else {
            dateReference = DreamDay.date(fromKey: dream.day)
                .map { "on " + $0.formatted(date: .abbreviated, time: .omitted) }
                ?? "on a previous workday"
        }
        return dream.narrative
            .replacingOccurrences(of: "on \(dream.day)", with: dateReference)
            .replacingOccurrences(of: ", and no work goals were recorded", with: "")
    }

    private func dreamDayLabel(_ dream: DreamReport) -> String {
        if TodayDreamSelection.isCurrent(dream, referenceDate: model.day) {
            return "Yesterday"
        }
        return DreamDay.date(fromKey: dream.day)
            .map { $0.formatted(date: .abbreviated, time: .omitted) }
            ?? "Previous workday"
    }

    private func retrospectiveMarkdown(_ dream: DreamReport) -> String? {
        let groups: [(String, [String])] = [
            ("Needs attention", dream.attention),
            ("Repeated work worth automating", dream.repeatedWork),
            ("Suggested recurring checks", dream.suggestedChecks),
            ("Friction to smooth out", dream.frictions),
        ]
        let sections = groups.compactMap { title, items -> String? in
            guard !items.isEmpty else { return nil }
            return "### \(title)\n" + items.map { "- \($0)" }.joined(separator: "\n")
        }
        guard !sections.isEmpty else { return nil }
        return sections.joined(separator: "\n\n")
    }

    @ViewBuilder private func dreamInferenceNotice(_ dream: DreamReport) -> some View {
        if dream.isFallback {
            HStack(alignment: .center, spacing: 12) {
                Label(dream.provenanceDescription, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(Brand.error)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if TodayDreamSelection.isRetryableFailure(
                    dream, referenceDate: model.day
                ) {
                    Button {
                        app.dreamNow()
                    } label: {
                        if app.dreaming.isDreaming {
                            LoadingStateLabel("Dreaming…", font: .caption)
                        } else {
                            Label("Dream again", systemImage: "arrow.clockwise")
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .fixedSize()
                    .disabled(app.dreaming.isDreaming || !app.libraryReady)
                    .help(app.libraryReady
                          ? "Retry yesterday's dream with the configured Main LLM"
                          : "Preparing your meeting library")
                    .accessibilityIdentifier("today.dream.retry")
                }
            }
        } else if dream.inferenceProvenance?.location == .remote {
            Label("Generated using approved remote inference", systemImage: "network")
                .font(.caption)
                .foregroundStyle(.secondary)
                .help(dream.provenanceDescription)
        }
    }

    // MARK: Now

    /// What's happening right now: the live recording front and center,
    /// otherwise the most recent capture of the day, otherwise an
    /// invitation to record.
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
                        Button("Stop recording") { app.stopRecording() }
                            .buttonStyle(.bordered)
                    }
                }
            }
        } else {
            HStack(spacing: 10) {
                Label("Nothing recording right now", systemImage: "record.circle")
                    .font(WorkspaceTypography.body).foregroundStyle(.secondary)
                Spacer()
                Button("Record now") {
                    app.startRecording(
                        context: app.recordingContext(for: app.detector.activeApp))
                }
            }
        }
    }

    // MARK: Day so far

    private var perApp: [(key: String, value: TimeInterval)] {
        DayActivityProjection(blocks: model.blocks, day: model.day).perApp
    }

    @ViewBuilder private var daySoFar: some View {
        let apps = perApp
        let todaysMeetings = model.meetings(in: app)
        if !model.blocks.isEmpty || !model.shots.isEmpty || model.digest != nil || !todaysMeetings.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Day so far").font(WorkspaceTypography.sectionTitle)
                    Spacer()
                    Button("Open timeline") { app.navSection = .timeline }
                        .buttonStyle(.plain)
                        .foregroundStyle(Brand.teal)
                }
                DayStatRow(
                    trackedSeconds: DayActivityProjection(blocks: model.blocks, day: model.day).activeSeconds,
                    appCount: apps.count,
                    momentCount: model.shots.count,
                    meetingCount: todaysMeetings.count)
                if !apps.isEmpty {
                    ProportionBar(segments: ProportionBarMath.segments(
                        perApp: apps.map { (label: $0.key, seconds: $0.value) }
                    ).map {
                        ($0, $0.label == "Other" ? Color(nsColor: .tertiaryLabelColor)
                                                 : CaptureStyle.color(for: $0.label))
                    })
                }
                digestBlock
            }
        } else {
            Text("Your brief will draw on today's meetings and captured activity. Record a meeting or set up day memory to get started.")
                .workspaceTextRole(.supporting)
            Button("Set up day memory") { app.openSettings(tab: .dayMemory) }
        }
    }

    @ViewBuilder private var digestBlock: some View {
        if let digest = model.digest {
            HStack(spacing: 8) {
                Text("Day digest").font(WorkspaceTypography.bodyEmphasis)
                Spacer()
                Button {
                    Task { await model.generateDigest(app: app) }
                } label: {
                    Label(model.generating ? "Generating…" : "Regenerate digest",
                          systemImage: model.generating ? "hourglass" : "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(model.generating)
                .accessibilityIdentifier("today.dayDigest.generate")
                Menu {
                    Button { model.copyDigest(digest) } label: {
                        Label("Copy digest", systemImage: "doc.on.doc")
                    }
                    Button { model.exportDigest(digest) } label: {
                        Label("Export Markdown", systemImage: "square.and.arrow.up")
                    }
                } label: {
                    Label("Digest actions", systemImage: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityLabel("Day digest actions")
                .accessibilityIdentifier("today.dayDigest.actions")
            }
            HStack {
                if let generated = model.digestUpdatedAt { Text("Generated " + generated.formatted(date: .omitted, time: .shortened)) }
                if let latest = model.latestDigestEvidenceAt { Text("Latest capture " + latest.formatted(date: .omitted, time: .shortened)) }
                if model.digestIsStale { Text("New evidence available") }
            }.font(WorkspaceTypography.metadata).foregroundStyle(.secondary)
            DayDigestView(digest, mode: .today)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("today.dayDigest.text")
        } else {
            HStack(spacing: 8) {
                Text("Day digest").font(WorkspaceTypography.bodyEmphasis)
                Spacer()
                Button("Write day digest") {
                    Task { await model.generateDigest(app: app) }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(model.generating)
                .accessibilityIdentifier("today.dayDigest.generate")
                if model.generating { LoadingStateLabel("Writing digest…") }
            }
        }
        if let digestError = model.digestError {
            Label(digestError, systemImage: "exclamationmark.triangle")
                .font(.callout).foregroundStyle(Brand.error)
        }
    }

    // MARK: Meetings

    private var capturedSection: some View {
        let todays = model.meetings(in: app)
        return WorkspaceSection(title: "Captured", icon: "tray.full") {
            VStack(spacing: 0) {
                if todays.isEmpty {
                    EmptyWorkspaceRow(text: model.shots.isEmpty
                        ? "Nothing has been captured today yet."
                        : "No meetings captured yet — today's screen moments live in the Timeline.")
                } else {
                    // The screen-moment count already lives in the Day so far
                    // stat row above; repeating it here read as two different
                    // numbers for the same thing. Captured stays meetings-only.
                    ForEach(todays.prefix(4)) { meeting in
                        Button {
                            app.openMeeting(meeting.id)
                        } label: {
                            HStack(spacing: 8) {
                                MeetingRowView(meeting: meeting)
                                let ownedCount = app.outcomeIndex.projection(for: meeting.id)?
                                    .actionReferences.filter(\.isForUser).count ?? 0
                                BrandChip(
                                    icon: "checklist",
                                    text: "\(ownedCount) mine",
                                    size: .compact)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.vertical, 6)
                        Divider()
                    }
                }
            }
        }
    }

    private var summarySection: some View {
        WorkspaceSection(title: "Today’s brief", icon: "chart.bar") {
            daySoFar
        }
    }

}

private struct TodayMemoryStatus: View {
    @EnvironmentObject private var app: AppState
    @ObservedObject var sampler: ActivitySampler

    private var enabled: Bool {
        app.settings.trackingEnabled
    }
    private var status: String {
        !enabled ? "Off" : sampler.isPaused ? "Paused" : "Enabled"
    }

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                LabeledContent("App activity", value: app.settings.trackingEnabled ? status : "Off")
                LabeledContent("Visible text", value: captureStatus(
                    enabled: app.settings.effectiveScreenContextCaptureMode.capturesText,
                    permission: .accessibility))
                LabeledContent("Images", value: captureStatus(
                    enabled: app.settings.effectiveScreenContextCaptureMode.capturesPixels,
                    permission: .screenRecording))
                HStack {
                    if enabled { TrackingPauseButton(sampler: sampler, presentation: .toolbar) }
                    Button("Day memory settings") { app.openSettings(tab: .dayMemory) }
                }
            }.padding(.top, 8)
        } label: {
            Label("Day memory · \(status)", systemImage: "clock.arrow.circlepath")
                .font(WorkspaceTypography.metadata)
        }
        .accessibilityIdentifier("today.memoryStatus")
    }

    private func captureStatus(enabled: Bool, permission: AppPermission) -> String {
        guard app.settings.trackingEnabled, enabled else { return "Off" }
        guard !sampler.isPaused else { return "Paused" }
        return permission.isGranted ? "Enabled" : "Permission needed"
    }
}

/// Pure report selection keeps the overnight/current-day boundary testable
/// without mounting SwiftUI or relying on a stale `CaptureModel.day` value.
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
