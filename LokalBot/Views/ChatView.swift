import SwiftUI
import AppKit
import AVFoundation

// The assistant's conversation surfaces: the editorial transcript embedded
// by the Ask section (spec §2.3), and the saved-conversation list shown in
// Ask's content column. The assistant itself is a small ReAct agent
// (`ChatAgent`) over the summarisation `TextEngine` that can search
// transcripts, list meetings, and read a meeting's summary or transcript
// via tool calls — all on-device.

// MARK: - Editorial transcript

/// The conversation transcript, restyled from chat bubbles to an editorial
/// layout (spec §2.3): user turns as compact teal-tinted rows, assistant
/// turns as full-width flat text with tool activity collapsed to one
/// "worked: …" line. Embedded by the Ask surface.
struct ChatTranscriptView: View {
    @ObservedObject var model: ChatViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isNearBottom = true
    @State private var scrollPosition = ScrollPosition(edge: .top)
    @State private var displayedConversation: UUID?

    var body: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .bottom) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(transcriptEntries) { entry in
                            EditorialTurn(
                                message: entry.message,
                                model: model,
                                startsQuestion: entry.startsQuestion,
                                dateDividerTitle: entry.dateDividerTitle,
                                showsQuestionScope: entry.showsQuestionScope,
                                isLatestQuestion: entry.isLatestQuestion)
                                .id(entry.id)
                        }
                    }
                    .padding(.horizontal, WorkspaceMetric.pagePadding)
                    .padding(.top, 20)
                    .padding(.bottom, WorkspaceMetric.pagePadding)
                    .workspaceReadingWidth()
                    .frame(maxWidth: .infinity, alignment: .top)
                    .accessibilityIdentifier("chat.readingColumn")
                }
                .accessibilityIdentifier("chat.messages")
                .scrollPosition($scrollPosition)
                .onScrollGeometryChange(for: CGFloat.self) { geometry in
                    max(0, geometry.contentOffset.y)
                } action: { _, offset in
                    if let id = displayedConversation { model.readingOffsets[id] = offset }
                }
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    let remaining = geometry.contentSize.height - geometry.visibleRect.maxY
                    return remaining < 96
                } action: { _, nearBottom in
                    isNearBottom = nearBottom
                }

                if !isNearBottom {
                    HStack {
                        Spacer(minLength: 0)
                        Button {
                            scrollToEnd(proxy, animated: true, force: true)
                        } label: {
                            Label("Jump to latest", systemImage: "arrow.down")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .background(.regularMaterial, in: Capsule())
                        .shadow(color: .black.opacity(0.08), radius: 8, y: 3)
                        .accessibilityIdentifier("chat.jumpToLatest")
                    }
                    .workspaceReadingWidth()
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, WorkspaceMetric.pagePadding)
                    .padding(.bottom, 16)
                }
            }
            .onChange(of: model.messages.count) {
                scrollToEnd(proxy, animated: true)
            }
            .onChange(of: model.messages.last?.text) { previousText, currentText in
                let answerStarted = (previousText ?? "").isEmpty
                    && !(currentText ?? "").isEmpty
                    && model.messages.last?.role == .assistant
                if answerStarted, isNearBottom, let id = model.messages.last?.id {
                    scrollToTurn(proxy, id: id, anchor: .top, animated: true)
                } else {
                    scrollToEnd(proxy, animated: false)
                }
            }
            .onChange(of: model.messages.last?.activity.count) {
                scrollToEnd(proxy, animated: false)
            }
            .onChange(of: model.currentID) {
                restorePosition(proxy)
            }
            .onAppear { restorePosition(proxy) }
        }
    }

    private func restorePosition(_ proxy: ScrollViewProxy) {
        displayedConversation = nil
        let id = model.currentID
        let saved = model.readingOffsets[id]
        DispatchQueue.main.async {
            if let saved { scrollPosition.scrollTo(y: saved); isNearBottom = false } else { isNearBottom = true; scrollToEnd(proxy, animated: false, force: true) }
            displayedConversation = id
        }
    }

    private var transcriptEntries: [ChatTranscriptEntry] {
        let latestUserID = model.messages.last(where: { $0.role == .user })?.id
        var previousUser: ChatMessage?
        return model.messages.enumerated().map { index, message in
            defer {
                if message.role == .user { previousUser = message }
            }
            return ChatTranscriptEntry(
                message: message,
                startsQuestion: index > 0 && message.role == .user,
                dateDividerTitle: ChatTranscriptPresentation.dateDividerTitle(
                    for: message,
                    after: previousUser),
                showsQuestionScope: message.role == .user
                    && ChatTranscriptPresentation.questionScopeChanged(
                        message,
                        after: previousUser),
                isLatestQuestion: message.id == latestUserID)
        }
    }

    private func scrollToEnd(
        _ proxy: ScrollViewProxy,
        animated: Bool,
        force: Bool = false
    ) {
        guard force || isNearBottom else { return }
        guard let last = model.messages.last?.id else { return }
        if animated {
            withAnimation(WorkspaceMotion.animation(.autoScroll, reduceMotion: reduceMotion)) {
                proxy.scrollTo(last, anchor: .bottom)
            }
        } else {
            proxy.scrollTo(last, anchor: .bottom)
        }
    }

    private func scrollToTurn(
        _ proxy: ScrollViewProxy,
        id: UUID,
        anchor: UnitPoint,
        animated: Bool
    ) {
        if animated {
            withAnimation(WorkspaceMotion.animation(.autoScroll, reduceMotion: reduceMotion)) {
                proxy.scrollTo(id, anchor: anchor)
            }
        } else {
            proxy.scrollTo(id, anchor: anchor)
        }
    }
}

private struct ChatTranscriptEntry: Identifiable {
    let message: ChatMessage
    let startsQuestion: Bool
    let dateDividerTitle: String?
    let showsQuestionScope: Bool
    let isLatestQuestion: Bool
    var id: UUID { message.id }
}

enum ChatTranscriptPresentation {
    static func dateDividerTitle(
        for message: ChatMessage,
        after previousUser: ChatMessage?,
        calendar: Calendar = .autoupdatingCurrent
    ) -> String? {
        guard message.role == .user else { return nil }
        if message.createdAtIsEstimated {
            return previousUser?.createdAtIsEstimated == true ? nil : "Earlier conversation"
        }
        if let previousUser,
           !previousUser.createdAtIsEstimated,
           calendar.isDate(previousUser.createdAt, inSameDayAs: message.createdAt) {
            return nil
        }
        if calendar.isDateInToday(message.createdAt) { return "Today" }
        if calendar.isDateInYesterday(message.createdAt) { return "Yesterday" }
        return message.createdAt.formatted(date: .long, time: .omitted)
    }

    static func questionScopeChanged(
        _ message: ChatMessage,
        after previousUser: ChatMessage?
    ) -> Bool {
        guard message.role == .user else { return false }
        guard let previousUser else { return true }
        return Set(message.sourceScopes) != Set(previousUser.sourceScopes)
            || message.dayScopeKey != previousUser.dayScopeKey
            || message.attachedScreenDayKeys != previousUser.attachedScreenDayKeys
    }

    static func isLongQuestion(_ text: String) -> Bool {
        text.count > 180 || text.components(separatedBy: .newlines).count > 3
    }
}

private struct ConversationDateDivider: View {
    let title: String

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .font(Font.scaled(.callout).weight(.semibold))
                .foregroundStyle(.secondary)
            Color.primary.opacity(0.10)
                .frame(height: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

private struct EditorialTurn: View {
    @EnvironmentObject var app: AppState
    let message: ChatMessage
    @ObservedObject var model: ChatViewModel
    let startsQuestion: Bool
    let dateDividerTitle: String?
    let showsQuestionScope: Bool
    let isLatestQuestion: Bool
    @ObservedObject private var downloads = ModelDownloadManager.shared
    @State private var speechPlayer: AVAudioPlayer?
    @State private var speechError: String?
    @State private var preparingSpeech = false
    @State private var readingSpeech = false
    @State private var speechTask: Task<Void, Never>?
    @State private var speechSessionID: UUID?
    @State private var copied = false
    @State private var questionExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let dateDividerTitle {
                ConversationDateDivider(title: dateDividerTitle)
            } else if startsQuestion {
                Divider()
            }
            Group {
                if message.role == .user { userRow } else { assistantBlock }
            }
        }
        .accessibilityIdentifier(message.role == .user ? "chat.message.user"
                                                       : "chat.message.assistant")
        .onDisappear {
            stopAssistantSpeech(clearError: false)
        }
    }

    private var userRow: some View {
        VStack(alignment: .leading, spacing: 7) {
            turnMetadata(
                "You",
                systemImage: "person.crop.circle",
                scopeSummary: showsQuestionScope ? questionScopeSummary : nil)
            Text(message.text)
                .font(Font.scaled(.title2).weight(.semibold))
                .lineLimit(questionIsExpanded ? nil : 3)
                .textSelection(.enabled)
            if ChatTranscriptPresentation.isLongQuestion(message.text), !isLatestQuestion {
                Button(questionExpanded ? "Show less" : "Show full question") {
                    questionExpanded.toggle()
                }
                .buttonStyle(.plain)
                .font(Font.scaled(.callout).weight(.semibold))
                .foregroundStyle(Brand.teal)
                .frame(minHeight: 28)
                .accessibilityIdentifier("chat.question.expand")
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityValue(userTurnAccessibilityValue)
    }

    @ViewBuilder private var assistantBlock: some View {
        let parsed = ChatCitationParser.extract(message.text)
        VStack(alignment: .leading, spacing: 10) {
            if isStoppedTurn {
                responseStatusRow(
                    title: "Response stopped",
                    detail: model.canRetry(message.id)
                        ? "The response was interrupted. You can try the question again."
                        : "This earlier response was not completed.",
                    systemImage: "stop.circle",
                    tint: Color.primary.opacity(0.55))
            } else if message.isError {
                responseStatusRow(
                    title: "Answer unavailable",
                    detail: message.text,
                    systemImage: "exclamationmark.triangle",
                    tint: Brand.error)
            } else {
                turnMetadata(
                    message.isPending ? "LokalBot is answering" : "LokalBot",
                    systemImage: "sparkles")
                if message.activity.contains(where: { !$0.done }) {
                    WorkedLine(activities: message.activity)
                }
            }
            if message.isPending && message.text.isEmpty && !message.isError {
                ModelPreparationView(
                    presentation: assistantPreparation,
                    style: .standard)
                answerActions(copyText: "", allowsSpeech: false)
            } else if !message.isError && !isStoppedTurn {
                if !parsed.display.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Group {
                        if message.isPending {
                            Text(verbatim: parsed.display).textSelection(.enabled)
                        } else {
                            SelectableDigestText(ChatCitationParser.extract(message.text, linked: true).display, style: .editorial)
                                .environment(\.openURL, OpenURLAction { url in
                                    guard url.scheme == "lokalbot-citation" else { return .systemAction }
                                    guard url.host == "source", let number = Int(url.lastPathComponent),
                                          parsed.citations.indices.contains(number - 1) else { return .discarded }
                                    let citation = parsed.citations[number - 1]
                                    if let snapshotID = citation.snapshotID {
                                        app.openScreenSnapshot(snapshotID)
                                    } else {
                                        app.openCitation(citation)
                                    }
                                    return .handled
                                })
                        }
                    }
                        .foregroundStyle(message.isError ? AnyShapeStyle(.red)
                                                         : AnyShapeStyle(.primary))
                        .contextMenu {
                            Button {
                                toggleAssistantSpeech(parsed.display)
                            } label: {
                                Label(readingSpeech ? "Stop reading aloud" : "Read aloud",
                                      systemImage: assistantSpeechIcon)
                            }
                        }
                        .accessibilityAction(
                            named: Text(readingSpeech ? "Stop reading aloud" : "Read aloud")) {
                                toggleAssistantSpeech(parsed.display)
                            }
                    if let speechError {
                        Text(speechError)
                            .font(.scaled(.caption2))
                            .foregroundStyle(Brand.error)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                answerActions(copyText: parsed.display, allowsSpeech: true)
                if !parsed.citations.isEmpty {
                    EvidenceDisclosure(citations: parsed.citations)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var questionIsExpanded: Bool {
        isLatestQuestion || questionExpanded
    }

    private var userTurnAccessibilityValue: String {
        guard let questionScopeSummary else { return message.text }
        return "\(message.text). Question scope: \(questionScopeSummary)"
    }

    private var isStoppedTurn: Bool {
        let normalized = message.text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized == "stopped." || normalized.hasPrefix("response stopped")
    }

    private var questionScopeSummary: String? {
        guard message.role == .user,
              !message.sourceScopes.isEmpty || message.dayScopeKey != nil else { return nil }
        let selected = Set(message.sourceScopes)
        let sourceText: String
        if selected == AskSourceScope.defaults {
            sourceText = "All sources"
        } else {
            sourceText = AskSourceScope.allCases
                .filter(selected.contains)
                .map(\.displayName)
                .joined(separator: ", ")
        }
        var parts = [sourceText]
        if let dayKey = message.dayScopeKey {
            parts.append(AskDateScope(storageKey: dayKey)?.label() ?? dayKey)
        }
        if !message.attachedScreenDayKeys.isEmpty {
            let days = message.attachedScreenDayKeys.map { key in
                AskDayScope.date(for: key)?.formatted(date: .abbreviated, time: .omitted)
                    ?? key
            }.joined(separator: ", ")
            parts.append("attached screen: \(days)")
        }
        return parts.joined(separator: " · ")
    }

    private func turnMetadata(
        _ title: String,
        systemImage: String,
        scopeSummary: String? = nil
    ) -> some View {
        HStack(spacing: 7) {
            Image(systemName: systemImage)
                .frame(width: 14)
            Text(title)
                .font(Font.scaled(.callout).weight(.semibold))
            if !message.createdAtIsEstimated {
                Text("·").foregroundStyle(.tertiary)
                Text(message.createdAt.formatted(date: .omitted, time: .shortened))
                    .font(Font.scaled(.callout).monospacedDigit())
            }
            if let scopeSummary {
                Text("·").foregroundStyle(.tertiary)
                Image(systemName: "scope")
                Text(scopeSummary).lineLimit(1)
            }
        }
        .font(Font.scaled(.callout))
        .foregroundStyle(Color.primary.opacity(0.68))
        .accessibilityElement(children: .combine)
    }

    private func responseStatusRow(
        title: String,
        detail: String,
        systemImage: String,
        tint: Color
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Font.scaled(.body).weight(.semibold))
                Text(detail)
                    .font(Font.scaled(.callout))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if model.canRetry(message.id) {
                Button {
                    model.retry(message.id)
                } label: {
                    Label("Retry", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("chat.answer.retry")
            }
        }
        .padding(10)
        .background(
            .quaternary.opacity(0.18),
            in: RoundedRectangle(cornerRadius: Brand.Radius.control, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Brand.Radius.control, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08))
        }
    }

    @ViewBuilder
    private func answerActions(copyText: String, allowsSpeech: Bool) -> some View {
        HStack(spacing: 14) {
            if !copyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button {
                    copyAnswer(copyText)
                } label: {
                    Label(copied ? "Copied" : "Copy",
                          systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .disabled(copied)
                .help("Copy this answer")
                .accessibilityIdentifier("chat.answer.copy")
            }

            if allowsSpeech {
                Button {
                    toggleAssistantSpeech(copyText)
                } label: {
                    Label(readingSpeech ? "Stop reading" : "Read aloud",
                          systemImage: assistantSpeechIcon)
                }
                .help(readingSpeech ? "Stop reading aloud" : "Read this answer aloud")
                .accessibilityIdentifier("chat.answer.readAloud")
            }

            if model.canRetry(message.id) {
                Button {
                    model.retry(message.id)
                } label: {
                    Label("Retry", systemImage: "arrow.clockwise")
                }
                .help("Try this question again")
                .accessibilityIdentifier("chat.answer.retry")
            }

            if message.isPending && model.isResponding {
                Button {
                    model.stop()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .keyboardShortcut(.cancelAction)
                .help("Stop answering (Esc)")
                .accessibilityIdentifier("chat.answer.stop")
            }
        }
        .buttonStyle(.bordered)
        .padding(.top, 2)
    }

    private func copyAnswer(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else { return }
        copied = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }

    private var assistantPreparation: ModelPreparationPresentation {
        if app.settings.summarizerBackend == .builtIn,
           let entry = ModelCatalog.entry(
                id: app.settings.builtInModelID,
                custom: app.settings.customBuiltInModels),
           let progress = downloads.progress[entry.id] {
            return .init(
                state: .preparing,
                title: "Preparing \(entry.displayName)",
                status: "Downloading the on-device model — \(Int(progress * 100))%",
                progress: progress)
        }

        switch model.responsePhase {
        case .preparingEngine:
            return .init(
                state: .preparing,
                title: "Preparing the assistant",
                status: app.settings.summarizerBackend == .builtIn
                    ? "Checking the selected on-device model…"
                    : "Connecting to the selected model…")
        case .startingAssistant:
            return .init(
                state: .preparing,
                title: "Starting the assistant",
                status: app.settings.summarizerBackend == .builtIn
                    ? "Loading the model into memory…"
                    : "Waiting for the first response…")
        case nil:
            return .init(
                state: .preparing,
                title: "Preparing the assistant",
                status: "Starting the selected model…")
        }
    }

    private var assistantSpeechIcon: String {
        if readingSpeech { return "stop.fill" }
        if preparingSpeech { return "hourglass" }
        return "speaker.wave.2"
    }

    private func toggleAssistantSpeech(_ text: String) {
        if readingSpeech {
            stopAssistantSpeech()
        } else {
            readAssistantTurn(text)
        }
    }

    private func readAssistantTurn(_ text: String) {
        stopAssistantSpeech(clearError: false)
        speechError = nil
        let sessionID = UUID()
        speechSessionID = sessionID
        preparingSpeech = true
        readingSpeech = true
        speechTask = Task {
            defer { finishAssistantSpeech(sessionID) }
            do {
                let url = try await KokoroSpeechEngine.shared.synthesize(.init(
                    text: text,
                    voice: app.settings.speechVoice,
                    speed: app.settings.speechSpeed,
                    outputURL: nil))
                // Caller owns this plaintext temporary output, including
                // cancellation, superseded playback and player failures.
                defer { try? FileManager.default.removeItem(at: url) }
                try Task.checkCancellation()
                let player = try AVAudioPlayer(contentsOf: url)
                player.prepareToPlay()
                guard speechSessionID == sessionID else { return }
                speechPlayer = player
                preparingSpeech = false
                guard player.play() else {
                    throw NSError(
                        domain: "LokalBot.SpeechPlayback",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Could not start speech playback."])
                }
                try await Task.sleep(
                    nanoseconds: UInt64(max(player.duration, 0.1) * 1_000_000_000))
            } catch is CancellationError {
            } catch {
                if speechSessionID == sessionID {
                    speechError = error.localizedDescription
                }
            }
        }
    }

    private func stopAssistantSpeech(clearError: Bool = true) {
        speechSessionID = nil
        speechTask?.cancel()
        speechTask = nil
        speechPlayer?.stop()
        speechPlayer = nil
        preparingSpeech = false
        readingSpeech = false
        if clearError {
            speechError = nil
        }
    }

    private func finishAssistantSpeech(_ sessionID: UUID) {
        guard speechSessionID == sessionID else { return }
        speechSessionID = nil
        speechTask = nil
        speechPlayer?.stop()
        speechPlayer = nil
        preparingSpeech = false
        readingSpeech = false
    }
}

/// One compact evidence disclosure matching inline `[n]` references in the answer.
private struct EvidenceDisclosure: View {
    @EnvironmentObject var app: AppState
    let citations: [ChatCitation]
    @State private var isExpanded: Bool

    init(citations: [ChatCitation]) {
        self.citations = citations
        _isExpanded = State(initialValue: citations.count <= 3)
    }

    var body: some View {
        WorkspaceDisclosure(
            isExpanded: $isExpanded,
            identifier: "chat.evidence",
            style: .compact) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(citations.enumerated()), id: \.element.id) { index, citation in
                    sourceRow(number: index + 1, citation: citation)
                }
            }
            Text("LokalBot used only the sources enabled for this question. Citation numbers remain stable even when a local source is later removed.")
                .font(Font.scaled(.callout))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)
        } label: {
            HStack(spacing: 8) {
                Label("Evidence", systemImage: "checkmark.shield")
                    .font(Font.scaled(.body))
                Text(evidenceSummary)
                    .font(Font.scaled(.callout))
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("chat.sources")
    }

    private var evidenceSummary: String {
        guard let first = citations.first else { return "No sources" }
        let keys = Set(citations.map { citation in
            switch citation.kind {
            case .meeting: "meeting:\(citation.meetingID)"
            case .screen: "screen:\(citation.snapshotID.map(String.init) ?? "unknown")"
            }
        })
        if citations.count == 1 {
            return "1 source · \(resolved(first).title)"
        }
        if keys.count == 1 {
            return "\(citations.count) citations · \(resolved(first).title)"
        }
        return "\(citations.count) citations · \(keys.count) sources"
    }

    @ViewBuilder private func sourceRow(number: Int, citation: ChatCitation) -> some View {
        let source = resolved(citation)
        Button {
            guard source.available else { return }
            switch citation.kind {
            case .meeting: app.openCitation(citation)
            case .screen:
                if let snapshotID = citation.snapshotID { app.openScreenSnapshot(snapshotID) }
            }
        } label: {
            HStack(spacing: 10) {
                Text("\(number)")
                    .font(Font.scaled(.callout).weight(.semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .frame(width: 20, height: 20)
                    .background(Brand.tealFill, in: RoundedRectangle(cornerRadius: 4))
                Image(systemName: source.icon)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 3) {
                    Text(source.title)
                        .font(Font.scaled(.body).weight(.semibold))
                        .foregroundStyle(source.available ? .primary : .secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(source.detail)
                        .font(Font.scaled(.callout)).foregroundStyle(.secondary)
                }
                Spacer()
                if source.available {
                    Image(systemName: "chevron.right")
                        .font(.scaled(.caption).weight(.semibold))
                        .foregroundStyle(.tertiary)
                } else {
                    Text("Unavailable")
                        .font(Font.scaled(.callout))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .lbGroupedSurface()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!source.available)
        .accessibilityHint(source.available
            ? "Opens the cited local evidence"
            : "The cited local source is no longer available")
    }

    private func resolved(_ citation: ChatCitation) -> (
        title: String, detail: String, icon: String, available: Bool
    ) {
        switch citation.kind {
        case .meeting:
            let meeting = (try? SessionLookup.find(
                id: citation.meetingID, in: app.meetings)) ?? nil
            guard let meeting else {
                return ("Meeting \(citation.meetingID)", "Local source missing", "person.2", false)
            }
            let stamp = citation.stampText.map { " · \($0)" } ?? ""
            return (
                meeting.displayTitle,
                "Meeting · \(meeting.startedAt.formatted(date: .abbreviated, time: .shortened))\(stamp)",
                "person.2",
                true)
        case .screen:
            guard let snapshotID = citation.snapshotID,
                  let shot = app.activityStore.screenshot(id: snapshotID) else {
                return ("Screen moment", "Local source missing", "display", false)
            }
            return (
                shot.windowTitle.isEmpty ? shot.app : shot.windowTitle,
                "Screen · \(shot.ts.formatted(date: .abbreviated, time: .shortened))",
                "display",
                true)
        }
    }

}

/// Tool activity collapsed to a single caption line ("worked: searched
/// transcripts · read summary"); expands to the per-step rows on click.
/// While a step is in flight it shows that step with a spinner instead.
private struct WorkedLine: View {
    let activities: [ChatMessage.Activity]
    @State private var expanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var inFlight: ChatMessage.Activity? { activities.first { !$0.done } }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                    expanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    if let current = inFlight {
                        LoadingStateLabel(current.text, controlSize: .mini)
                    } else {
                        Image(systemName: "checkmark.circle").font(.scaled(.caption2))
                        Text("worked: " + activities.map(\.text).joined(separator: " · "))
                            .lineLimit(1)
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.scaled(.caption2))
                    }
                }
                .font(Font.scaled(.callout))
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            if expanded {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(activities) { ActivityRow(activity: $0) }
                }
            }
        }
    }
}

private struct ActivityRow: View {
    let activity: ChatMessage.Activity

    var body: some View {
        HStack(spacing: 6) {
            if activity.done {
                Image(systemName: activity.icon).font(.scaled(.caption2)).foregroundStyle(.secondary)
                Text(activity.text).font(Font.scaled(.callout)).foregroundStyle(.secondary)
            } else {
                LoadingStateLabel(activity.text, controlSize: .mini)
            }
        }
        .chipChrome()
    }
}

/// The Ask section's question history — a selectable list of saved conversations
/// plus a visible "New conversation" action. Selecting one loads it into the transcript;
/// conversations persist across launches via `ChatStore`.
struct ChatConversationList: View {
    @EnvironmentObject var app: AppState
    var body: some View { ConversationListContent(model: app.chat) }
}

private struct ConversationListContent: View {
    @ObservedObject var model: ChatViewModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var historyQuery = ""
    @State private var pendingDeletion: Conversation?

    var body: some View {
        VStack(spacing: 0) {
            historyHeader
            List(selection: conversationSelection) {
                if historySections.isEmpty {
                    Text("No questions match “\(historyQuery)”.")
                        .font(Font.scaled(.callout))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(historySections, id: \.title) { section in
                        Group {
                            Text(section.title)
                                .font(Font.scaled(.callout).weight(.semibold))
                                .workspaceTextRole(.metadata)
                                .accessibilityAddTraits(.isHeader)
                            ForEach(section.conversations) { conversation in
                                row(conversation)
                                    .tag(conversation.id)
                                    .accessibilityIdentifier(
                                        "chat.conversation.\(conversation.id.uuidString)")
                                    .contextMenu {
                                        Button(role: .destructive) {
                                            pendingDeletion = conversation
                                        } label: {
                                            Label("Delete", systemImage: "trash")
                                        }
                                    }
                            }
                        }
                    }
                }
            }
            .listStyle(.inset)
            .accessibilityLabel("Saved conversations")
            .accessibilityIdentifier("chat.history.list")
            .scrollContentBackground(.hidden)
            .tint(Brand.tealFill)
        }
        // One native title owns both the visible toolbar label and the window's
        // accessibility title. The detail column deliberately adds no second
        // Ask label.
        .navigationTitle("Ask")
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Conversation history")
        .accessibilityIdentifier("chat.conversationList")
        .alert(
            "Delete Question?",
            isPresented: deletionConfirmationPresented,
            presenting: pendingDeletion
        ) { conversation in
            Button("Delete", role: .destructive) {
                model.delete(conversation.id)
                pendingDeletion = nil
            }
            Button("Cancel", role: .cancel) {
                pendingDeletion = nil
            }
        } message: { conversation in
            Text("This removes “\(ChatViewModel.displayTitle(for: conversation))” from Ask history.")
        }
    }

    private var historyHeader: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Conversations").font(.scaled(.title3).bold())
                    Text("\(model.conversations.count) conversations").font(.scaled(.callout)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
            Button {
                model.newConversation()
            } label: {
                Label("New Conversation", systemImage: "square.and.pencil").labelStyle(.iconOnly)
                    .font(Font.scaled(.body))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.bordered)
            .foregroundStyle(.primary)
            .frame(minHeight: 28)
            .keyboardShortcut("n", modifiers: [.command])
            .help("Start a new question")
            .accessibilityIdentifier("chat.new")

            }

            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search questions", text: $historyQuery)
                    .textFieldStyle(.plain)
                    .font(Font.scaled(.body))
                    .accessibilityIdentifier("chat.history.search")
                if !historyQuery.isEmpty {
                    Button {
                        historyQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Clear question search")
                    .accessibilityLabel("Clear question search")
                }
            }
            .padding(.horizontal, 9)
            .frame(minHeight: 32)
            .workspaceControl()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 14)
    }

    private var deletionConfirmationPresented: Binding<Bool> {
        Binding(
            get: { pendingDeletion != nil },
            set: { presented in
                if !presented { pendingDeletion = nil }
            })
    }

    private var conversationSelection: Binding<Conversation.ID?> {
        Binding(
            get: { model.currentID },
            set: { selected in
                guard let selected else { return }
                model.select(selected)
            })
    }

    private var matchingConversations: [Conversation] {
        let query = historyQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return model.conversations }
        return model.conversations.filter {
            $0.title.localizedStandardContains(query)
                || $0.messages.contains { $0.text.localizedStandardContains(query) }
        }
    }

    private var historySections: [(title: String, conversations: [Conversation])] {
        let calendar = Calendar.autoupdatingCurrent
        let now = Date()
        let weekStart = calendar.date(byAdding: .day, value: -7,
                                      to: calendar.startOfDay(for: now)) ?? .distantPast
        let groups: [(String, (Conversation) -> Bool)] = [
            ("Today", { calendar.isDateInToday($0.updatedAt) }),
            ("Yesterday", { calendar.isDateInYesterday($0.updatedAt) }),
            ("Previous 7 Days", {
                !calendar.isDateInToday($0.updatedAt)
                    && !calendar.isDateInYesterday($0.updatedAt)
                    && $0.updatedAt >= weekStart
            }),
            ("Earlier", { $0.updatedAt < weekStart }),
        ]
        return groups.compactMap { title, includes in
            let conversations = matchingConversations.filter(includes)
            return conversations.isEmpty ? nil : (title, conversations)
        }
    }

    private func row(_ conversation: Conversation) -> some View {
        let title = ChatViewModel.displayTitle(for: conversation)
        let timestamp = historyTimestamp(conversation.updatedAt)
        return Button { model.select(conversation.id) } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Font.scaled(.body).weight(.semibold))
                    .lineLimit(1)
                Text(timestamp)
                    .font(Font.scaled(.callout)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(timestamp)
        .accessibilityAddTraits(model.currentID == conversation.id ? .isSelected : [])
    }

    private func historyTimestamp(_ date: Date) -> String {
        let calendar = Calendar.autoupdatingCurrent
        if calendar.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(date: .abbreviated, time: .omitted)
    }
}
