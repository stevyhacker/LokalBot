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

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            readiness
            preview
            DisclosureGroup("Lifetime usage") {
                HStack {
                    StatTile(icon: "text.badge.plus", value: "\(stats.stats.generations)", label: "suggested")
                    StatTile(icon: "checkmark", value: "\(stats.stats.accepts)", label: "accepted")
                }.padding(.top, 8)
            }
        }
        .onDisappear { task?.cancel() }
        .accessibilityIdentifier("autocomplete.home")
    }

    private var readiness: some View {
        WorkspaceSection(title: app.settings.cotypingEnabled ? "Autocomplete on" : (modelReady ? "Off · model ready" : "Off · model needed"), icon: "checkmark.circle") {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) { readinessItems }
                VStack(alignment: .leading, spacing: 10) { readinessItems }
            }
            if !modelReady {
                CotypingModelPreparationView(compact: true)
            }
        }
    }

    @ViewBuilder private var readinessItems: some View {
        readinessItem("Model", selectedModel?.displayName ?? "LFM2.5 1.2B Instruct", ready: modelReady)
        readinessItem("Accessibility", permissionLabel(.accessibility),
                      ready: demoReady || (permissions.granted[.accessibility] ?? false))
        readinessItem("Input Monitoring", permissionLabel(.inputMonitoring),
                      ready: demoReady || (permissions.granted[.inputMonitoring] ?? false))
    }

    private func readinessItem(_ title: String, _ detail: String, ready: Bool) -> some View {
        HStack(spacing: 8) {
            StatusDot(color: ready ? .green : .orange)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(WorkspaceTypography.metadata).foregroundStyle(.secondary)
                Text(detail).font(WorkspaceTypography.rowTitle).lineLimit(1)
            }
        }
    }

    private func permissionLabel(_ permission: AppPermission) -> String {
        (demoReady || (permissions.granted[permission] ?? false)) ? "Granted" : "Needs permission"
    }

    private var preview: some View {
        WorkspaceSection(title: "Try the real autocomplete", icon: "text.cursor") {
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
                        .font(WorkspaceTypography.metadataEmphasis)
                        .foregroundStyle(.secondary)
                    if generating { ProgressView().controlSize(.small) }
                    Spacer()
                    Button("Insert suggestion") { accept() }
                        .primaryActionButton()
                        .disabled(suggestion.isEmpty)
                }
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(Brand.error)
                }
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
