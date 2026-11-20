import SwiftUI

struct TimelineDigestPage: View {
    @EnvironmentObject private var app: AppState
    @ObservedObject var model: CaptureModel
    @ObservedObject var lifecycle: DayDigestLifecycle
    let list: TimelineDayList
    let presentation: DayDigestPresentation?
    let onSelectRow: (String) -> Void

    private var scheduledRun: Bool { lifecycle.isGenerating(on: model.day) && !model.generating }

    var body: some View {
        let state = TodayDigestLine.state(
            hasDigest: model.digest != nil, writtenAt: model.digestUpdatedAt,
            isStale: model.digestIsStale, isWriting: model.generating || scheduledRun)
        ScrollView {
            TimelinePageColumn {
                TimelineHighlightsPanel(
                    state: state,
                    highlights: presentation?.atAGlanceMarkdown ?? "",
                    hasDigest: model.digest != nil,
                    day: model.day,
                    writesEachEvening: app.settings.dayDigestAutoEnabled,
                    error: model.digestError,
                    onWrite: { Task { await model.generateDigest(app: app) } })
                TimelineDayActionsPanel(
                    threads: TimelineDayActions.threads(app.outcomeIndex.userActionThreads, on: model.day))
                    .id(DreamDay.key(for: model.day))
                if let presentation, presentation.hasBodyBelowHighlights {
                    DayDigestView(presentation, mode: .timeline)
                        .environment(\.dayDigestProjects, projects)
                        .environment(\.dayDigestTimeRangeAction, DayDigestTimeRangeAction { range in
                            list.workRow(inTimeRange: range, day: model.day).map { row in { onSelectRow(row.id) } }
                        })
                }
            }
        }
        .onChange(of: scheduledRun) { wasRunning, isRunning in
            if wasRunning, !isRunning { model.refreshOverview(app: app) }
        }
    }

    private var projects: [String: String] {
        Dictionary(model.projectSplit.projects.map { ($0.project.lowercased(), $0.project) },
                   uniquingKeysWith: { first, _ in first })
    }
}

extension DayDigestPresentation {
    var hasBodyBelowHighlights: Bool {
        !blockers.isEmpty || !decisions.isEmpty || !focusBlocks.isEmpty || !followUps.isEmpty
    }
}

struct TimelineHighlightsPanel: View {
    let state: TodayDigestLine
    let highlights: String
    let hasDigest: Bool
    let day: Date
    let writesEachEvening: Bool
    var error: String?
    let onWrite: () -> Void

    static var lead: AppFont { AppFont.scaledSystem(size: 15) }

    private var isWritingFirst: Bool { state == .writing && !hasDigest }

    private var showsContent: Bool {
        !highlights.isEmpty || state == .missing || isWritingFirst || error != nil
    }

    private var showsFooter: Bool {
        guard hasDigest else { return false }
        switch state {
        case .writing, .stale: return true
        case .current(let writtenAt): return writtenAt != nil
        case .missing: return false
        }
    }

    var body: some View {
        if showsContent || showsFooter {
            SectionPanel(
                title: Text("Highlights"),
                systemImage: "doc.text",
                identifier: "timeline.highlights",
                showsContent: showsContent,
                showsFooter: showsFooter
            ) {
                EmptyView()
            } content: {
                VStack(alignment: .leading, spacing: 10) {
                    if !highlights.isEmpty {
                        SelectableDigestText(highlights, font: Self.lead)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityElement(children: .contain)
                            .accessibilityIdentifier("timeline.dayDigest.highlights")
                    }
                    if state == .missing {
                        noDigest
                    } else if isWritingFirst {
                        writingFirst
                    }
                    if let error {
                        Label(error, systemImage: "exclamationmark.triangle").workspaceTextRole(.warning)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, SectionPanelMetric.inset)
                .padding(.vertical, 14)
            } footer: {
                freshness
            }
        }
    }

    private var noDigest: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("No digest for this day yet")
                    .font(Self.lead.weight(.semibold))
                Text(writesEachEvening
                     ? "LokalBot writes one each evening from the day's meetings and work."
                     : "Your digest brings together this day's meetings and captured activity.")
                    .workspaceTextRole(.supporting)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("Write Digest", action: onWrite)
                .buttonStyle(.bordered)
                .fixedSize()
                .accessibilityIdentifier("timeline.dayDigest.generate")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("timeline.dayDigest.missing")
    }

    private var writingFirst: some View {
        HStack(alignment: .center, spacing: 12) {
            ProgressView().controlSize(.small)
            VStack(alignment: .leading, spacing: 2) {
                Text("Writing this day's digest…")
                    .font(Self.lead.weight(.semibold))
                Text("The day below is already up to date.")
                    .workspaceTextRole(.supporting)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private var freshness: some View {
        switch state {
        case .writing:
            ProgressView().controlSize(.small)
            Text("Updating the digest with new activity…")
                .sectionPanelFooterText()
        case .current(let writtenAt):
            if let writtenAt {
                written(writtenAt)
                    .sectionPanelFooterText()
            }
        case .stale(let writtenAt):
            staleText(writtenAt)
                .accessibilityIdentifier("capture.dayDigest.stale")
                .sectionPanelFooterText()
            Button("Update", action: onWrite)
                .fixedSize()
                .accessibilityIdentifier("timeline.dayDigest.update")
        case .missing:
            EmptyView()
        }
    }

    private func written(_ date: Date) -> Text {
        let sameDay = Calendar.current.isDate(date, inSameDayAs: day)
        return Text("Digest written \(date.formatted(date: sameDay ? .omitted : .abbreviated, time: .shortened))")
    }

    private func staleText(_ date: Date?) -> Text {
        guard let date else { return Text("New activity since") }
        return written(date) + Text(verbatim: " · ") + Text("New activity since")
    }
}

struct TimelineDayActionsPanel: View {
    @EnvironmentObject private var app: AppState
    let threads: [ActionThread]
    @State private var hadOpen = false

    var body: some View {
        if let summary = TimelineDayActions.summary(of: threads) {
            SectionPanel(
                title: Text("Actions from this day’s meetings"),
                systemImage: AppState.NavSection.actions.symbol,
                status: Self.pill(TimelineDayActions.pill(for: summary)),
                identifier: "timeline.dayActions",
                showsContent: TimelineDayActions.showsRows(summary, hadOpen: hadOpen),
                titleLineLimit: 2
            ) {
                Button("All actions") { app.openActions() }
                    .accessibilityIdentifier("timeline.dayActions.all")
            } content: {
                VStack(spacing: 0) {
                    ForEach(threads) { thread in
                        ActionThreadRow(thread: thread)
                        if thread.id != threads.last?.id { Divider() }
                    }
                }
                .padding(.horizontal, SectionPanelMetric.inset)
            }
            .onChange(of: summary, initial: true) { _, summary in
                if case .open = summary { hadOpen = true }
            }
        }
    }

    static func pill(_ pill: TimelineDayActions.Pill) -> SectionPanelPill {
        switch pill {
        case .open(let count): SectionPanelPill(text: Text("\(count) open"), tone: .count)
        case .allDone: SectionPanelPill(text: Text("All done"), tone: .done)
        }
    }
}
