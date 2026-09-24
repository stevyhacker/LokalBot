import SwiftUI
import UniformTypeIdentifiers

struct AgentComposer: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.colorSchemeContrast) private var contrast
    @ObservedObject var controller: AgentSessionController
    @ObservedObject var sessions: AgentSessionTabs
    let taskID: UUID
    let showPreview: (AgentResultPreview) -> Void
    @State private var pickingFiles = false
    @State private var pickingFolder = false
    @State private var pickingContext = false
    @State private var showingAccess = false
    @State private var pendingMode: AgentApprovalMode?
    @State private var submitting = false
    @State private var queueExpanded = true
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !controller.queuedPrompts.isEmpty { queue }
            if let error = controller.composerError {
                HStack(alignment: .top) {
                    Text(error).font(.callout).foregroundStyle(.orange).textSelection(.enabled)
                    Spacer()
                    Button { controller.composerError = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless).accessibilityLabel("Dismiss message")
                }.accessibilityElement(children: .contain).accessibilityIdentifier("agent.composerError")
            }
            if sessions.selectedTab?.record.isArchived == true {
                Button("Restore task to continue") { Task { await sessions.setArchived(taskID, false) } }
                    .frame(maxWidth: .infinity).padding(12)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    attachmentChips
                    TextField(controller.state == .running ? "Add a follow-up or steer the agent…" : "Ask the agent…", text: $controller.draft, axis: .vertical)
                        .textFieldStyle(.plain).lineLimit(2...8).font(.system(size: sessions.textSize))
                        .focused($focused).onSubmit { submit(steer: false) }
                        .disabled(submitting || controller.state == .starting)
                        .accessibilityIdentifier("agent.composer")
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 10) { contextControls; Spacer(minLength: 4); sendControls }
                        VStack(alignment: .leading, spacing: 10) {
                            contextControls
                            HStack { Spacer(); sendControls }
                        }
                    }
                }
                .padding(14)
                .composerChrome(focused: focused)
                .dropDestination(for: URL.self) { urls, _ in
                    for url in urls where url.isFileURL { controller.addAttachment(.file(url)) }
                    return urls.contains(where: \.isFileURL)
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("agent.composerSurface")
            }
            HStack(spacing: 5) {
                Image(systemName: model.destination.icon)
                Text("\(model.name) · \(model.destination.label)")
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button { showingAccess.toggle() } label: { Image(systemName: "info.circle").frame(width: 24, height: 24) }
                    .buttonStyle(.borderless).accessibilityLabel("Task access details")
                    .popover(isPresented: $showingAccess) { accessDetails }
            }.font(WorkspaceTypography.metadata).foregroundStyle(contrast == .increased ? Color.primary : Color.secondary)
                .accessibilityElement(children: .contain).accessibilityIdentifier("agent.model")
        }
        .fileImporter(isPresented: $pickingFiles, allowedContentTypes: [.text, .sourceCode, .json, .pdf], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): urls.forEach { controller.addAttachment(.file($0)) }
            case .failure(let error): controller.composerError = error.localizedDescription
            }
        }
        .fileImporter(isPresented: $pickingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result {
                if controller.items.isEmpty && !controller.hasLiveRuntime {
                    controller.workspace = url
                } else {
                    sessions.addSession().controller.workspace = url
                }
                sessions.persist()
            }
        }
        .sheet(isPresented: $pickingContext) { AgentContextPicker(controller: controller) }
        .alert(item: $pendingMode) { mode in
            Alert(title: Text(mode.confirmationTitle), message: Text(mode.confirmationMessage),
                  primaryButton: .destructive(Text(mode.confirmationAction)) { Task { await controller.setApprovalMode(mode) } },
                  secondaryButton: .cancel(Text("Keep Current Mode")))
        }
        .onChange(of: sessions.composerFocusRequest) { focused = true }
        .onChange(of: controller.draft) {
            if controller.draft == "@" || controller.draft.hasSuffix(" @") || controller.draft.hasSuffix("\n@") {
                controller.draft.removeLast(); pickingContext = true
            }
        }
        .onAppear { focused = true }
    }

    private var model: AgentSessionController.ModelContext { controller.modelContext ?? .init(settings: app.settings) }
    private var hasPrompt: Bool { !controller.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private var contextControls: some View {
        HStack(spacing: 10) {
            Menu {
                Button("Files…") { pickingFiles = true }
                Button("Meetings and saved moments…") { pickingContext = true }
            } label: { Image(systemName: "plus").frame(width: 26, height: 26) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel("Attach context").accessibilityIdentifier("agent.attach")
            Button { pickingFolder = true } label: {
                Label(controller.workspaceDisplayName, systemImage: "folder").lineLimit(1)
            }.buttonStyle(.borderless).help("Working folder. Changing it in an existing conversation starts a new task.")
                .accessibilityIdentifier("agent.workspace")
            Menu {
                ForEach(AgentApprovalMode.allCases) { mode in
                    Button {
                        if mode.rawValue > controller.approvalMode.rawValue { pendingMode = mode } else { Task { await controller.setApprovalMode(mode) } }
                    } label: {
                        Label(mode.title, systemImage: mode == controller.approvalMode ? "checkmark" : mode.systemImage)
                    }
                }
            } label: { Label(controller.approvalMode.title, systemImage: controller.approvalMode.systemImage).lineLimit(1) }
                .menuStyle(.borderlessButton).fixedSize()
                .help(controller.approvalMode.detail).accessibilityLabel("Agent approval mode")
                .accessibilityValue(controller.approvalMode.title).accessibilityIdentifier("agent.approvalMode")
        }.font(WorkspaceTypography.metadataEmphasis).foregroundStyle(.primary)
    }

    @ViewBuilder private var sendControls: some View {
        HStack(spacing: 8) {
            if controller.state == .running {
                Button("Stop", systemImage: "stop.fill") { Task { await controller.abort() } }
                    .disabled(controller.isStopping).accessibilityIdentifier("agent.stop")
                Button("Send now") { submit(steer: true) }
                    .help("Steer the current task at its next opportunity")
                    .disabled(!hasPrompt || controller.isSending || controller.isStopping || submitting)
                    .accessibilityIdentifier("agent.steer")
            }
            Button(controller.state == .running ? "Queue follow-up" : "Send", systemImage: controller.state == .running ? "text.badge.plus" : "arrow.up") {
                submit(steer: false)
            }
            .primaryActionButton().controlSize(.large)
            .font(.system(size: 13, weight: .semibold))
            .disabled(!hasPrompt || submitting || controller.isStopping || controller.state == .starting)
            .accessibilityIdentifier("agent.send")
        }.font(.callout)
    }

    private var attachmentChips: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(controller.attachments) { attachment in
                    HStack(spacing: 4) {
                        Button {
                            do { showPreview(try controller.contextResolver.resolve(attachment)) } catch { controller.composerError = error.localizedDescription }
                        } label: { Label(attachment.title, systemImage: attachment.icon).lineLimit(1) }
                            .buttonStyle(.borderless).help("Preview attached source")
                        Button { controller.attachments.removeAll { $0.id == attachment.id } } label: { Image(systemName: "xmark").frame(width: 24, height: 24) }
                            .buttonStyle(.borderless).accessibilityLabel("Remove \(attachment.title)")
                    }.font(.caption).padding(.leading, 8).background(.quaternary, in: Capsule())
                }
            }
        }.scrollIndicators(.hidden).frame(height: controller.attachments.isEmpty ? 0 : 30)
            .accessibilityIdentifier("agent.attachments")
    }

    private var queue: some View {
        DisclosureGroup("\(controller.queuedPrompts.count) queued follow-ups\(controller.queueIsPaused ? " · paused" : "")", isExpanded: $queueExpanded) {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(controller.queuedPrompts) { prompt in
                        HStack {
                            Text(prompt.text).font(.callout).lineLimit(2)
                            Spacer()
                            Button("Edit") { controller.editQueued(prompt.id); focused = true }
                            Button("Cancel") { controller.cancelQueued(prompt.id) }
                        }.buttonStyle(.borderless).accessibilityElement(children: .contain)
                            .accessibilityIdentifier("agent.queue.\(prompt.id)")
                    }
                }.padding(.top, 6)
            }.frame(maxHeight: 120)
        }
        .font(.callout).accessibilityIdentifier("agent.queue")
        .overlay(alignment: .topTrailing) {
            if controller.state != .running && controller.state != .starting {
                Button("Send next") {
                    Task { if await sessions.start(taskID) { await controller.deliverNextQueued() } }
                }.buttonStyle(.borderless).font(.caption)
            }
        }
    }

    private var accessDetails: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("This task’s access").font(.headline)
            Label(controller.workspace.path, systemImage: "folder")
                .lineLimit(1)
                .truncationMode(.middle)
                .help(controller.workspace.path)
                .textSelection(.enabled)
            Group {
                Text(controller.approvalMode.detail)
                Text("Meeting Library: scoped local read access when this task runs. Saved screen moments require the separate screen-memory grant.")
                Text("\(model.destination.label). Attached text is included when you send. Files and tool actions follow the approval mode above.")
                if controller.modelContext != nil, controller.modelContext != .init(settings: app.settings) {
                    Text("New tasks use the model selected in Settings.")
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }.font(.callout).padding(18).frame(width: 360)
    }

    private func submit(steer: Bool) {
        guard hasPrompt, !submitting else { return }
        if controller.state == .running && !steer { controller.queueDraft(); return }
        let original = controller.draft
        let sources = controller.attachments
        submitting = true
        Task {
            defer { submitting = false }
            guard await sessions.start(taskID) else { return }
            // Never send a stale draft after a suspended model warm-up.
            guard controller.draft == original, controller.attachments == sources else { return }
            controller.draft = ""; controller.attachments = []
            let sent = await controller.send(prompt: original.trimmingCharacters(in: .whitespacesAndNewlines), attachments: sources, steer: steer)
            if sent { app.navigationHandoff.consumeAgentContext() } else if controller.draft.isEmpty && controller.attachments.isEmpty {
                controller.draft = original; controller.attachments = sources
            }
            sessions.persist()
        }
    }
}
