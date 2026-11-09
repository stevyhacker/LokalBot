import Foundation

/// The answer to a question or problem raised in the call, found in the
/// person's own work while the call goes on. Built for the Meta Global AI
/// Developer Hackathon (2026).
struct RadarAnswer: Codable, Equatable, Sendable {
    struct Source: Codable, Equatable, Identifiable, Sendable {
        enum Kind: String, Codable, Sendable {
            case memory, project, action, meeting, screen, document, code, commit, pullRequest, issue
        }

        var kind: Kind
        /// A file line, `#398`, a meeting, a document name.
        var title: String
        /// Words from the source, as read; the answer was kept because they are there.
        var quote: String
        /// A GitHub or file URL to open.
        var link: String?
        var meetingID: UUID?
        var time: Double?

        var id: String { "\(kind.rawValue)|\(title)|\(quote)" }
    }

    var text: String
    var sources: [Source]
    var model: String
    /// From the question being caught to the answer.
    var seconds: Double
    /// Where it looked, in order, for the card's "how it found this".
    var steps: [String]
}

/// The meeting a question came from, as the answer prompt sees it.
struct LiveAnswerMeeting: Sendable {
    var title: String
    var date: Date
    /// The last few lines before the question, as "Me: …" and "Others: …".
    var recentLines: [String]
}

/// Context labelled for citing: what LokalBot already remembers, given to
/// the model up front.
struct LiveAnswerContext: Sendable {
    var kind: RadarAnswer.Source.Kind
    var title: String
    var text: String
    var meetingID: UUID?
}

/// Where live answers read: the memory given up front, the library's own
/// tools (meetings, actions, screen text), and the person's folders.
@MainActor
protocol LiveAnswerEnvironment: AnyObject {
    func context(for question: String, meeting: LiveAnswerMeeting) async -> [LiveAnswerContext]
    func places() async -> [LiveAnswerPlace]
    var libraryToolSpecs: [ChatToolSpec] { get }
    func runLibraryTool(_ call: ChatToolCall) async -> LiveAnswerToolOutput
}

/// One live answer: memory first, then up to a few read-only tool calls, on
/// the Muse model chosen in Settings (Wonder by default). Every source the
/// answer cites must contain its quote, checked here against what the tools
/// returned, so an answer can't rest on something nobody read.
enum LiveAnswerSession {
    typealias Call = @MainActor (_ messages: [[String: Any]], _ tools: [[String: Any]], _ model: String)
        async throws -> MuseChatClient.Reply

    static let maximumTurns = 6
    static let timeout: Duration = .seconds(60)

    struct Outcome: Sendable {
        var answer: RadarAnswer?
        var usage = MuseChatClient.Usage()
        var turns = 0
        var seconds = 0.0
        /// Why there is no answer: the model's reason, or what failed.
        var reason: String?
        var steps: [String] = []
    }

    static let system = """
    You find the answer to a question or problem that just came up in a live meeting, from the work of the person \
    using LokalBot. They are still in the call, so be quick.

    1. Start from LOKALBOT REMEMBERS: their projects and where each stands, their open actions, what they told \
    LokalBot about themselves, and their work memory. If it already answers the question, answer at once.
    2. Otherwise look it up, with as few calls as you can (at most four): earlier meetings, what they saw on screen, \
    documents and sheets in their folders, and code, commits, pull requests, and issues in their repositories. Prefer \
    one precise call to several broad ones.
    3. Check before answering: a number, date, name, or status must come from something you read just now or from \
    LOKALBOT REMEMBERS, not from the conversation or your own knowledge.

    Reply with the answer tool: one or two short sentences the person could say out loud, and one to three sources. \
    Each source gives the id in brackets of what you read ([C1], [R2], …) and words copied exactly from it that \
    support the answer. If their work can't answer it (an opinion, small talk, a plan nobody made yet), or you \
    can't find it, call no_answer. Never guess.
    """

    static func prompt(question: String, quote: String, meeting: LiveAnswerMeeting,
                       context: [(label: String, item: LiveAnswerContext)], places: [LiveAnswerPlace]) -> String {
        var parts = ["MEETING: \(meeting.title), \(meeting.date.formatted(date: .complete, time: .shortened))"]
        if !meeting.recentLines.isEmpty {
            parts.append("RECENT LINES:\n" + meeting.recentLines.joined(separator: "\n"))
        }
        parts.append("QUESTION: \(question)" + (quote.isEmpty || quote == question ? "" : " (said: “\(quote)”)"))
        if context.isEmpty {
            parts.append("LOKALBOT REMEMBERS: nothing relevant.")
        } else {
            let blocks = context.map { entry -> String in "[\(entry.label)] \(entry.item.title)\n\(entry.item.text)" }
            parts.append("LOKALBOT REMEMBERS:\n" + blocks.joined(separator: "\n\n"))
        }
        if places.isEmpty {
            parts.append("FOLDERS: none shared, so documents and code can't be read.")
        } else {
            parts.append("FOLDERS YOU MAY READ:\n" + places.map(describe).joined(separator: "\n"))
        }
        return parts.joined(separator: "\n\n")
    }

    private static func describe(_ place: LiveAnswerPlace) -> String {
        guard place.isRepository else { return "- \(place.name)" }
        let remote = place.gitHub.map { ", github.com/\($0)" } ?? ""
        return "- \(place.name) (git repository\(remote))"
    }

    static let libraryTools: Set<String> = ["search_meetings", "get_meeting", "get_action_items", "search_screen"]

    static func definitions(libraryTools specs: [ChatToolSpec], places: [LiveAnswerPlace]) -> [[String: Any]] {
        var tools = specs.filter { libraryTools.contains($0.name) }.map { spec in
            LiveAnswerTools.function(spec.name, spec.summary, Dictionary(uniqueKeysWithValues: spec.arguments.map {
                ($0.name, ["type": "string", "description": $0.description] as [String: Any])
            }), required: spec.arguments.filter(\.required).map(\.name))
        }
        tools += LiveAnswerTools.definitions(places: places)
        tools.append(LiveAnswerTools.function(
            "answer", "The answer, with the sources it rests on.",
            ["text": ["type": "string", "description": "One or two short sentences."],
             "sources": ["type": "array", "items": [
                "type": "object",
                "properties": ["id": ["type": "string", "description": "The bracketed id, like C1 or R2."],
                               "quote": ["type": "string", "description": "Words copied exactly from that source."]],
                "required": ["id", "quote"]] as [String: Any]]],
            required: ["text", "sources"]))
        tools.append(LiveAnswerTools.function(
            "no_answer", "Their work doesn't answer this, or it isn't something to look up.",
            ["reason": ["type": "string"]], required: ["reason"]))
        return tools
    }

    @MainActor
    static func run(question: String, quote: String, meeting: LiveAnswerMeeting, environment: LiveAnswerEnvironment,
                    model: String, call: Call, progress: @escaping (String) -> Void) async throws -> Outcome {
        let started = ContinuousClock.now
        var outcome = Outcome()
        func finish() -> Outcome {
            let elapsed = (ContinuousClock.now - started).components
            outcome.seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
            return outcome
        }

        progress(String(localized: "Checking what LokalBot remembers…"))
        var references: [String: LiveAnswerToolOutput] = [:]
        let context = await environment.context(for: question, meeting: meeting).enumerated().map { index, item in
            (label: "C\(index + 1)", item: item)
        }
        for entry in context {
            references[entry.label] = LiveAnswerToolOutput(text: entry.item.text, kind: entry.item.kind,
                                                           title: entry.item.title, meetingID: entry.item.meetingID)
        }
        let places = await environment.places()
        let tools = definitions(libraryTools: environment.libraryToolSpecs, places: places)
        var messages: [[String: Any]] = [
            ["role": "system", "content": system],
            ["role": "user", "content": prompt(question: question, quote: quote, meeting: meeting,
                                               context: context, places: places)],
        ]
        var nextReference = 1

        for turn in 0..<maximumTurns {
            try Task.checkCancellation()
            if ContinuousClock.now - started > timeout {
                outcome.reason = "took too long"
                return finish()
            }
            if turn == maximumTurns - 1 {
                messages.append(["role": "user", "content": "Answer now with what you have read, or call no_answer."])
            }
            let reply = try await call(messages, tools, model)
            outcome.usage = outcome.usage + reply.usage
            outcome.turns += 1
            messages.append(MuseChatClient.assistantMessage(for: reply))
            guard !reply.toolCalls.isEmpty else {
                outcome.reason = "no tool call"
                return finish()
            }
            for toolCall in reply.toolCalls {
                let arguments = toolCall.decodedArguments
                switch toolCall.name {
                case "answer":
                    if let answer = ground(arguments, references: references, model: model, steps: outcome.steps) {
                        outcome.answer = answer
                    } else {
                        outcome.reason = "no source contained its quote"
                    }
                    var done = finish()
                    done.answer?.seconds = done.seconds
                    return done
                case "no_answer":
                    outcome.reason = arguments["reason"] as? String ?? "no answer"
                    return finish()
                default:
                    let step = stepText(toolCall.name, arguments)
                    progress(step)
                    // The card lists the steps once it has an answer, without the ellipsis.
                    outcome.steps.append(step.hasSuffix("…") ? String(step.dropLast()) : step)
                    let output: LiveAnswerToolOutput
                    if libraryTools.contains(toolCall.name) {
                        let call = ChatToolCall(name: toolCall.name, arguments: arguments.compactMapValues { value in
                            (value as? String) ?? (value as? Int).map(String.init)
                        })
                        output = await environment.runLibraryTool(call)
                    } else if LiveAnswerTools.names.contains(toolCall.name) {
                        output = await LiveAnswerTools.run(toolCall.name, arguments, places: places)
                    } else {
                        output = .message("Unknown tool \(toolCall.name).")
                    }
                    var text = String(output.text.prefix(LiveAnswerTools.outputCharacters))
                    if output.kind != nil {
                        let label = "R\(nextReference)"
                        nextReference += 1
                        references[label] = output
                        text = "[\(label)] \(output.title)\n" + text
                    }
                    messages.append(MuseChatClient.toolResultMessage(callID: toolCall.id, content: text))
                }
            }
        }
        outcome.reason = "ran out of turns"
        return finish()
    }

    /// What the card says before a tool finishes.
    static func stepText(_ name: String, _ arguments: [String: Any]) -> String {
        let query = (arguments["query"] as? String).map { "“\($0)”" } ?? ""
        switch name {
        case "search_meetings": return String(localized: "Searching your meetings for \(query)…")
        case "get_meeting": return String(localized: "Reading a meeting…")
        case "get_action_items": return String(localized: "Checking your actions…")
        case "search_screen": return String(localized: "Searching what you saw on screen for \(query)…")
        case "search_documents": return String(localized: "Searching your documents for \(query)…")
        case "read_document": return String(localized: "Reading \(((arguments["path"] as? String ?? "") as NSString).lastPathComponent)…")
        case "search_code": return String(localized: "Searching the code for \(query)…")
        case "read_file": return String(localized: "Reading \(((arguments["path"] as? String ?? "") as NSString).lastPathComponent)…")
        case "recent_commits": return String(localized: "Reading recent commits…")
        case "github": return String(localized: "Checking GitHub…")
        default: return String(localized: "Looking it up…")
        }
    }

    /// The answer, keeping only sources whose quote is in what they name.
    /// A source inside a multi-line result takes the line it was found on
    /// (a file line, a commit, a pull request) as its title and link.
    static func ground(_ arguments: [String: Any], references: [String: LiveAnswerToolOutput], model: String,
                       steps: [String]) -> RadarAnswer? {
        guard let text = (arguments["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
              let cited = arguments["sources"] as? [[String: Any]] else { return nil }
        var sources: [RadarAnswer.Source] = []
        for entry in cited {
            let label = (entry["id"] as? String ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "[] ")).uppercased()
            guard let reference = references[label], let kind = reference.kind,
                  let quote = (entry["quote"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  quoteIsIn(quote, text: reference.text) else { continue }
            var source = RadarAnswer.Source(kind: kind, title: reference.title, quote: quote, link: reference.link,
                                            meetingID: reference.meetingID, time: reference.time)
            if let line = reference.lines.first(where: { quoteIsIn(quote, text: $0.text) }) {
                source.title = line.title
                source.link = line.link ?? source.link
            }
            if !sources.contains(where: { $0.id == source.id }) { sources.append(source) }
        }
        guard !sources.isEmpty else { return nil }
        return RadarAnswer(text: text, sources: Array(sources.prefix(3)), model: model, seconds: 0, steps: steps)
    }

    /// The radar's rule for quotes: the whole quote after normalizing, or
    /// most of a longer quote's words on one line.
    static func quoteIsIn(_ quote: String, text: String) -> Bool {
        RadarScreenAnswers.quoteIsOnScreen(quote, text: text)
    }
}
