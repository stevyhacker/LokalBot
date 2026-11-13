import AppKit
import SwiftUI

/// Which citation's passage is showing, and where it was opened: at the
/// number in the answer's text, or at the number in the sources list.
struct OpenCitation: Equatable, Identifiable {
    enum Origin: Equatable {
        /// The clicked spot in the answer text, when it is known.
        case answer(CGRect?)
        case sources
    }

    var number: Int
    var origin: Origin

    var id: Int { number }
    var isFromAnswer: Bool {
        if case .answer = origin { return true }
        return false
    }
}

/// The list that ends an answer: a row per meeting, file, screen moment or
/// saved agent note it cited, with the answer's numbers and their times, and one row for what the
/// person told LokalBot about themselves when that went into the answer.
struct AnswerSourcesList: View {
    @EnvironmentObject private var app: AppState
    let citations: [ChatCitation]
    var claimIDs: [UUID] = []
    var personalModel: PersonalModelController?
    @Binding var open: OpenCitation?
    /// Cited files, looked up in the Files index.
    @State private var files: [Int64: FileSearchHit] = [:]
    /// Cited coding-agent notes, looked up in the saved notes.
    @State private var notes: [String: AgentNoteHit] = [:]

    var body: some View {
        let groups = AnswerSources.groups(citations) { files[$0]?.path }
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                if index > 0 { Divider() }
                sourceRow(group)
            }
            if !claimIDs.isEmpty, let personalModel {
                if !groups.isEmpty { Divider() }
                PersonalContextRow(claimIDs: claimIDs, personalModel: personalModel)
            }
        }
        .askCard(cornerRadius: LBTokens.Metric.groupRadius)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sources")
        .accessibilityIdentifier("chat.sources")
        .task(id: citations.compactMap(\.fileID)) { await loadCitedFiles() }
        .task(id: citations.compactMap(\.noteID)) { await loadCitedNotes() }
    }

    private func sourceRow(_ group: AnswerSourceGroup) -> some View {
        let source = resolved(group.first)
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                sourceName(group, source: source)
                Spacer(minLength: 8)
                HStack(spacing: 12) { citationGroups(group, available: source.available) }
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 10) { sourceName(group, source: source) }
                MeetingWrappingRow(spacing: 12, lineSpacing: 4) {
                    citationGroups(group, available: source.available)
                }
                .padding(.leading, 42)
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 12)
        .padding(.vertical, 7)
        .frame(minHeight: 36)
    }

    @ViewBuilder private func sourceName(_ group: AnswerSourceGroup, source: ResolvedSource) -> some View {
        lead(group, source: source)
        Button { openSource(group.first) } label: {
            Text(verbatim: source.title)
                .font(AppFont.scaled(.body).weight(.semibold))
                .foregroundStyle(source.available ? .primary : .secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .buttonStyle(AskTitleButtonStyle())
        .disabled(!source.available)
        .help(source.available ? source.openHelp : "")
        Text(verbatim: source.meta)
            .font(AppFont.scaled(.callout))
            .workspaceSupportingForeground()
            .lineLimit(1)
            .truncationMode(.head)
            .layoutPriority(-1)
    }

    @ViewBuilder private func lead(_ group: AnswerSourceGroup, source: ResolvedSource) -> some View {
        switch group.kind {
        case .meeting:
            AskSourceTile(symbol: "waveform", size: CGSize(width: 32, height: 22))
        case .screen:
            if let snapshotID = group.first.snapshotID, source.available {
                ScreenThumbnailView(snapshotID: snapshotID, height: 22, cornerRadius: 5)
                    .frame(width: 32)
                    .overlay {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .strokeBorder(LBTokens.Palette.groupStroke)
                    }
                    .accessibilityHidden(true)
            } else {
                AskSourceTile(symbol: "display", size: CGSize(width: 32, height: 22))
            }
        case .file:
            if let hit = group.first.fileID.flatMap({ files[$0] }) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: hit.path))
                    .resizable()
                    .frame(width: 20, height: 20)
                    .frame(width: 32, height: 22)
                    .accessibilityHidden(true)
            } else {
                AskSourceTile(symbol: "doc", size: CGSize(width: 32, height: 22))
            }
        case .note:
            AskSourceTile(symbol: "note.text", size: CGSize(width: 32, height: 22))
        }
    }

    /// Each number opens its passage here; a meeting time opens the meeting
    /// at that moment.
    @ViewBuilder private func citationGroups(_ group: AnswerSourceGroup, available: Bool) -> some View {
        ForEach(group.entries) { entry in
            HStack(spacing: 5) {
                CitationPill(number: entry.number, isOn: open?.number == entry.number) {
                    open = open?.number == entry.number ? nil : OpenCitation(number: entry.number, origin: .sources)
                }
                .popover(isPresented: sourcesPopover(entry.number), arrowEdge: .bottom) {
                    CitationPassagePopover(citation: entry.citation) { open = nil }
                }
                if entry.citation.kind == .meeting, let seconds = entry.citation.seconds {
                    Button { app.openCitation(entry.citation) } label: {
                        AskTimeStamp(seconds: seconds)
                            .padding(.vertical, 2)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!available)
                    .help("Open in meeting")
                    .accessibilityLabel("Open in meeting")
                    .accessibilityValue(Text(verbatim: Transcript.shortStamp(seconds)))
                }
            }
        }
    }

    private func sourcesPopover(_ number: Int) -> Binding<Bool> {
        Binding(
            get: { open == OpenCitation(number: number, origin: .sources) },
            set: { presented in
                if !presented, open == OpenCitation(number: number, origin: .sources) { open = nil }
            })
    }

    private func openSource(_ citation: ChatCitation) {
        switch citation.kind {
        case .meeting: app.openCitation(citation)
        case .screen:
            if let snapshotID = citation.snapshotID { app.openScreenSnapshot(snapshotID) }
        case .file:
            if let hit = citation.fileID.flatMap({ files[$0] }) { FileSearchOpener.open(hit, query: nil) }
        case .note:
            if let hit = citation.noteID.flatMap({ notes[$0] }) { AgentNoteOpener.open(hit) }
        }
    }

    private struct ResolvedSource {
        var title: String
        var meta: String
        var available: Bool
        var openHelp: LocalizedStringKey = "Open"
    }

    private func resolved(_ citation: ChatCitation) -> ResolvedSource {
        let language = app.settings.appLanguage
        let locale = language.locale
        switch citation.kind {
        case .meeting:
            guard let meeting = (try? SessionLookup.find(id: citation.meetingID, in: app.meetings)) ?? nil else {
                return .init(title: language.localized("Meeting"), meta: language.localized("Unavailable"), available: false)
            }
            return .init(title: meeting.displayTitle, meta: AskDateLabel.moment(meeting.startedAt, locale: locale),
                         available: true, openHelp: "Open in meeting")
        case .screen:
            guard let snapshotID = citation.snapshotID,
                  let shot = app.activityStore.screenshot(id: snapshotID) else {
                return .init(title: language.localized("Screen"), meta: language.localized("Unavailable"), available: false)
            }
            let when = AskDateLabel.moment(shot.ts, locale: locale)
            return .init(title: shot.windowTitle.isEmpty ? shot.app : shot.windowTitle,
                         meta: shot.windowTitle.isEmpty ? when : "\(shot.app) · \(when)",
                         available: true, openHelp: "Show in Timeline")
        case .file:
            guard let hit = citation.fileID.flatMap({ files[$0] }) else {
                return .init(title: language.localized("Files"), meta: language.localized("Unavailable"), available: false)
            }
            return .init(title: hit.name, meta: hit.folder, available: true)
        case .note:
            guard let hit = citation.noteID.flatMap({ notes[$0] }) else {
                return .init(title: language.localized("Agent note"), meta: language.localized("Unavailable"),
                             available: false)
            }
            return .init(title: hit.title, meta: "\(language.localized("Agent note")) · \(hit.sourceLabel)",
                         available: true)
        }
    }

    /// Notes are read only while Read coding agent notes is on, as on the
    /// rest of the page.
    private func loadCitedNotes() async {
        let ids = citations.compactMap(\.noteID)
        guard !ids.isEmpty, app.settings.codingAgentNotesEnabled else { return }
        let index = app.agentNotesIndex
        notes = await Task.detached(priority: .userInitiated) {
            var found: [String: AgentNoteHit] = [:]
            for id in ids {
                if let hit = try? index.hit(id: id) { found[id] = hit }
            }
            return found
        }.value
    }

    private func loadCitedFiles() async {
        let ids = citations.compactMap(\.fileID)
        guard !ids.isEmpty, app.settings.fileSearchEnabled else { return }
        var found: [Int64: FileSearchHit] = [:]
        for id in ids {
            if let hit = await app.fileSearch.hit(segment: id) { found[id] = hit }
        }
        files = found
    }
}

/// What the person told LokalBot about themselves that went into this answer.
/// Quick Recall's sources end with the same row.
struct PersonalContextRow: View {
    @EnvironmentObject private var app: AppState
    let claimIDs: [UUID]
    @ObservedObject var personalModel: PersonalModelController

    var body: some View {
        let told = claimIDs.map { id in
            personalModel.claim(id: id).map { "“\($0.text)”" }
                ?? app.settings.appLanguage.localized("Forgotten since this answer")
        }
        HStack(spacing: 10) {
            AskSourceTile(symbol: "person.crop.circle.badge.checkmark", size: CGSize(width: 32, height: 22))
            Text("You told LokalBot")
                .font(AppFont.scaled(.body).weight(.semibold))
                .lineLimit(1)
                .fixedSize()
            Text(verbatim: told.joined(separator: " · "))
                .font(AppFont.scaled(.callout))
                .workspaceSupportingForeground()
                .lineLimit(1)
                .help(told.joined(separator: "\n"))
            Spacer(minLength: 8)
            Button("Manage") {
                app.openSettings(tab: .personalContext)
                app.focusedSettingID = "settings.askMemoryEnabled"
            }
            .buttonStyle(.workspaceLink)
            .font(AppFont.scaled(.callout))
            .fixedSize()
        }
        .padding(.leading, 8)
        .padding(.trailing, 12)
        .padding(.vertical, 7)
        .frame(minHeight: 36)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.personalContext")
    }
}

/// A citation number as a small pill. Filled while its passage is showing.
struct CitationPill: View {
    let number: Int
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(verbatim: "\(number)")
                .font(AppFont.scaled(.subheadline).weight(.semibold).monospacedDigit())
                .foregroundStyle(isOn ? Color.white : LBTokens.Palette.accentText)
                .padding(.horizontal, 4)
                .frame(minWidth: 17, minHeight: 16)
                .background(isOn ? LBTokens.Palette.accentFill : LBTokens.Palette.accentFill.opacity(0.12),
                            in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                .padding(.vertical, 3)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Show the quoted passage")
        .accessibilityLabel("Source \(number)")
        .accessibilityHint("Show the quoted passage")
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .accessibilityIdentifier("chat.citation.\(number)")
    }
}

/// The passage a citation points at, read in place: the source, its time and
/// speaker, the quote, then a button to play from there or show the file,
/// and one to open the source. Nothing leaves Ask until one of those is used.
struct CitationPassagePopover: View {
    @EnvironmentObject private var app: AppState
    let citation: ChatCitation
    let dismiss: () -> Void
    @StateObject private var player = MeetingPlayer()
    @State private var content: Content = .loading

    private enum Content {
        case loading
        case meeting(Meeting, CitationPassage.Line?)
        case screen(ActivityStore.Screenshot, String?)
        case file(FileSearchHit)
        case note(AgentNoteHit)
        case unavailable
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch content {
            case .loading:
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: 60)
            case .meeting(let meeting, let line): meetingPassage(meeting, line: line)
            case .screen(let shot, let text): screenPassage(shot, text: text)
            case .file(let hit): filePassage(hit)
            case .note(let hit): notePassage(hit)
            case .unavailable:
                Text("Unavailable").workspaceSupportingForeground().frame(maxWidth: .infinity, minHeight: 40)
            }
        }
        .padding(14)
        .frame(width: 372, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.citation.passage")
        .task(id: citation.id) { await load() }
        .onDisappear { player.stop() }
    }

    // MARK: Kinds

    @ViewBuilder private func meetingPassage(_ meeting: Meeting, line: CitationPassage.Line?) -> some View {
        let locale = app.settings.appLanguage.locale
        let stamp = (line?.start ?? citation.seconds).map(Transcript.shortStamp)
        header(title: meeting.displayTitle,
               meta: [AskDateLabel.day(meeting.startedAt, locale: locale), stamp,
                      line.map { SpeakerDisplayName.label($0.speaker) }]) {
            AskSourceTile(symbol: "waveform")
        }
        if let line, let text = CitationPassage.quote(line.text) {
            quote("“\(text)”")
        }
        HStack(spacing: 8) {
            if let line, let stamp {
                let isPlaying = player.isPlaying
                Button {
                    if isPlaying { player.pause() } else { player.playExcerpt(from: line.start, to: line.end) }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 9))
                            .accessibilityHidden(true)
                        if isPlaying { Text("Pause") } else { Text("Play from \(stamp)") }
                    }
                }
                .disabled(!player.isLoaded || line.end <= line.start)
                .accessibilityIdentifier("chat.citation.play")
            }
            Spacer(minLength: 8)
            openLink("Open in meeting") { app.openCitation(citation) }
        }
    }

    @ViewBuilder private func screenPassage(_ shot: ActivityStore.Screenshot, text: String?) -> some View {
        let when = AskDateLabel.moment(shot.ts, locale: app.settings.appLanguage.locale)
        header(title: shot.windowTitle.isEmpty ? shot.app : shot.windowTitle,
               meta: [shot.windowTitle.isEmpty ? nil : shot.app, when]) {
            AskSourceTile(symbol: "display")
        }
        if shot.hasPixels {
            ScreenThumbnailView(screenshot: shot, height: 132, contentMode: .fit, cornerRadius: 7)
                .overlay {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(LBTokens.Palette.groupStroke)
                }
                .accessibilityHidden(true)
        }
        if let text = CitationPassage.quote(text, limit: 280) { quote(text) }
        HStack {
            Spacer(minLength: 8)
            openLink("Show in Timeline") { app.openScreenSnapshot(shot.id) }
        }
    }

    @ViewBuilder private func filePassage(_ hit: FileSearchHit) -> some View {
        header(title: hit.name,
               meta: [hit.folder, AskDateLabel.day(hit.date, locale: app.settings.appLanguage.locale)]) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: hit.path))
                .resizable()
                .frame(width: 26, height: 26)
                .frame(width: 44, height: 30)
                .accessibilityHidden(true)
        }
        if let text = CitationPassage.quote(hit.excerpt) { quote(text) }
        HStack(spacing: 8) {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([hit.url]) }
            Spacer(minLength: 8)
            openLink("Open") { FileSearchOpener.open(hit, query: nil) }
        }
    }

    /// A saved coding-agent note: what it says, and the agent's own file.
    @ViewBuilder private func notePassage(_ hit: AgentNoteHit) -> some View {
        header(title: hit.title,
               meta: [hit.sourceLabel, AskDateLabel.day(hit.modified, locale: app.settings.appLanguage.locale)]) {
            AskSourceTile(symbol: "note.text")
        }
        if let text = CitationPassage.quote(hit.summary ?? hit.snippet, limit: 280) { quote(text) }
        HStack(spacing: 8) {
            Button("Show in Finder") { AgentNoteOpener.reveal(hit) }
            Spacer(minLength: 8)
            openLink("Open") { AgentNoteOpener.open(hit) }
        }
    }

    // MARK: Parts

    private func header<Lead: View>(title: String, meta: [String?], @ViewBuilder lead: () -> Lead) -> some View {
        HStack(spacing: 10) {
            lead()
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: title)
                    .font(AppFont.scaled(.body).weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(verbatim: meta.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(AppFont.scaled(.callout))
                    .workspaceSupportingForeground()
                    .lineLimit(1)
                    .truncationMode(.head)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func quote(_ text: String) -> some View {
        Text(verbatim: text)
            .font(AppFont.scaledSystem(size: 13.5))
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, 10)
            .overlay(alignment: .leading) {
                LBTokens.Palette.accentFill.opacity(0.35).frame(width: 2)
            }
            .accessibilityIdentifier("chat.citation.quote")
    }

    private func openLink(_ title: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(title) {
            player.pause()
            dismiss()
            action()
        }
        .buttonStyle(.workspaceLink)
        .accessibilityIdentifier("chat.citation.open")
    }

    // MARK: Loading

    private func load() async {
        switch citation.kind {
        case .meeting:
            guard let meeting = (try? SessionLookup.find(id: citation.meetingID, in: app.meetings)) ?? nil else {
                content = .unavailable
                return
            }
            let folder = meeting.folderURL(in: app.storage)
            var line: CitationPassage.Line?
            if let seconds = citation.seconds {
                let lines = await Task.detached(priority: .userInitiated) {
                    CitationPassage.transcriptLines(in: folder)
                }.value
                line = CitationPassage.line(at: seconds, in: lines)
            }
            guard !Task.isCancelled else { return }
            content = .meeting(meeting, line)
            if line != nil {
                await player.loadInBackground(folder: folder, hasSystemTrack: meeting.hasSystemTrack)
            }
        case .screen:
            guard let snapshotID = citation.snapshotID,
                  let shot = app.activityStore.screenshot(id: snapshotID) else {
                content = .unavailable
                return
            }
            content = .screen(shot, app.activityStore.ocrText(snapshotID: snapshotID, maxChars: 1_200))
        case .file:
            guard app.settings.fileSearchEnabled, let id = citation.fileID,
                  let hit = await app.fileSearch.hit(segment: id) else {
                content = .unavailable
                return
            }
            content = .file(hit)
        case .note:
            guard app.settings.codingAgentNotesEnabled, let id = citation.noteID else {
                content = .unavailable
                return
            }
            let index = app.agentNotesIndex
            let hit = await Task.detached(priority: .userInitiated) { try? index.hit(id: id) }.value
            guard !Task.isCancelled else { return }
            content = hit.map(Content.note) ?? .unavailable
        }
    }
}

/// Finds where in an answer's text a citation number was clicked, so its
/// passage opens at the number. The answer is one selectable text, which has
/// no frame per link; the click that activated the link has a location.
@MainActor
final class CitationClickProbe {
    fileprivate weak var view: NSView?

    /// The clicked spot in the text's own coordinates, or nil when the link
    /// was not activated by a click inside it (the keyboard, VoiceOver).
    func clickRect() -> CGRect? {
        guard let view, let window = view.window, let event = NSApp.currentEvent,
              event.window === window,
              [.leftMouseUp, .leftMouseDown].contains(event.type) else { return nil }
        let point = view.convert(event.locationInWindow, from: nil)
        guard view.bounds.insetBy(dx: -4, dy: -4).contains(point) else { return nil }
        return CGRect(x: point.x - 9, y: point.y - 9, width: 18, height: 18)
    }
}

/// Sits behind the answer text and shares its bounds.
struct CitationClickProbeView: NSViewRepresentable {
    let probe: CitationClickProbe

    func makeNSView(context: Context) -> NSView {
        let view = ProbeView()
        probe.view = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) { probe.view = view }

    private final class ProbeView: NSView {
        // SwiftUI's coordinates start at the top leading corner.
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
