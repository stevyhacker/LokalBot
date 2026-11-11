import SwiftUI

/// The access chip's list: the levels the app has, each with what the agent
/// does on its own and what still asks, then the model and reasoning. The
/// level is one remembered choice for every task.
struct AgentAccessPopover: View {
    @EnvironmentObject private var app: AppState
    @ObservedObject var controller: AgentSessionController
    let model: AgentSessionController.ModelContext
    let choose: (AgentApprovalMode) -> Void
    @State private var resolvedReasoning: ResolvedReasoningSupport?

    private var localized: (String) -> String { app.settings.appLanguage.catalog }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Access").font(.scaled(.headline)).accessibilityAddTraits(.isHeader)
                Spacer()
                Text("All tasks").font(.scaled(.callout)).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 10) {
                ForEach(AgentApprovalMode.allCases) { mode in level(mode) }
            }
            Text("Editing LokalBot’s own data files always asks first.")
                .font(.scaled(.callout)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            modelRows
        }
        .padding(16)
        .frame(width: 360)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("agent.accessPopover")
    }

    private func level(_ mode: AgentApprovalMode) -> some View {
        let selected = mode == controller.approvalMode
        return Button { choose(mode) } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? Brand.teal : Color.secondary)
                    .padding(.top, 1).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: localized(mode.levelTitle)).font(AppFont.scaled(.body).weight(.semibold))
                    Text(verbatim: mode.levelDetail(workspaceName: controller.workspaceDisplayName, localize: localized))
                        .font(.scaled(.callout))
                        .foregroundStyle(mode.needsCaution ? LBTokens.Palette.attentionText : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
        .accessibilityIdentifier("agent.access.\(mode.rawValue)")
    }

    // MARK: - Model and reasoning

    static func destinationLabel(_ destination: InferencePresentation, localize: (String) -> String) -> String {
        switch destination {
        case .onDevice: localize("On this Mac")
        case .remote(let host): String(format: localize("Remote · %@"), host)
        case .blocked: localize("Model connection blocked")
        }
    }

    @ViewBuilder private var modelRows: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 10) {
            GridRow {
                Text("Model").foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline) {
                    Text(verbatim: "\(model.name) · \(Self.destinationLabel(model.destination, localize: localized))")
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button("Change…") { app.openSettings(tab: .models) }
                        .buttonStyle(.workspaceLink).accessibilityIdentifier("agent.changeModel")
                }
            }
            if reasoningSupport.isAdjustable {
                GridRow {
                    Text("Reasoning").foregroundStyle(.secondary)
                    reasoningMenu
                }
            }
        }
        .font(.scaled(.callout))
        if case .remote(let host) = model.destination {
            Text("Your messages, attached context and what the agent reads are sent to \(host).")
                .font(.scaled(.callout)).foregroundStyle(LBTokens.Palette.attentionText)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("agent.remoteNote")
        }
        if controller.modelContext != nil, controller.modelContext != .init(settings: app.settings) {
            Text("New tasks use the model selected in Settings.")
                .font(.scaled(.callout)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The launched model's levels, or the selected model's before launch.
    private var reasoningSupport: ReasoningSupport {
        controller.reasoningSupport ?? resolvedReasoning?.support(for: app.settings) ?? .known(for: app.settings)
    }

    /// Agent Mode's own level, or the Think level from Settings → Models,
    /// offering only the levels the model accepts.
    private var reasoningMenu: some View {
        let support = reasoningSupport
        let chosen = app.settings.agentReasoningLevel
        let shown = support.displayed(app.settings.effectiveAgentReasoningLevel)
        let checked = chosen.map(support.displayed)
        let sameAsThink = "Same as Think (\(support.displayed(app.settings.thinkReasoningLevel).displayName))"
        func choose(_ level: ThinkReasoningLevel?) {
            app.settings.agentReasoningLevel = level
            controller.reasoningLevelDidChange()
        }
        return Menu {
            Button {
                choose(nil)
            } label: {
                if chosen == nil { Label(sameAsThink, systemImage: "checkmark") } else { Text(sameAsThink) }
            }
            Divider()
            ForEach([ThinkReasoningLevel.automatic] + support.levels) { level in
                Button {
                    choose(level)
                } label: {
                    let title = level == .automatic ? support.automaticTitle : level.displayName
                    if checked == level {
                        Label(title, systemImage: "checkmark")
                    } else {
                        Text(title)
                    }
                }
            }
        } label: { Text(shown.displayName).lineLimit(1) }
            .fixedSize()
            .help("How much the agent reasons before each step, from the levels this model accepts. "
                  + "Same as Think follows Settings → Models. A change applies from the agent's next step.")
            .accessibilityLabel("Agent reasoning level")
            .accessibilityValue(chosen == nil ? "Same as Think, \(shown.displayName)" : shown.displayName)
            .accessibilityIdentifier("agent.reasoning")
            .task(id: ReasoningSupport.lookupKey(for: app.settings)) {
                resolvedReasoning = await .resolve(for: app.settings)
            }
    }
}
