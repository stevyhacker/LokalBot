import SwiftUI

/// What autocomplete runs on and whether it can run, shared by the page's
/// notices and the "Try it…" sheet.
@MainActor
struct AutocompleteReadiness {
    let app: AppState
    let server: RemoteCotypingEngine

    var demoReady: Bool {
#if LOKALBOT_UI_TEST_HOST
        ProcessInfo.processInfo.environment["LOKALBOT_COTYPING_DEMO"] == "1"
#else
        false
#endif
    }

    var selectedModel: ModelCatalog.Entry? {
        ModelCatalog.entry(id: app.settings.cotypingBuiltInModelID, custom: app.settings.customBuiltInModels)
    }

    /// Autocomplete runs on a server: nothing to download, only setup to finish.
    var usesServer: Bool { app.settings.cotypingBackend != .onDevice }

    var modelReady: Bool {
        if demoReady { return true }
        guard !usesServer else { return serverSetupProblem == nil }
        return selectedModel.flatMap { ModelCatalog.localURL(for: $0, storage: app.storage) } != nil
    }

    /// What to change before the selected server can be used.
    var serverSetupProblem: String? {
        guard usesServer, case .unavailable(let reason) = app.settings.cotypingRoute(includingCredentials: false)
        else { return nil }
        return reason
    }

    /// Why the selected server's last request brought no suggestion.
    var serverProblem: String? {
        guard usesServer, let problem = server.problem,
              case .server(let endpoint) = app.settings.cotypingRoute(includingCredentials: false),
              endpoint.identity == problem.identity else { return nil }
        return problem.message
    }

    /// The model suggestions come from, on this Mac or a server.
    var modelName: String {
        usesServer ? app.settings.cotypingModelDisplayName
            : selectedModel?.displayName ?? app.settings.cotypingBuiltInModelID
    }
}

/// What the Autocomplete page has to say that its header does not: macOS's
/// own predictions showing beside LokalBot's, and a server that is not set
/// up or has just failed. Nothing when there is nothing to say.
struct AutocompleteNotices: View {
    @EnvironmentObject private var app: AppState
    /// Autocomplete on a chosen server, for its last problem.
    @ObservedObject var server: RemoteCotypingEngine
    /// macOS's own inline predictions, read again each time LokalBot comes forward.
    @State private var systemPredictionsOn = AutocompleteNotices.readSystemPredictions()

    var body: some View {
        let readiness = AutocompleteReadiness(app: app, server: server)
        let showsPredictions = app.settings.cotypingEnabled && systemPredictionsOn
        Group {
            if showsPredictions || readiness.serverSetupProblem != nil || readiness.serverProblem != nil {
                Section {
                    if showsPredictions { systemPredictionsNotice }
                    if let problem = readiness.serverSetupProblem {
                        Label { Text(verbatim: problem) } icon: { Image(systemName: "exclamationmark.triangle") }
                            .font(AppFont.scaled(.callout))
                            .settingsSecondary()
                            .fixedSize(horizontal: false, vertical: true)
                    } else if let problem = readiness.serverProblem {
                        Label { Text(verbatim: problem) } icon: { Image(systemName: "exclamationmark.triangle") }
                            .font(AppFont.scaled(.callout))
                            .foregroundStyle(Brand.error)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("autocomplete.serverProblem")
                    }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            systemPredictionsOn = Self.readSystemPredictions()
        }
    }

    static func readSystemPredictions() -> Bool {
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
}

/// "Try it…" on Autocomplete: the rehearsal, over the page. It runs the real
/// prompt, model and normalizer with the page's settings, without touching
/// the acceptance statistics or the learning store.
struct AutocompleteTrySheet: View {
    @EnvironmentObject private var app: AppState
    @ObservedObject var server: RemoteCotypingEngine
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let readiness = AutocompleteReadiness(app: app, server: server)
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Try autocomplete").font(AppFont.scaled(.title2).weight(.bold))
                    .accessibilityAddTraits(.isHeader)
                Text(verbatim: explanation)
                    .font(AppFont.scaled(.callout)).settingsSecondary()
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 22).padding(.top, 20).padding(.bottom, 12)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let problem = readiness.serverSetupProblem ?? readiness.serverProblem {
                        Label { Text(verbatim: problem) } icon: { Image(systemName: "exclamationmark.triangle") }
                            .font(AppFont.scaled(.callout))
                            .foregroundStyle(LBTokens.Palette.attentionText)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if !readiness.modelReady {
                        // Download it here to try it; its licence is linked beside it.
                        CotypingModelPreparationView(compact: true)
                    }
                    AutocompleteRehearsal(readiness: readiness)
                }
                .padding(.horizontal, 22).padding(.bottom, 16)
            }
            Divider()
            HStack(spacing: 12) {
                Text("Uses the same settings and model as in other apps.")
                    .font(AppFont.scaled(.callout)).settingsSecondary()
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 12)
                // No Return or Escape shortcut: both belong to the reply field,
                // where Escape dismisses a suggestion.
                Button("Done") { dismiss() }
                    .primaryActionButton()
                    .accessibilityIdentifier("autocomplete.try.done")
            }
            .padding(.horizontal, 22).padding(.vertical, 14)
        }
        .frame(width: 600)
        .frame(minHeight: 420, maxHeight: 640)
        .toggleStyle(LBAccentSwitchStyle())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("autocomplete.try")
    }

    /// What typing here does and does not send. A server receives the
    /// rehearsal's text as it receives typing in other apps.
    private var explanation: String {
        let language = app.settings.appLanguage
        if app.settings.cotypingLeavesThisMac, let host = app.settings.cotypingConfiguredServerURL?.host {
            return String(format: language.localized(
                "Type in the box. What you type here is sent to %@, as it is in other apps. Nothing is saved."), host)
        }
        return language.localized("Type in the box. Nothing here leaves this Mac or is saved.")
    }
}

/// The rehearsal itself: a sample conversation, a reply field that shows the
/// real suggestion, and what the suggestion drew on.
struct AutocompleteRehearsal: View {
    @EnvironmentObject var app: AppState
    @ObservedObject private var permissions = PermissionManager.shared
    let readiness: AutocompleteReadiness

    private static let openingText = "Hi Sarah, thanks for the update. I wanted to follow"

    @State private var text = AutocompleteRehearsal.openingText
    @State private var rehearsal = AutocompleteRehearsal.openingRehearsal
    /// What the visible suggestion drew on; nil until one has been generated.
    @State private var contextUse: CotypingContextUse?
    @State private var generating = false
    @State private var error: String?
    /// Why the model's last answer became no suggestion.
    @State private var emptyReason: CotypingSuppressionReason?
    /// The text a suggestion is wanted for. Each new request starts one
    /// generation and ends the one before; the view owns the task's life.
    @State private var request: Request?
    @State private var requestSerial = 0
    @State private var topUpTask: Task<Void, Never>?
    @State private var focusRevision = 0

    private static var openingRehearsal: CotypingRehearsal {
        var rehearsal = CotypingRehearsal()
#if LOKALBOT_UI_TEST_HOST
        if ProcessInfo.processInfo.environment["LOKALBOT_COTYPING_DEMO"] == "1" {
            rehearsal.present(" up on the migration timeline we scoped yesterday.", after: openingText)
        }
#endif
        return rehearsal
    }

    private var demoReady: Bool { readiness.demoReady }

    private struct Request: Equatable {
        var serial: Int
        /// The text before the caret when the suggestion was asked for.
        var context: String
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

    var body: some View {
        // No identifier here: on a container it would replace the
        // identifier of every element inside.
        preview
            .task(id: request) {
                if let request { await generate(request) }
            }
            .onDisappear { topUpTask?.cancel() }
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
            } else if let emptyReason {
                Label(Self.explanation(emptyReason), systemImage: "info.circle")
                    .font(AppFont.scaled(.callout))
                    .settingsSecondary()
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("autocomplete.rehearsal.empty")
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

    /// Why the model's answer is not on screen, so a working model that
    /// suggested nothing does not look like a broken one.
    static func explanation(_ reason: CotypingSuppressionReason) -> LocalizedStringKey {
        switch reason {
        case .emptyGeneration, .normalizedToEmpty:
            "The model answered with no text."
        case .echoesPrecedingText, .duplicatesTrailingText, .promptContextLeak:
            "The model repeated text it was given, so its answer is hidden."
        case .placeholderText, .questionContinuation, .unsafeToInsert, .wordCompletionMismatch:
            "The answer did not fit at the cursor, so it is hidden."
        case .lowConfidence:
            "The model was unsure of the next word, so it suggested nothing."
        }
    }

    /// Asks for a suggestion for the text as it stands. The request replaces
    /// any earlier one, whose generation SwiftUI then cancels.
    private func schedule() {
        topUpTask?.cancel()
        rehearsal.dismiss()
        error = nil
        emptyReason = nil
        contextUse = nil
        let context = text
        guard !context.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            request = nil
            return
        }
        requestSerial += 1
        request = Request(serial: requestSerial, context: context)
    }

    private func generate(_ request: Request) async {
        try? await Task.sleep(for: .milliseconds(app.settings.cotypingDebounceMs))
        guard !Task.isCancelled else { return }
        generating = true
        defer { generating = false }
        do {
            let result: CotypingPreview
#if LOKALBOT_UI_TEST_HOST
            if demoReady { result = CotypingPreview(text: " up on the synthetic review.") } else {
                result = try await app.cotyping.preview(
                    precedingText: request.context, conversation: CotypingRehearsalConversation.sample)
            }
#else
            result = try await app.cotyping.preview(
                precedingText: request.context, conversation: CotypingRehearsalConversation.sample)
#endif
            // Never show a suggestion for text that has since changed: any
            // change makes a new request and cancels this one.
            guard !Task.isCancelled, self.request == request else { return }
            rehearsal.present(result.text, after: request.context,
                              wordLimit: app.settings.cotypingMaxWords)
            contextUse = result.use
            emptyReason = result.suppression
        } catch is CancellationError {
        } catch {
            if !Task.isCancelled { self.error = error.localizedDescription }
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
        request = nil
        topUpTask?.cancel()
        rehearsal.dismiss()
        // No suggestion is on screen any more, so there is nothing its
        // context rows could describe.
        contextUse = nil
        emptyReason = nil
        generating = false
    }
}

/// Counters and timings from typing in other apps. They answer what a model
/// benchmark cannot: whether suggestions arrive in time, whether an accepted
/// one lands in the field, and whether it is kept.
struct AutocompleteMeasurements: View {
    @EnvironmentObject private var app: AppState
    @ObservedObject var server: RemoteCotypingEngine
    @ObservedObject private var stats = CotypingStatsStore.shared

    var body: some View { usage }

    private var usesServer: Bool { app.settings.cotypingBackend != .onDevice }

    private var selectedModel: ModelCatalog.Entry? {
        ModelCatalog.entry(id: app.settings.cotypingBuiltInModelID, custom: app.settings.customBuiltInModels)
    }

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
