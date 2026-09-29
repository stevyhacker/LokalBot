import SwiftUI

struct BriefContextView: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        DisclosureGroup("Context used for the morning brief") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Overnight review uses your recorded evidence and the projects and goals below. Pin an item to keep it in future reviews.")
                    .workspaceTextRole(.supporting)
                if let memory = app.dreamMemory, !memory.activeProjects.isEmpty || !memory.workGoals.isEmpty {
                    ForEach(memory.activeProjects, id: \.name) { project in
                        pin(project.name, detail: project.status, value: project.pinned, entry: .project(name: project.name))
                    }
                    ForEach(memory.workGoals, id: \.text) { goal in
                        pin(goal.text, detail: goal.horizon, value: goal.pinned, entry: .goal(text: goal.text))
                    }
                } else {
                    Text("No projects or goals have been identified yet.").foregroundStyle(.secondary)
                }
                Button("Configure overnight review") { app.openSettings(tab: .dayMemory) }
            }.padding(.top, 8)
        }.accessibilityIdentifier("today.briefContext")
    }

    private func pin(_ title: String, detail: String, value: Bool, entry: DreamMemoryEntry) -> some View {
        Toggle(isOn: Binding(get: { value }, set: { app.setDreamMemoryPinned($0, for: entry) })) {
            VStack(alignment: .leading) {
                Text(title)
                Text(detail).font(Font.scaled(.callout)).foregroundStyle(.secondary)
            }
        }.disabled(app.dreaming.isDreaming)
    }
}
