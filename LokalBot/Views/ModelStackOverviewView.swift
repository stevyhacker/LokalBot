import SwiftUI

struct ModelStackOverviewView: View {
    @ObservedObject var app: AppState
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @ObservedObject private var roles: ModelRoles
    @ObservedObject private var checks: ModelCheckController
    @ObservedObject private var setup: ModelSetupController
    let present: (ModelsSettingsSheet) -> Void
    let connections: () -> Void

    init(app: AppState, present: @escaping (ModelsSettingsSheet) -> Void, connections: @escaping () -> Void) {
        self.app = app
        roles = app.modelRoles
        checks = app.modelChecks
        setup = app.modelSetup
        self.present = present
        self.connections = connections
    }

    private var snapshot: ModelRolesSnapshot {
#if LOKALBOT_UI_TEST_HOST
        if ProcessInfo.processInfo.environment["LOKALBOT_MODELS_DEMO_READY"] == "1" {
            var snapshot = roles.snapshot
            snapshot.statuses = Dictionary(uniqueKeysWithValues: ModelRole.allCases.map { ($0, .ready) })
            return snapshot
        }
#endif
        return roles.snapshot
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 18) {
                Text("Current setup").font(.system(size: 14, weight: .semibold))
                Text((ModelStackPreset.matching(app.settings)?.title ?? "Custom")
                     + " · " + ModelSettingsPresentation.setupLocation(app.settings))
                    .font(.system(size: 13)).settingsSecondary()
                Spacer(minLength: 8)
                Button("Choose preset…") { present(.presets) }
                    .buttonStyle(.bordered)
                    .disabled(setup.pending != nil)
                    .accessibilityIdentifier("models.choosePreset")
            }
            .padding(.vertical, 4)
            VStack(alignment: .leading, spacing: 4) {
                Text("Core models").font(.system(size: 16, weight: .semibold))
                if checks.results.isEmpty, !checks.isTesting {
                    Text("Selected models have not been checked yet.")
                        .font(.system(size: 13)).settingsSecondary()
                }
                coreRow(.transcribe, model: app.settings.transcriptionModelDisplayName,
                        detail: "Meeting audio to text", sheet: .transcription)
                SettingsSeparator()
                coreRow(.think, model: ModelSettingsPresentation.assistantName(app.settings),
                        detail: "Summaries, Ask, and Agent", sheet: .assistant)
                SettingsSeparator()
                coreRow(.autocomplete, model: ModelCatalog.entry(
                    id: app.settings.cotypingBuiltInModelID,
                    custom: app.settings.customBuiltInModels)?.displayName ?? app.settings.cotypingBuiltInModelID,
                        detail: "Suggestions as you type", sheet: .autocomplete)
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
            .settingsPanel()
            processingBudget
                .padding(.horizontal, 16).padding(.vertical, 14)
                .settingsPanel()
            VStack(alignment: .leading, spacing: 4) {
                Text("Also used by LokalBot").font(.system(size: 16, weight: .semibold))
                    .padding(.bottom, 6)
                supportingRow("Dictation composition", icon: "text.bubble",
                              value: ModelSettingsPresentation.dictationLabel(app.settings),
                              detail: dictationDetail, sheet: .dictation)
                SettingsSeparator()
                supportingRow("Read aloud", icon: "speaker.wave.2",
                              value: "Kokoro 82M · On this Mac", sheet: .speech)
                SettingsSeparator()
                supportingRow("Search by meaning", icon: "magnifyingglass",
                              value: app.settings.semanticSearchEnabled
                                ? "Managed automatically · On this Mac" : "Off · On this Mac",
                              sheet: .search)
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
            .settingsPanel()
        }
        .controlSize(.regular)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("models.overview")
    }

    /// How much of a long meeting Think processes per pass. It applies to every
    /// Think backend, so it lives here rather than with one connection.
    private var processingBudget: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Think processing budget").font(.system(size: 16, weight: .semibold))
            Picker("Think processing budget", selection: $app.settings.generationBudgetPreset) {
                ForEach(GenerationBudgetPreset.allCases) { Text($0.displayName).tag($0) }
            }
            .labelsHidden().pickerStyle(.segmented).frame(maxWidth: 420)
            .accessibilityIdentifier("models.generationBudget")
            .settingTarget("settings.generationBudgetPreset", selected: app.focusedSettingID)
            Text("Applies to every Think model — built-in, Apple Intelligence, and servers. "
                 + app.settings.generationBudgetPreset.detail)
                .font(.system(size: 12)).settingsSecondary()
                .fixedSize(horizontal: false, vertical: true)
            if app.settings.generationBudgetPreset == .unlimited {
                Label("Unlimited removes practical caps: a single meeting can process for up to "
                      + "6 hours. On a paid API this can run up significant token costs; on a "
                      + "local model it can keep this Mac busy and hot for a long time.",
                      systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12)).foregroundStyle(Brand.error)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("models.generationBudget.warning")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var dictationDetail: String? {
        switch InferencePresentation(settings: app.settings.dictationCompositionTextEngineSettings) {
        case .remote: "Spoken requests are composed remotely."
        case .blocked: "The composition connection needs attention."
        case .onDevice: nil
        }
    }

    private func coreRow(_ role: ModelRole, model: String, detail: String, sheet: ModelsSettingsSheet) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 20) {
                roleHeading(role, detail: detail).frame(width: 200, alignment: .leading)
                modelSummary(role, model: model).frame(minWidth: 170, maxWidth: .infinity, alignment: .leading)
                changeButton(role, sheet: sheet)
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    roleHeading(role, detail: detail)
                    Spacer()
                    changeButton(role, sheet: sheet)
                }
                modelSummary(role, model: model).padding(.leading, 40)
            }
        }
        .padding(.vertical, 14)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(role.settingsTitle)
    }

    private func roleHeading(_ role: ModelRole, detail: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: role.settingsIcon)
                .font(.system(size: 19, weight: .regular)).frame(width: 30, height: 32)
                .settingsModelIcon(role == .think ? InferencePresentation(settings: app.settings) : .onDevice)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(role.settingsTitle).font(.system(size: 14, weight: .semibold))
                Text(detail).font(.system(size: 12)).settingsSecondary()
            }
        }
    }

    private func modelSummary(_ role: ModelRole, model: String) -> some View {
        let status = snapshot[role]
        let destination = role == .think ? InferencePresentation(settings: app.settings) : .onDevice
        return VStack(alignment: .leading, spacing: 4) {
            Text(model).font(.system(size: 14, weight: .semibold)).textSelection(.enabled)
            Label(locationLabel(role, status: status), systemImage: destination.icon)
                .font(.system(size: 12)).settingsModelLocation(destination)
            if checks.testingRole == role {
                Label("Checking…", systemImage: "ellipsis.circle")
                    .font(.system(size: 12)).settingsSecondary()
            } else if status.isReady, let result = checks.results[role] {
                Label(result.label, systemImage: result.failure == nil ? "checkmark.circle" : "exclamationmark.triangle")
                    .font(.system(size: 12))
                    .foregroundStyle(result.failure == nil
                        ? SettingsPalette.secondary(colorScheme, contrast: contrast) : SettingsPalette.warning(colorScheme))
                    .lineLimit(2)
                    .accessibilityIdentifier("models.stack.status.\(role.rawValue)")
            } else if destination.isBlocked {
                Button("Review connection…", action: connections)
                    .font(.system(size: 12)).buttonStyle(.workspaceLink)
            } else if !status.isReady {
                Label(status.label, systemImage: status.isWorking ? "arrow.down.circle" : "exclamationmark.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(status.isWorking
                        ? SettingsPalette.secondary(colorScheme, contrast: contrast) : SettingsPalette.warning(colorScheme))
                    .lineLimit(2)
                    .accessibilityIdentifier("models.stack.status.\(role.rawValue)")
            }
        }
    }

    private func locationLabel(_ role: ModelRole, status: ModelRoleStatus) -> String {
        if role == .think {
            switch app.settings.summarizerBackend {
            case .builtIn: return status.isReady ? "On this Mac · Downloaded" : "On this Mac"
            case .appleIntelligence: return "On this Mac · System model"
            case .ollama, .openAICompatible: return ModelSettingsPresentation.destination(app.settings)
            }
        }
        return status.isReady ? "On this Mac · Downloaded" : "On this Mac"
    }

    private func changeButton(_ role: ModelRole, sheet: ModelsSettingsSheet) -> some View {
        Button("Change…") { present(sheet) }
            .buttonStyle(.bordered)
            .frame(minWidth: 84)
            .disabled(setup.pending != nil)
            .accessibilityIdentifier("models.stack.change.\(role == .autocomplete ? "type" : role.rawValue)")
            .accessibilityLabel("Change \(role.settingsTitle) model")
    }

    private func supportingRow(_ title: String, icon: String, value: String,
                               detail: String? = nil, sheet: ModelsSettingsSheet) -> some View {
        let destination = sheet == .dictation
            ? InferencePresentation(settings: app.settings.dictationCompositionTextEngineSettings) : .onDevice
        return Button { present(sheet) } label: {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 17)).frame(width: 30, height: 30)
                    .settingsModelIcon(destination)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 13, weight: .medium))
                    if let detail { Text(detail).font(.system(size: 12)).settingsSecondary() }
                }
                Spacer(minLength: 12)
                Text(value).font(.system(size: 12)).settingsModelLocation(destination)
                    .multilineTextAlignment(.trailing).fixedSize(horizontal: false, vertical: true)
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).settingsSecondary()
            }
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("models.supporting.\(sheet.rawValue)")
    }

}
