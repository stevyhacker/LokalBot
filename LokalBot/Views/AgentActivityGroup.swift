import SwiftUI

struct AgentActivityGroup: View {
    let group: AgentTranscriptGroup
    let searchQuery: String
    let showPreview: (AgentResultPreview) -> Void
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(group.items) { item in
                    if case .tool(_, let name, let args, let output, let status) = item {
                        HStack(alignment: .top, spacing: 8) {
                            statusIcon(status)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(summary(name, args: args)).font(.callout)
                                DisclosureGroup("Details") {
                                    ScrollView {
                                        Text(args + (output.isEmpty ? "" : "\n\n" + output))
                                            .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }.frame(maxHeight: 180)
                                }.font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            Button("Open") { if let result = AgentResultPreview.tool(item) { showPreview(result) } }
                                .buttonStyle(.borderless).font(.caption)
                                .accessibilityLabel("Open \(name) result")
                        }
                    }
                }
            }.padding(.top, 10)
        } label: {
            HStack(spacing: 8) {
                if running { ProgressView().controlSize(.mini) } else { Image(systemName: failed ? "exclamationmark.circle" : "checkmark.circle").foregroundStyle(failed ? Color.orange : Color.secondary) }
                Text(group.summary).font(WorkspaceTypography.metadataEmphasis)
                if running { Text("In progress").font(.caption).foregroundStyle(.secondary) }
            }
        }
        .padding(.vertical, 8).padding(.horizontal, 10)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
        .onChange(of: searchQuery) {
            if !searchQuery.isEmpty && group.items.contains(where: { $0.searchableText.localizedCaseInsensitiveContains(searchQuery) }) { expanded = true }
        }
        .accessibilityIdentifier("agent.activityGroup")
    }

    private var running: Bool { group.items.contains { if case .tool(_, _, _, _, .running) = $0 { true } else { false } } }
    private var failed: Bool { group.items.contains { if case .tool(_, _, _, _, .failed) = $0 { true } else { false } } }
    @ViewBuilder private func statusIcon(_ status: AgentToolStatus) -> some View {
        switch status {
        case .running: ProgressView().controlSize(.mini)
        case .succeeded: Image(systemName: "checkmark.circle").foregroundStyle(.secondary)
        case .failed: Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
        }
    }
    private func summary(_ name: String, args: String) -> String {
        let object = (try? JSONSerialization.jsonObject(with: Data(args.utf8))) as? [String: Any] ?? [:]
        if let path = object["path"] as? String {
            let verb = ["read": "Read", "write": "Write", "edit": "Edit"][name] ?? name
            return "\(verb) \(URL(fileURLWithPath: path).lastPathComponent)"
        }
        if let command = object["command"] as? String, command.contains("lokalbot-cli") {
            return command.contains("search") ? "Search meeting library" : "Read meeting evidence"
        }
        return name == "bash" ? "Run command" : name
    }
}
