import SwiftUI
import AppKit
import AVFoundation

// The assistant's conversation surfaces: the transcript embedded by the Ask
// section (questions, answers with numbered citations, a sources list under
// each answer), and the saved-conversation list shown in Ask's content column. The assistant itself is a small ReAct agent
// (`ChatAgent`) over the summarisation `TextEngine` that can search
// transcripts, list meetings, and read a meeting's summary or transcript
// via tool calls — all on-device.

// MARK: - Editorial transcript

/// The conversation transcript: each question as a heading with its time,
/// then the answer as flat text with tool activity collapsed to one line,
/// its sources and its actions. Embedded by the Ask surface.
struct ChatTranscriptView: View {
    /// `page` is the Ask screen. `compact` is the answer inside the Quick
    /// Recall window: tighter margins, the question under "You" and its time,
    /// sources as rows like that window's results, and no per-answer actions
    /// (the window's foot has Copy).
    enum Style { case page, compact }

    @ObservedObject var model: ChatViewModel
    var style: Style = .page
    /// Called after a source was opened from an answer, so a small window
    /// can bring the main window forward and close.
    var onOpenSource: ((ChatCitation.Kind) -> Void)?
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
                                isLatestQuestion: entry.isLatestQuestion,
                                question: entry.question,
                                isLastTurn: entry.isLastTurn,
                                style: style,
                                onOpenSource: onOpenSource)
                                .id(entry.id)
                        }
                    }
                    .padding(.horizontal, style == .compact ? 24 : WorkspaceMetric.pagePadding)
                    .padding(.top, style == .compact ? 14 : 20)
                    .padding(.bottom, style == .compact ? 14 : WorkspaceMetric.pagePadding)
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
        let lastID = model.messages.last?.id
        var previousUser: ChatMessage?
        return model.messages.enumerated().map { index, message in
            defer {
                if message.role == .user { previousUser = message }
            }
            return ChatTranscriptEntry(
                message: message,
                startsQuestion: index > 0 && message.role == .user,
                dateDividerTitle: ChatTranscriptPresentation.visibleDateDividerTitle(
                    for: message,
                    after: previousUser),
                isLatestQuestion: message.id == latestUserID,
                question: message.role == .assistant ? previousUser : nil,
                isLastTurn: message.id == lastID)
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
    let isLatestQuestion: Bool
    /// For an answer, the question it replied to.
    let question: ChatMessage?
    let isLastTurn: Bool
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

    /// The divider a question shows above it. A conversation that starts
    /// today needs none: each question already carries its time.
    static func visibleDateDividerTitle(
        for message: ChatMessage,
        after previousUser: ChatMessage?,
        calendar: Calendar = .autoupdatingCurrent
    ) -> String? {
        if previousUser == nil, !message.createdAtIsEstimated, calendar.isDateInToday(message.createdAt) {
            return nil
        }
        return dateDividerTitle(for: message, after: previousUser, calendar: calendar)
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
                .font(AppFont.scaled(.callout).weight(.semibold))
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let message: ChatMessage
    @ObservedObject var model: ChatViewModel
    let startsQuestion: Bool
    let dateDividerTitle: String?
    let isLatestQuestion: Bool
    /// The question an answer replied to.
    let question: ChatMessage?
    /// The answer that ends the conversation; a failed one keeps its matches.
    let isLastTurn: Bool
    var style: ChatTranscriptView.Style = .page
    var onOpenSource: ((ChatCitation.Kind) -> Void)?
    @ObservedObject private var downloads = ModelDownloadManager.shared
    @State private var speechPlayer: AVAudioPlayer?
    @State private var speechError: String?
    @State private var preparingSpeech = false
    @State private var readingSpeech = false
    @State private var speechTask: Task<Void, Never>?
    @State private var speechSessionID: UUID?
    @State private var copied = false
    @State private var questionExpanded = false
    @State private var openCitation: OpenCitation?
    @State private var clickProbe = CitationClickProbe()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let dateDividerTitle {
                ConversationDateDivider(title: dateDividerTitle)
            } else if startsQuestion {
                Divider().padding(.bottom, 8)
            }
            Group {
                if message.role == .user {
                    if style == .compact { compactUserRow } else { userRow }
                } else {
                    assistantBlock
                }
            }
        }
        .accessibilityIdentifier(message.role == .user ? "chat.message.user"
                                                       : "chat.message.assistant")
        .onDisappear {
            stopAssistantSpeech(clearError: false)
        }
    }

    /// The question in its own words, with the time it was asked. What it
    /// was limited to is in the time's tooltip and the spoken value; the
    /// composer's two menus are where scope is chosen.
    private var userRow: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(message.text)
                    .font(LBTokens.Typography.question)
                    .lineLimit(questionIsExpanded ? nil : 3)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !message.createdAtIsEstimated {
                    Text(message.createdAt.formatted(date: .omitted, time: .shortened))
                        .font(AppFont.scaled(.callout).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .help(questionScopeSummary ?? "")
                }
            }
            if ChatTranscriptPresentation.isLongQuestion(message.text), !isLatestQuestion {
                Button(questionExpanded ? "Show less" : "Show full question") {
                    questionExpanded.toggle()
                }
                .buttonStyle(.plain)
                .font(AppFont.scaled(.callout).weight(.semibold))
                .foregroundStyle(Brand.teal)
                .frame(minHeight: 28)
                .accessibilityIdentifier("chat.question.expand")
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityValue(userTurnAccessibilityValue)
    }

    /// Quick Recall: "You" and the time on a quiet line, the question under it.
    private var compactUserRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: compactAskedLine)
                .font(AppFont.scaled(.callout).monospacedDigit())
                .foregroundStyle(.secondary)
            Text(message.text)
                .font(AppFont.scaledSystem(size: 16, weight: .semibold))
                .lineLimit(questionIsExpanded ? nil : 3)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityValue(userTurnAccessibilityValue)
    }

    private var compactAskedLine: String {
        let you = app.settings.appLanguage.localized("You")
        guard !message.createdAtIsEstimated else { return you }
        return "\(you) · \(message.createdAt.formatted(date: .omitted, time: .shortened))"
    }

    @ViewBuilder private var assistantBlock: some View {
        if let receipt = message.rememberReceipt {
            if let personalModel = model.personalModel {
                RememberReceiptCard(message: message, receipt: receipt, personalModel: personalModel)
            } else {
                Text(message.text).foregroundStyle(.secondary)
            }
        } else {
            answerBlock
        }
    }

    @ViewBuilder private var answerBlock: some View {
        let parsed = ChatCitationParser.extract(message.text)
        VStack(alignment: .leading, spacing: 12) {
            if isStoppedTurn {
                statusCard(title: "Response stopped", detail: nil, systemImage: "stop.circle",
                           tint: Color.secondary, offersModelSettings: false)
            } else if message.isError {
                statusCard(title: "Couldn't answer", detail: message.text,
                           systemImage: "exclamationmark.triangle",
                           tint: LBTokens.Palette.attentionText, offersModelSettings: true)
                if isLastTurn, let question {
                    FailedAnswerMatches(question: question)
                }
            } else {
                if message.activity.contains(where: { !$0.done }) {
                    WorkedLine(activities: message.activity)
                }
                if message.isPending && message.text.isEmpty {
                    ModelPreparationView(
                        presentation: assistantPreparation,
                        style: .standard)
                } else {
                    if !parsed.display.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        answerText(parsed)
                        if let speechError {
                            Text(speechError)
                                .font(.scaled(.caption2))
                                .foregroundStyle(Brand.error)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                    if !message.isPending {
                        let claimIDs = model.personalModel == nil ? [] : message.usedClaimIDs ?? []
                        if !parsed.citations.isEmpty || !claimIDs.isEmpty {
                            switch style {
                            case .page:
                                AnswerSourcesList(citations: parsed.citations, claimIDs: claimIDs,
                                                  personalModel: model.personalModel, open: $openCitation)
                            case .compact:
                                QuickRecallAnswerSources(citations: parsed.citations, claimIDs: claimIDs,
                                                         personalModel: model.personalModel,
                                                         question: question?.text ?? "", onOpen: onOpenSource)
                            }
                        }
                        if style == .page { answerActions(copyText: parsed.display) }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The answer as one selectable text. A citation number is a small pill;
    /// clicking it shows the quoted passage at the number, in place.
    @ViewBuilder
    private func answerText(_ parsed: (display: String, citations: [ChatCitation])) -> some View {
        Group {
            if message.isPending {
                SelectableDigestText(StreamingMarkdown.displayable(parsed.display), style: .editorial)
            } else {
                SelectableDigestText(ChatCitationParser.extract(message.text, linked: true).display, style: .editorial)
                    .background(CitationClickProbeView(probe: clickProbe))
                    .environment(\.openURL, OpenURLAction { url in
                        guard url.scheme == "lokalbot-citation" else { return .systemAction }
                        guard url.host == "source", let number = Int(url.lastPathComponent),
                              parsed.citations.indices.contains(number - 1) else { return .discarded }
                        openCitation = OpenCitation(number: number, origin: .answer(clickProbe.clickRect()))
                        return .handled
                    })
                    .popover(item: answerPassage, attachmentAnchor: .rect(answerPassageAnchor),
                             arrowEdge: .bottom) { open in
                        if parsed.citations.indices.contains(open.number - 1) {
                            let citation = parsed.citations[open.number - 1]
                            CitationPassagePopover(citation: citation) {
                                openCitation = nil
                                // The popover opens its source right after this.
                                if let onOpenSource {
                                    DispatchQueue.main.async { onOpenSource(citation.kind) }
                                }
                            }
                        }
                    }
            }
        }
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
    }

    /// The passage opened from a number in the text (the sources list opens
    /// its own, at its own numbers).
    private var answerPassage: Binding<OpenCitation?> {
        Binding(
            get: { openCitation?.isFromAnswer == true ? openCitation : nil },
            set: { value in
                if value == nil, openCitation?.isFromAnswer == true { openCitation = nil }
            })
    }

    private var answerPassageAnchor: Anchor<CGRect>.Source {
        if case .answer(let rect?) = openCitation?.origin { return .rect(rect) }
        return .bounds
    }

    private var questionIsExpanded: Bool {
        isLatestQuestion || questionExpanded
    }

    private var userTurnAccessibilityValue: String {
        guard let questionScopeSummary else { return message.text }
        return "\(message.text). \(questionScopeSummary)"
    }

    private var isStoppedTurn: Bool {
        let normalized = message.text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized == "stopped." || normalized.hasPrefix("response stopped")
    }

    private var questionScopeSummary: String? {
        guard message.role == .user,
              !message.sourceScopes.isEmpty || message.dayScopeKey != nil else { return nil }
        let language = app.settings.appLanguage
        var parts = [AskScopeSummary.sourcesLabel(
            Set(message.sourceScopes), available: AskSourceScope.allCases, localize: language.catalog)]
        if let dayKey = message.dayScopeKey {
            parts.append(AskDateScope(storageKey: dayKey)?.label() ?? dayKey)
        }
        if !message.attachedScreenDayKeys.isEmpty {
            let days = message.attachedScreenDayKeys.map { key in
                AskDayScope.date(for: key).map { AskDateLabel.day($0, locale: language.locale) } ?? key
            }.joined(separator: ", ")
            parts.append("\(language.localized("Context")): \(days)")
        }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// A short notice in place of an answer, with the way to fix it.
    private func statusCard(
        title: LocalizedStringKey,
        detail: String?,
        systemImage: String,
        tint: Color,
        offersModelSettings: Bool
    ) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(AppFont.scaled(.body).weight(.semibold))
                if let detail {
                    Text(verbatim: detail)
                        .font(AppFont.scaled(.callout))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            if offersModelSettings {
                Button("Model settings") { app.openSettings(tab: .models) }
                    .accessibilityIdentifier("chat.answer.modelSettings")
            }
            if model.canRetry(message.id) {
                Button {
                    model.retry(message.id)
                } label: {
                    Label("Retry", systemImage: "arrow.clockwise")
                }
                .accessibilityIdentifier("chat.answer.retry")
            }
        }
        .buttonStyle(.bordered)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .askCard(cornerRadius: LBTokens.Metric.groupRadius)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.answer.status")
    }

    /// Copy, read aloud and ask again: quiet icons, each named for VoiceOver.
    private func answerActions(copyText: String) -> some View {
        HStack(spacing: 2) {
            if !copyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                answerAction(copied ? "checkmark" : "doc.on.doc", label: copied ? "Copied" : "Copy this answer",
                             identifier: "chat.answer.copy") { copyAnswer(copyText) }
                    .disabled(copied)
                answerAction(assistantSpeechIcon, label: readingSpeech ? "Stop reading aloud" : "Read aloud",
                             identifier: "chat.answer.readAloud") { toggleAssistantSpeech(copyText) }
            }
            if model.canAskAgain(message.id) {
                answerAction("arrow.clockwise", label: "Ask again", identifier: "chat.answer.askAgain") {
                    model.askAgain(message.id)
                }
            }
        }
        .padding(.leading, -6)
        .padding(.top, -4)
    }

    private func answerAction(_ symbol: String, label: LocalizedStringKey, identifier: String,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }

    private func copyAnswer(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else { return }
        let animation = WorkspaceMotion.animation(.selection, reduceMotion: reduceMotion)
        withAnimation(animation) { copied = true }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            withAnimation(animation) { copied = false }
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

/// The reply to a "Remember …" message: saved locally, no model involved.
private struct RememberReceiptCard: View {
    @EnvironmentObject var app: AppState
    let message: ChatMessage
    let receipt: ChatMessage.RememberReceipt
    @ObservedObject var personalModel: PersonalModelController

    var body: some View {
        let claim = receipt.claimID.flatMap { personalModel.claim(id: $0) }
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: receipt.claimID == nil ? "exclamationmark.circle"
                                  : claim == nil ? "minus.circle" : "checkmark.circle")
                    .foregroundStyle(receipt.claimID == nil ? AnyShapeStyle(Brand.error)
                                     : AnyShapeStyle(Brand.teal))
                    .frame(width: 14)
                Text(receipt.claimID == nil ? "Not remembered"
                     : claim == nil ? "Remembered, then forgotten" : "Remembered")
                    .font(AppFont.scaled(.callout).weight(.semibold))
            }
            .foregroundStyle(Color.primary.opacity(0.68))
            Text(claim?.text ?? message.text)
                .foregroundStyle(claim == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if let claim {
                HStack(spacing: 10) {
                    Menu {
                        ForEach(PersonalClaim.Kind.allCases, id: \.self) { kind in
                            Button(kind.displayName) { personalModel.update(claim.id, kind: kind) }
                        }
                    } label: {
                        Label(claim.kind.displayName, systemImage: claim.kind.systemImage)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Change what kind of thing this is")
                    .accessibilityIdentifier("chat.remember.kind")
                    Button("Undo") { personalModel.forget([claim.id]) }
                        .accessibilityIdentifier("chat.remember.undo")
                    Button("Manage…") { openAboutYou() }
                }
                .buttonStyle(.borderless)
                .font(AppFont.scaled(.callout))
            } else if receipt.claimID == nil {
                Button("Manage…") { openAboutYou() }
                    .buttonStyle(.borderless)
                    .font(AppFont.scaled(.callout))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: Brand.Radius.row))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.remember.receipt")
    }

    private func openAboutYou() {
        app.openSettings(tab: .personalContext)
        app.focusedSettingID = "settings.askMemoryEnabled"
    }
}

/// The matches for a question whose answer failed, found again on this Mac
/// within the sources, dates and evidence limits recorded with the question.
private struct FailedAnswerMatches: View {
    @EnvironmentObject private var app: AppState
    let question: ChatMessage
    @State private var matches = AskMatches()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !matches.isEmpty {
                Text("Matches")
                    .font(AppFont.scaled(.subheadline).weight(.bold))
                    .foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)
                AskMatchesList(matches: matches, query: question.text)
                    .askCard()
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.answer.matches")
        .task(id: question.id) { await load() }
    }

    private func load() async {
        var state = RecallWorkspaceState()
        state.sources = question.sourceScopes.isEmpty ? AskSourceScope.defaults : Set(question.sourceScopes)
        state.meetingIDs = question.meetingIDs
        state.screenIDs = question.screenSnapshotIDs
        let dateScope = question.dayScopeKey.flatMap { AskDateScope(storageKey: $0) }
        let result = await RecallSearch.search(question.text, state: state, dateScope: dateScope, app: app)
        guard !Task.isCancelled else { return }
        matches = AskMatches(result)
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
                .font(AppFont.scaled(.callout))
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
                Text(activity.text).font(AppFont.scaled(.callout)).foregroundStyle(.secondary)
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
    @EnvironmentObject private var app: AppState
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
                        .font(AppFont.scaled(.callout))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(historySections, id: \.title) { section in
                        Group {
                            Text(section.title)
                                .font(AppFont.scaled(.callout).weight(.semibold))
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

    /// A search field and the New button; the list below needs no heading.
    private var historyHeader: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField("Search questions", text: $historyQuery)
                    .textFieldStyle(.plain)
                    .font(AppFont.scaled(.body))
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
            .padding(.horizontal, 8)
            .frame(minHeight: 28)
            .workspaceControl()

            Button {
                model.newConversation()
            } label: {
                Label("New Conversation", systemImage: "square.and.pencil").labelStyle(.iconOnly)
                    .font(AppFont.scaled(.body))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .keyboardShortcut("n", modifiers: [.command])
            .help("Start a new question")
            .accessibilityIdentifier("chat.new")
        }
        .padding(.horizontal, 10)
        .padding(.top, 10)
        .padding(.bottom, 8)
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
        // A conversation that has no question yet reads "New question".
        let title = conversation.messages.isEmpty && conversation.title == ChatViewModel.newChatTitle
            ? app.settings.appLanguage.localized("New question")
            : ChatViewModel.displayTitle(for: conversation)
        let timestamp = historyTimestamp(conversation.updatedAt)
        return Button { model.select(conversation.id) } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(AppFont.scaled(.body).weight(.semibold))
                    .lineLimit(1)
                Text(timestamp)
                    .font(AppFont.scaled(.callout)).foregroundStyle(.secondary)
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
