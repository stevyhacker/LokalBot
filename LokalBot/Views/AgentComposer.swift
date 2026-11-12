import SwiftUI
import UniformTypeIdentifiers

/// Where the agent is told what to do: the message, what to attach, the
/// working folder and how much it may do on its own. A message sent while the
/// agent works waits above the field until the turn ends.
struct AgentComposer: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.colorSchemeContrast) private var contrast
    @ObservedObject var controller: AgentSessionController
    @ObservedObject var sessions: AgentSessionTabs
    let taskID: UUID
    /// A new task has no conversation above the composer yet.
    var isNewTask = false
    let showPreview: (AgentResultPreview) -> Void
    @State private var pickingFiles = false
    @State private var pickingFolder = false
    @State private var pickingContext = false
    @State private var showingAccess = false
    @State private var pendingMode: AgentApprovalMode?
    @State private var submitting = false
    @FocusState private var focused: Bool

    private var localized: (String) -> String { app.settings.appLanguage.catalog }
    private var model: AgentSessionController.ModelContext { controller.modelContext ?? .init(settings: app.settings) }
    private var hasPrompt: Bool { !controller.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var isWorking: Bool { controller.state == .running }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !controller.queuedPrompts.isEmpty { queue }
            if let notice = controller.workspaceAccessNotice {
                Text(notice).font(.scaled(.callout)).foregroundStyle(LBTokens.Palette.attentionText).textSelection(.enabled)
                    .accessibilityIdentifier("agent.workspaceNotice")
            }
            if let error = controller.composerError {
                HStack(alignment: .top) {
                    Text(error).font(.scaled(.callout)).foregroundStyle(LBTokens.Palette.attentionText).textSelection(.enabled)
                    Spacer()
                    Button { controller.composerError = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless).accessibilityLabel("Dismiss message")
                }.accessibilityElement(children: .contain).accessibilityIdentifier("agent.composerError")
            }
            if sessions.selectedTab?.record.isArchived == true {
                Button("Restore task to continue") { Task { await sessions.setArchived(taskID, false) } }
                    .frame(maxWidth: .infinity).padding(12)
            } else {
                surface
            }
            destinationLine
        }
        .fileImporter(isPresented: $pickingFiles, allowedContentTypes: [.text, .sourceCode, .json, .pdf], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): urls.forEach { controller.addAttachment(.file($0)) }
            case .failure(let error): controller.composerError = error.localizedDescription
            }
        }
        .fileImporter(isPresented: $pickingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result {
                if let notice = controller.workspaceAccessNotice(for: url) {
                    controller.composerError = notice
                    return
                }
                if controller.items.isEmpty && !controller.hasLiveRuntime,
                   sessions.selectedTab?.record.sessionFile == nil {
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

    // MARK: - Field and controls

    private var placeholder: String {
        if isWorking { return localized("Add to this task") }
        return localized(isNewTask ? "Ask the agent…" : "Ask a follow-up")
    }

    private var surface: some View {
        VStack(alignment: .leading, spacing: 10) {
            attachmentChips
            TextField(placeholder, text: $controller.draft, axis: .vertical)
                .textFieldStyle(.plain).lineLimit(2...8).font(.system(size: sessions.textSize))
                .focused($focused).onSubmit { submit() }
                .disabled(submitting || controller.state == .starting)
                .accessibilityIdentifier("agent.composer")
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) { contextControls; Spacer(minLength: 4); sendControls }
                VStack(alignment: .leading, spacing: 8) {
                    contextControls
                    HStack { Spacer(); sendControls }
                }
            }
        }
        .padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 10)
        .composerChrome(focused: focused)
        .dropDestination(for: URL.self) { urls, _ in
            for url in urls where url.isFileURL { controller.addAttachment(.file(url)) }
            return urls.contains(where: \.isFileURL)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("agent.composerSurface")
    }

    /// Attach, the working folder, and the one access chip.
    private var contextControls: some View {
        HStack(spacing: 12) {
            Menu {
                Button("Files…") { pickingFiles = true }
                Button("Meetings and saved moments…") { pickingContext = true }
            } label: { Image(systemName: "plus").frame(width: 24, height: 24) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel("Attach context").accessibilityIdentifier("agent.attach")
            Button { pickingFolder = true } label: {
                Label { Text(verbatim: controller.workspaceDisplayName).lineLimit(1) } icon: { Image(systemName: "folder") }
            }.buttonStyle(.borderless)
                .help("The agent works in this folder. Choosing another folder after a task has started opens a new task.")
                .accessibilityLabel("Working folder").accessibilityValue(Text(verbatim: controller.workspaceDisplayName))
                .accessibilityIdentifier("agent.workspace")
            accessChip
        }.font(AppFont.scaled(.callout).weight(.medium)).foregroundStyle(.primary)
    }

    /// Names what the agent does on its own, and opens the levels.
    private var accessChip: some View {
        let mode = controller.approvalMode
        return Button { showingAccess.toggle() } label: {
            HStack(spacing: 5) {
                Image(systemName: mode.systemImage)
                Text(verbatim: localized(mode.chipTitle)).lineLimit(1)
                Image(systemName: "chevron.down").font(.scaled(.caption2).weight(.semibold)).accessibilityHidden(true)
            }
            .foregroundStyle(mode.needsCaution ? LBTokens.Palette.attentionText : Color.primary)
        }
        .buttonStyle(.borderless)
        .help(mode.levelDetail(workspaceName: controller.workspaceDisplayName, localize: localized))
        .accessibilityLabel("Access").accessibilityValue(Text(verbatim: localized(mode.chipTitle)))
        .accessibilityIdentifier("agent.approvalMode")
        .popover(isPresented: $showingAccess, arrowEdge: .bottom) {
            AgentAccessPopover(controller: controller, model: model) { mode in
                // Raising the level is confirmed; lowering it applies at once.
                if mode.rawValue > controller.approvalMode.rawValue {
                    showingAccess = false
                    pendingMode = mode
                } else {
                    Task { await controller.setApprovalMode(mode) }
                }
            }
        }
    }

    @ViewBuilder private var sendControls: some View {
        HStack(spacing: 8) {
            if isWorking {
                Button("Stop", systemImage: "stop.fill") { Task { await controller.abort() } }
                    .buttonStyle(.bordered).controlSize(.large)
                    .disabled(controller.isStopping).accessibilityIdentifier("agent.stop")
            }
            Button("Send", systemImage: "arrow.up") { submit() }
                .primaryActionButton().controlSize(.large)
                .font(.scaledSystem(size: 13, weight: .semibold))
                .disabled(!hasPrompt || submitting || controller.isStopping || controller.state == .starting)
                .accessibilityIdentifier("agent.send")
        }.font(.scaled(.callout))
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
                    }.font(.scaled(.caption)).padding(.leading, 8).background(.quaternary, in: Capsule())
                }
            }
        }.scrollIndicators(.hidden).frame(height: controller.attachments.isEmpty ? 0 : 30)
            .accessibilityIdentifier("agent.attachments")
    }

    /// Shown only when the model is not on this Mac, so where a task's
    /// prompts go stays in view without opening the access list.
    @ViewBuilder private var destinationLine: some View {
        if model.destination != .onDevice {
            HStack(spacing: 5) {
                Image(systemName: model.destination.icon)
                Text(verbatim: "\(model.name) · \(AgentAccessPopover.destinationLabel(model.destination, localize: localized))")
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            .font(AppFont.scaled(.callout))
            .foregroundStyle(contrast == .increased ? Color.primary : LBTokens.Palette.attentionText)
            .padding(.horizontal, 4)
            .accessibilityElement(children: .combine).accessibilityIdentifier("agent.model")
        }
    }

    // MARK: - Queued messages

    /// Up to three rows show whole; a longer queue scrolls in the same space.
    private var queue: some View {
        Group {
            if controller.queuedPrompts.count <= 3 { queueRows } else { ScrollView { queueRows }.frame(height: 118) }
        }
        .accessibilityElement(children: .contain).accessibilityIdentifier("agent.queue")
    }

    private var queueRows: some View {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(controller.queuedPrompts) { prompt in
                    HStack(spacing: 8) {
                        Image(systemName: "clock").foregroundStyle(.secondary).accessibilityHidden(true)
                        Text(isWorking ? "Sends when done" : "Not sent yet").foregroundStyle(.secondary)
                            .fixedSize()
                        Text(verbatim: prompt.text).lineLimit(1).truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button("Send now") { sendNow(prompt.id) }
                            .buttonStyle(.bordered).controlSize(.small)
                            .disabled(controller.isSending || controller.isStopping || controller.state == .starting)
                            .help(isWorking ? "Steer the current task at its next opportunity" : "Send now")
                            .accessibilityIdentifier("agent.steer")
                        Button { controller.cancelQueued(prompt.id) } label: {
                            Image(systemName: "xmark").frame(width: 22, height: 22)
                        }
                        .buttonStyle(.borderless).help("Remove queued message")
                        .accessibilityLabel("Remove queued message")
                        .accessibilityIdentifier("agent.queue.remove")
                    }
                    .font(.scaled(.callout))
                    .padding(.leading, 12).padding(.trailing, 8).padding(.vertical, 6)
                    .lbGroupedSurface()
                    .contextMenu {
                        Button("Edit") { controller.editQueued(prompt.id); focused = true }
                        Button("Remove") { controller.cancelQueued(prompt.id) }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("agent.queue.\(prompt.id)")
                }
            }
    }

    private func sendNow(_ id: UUID) {
        Task {
            guard await sessions.start(taskID) else { return }
            await controller.sendQueuedNow(id)
            sessions.persist()
        }
    }

    /// While the agent works, Send queues the message. Otherwise it starts
    /// the task if needed and sends.
    private func submit() {
        guard hasPrompt, !submitting else { return }
        if isWorking { controller.queueDraft(); return }
        let original = controller.draft
        let sources = controller.attachments
        submitting = true
        Task {
            defer { submitting = false }
            guard await sessions.start(taskID) else { return }
            // Never send a stale draft after a suspended model warm-up.
            guard controller.draft == original, controller.attachments == sources else { return }
            controller.draft = ""; controller.attachments = []
            let sent = await controller.send(prompt: original.trimmingCharacters(in: .whitespacesAndNewlines), attachments: sources)
            if sent { app.navigationHandoff.consumeAgentContext() } else if controller.draft.isEmpty && controller.attachments.isEmpty {
                controller.draft = original; controller.attachments = sources
            }
            sessions.persist()
        }
    }
}
