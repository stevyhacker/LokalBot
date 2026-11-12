import SwiftUI

extension OnboardingDownloadPlan {
    /// The plan for what the app has selected and what is on this Mac now.
    @MainActor
    init(app: AppState, roles: ModelRoles, session: OnboardingDownloadSession) {
        let snapshot = roles.snapshot
        let ready = Set(ModelRole.allCases.filter { snapshot[$0].isReady })
        self.init(settings: app.settings,
                  statuses: snapshot.statuses,
                  includeAutocomplete: session.includeAutocomplete,
                  started: session.started,
                  readyBefore: session.readyBefore ?? ready,
                  availableBytes: snapshot.readiness.availableBytes)
    }
}

private func byteCount(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

/// Setup, step 3. Download progress reaches only the views that observe
/// `ModelRoles`: AppState does not relay it.
struct OnboardingDownloadStep: View {
    @ObservedObject var app: AppState
    @ObservedObject private var roles: ModelRoles
    @Binding var session: OnboardingDownloadSession
    let retry: () -> Void
    @ObservedObject private var permissions = PermissionManager.shared
    @State private var estimator = DownloadTimeEstimator()

    init(app: AppState, session: Binding<OnboardingDownloadSession>, retry: @escaping () -> Void) {
        self.app = app
        roles = app.modelRoles
        _session = session
        self.retry = retry
    }

    var body: some View {
        let plan = OnboardingDownloadPlan(app: app, roles: roles, session: session)
        OnboardingDownloadContent(
            plan: plan,
            // An estimate only once the speed has been watched for a while.
            minutesLeft: plan.downloadedBytes == nil ? nil
                : plan.totalBytes.flatMap { estimator.minutesLeft(totalBytes: $0) },
            destination: InferencePresentation(settings: app.settings),
            microphoneAllowed: permissions.granted[.microphone] == true,
            showsDownloadSource: showsDownloadSource,
            session: $session,
            downloadSource: $app.settings.modelDownloadSource,
            retry: retry)
            .onAppear { settle(plan.phase) }
            .onChange(of: plan.phase) { _, phase in settle(phase) }
            .onChange(of: plan.downloadedBytes) { _, bytes in
                if let bytes { estimator.record(downloadedBytes: bytes, at: Date()) } else { estimator.reset() }
            }
    }

    /// A download that began outside this window (before a restart, or from
    /// Settings) counts what is missing from the moment it is first seen.
    private func settle(_ phase: OnboardingDownloadPlan.Phase) {
        guard phase != .before, session.readyBefore == nil else { return }
        let snapshot = roles.snapshot
        session.readyBefore = Set(ModelRole.allCases.filter { snapshot[$0].isReady })
    }

    /// huggingface.co is blocked in mainland China, so the first download
    /// offers HF-Mirror and ModelScope there: on a Mac set to that region or to
    /// Simplified Chinese, or once a mirror is already chosen. Settings → Models
    /// always has the same picker.
    private var showsDownloadSource: Bool {
        Locale.current.region?.identifier == "CN"
            || Locale.preferredLanguages.first?.hasPrefix("zh-Hans") == true
            || app.settings.appLanguage == .simplifiedChinese
            || app.settings.modelDownloadSource != .huggingFace
    }
}

/// The download step for one plan: each model's job and size before anything
/// downloads, then progress per model and overall.
struct OnboardingDownloadContent: View {
    let plan: OnboardingDownloadPlan
    /// Nil until the speed makes an honest estimate.
    let minutesLeft: Int?
    /// Where Think runs. A server is disclosed; this Mac needs no note.
    let destination: InferencePresentation
    let microphoneAllowed: Bool
    let showsDownloadSource: Bool
    @Binding var session: OnboardingDownloadSession
    @Binding var downloadSource: ModelDownloadSource
    let retry: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            heading(plan)
            OnboardingCard {
                if plan.phase != .before, !(plan.phase == .finished && !plan.allReady) {
                    hero(plan)
                    Divider()
                }
                ForEach(plan.models) { model in
                    if model.id != plan.models.first?.id { Divider() }
                    row(model, plan: plan)
                }
            }
            if session.includeAutocomplete, plan.models.contains(where: { $0.role == .autocomplete }) {
                Text("Autocomplete also reads the window you are typing in, such as the conversation you are answering, to fit its suggestions: the text just above the field, and, once Screen Recording is allowed, the whole window with on-device text recognition. It stays on this Mac and is never saved; turn either off in Settings → Autocomplete.")
                    .font(.scaled(.callout)).workspaceSupportingForeground()
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 2)
            }
            if destination != .onDevice {
                InferenceDisclosure(destination: destination,
                                    localText: "The configured Think model processes selected context on this Mac.",
                                    remoteText: "Selected transcript and work context is sent to the approved model server.")
            }
            if plan.phase == .before {
                beforeNotes(plan)
            } else {
                afterOptions(plan)
            }
        }
        .animation(WorkspaceMotion.animation(.milestone, reduceMotion: reduceMotion), value: plan.phase)
    }

    // MARK: Heading

    @ViewBuilder private func heading(_ plan: OnboardingDownloadPlan) -> some View {
        switch plan.phase {
        case .before:
            OnboardingHeading(
                title: "Download the models",
                lead: "LokalBot transcribes, writes notes and answers questions on this Mac, so it needs the models below. They download once, then work offline.")
        case .running, .stopped:
            OnboardingHeading(
                title: "Downloading the models",
                lead: "You can start now. The download keeps going in the background.")
        case .finished:
            if plan.allReady {
                OnboardingHeading(
                    title: "You’re ready",
                    lead: destination == .onDevice
                        ? "The models are on this Mac, so notes and answers work offline too." : nil)
            } else {
                OnboardingHeading(title: "Prepare Your Workflows")
            }
        }
    }

    // MARK: Overall progress

    private func hero(_ plan: OnboardingDownloadPlan) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                heroTitle(plan)
                    .font(.scaled(.title3).weight(.semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                heroAmount(plan)
                    .font(.scaled(.callout).monospacedDigit())
                    .workspaceSupportingForeground()
            }
            if plan.phase == .finished {
                ProgressView(value: 1).tint(LBTokens.Palette.accentFill)
            } else if let fraction = plan.fraction {
                ProgressView(value: fraction).tint(LBTokens.Palette.accentFill)
            } else if plan.isDownloading {
                ProgressView().progressViewStyle(.linear).tint(LBTokens.Palette.accentFill)
            }
            if plan.phase == .stopped, let message = plan.stoppedModels.compactMap(\.stoppedMessage).first {
                Text(verbatim: message)
                    .font(.scaled(.callout)).workspaceSupportingForeground()
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 13)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("onboarding.downloadProgress")
    }

    @ViewBuilder private func heroTitle(_ plan: OnboardingDownloadPlan) -> some View {
        switch plan.phase {
        case .stopped:
            Label(plan.stoppedModels.count == 1 ? "One download stopped" : "Downloads stopped",
                  systemImage: "exclamationmark.triangle")
                .foregroundStyle(LBTokens.Palette.attentionText)
        case .finished:
            Label("Your models are ready", systemImage: "checkmark")
                .foregroundStyle(LBTokens.Palette.successText)
        case .before, .running:
            if let minutesLeft {
                if minutesLeft == 1 { Text("About 1 minute left") } else { Text("About \(minutesLeft) minutes left") }
            } else {
                Text("Downloading…")
            }
        }
    }

    @ViewBuilder private func heroAmount(_ plan: OnboardingDownloadPlan) -> some View {
        if let total = plan.totalBytes, total > 0 {
            if plan.phase == .finished {
                Text("\(byteCount(total)) downloaded")
            } else if let downloaded = plan.downloadedBytes {
                // Sizes carry their unit, so the pair reads the same in every language.
                Text(verbatim: "\(byteCount(downloaded)) / \(byteCount(total))")
            }
        }
    }

    // MARK: Models

    private func row(_ model: OnboardingDownloadPlan.Model, plan: OnboardingDownloadPlan) -> some View {
        OnboardingRow(symbol: model.symbol) {
            OnboardingRowTitle(title: LocalizedStringKey(model.title),
                               tag: model.role == .autocomplete ? "Optional" : nil)
            Text("\(Text(LocalizedStringKey(model.job))) · \(model.name)")
                .font(.scaled(.callout)).workspaceSupportingForeground()
                .fixedSize(horizontal: false, vertical: true)
        } trailing: {
            modelState(model, plan: plan)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("onboarding.model.\(model.role.rawValue)")
    }

    @ViewBuilder
    private func modelState(_ model: OnboardingDownloadPlan.Model, plan: OnboardingDownloadPlan) -> some View {
        switch model.state {
        case .ready:
            OnboardingDoneLabel(text: "Ready")
        case .needsSetup:
            Text("Needs Attention").font(.scaled(.callout).weight(.semibold))
                .foregroundStyle(LBTokens.Palette.attentionText)
        case .downloading(let progress):
            if let progress {
                ProgressView(value: min(1, max(0, progress)))
                    .tint(LBTokens.Palette.accentFill)
                    .frame(width: 84)
                Text(progress, format: .percent.precision(.fractionLength(0)))
                    .font(.scaled(.callout).monospacedDigit()).workspaceSupportingForeground()
                    .frame(minWidth: 34, alignment: .trailing)
            } else {
                ProgressView().controlSize(.small)
            }
        case .stopped:
            Text("Stopped").font(.scaled(.callout).weight(.semibold))
                .foregroundStyle(LBTokens.Palette.attentionText)
            Button("Retry", action: retry)
                .accessibilityIdentifier("onboarding.retry.\(model.role.rawValue)")
        case .notStarted:
            if let bytes = model.bytes {
                Text(verbatim: byteCount(bytes))
                    .font(.scaled(.callout).monospacedDigit()).workspaceSupportingForeground()
            }
            if model.role == .autocomplete, plan.phase == .before {
                Toggle("Also prepare Autocomplete (optional)", isOn: $session.includeAutocomplete)
                    .labelsHidden()
                    .accessibilityLabel("Also prepare Autocomplete (optional)")
                    .accessibilityIdentifier("onboarding.includeAutocomplete")
            }
        }
    }

    // MARK: Before the download

    private func beforeNotes(_ plan: OnboardingDownloadPlan) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sizeNote(plan)
            OnboardingNote(symbol: "clock", text: "You can use LokalBot while it downloads.")
            OnboardingNote(symbol: "lock", text: "Downloads use the model provider. They do not send your meeting content. Existing downloaded models are kept.")
            if showsDownloadSource {
                ModelDownloadSourcePicker(source: $downloadSource,
                                          accessibilityIdentifier: "onboarding.downloadSource")
                    .padding(.top, 6).padding(.horizontal, 2)
            }
        }
        .padding(.top, -4)
    }

    /// The total and the free space, in the warning colour when it will not fit.
    @ViewBuilder private func sizeNote(_ plan: OnboardingDownloadPlan) -> some View {
        let total = plan.remainingBytes.flatMap { $0 > 0 ? byteCount($0) : nil }
        let free = plan.availableBytes.map { byteCount(max(0, $0)) }
        if total != nil || free != nil {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: plan.fitsOnDisk ? "arrow.down.to.line" : "exclamationmark.triangle")
                    .accessibilityHidden(true)
                if let total { Text("\(total) in all").fontWeight(.semibold) }
                if total != nil, free != nil { Text(verbatim: "·") }
                if let free { Text("\(free) free on this Mac") }
            }
            .font(.scaled(.callout))
            .foregroundStyle(plan.fitsOnDisk ? Color.primary : LBTokens.Palette.attentionText)
            .padding(.horizontal, 2)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("onboarding.downloadSize")
        }
    }

    // MARK: While it downloads, and after

    private func afterOptions(_ plan: OnboardingDownloadPlan) -> some View {
        let waiting = plan.phase != .finished
        return VStack(alignment: .leading, spacing: 10) {
            if waiting {
                Text("While you wait").font(.scaled(.headline)).padding(.leading, 2)
                    .accessibilityAddTraits(.isHeader)
            }
            OnboardingCard {
                Toggle(isOn: $session.opensSampleMeeting) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(LocalizedStringKey(waiting
                            ? "Open a sample meeting when the models are ready"
                            : "Open the sample meeting first"))
                            .font(.scaled(.body).weight(.semibold))
                        Text("A made-up three-and-a-half-minute call. Read its notes and ask it a question before your first real meeting.")
                            .font(.scaled(.callout)).workspaceSupportingForeground()
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.leading, 4)
                }
                .toggleStyle(.checkbox)
                .tint(LBTokens.Palette.accentFill)
                .padding(.horizontal, 14).padding(.vertical, 11)
                .accessibilityIdentifier("onboarding.openSample")
                if waiting, microphoneAllowed {
                    Divider()
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: "mic").foregroundStyle(Brand.teal).frame(width: 16)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Recording already works").font(.scaled(.body).weight(.semibold))
                            Text("A meeting you record now gets its notes as soon as the download finishes.")
                                .font(.scaled(.callout)).workspaceSupportingForeground()
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.horizontal, 14).padding(.vertical, 11)
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }
}

private extension OnboardingDownloadPlan.Model {
    var symbol: String {
        switch role {
        case .transcribe: "waveform"
        case .think: "doc.text"
        case .autocomplete: "keyboard"
        }
    }

    var stoppedMessage: String? {
        if case .stopped(let message) = state { return message }
        return nil
    }
}

/// The download step's footer, kept current by `ModelRoles`.
struct OnboardingDownloadFooter: View {
    @ObservedObject var app: AppState
    @ObservedObject private var roles: ModelRoles
    let session: OnboardingDownloadSession
    let back: () -> Void
    let start: () -> Void
    /// Ends setup; true opens the sample meeting when its models are ready.
    let finish: (Bool) -> Void

    init(app: AppState, session: OnboardingDownloadSession, back: @escaping () -> Void,
         start: @escaping () -> Void, finish: @escaping (Bool) -> Void) {
        self.app = app
        roles = app.modelRoles
        self.session = session
        self.back = back
        self.start = start
        self.finish = finish
    }

    var body: some View {
        OnboardingDownloadFooterContent(
            plan: OnboardingDownloadPlan(app: app, roles: roles, session: session),
            opensSampleMeeting: session.opensSampleMeeting,
            back: back, start: start, finish: finish)
    }
}

/// Skip and "Download 5.2 GB" before anything downloads, then the way into
/// the app while it runs.
struct OnboardingDownloadFooterContent: View {
    let plan: OnboardingDownloadPlan
    let opensSampleMeeting: Bool
    let back: () -> Void
    let start: () -> Void
    let finish: (Bool) -> Void

    var body: some View {
        if plan.phase == .before {
            Button("Skip for now") { finish(false) }
                .buttonStyle(.workspaceLink)
                .accessibilityIdentifier("onboarding.skipDownload")
        } else if plan.phase != .finished {
            Text("Closing this window doesn’t stop the download.")
                .font(.scaled(.callout)).workspaceSupportingForeground()
                .fixedSize(horizontal: false, vertical: true)
        }
        Spacer(minLength: 8)
        Button("Back", action: back)
            .controlSize(.large)
            .accessibilityIdentifier("onboarding.back")
        if plan.phase == .before {
            Button(action: start) {
                if let bytes = plan.remainingBytes, bytes > 0 {
                    Text("Download \(byteCount(bytes))")
                } else {
                    Text("Download")
                }
            }
            .primaryActionButton().controlSize(.large).keyboardShortcut(.defaultAction)
            .accessibilityIdentifier("onboarding.downloadModels")
        } else {
            Button("Start using LokalBot") { finish(opensSampleMeeting) }
                .primaryActionButton().controlSize(.large).keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("onboarding.finish")
        }
    }
}
