import AppKit
import SwiftUI

struct OnboardingDownloadSession: Equatable {
    var includeAutocomplete = false
    var started = false
    var readyBefore: Set<ModelRole>?
    var opensSampleMeeting = true
}

struct OnboardingView: View {
    static let size = CGSize(width: 650, height: 668)

    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var permissions = PermissionManager.shared
    @State private var step: OnboardingStep = .choose
    @State private var forward = true
    @State private var draft = CaptureSetupDraft(settings: AppSettings())
    @State private var baseline = CaptureSetupDraft(settings: AppSettings())
    @State private var download = OnboardingDownloadSession()
    @State private var requested: Set<AppPermission> = []
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

    private func finish(opensSampleMeeting: Bool) {
        saves = false
        app.finishOnboarding(applying: draft, opensSampleMeeting: opensSampleMeeting)
        dismiss()
    }

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

struct OnboardingFrame<Content: View, Footer: View>: View {
    let step: OnboardingStep
    var forward = true
    let select: (OnboardingStep) -> Void
    @ViewBuilder var content: Content
    @ViewBuilder var footer: Footer
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var titleBar: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            OnboardingStepper(current: step, select: select)
                .frame(maxWidth: .infinity)
                .frame(height: titleBar > 0 ? titleBar : 40)
                .padding(.bottom, titleBar > 0 ? 4 : 0)
                .padding(.top, -titleBar)
            Divider()
            ScrollView {
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
        .frame(width: OnboardingView.size.width, height: OnboardingView.size.height - titleBar)
        .background(WindowTitleBarReader(height: $titleBar))
        .toggleStyle(LBAccentSwitchStyle())
    }
}

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
            let height = min(max(content.safeAreaInsets.top.rounded(), 0), 60)
            guard height != reported else { return }
            reported = height
            DispatchQueue.main.async { [onChange] in onChange?(height) }
        }
    }
}

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

struct OnboardingCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .lbGroupedSurface()
    }
}

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
