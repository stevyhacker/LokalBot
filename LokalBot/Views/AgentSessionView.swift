import SwiftUI
import AppKit

/// One task: a new task's heading and composer mid-page, or the conversation
/// with the composer docked under it. The task's title and status sit in the
/// toolbar; an approval request docks above the composer.
struct AgentSessionView: View {
    @EnvironmentObject private var app: AppState
    @ObservedObject var controller: AgentSessionController
    @ObservedObject var sessions: AgentSessionTabs
    let taskID: UUID
    @State private var followingOutput = true
    /// The end of the conversation is in view, so there is nothing to jump to.
    @State private var endInView = true
    @State private var showingResults = false
    @State private var preview: AgentResultPreview?
    @State private var findVisible = false
    @State private var findQuery = ""
    @State private var matchIndex = 0
    @State private var expandedSteps: Set<String> = []
    @FocusState private var findFocused: Bool

    private var language: AppLanguage { app.settings.appLanguage }
    private var localized: (String) -> String { language.catalog }
    private var title: String {
        let tab = sessions.selectedTab
        return tab?.record.title ?? controller.sessionTitle ?? tab?.saved?.title ?? localized("New task")
    }
    /// A saved conversation with messages, loaded here or not yet.
    private var hasSavedConversation: Bool { sessions.selectedTab?.saved != nil }
    private var status: AgentTaskStatus { controller.status(hasSavedConversation: hasSavedConversation) }
    private var isWorking: Bool { controller.state == .running }
    private var blocks: [AgentTranscriptBlock] { AgentTranscriptLayout.make(controller.items, isWorking: isWorking) }

    /// Nothing has been said yet, so the composer sits mid-page.
    private var isNewTask: Bool {
        guard controller.items.isEmpty, !hasSavedConversation else { return false }
        if case .failed = controller.state { return false }
        return controller.state != .running
    }

    private var stepContext: AgentStepWording.Context {
        .init(workspace: controller.workspace, workspaceName: controller.workspaceDisplayName) { id in
            guard id.count >= 6 else { return nil }
            return app.meetings.first { $0.id.uuidString.lowercased().hasPrefix(id.lowercased()) }?.displayTitle
        }
    }

    var body: some View {
        // Resolve the reading width from the pane, rather than allowing a
        // long response or an action row to contribute its ideal width to
        // the native window's minimum size.
        GeometryReader { geometry in
            Group {
                if isNewTask {
                    newTask(width: geometry.size.width, height: geometry.size.height)
                } else {
                    conversation(width: geometry.size.width, height: geometry.size.height)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        // The task's own title replaces the section name in the toolbar.
        .toolbar(removing: .title)
        .toolbar {
            ToolbarItem(placement: .navigation) { titleAndStatus }
            // Without the system title nothing pushes the actions to the
            // trailing edge, so they sat against the task's title.
            ToolbarItem(placement: .primaryAction) { Spacer() }
            ToolbarItemGroup(placement: .primaryAction) { taskActions }
        }
        .inspector(isPresented: $showingResults) {
            AgentResultsPanel(controller: controller, context: stepContext, selection: $preview) { showingResults = false }
                .inspectorColumnWidth(min: 270, ideal: 350, max: 500)
        }
        .onChange(of: sessions.findRequest) { findVisible = true; findFocused = true }
        .onChange(of: sessions.resultsRequest) { showingResults.toggle() }
        .environment(\.openURL, OpenURLAction { url in
            if let source = controller.sourceAttachments.first(where: { $0.id == url.absoluteString }) {
                do { show(try controller.contextResolver.resolve(source)) } catch { controller.composerError = error.localizedDescription }
                return .handled
            }
            if url.isFileURL, let result = results.first(where: {
                guard let path = $0.filePath else { return false }
                return URL(fileURLWithPath: path, relativeTo: controller.workspace).standardizedFileURL == url.standardizedFileURL
            }) {
                show(result); return .handled
            }
            return ["https", "http"].contains(url.scheme ?? "") ? .systemAction : .discarded
        })
    }

    private func readingWidth(_ width: CGFloat) -> CGFloat {
        max(0, min(WorkspaceMetric.readingMaxWidth, width - 40))
    }

    // MARK: - Toolbar

    private var titleAndStatus: some View {
        HStack(spacing: 10) {
            Text(verbatim: title)
                .font(LBTokens.Typography.columnTitle).lineLimit(1).truncationMode(.tail)
                .help(title)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("agent.taskTitle")
            AgentStatusPill(status: status, text: toolbarStatus)
        }
        .frame(maxWidth: 420, alignment: .leading)
    }

    /// A new task needs no word beside its title; the list row says "Not started".
    private var toolbarStatus: String? {
        status == .notStarted ? nil : status.title(localize: localized)
    }

    @ViewBuilder private var taskActions: some View {
        Button { sessions.findRequest += 1 } label: { Image(systemName: "magnifyingglass").frame(width: 28, height: 28) }
            .help("Find in task (⌘F)").accessibilityLabel("Find in task")
            .disabled(controller.items.isEmpty)
            .accessibilityIdentifier("agent.find")
        Button { showingResults.toggle() } label: { Label("Results", systemImage: "sidebar.right") }
            .labelStyle(.iconOnly)
            .help("Results and sources (⌘⌥B)").accessibilityIdentifier("agent.results")
    }

    // MARK: - New task

    private func newTask(width: CGFloat, height: CGFloat) -> some View {
        let column = min(640, max(0, width - 40))
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("What would you like to work on?")
                    .font(.scaled(.title2).weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Text(verbatim: controller.approvalMode.capability(localize: localized))
                    .font(.scaled(.callout))
                    .foregroundStyle(controller.approvalMode.needsCaution ? LBTokens.Palette.attentionText : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
                    .accessibilityIdentifier("agent.capability")
                AgentComposer(controller: controller, sessions: sessions, taskID: taskID, isNewTask: true, showPreview: show)
                    .padding(.top, 18)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) { starters }
                    VStack(alignment: .leading, spacing: 10) { starters }
                }
                .padding(.top, 22)
            }
            .frame(width: column, alignment: .leading)
            .padding(.vertical, 24)
            // A little above the middle, where the eye lands first.
            .frame(maxWidth: .infinity, minHeight: max(0, height - 60), alignment: .center)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    @ViewBuilder private var starters: some View {
        starter("Draft follow-up", id: "followUp", icon: "arrowshape.turn.up.right",
                prompt: "Draft a follow-up from my most recent meeting. Do not send it.")
        starter("Prepare stand-up", id: "standUp", icon: "person.3",
                prompt: "Prepare a concise stand-up update from my recent meetings and open actions.")
        starter("Export actions", id: "exportActions", icon: "square.and.arrow.up",
                prompt: "Prepare a local Markdown export of my open meeting actions. Show me the plan before writing files.")
    }
    private func starter(_ title: LocalizedStringKey, id: String, icon: String, prompt: String) -> some View {
        Button { controller.draft = prompt; sessions.composerFocusRequest += 1 } label: {
            Label(title, systemImage: icon).padding(.vertical, 6).padding(.horizontal, 6)
        }.buttonStyle(.bordered).accessibilityIdentifier("agent.starter.\(id)")
    }

    // MARK: - Conversation

    private func conversation(width: CGFloat, height: CGFloat) -> some View {
        VStack(spacing: 0) {
            if findVisible { findBar.padding(.top, 10) }
            transcript
            if let request = controller.pendingApprovals.first {
                // Keep the opened preview scrollable without consuming the
                // conversation above it in a compact window.
                AgentApprovalDock(controller: controller, request: request,
                                  waiting: controller.pendingApprovals.count,
                                  previewMaxHeight: min(260, max(60, height - 520)))
                    .id(request.id)
                    .frame(width: readingWidth(width))
                    .padding(.bottom, 8)
            }
            AgentComposer(controller: controller, sessions: sessions, taskID: taskID, showPreview: show)
                .frame(width: readingWidth(width))
                .padding(.top, 4)
                .padding(.bottom, 14)
        }
    }

    private var matches: [String] {
        guard !findQuery.isEmpty else { return [] }
        return blocks.filter { $0.searchableText.localizedCaseInsensitiveContains(findQuery) }.map(\.id)
    }

    private var findBar: some View {
        HStack {
            TextField("Find in this task", text: $findQuery).textFieldStyle(.roundedBorder)
                .focused($findFocused).onSubmit { nextMatch(1) }.accessibilityIdentifier("agent.findField")
            Text(matches.isEmpty ? "0 matches" : "\(matchIndex + 1) of \(matches.count)").font(.scaled(.caption)).monospacedDigit()
            Button { nextMatch(-1) } label: { Image(systemName: "chevron.up") }.accessibilityLabel("Previous match")
            Button { nextMatch(1) } label: { Image(systemName: "chevron.down") }.accessibilityLabel("Next match")
            Button { findVisible = false; findQuery = "" } label: { Image(systemName: "xmark") }.accessibilityLabel("Close find")
        }.padding(.horizontal, 20).padding(.bottom, 8)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(blocks) { block in blockView(block).id(block.id) }
                    if case .failed(let message) = controller.state { recovery(message) }
                    if !controller.pendingApprovals.isEmpty {
                        Label("Waiting for your answer below", systemImage: "hand.raised.fill")
                            .font(AppFont.scaled(.callout).weight(.medium))
                            .foregroundStyle(LBTokens.Palette.attentionText)
                            .accessibilityIdentifier("agent.awaitingAnswer")
                    } else if status == .stopped {
                        Label("Stopped. Send a message to continue.", systemImage: "stop.circle")
                            .font(.scaled(.callout)).foregroundStyle(.secondary)
                            .accessibilityIdentifier("agent.stoppedNote")
                    }
                    Color.clear.frame(height: 1).id("agent.transcript.end")
                }
                .scrollTargetLayout()
                .frame(minWidth: 0, maxWidth: WorkspaceMetric.readingMaxWidth, alignment: .leading)
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .center)
                .padding(.horizontal, 20).padding(.vertical, 24)
            }
            .scrollPosition(id: $controller.visibleTranscriptID)
            .onScrollGeometryChange(for: Bool.self) {
                $0.contentSize.height - $0.visibleRect.maxY < 120
            } action: { _, nearEnd in followingOutput = nearEnd; endInView = nearEnd }
            .overlay(alignment: .bottomTrailing) {
                // Find stops following new output without scrolling a short
                // conversation, which left this button over text already in view.
                if !followingOutput && !endInView && !controller.items.isEmpty {
                    Button("Jump to latest", systemImage: "arrow.down") {
                        followingOutput = true; proxy.scrollTo("agent.transcript.end", anchor: .bottom)
                    }.buttonStyle(.bordered).padding(12)
                }
            }
            .onChange(of: controller.items) {
                if followingOutput && !findVisible { proxy.scrollTo("agent.transcript.end", anchor: .bottom) }
            }
            .onChange(of: findQuery) {
                matchIndex = 0
                // A match inside a folded run of steps opens that run.
                for case .steps(let group) in blocks where !findQuery.isEmpty
                    && group.entries.contains(where: { $0.searchableText.localizedCaseInsensitiveContains(findQuery) }) {
                    expandedSteps.insert(group.id)
                }
                if let first = matches.first { followingOutput = false; proxy.scrollTo(first, anchor: .top) }
            }
            .onChange(of: matchIndex) {
                if matches.indices.contains(matchIndex) { proxy.scrollTo(matches[matchIndex], anchor: .top) }
            }
        }.accessibilityIdentifier("agent.transcript")
    }

    @ViewBuilder private func blockView(_ block: AgentTranscriptBlock) -> some View {
        switch block {
        case .user(let item):
            userMessage(item)
        case .said(let item):
            said(item)
        case .answer(let item, let steps):
            answer(item, steps: steps)
        case .notice(let item):
            if case .notice(_, let text, let error) = item {
                Label(text, systemImage: error ? "exclamationmark.triangle" : "info.circle")
                    .font(.scaled(.callout))
                    .foregroundStyle(error ? LBTokens.Palette.attentionText : Color.secondary).textSelection(.enabled)
            }
        case .steps(let group):
            AgentStepsLine(group: group, context: stepContext, taskIsWorking: isWorking, textSize: sessions.textSize,
                           expanded: Binding(
                            get: { expandedSteps.contains(group.id) },
                            set: { if $0 { expandedSteps.insert(group.id) } else { expandedSteps.remove(group.id) } }),
                           showPreview: show)
        case .live(let item):
            AgentLiveStep(item: item, context: stepContext)
        }
    }

    @ViewBuilder private func userMessage(_ item: AgentTranscriptItem) -> some View {
        if case .user(_, let text) = item {
            Text(text).font(.system(size: sessions.textSize)).textSelection(.enabled)
                .padding(.horizontal, 14).padding(.vertical, 10).lbGroupedSurface()
                .contextMenu {
                    Button("Copy") { copy(text) }
                    Button("Edit as follow-up") { controller.editAsFollowUp(item); sessions.composerFocusRequest += 1 }
                    branchButton(item)
                }
                .accessibilityAction(named: "Copy") { copy(text) }
                .accessibilityAction(named: "Edit as follow-up") {
                    controller.editAsFollowUp(item); sessions.composerFocusRequest += 1
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.top, item.id == controller.items.first?.id ? 0 : 18)
        }
    }

    /// What the agent says while it works, in full and without actions.
    @ViewBuilder private func said(_ item: AgentTranscriptItem) -> some View {
        if case .assistant(_, let text, let streaming) = item {
            Group {
                if streaming {
                    Text(verbatim: text).font(.system(size: sessions.textSize)).lineSpacing(5).textSelection(.enabled)
                } else {
                    AgentResponseText(text: text, fontSize: sessions.textSize, searchQuery: findQuery)
                }
            }
            .accessibilityIdentifier("agent.assistant")
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The answer a finished turn ends with: the focal point, then the files
    /// that turn changed and quiet copy and retry controls.
    @ViewBuilder private func answer(_ item: AgentTranscriptItem, steps: [AgentTranscriptItem]) -> some View {
        if case .assistant(_, let text, _) = item {
            VStack(alignment: .leading, spacing: 14) {
                AgentResponseText(text: text, fontSize: sessions.textSize, searchQuery: findQuery)
                    .accessibilityIdentifier("agent.assistant")
                let files = controller.changedFiles(in: steps)
                if !files.isEmpty {
                    AgentChangedFilesCard(files: files) { file in
                        if let step = steps.first(where: { $0.id == file.stepID }),
                           let result = AgentResultPreview.tool(step) { show(result) }
                    }
                }
                HStack(spacing: 16) {
                    Button("Copy", systemImage: "doc.on.doc") { copy(text) }.labelStyle(.titleAndIcon)
                    Button("Retry", systemImage: "arrow.clockwise") {
                        controller.reviewResponseRetry(item); sessions.composerFocusRequest += 1
                    }
                    .labelStyle(.titleAndIcon)
                    .accessibilityLabel("Retry response")
                    Menu {
                        Button("Open in results") {
                            show(.init(id: item.id, title: localized("Agent response"),
                                       detail: localized("Conversation result"), text: text))
                        }
                        branchButton(item)
                    } label: { Label("More", systemImage: "ellipsis") }
                        .labelStyle(.iconOnly)
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                        .foregroundStyle(.primary).accessibilityLabel("More response actions")
                        .accessibilityIdentifier("agent.responseMore")
                }.buttonStyle(AgentMessageActionStyle())
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
    }
    private func branchButton(_ item: AgentTranscriptItem) -> some View {
        Button("Branch from here") { Task { await sessions.fork(taskID, through: item) } }
            .disabled(controller.state == .running || controller.state == .starting || controller.isSending
                      || (controller.activeSessionFile == nil && sessions.selectedTab?.record.sessionFile == nil))
            .help("Create an independent task through this message. Existing files and actions are unchanged.")
    }
    private func recovery(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Task needs attention", systemImage: "exclamationmark.triangle").font(.scaled(.headline))
            Text(message).font(.scaled(.callout)).textSelection(.enabled)
            HStack {
                if controller.recoveryAction == .openModels {
                    Button("Open Models") { app.openSettings(tab: .models) }.accessibilityIdentifier("agent.openModels")
                }
                Button("Reconnect") { Task { _ = await sessions.start(taskID) } }.accessibilityIdentifier("agent.restart")
                if controller.failedPrompt != nil { Button("Review & retry") { controller.reviewRetry(); sessions.composerFocusRequest += 1 } }
            }
        }.padding(14).lbStatusSurface(LBTokens.Palette.attention)
    }
    private var results: [AgentResultPreview] { controller.items.compactMap(AgentResultPreview.tool) }
    private func show(_ value: AgentResultPreview) { preview = value; showingResults = true }
    private func nextMatch(_ offset: Int) {
        guard !matches.isEmpty else { return }
        matchIndex = (matchIndex + offset + matches.count) % matches.count
    }
}

/// The task's status beside its title: amber when it needs an answer, teal
/// with a spinner while it works, a quiet word otherwise.
struct AgentStatusPill: View {
    @Environment(\.colorSchemeContrast) private var contrast
    let status: AgentTaskStatus
    let text: String?

    var body: some View {
        if let text {
            HStack(spacing: 5) {
                switch status.tone {
                case .working: ProgressView().controlSize(.mini)
                case .attention: Image(systemName: status.symbol).font(.scaled(.caption2))
                case .quiet, .done: EmptyView()
                }
                Text(verbatim: text).font(AppFont.scaled(.callout).weight(.medium)).lineLimit(1)
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, status.tone == .attention || status.tone == .done ? 8 : 0)
            .padding(.vertical, 3)
            .background(fill, in: Capsule())
            .fixedSize()
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("agent.taskStatus")
        }
    }

    private var foreground: Color {
        switch status.tone {
        case .attention: LBTokens.Palette.attentionText
        case .working: Brand.teal
        case .done: contrast == .increased ? Color.primary : Brand.teal
        case .quiet: contrast == .increased ? Color.primary : Color.secondary
        }
    }

    private var fill: Color {
        switch status.tone {
        case .attention: LBTokens.Palette.attention.opacity(0.16)
        case .done: Brand.teal.opacity(0.12)
        case .working, .quiet: .clear
        }
    }
}

/// The files one turn wrote or edited, under its answer.
struct AgentChangedFilesCard: View {
    @EnvironmentObject private var app: AppState
    let files: [AgentChangedFile]
    /// Shows what was written, beside the conversation.
    let preview: (AgentChangedFile) -> Void

    var body: some View {
        let localized = app.settings.appLanguage.catalog
        VStack(alignment: .leading, spacing: 10) {
            Text("Changed files").font(AppFont.scaled(.callout).weight(.semibold)).foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            ForEach(files) { file in
                let exists = FileManager.default.fileExists(atPath: file.target.url.path)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) { name(file, detail: file.detail(localize: localized)); Spacer(minLength: 8); actions(file, exists: exists) }
                    VStack(alignment: .leading, spacing: 8) {
                        name(file, detail: file.detail(localize: localized))
                        HStack(spacing: 8) { actions(file, exists: exists) }
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .lbGroupedSurface()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("agent.changedFiles")
    }

    private func name(_ file: AgentChangedFile, detail: String) -> some View {
        Button { preview(file) } label: {
            HStack(spacing: 10) {
                Image(systemName: "doc.text").font(.scaled(.title2)).foregroundStyle(Brand.teal).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: file.target.name).font(AppFont.scaled(.body).weight(.semibold)).lineLimit(1)
                        .truncationMode(.middle)
                    Text(verbatim: detail).font(.scaled(.callout))
                        .foregroundStyle(file.target.place == .outside ? LBTokens.Palette.attentionText : Color.secondary)
                        .lineLimit(2).truncationMode(.middle)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private func actions(_ file: AgentChangedFile, exists: Bool) -> some View {
        Button("Open") { NSWorkspace.shared.open(file.target.url) }
            .disabled(!exists)
            .accessibilityLabel(Text(verbatim: "\(app.settings.appLanguage.localized("Open")): \(file.target.name)"))
            .accessibilityIdentifier("agent.changedFiles.open")
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file.target.url]) }
            .disabled(!exists)
            .accessibilityIdentifier("agent.changedFiles.reveal")
    }
}

/// Message actions need label contrast, including in dark mode and Increase
/// Contrast, rather than the brand tint used for decorative accents.
private struct AgentMessageActionStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.scaled(.callout).weight(.medium))
            .foregroundStyle(enabled ? Color.primary : Color.secondary)
            .opacity(configuration.isPressed ? 0.65 : 1)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
    }
}
