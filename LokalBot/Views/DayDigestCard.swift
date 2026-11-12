import SwiftUI

/// Yesterday's overnight brief on Today, as a panel: what happened, the
/// priorities it leaves, and a footer saying how it was written.
struct YesterdayBriefPanel: View {
    @EnvironmentObject private var app: AppState
    let report: DreamReport
    let day: Date

    /// "Yesterday", or the day an older brief covers.
    private var title: Text {
        if TodayDreamSelection.isCurrent(report, referenceDate: day) { return Text("Yesterday") }
        return Text(verbatim: reportDay?.formatted(date: .abbreviated, time: .omitted) ?? report.day)
    }

    private var reportDay: Date? { DreamDay.date(fromKey: report.day) }

    private var notes: [String] {
        report.attention + report.repeatedWork + report.suggestedChecks + report.frictions
    }

    private func linkedThread(_ id: String?) -> ActionThread? {
        guard let id else { return nil }
        return app.outcomeIndex.userActionThreads.first { $0.id == id }
    }

    var body: some View {
        TodayPanel(
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
                if !report.narrative.isEmpty {
                    DreamBriefText(text: report.narrative)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !report.topActions.isEmpty { priorities }
                if !notes.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(notes.enumerated()), id: \.offset) { _, text in
                            DreamBriefText(text: "• " + text)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
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
            .padding(.horizontal, TodayPanelMetric.inset)
            .padding(.vertical, 14)
        } footer: {
            // The report's own account of which model wrote it and where.
            Text(report.provenanceDescription)
                .todayPanelFooterText()
        }
    }

    /// The brief's top actions, in its order. One taken from the recorded
    /// candidates is the real thread: it can be checked off here and stays in
    /// sync. The rest are numbered advice.
    private var priorities: some View {
        VStack(alignment: .leading, spacing: 6) {
            TodayPanelLabel(text: prioritiesLabel)
            VStack(alignment: .leading, spacing: 3) {
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
