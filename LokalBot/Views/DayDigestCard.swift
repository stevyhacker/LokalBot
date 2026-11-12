import SwiftUI

/// Yesterday's overnight brief on Today, folded to one line.
struct YesterdayDigestLine: View {
    @EnvironmentObject private var app: AppState
    let report: DreamReport
    let day: Date
    @State private var expanded = false

    /// "Yesterday", or the day an older brief covers.
    private var label: Text {
        if TodayDreamSelection.isCurrent(report, referenceDate: day) { return Text("Yesterday") }
        return Text(verbatim: DreamDay.date(fromKey: report.day)?
            .formatted(date: .abbreviated, time: .omitted) ?? report.day)
    }

    private func linkedThread(_ id: String?) -> ActionThread? {
        guard let id else { return nil }
        return app.outcomeIndex.userActionThreads.first { $0.id == id }
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            DreamBriefText(text: report.narrative)
            ForEach(Array(report.topActions.enumerated()), id: \.offset) { index, action in
                // A top action taken from the recorded candidates is the real
                // thread: it can be checked off here and stays in sync.
                if let thread = linkedThread(report.topActionThreadID(at: index)) {
                    ActionThreadRow(thread: thread)
                } else {
                    DreamBriefText(text: "• " + action)
                }
            }
            ForEach(Array((report.attention + report.repeatedWork + report.suggestedChecks + report.frictions).enumerated()), id: \.offset) { _, text in
                DreamBriefText(text: "• " + text)
            }
            if report.isFallback {
                Text("Previous-day summary uses captured evidence only.").workspaceTextRole(.supporting)
            }
            if report.inferenceProvenance?.location == .remote {
                Label("Previous-day summary used approved remote inference", systemImage: "network")
                    .workspaceTextRole(.trust)
            }
            Text(report.provenanceDescription).workspaceTextRole(.metadata)
            if TodayDreamSelection.isRetryableFailure(report, referenceDate: day) {
                Button(app.dreaming.isDreaming ? "Updating…" : "Retry previous-day summary") { app.dreamNow() }
                    .disabled(app.dreaming.isDreaming || !app.libraryReady)
                    .accessibilityIdentifier("today.dream.retry")
            }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                label.font(TodayType.sectionHeading)
                Text(report.narrative).lineLimit(1).foregroundStyle(.secondary)
            }
        }
        .help(report.provenanceDescription)
        .accessibilityIdentifier("today.dream")
    }
}
