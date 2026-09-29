import SwiftUI

struct ModelPresetsSection: View {
    let settings: AppSettings
    let switching: Bool
    let choose: (ModelStackPreset) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Presets").font(.scaled(.headline))
            ForEach(ModelStackPreset.allCases) { preset in
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(preset.title).font(.scaled(.body).weight(.medium))
                        Text(preset.subtitle).font(.scaled(.callout)).settingsSecondary()
                    }
                    Spacer(minLength: 8)
                    if preset.patch.matches(settings) {
                        Text("Current").font(.scaled(.callout)).foregroundStyle(Brand.teal)
                    }
                    Button("Apply…") { choose(preset) }
                        .buttonStyle(.bordered)
                        .disabled(switching)
                        .accessibilityLabel("Review \(preset.title) preset")
                        .accessibilityIdentifier(preset == .recommended ? "models.choosePreset" : "models.preset.lightweight")
                }
                if preset != ModelStackPreset.allCases.last { SettingsSeparator() }
            }
            Text("Review model changes and download sizes before applying. Existing models are kept.")
                .font(.scaled(.callout)).settingsSecondary()
        }
        .padding(16).settingsPanel()
    }
}

/// The overview exposes saved approvals without choosing or approving a server.
/// Connection editing and its full data disclosure remain in the existing editor.
struct ModelRemoteOverview: View {
    @ObservedObject var app: AppState
    let connections: () -> Void
    @State private var revokingOrigin: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Remote Server").font(.scaled(.headline))
                Spacer()
                Button("Manage Connections…", action: connections)
                    .buttonStyle(.workspaceLink)
                    .accessibilityIdentifier("models.connections")
            }
            if app.settings.approvedRemoteInferenceOrigins.isEmpty {
                Label("No remote servers approved", systemImage: "lock.shield")
                    .font(.scaled(.body)).settingsSecondary()
                Text("Local models process on this Mac. Each remote server requires its own approval before context can leave the Mac.")
                    .font(.scaled(.callout)).settingsSecondary()
            } else {
                ForEach(app.settings.approvedRemoteInferenceOrigins, id: \.self) { origin in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Label(origin, systemImage: "network").textSelection(.enabled)
                            Spacer()
                            Button("Revoke…") { revokingOrigin = origin }
                                .accessibilityLabel("Revoke access to \(origin)")
                        }
                        Toggle("Allow scheduled summaries and overnight review", isOn: automationApproval(origin))
                            .accessibilityIdentifier("models.overview.automationConsent.\(origin)")
                        Text("Scheduled runs can send activity titles, captured screen text, meeting evidence, and retained Dream memory to this origin without a prompt each time.")
                            .font(.scaled(.callout)).settingsSecondary()
                    }
                    if origin != app.settings.approvedRemoteInferenceOrigins.last { SettingsSeparator() }
                }
            }
        }
        .padding(16).settingsPanel()
        .confirmationDialog("Revoke access to \(revokingOrigin ?? "this server")?", isPresented: Binding(
            get: { revokingOrigin != nil }, set: { if !$0 { revokingOrigin = nil } })) {
            Button("Revoke Access", role: .destructive) {
                guard let origin = revokingOrigin else { return }
                app.settings.approvedRemoteInferenceOrigins.removeAll { $0 == origin }
                app.settings.approvedRemoteAutomationOrigins.removeAll { $0 == origin }
                revokingOrigin = nil
            }
        } message: {
            Text("This also revokes scheduled processing for this origin. Any model using it will require approval again.")
        }
    }

    private func automationApproval(_ origin: String) -> Binding<Bool> {
        Binding {
            app.settings.approvedRemoteAutomationOrigins.contains(origin)
        } set: { approved in
            app.settings.approvedRemoteAutomationOrigins.removeAll { $0 == origin }
            if approved && app.settings.approvedRemoteInferenceOrigins.contains(origin) {
                app.settings.approvedRemoteAutomationOrigins.append(origin)
            }
        }
    }
}
