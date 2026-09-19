import SwiftUI

struct AgentView: View {
    @EnvironmentObject private var app: AppState
    @ObservedObject var sessions: AgentSessionTabs
    @ObservedObject var installer: AgentRuntimeInstaller

    var body: some View {
        Group {
            if installer.phase == .installed {
                NavigationSplitView {
                    AgentTaskSidebar(sessions: sessions)
                        .navigationSplitViewColumnWidth(min: 190, ideal: 230, max: 320)
                } detail: {
                    if let tab = sessions.selectedTab {
                        AgentSessionView(controller: tab.controller, sessions: sessions, taskID: tab.id)
                            .id(tab.id)
                    }
                }
                .task { await sessions.refreshHistory() }
            } else { installCard }
        }
        .navigationTitle("Agent")
        .alert("Agent tasks", isPresented: Binding(get: { sessions.error != nil }, set: { if !$0 { sessions.error = nil } })) {
            Button("OK") { sessions.error = nil }
        } message: { Text(sessions.error ?? "") }
    }
    // MARK: - Install card

    private var installCard: some View {
        VStack(spacing: 12) {
            Image(systemName: "wand.and.sparkles").font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("Agent Mode").font(.title2.bold())
            Text(installDescription)
                .multilineTextAlignment(.center)
                .workspaceTextRole(.trust)
                .frame(maxWidth: 420)
            switch installer.phase {
            case .checking:
                LoadingStateLabel("Verifying Agent runtime…", font: .caption)
            case .idle:
                Button("Download & Enable Agent Mode") {
                    Task { await installer.installIfNeeded() }
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("agent.install")
            case .downloading(let name, let progress):
                ProgressView(value: progress >= 0 ? progress : nil)
                    .frame(maxWidth: 320)
                Text("Downloading \(name)…").font(.caption).foregroundStyle(.secondary)
            case .installing(let name):
                LoadingStateLabel("Installing \(name)…", font: .caption)
            case .failed(let message):
                Text(message).workspaceTextRole(.warning)
                    .frame(maxWidth: 420)
                Button("Repair Agent Mode") { Task { await installer.repair() } }
                    .accessibilityIdentifier("agent.installRetry")
            case .installed:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var installDescription: String {
        let inference = InferencePresentation(settings: app.settings).detail(
            local: "Model inference runs on this Mac.",
            remote: "Prompts and approved context are sent to your configured remote Main LLM.")
        return "A local coding and file agent powered by your selected Main LLM. Setup downloads about 50 MB and uses about 225 MB after installation. \(inference) Session history stays local; commands you approve run with your Mac user permissions and may access files or the network."
    }
}
