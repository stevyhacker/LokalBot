import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Settings → Personal Context → Email: connected Gmail accounts, read-only.
struct EmailSettingsSection: View {
    @ObservedObject var email: EmailController
    let focusedSettingID: String?
    @State private var disconnecting: EmailAccount?
    @State private var revocationUnconfirmed = false
    @State private var confirmingConnect = false

    static let privacyPolicyURL = URL(string: "https://www.lokalbot.com/privacy#email")!

    var body: some View {
        Section("Email") {
            SettingsHelp("Read-only. LokalBot downloads conversations you wrote in and mail with people on your calendar from the last 90 days. Newsletters, promotions, and notifications are skipped. Mail stays encrypted on this Mac.")
                .settingTarget("settings.email", selected: focusedSettingID)
            ForEach(email.accounts) { account in
                accountRow(account)
            }
            if email.hasGoogleClient {
                HStack(spacing: 12) {
                    Button(email.isSigningIn ? "Waiting for your browser…" : "Add Gmail Account…") {
                        revocationUnconfirmed = false
                        confirmingConnect = true
                    }
                    .disabled(email.isSigningIn)
                    .accessibilityIdentifier("settings.email.addGmail")
                    if email.isSigningIn {
                        Button("Cancel") { email.cancelSignIn() }
                    } else if !email.hasBuiltInClient {
                        Button("Change Client File…") { chooseClientFile() }
                            .buttonStyle(.workspaceLink)
                    }
                }
                if email.isSigningIn && email.usesOwnClient {
                    SettingsHelp("Finish signing in in your browser, then return here.")
                }
            } else {
                LabeledContent {
                    Button("Choose Client File…") { chooseClientFile() }
                        .accessibilityIdentifier("settings.email.chooseClient")
                } label: {
                    SettingsLabel("Google sign-in",
                                  help: "Until LokalBot has a verified Google app, Gmail uses your own OAuth client. In Google Cloud, enable the Gmail API, create an OAuth client of type Desktop app, set the app's publishing status to In production so the sign-in doesn't expire after a week, download the client's JSON file, and choose it here.")
                }
            }
            if let error = email.lastError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .workspaceTextRole(.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if revocationUnconfirmed {
                SettingsHelp("Disconnected here, but Google didn't confirm it. You can also remove LokalBot's access in your Google Account settings.")
            }
            SettingsDetails("What LokalBot reads", Self.readingDetails)
            if email.hasBuiltInClient {
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 8) {
                        SettingsHelp("For your own Google Cloud project: enable the Gmail API, create an OAuth client of type Desktop app, publish it, download its JSON file, and choose it here. New sign-ins then use your client instead of LokalBot's.")
                        HStack(spacing: 12) {
                            Button(email.usesOwnClient ? "Change Client File…" : "Choose Client File…") {
                                chooseClientFile()
                            }
                            if email.usesOwnClient {
                                Button("Use LokalBot's Client") { email.useBuiltInClient() }
                                    .buttonStyle(.workspaceLink)
                            }
                        }
                    }
                    .padding(.top, 4)
                } label: {
                    Text("Use your own Google OAuth client")
                        .font(.scaled(.callout).weight(.medium))
                        .settingsSecondary()
                }
            }
        }
        .alert("Connect a Gmail account?", isPresented: $confirmingConnect) {
            Button("Continue") { email.connectGmail() }
            Button("Privacy Policy") { NSWorkspace.shared.open(Self.privacyPolicyURL) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("LokalBot asks Google for read-only access to Gmail. It downloads conversations you wrote in and mail with people on your calendar from the last 90 days, keeps them encrypted on this Mac, and never sends them to LokalBot or anyone else. Disconnecting deletes them.")
        }
        .confirmationDialog(
            Text("Disconnect \(disconnecting?.address ?? "")?"),
            isPresented: Binding(get: { disconnecting != nil }, set: { if !$0 { disconnecting = nil } }),
            titleVisibility: .visible
        ) {
            Button("Disconnect", role: .destructive) {
                guard let account = disconnecting else { return }
                disconnecting = nil
                Task { revocationUnconfirmed = !(await email.disconnect(account.id)) }
            }
            Button("Cancel", role: .cancel) { disconnecting = nil }
        } message: {
            Text("LokalBot stops reading this account, asks Google to revoke its access, and deletes the mail it downloaded.")
        }
    }

    /// One catalog key, split only to keep the line short.
    private static let readingDetails = "LokalBot reads headers first and downloads a conversation only if you wrote in it, "
        + "or if someone on your calendar takes part and it isn't bulk mail. It never reads Spam, Trash, or Drafts, "
        + "and it keeps attachment names but never their contents. It checks for new mail at launch, every few hours, "
        + "each morning, and before meetings. Google's read-only permission means LokalBot can't send, delete, or change mail."

    private func accountRow(_ account: EmailAccount) -> some View {
        LabeledContent {
            HStack(spacing: 10) {
                if email.syncingAccountID == account.id {
                    ProgressView().controlSize(.small)
                } else if account.sync.needsSignIn {
                    Button("Sign In Again") { email.connectGmail(loginHint: account.address) }
                        .disabled(email.isSigningIn)
                } else {
                    Button("Check Now") { email.requestSync(account.id) }
                        .disabled(email.syncingAccountID != nil)
                }
                Button("Disconnect…") { disconnecting = account }
                    .buttonStyle(.workspaceLink)
            }
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: account.address)
                    .lineLimit(1)
                    .truncationMode(.middle)
                status(account)
                    .font(.scaled(.callout))
                    .settingsSecondary()
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityIdentifier("settings.email.account")
    }

    @ViewBuilder private func status(_ account: EmailAccount) -> some View {
        if email.syncingAccountID == account.id {
            Text("Checking for new mail…")
        } else if account.sync.needsSignIn {
            Text("Sign in again to keep checking this account.")
        } else if let error = account.sync.lastError {
            Text(verbatim: error)
        } else if let checked = account.sync.lastSuccessAt {
            VStack(alignment: .leading, spacing: 2) {
                Text("Checked \(checked.formatted(.relative(presentation: .named))) · \(account.sync.threadCount) conversations")
                if account.sync.capped {
                    Text("Stopped at the first \(EmailScope.maxThreadsPerScan) conversations.")
                }
            }
        } else {
            Text("Waiting for the first check.")
        }
    }

    private func chooseClientFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        email.importGoogleClient(from: url)
    }
}
