import SwiftUI

struct AgentApprovalDock: View {
    @ObservedObject var controller: AgentSessionController
    let request: AgentApprovalRequest
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Approval required: \(request.tool)", systemImage: "hand.raised.fill")
                .font(.callout.weight(.semibold))

            Text(approvalEffect(request.tool)).workspaceTextRole(.trust)
            if let path = request.path {
                Text(path).font(.caption.monospaced()).lineLimit(2).textSelection(.enabled)
            }
            if let command = request.command {
                Text(command).font(.caption.monospaced()).lineLimit(2).textSelection(.enabled)
            }
            DisclosureGroup("Review details", isExpanded: $expanded) {
                ScrollView { details }.frame(maxHeight: 180)
            }

            ViewThatFits(in: .horizontal) {
                HStack { approvalButtons }
                VStack(alignment: .trailing, spacing: 8) { approvalButtons }
            }
        }
        .padding(12)
        .background(.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.orange.opacity(0.4)))
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let path = request.path {
                approvalText(label: "File", value: path)
            }
            if let command = request.command {
                approvalCode(label: "Command", value: command)
            }
            if let content = request.content {
                approvalCode(label: "Content to write", value: content)
            }
            ForEach(Array(request.edits.enumerated()), id: \.offset) { index, edit in
                VStack(alignment: .leading, spacing: 6) {
                    if request.edits.count > 1 {
                        Text("Edit \(index + 1)").font(.caption.weight(.semibold))
                    }
                    approvalCode(label: "Remove", value: edit.oldText, tint: .red)
                    approvalCode(label: "Replace with", value: edit.newText, tint: .green)
                }
            }
            if let workspace = request.workspace {
                approvalText(label: "Working folder", value: workspace)
            }
            if !request.hasStructuredDetails, let summary = request.summary, !summary.isEmpty {
                approvalCode(label: "Request details", value: summary)
            }
            if request.isTruncated {
                Label("Preview shortened because the requested change is very large.",
                      systemImage: "ellipsis.circle")
                    .workspaceTextRole(.supporting)
            }
        }
    }

    @ViewBuilder private var approvalButtons: some View {
        Button("Deny") {
            Task {
                await controller.respondToApproval(
                    id: request.id, approved: false, scope: .once)
            }
        }
        .primaryActionButton()
        .keyboardShortcut(.cancelAction)
        .accessibilityIdentifier("agent.approve.deny")

        if controller.canAllowForSession(request) {
            Button("Allow \(request.tool) for Session") {
                Task {
                    await controller.respondToApproval(
                        id: request.id, approved: true, scope: .session)
                }
            }
            .help("Automatically allow future \(request.tool) requests until this session closes")
            .accessibilityIdentifier("agent.approve.session")
        }

        Button("Allow Once") {
            Task {
                await controller.respondToApproval(
                    id: request.id, approved: true, scope: .once)
            }
        }
        .disabled(!request.canApprove)
        .accessibilityIdentifier("agent.approve.once")
    }

    private func approvalEffect(_ tool: String) -> String {
        switch tool.lowercased() {
        case "read": "Read the file shown below and make its contents available to this session."
        case "write": "Create or replace the file shown below with the proposed content."
        case "edit": "Apply the replacements shown below to the target file."
        case "bash", "shell": "Run the command shown below in the working folder with this session's current access."
        default: "Allow the operation shown below with this session's current access."
        }
    }

    private func approvalText(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(value).font(.caption.monospaced()).textSelection(.enabled)
        }
    }

    private func approvalCode(label: String, value: String, tint: Color = .gray) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ScrollView([.horizontal, .vertical]) {
                Text(value.isEmpty ? "(empty)" : value)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(7)
            }
            .frame(minHeight: 34, maxHeight: 170)
            .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(tint.opacity(0.18)))
        }
    }

}

extension AgentApprovalMode {
    var title: String {
        switch self {
        case .askBeforeChanges: "Ask before changes"
        case .approveReads: "Auto-approve reads"
        case .approveReadsAndEdits: "Auto-approve reads & edits"
        case .fullAccess: "Full access"
        }
    }

    var systemImage: String {
        switch self {
        case .askBeforeChanges: "hand.raised"
        case .approveReads: "eye"
        case .approveReadsAndEdits: "pencil"
        case .fullAccess: "lock.open"
        }
    }

    var detail: String {
        switch self {
        case .askBeforeChanges:
            "Reads in the working folder run automatically. Outside reads, file changes, and shell commands ask first."
        case .approveReads:
            "All reads run automatically, including outside the working folder. File changes and shell commands ask first."
        case .approveReadsAndEdits:
            "Reads and ordinary file edits run automatically, including outside the working folder. File-tool changes to LokalBot’s private data and shell commands ask first."
        case .fullAccess:
            "Reads, ordinary file edits, and shell calls run automatically. File-tool changes to LokalBot’s private data still ask; shell commands remain unrestricted."
        }
    }

    var accessSummary: String {
        switch self {
        case .askBeforeChanges:
            "Outside reads, file changes, and shell commands require approval"
        case .approveReads:
            "All reads are automatic; file changes and shell commands require approval"
        case .approveReadsAndEdits:
            "Reads and ordinary edits are automatic; private app data changes and shell commands ask"
        case .fullAccess:
            "Reads, ordinary edits, and shell commands are automatic; private app data changes ask"
        }
    }

    var runtimeSummary: String {
        switch self {
        case .askBeforeChanges:
            "Outside reads, file changes, and shell commands ask first."
        case .approveReads:
            "All reads run automatically; file changes and shell commands ask first."
        case .approveReadsAndEdits:
            "Reads and ordinary edits run automatically; private app data changes and shell commands ask first."
        case .fullAccess:
            "Reads, ordinary edits, and shell calls run automatically. Private app data file-tool changes ask."
        }
    }

    var confirmationTitle: String {
        switch self {
        case .askBeforeChanges: "Use Ask before changes?"
        case .approveReads: "Auto-approve every read?"
        case .approveReadsAndEdits: "Auto-approve every read and edit?"
        case .fullAccess: "Give this agent full access?"
        }
    }

    var confirmationMessage: String {
        switch self {
        case .askBeforeChanges:
            "Outside reads, file changes, and shell commands will ask first."
        case .approveReads:
            "The agent can read any file this Mac account can access, including files outside the working folder, without showing each request. File changes and shell commands will still ask. This choice is remembered for future sessions."
        case .approveReadsAndEdits:
            "The agent can read, create, overwrite, and edit ordinary files anywhere this Mac account can access without showing each request. File-tool changes to LokalBot’s private data, runtime, and app bundle will still ask, as will shell commands. This choice is remembered for future sessions."
        case .fullAccess:
            "The agent can read and change ordinary files anywhere and run shell commands without asking. File-tool changes to LokalBot’s private data, runtime, and app bundle still ask. Shell commands may delete data, access secrets, change app files, or connect to the network. This choice is remembered for future sessions."
        }
    }

    var confirmationAction: String {
        switch self {
        case .askBeforeChanges: "Keep Asking"
        case .approveReads: "Auto-approve Reads"
        case .approveReadsAndEdits: "Auto-approve Reads & Edits"
        case .fullAccess: "Give Full Access"
        }
    }
}
