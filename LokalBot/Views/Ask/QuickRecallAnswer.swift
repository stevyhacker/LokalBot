import AppKit
import SwiftUI

/// The sources under an answer in the Quick Recall window: a row per
/// citation, numbered as in the answer, laid out like that window's results.
/// A meeting's row carries the time it jumps to; the second line quotes the
/// passage with the question's words marked. Opening a row shows the source
/// in the main window.
struct QuickRecallAnswerSources: View {
    @EnvironmentObject private var app: AppState
    let citations: [ChatCitation]
    var claimIDs: [UUID] = []
    var personalModel: PersonalModelController?
    /// The question this answer replied to.
    var question = ""
    /// Called after a source was opened.
    var onOpen: ((ChatCitation.Kind) -> Void)?
    /// What each citation points at, by its number. Read from what is
    /// already stored on this Mac.
    @State private var sources: [Int: Source] = [:]

    private struct Source {
        var title: String
        var qualifier: String?
        var when: Date?
        var speaker: String?
        var line: String?
        var open: (() -> Void)?
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Sources")
                .font(.scaled(.subheadline).weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.bottom, 3)
                .accessibilityAddTraits(.isHeader)
            ForEach(Array(citations.enumerated()), id: \.offset) { offset, citation in
                row(number: offset + 1, citation: citation)
            }
            if !claimIDs.isEmpty, let personalModel {
                PersonalContextRow(claimIDs: claimIDs, personalModel: personalModel)
                    .padding(.horizontal, -8)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sources")
        .accessibilityIdentifier("chat.sources")
        .task(id: citations) { await load() }
    }

    private func row(number: Int, citation: ChatCitation) -> some View {
        let language = app.settings.appLanguage
        let source = sources[number] ?? Source(title: language.localized(placeholderTitle(citation.kind)))
        let when = source.when.map {
            QuickRecallDateLabel.string(for: $0, locale: language.locale, localize: language.catalog)
        }
        return Button {
            source.open?()
            onOpen?(citation.kind)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Text(verbatim: "\(number)")
                    .font(.scaled(.subheadline).weight(.bold).monospacedDigit())
                    .foregroundStyle(LBTokens.Palette.accentText)
                    .frame(minWidth: 18, minHeight: 18)
                    .background(LBTokens.Palette.accentFill.opacity(0.12), in: Circle())
                    .padding(.top, 1)
                    .accessibilityHidden(true)
                QuickRecallRowText(title: source.title, qualifier: source.qualifier, trailing: when,
                                   speaker: source.speaker, snippet: source.line) {
                    if citation.kind == .meeting, let seconds = citation.seconds {
                        AskTimeStamp(seconds: seconds)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(AskLineButtonStyle(cornerRadius: Brand.Radius.row))
        .padding(.horizontal, -10)
        .disabled(source.open == nil)
        .accessibilityLabel(Text(verbatim: "\(number). \(source.title)"))
        .accessibilityIdentifier("quickRecall.source.\(number)")
    }

    private func placeholderTitle(_ kind: ChatCitation.Kind) -> String {
        switch kind {
        case .meeting: "Meeting"
        case .screen: "Screen"
        case .file: "Files"
        case .note: "Agent note"
        }
    }

    /// Files and agent notes are read only while their own settings are on,
    /// as on the Ask screen.
    private func load() async {
        var found: [Int: Source] = [:]
        var transcripts: [UUID: [CitationPassage.Line]] = [:]
        for (offset, citation) in citations.enumerated() {
            guard !Task.isCancelled else { return }
            switch citation.kind {
            case .meeting:
                guard let meeting = (try? SessionLookup.find(id: citation.meetingID, in: app.meetings)) ?? nil else {
                    continue
                }
                var line: CitationPassage.Line?
                if let seconds = citation.seconds {
                    if transcripts[meeting.id] == nil {
                        let folder = meeting.folderURL(in: app.storage)
                        transcripts[meeting.id] = await Task.detached(priority: .userInitiated) {
                            CitationPassage.transcriptLines(in: folder)
                        }.value
                    }
                    line = CitationPassage.line(at: seconds, in: transcripts[meeting.id] ?? [])
                }
                found[offset + 1] = Source(
                    title: meeting.displayTitle, when: meeting.startedAt,
                    speaker: line.map { SpeakerDisplayName.label($0.speaker) },
                    line: QuickRecallQuote.line(line?.text, question: question),
                    open: { app.openCitation(citation) })
            case .screen:
                guard let snapshotID = citation.snapshotID,
                      let shot = app.activityStore.screenshot(id: snapshotID) else { continue }
                found[offset + 1] = Source(
                    title: shot.windowTitle.isEmpty ? shot.app : shot.windowTitle,
                    qualifier: shot.windowTitle.isEmpty ? nil : shot.app, when: shot.ts,
                    line: QuickRecallQuote.line(
                        app.activityStore.ocrText(snapshotID: snapshotID, maxChars: 1_200), question: question),
                    open: { app.openScreenSnapshot(snapshotID) })
            case .file:
                guard app.settings.fileSearchEnabled, let id = citation.fileID,
                      let hit = await app.fileSearch.hit(segment: id) else { continue }
                found[offset + 1] = Source(
                    title: hit.name, qualifier: hit.folder, when: hit.date,
                    speaker: hit.excerpt == nil
                        ? nil : QuickRecallRowModel.fileLead(hit, localize: app.settings.appLanguage.catalog),
                    line: QuickRecallQuote.line(hit.excerpt, question: question),
                    open: { FileSearchOpener.open(hit, query: question) })
            case .note:
                guard app.settings.codingAgentNotesEnabled, let id = citation.noteID else { continue }
                let index = app.agentNotesIndex
                guard let hit = await Task.detached(priority: .userInitiated, operation: { try? index.hit(id: id) }).value
                else { continue }
                found[offset + 1] = Source(
                    title: hit.title, qualifier: hit.sourceLabel, when: hit.modified,
                    line: QuickRecallQuote.line(hit.summary ?? hit.snippet, question: question),
                    open: { AgentNoteOpener.open(hit) })
            }
        }
        guard !Task.isCancelled else { return }
        sources = found
    }
}

/// The foot of an answer: where it was answered and what it read, Copy, and
/// the way into the full Ask screen.
struct QuickRecallAnswerFoot: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var model: ChatViewModel
    let continueInMainWindow: () -> Void
    @State private var copied = false

    var body: some View {
        let inference = InferencePresentation(settings: app.settings)
        let answer = latestAnswer
        HStack(spacing: 8) {
            // A "Remember …" receipt was saved here without any model.
            if model.messages.last?.rememberReceipt == nil {
                Image(systemName: inference == .onDevice ? "lock" : inference.icon)
                    .font(.system(size: 11))
                    .foregroundStyle(inference.isBlocked ? AnyShapeStyle(LBTokens.Palette.attentionText)
                                                         : AnyShapeStyle(.secondary))
                    .accessibilityHidden(true)
                Text(verbatim: QuickRecallAskScope.answerFootLabel(
                    inference: inference, isAnswered: answer != nil, scope: scopeLabel,
                    localize: app.settings.appLanguage.catalog))
                    .font(.scaled(.callout))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .accessibilityIdentifier("quickRecall.answer.place")
            }
            Spacer(minLength: 8)
            if let answer {
                Button { copy(answer) } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 13))
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .disabled(copied)
                .help(copied ? "Copied" : "Copy this answer")
                .accessibilityLabel(copied ? "Copied" : "Copy this answer")
                .accessibilityIdentifier("quickRecall.answer.copy")
            }
            Button("Continue in main window", action: continueInMainWindow)
                .accessibilityIdentifier("quickRecall.continue")
        }
        .padding(.leading, 22)
        .padding(.trailing, 12)
        .frame(minHeight: 46)
    }

    /// The text of the answer that ends the conversation, once it is written.
    private var latestAnswer: String? {
        guard let message = model.messages.last, message.role == .assistant,
              !message.isPending, !message.isError, message.rememberReceipt == nil else { return nil }
        let text = ChatCitationParser.extract(message.text).display
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// What the last question was limited to, in the words the Ask screen's
    /// sources menu uses: "All sources", one meeting's title, or how many
    /// meetings and screen moments.
    private var scopeLabel: String? {
        guard let question = model.messages.last(where: { $0.role == .user }) else { return nil }
        let summary = AskScopeSummary.make(
            .init(sources: question.sourceScopes.isEmpty ? AskSourceScope.defaults : Set(question.sourceScopes),
                  available: AskSourceScope.available(filesEnabled: app.settings.fileSearchEnabled,
                                                      agentNotesEnabled: app.settings.codingAgentNotesEnabled),
                  meetingIDs: question.meetingIDs, screenIDs: question.screenSnapshotIDs),
            meetingTitle: { id in app.meetings.first { $0.id == id }?.displayTitle },
            localize: app.settings.appLanguage.catalog)
        return summary.narrowedTo ?? summary.title
    }

    private func copy(_ text: String) {
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
}
