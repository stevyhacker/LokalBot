import SwiftUI

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

    var usesServer: Bool { app.settings.cotypingBackend != .onDevice }

    var modelReady: Bool {
        if demoReady { return true }
        guard !usesServer else { return serverSetupProblem == nil }
        return selectedModel.flatMap { ModelCatalog.localURL(for: $0, storage: app.storage) } != nil
    }

    var serverSetupProblem: String? {
        guard usesServer, case .unavailable(let reason) = app.settings.cotypingRoute(includingCredentials: false)
        else { return nil }
        return reason
    }

    var serverProblem: String? {
        guard usesServer, let problem = server.problem,
              case .server(let endpoint) = app.settings.cotypingRoute(includingCredentials: false),
              endpoint.identity == problem.identity else { return nil }
        return problem.message
    }

    var modelName: String {
        usesServer ? app.settings.cotypingModelDisplayName
            : selectedModel?.displayName ?? app.settings.cotypingBuiltInModelID
    }
}

struct AutocompleteNotices: View {
    @EnvironmentObject private var app: AppState
    @ObservedObject var server: RemoteCotypingEngine
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
        return ProcessInfo.processInfo.environment["LOKALBOT_SYSTEM_PREDICTIONS_ON"] == "1"
#else
        return CotypingSystemInlinePredictions.isOn()
#endif
    }

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

    private var explanation: String {
        let language = app.settings.appLanguage
        if app.settings.cotypingLeavesThisMac, let host = app.settings.cotypingConfiguredServerURL?.host {
            return String(format: language.localized(
                "Type in the box. What you type here is sent to %@, as it is in other apps. Nothing is saved."), host)
        }
        return language.localized("Type in the box. Nothing here leaves this Mac or is saved.")
    }
}

struct AutocompleteRehearsal: View {
    @EnvironmentObject var app: AppState
    @ObservedObject private var permissions = PermissionManager.shared
    let readiness: AutocompleteReadiness

    private static let openingText = "Hi Sarah, thanks for the update. I wanted to follow"

    @State private var text = AutocompleteRehearsal.openingText
    @State private var rehearsal = AutocompleteRehearsal.openingRehearsal
    @State private var contextUse: CotypingContextUse?
    @State private var generating = false
    @State private var error: String?
    @State private var emptyReason: CotypingSuppressionReason?
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
        var context: String
    }

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
                    switch rehearsal.textChanged(to: updated) {
                    case .stale: schedule()
                    case .advanced: topUp()
                    case .unchanged: break
                    }
                }
                .onChange(of: contextGrants) { _, _ in
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

    private func accept(_ scope: CotypingAcceptScope) {
        guard let updated = rehearsal.accept(scope, text: text,
                                             options: .init(settings: app.settings)) else { return }
        text = updated
        topUp()
    }

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
        contextUse = nil
        emptyReason = nil
        generating = false
    }
}

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
