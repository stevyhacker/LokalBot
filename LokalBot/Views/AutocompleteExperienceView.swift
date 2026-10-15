import SwiftUI

/// Writing-settings readiness and preview. The real completion engine is used
/// without touching production acceptance statistics or the learning store.
struct AutocompleteExperienceView: View {
    @EnvironmentObject var app: AppState
    @ObservedObject private var permissions = PermissionManager.shared
    @ObservedObject private var stats = CotypingStatsStore.shared

    private static let openingText = "Hi Sarah, thanks for the update. I wanted to follow"

    @State private var text = AutocompleteExperienceView.openingText
    @State private var rehearsal = AutocompleteExperienceView.openingRehearsal
    /// What the visible suggestion drew on; nil until one has been generated.
    @State private var contextUse: CotypingContextUse?
    @State private var generating = false
    @State private var error: String?
    @State private var task: Task<Void, Never>?
    @State private var topUpTask: Task<Void, Never>?
    @State private var focusRevision = 0
    /// macOS's own inline predictions, read again each time LokalBot comes forward.
    @State private var systemPredictionsOn = AutocompleteExperienceView.readSystemPredictions()

    private static var openingRehearsal: CotypingRehearsal {
        var rehearsal = CotypingRehearsal()
#if LOKALBOT_UI_TEST_HOST
        if ProcessInfo.processInfo.environment["LOKALBOT_COTYPING_DEMO"] == "1" {
            rehearsal.present(" up on the migration timeline we scoped yesterday.", after: openingText)
        }
#endif
        return rehearsal
    }

    private var selectedModel: ModelCatalog.Entry? {
        ModelCatalog.entry(
            id: app.settings.cotypingBuiltInModelID,
            custom: app.settings.customBuiltInModels)
    }

    private var modelReady: Bool {
#if LOKALBOT_UI_TEST_HOST
        if ProcessInfo.processInfo.environment["LOKALBOT_COTYPING_DEMO"] == "1" { return true }
#endif
        guard !usesServer else { return serverSetupProblem == nil }
        return selectedModel.flatMap { ModelCatalog.localURL(for: $0, storage: app.storage) } != nil
    }

    /// Autocomplete runs on a server: nothing to download, only setup to finish.
    private var usesServer: Bool { app.settings.cotypingBackend != .onDevice }

    /// What to change before the selected server can be used.
    private var serverSetupProblem: String? {
        if case .unavailable(let reason) = app.settings.cotypingRoute(includingCredentials: false) { return reason }
        return nil
    }

    /// The model suggestions come from, on this Mac or a server.
    private var modelName: String {
        usesServer ? app.settings.cotypingModelDisplayName : selectedModel?.displayName ?? "LFM2.5 1.2B Instruct"
    }

    private var demoReady: Bool {
#if LOKALBOT_UI_TEST_HOST
        ProcessInfo.processInfo.environment["LOKALBOT_COTYPING_DEMO"] == "1"
#else
        false
#endif
    }

    /// The context grants a suggestion depends on.
    private var contextGrants: [Bool] {
        [app.settings.cotypingUseVisibleContext, app.settings.cotypingUseMeetingMemory,
         app.settings.cotypingUseScreenMemory]
    }

    private var contextStatuses: [CotypingContextStatus] {
        CotypingContextStatus.rehearsal(
            availability: app.cotypingContextAvailability(
                accessibilityGranted: demoReady || (permissions.granted[.accessibility] ?? false)),
            use: contextUse)
    }

    /// Returns Form sections: a readiness summary, then the live preview. Both
    /// use the Settings row type scale instead of nested workspace panels, and
    /// the preview stays near the top of Writing without scrolling.
    var body: some View {
        Group {
            Section {
                summary
                if app.settings.cotypingEnabled && systemPredictionsOn {
                    systemPredictionsNotice
                }
                if let serverSetupProblem, usesServer {
                    Label(serverSetupProblem, systemImage: "exclamationmark.triangle")
                        .font(AppFont.scaled(.callout))
                        .settingsSecondary()
                        .fixedSize(horizontal: false, vertical: true)
                } else if !modelReady {
                    CotypingModelPreparationView(compact: true)
                }
            }
            Section("Try the real autocomplete") {
                preview
                    .settingTarget("settings.autocompletePreview", selected: app.focusedSettingID)
                DisclosureGroup("Usage and timing") { usage }
            }
        }
        .onDisappear { task?.cancel() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            systemPredictionsOn = Self.readSystemPredictions()
        }
    }

    private static func readSystemPredictions() -> Bool {
#if LOKALBOT_UI_TEST_HOST
        // The test runner's own keyboard settings must not change the layout under test.
        return ProcessInfo.processInfo.environment["LOKALBOT_SYSTEM_PREDICTIONS_ON"] == "1"
#else
        return CotypingSystemInlinePredictions.isOn()
#endif
    }

    /// Two grey suggestions at the same caret look broken, so ask for the
    /// macOS one to be turned off, as Cotypist does.
    private var systemPredictionsNotice: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("macOS can show its own inline predictions where you type, so two suggestions may appear at once. Turn off “Show inline predictive text” in Keyboard → Text Input → Edit….",
                  systemImage: "exclamationmark.triangle")
                .workspaceTextRole(.warning)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open Keyboard Settings") {
                NSWorkspace.shared.open(CotypingSystemInlinePredictions.keyboardSettingsURL)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("autocomplete.systemPredictions")
    }

    /// Counters and timings from typing in other apps. They answer what a
    /// model benchmark cannot: whether suggestions arrive in time, whether an
    /// accepted one lands in the field, and whether it is kept.
    private var usage: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                StatTile(icon: "text.badge.plus", value: "\(stats.stats.generations)", label: "suggested")
                StatTile(icon: "checkmark", value: "\(stats.stats.accepts)", label: "accepted")
            }
            let rows = stats.stats.liveRows
            if !rows.isEmpty {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                    GridRow {
                        Text("Where")
                        Text("Shown")
                        Text("Keystroke to visible")
                        Text("Accepted")
                        Text("Arrived in the field")
                        Text("Taken back")
                    }
                    .fontWeight(.semibold)
                    ForEach(rows, id: \.title) { row in
                        GridRow {
                            Text(row.title)
                            Text("\(row.measure.shown)")
                            Text(Self.timing(row.measure))
                            Text("\(row.measure.accepts)")
                            Text(Self.insertions(row.measure))
                            Text("\(row.measure.acceptsCorrected)")
                        }
                        .monospacedDigit()
                    }
                }
                .font(AppFont.scaled(.callout))
                .accessibilityIdentifier("autocomplete.measurements")
            }
            HStack {
                Button("Copy measurements") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(
                        stats.stats.report(model: usesServer ? app.settings.cotypingModelDisplayName
                                           : selectedModel?.displayName ?? app.settings.cotypingBuiltInModelID),
                        forType: .string)
                }
                Button("Reset") { stats.clear() }
                    .disabled(stats.stats == CotypingStats())
            }
            SettingsHelp("Measured while you type in other apps: the wait from your last keystroke to a visible suggestion, whether accepted text arrived in the field, and whether you deleted or undid it straight away. Counts and timings only, kept on this Mac; no text, app names or window titles are stored.")
        }
        .padding(.top, 8)
    }

    private static func timing(_ measure: CotypingLiveMeasure) -> String {
        guard let median = measure.medianVisibleMs else { return "n/a" }
        return "\(median) ms (p95 \(measure.p95VisibleMs ?? median))"
    }

    private static func insertions(_ measure: CotypingLiveMeasure) -> String {
        var text = "\(measure.insertionsConfirmed) of \(measure.insertionsChecked)"
        if measure.insertionsUnconfirmed > 0 { text += ", \(measure.insertionsUnconfirmed) not readable" }
        return text
    }

    /// The page's switch sits with what it controls: whether autocomplete is
    /// on, which model it uses, and whether it can run.
    private var summary: some View {
        HStack(alignment: .top, spacing: 12) {
            IconTile(systemImage: "text.cursor",
                     tint: app.settings.cotypingEnabled ? Brand.teal : Color(nsColor: .systemGray),
                     size: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(app.settings.cotypingEnabled ? "Autocomplete on" : "Autocomplete off")
                        .font(AppFont.scaled(.body).weight(.semibold))
                    Text(summaryDetail)
                        .font(AppFont.scaled(.callout))
                        .settingsSecondary()
                        .fixedSize(horizontal: false, vertical: true)
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 14) { readiness }
                    VStack(alignment: .leading, spacing: 6) { readiness }
                }
            }
            Spacer(minLength: 12)
            Toggle("Enable autocomplete", isOn: $app.settings.cotypingEnabled)
                .labelsHidden()
                .accessibilityLabel("Enable autocomplete")
                .settingTarget("settings.cotypingEnabled", selected: app.focusedSettingID)
        }
        .padding(.vertical, 4)
        .accessibilityIdentifier("autocomplete.home")
    }

    @ViewBuilder private var readiness: some View {
        MemoryHealthStatus(value: usesServer ? (modelReady ? "Server ready" : "Server setup needed")
                                             : (modelReady ? "Model ready" : "Model needed"),
                           tone: modelReady ? .good : .attention)
            .help(modelName)
        permissionStatus("Accessibility", .accessibility)
        permissionStatus("Input Monitoring", .inputMonitoring)
    }

    private var summaryDetail: String {
        if app.settings.cotypingEnabled { return "\(modelName) · suggestions appear as you type in other apps." }
        if usesServer {
            return modelReady
                ? "The server is ready. Turn on autocomplete to start."
                : "Finish setting up the autocomplete server below to try it."
        }
        return modelReady
            ? "The model is ready. Turn on autocomplete to start."
            : "Download the Autocomplete model to try it."
    }

    private func permissionStatus(_ title: String, _ permission: AppPermission) -> some View {
        let granted = demoReady || (permissions.granted[permission] ?? false)
        return MemoryHealthStatus(value: granted ? "\(title) granted" : "\(title) needed",
                                  tone: granted ? .good : .attention)
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 10) {
            conversation
            RehearsalTextEditor(text: $text, suggestion: rehearsal.ghost,
                                acceptKey: app.settings.cotypingAcceptKey,
                                fullAcceptKey: app.settings.cotypingFullAcceptKey,
                                focusRevision: focusRevision,
                                onAccept: { accept($0) },
                                onReject: { dismiss() })
                .frame(minHeight: 76)
                .padding(4)
                .background(Color(nsColor: .textBackgroundColor),
                            in: RoundedRectangle(cornerRadius: Brand.Radius.control))
                .overlay {
                    RoundedRectangle(cornerRadius: Brand.Radius.control)
                        .strokeBorder(Color(nsColor: .separatorColor))
                        .allowsHitTesting(false)
                }
                .onChange(of: text) { _, updated in
                    // An accept or typing the suggested characters keeps the
                    // rest of the ghost, as in another app; anything else is stale.
                    switch rehearsal.textChanged(to: updated) {
                    case .stale: schedule()
                    case .advanced: topUp()
                    case .unchanged: break
                    }
                }
                .onChange(of: contextGrants) { _, _ in
                    // Re-run a rehearsal that is in use so the change shows at
                    // once; a setting alone should not load the model.
                    if contextUse != nil || !rehearsal.ghost.isEmpty || generating { schedule() }
                }

            HStack {
                Text(CotypingAcceptHint.text(
                    acceptKey: app.settings.cotypingAcceptKey,
                    fullAcceptKey: app.settings.cotypingFullAcceptKey,
                    granularity: app.settings.cotypingAcceptGranularity))
                    .font(AppFont.scaled(.callout))
                    .settingsSecondary()
                    .accessibilityIdentifier("autocomplete.rehearsal.hint")
                if generating { ProgressView().controlSize(.small) }
                Spacer()
                Button("Insert suggestion") { accept(.whole) }
                    .primaryActionButton()
                    .disabled(rehearsal.ghost.isEmpty)
                    // The text the button would insert: the ghost is painted,
                    // so this is how assistive technology can read it.
                    .accessibilityValue(rehearsal.ghost)
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(AppFont.scaled(.callout)).foregroundStyle(Brand.error)
            }
            contextSources
        }
    }

    /// A synthetic exchange the reply answers. It is the "text above the field"
    /// for this rehearsal, so the visible-text setting has something to read.
    private var conversation: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Sample conversation")
                .font(AppFont.scaled(.callout).weight(.semibold))
                .settingsSecondary()
            ForEach(CotypingRehearsalConversation.sample) { message in
                (Text(message.sender).fontWeight(.semibold) + Text("  " + message.text))
                    .font(AppFont.scaled(.callout))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("autocomplete.rehearsal.conversation")
    }

    /// Which optional sources shaped the suggestion on screen, with source
    /// names and states in aligned columns.
    private var contextSources: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Context for this suggestion")
                .font(AppFont.scaled(.callout).weight(.semibold))
                .settingsSecondary()
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 5) {
                ForEach(contextStatuses) { status in
                    GridRow(alignment: .firstTextBaseline) {
                        StatusDot(color: color(for: status.tone), size: 7)
                            .accessibilityHidden(true)
                        Text(status.title)
                            .foregroundStyle(status.tone == .off ? Color.secondary : Color.primary)
                            .fixedSize()
                            // One element with an explicit label: combining the
                            // dot and the styled text left assistive technology
                            // with an empty label.
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("\(status.title): \(status.detail)")
                            .accessibilityIdentifier("autocomplete.rehearsal.context.\(status.id)")
                        detailText(status)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.leading, 6)
                            .accessibilityHidden(true)
                    }
                }
            }
            .font(AppFont.scaled(.callout))
        }
        .padding(.top, 2)
    }

    @ViewBuilder private func detailText(_ status: CotypingContextStatus) -> some View {
        if status.tone == .attention {
            Text(status.detail).foregroundStyle(LBTokens.Palette.attentionText)
        } else {
            Text(status.detail).settingsSecondary()
        }
    }

    private func color(for tone: CotypingContextStatus.Tone) -> Color {
        switch tone {
        case .used: Brand.teal
        case .attention: Brand.amber
        case .ready, .off: Color.secondary
        }
    }

    private func schedule() {
        task?.cancel()
        topUpTask?.cancel()
        rehearsal.dismiss()
        error = nil
        contextUse = nil
        let context = text
        guard !context.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        task = Task {
            try? await Task.sleep(for: .milliseconds(app.settings.cotypingDebounceMs))
            guard !Task.isCancelled else { return }
            generating = true
            defer { generating = false }
            do {
                let result: CotypingPreview
#if LOKALBOT_UI_TEST_HOST
                if demoReady { result = CotypingPreview(text: " up on the synthetic review.") } else {
                    result = try await app.cotyping.preview(
                        precedingText: context, conversation: CotypingRehearsalConversation.sample)
                }
#else
                result = try await app.cotyping.preview(
                    precedingText: context, conversation: CotypingRehearsalConversation.sample)
#endif
                // Never show a suggestion for text that has since changed.
                if !Task.isCancelled, text == context {
                    rehearsal.present(result.text, after: context,
                                      wordLimit: app.settings.cotypingMaxWords)
                    contextUse = result.use
                }
            } catch is CancellationError {
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
    }

    /// One accept keypress, planned by the same code as a live field: the
    /// accept key takes the configured word or phrase and leaves the rest.
    private func accept(_ scope: CotypingAcceptScope) {
        guard let updated = rehearsal.accept(scope, text: text,
                                             options: .init(settings: app.settings)) else { return }
        text = updated
        topUp()
    }

    /// Keeps the ghost a few words ahead while it is accepted or typed
    /// through, by the same rules as a live field.
    private func topUp() {
        let limit = app.settings.cotypingMaxWords
        guard let prefix = rehearsal.topUpPrefix(wordLimit: limit) else { return }
        topUpTask?.cancel()
        topUpTask = Task {
            guard let more = try? await app.cotyping.preview(
                precedingText: prefix, conversation: CotypingRehearsalConversation.sample,
                maxWords: CotypingSuggestionExtension.topUpWordLimit(wordLimit: limit)),
                  !Task.isCancelled else { return }
            if rehearsal.topUp(with: more.text, continuing: prefix, wordLimit: limit) { topUp() }
        }
    }

    private func dismiss() {
        task?.cancel()
        topUpTask?.cancel()
        rehearsal.dismiss()
        // No suggestion is on screen any more, so there is nothing its
        // context rows could describe.
        contextUse = nil
        generating = false
    }
}

/// The effective state of an optional context source, shown under its switch:
/// nothing while the switch is off, otherwise whether it can contribute now.
struct CotypingContextStateLabel: View {
    @Environment(\.colorScheme) private var scheme
    let state: CotypingContextAvailability.State

    var body: some View {
        if let message = state.message {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                StatusDot(color: dotColor, size: 7)
                if case .unavailable = state {
                    Text(message).foregroundStyle(SettingsPalette.warning(scheme))
                } else {
                    Text(message).settingsSecondary()
                }
            }
            .font(AppFont.scaled(.callout))
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
        }
    }

    private var dotColor: Color {
        switch state {
        case .available: Brand.teal
        case .unavailable: Brand.amber
        case .off, .nothingSaved: Color.secondary
        }
    }
}
