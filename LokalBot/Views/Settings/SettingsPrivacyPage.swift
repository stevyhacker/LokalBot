import AppKit
import SwiftUI

/// Settings → Privacy & permissions: the one place that asks for macOS
/// permissions and shows what leaves this Mac. Each permission says which
/// features use it and where it stands; each server that receives something
/// is listed with the control that revokes it; sharing with agents and with
/// phones is summed up and opens its own page, where its consent lives.
/// PRIVACY.md is the contract for every sentence here.
struct SettingsPrivacySections: View {
    @EnvironmentObject private var app: AppState
    let status: SettingsStatus
    /// Observed for the error a Calendar request can end with.
    @ObservedObject var calendar: EventKitCalendarEventProvider
    @State private var libraryBytes: Int64?
    @State private var revokingOrigin: String?
    @State private var revokingTranscriptionOrigin: String?

    private var localized: (String) -> String { app.settings.appLanguage.catalog }

    var body: some View {
        Group {
            Section {
                ForEach(SettingsPermission.allCases) { permission in
                    permissionRow(permission)
                        .settingTarget(permission == .microphone ? "settings.permissions" : "settings.permission.\(permission.rawValue)",
                                       selected: app.focusedSettingID)
                }
                HStack {
                    SettingsHelp("Accessibility and Input Monitoring grants apply at launch.")
                    Spacer()
                    Button("Relaunch") { SettingsStatusActions.perform(.relaunch, in: app) }
                        .controlSize(.small)
                        .accessibilityIdentifier("settings.permissions.relaunch")
                }
            } header: {
                Text("Permissions")
            } footer: {
                SettingsHelp("macOS asks once for each. Only the features listed use them.")
            }
            Section("What leaves this Mac") {
                onlineModels
                agentsRow
                devicesRow
                VStack(alignment: .leading, spacing: 2) {
                    Text("Anything else")
                    SettingsHelp("Model downloads, update checks, and Agent Mode’s one-time setup use the internet. So does Gmail, once you connect it.")
                }
                // On one row, so the confirmations are presented once.
                .remoteOriginRevocation(app: app, inference: $revokingOrigin, transcription: $revokingTranscriptionOrigin)
            }
            Section("Where it’s kept") {
                SettingsLibraryRow(bytes: libraryBytes, showsPath: true)
                    .settingTarget("settings.libraryLocation", selected: app.focusedSettingID)
            }
            Section {
                HStack(spacing: 16) {
                    Link("Privacy Policy", destination: URL(string: "https://www.lokalbot.com/privacy")!)
                        .buttonStyle(.workspaceLink)
                    Link("Support", destination: URL(string: "https://www.lokalbot.com/support")!)
                        .buttonStyle(.workspaceLink)
                }
                .font(AppFont.scaled(.body))
            }
        }
        .task { libraryBytes = await SettingsLibrarySize.measure(root: app.storage.rootURL) }
    }

    // MARK: - Permissions

    private func permissionRow(_ permission: SettingsPermission) -> some View {
        let access = status.access(permission)
        return HStack(alignment: .center, spacing: 10) {
            sign(access)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(LocalizedStringKey(permission.title))
                SettingsHelp(permission.usedBy)
                if permission == .calendar, let error = calendar.accessRequestError {
                    Text(error)
                        .font(.scaled(.callout))
                        .foregroundStyle(Brand.error)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            switch access {
            case .allowed:
                Text("Allowed").settingsSecondary()
            case .missing:
                SettingsFixButton(title: status.allowTitle(permission), action: .allow(permission),
                                  identifier: "settings.permission.\(permission.rawValue).allow")
            case .notNeeded:
                Text("Not needed now").settingsSecondary()
                // Still offered: a feature turned on later, or Autocomplete
                // reading the focused window, uses it once it is granted.
                SettingsFixButton(title: status.allowTitle(permission), action: .allow(permission), link: true,
                                  identifier: "settings.permission.\(permission.rawValue).allow")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.permission.\(permission.rawValue)")
    }

    @ViewBuilder private func sign(_ access: SettingsStatus.Access) -> some View {
        switch access {
        case .allowed:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(LBTokens.Palette.success)
        case .missing:
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(LBTokens.Palette.attention)
        case .notNeeded:
            Image(systemName: "minus.circle.fill").foregroundStyle(.tertiary)
        }
    }

    // MARK: - What leaves this Mac

    /// Every origin approved to receive something, with its Revoke, and the
    /// server Autocomplete sends typing to.
    @ViewBuilder private var onlineModels: some View {
        let settings = app.settings
        let autocompleteHost = settings.cotypingLeavesThisMac ? settings.cotypingConfiguredServerURL?.host : nil
        if settings.approvedRemoteInferenceOrigins.isEmpty, settings.approvedRemoteTranscriptionOrigins.isEmpty,
           autocompleteHost == nil {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Online models")
                    SettingsHelp("None. Every model runs on this Mac.")
                }
                Spacer(minLength: 8)
                SettingsFixButton(title: "Models…", action: .open(.models, focus: nil),
                                  identifier: "settings.privacy.models")
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("settings.privacy.onlineModels")
        }
        ForEach(settings.approvedRemoteInferenceOrigins, id: \.self) { origin in
            originRow(SubscriptionPlan.approvalDisplayName(origin), icon: "globe",
                      detail: "Includes scheduled daily summaries and overnight review, which can send activity titles, captured screen text, meeting evidence, and retained Dream memory to this origin without a prompt each time.") {
                Button("Revoke…") { revokingOrigin = origin }
                    .controlSize(.small)
                    .accessibilityLabel("Revoke access to \(SubscriptionPlan.approvalDisplayName(origin))")
            }
        }
        ForEach(settings.approvedRemoteTranscriptionOrigins, id: \.self) { origin in
            originRow(SubscriptionPlan.approvalDisplayName(origin), icon: "waveform",
                      detail: "Transcription server. Receives meeting and dictation audio, the language hint, and transcription vocabulary, including automatic processing after meetings.") {
                Button("Revoke…") { revokingTranscriptionOrigin = origin }
                    .controlSize(.small)
                    .accessibilityLabel("Revoke audio access for \(SubscriptionPlan.approvalDisplayName(origin))")
            }
        }
        if let autocompleteHost {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "character.cursor.ibeam")
                    .foregroundStyle(LBTokens.Palette.attentionText)
                    .frame(width: 18)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: autocompleteHost).textSelection(.enabled)
                    Text("Autocomplete also sends what you type, with the context you turn on under Autocomplete, to \(autocompleteHost).")
                        .font(.scaled(.callout))
                        .settingsSecondary()
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                SettingsFixButton(title: "Change…", action: .open(.models, focus: "settings.cotypingBackend"),
                                  identifier: "settings.privacy.autocompleteServer")
            }
        }
    }

    private func originRow<Control: View>(_ name: String, icon: String, detail: String,
                                          @ViewBuilder control: () -> Control) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(LBTokens.Palette.attentionText)
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: name).textSelection(.enabled)
                SettingsHelp(detail)
            }
            Spacer(minLength: 8)
            control()
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.privacy.origin")
    }

    private var agentsRow: some View {
        let kinds = status.input.agentKinds
        return pageRow(.agents, title: "AI agents on this Mac") {
            if kinds == 0 {
                Text("Can’t read anything")
            } else {
                Text("\(kinds) of \(AgentReadAccess.Kind.allCases.count) kinds")
            }
        }
    }

    private var devicesRow: some View {
        pageRow(.devices, title: "Phones & tablets") {
            if app.settings.companionSharingEnabled {
                Text("\(status.input.pairedDevices) paired")
            } else {
                Text("Off")
            }
        }
    }

    /// A summary that opens the page where the sharing is set up and agreed to.
    private func pageRow<Detail: View>(_ page: AppState.SettingsTab, title: String,
                                       @ViewBuilder detail: () -> Detail) -> some View {
        Button { SettingsStatusActions.perform(.open(page, focus: nil), in: app) } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(LocalizedStringKey(title))
                    detail().font(.scaled(.callout)).settingsSecondary()
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.forward").font(.scaled(.caption)).settingsSecondary()
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("settings.privacy.\(page.rawValue)")
    }
}

// MARK: - Revoking a server

/// The two confirmations that revoke a server's approval, shared by Models
/// and Privacy & permissions so both revoke the same way.
private struct RemoteOriginRevocation: ViewModifier {
    @ObservedObject var app: AppState
    @Binding var inference: String?
    @Binding var transcription: String?

    func body(content: Content) -> some View {
        content
            .confirmationDialog("Revoke access to \(inference.map(SubscriptionPlan.approvalDisplayName) ?? "this server")?",
                                isPresented: Binding(get: { inference != nil }, set: { if !$0 { inference = nil } })) {
                Button("Revoke Access", role: .destructive) {
                    guard let origin = inference else { return }
                    app.settings.approvedRemoteInferenceOrigins.removeAll { $0 == origin }
                    inference = nil
                }
            } message: {
                Text("This also revokes scheduled processing for this origin. Any model using it will require approval again.")
            }
            .confirmationDialog(
                "Stop sending audio to \(transcription.map(SubscriptionPlan.approvalDisplayName) ?? "this server")?",
                isPresented: Binding(get: { transcription != nil }, set: { if !$0 { transcription = nil } })) {
                Button("Revoke Access", role: .destructive) {
                    guard let origin = transcription else { return }
                    app.settings.approvedRemoteTranscriptionOrigins.removeAll { $0 == origin }
                    transcription = nil
                }
            } message: {
                Text("Meetings will wait for transcription until you approve this server again or choose a model on this Mac.")
            }
    }
}

extension View {
    /// Confirms and carries out revoking a Think or transcription server.
    func remoteOriginRevocation(app: AppState, inference: Binding<String?>,
                                transcription: Binding<String?>) -> some View {
        modifier(RemoteOriginRevocation(app: app, inference: inference, transcription: transcription))
    }
}
