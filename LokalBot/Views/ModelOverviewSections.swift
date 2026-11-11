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
                        Text(preset.modelSummary).font(.scaled(.caption)).settingsSecondary()
                            .accessibilityIdentifier("models.preset.\(preset.rawValue).models")
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
    @State private var revokingTranscriptionOrigin: String?

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
                            Label(SubscriptionPlan.approvalDisplayName(origin), systemImage: "network")
                                .textSelection(.enabled)
                            Spacer()
                            Button("Revoke…") { revokingOrigin = origin }
                                .accessibilityLabel("Revoke access to \(SubscriptionPlan.approvalDisplayName(origin))")
                        }
                        Text("Includes scheduled daily summaries and overnight review, which can send activity titles, captured screen text, meeting evidence, and retained Dream memory to this origin without a prompt each time.")
                            .font(.scaled(.callout)).settingsSecondary()
                    }
                    if origin != app.settings.approvedRemoteInferenceOrigins.last { SettingsSeparator() }
                }
            }
            if !app.settings.approvedRemoteTranscriptionOrigins.isEmpty {
                SettingsSeparator()
                ForEach(app.settings.approvedRemoteTranscriptionOrigins, id: \.self) { origin in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Label(SubscriptionPlan.approvalDisplayName(origin), systemImage: "waveform")
                                .textSelection(.enabled)
                            Spacer()
                            Button("Revoke…") { revokingTranscriptionOrigin = origin }
                                .accessibilityLabel("Revoke audio access for \(SubscriptionPlan.approvalDisplayName(origin))")
                        }
                        Text("Transcription server. Receives meeting and dictation audio, the language hint, and transcription vocabulary, including automatic processing after meetings.")
                            .font(.scaled(.callout)).settingsSecondary()
                    }
                    if origin != app.settings.approvedRemoteTranscriptionOrigins.last { SettingsSeparator() }
                }
            }
        }
        .padding(16).settingsPanel()
        .remoteOriginRevocation(app: app, inference: $revokingOrigin, transcription: $revokingTranscriptionOrigin)
    }
}
