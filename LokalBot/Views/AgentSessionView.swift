import SwiftUI
import AppKit

struct AgentSessionView: View {
    @EnvironmentObject private var app: AppState
    @ObservedObject var controller: AgentSessionController
    @ObservedObject var sessions: AgentSessionTabs
    let taskID: UUID
    @State private var followingOutput = true
    @State private var showingResults = false
    @State private var preview: AgentResultPreview?
    @State private var findVisible = false
    @State private var findQuery = ""
    @State private var matchIndex = 0
    @FocusState private var findFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            taskHeader
            if findVisible { findBar }
            transcript
            if let request = controller.pendingApprovals.first {
                VStack(alignment: .leading, spacing: 4) {
                    if controller.pendingApprovals.count > 1 {
                        Text("\(controller.pendingApprovals.count) approvals waiting").font(.caption)
                    }
                    AgentApprovalDock(controller: controller, request: request).id(request.id)
                }
                .frame(maxWidth: WorkspaceMetric.readingMaxWidth)
                .padding(.horizontal, 20).padding(.bottom, 8)
            }
            AgentComposer(controller: controller, sessions: sessions, taskID: taskID, showPreview: show)
                .frame(maxWidth: WorkspaceMetric.readingMaxWidth)
                .padding(.horizontal, 20).padding(.bottom, 14)
        }
        .inspector(isPresented: $showingResults) {
            AgentResultsPanel(controller: controller, selection: $preview)
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

    private var taskHeader: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(sessions.selectedTab?.title ?? "New task").font(.headline).lineLimit(1)
                Text(controller.taskStatus).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button { sessions.findRequest += 1 } label: { Image(systemName: "magnifyingglass").frame(width: 28, height: 28) }
                .help("Find in task (⌘F)").accessibilityLabel("Find in task")
                .accessibilityIdentifier("agent.find")
            Button { showingResults.toggle() } label: { Label("Results", systemImage: "sidebar.right") }
                .help("Results and sources (⌘⌥B)").accessibilityIdentifier("agent.results")
        }
        .buttonStyle(.borderless).padding(.horizontal, 20).padding(.vertical, 12)
    }

    private var matches: [String] {
        guard !findQuery.isEmpty else { return [] }
        return AgentTranscriptGroup.make(controller.items).filter {
            $0.items.contains { $0.searchableText.localizedCaseInsensitiveContains(findQuery) }
        }.map(\.id)
    }

    private var findBar: some View {
        HStack {
            TextField("Find in this task", text: $findQuery).textFieldStyle(.roundedBorder)
                .focused($findFocused).onSubmit { nextMatch(1) }.accessibilityIdentifier("agent.findField")
            Text(matches.isEmpty ? "0 matches" : "\(matchIndex + 1) of \(matches.count)").font(.caption).monospacedDigit()
            Button { nextMatch(-1) } label: { Image(systemName: "chevron.up") }.accessibilityLabel("Previous match")
            Button { nextMatch(1) } label: { Image(systemName: "chevron.down") }.accessibilityLabel("Next match")
            Button { findVisible = false; findQuery = "" } label: { Image(systemName: "xmark") }.accessibilityLabel("Close find")
        }.padding(.horizontal, 20).padding(.bottom, 8)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    if controller.items.isEmpty { emptyState }
                    if case .failed(let message) = controller.state { recovery(message) }
                    ForEach(AgentTranscriptGroup.make(controller.items)) { group in
                        if group.isActivity {
                            AgentActivityGroup(group: group, searchQuery: findQuery, showPreview: show)
                                .id(group.id)
                        } else if let item = group.items.first { messageRow(item).id(group.id) }
                    }
                    Color.clear.frame(height: 1).id("agent.transcript.end")
                }
                .scrollTargetLayout()
                .frame(maxWidth: WorkspaceMetric.readingMaxWidth, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.horizontal, 20).padding(.vertical, 24)
            }
            .scrollPosition(id: $controller.visibleTranscriptID)
            .onScrollGeometryChange(for: Bool.self) {
                $0.contentSize.height - $0.visibleRect.maxY < 120
            } action: { _, nearEnd in followingOutput = nearEnd }
            .overlay(alignment: .bottomTrailing) {
                if !followingOutput && !controller.items.isEmpty {
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
                if let first = matches.first { followingOutput = false; proxy.scrollTo(first, anchor: .top) }
            }
            .onChange(of: matchIndex) {
                if matches.indices.contains(matchIndex) { proxy.scrollTo(matches[matchIndex], anchor: .top) }
            }
        }.accessibilityIdentifier("agent.transcript")
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("What would you like to work on?").font(.title2.weight(.semibold))
            Text("Start with your work memory or a file. The agent starts when you send.")
                .foregroundStyle(.secondary)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { starters }
                VStack(alignment: .leading, spacing: 12) { starters }
            }
        }.padding(.vertical, 24)
    }
    @ViewBuilder private var starters: some View {
        starter("Draft follow-up", id: "followUp", icon: "arrowshape.turn.up.right",
                prompt: "Draft a follow-up from my most recent meeting. Do not send it.")
        starter("Prepare stand-up", id: "standUp", icon: "person.3",
                prompt: "Prepare a concise stand-up update from my recent meetings and open actions.")
        starter("Export actions", id: "exportActions", icon: "square.and.arrow.up",
                prompt: "Prepare a local Markdown export of my open meeting actions. Show me the plan before writing files.")
    }
    private func starter(_ title: String, id: String, icon: String, prompt: String) -> some View {
        Button { controller.draft = prompt; sessions.composerFocusRequest += 1 } label: {
            Label(title, systemImage: icon).padding(.vertical, 8).padding(.horizontal, 10)
        }.buttonStyle(.bordered).accessibilityIdentifier("agent.starter.\(id)")
    }

    @ViewBuilder private func messageRow(_ item: AgentTranscriptItem) -> some View {
        switch item {
        case .user(_, let text):
            VStack(alignment: .trailing, spacing: 6) {
                Text(text).font(.system(size: sessions.textSize)).textSelection(.enabled)
                    .padding(12).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 14))
                HStack(spacing: 12) {
                    copyButton(text)
                    Button("Edit as follow-up") {
                        controller.editAsFollowUp(item); sessions.composerFocusRequest += 1
                    }
                    branchButton(item)
                }.font(.caption).buttonStyle(.borderless)
            }.frame(maxWidth: .infinity, alignment: .trailing)
        case .assistant(_, let text, let streaming):
            VStack(alignment: .leading, spacing: 12) {
                if streaming {
                    Text(verbatim: text).font(.system(size: sessions.textSize)).lineSpacing(5)
                        .textSelection(.enabled).accessibilityIdentifier("agent.assistant")
                } else {
                    SelectableDigestText(text, font: .system(size: sessions.textSize), searchQuery: findQuery, style: .agent)
                        .accessibilityIdentifier("agent.assistant")
                    HStack(spacing: 12) {
                        copyButton(text)
                        Button("Retry response") { controller.reviewResponseRetry(item); sessions.composerFocusRequest += 1 }
                        Button("Open in results") { show(.init(id: item.id, title: "Agent response", detail: "Conversation result", text: text)) }
                        branchButton(item)
                    }.font(.caption).buttonStyle(.borderless)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        case .notice(_, let text, let error):
            Label(text, systemImage: error ? "exclamationmark.triangle" : "info.circle")
                .font(.callout).foregroundStyle(error ? Color.orange : Color.secondary).textSelection(.enabled)
        default: EmptyView()
        }
    }

    private func copyButton(_ text: String) -> some View {
        Button("Copy", systemImage: "doc.on.doc") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
            .labelStyle(.titleAndIcon)
    }
    private func branchButton(_ item: AgentTranscriptItem) -> some View {
        Button("Branch from here") { Task { await sessions.fork(taskID, through: item) } }
            .disabled(controller.state == .running || controller.activeSessionFile == nil)
            .help("Create an independent task through this message. Existing files and actions are unchanged.")
    }
    private func recovery(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Task needs attention", systemImage: "exclamationmark.triangle").font(.headline)
            Text(message).font(.callout).textSelection(.enabled)
            HStack {
                if controller.recoveryAction == .openModels {
                    Button("Open Models") { app.openSettings(tab: .models) }.accessibilityIdentifier("agent.openModels")
                }
                Button("Reconnect") { Task { _ = await sessions.start(taskID) } }.accessibilityIdentifier("agent.restart")
                if controller.failedPrompt != nil { Button("Review & retry") { controller.reviewRetry(); sessions.composerFocusRequest += 1 } }
            }
        }.padding(14).background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }
    private var results: [AgentResultPreview] { controller.items.compactMap(AgentResultPreview.tool) }
    private func show(_ value: AgentResultPreview) { preview = value; showingResults = true }
    private func nextMatch(_ offset: Int) {
        guard !matches.isEmpty else { return }
        matchIndex = (matchIndex + offset + matches.count) % matches.count
    }
}
