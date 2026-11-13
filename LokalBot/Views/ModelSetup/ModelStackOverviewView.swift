import AppKit
import SwiftUI

/// Settings › Models: what each of the three models does, which one it is,
/// where it runs and whether it is ready; then rows that open the downloaded
/// models, the online services and the other models; then a folded group
/// for the rest.
struct ModelStackOverviewView: View {
    @ObservedObject var app: AppState
    @Environment(\.colorSchemeContrast) private var contrast
    @ObservedObject private var roles: ModelRoles
    @ObservedObject private var checks: ModelCheckController
    @ObservedObject private var setup: ModelSetupController
    @ObservedObject private var speech: ModelSpeechDownloadController
    @State private var resolvedReasoning: ResolvedReasoningSupport?
    /// Text and speech models found on disk, counted when something
    /// arrives or goes, not on every progress tick.
    @State private var modelFilesOnDisk = 0
    @SceneStorage("settings.models.advancedOpen") private var advancedOpen = false
    let present: (ModelsSettingsSheet) -> Void
    let open: (ModelsSettingsPage) -> Void
    let choosePreset: (ModelStackPreset) -> Void

    init(app: AppState, present: @escaping (ModelsSettingsSheet) -> Void,
         open: @escaping (ModelsSettingsPage) -> Void, choosePreset: @escaping (ModelStackPreset) -> Void) {
        self.app = app
        roles = app.modelRoles
        checks = app.modelChecks
        setup = app.modelSetup
        speech = app.speechModelDownload
        self.present = present
        self.open = open
        self.choosePreset = choosePreset
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

    private var localized: (String) -> String { app.settings.appLanguage.catalog }

    private var presentation: ModelsPagePresentation {
        ModelsPagePresentation(
            settings: app.settings, statuses: snapshot.statuses,
            checks: ModelCheckSummary(testing: checks.testingRole,
                                      failures: checks.results.compactMapValues(\.failure)))
    }

    /// Search and deep links that land on a setting under Advanced open it.
    private var advancedExpanded: Binding<Bool> {
        Binding(get: { advancedOpen || Self.advancedSettings.contains(app.focusedSettingID ?? "") },
                set: { advancedOpen = $0 })
    }

    static let advancedSettings: Set<String> = [
        "settings.thinkReasoningLevel", "settings.generationBudgetPreset", "settings.modelDownloadSource",
    ]

    var body: some View {
        let presentation = presentation
        VStack(alignment: .leading, spacing: 22) {
            group("What each model does", identifier: "models.heading.roles") {
                modelSetRow(presentation)
                ForEach(presentation.rows) { row in
                    SettingsSeparator()
                    roleRow(row)
                }
            }
            group("More", identifier: "models.heading.more") {
                moreRow(.downloaded, title: "Downloaded models", detail: "Delete ones you no longer use",
                        value: downloadedSummary)
                SettingsSeparator()
                moreRow(.connections, title: "Online services", detail: "Your AI subscription, or a server you run",
                        value: onlineSummary)
                SettingsSeparator()
                moreRow(.other, title: "Other models", detail: "Read aloud, search by meaning, Dictation’s Compose",
                        value: localized("On this Mac"))
            }
            advanced
        }
        .controlSize(.regular)
        .onAppear { speech.refresh() }
        .task(id: roles.revision) { modelFilesOnDisk = countModelFiles() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("models.overview")
    }

    private func group<Content: View>(_ title: String, identifier: String,
                                      @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(LocalizedStringKey(title)).font(.scaled(.headline))
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier(identifier)
            VStack(alignment: .leading, spacing: 0, content: content)
                .padding(.horizontal, 16).padding(.vertical, 4)
                .settingsPanel()
        }
    }

    // MARK: - Model set

    private func modelSetRow(_ presentation: ModelsPagePresentation) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Model set").font(.scaled(.body).weight(.medium))
                Text(verbatim: presentation.modelSetHelp.string(localized))
                    .font(.scaled(.callout)).settingsSecondary()
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            // Choosing a set opens its review, which lists the changes and
            // the download before anything is applied. A native pull-down:
            // SwiftUI's Menu gives assistive tools no way to open it.
            WorkspaceMenu(
                title: localized(presentation.modelSet?.title ?? "Custom"),
                label: localized("Model set"),
                identifier: "models.choosePreset",
                items: ModelStackPreset.allCases.map { preset in
                    WorkspaceMenu.Item(title: menuTitle(preset), identifier: "models.preset.\(preset.rawValue)",
                                       enabled: preset != presentation.modelSet,
                                       selected: preset == presentation.modelSet,
                                       action: { choosePreset(preset) })
                },
                font: .systemFont(ofSize: NSFont.systemFontSize))
                .fixedSize()
                .padding(.leading, 4)
                .background(Color(nsColor: .controlBackgroundColor),
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.primary.opacity(contrast == .increased ? 0.5 : 0.14))
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                .disabled(setup.pending != nil)
        }
        .padding(.vertical, 12)
    }

    private func menuTitle(_ preset: ModelStackPreset) -> String {
        guard let bytes = ModelsPagePresentation.bytes(of: preset, settings: app.settings) else {
            return localized(preset.title)
        }
        return "\(localized(preset.title)) · \(SettingsStatus.size(bytes))"
    }

    // MARK: - Roles

    private func roleRow(_ row: ModelRoleRow) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 16) {
                roleHeading(row).frame(width: 256, alignment: .leading)
                // A long model name wraps instead of pushing the row onto two levels.
                modelSummary(row).frame(minWidth: 150, idealWidth: 170, maxWidth: .infinity, alignment: .leading)
                chip(row)
                changeButton(row.role)
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    roleHeading(row)
                    Spacer(minLength: 8)
                    chip(row)
                    changeButton(row.role)
                }
                modelSummary(row).padding(.leading, 42)
            }
        }
        .padding(.vertical, 12)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(LocalizedStringKey(row.role.settingsTitle)))
    }

    private func roleHeading(_ row: ModelRoleRow) -> some View {
        HStack(spacing: 10) {
            IconTile(systemImage: row.role.settingsIcon, tint: tint(row.place), size: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(LocalizedStringKey(row.role.settingsTitle)).font(.scaled(.body).weight(.medium))
                Text(LocalizedStringKey(row.job)).font(.scaled(.callout)).settingsSecondary()
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func tint(_ place: ModelRoleRow.Place) -> Color {
        place == .thisMac ? Brand.teal : LBTokens.Palette.attentionText
    }

    private func modelSummary(_ row: ModelRoleRow) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(verbatim: row.name).font(.scaled(.body).weight(.semibold))
                .lineLimit(2).truncationMode(.middle)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Label {
                Text(verbatim: row.placeText.string(localized))
            } icon: {
                Image(systemName: row.place == .thisMac ? "laptopcomputer" : row.place == .notSetUp
                      ? "exclamationmark.triangle" : "globe")
            }
            .font(.scaled(.callout))
            .foregroundStyle(row.place == .thisMac ? AnyShapeStyle(.secondary)
                             : AnyShapeStyle(LBTokens.Palette.attentionText))
            if row.role == .think, let plan = SubscriptionPlan(backend: app.settings.summarizerBackend),
               plan.isApproved(in: app.settings) {
                Link("Manage usage", destination: plan.manageUsageURL).font(.scaled(.callout))
                    .accessibilityIdentifier("models.stack.planUsage")
            }
            if let problem = row.problem {
                Text(verbatim: problem)
                    .font(.scaled(.callout)).foregroundStyle(LBTokens.Palette.attentionText)
                    .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("models.stack.status.\(row.role.rawValue)")
            }
            if row.place == .notSetUp {
                Button("Review Connection…") { reviewConnection(row.role) }
                    .font(.scaled(.callout)).buttonStyle(.workspaceLink)
            }
        }
    }

    /// Each server is set up where it is chosen: Think's on Online services,
    /// the other two in their own pickers.
    private func reviewConnection(_ role: ModelRole) {
        switch role {
        case .transcribe: present(.transcription)
        case .think: open(.connections)
        case .autocomplete: present(.autocomplete)
        }
    }

    private func chip(_ row: ModelRoleRow) -> some View {
        let tone = row.chipTone
        let color: Color = tone == .good ? LBTokens.Palette.successText
            : tone == .attention ? LBTokens.Palette.attentionText : .secondary
        let fill: Color = tone == .good ? LBTokens.Palette.success
            : tone == .attention ? LBTokens.Palette.attention : .secondary
        return Text(verbatim: row.chip.text.string(localized))
            .font(.scaled(.caption).weight(.medium).monospacedDigit())
            .foregroundStyle(color)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(fill.opacity(LBTokens.Palette.statusFillOpacity + 0.04), in: Capsule())
            .help(checkedHelp(row.role))
            .accessibilityIdentifier("models.stack.chip.\(row.role.rawValue)")
    }

    /// When the model last answered its check, for the chip's tooltip.
    private func checkedHelp(_ role: ModelRole) -> String {
        guard let result = checks.results[role], result.failure == nil, snapshot[role].isReady else { return "" }
        return String(format: localized("Checked at %@"),
                      result.checkedAt.formatted(date: .omitted, time: .shortened))
    }

    private func changeButton(_ role: ModelRole) -> some View {
        Button("Change…") { present(sheet(for: role)) }
            .buttonStyle(.bordered)
            .disabled(setup.pending != nil)
            .accessibilityIdentifier("models.stack.change.\(role == .autocomplete ? "type" : role.rawValue)")
            .accessibilityLabel("Change \(role.settingsTitle) model")
    }

    private func sheet(for role: ModelRole) -> ModelsSettingsSheet {
        switch role {
        case .transcribe: .transcription
        case .think: .assistant
        case .autocomplete: .autocomplete
        }
    }

    // MARK: - More

    private func moreRow(_ page: ModelsSettingsPage, title: String, detail: String, value: String) -> some View {
        Button { open(page) } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(LocalizedStringKey(title)).font(.scaled(.body).weight(.medium))
                    Text(LocalizedStringKey(detail)).font(.scaled(.callout)).settingsSecondary()
                }
                Spacer(minLength: 12)
                Text(verbatim: value).font(.scaled(.callout)).settingsSecondary()
                    .lineLimit(1).truncationMode(.middle)
                Image(systemName: "chevron.forward").font(.system(size: 11, weight: .semibold)).settingsSecondary()
                    .accessibilityHidden(true)
            }
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("models.more.\(page.rawValue)")
    }

    /// How many models are on this Mac, counted the way Downloaded lists them.
    private var downloadedSummary: String {
        let count = modelFilesOnDisk + (speech.isDownloaded ? 1 : 0)
        return count > 0 ? String(count) : localized("None yet")
    }

    private func countModelFiles() -> Int {
        let files = (ModelCatalog.entries + app.settings.customBuiltInModels)
            .reduce(into: Set<String>()) { files, entry in
                if ModelCatalog.localURL(for: entry, storage: app.storage) != nil { files.insert(entry.fileName) }
            }
        let speechModels = roles.downloadedTranscriptionModelIDs
            .filter { TranscriptionModelChoice(rawValue: $0)?.isRemote == false }
        return files.count + speechModels.count
    }

    /// The services approved to receive something, or that none is.
    private var onlineSummary: String {
        let origins = app.settings.approvedRemoteInferenceOrigins + app.settings.approvedRemoteTranscriptionOrigins
        let names = origins.reduce(into: [String]()) { names, origin in
            // A server by its host, a subscription by its name.
            let name = URL(string: origin)?.host ?? SubscriptionPlan.approvalDisplayName(origin)
            if !names.contains(name) { names.append(name) }
        }
        return names.isEmpty ? localized("None set up") : names.joined(separator: ", ")
    }

    // MARK: - Advanced

    private var advanced: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                advancedExpanded.wrappedValue.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: advancedExpanded.wrappedValue ? "chevron.down" : "chevron.forward")
                        .font(.system(size: 10, weight: .semibold)).frame(width: 12)
                        .accessibilityHidden(true)
                    Text("Advanced").font(.scaled(.headline))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Advanced")
            .accessibilityValue(Text(advancedExpanded.wrappedValue ? "Expanded" : "Collapsed"))
            .accessibilityIdentifier("models.advanced")
            if advancedExpanded.wrappedValue {
                VStack(alignment: .leading, spacing: 0) {
                    if app.settings.summarizerBackend != .appleIntelligence {
                        reasoningRow
                        SettingsSeparator()
                    }
                    budgetRow
                    SettingsSeparator()
                    ModelDownloadSourcePicker(source: $app.settings.modelDownloadSource,
                                              accessibilityIdentifier: "models.downloadSource")
                        .padding(.vertical, 12)
                        .settingTarget("settings.modelDownloadSource", selected: app.focusedSettingID)
                    SettingsSeparator()
                    ModelStorageRow(app: app)
                    SettingsSeparator()
                    checksRow
                }
                .padding(.horizontal, 16).padding(.vertical, 4)
                .settingsPanel()
            }
        }
    }

    private func advancedRow<Control: View>(_ title: String, detail: String,
                                            @ViewBuilder control: () -> Control) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(LocalizedStringKey(title)).font(.scaled(.body).weight(.medium))
                Text(verbatim: detail).font(.scaled(.callout)).settingsSecondary()
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            control()
        }
        .padding(.vertical, 12)
    }

    private var reasoningSupport: ReasoningSupport {
        resolvedReasoning?.support(for: app.settings) ?? .known(for: app.settings)
    }

    /// Offers only the levels the selected model accepts (see
    /// `ReasoningSupport`); a stored level it lacks shows as the one it maps to.
    private var reasoningRow: some View {
        let support = reasoningSupport
        return advancedRow("How long Think reasons",
                           detail: localized("Automatic lets each task decide. A level sets the most any task uses.")) {
            if support.isAdjustable {
                Picker("Reasoning", selection: Binding(
                    get: { support.displayed(app.settings.thinkReasoningLevel) },
                    set: { app.settings.thinkReasoningLevel = $0 })) {
                    Text(LocalizedStringKey(support.automaticTitle)).tag(ThinkReasoningLevel.automatic)
                    ForEach(support.levels) { Text($0.displayName).tag($0) }
                }
                .labelsHidden().pickerStyle(.menu).fixedSize()
                .accessibilityLabel("Think reasoning level")
                .accessibilityIdentifier("models.think.reasoning")
            } else {
                Text("Set by the model").font(.scaled(.callout)).settingsSecondary()
                    .accessibilityIdentifier("models.think.reasoning")
            }
        }
        .help("How much the Think model reasons before it answers in summaries and Ask. The levels are the "
              + "ones this model accepts. Automatic keeps LokalBot's per-task amounts and the server's own "
              + "default. A level sets the most any task uses. Agent Mode follows this unless you pick its "
              + "own level in the Agent composer.")
        .settingTarget("settings.thinkReasoningLevel", selected: app.focusedSettingID)
        .task(id: ReasoningSupport.lookupKey(for: app.settings)) {
            resolvedReasoning = await .resolve(for: app.settings)
        }
    }

    /// How much of a long meeting Think processes per pass. It applies to every
    /// Think model, so it lives here rather than with one connection.
    private var budgetRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            advancedRow("Effort on long meetings",
                        detail: localized("More effort reads more of a long meeting, and takes longer. It applies to every Think model.")) {
                Picker("Think processing budget", selection: $app.settings.generationBudgetPreset) {
                    ForEach(GenerationBudgetPreset.allCases) { Text($0.displayName).tag($0) }
                }
                .labelsHidden().pickerStyle(.menu).fixedSize()
                .accessibilityLabel("Think processing budget")
                .accessibilityIdentifier("models.generationBudget")
            }
            Text(app.settings.generationBudgetPreset.detail)
                .font(.scaled(.callout)).settingsSecondary()
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, -12)
            if app.settings.generationBudgetPreset == .unlimited {
                Label("Unlimited removes practical caps: a single meeting can process for up to "
                      + "6 hours. On a paid API this can run up significant token costs; on a "
                      + "local model it can keep this Mac busy and hot for a long time.",
                      systemImage: "exclamationmark.triangle")
                    .font(.scaled(.callout)).foregroundStyle(Brand.error)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("models.generationBudget.warning")
            }
        }
        .padding(.bottom, app.settings.generationBudgetPreset.detail.isEmpty ? 0 : 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .settingTarget("settings.generationBudgetPreset", selected: app.focusedSettingID)
    }

    /// The checks run by themselves after a download, for models on this
    /// Mac. This is where to run them again, and the only place a model on
    /// a server is checked.
    private var checksRow: some View {
        advancedRow("Check the models",
                    detail: localized("Each model on this Mac is checked once after it downloads. An online model is checked only when you ask, because the check sends it a short sample.")) {
            Button("Check Setup…") { present(.checks) }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("models.testAll")
        }
        .settingTarget(SettingsStatus.modelChecksFocus, selected: app.focusedSettingID)
    }
}

/// Where the model files are and what is loaded now, under Advanced.
struct ModelStorageRow: View {
    @ObservedObject var app: AppState
    @ObservedObject private var roles: ModelRoles
    @ObservedObject private var residency = ModelResidency.shared

    init(app: AppState) {
        self.app = app
        roles = app.modelRoles
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Model Storage").font(.scaled(.body).weight(.medium))
                Text("Text models: \(roles.snapshot.storageSummary)").font(.scaled(.callout)).settingsSecondary()
                Text(memorySummary).font(.scaled(.callout)).settingsSecondary()
            }
            Spacer(minLength: 12)
            Button("Show in Finder") {
                let directory = app.storage.rootURL.appendingPathComponent("models", isDirectory: true)
                NSWorkspace.shared.selectFile(directory.path, inFileViewerRootedAtPath: app.storage.rootURL.path)
            }
            .buttonStyle(.bordered)
        }
        .padding(.vertical, 12)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("models.storage")
    }

    private var memorySummary: String {
        guard !residency.residents.isEmpty else { return "No models loaded in memory." }
        let used = ByteCountFormatter.string(fromByteCount: residency.totalBytes, countStyle: .memory)
        return "\(used) in memory · Models unload automatically when idle."
    }
}

/// The models that are not one of the three roles: Dictation's Compose,
/// reading aloud and search by meaning. Each opens the sheet it always had.
struct ModelOtherModelsView: View {
    @ObservedObject var app: AppState
    let present: (ModelsSettingsSheet) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            row("Dictation composition", icon: "text.bubble",
                value: ModelSettingsPresentation.dictationLabel(app.settings),
                detail: dictationDetail, sheet: .dictation)
            SettingsSeparator()
            row("Read aloud", icon: "speaker.wave.2", value: "Kokoro 82M · On this Mac", sheet: .speech)
            SettingsSeparator()
            row("Search by meaning", icon: "magnifyingglass",
                value: app.settings.semanticSearchEnabled ? "Managed automatically · On this Mac" : "Off · On this Mac",
                sheet: .search)
        }
        .padding(.horizontal, 16).padding(.vertical, 4)
        .settingsPanel()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("models.other")
    }

    private var dictationDetail: String? {
        switch InferencePresentation(settings: app.settings.dictationCompositionTextEngineSettings) {
        case .remote: "Spoken requests are composed remotely."
        case .blocked: "The composition connection needs attention."
        case .onDevice: nil
        }
    }

    private func row(_ title: String, icon: String, value: String,
                     detail: String? = nil, sheet: ModelsSettingsSheet) -> some View {
        let destination = sheet == .dictation
            ? InferencePresentation(settings: app.settings.dictationCompositionTextEngineSettings) : .onDevice
        return Button { present(sheet) } label: {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 17)).frame(width: 30, height: 30)
                    .settingsModelIcon(destination)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(LocalizedStringKey(title)).font(.scaled(.body).weight(.medium))
                    if let detail { Text(LocalizedStringKey(detail)).font(.scaled(.callout)).settingsSecondary() }
                }
                Spacer(minLength: 12)
                Text(value).font(.scaled(.callout)).settingsModelLocation(destination)
                    .multilineTextAlignment(.trailing).fixedSize(horizontal: false, vertical: true)
                Image(systemName: "chevron.forward").font(.system(size: 11, weight: .semibold)).settingsSecondary()
                    .accessibilityHidden(true)
            }
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("models.supporting.\(sheet.rawValue)")
    }
}
