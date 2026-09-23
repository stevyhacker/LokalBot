import SwiftUI

/// One digest presentation for Today and Timeline, with the same generation,
/// export, freshness and inference behavior in each destination.
struct DayDigestCard: View {
    @EnvironmentObject private var app: AppState
    @ObservedObject var model: CaptureModel
    var yesterday: DreamReport?
    let identifier: String
    var showsControls = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if showsControls { DayDigestControls(model: model, identifier: identifier) }
            if let yesterday { YesterdayDigestLine(report: yesterday, day: model.day) }
            if let updated = model.digestUpdatedAt {
                Text("Updated " + updated.formatted(date: .omitted, time: .shortened))
                    .workspaceTextRole(.metadata)
            }
            if model.digestIsStale {
                Label("New activity available. Update the digest to include it.", systemImage: "clock.arrow.circlepath")
                    .workspaceTextRole(.warning)
                    .accessibilityIdentifier("\(identifier).dayDigest.stale")
            }
            if let digest = model.digest {
                DayDigestView(digest, mode: .timeline)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("\(identifier).dayDigest.text")
            } else {
                Text("Your digest brings together this day's meetings and captured activity.")
                    .workspaceTextRole(.supporting)
            }
            if let error = model.digestError {
                Label(error, systemImage: "exclamationmark.triangle").workspaceTextRole(.warning)
            }
        }
    }
}

struct DayDigestControls: View {
    @EnvironmentObject private var app: AppState
    @ObservedObject var model: CaptureModel
    let identifier: String

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { ask; generate; actions }
            VStack(alignment: .leading, spacing: 8) {
                ask
                HStack(spacing: 8) { generate; actions }
            }
        }
        .controlSize(.small)
    }

    private var ask: some View {
        Button { app.openAsk(dayScope: model.day) } label: {
            Label("Ask about day", systemImage: "sparkle.magnifyingglass")
        }
        .buttonStyle(.borderedProminent)
        .accessibilityIdentifier(identifier == "timeline" ? "capture.askDay" : "\(identifier).askDay")
    }

    private var generate: some View {
        Button { Task { await model.generateDigest(app: app) } } label: {
            Label(model.generating ? "Writing digest…" : model.digest == nil ? "Write digest" : "Update digest",
                  systemImage: model.generating ? "hourglass" : "arrow.clockwise")
        }
        .buttonStyle(.bordered)
        .disabled(model.generating)
        .accessibilityIdentifier("\(identifier).dayDigest.generate")
    }

    @ViewBuilder private var actions: some View {
        if let digest = model.digest {
            Menu {
                Button { model.copyDigest(digest) } label: { Label("Copy digest", systemImage: "doc.on.doc") }
                    .accessibilityIdentifier("capture.dayDigest.copyAll")
                Button { model.exportDigest(digest) } label: { Label("Export Markdown", systemImage: "square.and.arrow.up") }
            } label: { Label("Digest actions", systemImage: "ellipsis.circle") }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityLabel("Day digest actions")
                .accessibilityIdentifier("\(identifier).dayDigest.actions")
        }
    }
}

private struct YesterdayDigestLine: View {
    @EnvironmentObject private var app: AppState
    let report: DreamReport
    let day: Date
    @State private var expanded = false

    private var label: String {
        TodayDreamSelection.isCurrent(report, referenceDate: day) ? "Yesterday"
            : DreamDay.date(fromKey: report.day)?.formatted(date: .abbreviated, time: .omitted) ?? "Previous workday"
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            DreamBriefText(text: report.narrative)
            ForEach(Array(report.topActions.enumerated()), id: \.offset) { _, action in
                DreamBriefText(text: "• " + action)
            }
            ForEach(Array((report.attention + report.repeatedWork + report.suggestedChecks + report.frictions).enumerated()), id: \.offset) { _, text in
                DreamBriefText(text: "• " + text)
            }
            Text(report.provenanceDescription).workspaceTextRole(.metadata)
            if TodayDreamSelection.isRetryableFailure(report, referenceDate: day) {
                Button(app.dreaming.isDreaming ? "Updating…" : "Retry previous-day summary") { app.dreamNow() }
                    .disabled(app.dreaming.isDreaming || !app.libraryReady)
                    .accessibilityIdentifier("today.dream.retry")
            }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(label).font(WorkspaceTypography.bodyEmphasis)
                Text(report.narrative).lineLimit(1).foregroundStyle(.secondary)
            }
        }
        .help(report.provenanceDescription)
        .accessibilityIdentifier("today.dream")
        if report.isFallback {
            Text("Previous-day summary uses captured evidence only.").workspaceTextRole(.supporting)
        }
        if report.inferenceProvenance?.location == .remote {
            Label("Previous-day summary used approved remote inference", systemImage: "network")
                .workspaceTextRole(.trust)
        }
    }
}
