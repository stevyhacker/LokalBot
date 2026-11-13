import SwiftUI

/// A run of tool steps as one quiet line ("Searched meeting library, read
/// meeting notes") that opens to a row per step. A finished turn's line
/// counts its steps and also holds what the agent said between them.
struct AgentStepsLine: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.layoutDirection) private var layoutDirection
    let group: AgentStepGroup
    let context: AgentStepWording.Context
    let taskIsWorking: Bool
    let textSize: Double
    @Binding var expanded: Bool
    let showPreview: (AgentResultPreview) -> Void

    private var language: AppLanguage { app.settings.appLanguage }
    private var localized: (String) -> String { language.catalog }

    private func label(_ item: AgentTranscriptItem) -> AgentStepLabel? {
        AgentStepWording.label(for: item, context: context, localize: localized)
    }

    private func text(_ item: AgentTranscriptItem) -> String? {
        guard case .tool(_, _, _, _, let status) = item, let label = label(item) else { return nil }
        return label.text(status, taskIsWorking: taskIsWorking, localize: localized)
    }

    private var summary: String {
        let labels = group.steps.compactMap { item -> (text: String, beginsWithName: Bool)? in
            guard let label = label(item), let text = text(item) else { return nil }
            return (text, label.beginsWithName)
        }
        return AgentStepWording.summary(
            labels, lowercaseFollowing: language.localizationIdentifier().hasPrefix("en"))
    }

    private var count: String? {
        group.isTurnSummary && group.steps.count > 1
            ? AgentStepWording.count(group.steps.count, localize: localized) : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(WorkspaceMotion.animation(.disclosure, reduceMotion: reduceMotion)) { expanded.toggle() }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Image(systemName: "chevron.forward")
                        .font(.scaled(.caption2).weight(.semibold))
                        // Turns to point down in either reading direction.
                        .rotationEffect(.degrees(expanded ? (layoutDirection == .rightToLeft ? -90 : 90) : 0))
                        .frame(width: 10)
                    Image(systemName: group.hasFailure ? "exclamationmark.circle" : "checkmark.circle")
                        .foregroundStyle(group.hasFailure ? LBTokens.Palette.attentionText : Color.secondary)
                    if let count {
                        Text(verbatim: count).fontWeight(.semibold).foregroundStyle(.primary).fixedSize()
                    }
                    Text(verbatim: summary).lineLimit(expanded ? 3 : 1).truncationMode(.tail)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                }
                .font(.scaled(.callout))
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(verbatim: [count, summary].compactMap { $0 }.joined(separator: ", ")))
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")
            .accessibilityIdentifier("agent.activityGroup")

            if expanded {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(group.entries) { entry in row(entry) }
                }
                .padding(.leading, 12)
                .overlay(alignment: .leading) {
                    Rectangle().fill(LBTokens.Palette.groupStroke).frame(width: 1).accessibilityHidden(true)
                }
                .padding(.leading, 4)
                .transition(WorkspaceMotion.disclosureTransition(reduceMotion: reduceMotion))
            }
        }
    }

    @ViewBuilder private func row(_ entry: AgentTranscriptItem) -> some View {
        switch entry {
        case .tool(_, let name, _, _, let status):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                statusIcon(status)
                Text(verbatim: text(entry) ?? name).foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = label(entry)?.detail {
                    Text(verbatim: detail).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 8)
                Button("Open") { if let result = AgentResultPreview.tool(entry) { showPreview(result) } }
                    .buttonStyle(.workspaceLink)
                    .accessibilityLabel(Text(verbatim: "\(localized("Open")): \(text(entry) ?? name)"))
            }
            .font(.scaled(.callout))
        case .assistant(_, let said, _):
            // What the agent said between steps, kept in order and quieter than the answer.
            Text(verbatim: said)
                .font(.system(size: max(12, textSize - 2))).foregroundStyle(.secondary).lineSpacing(3)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        default:
            EmptyView()
        }
    }

    @ViewBuilder private func statusIcon(_ status: AgentToolStatus) -> some View {
        switch status {
        case .succeeded:
            Image(systemName: "checkmark").foregroundStyle(.secondary).frame(width: 14)
        case .failed:
            Image(systemName: "exclamationmark.circle").foregroundStyle(LBTokens.Palette.attentionText).frame(width: 14)
        case .running:
            if taskIsWorking { ProgressView().controlSize(.mini).frame(width: 14) } else {
                Image(systemName: "minus").foregroundStyle(.secondary).frame(width: 14)
            }
        }
    }
}

/// The step the agent is on right now: "Reading open actions…".
struct AgentLiveStep: View {
    @EnvironmentObject private var app: AppState
    let item: AgentTranscriptItem
    let context: AgentStepWording.Context

    var body: some View {
        let localized = app.settings.appLanguage.catalog
        let label = AgentStepWording.label(for: item, context: context, localize: localized)
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(verbatim: (label?.doing ?? "") + "…").foregroundStyle(.secondary)
            if let detail = label?.detail {
                Text(verbatim: detail).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
            }
        }
        .font(.scaled(.callout))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("agent.liveStep")
    }
}
