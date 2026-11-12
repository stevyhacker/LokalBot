import SwiftUI

/// The day up to now as a panel: the tracked total, a bar per app, the
/// digest's highlights, and a footer saying when the digest was written, with
/// Update when there is newer activity. Sessions, tasks and the full digest
/// are on Timeline.
struct TodaySoFarSection: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.appTextScale) private var textScale
    @ObservedObject var model: CaptureModel
    /// Reflects every digest run for today, a scheduled one included, so a
    /// manual request cannot start a competing generation.
    @ObservedObject var lifecycle: DayDigestLifecycle
    @State private var highlights = ""

    private static let appLimit = 4
    /// The bar's name and duration columns, which grow with the text size
    /// like the time column of Meetings today.
    private static let nameColumnWidth: CGFloat = 100
    private static let durationColumnWidth: CGFloat = 52

    private var scheduledRun: Bool { lifecycle.isGenerating(on: model.day) && !model.generating }

    var body: some View {
        let perApp = DayActivityOverview.perApp(model.blocks)
        let state = TodayDigestLine.state(
            hasDigest: model.digest != nil, writtenAt: model.digestUpdatedAt,
            isStale: model.digestIsStale, isWriting: model.generating || scheduledRun)
        TodayPanel(
            title: Text("So far today"),
            systemImage: AppState.NavSection.timeline.symbol,
            identifier: "today.soFar",
            showsContent: !perApp.isEmpty || !highlights.isEmpty || model.digestError != nil,
            showsFooter: state != .current(writtenAt: nil)
        ) {
            Button("Open Timeline") { app.navSection = .timeline }
                .accessibilityIdentifier("today.openTimeline")
        } content: {
            VStack(alignment: .leading, spacing: 14) {
                if !perApp.isEmpty { tracked(perApp) }
                if !highlights.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        TodayPanelLabel(text: Text("Highlights"))
                        SelectableDigestText(highlights)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: WorkspaceMetric.readingMaxWidth, alignment: .leading)
                            .accessibilityElement(children: .contain)
                            .accessibilityIdentifier("today.dayDigest.text")
                    }
                }
                if let error = model.digestError {
                    Label(error, systemImage: "exclamationmark.triangle").workspaceTextRole(.warning)
                }
            }
            .padding(.horizontal, TodayPanelMetric.inset)
            .padding(.vertical, 14)
        } footer: {
            digestLine(state)
        }
        .onChange(of: model.digest, initial: true) { _, digest in
            highlights = TodayDigestHighlights.markdown(for: digest)
        }
        .onChange(of: scheduledRun) { wasRunning, isRunning in
            // Show the scheduled result as soon as it is saved.
            if wasRunning, !isRunning { model.refreshOverview(app: app) }
        }
    }

    /// "2h 25m tracked", then the busiest apps, each with its dot, a bar and
    /// its time. App names are shown as captured.
    private func tracked(_ perApp: [(label: String, seconds: TimeInterval)]) -> some View {
        let total = perApp.reduce(0) { $0 + $1.seconds }
        return VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(verbatim: CaptureStyle.hm(total))
                    .font(AppFont.scaledSystem(size: 22, weight: .bold).monospacedDigit())
                Text("tracked")
                    .font(AppFont.scaled(.body))
                    .workspaceSupportingForeground()
            }
            .accessibilityElement(children: .combine)
            ForEach(TodayAppBars.bars(perApp: perApp, cap: Self.appLimit)) { bar in
                appBar(bar)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("today.tracked")
    }

    /// The name and the time say everything; the bar only shows it.
    private func appBar(_ bar: TodayAppBars.Bar) -> some View {
        let color = bar.isOther ? Color.gray : CaptureStyle.color(for: bar.label)
        return HStack(spacing: 10) {
            HStack(spacing: 6) {
                StatusDot(color: color, size: 7)
                    .accessibilityHidden(true)
                Text(verbatim: bar.label)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(width: Self.nameColumnWidth * textScale, alignment: .leading)
            TodayAppBarShape(fraction: bar.fraction, color: color)
                .accessibilityHidden(true)
            Text(verbatim: CaptureStyle.hm(bar.seconds))
                .monospacedDigit()
                .workspaceSupportingForeground()
                .lineLimit(1)
                .frame(width: Self.durationColumnWidth * textScale, alignment: .trailing)
        }
        .font(AppFont.scaled(.callout))
        .accessibilityElement(children: .combine)
        .help(bar.label)
    }

    @ViewBuilder private func digestLine(_ state: TodayDigestLine) -> some View {
        switch state {
        case .writing:
            ProgressView().controlSize(.small)
            Text("Writing Digest…")
                .todayPanelFooterText()
        case .missing:
            Text("Your digest brings together this day's meetings and captured activity.")
                .todayPanelFooterText()
            writeButton
        case .current(let writtenAt):
            if let writtenAt {
                written(writtenAt)
                    .todayPanelFooterText()
            }
        case .stale(let writtenAt):
            staleText(writtenAt)
                .accessibilityIdentifier("today.dayDigest.stale")
                .todayPanelFooterText()
            writeButton
        }
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
        .fixedSize()
        .accessibilityIdentifier("today.dayDigest.generate")
    }
}

/// One app's share of the longest row: a quiet track with the app's colour
/// over the leading part of it.
private struct TodayAppBarShape: View {
    let fraction: Double
    let color: Color

    var body: some View {
        Capsule()
            .fill(LBTokens.Palette.quietFill)
            .frame(maxWidth: .infinity)
            .frame(height: 6)
            .overlay(alignment: .leading) {
                GeometryReader { proxy in
                    Capsule()
                        .fill(color)
                        .frame(width: max(fraction > 0 ? 3 : 0, proxy.size.width * fraction))
                        // Leading, so the bar grows from the right in
                        // right-to-left languages.
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
    }
}
