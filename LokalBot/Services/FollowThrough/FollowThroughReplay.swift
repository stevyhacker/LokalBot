import Foundation

/// `LokalBot --follow-through-replay <fixture.json> [--model <id>]`
///
/// Runs Follow-through's real loop and Meta Model API client against a
/// fixture meeting: read tools answer from the fixture, and every proposal is
/// recorded and approved without being carried out. Prints one JSON line per
/// step and a summary. For synthetic fixtures only: the key is read from
/// `META_API_KEY`, and no library, Keychain, mail, or calendar is touched.
enum FollowThroughReplay {
    struct Fixture: Decodable {
        struct Action: Decodable {
            let text: String
            let owner: String?
            let due: String?
            let evidence: [String]
        }

        struct Passage: Decodable {
            let id: String
            let title: String
            let date: String
            let text: String
        }

        let title: String
        let date: Date
        let attendees: [String]?
        let personName: String?
        let action: Action
        let summary: String
        let transcript: [String]
        let library: [Passage]
    }

    static func parse(_ args: [String]) -> (input: URL, model: String)? {
        guard let flag = args.firstIndex(of: "--follow-through-replay"), args.count > flag + 1 else { return nil }
        let model = args.firstIndex(of: "--model").flatMap { args.count > $0 + 1 ? args[$0 + 1] : nil }
        return (URL(fileURLWithPath: args[flag + 1]), model ?? MetaModelAPI.museWonder.id)
    }

    @MainActor
    final class Environment: FollowThroughEnvironment {
        let fixture: Fixture
        var codingAgents: [ActionAgentHandoff] = [.claudeCode]

        init(fixture: Fixture) { self.fixture = fixture }

        var readToolSpecs: [ChatToolSpec] {
            MeetingChatTools.specs.filter { FollowThroughTools.readTools.contains($0.name) }
        }

        func runReadTool(_ call: ChatToolCall) async -> ChatToolResult {
            switch call.name {
            case "search_meetings":
                let words = Set((call.string("query") ?? "").lowercased().split(separator: " ").map(String.init)
                    .filter { $0.count > 3 })
                let hits = fixture.library.filter { passage in
                    words.contains { passage.text.lowercased().contains($0) || passage.title.lowercased().contains($0) }
                }
                let text = hits.isEmpty ? "No matches." : hits.map { "- [\($0.id)] \($0.title) — \($0.date): \($0.text)" }
                    .joined(separator: "\n")
                return ChatToolResult(text: text, summary: "\(hits.count) matches")
            case "get_meeting":
                return ChatToolResult(text: "# \(fixture.title)\n\n\(fixture.summary)\n\nTranscript:\n"
                    + fixture.transcript.joined(separator: "\n"), summary: fixture.title)
            default:
                return ChatToolResult(text: "No other open actions.", summary: "0 actions")
            }
        }

        func perform(_ proposal: FollowThroughProposal, for target: FollowThroughTarget) async throws -> String {
            "Recorded by the replay; nothing was opened."
        }
    }

    @MainActor
    static func run(input: URL, model: String) async -> Int32 {
        let key = ProcessInfo.processInfo.environment["META_API_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !key.isEmpty else {
            FileHandle.standardError.write(Data("follow-through-replay: set META_API_KEY\n".utf8))
            return 2
        }
        let fixture: Fixture
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            fixture = try decoder.decode(Fixture.self, from: Data(contentsOf: input))
        } catch {
            FileHandle.standardError.write(Data("follow-through-replay: \(error.localizedDescription)\n".utf8))
            return 2
        }
        let target = FollowThroughTarget(
            meetingID: UUID(), meetingTitle: fixture.title, meetingDate: fixture.date, actionID: "a1",
            text: fixture.action.text, owner: fixture.action.owner, due: fixture.action.due,
            evidence: fixture.action.evidence)
        var meeting = Meeting(id: target.meetingID, title: fixture.title, appName: "Replay",
                              startedAt: fixture.date, relativePath: "replay")
        meeting.participantNameHints = fixture.attendees
        let briefing = FollowThroughBriefing.make(target: target, meeting: meeting, summary: fixture.summary,
                                                  radar: nil, personName: fixture.personName ?? "")

        let client = MuseChatClient(apiKey: key, model: model, reasoningEffort: "low", maxTokens: 8_000,
                                    priority: .agent, purpose: "follow-through replay")
        let started = ContinuousClock.now
        var turns = 0
        let session = FollowThroughSession(
            target: target, briefing: briefing, model: model, environment: Environment(fixture: fixture),
            call: { messages, tools in
                turns += 1
                return try await client.send(messages: messages, tools: tools)
            })
        session.start()
        var reported = 0
        while true {
            try? await Task.sleep(for: .milliseconds(50))
            while reported < session.steps.count {
                print(json(describe(session.steps[reported])))
                reported += 1
            }
            if session.state == .waitingForApproval,
               case .proposal(let proposal)? = session.steps.last, proposal.status == .pending {
                session.approve(proposal)
            }
            if session.state == .finished { break }
            if case .failed(let message) = session.state {
                FileHandle.standardError.write(Data("follow-through-replay failed: \(message)\n".utf8))
                return 1
            }
        }
        let elapsed = (ContinuousClock.now - started).components
        print(json(["summary": [
            "model": model, "turns": turns, "steps": session.steps.count,
            "proposals": session.steps.filter { if case .proposal = $0 { true } else { false } }.count,
            "seconds": Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18,
            "inputTokens": session.usage.inputTokens, "outputTokens": session.usage.outputTokens,
            "reasoningTokens": session.usage.reasoningTokens, "cost": session.cost,
            "finalSummary": session.summary ?? "",
        ] as [String: Any]]))
        return 0
    }

    private static func describe(_ step: FollowThroughSession.Step) -> [String: Any] {
        switch step {
        case .read(_, let tool, let summary):
            return ["read": tool, "result": summary]
        case .note(_, let text):
            return ["note": text]
        case .proposal(let proposal):
            var result: [String: Any] = ["proposal": proposal.title, "why": proposal.rationale]
            switch proposal.kind {
            case .email(let to, let cc, let subject, let body):
                result["to"] = to
                result["cc"] = cc
                result["subject"] = subject
                result["body"] = body
            case .event(let title, let start, let minutes, let attendees, let notes):
                result["title"] = title
                result["start"] = start.formatted(.iso8601)
                result["minutes"] = minutes
                result["attendees"] = attendees
                result["agenda"] = notes
            case .codingTask(let agent, let prompt):
                result["agent"] = agent.rawValue
                result["prompt"] = prompt
            case .markDone(let note):
                result["note"] = note
            }
            return result
        }
    }

    private static func json(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}
