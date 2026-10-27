import AppKit

/// Hands one meeting action to a coding agent installed on this Mac, with a
/// prompt already typed into its input box. Every route only fills the box:
/// nothing leaves this Mac until the user sends the prompt there.
enum ActionAgentHandoff: String, CaseIterable, Identifiable {
    case claudeCode = "Claude Code"
    case codex = "Codex"

    var id: String { rawValue }

    /// Claude Code's limit for a deep link's `q`. Codex documents no limit;
    /// it gets the same budget.
    static let promptCharacterLimit = 5_000

    enum Route: Equatable {
        /// `claude://code/new`: a new session in the Claude app's Code tab.
        case claudeDesktop
        /// `claude-cli://open`: Claude Code in a new window of the terminal
        /// it last ran in. Claude Code registers this handler itself after
        /// the first prompt of an interactive session.
        case claudeCodeTerminal
        /// `codex://new`: a new chat in the Codex app. The Codex CLI has no
        /// documented way to fill a prompt without sending it.
        case codexApp

        /// Each route's documented link. None sets a working folder, so the
        /// agent starts where it normally does rather than in the library.
        func url(prompt: String) -> URL? {
            let value = ExternalAgentHandoff.encodeQueryValue(prompt)
            return switch self {
            case .claudeDesktop: URL(string: "claude://code/new?q=\(value)")
            case .claudeCodeTerminal: URL(string: "claude-cli://open?q=\(value)")
            case .codexApp: URL(string: "codex://new?prompt=\(value)")
            }
        }
    }

    /// The first route something on this Mac handles, or nil. A desktop app
    /// wins over the terminal. `handler` returns the app registered for a link.
    func route(handler: (URL) -> URL?) -> Route? {
        let routes: [(String, Route)] = switch self {
        case .claudeCode: [("claude://code/new", .claudeDesktop), ("claude-cli://open", .claudeCodeTerminal)]
        case .codex: [("codex://new", .codexApp)]
        }
        return routes.first { URL(string: $0.0).flatMap(handler) != nil }?.1
    }
}

/// Installed targets, looked up at most once a minute: workspace menus
/// rebuild their items on every playback update, and Claude Code registers
/// its link handler only after its first interactive prompt.
@MainActor enum ActionAgentAvailability {
    private static var cache: (checkedAt: Date, routes: [ActionAgentHandoff: ActionAgentHandoff.Route])?

    static var installed: [ActionAgentHandoff] {
        let routes = routes()
        return ActionAgentHandoff.allCases.filter { routes[$0] != nil }
    }

    static func route(for target: ActionAgentHandoff) -> ActionAgentHandoff.Route? { routes()[target] }

    private static func routes(now: Date = Date()) -> [ActionAgentHandoff: ActionAgentHandoff.Route] {
        if let cache, now.timeIntervalSince(cache.checkedAt) < 60 { return cache.routes }
        var routes: [ActionAgentHandoff: ActionAgentHandoff.Route] = [:]
        for target in ActionAgentHandoff.allCases {
            routes[target] = target.route(handler: NSWorkspace.shared.urlForApplication(toOpen:))
        }
        cache = (now, routes)
        return routes
    }
}

/// What a handoff prompt says about one action: its details, and where each
/// meeting it came up in keeps its summary, notes, and transcript.
struct ActionHandoffBrief: Equatable {
    struct File: Equatable {
        var label: String
        var url: URL
    }

    struct Source: Equatable {
        var title: String
        var startedAt: Date
        var meetingID: String
        /// Where the action's first cited passage starts in the recording.
        var evidenceAt: TimeInterval?
        var folder: URL
        var files: [File]
    }

    var text: String
    var owner: String?
    var ownerIsUser: Bool
    var due: String?
    var dueDate: Date?
    var dueSaidOn: Date?
    var status: String
    /// Latest first.
    var sources: [Source]

    static let maximumSources = 5
    static let maximumTextCharacters = 1_000

    /// The meeting files an agent can read, labeled as the prompt names them.
    static let meetingFiles = [("Summary", "summary.md"), ("My notes", MeetingNotes.fileName),
                               ("Transcript", "transcript.md")]

    /// One source per meeting, latest first. `folder` resolves a meeting's
    /// folder, and files that don't exist yet are left out.
    static func sources(for references: [OutcomeActionReference], folder: (Meeting.ID) -> URL?,
                        fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> [Source] {
        var seen: Set<Meeting.ID> = []
        return references.sorted { $0.meetingStartedAt > $1.meetingStartedAt }.compactMap { reference -> Source? in
            guard seen.insert(reference.meetingID).inserted, let folder = folder(reference.meetingID) else { return nil }
            let files = meetingFiles.compactMap { label, name -> File? in
                let url = folder.appendingPathComponent(name)
                return fileExists(url) ? File(label: label, url: url) : nil
            }
            return Source(title: reference.meetingTitle, startedAt: reference.meetingStartedAt,
                          meetingID: SessionLookup.shortID(reference.meetingID),
                          evidenceAt: reference.action.citations.first?.start, folder: folder, files: files)
        }
    }
}

extension ActionAgentHandoff {
    /// A prompt the user can send as is. Older meetings are left out first
    /// when the prompt would pass `limit`.
    static func prompt(_ brief: ActionHandoffBrief, limit: Int = promptCharacterLimit,
                       timeZone: TimeZone = .current) -> String {
        var sources = Array(brief.sources.prefix(ActionHandoffBrief.maximumSources))
        while true {
            let text = render(brief, sources: sources, timeZone: timeZone)
            if text.count <= limit { return text }
            if sources.count > 1 { sources.removeLast(); continue }
            let cut = "\n\n[Cut short to fit.]"
            return String(text.prefix(limit - cut.count)) + cut
        }
    }

    private static func render(_ brief: ActionHandoffBrief, sources: [ActionHandoffBrief.Source],
                               timeZone: TimeZone) -> String {
        let day = formatter("yyyy-MM-dd", timeZone: timeZone)
        let time = formatter("EEE yyyy-MM-dd HH:mm", timeZone: timeZone)
        var text = brief.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count > ActionHandoffBrief.maximumTextCharacters {
            text = String(text.prefix(ActionHandoffBrief.maximumTextCharacters - 1)) + "…"
        }
        let owner = brief.ownerIsUser ? "me" : brief.owner?.trimmingCharacters(in: .whitespacesAndNewlines)
        var lines = [
            "Help me with this action item from a meeting I recorded in LokalBot.",
            "",
            "Action: \(text)",
            "Owner: \(owner.flatMap { $0.isEmpty ? nil : $0 } ?? "not clear")",
        ]
        if let due = brief.due?.trimmingCharacters(in: .whitespacesAndNewlines), !due.isEmpty {
            if let date = brief.dueDate {
                let resolved = day.string(from: date)
                lines.append(resolved == due ? "Due: \(resolved)" : "Due: \(resolved) (said “\(due)”)")
            } else {
                lines.append("Due: “\(due)”" + (brief.dueSaidOn.map { " (said on \(day.string(from: $0)))" } ?? ""))
            }
        }
        lines.append("Status: \(brief.status)")
        if brief.sources.count > 1 {
            lines += ["", sources.count == brief.sources.count
                ? "It came up in \(sources.count) meetings, newest first:"
                : "It came up in \(brief.sources.count) meetings. Here are the latest \(sources.count):"]
        }
        for source in sources {
            var heading = "Meeting: \(source.title), \(time.string(from: source.startedAt)) (LokalBot meeting ID \(source.meetingID))."
            if let evidenceAt = source.evidenceAt, source.files.contains(where: { $0.url.lastPathComponent == "transcript.md" }) {
                heading += " It comes up at [\(Transcript.stamp(evidenceAt))] in the transcript."
            }
            lines += ["", heading]
            lines += source.files.isEmpty
                ? ["- Folder: `\(source.folder.path)`"]
                : source.files.map { "- \($0.label): `\($0.url.path)`" }
        }
        if !sources.isEmpty {
            lines += ["", "These files are LokalBot's records of the meeting. Read them for the full context, but don't edit them."]
        }
        return lines.joined(separator: "\n")
    }

    private static func formatter(_ format: String, timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = format
        return formatter
    }
}

extension AppState {
    /// Opens `target` with a prompt for one action, or for every meeting an
    /// action thread came up in. `owner` is the name the row shows.
    func handOff(_ references: [OutcomeActionReference], text: String, owner: String?, ownerIsUser: Bool,
                 due: String?, dueDate: Date?, dueSaidOn: Date?, status: String, to target: ActionAgentHandoff) {
        let byID = Dictionary(meetings.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let brief = ActionHandoffBrief(
            text: text, owner: owner, ownerIsUser: ownerIsUser, due: due, dueDate: dueDate, dueSaidOn: dueSaidOn,
            status: status,
            sources: ActionHandoffBrief.sources(for: references) { byID[$0]?.folderURL(in: storage) })
        guard let url = ActionAgentAvailability.route(for: target)?.url(prompt: ActionAgentHandoff.prompt(brief)),
              NSWorkspace.shared.open(url) else {
            lastError = "Couldn't open \(target.rawValue)."
            return
        }
    }

    func handOff(_ reference: OutcomeActionReference, owner: String? = nil, to target: ActionAgentHandoff) {
        handOff([reference], text: reference.text,
                owner: owner ?? reference.owner.map { SpeakerDisplayName.label($0) },
                ownerIsUser: Self.isUserOwner(reference.owner, isForUser: reference.isForUser),
                due: reference.due, dueDate: reference.resolvedDueDate,
                dueSaidOn: reference.dueReferenceDate, status: reference.status.label, to: target)
    }

    func handOff(_ thread: ActionThread, to target: ActionAgentHandoff) {
        handOff(thread.references, text: thread.text, owner: thread.owner.map { SpeakerDisplayName.label($0) },
                ownerIsUser: Self.isUserOwner(thread.owner, isForUser: thread.isForUser),
                due: thread.due, dueDate: thread.resolvedDueDate,
                dueSaidOn: thread.dueReferenceDate, status: thread.statusLabel, to: target)
    }

    /// Rows show "You" only for an owner named "Me" on the user's own work.
    private static func isUserOwner(_ owner: String?, isForUser: Bool) -> Bool {
        isForUser && owner?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "me"
    }
}
