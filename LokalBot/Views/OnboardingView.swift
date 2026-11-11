import AppKit
import SwiftUI

/// What the download step and its footer share while the window is open.
struct OnboardingDownloadSession: Equatable {
    var includeAutocomplete = false
    /// Download was pressed in this window.
    var started = false
    /// The roles that were on this Mac when the download began, so the
    /// progress counts only what this download fetches.
    var readyBefore: Set<ModelRole>?
    var opensSampleMeeting = true
}

/// First-run setup in three steps. Choices stay a draft until setup finishes;
/// permissions and model downloads happen only through their named actions.
struct OnboardingView: View {
    static let size = CGSize(width: 650, height: 668)

    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var permissions = PermissionManager.shared
    @State private var step: OnboardingStep = .choose
    /// Direction of the last step change, so the incoming page arrives from
    /// the side the user is moving toward.
    @State private var forward = true
    @State private var draft = CaptureSetupDraft(settings: AppSettings())
    /// The choices the settings held when this draft was started.
    @State private var baseline = CaptureSetupDraft(settings: AppSettings())
    @State private var download = OnboardingDownloadSession()
    /// Permissions whose System Settings pane this window opened.
    @State private var requested: Set<AppPermission> = []
    /// False until the window has loaded its state, and again once setup
    /// has finished, so nothing is saved for a setup that is not under way.
    @State private var saves = false

    private var access: OnboardingAccess {
        OnboardingAccess(
            draft: draft,
            granted: permissions.granted,
            grantedAtLaunch: permissions.grantedAtLaunch,
            requested: requested,
            turnedOff: permissions.turnedOff)
    }

    var body: some View {
        OnboardingFrame(step: step, forward: forward, select: go) {
            switch step {
            case .choose:
                OnboardingChooseStep(draft: $draft, settings: app.settings)
            case .access:
                OnboardingAccessStep(
                    access: access,
                    readsScreenText: draft.contextMode.capturesText,
                    allow: allow,
                    restart: restart)
            case .download:
                OnboardingDownloadStep(app: app, session: $download, retry: startDownload)
            }
        } footer: {
            footer
        }
        .onAppear(perform: begin)
        .onDisappear { permissions.stopPolling(); PermissionGuidanceController.shared.dismiss() }
        .onChange(of: step) { save() }
        .onChange(of: draft) { save() }
        .onChange(of: download.includeAutocomplete) { save() }
        .onChange(of: download.opensSampleMeeting) { save() }
        // A grant is the moment before a restart, asked for here or by macOS.
        .onChange(of: permissions.granted) { save() }
    }

    @ViewBuilder private var footer: some View {
        Group {
            switch step {
            case .choose:
                languagePicker
                Spacer(minLength: 8)
                continueButton
            case .access:
                Text("\(access.allowedCount) of \(access.rows.count) allowed")
                    .font(.scaled(.callout)).workspaceSupportingForeground()
                    .accessibilityIdentifier("onboarding.allowedCount")
                Spacer(minLength: 8)
                backButton
                continueButton
            case .download:
                OnboardingDownloadFooter(
                    app: app, session: download,
                    back: { go(to: .access) },
                    start: startDownload,
                    finish: finish)
            }
        }
    }

    private var languagePicker: some View {
        HStack(spacing: 6) {
            Image(systemName: "globe").foregroundStyle(.secondary).accessibilityHidden(true)
            Picker("App language", selection: $app.settings.appLanguage) {
                ForEach(AppLanguage.allCases) { language in
                    Text(verbatim: language.pickerLabel(in: app.settings.appLanguage)).tag(language)
                }
            }
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
            .accessibilityIdentifier("onboarding.appLanguage")
        }
    }

    private var backButton: some View {
        Button("Back") { if let previous = step.previous { go(to: previous) } }
            .controlSize(.large)
            .accessibilityIdentifier("onboarding.back")
    }

    private var continueButton: some View {
        Button("Continue") { if let next = step.next { go(to: next) } }
            .primaryActionButton().controlSize(.large).keyboardShortcut(.defaultAction)
            .accessibilityIdentifier("onboarding.continue")
    }

    private func go(to next: OnboardingStep) {
        withAnimation(WorkspaceMotion.animation(.milestone, reduceMotion: reduceMotion)) {
            forward = next.rawValue > step.rawValue
            step = next
        }
    }

    // MARK: Actions

    private func allow(_ permission: AppPermission, from frame: CGRect) {
        requested.insert(permission)
        PermissionGuidanceController.shared.requestAccess(for: permission, sourceFrameInScreen: frame)
    }

    private func restart() {
        save(reopensAfterRestart: true)
        app.settingsStore.flush()
        PermissionManager.relaunch()
    }

    private func startDownload() {
        if !download.started {
            let snapshot = app.modelRoles.snapshot
            download.readyBefore = Set(ModelRole.allCases.filter { snapshot[$0].isReady })
            download.started = true
        }
        app.modelRoles.startCoreModelDownloads(includeAutocomplete: download.includeAutocomplete)
    }

    /// Applies the choices and ends setup. The sample meeting opens only
    /// when the person saw that option, which is once a download exists.
    private func finish(opensSampleMeeting: Bool) {
        saves = false
        app.finishOnboarding(applying: draft, opensSampleMeeting: opensSampleMeeting)
        dismiss()
    }

    // MARK: Resuming after a restart

    /// Every time the window opens: continue the setup that was under way
    /// for these settings, or start from the settings as they are now.
    private func begin() {
        permissions.refresh()
        permissions.startPolling()
        saves = true
        baseline = CaptureSetupDraft(settings: app.settings)
        if let saved = OnboardingResumeStore.live.load(for: app.settings) {
            draft = saved.draft
            step = saved.step
            download.includeAutocomplete = saved.includeAutocomplete
            download.opensSampleMeeting = saved.opensSampleMeeting
            // The restart it was saved for has happened.
            if saved.reopensAfterRestart { save() }
        } else {
            draft = baseline
            step = .choose
        }
    }

    private func save(reopensAfterRestart: Bool = false) {
        guard saves else { return }
        OnboardingResumeStore.live.save(OnboardingResumeState(
            step: step, draft: draft, baseline: baseline,
            includeAutocomplete: download.includeAutocomplete,
            opensSampleMeeting: download.opensSampleMeeting,
            reopensAfterRestart: reopensAfterRestart))
    }
}

// MARK: - Window layout

/// The setup window: the stepper as its top bar, one scrolling step, and the
/// footer that moves between steps.
struct OnboardingFrame<Content: View, Footer: View>: View {
    let step: OnboardingStep
    var forward = true
    let select: (OnboardingStep) -> Void
    @ViewBuilder var content: Content
    @ViewBuilder var footer: Footer
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Height of the window's own title bar, which pushes the content down.
    @State private var titleBar: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            // In a window, the steps share the title bar with the traffic
            // lights and line up with them; elsewhere they get a bar of their own.
            OnboardingStepper(current: step, select: select)
                .frame(maxWidth: .infinity)
                .frame(height: titleBar > 0 ? titleBar : 40)
                .padding(.bottom, titleBar > 0 ? 4 : 0)
                .padding(.top, -titleBar)
            Divider()
            ScrollView {
                // The ZStack lets the outgoing and incoming pages overlap
                // while they cross instead of stacking vertically.
                ZStack(alignment: .top) {
                    content
                        .padding(.horizontal, 44).padding(.top, 18).padding(.bottom, 12)
                        .frame(maxWidth: .infinity, alignment: .top)
                        .id(step)
                        .transition(WorkspaceMotion.stepTransition(forward: forward, reduceMotion: reduceMotion))
                }
            }
            Divider()
            HStack(spacing: 10) { footer }
                .padding(.horizontal, 20)
                .frame(height: 56)
        }
        // The title bar is part of the window's height, so the content gives it up.
        .frame(width: OnboardingView.size.width, height: OnboardingView.size.height - titleBar)
        .background(WindowTitleBarReader(height: $titleBar))
        .toggleStyle(LBAccentSwitchStyle())
    }
}

/// Reads how far the window's title bar pushes its content down. AppKit
/// knows this on every system; the geometry SwiftUI reported for it was
/// zero on macOS 26, which left the stepper in a bar of its own below the
/// traffic lights and the window a title bar too tall.
private struct WindowTitleBarReader: NSViewRepresentable {
    @Binding var height: CGFloat

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.onChange = { height = $0 }
        return view
    }

    func updateNSView(_ nsView: ProbeView, context: Context) {
        nsView.onChange = { height = $0 }
        nsView.report()
    }

    final class ProbeView: NSView {
        var onChange: ((CGFloat) -> Void)?
        private var reported: CGFloat?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            report()
        }

        override func layout() {
            super.layout()
            report()
        }

        func report() {
            guard let content = window?.contentView else { return }
            // A stray value must not push the stepper out of the window.
            let height = min(max(content.safeAreaInsets.top.rounded(), 0), 60)
            guard height != reported else { return }
            reported = height
            DispatchQueue.main.async { [onChange] in onChange?(height) }
        }
    }
}

// MARK: - Stepper

/// The window's top bar: the three steps by name. A finished step shows a
/// check and goes back to it when clicked.
struct OnboardingStepper: View {
    let current: OnboardingStep
    let select: (OnboardingStep) -> Void

    var body: some View {
        HStack(spacing: 9) {
            ForEach(OnboardingStep.allCases) { step in
                if step != OnboardingStep.allCases.first {
                    Rectangle()
                        .fill(step.rawValue <= current.rawValue
                              ? AnyShapeStyle(LBTokens.Palette.accentFill) : AnyShapeStyle(.quaternary))
                        .frame(width: 26, height: 1.5)
                        .accessibilityHidden(true)
                }
                item(step)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Setup progress")
        .accessibilityValue("Step \(current.rawValue + 1) of \(OnboardingStep.allCases.count)")
        .accessibilityIdentifier("onboarding.progress")
    }

    @ViewBuilder private func item(_ step: OnboardingStep) -> some View {
        if step.rawValue < current.rawValue {
            Button { select(step) } label: {
                label(step, marker: marker(done: step))
                    .workspaceSupportingForeground()
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue("Done")
            .accessibilityIdentifier("onboarding.step.\(step.rawValue + 1)")
        } else if step == current {
            label(step, marker: marker(number: step, current: true))
                .fontWeight(.semibold)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isSelected)
                .accessibilityIdentifier("onboarding.step.\(step.rawValue + 1)")
        } else {
            label(step, marker: marker(number: step, current: false))
                .foregroundStyle(.secondary)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("onboarding.step.\(step.rawValue + 1)")
        }
    }

    private func label(_ step: OnboardingStep, marker: some View) -> some View {
        HStack(spacing: 6) {
            marker
            Text(LocalizedStringKey(step.title)).font(.scaled(.callout)).lineLimit(1)
        }
    }

    private func marker(done step: OnboardingStep) -> some View {
        Image(systemName: "checkmark")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(Brand.teal)
            .frame(width: 18, height: 18)
            .background(Brand.teal.opacity(0.14), in: Circle())
            .accessibilityHidden(true)
    }

    private func marker(number step: OnboardingStep, current: Bool) -> some View {
        Text(step.rawValue + 1, format: .number)
            .font(.system(size: 10.5, weight: .bold))
            .foregroundStyle(current ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
            .frame(width: 18, height: 18)
            .background {
                if current {
                    Circle().fill(LBTokens.Palette.accentFill)
                } else {
                    Circle().strokeBorder(.tertiary, lineWidth: 1.2)
                }
            }
            .accessibilityHidden(true)
    }
}

// MARK: - Shared parts

/// A step's title with one lead sentence, centred.
struct OnboardingHeading: View {
    let title: LocalizedStringKey
    var lead: LocalizedStringKey?

    var body: some View {
        VStack(spacing: 7) {
            Text(title)
                .font(.scaled(.title).bold())
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("onboarding.title")
            if let lead {
                Text(lead)
                    .font(.scaledSystem(size: 13.5))
                    .workspaceSupportingForeground()
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 480)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// Rows in one grouped card. Callers place a `Divider()` between rows.
struct OnboardingCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .lbGroupedSurface()
    }
}

/// One card row: a symbol tile, its text, and a control or state at the end.
struct OnboardingRow<Detail: View, Trailing: View>: View {
    let symbol: String
    var alignment: VerticalAlignment = .center
    @ViewBuilder var detail: Detail
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: alignment, spacing: 12) {
            IconTile(systemImage: symbol, tint: Brand.teal, size: 30)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) { detail }
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 8) { trailing }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(minHeight: 56)
    }
}

/// A row's title, with the quiet tag that says what it is for.
struct OnboardingRowTitle: View {
    let title: LocalizedStringKey
    var tag: LocalizedStringKey?

    var body: some View {
        HStack(spacing: 7) {
            Text(title).font(.scaled(.body).weight(.semibold))
            if let tag {
                Text(tag)
                    .font(.scaledSystem(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(.quaternary.opacity(0.5), in: Capsule())
            }
        }
    }
}

/// A quiet line under a card: a small symbol and one sentence.
struct OnboardingNote: View {
    let symbol: String
    let text: LocalizedStringKey

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol).font(.scaled(.callout)).accessibilityHidden(true)
            Text(text).font(.scaled(.callout)).fixedSize(horizontal: false, vertical: true)
        }
        .workspaceSupportingForeground()
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 2)
    }
}

/// A green check with one word: Allowed, Ready.
struct OnboardingDoneLabel: View {
    let text: LocalizedStringKey

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).accessibilityHidden(true)
            Text(text).font(.scaled(.callout).weight(.semibold))
        }
        .foregroundStyle(LBTokens.Palette.successText)
    }
}
