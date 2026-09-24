import SwiftUI

/// Writing-settings readiness and preview. The real completion engine is used
/// without touching production acceptance statistics or the learning store.
struct AutocompleteExperienceView: View {
    @EnvironmentObject var app: AppState
    @ObservedObject private var permissions = PermissionManager.shared
    @ObservedObject private var stats = CotypingStatsStore.shared

    @State private var text = "Hi Sarah, thanks for the update. I wanted to follow"
#if LOKALBOT_UI_TEST_HOST
    @State private var suggestion = ProcessInfo.processInfo.environment["LOKALBOT_COTYPING_DEMO"] == "1"
        ? " up on the migration timeline we scoped yesterday." : ""
#else
    @State private var suggestion = ""
#endif
    @State private var generating = false
    @State private var error: String?
    @State private var task: Task<Void, Never>?
    @State private var focusRevision = 0

    private var selectedModel: ModelCatalog.Entry? {
        ModelCatalog.entry(
            id: app.settings.cotypingBuiltInModelID,
            custom: app.settings.customBuiltInModels)
    }

    private var modelReady: Bool {
#if LOKALBOT_UI_TEST_HOST
        if ProcessInfo.processInfo.environment["LOKALBOT_COTYPING_DEMO"] == "1" { return true }
#endif
        return selectedModel.flatMap { ModelCatalog.localURL(for: $0, storage: app.storage) } != nil
    }

    private var demoReady: Bool {
#if LOKALBOT_UI_TEST_HOST
        ProcessInfo.processInfo.environment["LOKALBOT_COTYPING_DEMO"] == "1"
#else
        false
#endif
    }

    /// Returns Form sections: a readiness summary, then the live preview. Both
    /// use the Settings row type scale instead of nested workspace panels, and
    /// the preview stays near the top of Writing without scrolling.
    var body: some View {
        Group {
            Section {
                summary
                if !modelReady {
                    CotypingModelPreparationView(compact: true)
                }
            }
            Section("Try the real autocomplete") {
                preview
                    .settingTarget("settings.autocompletePreview", selected: app.focusedSettingID)
                DisclosureGroup("Lifetime usage") {
                    HStack {
                        StatTile(icon: "text.badge.plus", value: "\(stats.stats.generations)", label: "suggested")
                        StatTile(icon: "checkmark", value: "\(stats.stats.accepts)", label: "accepted")
                    }.padding(.top, 8)
                }
            }
        }
        .onDisappear { task?.cancel() }
    }

    private var summary: some View {
        HStack(alignment: .top, spacing: 12) {
            IconTile(systemImage: "text.cursor",
                     tint: app.settings.cotypingEnabled ? Brand.tealFill : Color(nsColor: .systemGray),
                     size: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(app.settings.cotypingEnabled ? "Autocomplete on" : "Autocomplete off")
                        .font(WorkspaceTypography.bodyEmphasis)
                    Text(summaryDetail)
                        .font(WorkspaceTypography.metadata)
                        .settingsSecondary()
                        .fixedSize(horizontal: false, vertical: true)
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) { readiness }
                    VStack(alignment: .leading, spacing: 6) { readiness }
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityIdentifier("autocomplete.home")
    }

    @ViewBuilder private var readiness: some View {
        MemoryHealthStatus(value: modelReady ? "Model ready" : "Model needed",
                           tone: modelReady ? .good : .attention)
            .help(selectedModel?.displayName ?? "LFM2.5 1.2B Instruct")
        permissionStatus("Accessibility", .accessibility)
        permissionStatus("Input Monitoring", .inputMonitoring)
    }

    private var summaryDetail: String {
        let model = selectedModel?.displayName ?? "LFM2.5 1.2B Instruct"
        if app.settings.cotypingEnabled { return "\(model) · suggestions appear as you type in other apps." }
        return modelReady
            ? "The model is ready. Turn on autocomplete below to start."
            : "Download the Autocomplete model to try it."
    }

    private func permissionStatus(_ title: String, _ permission: AppPermission) -> some View {
        let granted = demoReady || (permissions.granted[permission] ?? false)
        return MemoryHealthStatus(value: granted ? "\(title) granted" : "\(title) needed",
                                  tone: granted ? .good : .attention)
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 10) {
            RehearsalTextEditor(text: $text, suggestion: suggestion,
                                acceptKey: app.settings.cotypingAcceptKey,
                                focusRevision: focusRevision,
                                onAccept: { accept() },
                                onReject: { task?.cancel(); suggestion = ""; generating = false })
                .frame(minHeight: 120)
                .padding(8)
                .workspaceControl()
                .onChange(of: text) { _, _ in schedule() }

            HStack {
                Text("\(app.settings.cotypingAcceptKey.label) accepts · Esc dismisses")
                    .font(WorkspaceTypography.metadata)
                    .settingsSecondary()
                if generating { ProgressView().controlSize(.small) }
                Spacer()
                Button("Insert suggestion") { accept() }
                    .primaryActionButton()
                    .disabled(suggestion.isEmpty)
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(WorkspaceTypography.metadata).foregroundStyle(Brand.error)
            }
        }
    }

    private func schedule() {
        task?.cancel()
        suggestion = ""
        error = nil
        let context = text
        guard !context.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        task = Task {
            try? await Task.sleep(for: .milliseconds(app.settings.cotypingDebounceMs))
            guard !Task.isCancelled else { return }
            generating = true
            defer { generating = false }
            do {
                let result: String
#if LOKALBOT_UI_TEST_HOST
                if demoReady { result = " up on the synthetic review." } else {
                    result = try await app.cotyping.previewSuggestion(precedingText: context)
                }
#else
                result = try await app.cotyping.previewSuggestion(precedingText: context)
#endif
                if !Task.isCancelled {
                    suggestion = result
                }
            } catch is CancellationError {
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
    }

    private func accept() {
        guard !suggestion.isEmpty else { return }
        text += suggestion
        suggestion = ""
    }
}
