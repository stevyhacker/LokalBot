import SwiftUI

/// The day up to now: tracked time by app, the digest's highlights, and one
/// line saying when the digest was written, with Update when there is newer
/// activity. Sessions, tasks and the full digest are on Timeline.
struct TodaySoFarSection: View {
    @EnvironmentObject private var app: AppState
    @ObservedObject var model: CaptureModel
    /// Reflects every digest run for today, a scheduled one included, so a
    /// manual request cannot start a competing generation.
    @ObservedObject var lifecycle: DayDigestLifecycle
    @State private var highlights = ""

    private static let appLimit = 4

    private var scheduledRun: Bool { lifecycle.isGenerating(on: model.day) && !model.generating }

    var body: some View {
        let perApp = DayActivityOverview.perApp(model.blocks)
        VStack(alignment: .leading, spacing: 10) {
            TodaySectionHeading(title: "So far today") {
                Button("Open Timeline") { app.navSection = .timeline }
                    .buttonStyle(.workspaceLink)
                    .font(AppFont.scaled(.callout))
                    .accessibilityIdentifier("today.openTimeline")
            }
            if !perApp.isEmpty { tracked(perApp) }
            if !highlights.isEmpty {
                SelectableDigestText(highlights)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: WorkspaceMetric.readingMaxWidth, alignment: .leading)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("today.dayDigest.text")
            }
            digestLine
            if let error = model.digestError {
                Label(error, systemImage: "exclamationmark.triangle").workspaceTextRole(.warning)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("today.soFar")
        .onChange(of: model.digest, initial: true) { _, digest in
            highlights = TodayDigestHighlights.markdown(for: digest)
        }
        .onChange(of: scheduledRun) { wasRunning, isRunning in
            // Show the scheduled result as soon as it is saved.
            if wasRunning, !isRunning { model.refreshOverview(app: app) }
        }
    }

    /// "2h 25m tracked", then the busiest apps, each with its dot. App names
    /// are shown as captured.
    private func tracked(_ perApp: [(label: String, seconds: TimeInterval)]) -> some View {
        let total = perApp.reduce(0) { $0 + $1.seconds }
        return MeetingWrappingRow(spacing: 14, lineSpacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(verbatim: CaptureStyle.hm(total))
                    .font(AppFont.scaled(.body).weight(.bold).monospacedDigit())
                Text("tracked")
                    .font(AppFont.scaled(.body))
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            ForEach(AppTimePresentation.rows(perApp: perApp, cap: Self.appLimit), id: \.label) { row in
                HStack(spacing: 5) {
                    StatusDot(color: row.isOther ? .gray : CaptureStyle.color(for: row.label), size: 7)
                        .accessibilityHidden(true)
                    Text(verbatim: row.label).lineLimit(1)
                    Text(verbatim: CaptureStyle.hm(row.seconds))
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                }
                .font(AppFont.scaled(.callout))
                .foregroundStyle(.secondary)
                .accessibilityElement(children: .combine)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("today.tracked")
    }

    @ViewBuilder private var digestLine: some View {
        let state = TodayDigestLine.state(
            hasDigest: model.digest != nil, writtenAt: model.digestUpdatedAt,
            isStale: model.digestIsStale, isWriting: model.generating || scheduledRun)
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            switch state {
            case .writing:
                ProgressView().controlSize(.small)
                Text("Writing Digest…")
            case .missing:
                Text("Your digest brings together this day's meetings and captured activity.")
                    .fixedSize(horizontal: false, vertical: true)
                writeButton
            case .current(let writtenAt):
                if let writtenAt { written(writtenAt) }
            case .stale(let writtenAt):
                staleText(writtenAt)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("today.dayDigest.stale")
                writeButton
            }
        }
        .font(AppFont.scaled(.callout))
        .foregroundStyle(.secondary)
    }

    private func written(_ date: Date) -> Text {
        Text("Digest written \(date.formatted(date: .omitted, time: .shortened))")
    }

    private func staleText(_ date: Date?) -> Text {
        guard let date else { return Text("New activity since") }
        return written(date) + Text(verbatim: " · ") + Text("New activity since")
    }

    private var writeButton: some View {
        Button(model.digest == nil ? "Write Digest" : "Update") {
            Task { await model.generateDigest(app: app) }
        }
        .buttonStyle(.workspaceLink)
        .accessibilityIdentifier("today.dayDigest.generate")
    }
}
