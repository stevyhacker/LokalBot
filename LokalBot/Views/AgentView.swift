import SwiftUI

struct AgentView: View {
    @EnvironmentObject private var app: AppState
    @ObservedObject var sessions: AgentSessionTabs
    @ObservedObject var installer: AgentRuntimeInstaller
    @SceneStorage("agent.tasks.width") private var taskColumnWidth = 230.0

    var body: some View {
        Group {
            if installer.phase == .installed {
                // The main window already owns navigation. A second nested
                // NavigationSplitView lets its inferred detail minimum grow
                // with the transcript and can prevent the window shrinking.
                HSplitView {
                    AgentTaskSidebar(sessions: sessions, verifyRuntime: verifyRuntime)
                        .frame(minWidth: 190, idealWidth: taskColumnWidth, maxWidth: 280)
                        .onGeometryChange(for: Double.self) { Double($0.size.width) } action: { taskColumnWidth = $0 }
                        .splitPaneAccessibilityLabel("Agent tasks")
                    if let tab = sessions.selectedTab {
                        AgentSessionView(controller: tab.controller, sessions: sessions, taskID: tab.id)
                            .id(tab.id)
                            .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
                            .splitPaneAccessibilityLabel("Agent conversation")
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

    private func verifyRuntime() {
        Task {
            guard !(await installer.verifyInstalledState()) else { return }
            sessions.persist()
            for tab in sessions.tabs {
                if !(await tab.controller.park()) { await tab.controller.shutdown() }
            }
        }
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
