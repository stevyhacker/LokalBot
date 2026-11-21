import AppKit

enum ExternalAgentHandoff: String, CaseIterable {
    case claude = "Claude"
    case codex = "Codex"

    static let promptCharacterLimit = 12_000

    static let installed: [ExternalAgentHandoff] = allCases.filter { target in
        URL(string: "\(target.scheme)://").flatMap(NSWorkspace.shared.urlForApplication(toOpen:)) != nil
    }

    private var scheme: String {
        switch self {
        case .claude: "claude"
        case .codex: "codex"
        }
    }

    func url(prompt: String) -> URL? {
        let (base, key) = switch self {
        case .claude: ("claude://claude.ai/new", "q")
        case .codex: ("codex://new", "prompt")
        }
        return URL(string: "\(base)?\(key)=\(Self.encodeQueryValue(prompt))")
    }

    @MainActor func open(prompt: String) -> Bool {
        guard let url = url(prompt: prompt) else { return false }
        return NSWorkspace.shared.open(url)
    }

    static func encodeQueryValue(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreservedCharacters) ?? ""
    }

    private static let unreservedCharacters = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    static func prompt(for meeting: Meeting, limit: Int = promptCharacterLimit) -> String {
        prompt(meetingID: SessionLookup.shortID(meeting.id), limit: limit) { transcriptCharacters in
            SessionFormatter.getMarkdown(meeting, options: .init(
                includeSummary: true,
                includeTranscript: transcriptCharacters != nil,
                includeMetadata: true,
                transcriptCharacters: transcriptCharacters))
        }
    }

    static func prompt(meetingID: String, limit: Int, notes: (Int?) -> String) -> String {
        let intro = "Here are my notes from a meeting recorded in LokalBot (meeting ID \(meetingID)).\n\n"
        let withoutTranscript = notes(nil)
        let room = limit - intro.count - withoutTranscript.count - 200
        let body = room >= 1_000 ? notes(room) : withoutTranscript
        let text = intro + body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count > limit else { return text }
        let cut = "\n\n[Cut short to fit.]"
        return String(text.prefix(limit - cut.count)) + cut
    }
}
