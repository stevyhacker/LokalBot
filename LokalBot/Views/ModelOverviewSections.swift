import SwiftUI

/// The overview exposes saved approvals without choosing or approving a server.
/// Connection editing and its full data disclosure remain in the existing editor.
struct ModelRemoteOverview: View {
    @ObservedObject var app: AppState
    @State private var revokingOrigin: String?
    @State private var revokingTranscriptionOrigin: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Approved to receive your data").font(.scaled(.headline))
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
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("models.approvals")
        .remoteOriginRevocation(app: app, inference: $revokingOrigin, transcription: $revokingTranscriptionOrigin)
    }
}
