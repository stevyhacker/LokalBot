import SwiftUI

struct YesterdayBriefPanel: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.appTextScale) private var textScale
    let report: DreamReport
    let day: Date

    private var title: Text {
        if TodayDreamSelection.isCurrent(report, referenceDate: day) { return Text("Yesterday") }
        return Text(verbatim: reportDay?.formatted(date: .abbreviated, time: .omitted) ?? report.day)
    }

    private var reportDay: Date? { DreamDay.date(fromKey: report.day) }

    private var notes: [String] {
        report.attention + report.repeatedWork + report.suggestedChecks + report.frictions
    }

    private var hasNarrative: Bool { !report.narrative.isEmpty }
    private var hasPriorities: Bool { !report.topActions.isEmpty }
    private var hasNotes: Bool { !notes.isEmpty }

    private func linkedThread(_ id: String?) -> ActionThread? {
        guard let id else { return nil }
        return app.outcomeIndex.userActionThreads.first { $0.id == id }
    }

    var body: some View {
        SectionPanel(
            title: title,
            systemImage: "moon",
            identifier: "today.dream"
        ) {
            if let reportDay {
                Button("Open day") { app.openTimelineDay(reportDay) }
                    .accessibilityIdentifier("today.dream.openDay")
            }
        } content: {
            VStack(alignment: .leading, spacing: 14) {
                briefContent
                if report.isFallback {
                    Text("Previous-day summary uses captured evidence only.").workspaceTextRole(.supporting)
                }
                if report.inferenceProvenance?.location == .remote {
                    Label("Previous-day summary used approved remote inference", systemImage: "network")
                        .workspaceTextRole(.trust)
                }
                if TodayDreamSelection.isRetryableFailure(report, referenceDate: day) {
                    Button(app.dreaming.isDreaming ? "Updating…" : "Retry previous-day summary") { app.dreamNow() }
                        .disabled(app.dreaming.isDreaming || !app.libraryReady)
                        .accessibilityIdentifier("today.dream.retry")
                }
            }
            .padding(.horizontal, SectionPanelMetric.inset)
            .padding(.vertical, 14)
        } footer: {
            Text(verbatim: report.provenanceDescription(localized: { app.settings.appLanguage.localized($0) }))
                .sectionPanelFooterText()
        }
    }

    @ViewBuilder private var briefContent: some View {
        if hasNotes && (hasNarrative || hasPriorities) {
            YesterdayBriefColumnsLayout(textScale: textScale) {
                VStack(alignment: .leading, spacing: 14) {
                    if hasNarrative { narrative }
                    if hasPriorities { priorities }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                columnDivider
                notesSection
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else if hasNarrative && hasPriorities {
            YesterdayBriefColumnsLayout(textScale: textScale) {
                narrative
                    .frame(maxWidth: .infinity, alignment: .leading)
                columnDivider
                priorities
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else if hasNarrative {
            narrative.frame(maxWidth: WorkspaceMetric.readingMaxWidth, alignment: .leading)
        } else if hasPriorities {
            priorities.frame(maxWidth: WorkspaceMetric.readingMaxWidth, alignment: .leading)
        } else if hasNotes {
            notesSection.frame(maxWidth: WorkspaceMetric.readingMaxWidth, alignment: .leading)
        }
    }

    private var columnDivider: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .accessibilityHidden(true)
    }

    private var narrative: some View {
        DreamBriefText(text: report.narrative)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var notesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionPanelLabel(text: Text("Notes"))
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(notes.enumerated()), id: \.offset) { _, text in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(verbatim: "•")
                            .font(AppFont.scaled(.body))
                            .workspaceSupportingForeground()
                            .accessibilityHidden(true)
                        DreamBriefText(text: text)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private var priorities: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionPanelLabel(text: prioritiesLabel)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(report.topActions.enumerated()), id: \.offset) { index, action in
                    if let thread = linkedThread(report.topActionThreadID(at: index)) {
                        ActionThreadRow(thread: thread)
                    } else {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(verbatim: "\(index + 1).")
                                .font(AppFont.scaled(.body).monospacedDigit())
                            DreamBriefText(text: action)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }

    private var prioritiesLabel: Text {
        switch TodayDreamSelection.prioritiesSource(for: report, referenceDate: day) {
        case .today: Text("Priorities for today")
        case .previousWorkday: Text("Priorities from a previous workday")
        case .day(let name): Text("Priorities from \(name)")
        }
    }
}
