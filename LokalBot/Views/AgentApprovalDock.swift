import SwiftUI

/// One approval request as a card above the composer: a question that names
/// its target, what will happen and where, the text to review, and the
/// answers the policy allows for this kind of request. Deny sits apart from
/// the answers that allow.
struct AgentApprovalDock: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.colorSchemeContrast) private var contrast
    @ObservedObject var controller: AgentSessionController
    let request: AgentApprovalRequest
    /// Requests waiting for an answer, this one included.
    var waiting = 1
    /// Room for the whole preview once it is opened.
    var previewMaxHeight: CGFloat = 220
    @State private var showingAll = false
    @State private var previewHeight: CGFloat = 0

    private var localized: (String) -> String { app.settings.appLanguage.catalog }

    private var presentation: AgentApprovalPresentation {
        let model = controller.modelContext ?? .init(settings: app.settings)
        var remoteHost: String?
        if case .remote(let host) = model.destination { remoteHost = host }
        // A command runs in the folder its request came from.
        let isCommand = ["bash", "shell"].contains(request.tool.lowercased())
        let folder = isCommand
            ? request.workspace.map { controller.workspaceDisplayName(for: URL(fileURLWithPath: $0)) }
            : nil
        return AgentApprovalPresentation(
            request: request, place: controller.approvalPlace(request),
            targetExists: controller.approvalTargetExists(request),
            workspaceName: folder ?? controller.workspaceDisplayName, remoteHost: remoteHost,
            canAllowForTask: controller.canAllowForSession(request), localize: localized)
    }

    var body: some View {
        let presentation = presentation
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: presentation.symbol)
                .font(.scaled(.body))
                .foregroundStyle(LBTokens.Palette.attentionText)
                .frame(width: 28, height: 28)
                .background(LBTokens.Palette.attention.opacity(0.18), in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    // A plain heading: a selectable one reached accessibility with no
                    // words on the hosted macOS runner, so the question went unread.
                    Text(verbatim: presentation.title)
                        .font(.scaled(.headline))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("agent.approval.title")
                    Spacer(minLength: 8)
                    if waiting > 1 {
                        Text("1 of \(waiting)")
                            .font(.scaled(.callout)).foregroundStyle(LBTokens.Palette.attentionText)
                            .accessibilityIdentifier("agent.approval.count")
                    }
                }
                Text(verbatim: presentation.effect)
                    .font(.scaled(.callout)).foregroundStyle(contrast == .increased ? Color.primary : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let caution = presentation.caution {
                    Label { Text(verbatim: caution).font(LBTokens.Typography.path).textSelection(.enabled) } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                    }
                    .foregroundStyle(LBTokens.Palette.attentionText)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("agent.approval.path")
                }
                if let destination = presentation.destination {
                    Label { Text(verbatim: destination) } icon: { Image(systemName: "network") }
                        .font(.scaled(.callout)).foregroundStyle(LBTokens.Palette.attentionText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !presentation.preview.isEmpty { preview(presentation) }
                if request.isTruncated {
                    Label("Preview shortened because the requested change is very large.",
                          systemImage: "ellipsis.circle")
                        .workspaceTextRole(.supporting)
                }
                if !request.canApprove {
                    Label("This request can’t be shown in full, so it can only be denied.",
                          systemImage: "exclamationmark.triangle")
                        .workspaceTextRole(.warning)
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { deny; Spacer(minLength: 12); allowing(presentation) }
                    VStack(alignment: .leading, spacing: 8) { HStack(spacing: 8) { allowing(presentation) }; deny }
                }
                .padding(.top, 2)
            }
        }
        .padding(14)
        .lbStatusSurface(LBTokens.Palette.attention)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("agent.approval")
        .onChange(of: request.id) { showingAll = false }
    }

    /// The first lines of what will be written or run; the rest on request.
    private func preview(_ presentation: AgentApprovalPresentation) -> some View {
        let lines = presentation.previewLines
        let isLong = lines.count > AgentApprovalPresentation.collapsedPreviewLines
        let shown = showingAll || !isLong
            ? presentation.preview
            : lines.prefix(AgentApprovalPresentation.collapsedPreviewLines).joined(separator: "\n")
        let text = Text(verbatim: shown)
            .font(LBTokens.Typography.path)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        return VStack(alignment: .leading, spacing: 6) {
            // The box is as tall as its text, up to a limit; beyond it the text scrolls in place.
            ScrollView(.vertical) {
                text.onGeometryChange(for: CGFloat.self) { $0.size.height } action: { previewHeight = $0 }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: min(max(previewHeight, 16), showingAll ? previewMaxHeight : 96))
            .accessibilityIdentifier("agent.approval.preview")
            if isLong {
                Button(showingAll ? localized("Show less") : AgentApprovalPresentation.showAll(lines.count, localize: localized)) {
                    showingAll.toggle()
                }
                .buttonStyle(.workspaceLink).font(.scaled(.callout))
                .accessibilityIdentifier("agent.approval.showAll")
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.75),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(LBTokens.Palette.groupStroke).allowsHitTesting(false).accessibilityHidden(true)
        }
    }

    private var deny: some View {
        Button("Deny") {
            Task { await controller.respondToApproval(id: request.id, approved: false, scope: .once) }
        }
        .buttonStyle(.bordered).controlSize(.large)
        .keyboardShortcut(.cancelAction)
        .accessibilityIdentifier("agent.approve.deny")
    }

    @ViewBuilder private func allowing(_ presentation: AgentApprovalPresentation) -> some View {
        if let taskAnswer = presentation.taskAnswer {
            Button {
                Task { await controller.respondToApproval(id: request.id, approved: true, scope: .session) }
            } label: { Text(verbatim: taskAnswer) }
            .buttonStyle(.bordered).controlSize(.large)
            .help("Further changes of this kind inside the working folder run without asking, until this task’s agent stops or the access level changes.")
            .accessibilityIdentifier("agent.approve.session")
        }
        Button("Allow once") {
            Task { await controller.respondToApproval(id: request.id, approved: true, scope: .once) }
        }
        .primaryActionButton().controlSize(.large)
        .disabled(!request.canApprove)
        .accessibilityIdentifier("agent.approve.once")
    }
}

/// The confirmation shown before the access level is raised.
extension AgentApprovalMode {
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
            "The agent can read and change ordinary files anywhere, run shell commands, and use any other agent tool without asking. File-tool changes to LokalBot’s private data, runtime, and app bundle still ask. Shell commands and other tools may delete data, access secrets, change app files, or connect to the network. This choice is remembered for future sessions."
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
