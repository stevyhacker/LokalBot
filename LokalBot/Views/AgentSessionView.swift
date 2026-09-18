import SwiftUI
import UniformTypeIdentifiers

/// One live Agent Mode tab. Every tab stays mounted while hidden so its
/// transcript, draft, approvals, and independent pi process remain intact.
struct AgentSessionView: View {
    @EnvironmentObject private var app: AppState
    @ObservedObject var controller: AgentSessionController
    let isSelected: Bool
    let showSessionHistory: () -> Void

    @State private var pickingFolder = false
    @State private var launchContext: AgentLaunchContext?
    @State private var followingOutput = true
    @State private var pendingApprovalMode: AgentApprovalMode?
    @FocusState private var composerFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            transcript
            Divider()
            // Keep the draft and its authority context visible while the
            // introduction, history, or a long response scrolls independently.
            composer
        }
        .task {
            if isSelected { launchContext = app.navigationHandoff.agentContext }
            focusComposerWhenReady()
        }
        .onChange(of: isSelected) {
            if isSelected, let context = app.navigationHandoff.agentContext { launchContext = context }
            focusComposerWhenReady()
        }
        .onChange(of: app.navigationHandoff.revision) {
            if isSelected, let context = app.navigationHandoff.agentContext { launchContext = context }
        }
        .onChange(of: controller.state) {
            focusComposerWhenReady()
        }
        .alert(item: $pendingApprovalMode) { mode in
            Alert(
                title: Text(mode.confirmationTitle),
                message: Text(mode.confirmationMessage),
                primaryButton: .destructive(Text(mode.confirmationAction)) {
                    Task { await controller.setApprovalMode(mode) }
                },
                secondaryButton: .cancel(Text("Keep Current Mode")))
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button {
                pickingFolder = true
            } label: {
                Label(controller.workspaceDisplayName, systemImage: "folder")
            }
            .help(controller.workspace.path)
            .fileImporter(isPresented: $pickingFolder,
                          allowedContentTypes: [.folder]) { result in
                if case .success(let url) = result {
                    let wasStarted = controller.state != .idle
                    controller.workspace = url
                    if wasStarted {
                        Task {
                            await controller.shutdown()
                            await controller.start()
                        }
                    }
                }
            }
            .accessibilityIdentifier("agent.workspace")

            statusBadge
            Spacer()
            approvalModeMenu
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder private var statusBadge: some View {
        switch controller.state {
        case .idle:
            Label("Ready to start", systemImage: "circle")
                .font(WorkspaceTypography.metadata).foregroundStyle(.secondary)
        case .starting:
            LoadingStateLabel("Starting…", controlSize: .mini)
        case .ready:
            Label("Ready", systemImage: "circle.fill")
                .font(WorkspaceTypography.metadata).foregroundStyle(.green)
        case .running:
            LoadingStateLabel("Working…", controlSize: .mini)
        case .failed(let message):
            Label("Needs attention", systemImage: "exclamationmark.triangle.fill")
                .font(WorkspaceTypography.metadata).foregroundStyle(Brand.error)
                .help(message)
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    transcriptLead
                    ForEach(controller.items) { item in
                        row(for: item).id(item.id)
                    }
                }
                .padding(WorkspaceMetric.pagePadding)
                .frame(maxWidth: .infinity, minHeight: 320, alignment: .topLeading)
            }
            .onScrollGeometryChange(for: Bool.self) {
                $0.contentSize.height - $0.visibleRect.maxY < 96
            } action: { _, nearEnd in followingOutput = nearEnd }
            .overlay(alignment: .bottomTrailing) {
                if !followingOutput {
                    Button("Jump to latest") {
                        followingOutput = true
                        if let last = controller.items.last { proxy.scrollTo(last.id, anchor: .bottom) }
                    }.buttonStyle(.bordered).padding(12)
                }
            }
            .onChange(of: controller.items.count) {
                if followingOutput, let last = controller.items.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("agent.transcript")
    }

    @ViewBuilder private var transcriptLead: some View {
        switch controller.state {
        case .failed(let message):
            recoveryCard(message: message)
                .frame(maxWidth: .infinity)
                .padding(.vertical, controller.items.isEmpty ? 52 : 4)
        case .idle where controller.items.isEmpty,
             .starting where controller.items.isEmpty,
             .ready where controller.items.isEmpty:
            emptyState
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
        default:
            EmptyView()
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "sparkles")
                .font(.system(size: 30))
                .foregroundStyle(Brand.teal)
            VStack(alignment: .leading, spacing: 5) {
                Text("Run an ongoing task")
                    .font(WorkspaceTypography.pageTitle)
                Text(emptyStateDetail)
                    .workspaceTextRole(.trust)
            }
            if let context = app.navigationHandoff.agentContext {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Selected outcome").font(WorkspaceTypography.metadataEmphasis)
                        .foregroundStyle(.secondary)
                    Text(context.title).font(WorkspaceTypography.rowTitle)
                    Text("The prompt is prefilled below. Review it before sending.")
                        .workspaceTextRole(.supporting)
                }
                .workspacePanel()
            }
            HStack(spacing: 10) {
                Button(action: showSessionHistory) {
                    Label("Browse Session History", systemImage: "clock.arrow.circlepath")
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("agent.browseSessionHistory")

                if controller.canResumePreviousSession {
                    Button {
                        Task {
                            if controller.state == .idle { await controller.start() }
                            await controller.resumePreviousSession()
                        }
                    } label: {
                        Label("Resume Most Recent Session", systemImage: "clock.arrow.circlepath")
                    }
                    .buttonStyle(.bordered)
                    .disabled(controller.state == .starting)
                    .accessibilityIdentifier("agent.resumePrevious")
                }
            }
            HStack(spacing: 10) {
                starterCard(
                    "Draft follow-up",
                    id: "agent.starter.followUp",
                    icon: "arrowshape.turn.up.right",
                    prompt: "Draft a follow-up from my most recent meeting. Do not send it.")
                starterCard(
                    "Prepare stand-up update",
                    id: "agent.starter.standUp",
                    icon: "person.3.sequence",
                    prompt: "Prepare a concise stand-up update from my recent meetings and open actions.")
                starterCard(
                    "Export my actions",
                    id: "agent.starter.exportActions",
                    icon: "square.and.arrow.up",
                    prompt: "Prepare a local Markdown export of my open meeting actions. Show me the plan before writing files.")
            }
            DisclosureGroup("What it can access") {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Working folder: \(controller.workspaceDisplayName)", systemImage: "folder")
                    Label("Meeting Library: scoped local read access", systemImage: "lock.open")
                    Label(controller.approvalMode.accessSummary,
                          systemImage: controller.approvalMode.systemImage)
                }
                .workspaceTextRole(.trust)
                .padding(.top, 8)
            }
            .font(WorkspaceTypography.body)
            DisclosureGroup("Approval mode") {
                VStack(alignment: .leading, spacing: 10) {
                    Label(controller.approvalMode.title,
                          systemImage: controller.approvalMode.systemImage)
                    Text(controller.approvalMode.detail)
                    Text("Change this beside the composer. It resets when the session closes.")
                }
                .workspaceTextRole(.trust)
                .padding(.top, 8)
            }
            .font(WorkspaceTypography.body)
        }
        .workspaceReadingWidth()
    }

    private func starterCard(_ title: String, id: String, icon: String,
                             prompt: String) -> some View {
        Button {
            controller.draft = prompt
            composerFocused = true
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                Image(systemName: icon).foregroundStyle(Brand.teal)
                Text(title).font(WorkspaceTypography.rowTitle)
                Text("Prefill prompt").font(WorkspaceTypography.metadata).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(.quaternary.opacity(0.25),
                        in: RoundedRectangle(cornerRadius: Brand.Radius.control))
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier(id)
    }

    private var emptyStateDetail: String {
        let readiness = controller.state == .idle ? "The session starts after you press Send."
            : (controller.state == .starting ? "The session is starting." : "The session is ready.")
        return "Work in the selected folder across a continuing session. \(controller.approvalMode.runtimeSummary) "
            + "\(sessionModel.destination.label). \(readiness)"
    }

    private var configuredModel: AgentSessionController.ModelContext { .init(settings: app.settings) }
    private var sessionModel: AgentSessionController.ModelContext { controller.modelContext ?? configuredModel }

    private var approvalModeMenu: some View {
        Menu {
            ForEach(AgentApprovalMode.allCases) { mode in
                Button {
                    selectApprovalMode(mode)
                } label: {
                    Label(mode.title,
                          systemImage: controller.approvalMode == mode ? "checkmark" : mode.systemImage)
                }
            }
        } label: {
            Label(controller.approvalMode.title,
                  systemImage: controller.approvalMode.systemImage)
                .workspaceTextRole(.trust)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(controller.approvalMode.detail)
        .accessibilityLabel("Agent approval mode")
        .accessibilityValue(controller.approvalMode.title)
        .accessibilityIdentifier("agent.approvalMode")
    }

    private func selectApprovalMode(_ mode: AgentApprovalMode) {
        guard mode != controller.approvalMode else { return }
        if mode.rawValue > controller.approvalMode.rawValue {
            pendingApprovalMode = mode
        } else {
            Task { await controller.setApprovalMode(mode) }
        }
    }

    private func recoveryCard(message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 28))
                .foregroundStyle(Brand.error)
            Text("Agent Mode needs attention")
                .font(.title3.weight(.semibold))
            Text(message)
                .workspaceTextRole(.trust)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
                .frame(maxWidth: 460)
            HStack {
                if controller.recoveryAction == .openModels {
                    Button("Open Models") {
                        app.openSettings(tab: .models)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("agent.openModels")
                }
                Button("Try Again") {
                    Task {
                        await controller.shutdown()
                        await controller.start()
                    }
                }
                .accessibilityIdentifier("agent.restart")
            }
        }
        .padding(16)
    }

    @ViewBuilder private func row(for item: AgentTranscriptItem) -> some View {
        switch item {
        case .user(_, let text):
            Text(text)
                .padding(10)
                .background(.blue.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
                .frame(maxWidth: .infinity, alignment: .trailing)
        case .assistant(_, let text, let isStreaming):
            VStack(alignment: .leading, spacing: 4) {
                if isStreaming {
                    // Keep partial deltas cheap to lay out, and treat model
                    // output as literal text until the turn is complete.
                    Text(verbatim: text)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("agent.assistant")
                } else {
                    SelectableDigestText(text, style: .agent)
                        .accessibilityIdentifier("agent.assistant")
                }
                if isStreaming {
                    ProgressView().controlSize(.mini)
                }
            }
            .padding(10)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
            .frame(maxWidth: .infinity, alignment: .leading)
        case .tool(_, let name, let argsJSON, let output, let status):
            toolCard(name: name, argsJSON: argsJSON, output: output, status: status)
        case .approval(let request):
            approvalCard(request)
        case .notice(_, let text, let isError):
            Label(text, systemImage: isError ? "exclamationmark.triangle" : "info.circle")
                .font(.caption)
                .foregroundStyle(isError ? .orange : .secondary)
        }
    }

    private func toolCard(name: String, argsJSON: String, output: String, status: AgentToolStatus) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 6) {
                if !argsJSON.isEmpty {
                    Text(argsJSON).font(.caption.monospaced()).textSelection(.enabled)
                        .lineLimit(12)
                }
                if !output.isEmpty {
                    Text(output).font(.caption.monospaced()).textSelection(.enabled)
                        .lineLimit(30)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            HStack(spacing: 6) {
                switch status {
                case .running: ProgressView().controlSize(.mini)
                case .succeeded: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                }
                Text(name).font(.callout.weight(.medium).monospaced())
            }
        }
        .padding(8)
        .background(.quaternary.opacity(0.3),
                    in: RoundedRectangle(cornerRadius: Brand.Radius.row))
    }

    private func approvalCard(_ request: AgentApprovalRequest) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Approval required: \(request.tool)", systemImage: "hand.raised.fill")
                .font(.callout.weight(.semibold))

            Text(approvalEffect(request.tool)).workspaceTextRole(.trust)
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

            HStack {
                Button("Deny") {
                    Task {
                        await controller.respondToApproval(
                            id: request.id, approved: false, scope: .once)
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("agent.approve.deny")

                Spacer()

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
                .accessibilityIdentifier("agent.approve.once")
            }
        }
        .padding(12)
        .background(.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.orange.opacity(0.4)))
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

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            VStack(alignment: .leading, spacing: 4) {
                Label("\(sessionModel.name) · \(sessionModel.destination.label)",
                      systemImage: sessionModel.destination.icon)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("agent.model")
                if controller.modelContext != nil, sessionModel != configuredModel {
                    Text("New sessions use the model selected in Settings.").foregroundStyle(.secondary)
                }
                if let context = launchContext {
                    Text("Context: \(context.title)").lineLimit(2)
                }
            }.font(WorkspaceTypography.metadata).padding(.horizontal, 12)
        HStack(spacing: 8) {
            TextField("Ask the agent…", text: $controller.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...5)
                .focused($composerFocused)
                .onSubmit(submit)
                .accessibilityIdentifier("agent.composer")
            if controller.state == .running {
                Button("Stop") { Task { await controller.abort() } }
                    .accessibilityIdentifier("agent.stop")
            }
            Button("Send", action: submit)
                .buttonStyle(.borderedProminent)
                .disabled(controller.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || controller.state == .starting)
                .accessibilityIdentifier("agent.send")
        }
        .padding(12)
        .workspaceControl()
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
        }
    }

    private func submit() {
        let text = controller.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        Task {
            if !canSend {
                await controller.start()
            }
            guard canSend else { return }
            controller.draft = ""
            app.navigationHandoff.consumeAgentContext()
            await controller.send(prompt: text)
        }
    }

    private var canSend: Bool {
        controller.state == .ready || controller.state == .running
    }

    private func focusComposerWhenReady() {
        guard isSelected, controller.state == .ready else { return }
        Task { @MainActor in
            await Task.yield()
            composerFocused = true
        }
    }
}

private extension AgentApprovalMode {
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
            "All reads, writes, and edits run automatically, including outside the working folder. Shell commands ask first."
        case .fullAccess:
            "All current read, write, edit, and shell calls run automatically, including outside the working folder."
        }
    }

    var accessSummary: String {
        switch self {
        case .askBeforeChanges:
            "Outside reads, file changes, and shell commands require approval"
        case .approveReads:
            "All reads are automatic; file changes and shell commands require approval"
        case .approveReadsAndEdits:
            "All reads and file changes are automatic; shell commands require approval"
        case .fullAccess:
            "Reads, file changes, and shell commands are automatic"
        }
    }

    var runtimeSummary: String {
        switch self {
        case .askBeforeChanges:
            "Outside reads, file changes, and shell commands ask first."
        case .approveReads:
            "All reads run automatically; file changes and shell commands ask first."
        case .approveReadsAndEdits:
            "All reads and file changes run automatically; shell commands ask first."
        case .fullAccess:
            "All current read, file-change, and shell calls run automatically."
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
            "The agent can read any file this Mac account can access, including files outside the working folder, without showing each request. File changes and shell commands will still ask. This resets when the session closes."
        case .approveReadsAndEdits:
            "The agent can read, create, overwrite, and edit files anywhere this Mac account can access without showing each request. Shell commands will still ask. This resets when the session closes."
        case .fullAccess:
            "The agent can read and change files anywhere and run shell commands without asking. Commands may delete data, access secrets, or connect to the network. This resets when the session closes."
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
