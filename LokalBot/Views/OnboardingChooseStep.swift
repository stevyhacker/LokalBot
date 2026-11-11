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
                .accessibilityIdentifier("onboarding.choicesHeading")
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
                    // Shown for every workday choice, app names only included:
                    // it is what the person agrees to before picking more.
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
                .frame(width: 56, height: 56)
                .accessibilityLabel("LokalBot")
            Text("Welcome to LokalBot")
                .font(.scaled(.title).bold())
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("onboarding.title")
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
                option("When a call starts", meaning: draft.meetingMode.setupDetail, showsMeaning: false) {
                    Picker("When a call starts", selection: $draft.meetingMode) {
                        ForEach(CaptureSetupDraft.detectedCallModes) { mode in
                            Text(LocalizedStringKey(mode.setupTitle)).tag(mode)
                        }
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
                option("Keeps", meaning: draft.contextMode.setupDetail, showsMeaning: true) {
                    Picker("Keeps", selection: $draft.contextMode) {
                        ForEach(AppSettings.ScreenContextCaptureMode.allCases) { mode in
                            Text(LocalizedStringKey(mode.setupTitle)).tag(mode)
                        }
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

    private func description(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.scaled(.callout))
            .workspaceSupportingForeground()
            .fixedSize(horizontal: false, vertical: true)
    }

    /// The one option a choice has, on its own line under the description.
    /// What the chosen option means is the pop-up's help, and for the workday,
    /// where it says what is kept, a line of its own. The menu is a plain
    /// pop-up like the app's others: rows with a second line drew over the
    /// pop-up's arrows in right-to-left languages.
    private func option(_ label: LocalizedStringKey, meaning: String, showsMeaning: Bool,
                        @ViewBuilder control: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(label).font(.scaled(.callout)).workspaceSupportingForeground()
                    .accessibilityHidden(true)
                control()
                    .labelsHidden()
                    .controlSize(.small)
                    .fixedSize()
                    .help(Text(LocalizedStringKey(meaning)))
                    .accessibilityHint(showsMeaning ? Text(verbatim: "") : Text(LocalizedStringKey(meaning)))
            }
            if showsMeaning {
                Text(LocalizedStringKey(meaning))
                    .font(.scaled(.callout))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("onboarding.contextMode.meaning")
            }
        }
        .padding(.top, 6)
    }
}

private extension AppSettings.AutoRecordMode {
    /// The option's name in setup's "When a call starts" menu, and what it
    /// means, which is the menu's help while it is chosen.
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
