import SwiftUI

/// The Hand off review panel: the window LokalBot read, the brief the Think
/// model wrote, which the person can edit, and where to hand it.
struct WindowHandoffView: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        WindowHandoffContent(controller: app.windowHandoff)
            .background(HiddenWindowButtons())
    }
}

private struct WindowHandoffContent: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @ObservedObject var controller: WindowHandoffController
    @FocusState private var briefFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Divider()
            footer
        }
        .frame(width: 640, height: 540)
        .background {
            if reduceTransparency {
                Color(nsColor: .windowBackgroundColor)
            } else {
                Rectangle().fill(.regularMaterial)
            }
        }
        .onDisappear { controller.panelClosed() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            sourceIcon
            VStack(alignment: .leading, spacing: 3) {
                Text("Hand off this window")
                    .font(.scaled(.title3).weight(.semibold))
                Text(verbatim: sourceTitle)
                    .font(.scaled(.callout))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityIdentifier("windowHandoff.source")
                Text(verbatim: captureSummary)
                    .font(.scaled(.caption))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    @ViewBuilder private var sourceIcon: some View {
        let appName = controller.capture.source?.appName ?? ""
        if !appName.isEmpty, let icon = QuickRecallApplicationIconResolver.icon(for: appName) {
            Image(nsImage: icon)
                .resizable()
                .scaledToFit()
                .frame(width: 32, height: 32)
                .accessibilityHidden(true)
        } else {
            Image(systemName: "arrow.up.forward.app")
                .font(.scaled(.title))
                .foregroundStyle(.tint)
                .frame(width: 32, height: 32)
                .accessibilityHidden(true)
        }
    }

    private var sourceTitle: String {
        let capture = controller.capture
        let title = capture.windowTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let app = capture.source?.appName ?? ""
        switch (title.isEmpty, app.isEmpty) {
        case (false, false): return "\(title) · \(app)"
        case (false, true): return title
        case (true, false): return app
        case (true, true): return ""
        }
    }

    /// What was read: the address, how much text, the screenshot, and any
    /// redactions.
    private var captureSummary: String {
        let capture = controller.capture
        let language = app.settings.appLanguage
        guard capture.hasContent else { return capture.sourceURL ?? "" }
        var parts: [String] = []
        if let url = capture.sourceURL { parts.append(url) }
        parts.append(String(format: language.localized("%@ characters"), capture.text.count.formatted()))
        if capture.textFromScreenshot { parts.append(language.localized("read from the screenshot")) }
        if capture.screenshot != nil { parts.append(language.localized("screenshot")) }
        if capture.redactions > 0 {
            parts.append(String(format: language.localized("%@ redacted"), capture.redactions.formatted()))
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Content

    @ViewBuilder private var content: some View {
        if controller.needsSourceWindow {
            message(icon: "macwindow") {
                Text("Switch to the window you want to hand off, then press the Hand off shortcut.")
            }
        } else if controller.phase == .capturing {
            LoadingStateLabel(app.settings.appLanguage.localized("Reading the window…"))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let issue = controller.capture.issue {
            issueView(issue)
        } else if controller.phase != .idle, !controller.capture.hasContent {
            message(icon: "doc.text") {
                Text("LokalBot found no text in this window, so there is nothing to hand off.")
            }
        } else if controller.phase != .idle {
            briefEditor
        }
    }

    private func issueView(_ issue: WindowHandoffCapture.Issue) -> some View {
        message(icon: issue == .accessibilityNeeded ? "hand.raised" : "lock.shield") {
            switch issue {
            case .accessibilityNeeded:
                Text("LokalBot needs Accessibility access to read the window.")
            case .excludedApp:
                Text("This app is in your excluded apps, so LokalBot didn't read anything from it.")
            case .excludedSite:
                Text("This page is in your excluded sites, or its address couldn't be checked, so LokalBot didn't read anything from it.")
            case .secureField:
                Text("A password field is in this window, so LokalBot didn't read anything from it.")
            case .unreadable:
                Text("LokalBot couldn't read this window. Click into it and press the shortcut again.")
            }
            if issue == .accessibilityNeeded, let url = AppPermission.accessibility.settingsURL {
                Button("Open Accessibility Settings") { _ = NSWorkspace.shared.open(url) }
            }
        }
    }

    private func message<Content: View>(icon: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.scaled(.title))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            content()
                .font(.scaled(.callout))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
                .accessibilityIdentifier("windowHandoff.issue")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private var briefEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Brief")
                    .font(.scaled(.caption).weight(.semibold))
                    .foregroundStyle(.secondary)
                if controller.phase == .writing {
                    ProgressView().controlSize(.small)
                    Text(verbatim: writingLabel)
                        .font(.scaled(.caption))
                        .foregroundStyle(.secondary)
                } else if controller.briefIsTemplate {
                    Text("A simple brief from LokalBot. Edit it before handing off.")
                        .font(.scaled(.caption))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            if let notice = controller.notice {
                Text(verbatim: notice)
                    .font(.scaled(.caption))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("windowHandoff.notice")
            }
            if controller.phase == .writing {
                ScrollView {
                    Text(verbatim: controller.brief)
                        .font(.scaled(.body))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(8)
                .background(.quaternary.opacity(0.35),
                            in: RoundedRectangle(cornerRadius: Brand.Radius.control, style: .continuous))
            } else {
                TextEditor(text: $controller.brief)
                    .font(.scaled(.body))
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .background(.quaternary.opacity(0.35),
                                in: RoundedRectangle(cornerRadius: Brand.Radius.control, style: .continuous))
                    .focused($briefFocused)
                    .disabled(controller.phase == .handingOff)
                    .accessibilityLabel("Brief")
                    .accessibilityIdentifier("windowHandoff.brief")
            }
            targetPicker
        }
        .padding(18)
    }

    private var writingLabel: String {
        let language = app.settings.appLanguage
        return controller.modelName.map { String(format: language.localized("Writing with %@…"), $0) }
            ?? language.localized("Writing the brief…")
    }

    private var targetPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Hand off to", selection: $controller.target) {
                ForEach(controller.targets) { target in
                    Text(LocalizedStringKey(target.rawValue)).tag(target)
                }
            }
            .pickerStyle(.segmented)
            .disabled(controller.phase == .handingOff)
            .accessibilityIdentifier("windowHandoff.target")
            targetNote
                .font(.scaled(.caption))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Whether anything leaves the Mac before the person presses Send there.
    @ViewBuilder private var targetNote: some View {
        switch controller.target {
        case .agentMode:
            if app.settings.startHandoffsAutomatically {
                Text("A new Agent Mode task opens and starts on its own, as set in Settings.")
            } else {
                Text("A new Agent Mode task opens with the brief in its composer. Nothing is sent until you press Send.")
            }
        case .claudeCode:
            Text("Claude Code opens with the prompt typed in. Nothing is sent until you press Send there.")
        case .codex:
            Text("Codex opens with the prompt typed in. Nothing is sent until you press Send there.")
        case .copy:
            Text("The brief and the handoff folder's location are copied to the clipboard.")
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 12) {
            if controller.phase == .writing {
                Button("Skip", action: controller.skipBrief)
                    .help("Use a simple brief instead of waiting for the model")
            } else if controller.phase == .ready, controller.capture.hasContent {
                Button("Write Again", action: controller.rewriteBrief)
                    .help("Write the brief again with the model. Your edits are replaced.")
            }
            Spacer(minLength: 0)
            inferenceLabel
            Button("Cancel", action: controller.dismiss)
                .keyboardShortcut(.cancelAction)
            Button("Hand Off", action: controller.handOff)
                .keyboardShortcut(.defaultAction)
                .disabled(!controller.canHandOff)
                .accessibilityIdentifier("windowHandoff.handOff")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .frame(minHeight: 44)
    }

    private var inferenceLabel: some View {
        let inference = InferencePresentation(settings: app.settings)
        let language = app.settings.appLanguage
        return Label(inference.label, systemImage: inference.icon)
            .font(.scaled(.caption))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .help(inference.detail(
                local: language.localized("The brief is written by a model on this Mac."),
                remote: language.localized("The brief is written by your configured remote model.")))
    }
}
