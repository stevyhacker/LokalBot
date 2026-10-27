import SwiftUI

/// The agent setup window: an agent ran `lokalbot-cli setup start` and asks
/// to set LokalBot up for the person. Allow turns on settings access and any
/// read access the person ticks; Don't Allow leaves everything off.
struct AgentSetupView: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        AgentSetupCard(requests: app.agentSetup)
    }
}

private struct AgentSetupCard: View {
    @EnvironmentObject private var app: AppState
    @ObservedObject var requests: AgentSetupRequests
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var meetingLibrary = false
    @State private var screenMemory = false

    var body: some View {
        Group {
            if let request = requests.pending {
                VStack(alignment: .leading, spacing: 16) {
                    Label("Set up LokalBot with your agent", systemImage: "terminal")
                        .font(.scaled(.title2).weight(.semibold))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: String(request.requester.prefix(80))).font(.scaled(.headline))
                        Text("asks to set up LokalBot for you from the terminal.")
                    }
                    Text("Allowing it lets the agent change your LokalBot settings, download models, and walk you through macOS permissions. Turning on capture, a data source, or sharing still asks you here. You can turn this off at any time in Settings → Privacy.")
                        .workspaceTextRole(.supporting)
                    if request.grants.contains(.meetingLibrary) {
                        Toggle(isOn: $meetingLibrary) {
                            SettingsLabel("Allow external agents to read your meeting library",
                                          help: "Lets MCP clients and the lokalbot-cli skill (Claude, Cursor, …) list, read, search, and ask about your meetings — read-only and localhost only. Off by default.")
                        }
                        .accessibilityIdentifier("agentSetup.meetingLibrary")
                    }
                    if request.grants.contains(.screenMemory) {
                        Toggle(isOn: $screenMemory) {
                            SettingsLabel("Allow external agents to read screen memory",
                                          help: "Separate, scoped, read-only access to captured text and metadata. Screenshot pixels are never returned.")
                        }
                        .accessibilityIdentifier("agentSetup.screenMemory")
                    }
                    Text("Allow only an agent you started yourself. Any program on this Mac can make this request.")
                        .workspaceTextRole(.trust)
                    HStack {
                        Spacer()
                        Button("Don't Allow") { decline() }
                            .accessibilityIdentifier("agentSetup.deny")
                        Button("Allow") {
                            requests.allow(meetingLibrary: meetingLibrary, screenMemory: screenMemory, in: app)
                        }
                        .primaryActionButton()
                        .accessibilityIdentifier("agentSetup.allow")
                    }
                }
                .toggleStyle(LBAccentSwitchStyle())
            } else {
                VStack(spacing: 16) {
                    Text("Nothing is waiting for your approval.")
                    Button("Close") { dismissWindow(id: "agent-setup") }
                        .keyboardShortcut(.defaultAction)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(24)
        .frame(width: 540)
        .onAppear { requests.check() }
        .onChange(of: requests.pending?.nonce) { _, nonce in
            meetingLibrary = false
            screenMemory = false
            if nonce == nil { dismissWindow(id: "agent-setup") }
        }
    }

    /// A new install still needs its setup, so declining leads to onboarding.
    private func decline() {
        requests.deny()
        if !UserDefaults.standard.bool(forKey: AppState.onboardingShownKey) {
            WindowAccess.shared.open("onboarding")
        }
    }
}
