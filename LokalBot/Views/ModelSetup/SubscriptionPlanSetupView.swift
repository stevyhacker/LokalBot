import AppKit
import SwiftUI

/// Account, model, and consent for one subscription plan, shown in the Think
/// model sheet. Signing in, approval, and the model are separate steps: a
/// sign-in alone never lets context leave the Mac, and the sheet applies the
/// model and approval only when the user chooses Use model.
struct SubscriptionPlanSetupView: View {
    @ObservedObject var app: AppState
    let plan: SubscriptionPlan
    @Binding var model: String
    @Binding var consent: Bool
    /// Signed in with plan usage (ChatGPT) or signed in to Claude Code.
    @Binding var ready: Bool
    var chatGPTAccount: ChatGPTPlanAccount = .shared

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            switch plan {
            case .chatGPT:
                ChatGPTPlanAccountSection(app: app, model: $model, ready: $ready, account: chatGPTAccount)
            case .claude:
                ClaudePlanAccountSection(model: $model, ready: $ready)
            }
            SubscriptionPlanConsentSection(plan: plan, consent: $consent)
        }
    }
}

/// One labelled row of a plan's setup, with labels aligned in a column.
private struct PlanRow<Content: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder var content: Content

    var body: some View {
        GridRow(alignment: .firstTextBaseline) {
            Text(title)
                .font(AppFont.scaled(.body))
                .settingsSecondary()
                .gridColumnAlignment(.leading)
            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Model picker

/// The model menu for a plan. A ChatGPT plan lists the signed-in account's
/// own models; a Claude plan offers Claude Code's aliases, which follow the
/// newest model of each family.
struct SubscriptionPlanModelPicker: View {
    let plan: SubscriptionPlan
    @Binding var selection: String
    var account: ChatGPTPlanAccount = .shared
    /// Changes when the sign-in changes, so the list loads again.
    var accountKey: String = ""

    @State private var models: [ChatGPTPlanModel] = []
    @State private var loading = false
    @State private var loadError: String?
    @State private var signedOut = false

    static let claudeChoices: [ChatGPTPlanModel] = [
        .init(slug: "", displayName: "Claude Code default"),
        .init(slug: "fable", displayName: "Fable"),
        .init(slug: "opus", displayName: "Opus"),
        .init(slug: "sonnet", displayName: "Sonnet"),
        .init(slug: "haiku", displayName: "Haiku"),
    ]

    /// Known choices, plus a saved model the list no longer offers, so a
    /// retired selection stays visible instead of silently changing.
    private var choices: [ChatGPTPlanModel] {
        let known = plan == .claude ? Self.claudeChoices : models
        guard !selection.isEmpty, !known.contains(where: { $0.slug == selection }) else { return known }
        return known + [.init(slug: selection, displayName: selection)]
    }

    var body: some View {
        HStack(spacing: 8) {
            Picker("Model", selection: $selection) {
                if plan == .chatGPT, selection.isEmpty {
                    Text(loading ? "Loading models…" : "Choose a model").tag("")
                }
                ForEach(choices) { Text($0.displayName).tag($0.slug) }
            }
            .labelsHidden()
            .fixedSize()
            .disabled(plan == .chatGPT && choices.isEmpty)
            .accessibilityIdentifier("models.plan.model")
            if loading {
                ProgressView().controlSize(.small)
            } else if signedOut {
                Text("Sign in to choose a model.").font(AppFont.scaled(.callout)).settingsSecondary()
            } else if let loadError {
                Text(loadError).font(AppFont.scaled(.callout)).settingsSecondary()
                    .lineLimit(2)
                Button("Try again") { Task { await load(refresh: true) } }
                    .buttonStyle(.workspaceLink)
            }
        }
        .task(id: plan == .chatGPT ? accountKey : "claude") {
            if plan == .chatGPT { await load(refresh: false) }
        }
    }

    private func load(refresh: Bool) async {
        loading = true
        loadError = nil
        signedOut = false
        defer { loading = false }
        do {
            models = try await account.models(refresh: refresh)
            if models.isEmpty { loadError = "Your plan offered no models." }
            if selection.isEmpty, let first = models.first { selection = first.slug }
        } catch ChatGPTPlanError.signedOut {
            models = []
            signedOut = true
        } catch is CancellationError {
        } catch {
            models = []
            loadError = "Couldn't load your plan's models."
        }
    }
}

// MARK: - ChatGPT

private struct ChatGPTPlanAccountSection: View {
    @ObservedObject var app: AppState
    @Binding var model: String
    @Binding var ready: Bool
    let account: ChatGPTPlanAccount
    @State private var status: ChatGPTPlanStatus?
    @State private var signingIn = false
    @State private var signInTask: Task<Void, Never>?
    @State private var accountError: String?
    @State private var showingNotice = false
    @State private var revocationUnconfirmed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch status {
            case nil:
                ProgressView().controlSize(.small)
            case .signedOut(let previousEmail)?:
                signedOut(previousEmail: previousEmail)
            case .signedIn(let email, let planUsage)?:
                signedIn(email: email, planUsage: planUsage)
            }
            if let accountError {
                Label(accountError, systemImage: "exclamationmark.triangle").workspaceTextRole(.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if revocationUnconfirmed {
                Text("Signed out here, but OpenAI didn't confirm it. You can also disconnect LokalBot in ChatGPT settings.")
                    .workspaceTextRole(.supporting)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task { status = await account.status() }
        .onChange(of: status) { ready = status?.allowsPlanUsage == true }
        .onDisappear {
            signInTask?.cancel()
            Task { await account.cancelSignIn() }
        }
        .alert("You're using your ChatGPT plan", isPresented: $showingNotice) {
            Button("Got it") { app.settings.chatGPTPlanNoticeAcknowledged = true }
            Button("Manage usage") {
                app.settings.chatGPTPlanNoticeAcknowledged = true
                NSWorkspace.shared.open(SubscriptionPlan.chatGPT.manageUsageURL)
            }
        } message: {
            Text("Eligible requests from LokalBot now use your ChatGPT plan. Manage usage and app access in ChatGPT settings. LokalBot has no charges of its own.")
        }
    }

    private func signedOut(previousEmail: String?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Use your ChatGPT plan for Think instead of an API key.")
                .workspaceTextRole(.supporting)
            HStack(spacing: 12) {
                Button(signingIn ? "Waiting for your browser…" : "Continue with ChatGPT") {
                    startSignIn(newRegistration: false)
                }
                .primaryActionButton()
                .disabled(signingIn)
                .accessibilityIdentifier("models.chatGPTPlan.signIn")
                if signingIn {
                    Button("Cancel") { cancelSignIn() }
                } else if previousEmail != nil {
                    Button("Use a different account") { startSignIn(newRegistration: true) }
                        .buttonStyle(.workspaceLink)
                }
            }
            if signingIn {
                Text("Finish signing in in your browser, then return here.").workspaceTextRole(.supporting)
            } else if let previousEmail {
                Text("Last signed in as \(previousEmail).").workspaceTextRole(.supporting)
            }
        }
    }

    private func signedIn(email: String?, planUsage: Bool) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
            PlanRow(title: "Account") {
                HStack(spacing: 8) {
                    Label(email ?? "Signed in", systemImage: "checkmark.circle.fill")
                        .font(AppFont.scaled(.body))
                        .lineLimit(1).truncationMode(.middle)
                        .accessibilityIdentifier("models.chatGPTPlan.connected")
                    Spacer(minLength: 8)
                    // Switching accounts is offered after signing out.
                    Button("Sign out") { signOut() }
                        .buttonStyle(.workspaceLink)
                        .disabled(signingIn)
                }
            }
            if planUsage {
                PlanRow(title: "Model") {
                    SubscriptionPlanModelPicker(plan: .chatGPT, selection: $model, account: account,
                                                accountKey: email ?? "signed-in")
                }
                PlanRow(title: "Usage") {
                    HStack(spacing: 6) {
                        Text("Using ChatGPT plan").font(AppFont.scaled(.body))
                        Text("·").settingsSecondary()
                        Link("Manage usage", destination: SubscriptionPlan.chatGPT.manageUsageURL)
                    }
                }
            } else {
                PlanRow(title: "Usage") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("This sign-in doesn't allow requests on your plan.")
                            .workspaceTextRole(.warning)
                            .fixedSize(horizontal: false, vertical: true)
                        Button(signingIn ? "Waiting for your browser…" : "Allow plan usage…") {
                            startSignIn(newRegistration: false)
                        }
                        .disabled(signingIn)
                    }
                }
            }
        }
    }

    private func startSignIn(newRegistration: Bool) {
        signInTask?.cancel()
        accountError = nil
        revocationUnconfirmed = false
        signingIn = true
        signInTask = Task {
            defer { signingIn = false }
            do {
                if newRegistration { await account.forgetRegistration() }
                let result = try await account.signIn(newRegistration: newRegistration) { url in
                    await MainActor.run { NSWorkspace.shared.open(url) }
                }
                status = result
                app.modelChecks.invalidate(for: app.settings)
                if result.allowsPlanUsage, !app.settings.chatGPTPlanNoticeAcknowledged { showingNotice = true }
            } catch is CancellationError {
                status = await account.status()
            } catch {
                accountError = error.localizedDescription
                status = await account.status()
            }
        }
    }

    private func cancelSignIn() {
        signInTask?.cancel()
        Task { await account.cancelSignIn() }
    }

    private func signOut() {
        accountError = nil
        signingIn = true
        Task {
            defer { signingIn = false }
            revocationUnconfirmed = !(await account.signOut())
            status = await account.status()
            app.modelChecks.invalidate(for: app.settings)
        }
    }
}

// MARK: - Claude

private struct ClaudePlanAccountSection: View {
    @Binding var model: String
    @Binding var ready: Bool
    @State private var executable: URL?
    @State private var authStatus: ClaudeCodeCLI.AuthStatus?
    @State private var version: String?
    @State private var checking = true
    @State private var statusError: String?

    static let setupURL = URL(string: "https://code.claude.com/docs/en/setup")!

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Runs your own Claude Code with its tools turned off. You sign in to Claude Code yourself; LokalBot never sees your Claude sign-in.")
                .workspaceTextRole(.supporting)
                .fixedSize(horizontal: false, vertical: true)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
                PlanRow(title: "Account") { accountStatus }
                if authStatus?.loggedIn == true {
                    PlanRow(title: "Model") {
                        SubscriptionPlanModelPicker(plan: .claude, selection: $model)
                    }
                }
            }
        }
        .task { await check(refresh: false) }
        .onChange(of: authStatus) { ready = authStatus?.loggedIn == true }
    }

    @ViewBuilder
    private var accountStatus: some View {
        if checking {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Looking for Claude Code…").workspaceTextRole(.supporting)
            }
        } else if executable == nil {
            VStack(alignment: .leading, spacing: 8) {
                Label("Claude Code isn't installed on this Mac.", systemImage: "exclamationmark.triangle")
                    .workspaceTextRole(.warning)
                HStack(spacing: 12) {
                    Link("How to install Claude Code", destination: Self.setupURL)
                    Button("Check again") { Task { await check(refresh: true) } }
                }
            }
        } else if let authStatus, authStatus.loggedIn {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Label(signedInText(authStatus), systemImage: "checkmark.circle.fill")
                        .font(AppFont.scaled(.body))
                        .lineLimit(1).truncationMode(.middle)
                        .help([executable?.path, version].compactMap { $0 }.joined(separator: " · "))
                        .accessibilityIdentifier("models.claudePlan.connected")
                    Spacer(minLength: 8)
                    Link("Manage usage", destination: SubscriptionPlan.claude.manageUsageURL)
                }
                if !authStatus.usesSubscription {
                    Text("Claude Code signs in with \(authStatus.authMethod ?? "another method") rather than a Claude plan, so requests are billed that way.")
                        .workspaceTextRole(.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Label("Claude Code isn't signed in.", systemImage: "exclamationmark.triangle")
                    .workspaceTextRole(.warning)
                Text("Open Terminal, run claude, and sign in with your Claude account. Then check again.")
                    .workspaceTextRole(.supporting)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 12) {
                    Button("Open Terminal") { openTerminal() }
                    Button("Check again") { Task { await check(refresh: true) } }
                }
            }
        }
        if let statusError {
            Text(statusError).workspaceTextRole(.warning).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func signedInText(_ status: ClaudeCodeCLI.AuthStatus) -> String {
        var parts: [String] = []
        if let email = status.email { parts.append(email) }
        if let plan = status.planName { parts.append("\(plan) plan") }
        return parts.isEmpty ? "Signed in" : parts.joined(separator: " · ")
    }

    private func check(refresh: Bool) async {
        checking = true
        statusError = nil
        defer { checking = false }
        executable = await ClaudeCodeLocator.shared.executable(refresh: refresh)
        guard let executable else {
            authStatus = nil
            return
        }
        version = await ClaudeCodeCLI.version(executable: executable)
        do {
            authStatus = try await ClaudeCodeCLI.authStatus(executable: executable)
        } catch {
            authStatus = nil
            statusError = error.localizedDescription
        }
    }

    private func openTerminal() {
        guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else {
            return
        }
        NSWorkspace.shared.openApplication(at: terminal, configuration: NSWorkspace.OpenConfiguration())
    }
}

// MARK: - Consent

private struct SubscriptionPlanConsentSection: View {
    let plan: SubscriptionPlan
    @Binding var consent: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Allow sending context to \(plan.providerName) with my \(plan.title)", isOn: $consent)
                .font(AppFont.scaled(.body).weight(.medium))
                .accessibilityIdentifier("models.planConsent")
            Text("Think sends meeting transcripts, screen text, and dictation requests to "
                 + "\(plan.providerName) when you use those features. Scheduled daily summaries and "
                 + "overnight review also run there without asking each time, including activity titles, "
                 + "meeting evidence, and retained Dream memory. \(plan.providerName)'s terms for your "
                 + "account apply.")
                .workspaceTextRole(.trust)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: Brand.Radius.row))
    }
}
