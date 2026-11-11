import AppKit
import SwiftUI

/// Setup, step 1: what LokalBot does, that it stays on this Mac, and the
/// choices, each with its one real option beside it.
struct OnboardingChooseStep: View {
    @Binding var draft: CaptureSetupDraft
    let settings: AppSettings

    /// Nothing the AI features send leaves this Mac.
    private var everythingLocal: Bool {
        settings.remoteAIHosts.isEmpty && !InferencePresentation(settings: settings).isBlocked
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            welcome
            Text("What should LokalBot remember?")
                .font(.scaled(.headline))
                .padding(.leading, 2).padding(.bottom, -8)
                .accessibilityAddTraits(.isHeader)
            OnboardingCard {
                meetingNotes
                Divider()
                workday
                Divider()
                codingAgents
            }
            if draft.dayMemory {
                VStack(alignment: .leading, spacing: 6) {
                    OnboardingNote(
                        symbol: "info.circle",
                        text: "Private and incognito browser windows are captured like any other window unless you exclude the browser or site in Settings → Screen & Activity.")
                    OnboardingNote(
                        symbol: "lock",
                        text: "Text and images build on app activity. Images are encrypted on disk; captured text remains searchable under your retention policy.")
                }
                .padding(.top, -8)
            }
        }
    }

    private var welcome: some View {
        VStack(spacing: 7) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable().interpolation(.high)
                .frame(width: 60, height: 60)
                .accessibilityLabel("LokalBot")
            Text("Welcome to LokalBot")
                .font(.scaled(.title).bold())
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            Text("LokalBot takes notes in your meetings and remembers what you worked on, so you can search it or ask about it later.")
                .font(.scaledSystem(size: 13.5))
                .workspaceSupportingForeground()
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 480)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "lock").accessibilityHidden(true)
                // A server set up before setup was reopened is named for what it is.
                Text(LocalizedStringKey(everythingLocal
                    ? "Everything is processed and stored on this Mac. No account needed."
                    : "Local models process on this Mac. Each remote server requires its own approval before context can leave the Mac."))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.scaledSystem(size: 12.5, weight: .medium))
            .foregroundStyle(Brand.teal)
            .padding(.top, 2)
            .accessibilityIdentifier("onboarding.trust")
        }
        .frame(maxWidth: .infinity)
    }

    private var meetingNotes: some View {
        OnboardingRow(symbol: "mic", alignment: .top) {
            Text("Meeting notes").font(.scaled(.body).weight(.semibold))
            description("Notes and action items from your Zoom, Teams, Meet and FaceTime calls.")
            if draft.recordsDetectedCalls {
                option("When a call starts") {
                    Picker(selection: $draft.meetingMode) {
                        ForEach(CaptureSetupDraft.detectedCallModes) { mode in
                            menuRow(mode.setupTitle, mode.setupDetail).tag(mode)
                        }
                    } label: {
                        Text("When a call starts")
                    } currentValueLabel: {
                        Text(LocalizedStringKey(draft.meetingMode.setupTitle))
                    }
                    .accessibilityIdentifier("onboarding.meetingMode")
                }
            } else {
                description("Records only when you press Record.").padding(.top, 6)
            }
        } trailing: {
            Toggle("Meeting notes", isOn: $draft.recordsDetectedCalls)
                .labelsHidden()
                .accessibilityIdentifier("onboarding.meetingNotes")
        }
    }

    private var workday: some View {
        OnboardingRow(symbol: "macwindow", alignment: .top) {
            Text("Your workday").font(.scaled(.body).weight(.semibold))
            description("The apps you use and the text on screen, for search and a daily summary.")
            if draft.dayMemory {
                option("Keeps") {
                    Picker(selection: $draft.contextMode) {
                        ForEach(AppSettings.ScreenContextCaptureMode.allCases) { mode in
                            menuRow(mode.setupTitle, mode.setupDetail).tag(mode)
                        }
                    } label: {
                        Text("Keeps")
                    } currentValueLabel: {
                        Text(LocalizedStringKey(draft.contextMode.setupTitle))
                    }
                    .accessibilityIdentifier("onboarding.contextMode")
                }
            }
        } trailing: {
            Toggle("Your workday", isOn: $draft.dayMemory)
                .labelsHidden()
                .accessibilityIdentifier("onboarding.dayMemory")
        }
    }

    private var codingAgents: some View {
        OnboardingRow(symbol: "apple.terminal") {
            Text("Coding agent sessions").font(.scaled(.body).weight(.semibold))
            description("Read your Claude Code and Codex sessions so LokalBot remembers what your agents did. Files stay on this Mac.")
        } trailing: {
            Toggle("Coding agent sessions", isOn: $draft.codingAgentSessions)
                .labelsHidden()
                .accessibilityLabel("Read coding agent sessions")
                .accessibilityHint("Read your Claude Code and Codex sessions so LokalBot remembers what your agents did. Files stay on this Mac.")
                .accessibilityIdentifier("onboarding.codingAgentSessions")
        }
    }

    /// A menu item with its one-line explanation under the name.
    private func menuRow(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading) {
            Text(LocalizedStringKey(title))
            Text(LocalizedStringKey(detail))
        }
    }

    private func description(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.scaled(.callout))
            .workspaceSupportingForeground()
            .fixedSize(horizontal: false, vertical: true)
    }

    /// The one option a choice has, on its own line under the description.
    private func option(_ label: LocalizedStringKey, @ViewBuilder control: () -> some View) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.scaled(.callout)).workspaceSupportingForeground()
                .accessibilityHidden(true)
            control()
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
        }
        .padding(.top, 6)
    }
}

private extension AppSettings.AutoRecordMode {
    /// The option's name in setup's "When a call starts" menu.
    var setupTitle: String {
        switch self {
        case .automatic: "Record automatically"
        case .ask: "Ask me first"
        case .manual: "Never auto-record"
        }
    }

    var setupDetail: String {
        switch self {
        case .automatic: "Starts as soon as a call begins"
        case .ask: "A notification lets you start it"
        case .manual: "Records only when you press Record."
        }
    }
}

private extension AppSettings.ScreenContextCaptureMode {
    /// The option's name in setup's "Keeps" menu.
    var setupTitle: String {
        switch self {
        case .activityOnly: "App names only"
        case .accessibleText: "Text on screen"
        case .visualContext: "Text and screenshots"
        }
    }

    var setupDetail: String {
        switch self {
        case .activityOnly: "The app and the window title"
        case .accessibleText: "Readable text, no screenshots"
        case .visualContext: "Screenshots are encrypted on this Mac"
        }
    }
}
