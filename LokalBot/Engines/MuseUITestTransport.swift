#if LOKALBOT_UI_TEST_HOST
import Foundation

/// UI-test host only. `LOKALBOT_MUSE_UI_TEST` puts Live Radar and
/// Follow-through in a mode the hosted UI suite can film:
/// - `1`: Meta Model API requests get scripted replies instead of reaching
///   api.meta.ai, so no key, network, or model is used. Replies follow the
///   demo call in `Docs/meta-hackathon/demo-script.md` and still pass through
///   `MuseChatClient` parsing and the radar's grounding checks: a
///   contradiction appears only if local search put the earlier passage in
///   the request.
/// - `live`: requests go to Meta with the key read from the file named by
///   `LOKALBOT_UI_TEST_META_API_KEY_FILE`, so the key never appears in the
///   test configuration or its result bundle.
/// In both modes approved Follow-through steps do not open Mail or Calendar.
/// Screen-answer requests (the ones carrying images) get the answer the
/// film's synthetic captures show, which still has to pass the quote check
/// against the crop Vision read in the host.
enum MuseUITestTransport {
    private static var mode: String? { ProcessInfo.processInfo.environment["LOKALBOT_MUSE_UI_TEST"] }
    static var isEnabled: Bool { mode == "1" || mode == "live" }
    static var isScripted: Bool { mode == "1" }

    /// The key for `live` mode, or a placeholder the scripted replies ignore.
    static var apiKey: String? {
        if isScripted { return "ui-test-key" }
        guard mode == "live", let path = ProcessInfo.processInfo.environment["LOKALBOT_UI_TEST_META_API_KEY_FILE"],
              let key = try? String(contentsOfFile: path, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else { return nil }
        return key
    }

    static func reply(to request: URLRequest) async throws -> (Data, URLResponse) {
        // Long enough for the in-flight states to be visible.
        try await Task.sleep(for: .milliseconds(1_200))
        let body = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any] ?? [:]
        let messages = body["messages"] as? [[String: Any]] ?? []
        let message = body["tools"] != nil ? followThrough(messages)
            : messages.last?["content"] is [[String: Any]] ? screenAnswer(messages) : radar(messages)
        let finish = message["tool_calls"] == nil ? "stop" : "tool_calls"
        let payload: [String: Any] = [
            "choices": [["finish_reason": finish, "message": message]],
            "usage": ["prompt_tokens": 1_400, "completion_tokens": 180,
                      "completion_tokens_details": ["reasoning_tokens": 60]],
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let response = HTTPURLResponse(url: request.url ?? MetaModelAPI.baseURL, statusCode: 200,
                                       httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        return (data, response)
    }

    // MARK: - Live Radar

    private struct Rule {
        let trigger: String
        let kind: String
        let text: String
        let owner: String
        let due: String
        /// For contradictions: words an earlier passage must contain.
        let conflictsWith: String?
    }

    private static let rules = [
        Rule(trigger: "send the revised pricing deck to Marko", kind: "commitment",
             text: "Send the revised pricing deck to Marko", owner: "Me", due: "by Friday", conflictsWith: nil),
        Rule(trigger: "trial-to-paid conversion last month", kind: "question",
             text: "What was trial-to-paid conversion last month?", owner: "", due: "", conflictsWith: nil),
        Rule(trigger: "the launch is Friday the seventh", kind: "contradiction",
             text: "Launch moved to Friday the 7th; Launch planning agreed Monday, November 3rd",
             owner: "", due: "", conflictsWith: "Monday"),
        Rule(trigger: "the launch is Friday the seventh", kind: "question",
             text: "Is the launch now Friday the 7th?", owner: "", due: "", conflictsWith: nil),
        Rule(trigger: "free tier limited to one project", kind: "contradiction",
             text: "Free tier cut to one project; Launch planning settled on three", owner: "", due: "",
             conflictsWith: "three projects"),
        Rule(trigger: "Marko will review the onboarding emails", kind: "commitment",
             text: "Review the onboarding emails", owner: "Marko", due: "before Wednesday", conflictsWith: nil),
        Rule(trigger: "twenty percent off for annual plans", kind: "decision",
             text: "Annual plans get 20% off", owner: "", due: "", conflictsWith: nil),
    ]

    private static func radar(_ messages: [[String: Any]]) -> [String: Any] {
        let prompt = messages.last?["content"] as? String ?? ""
        let sections = prompt.components(separatedBy: "\n\n")
        let newLines = sections.first { $0.hasPrefix("NEW LINES:") }?.split(separator: "\n").dropFirst() ?? []
        let earlier = sections.first { $0.hasPrefix("EARLIER MEETINGS") }?.split(separator: "\n").dropFirst() ?? []
        var items: [[String: String]] = []
        for line in newLines {
            guard let label = line.split(separator: " ").first?.dropFirst() else { continue }
            for rule in rules where line.localizedCaseInsensitiveContains(rule.trigger) {
                var evidence = ""
                if let words = rule.conflictsWith {
                    guard let passage = earlier.first(where: { $0.localizedCaseInsensitiveContains(words) }),
                          let id = passage.split(separator: " ").first else { continue }
                    evidence = String(id)
                }
                items.append(["kind": rule.kind, "text": rule.text, "owner": rule.owner, "due": rule.due,
                              "line": String(label), "quote": rule.trigger, "evidence": evidence])
            }
        }
        let content = (try? JSONSerialization.data(withJSONObject: ["items": items, "answered": [String]()]))
            .map { String(decoding: $0, as: UTF8.self) } ?? "{\"items\":[],\"answered\":[]}"
        return ["role": "assistant", "content": content]
    }

    // MARK: - Screen answers

    /// The captures are labelled "Image N: <app> — <window>"; the answer names
    /// the one that shows it.
    private static func screenAnswer(_ messages: [[String: Any]]) -> [String: Any] {
        let texts = (messages.last?["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }
        let question = texts.first ?? ""
        let labels = texts.filter { $0.hasPrefix("Image ") }
        func image(from app: String) -> Int? { labels.firstIndex { $0.contains(app) }.map { $0 + 1 } }
        var answer: [String: Any] = ["answer": "", "image": 0, "quote": ""]
        if question.localizedCaseInsensitiveContains("conversion"), let index = image(from: "Safari") {
            answer = ["answer": "4.1% in September", "image": index, "quote": "Trial to paid, September 4.1%"]
        } else if question.localizedCaseInsensitiveContains("launch"), let index = image(from: "Notion") {
            answer = ["answer": "Monday, November 3", "image": index, "quote": "Launch Monday, November 3"]
        }
        let content = (try? JSONSerialization.data(withJSONObject: answer)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        return ["role": "assistant", "content": content]
    }

    // MARK: - Follow-through

    private static func followThrough(_ messages: [[String: Any]]) -> [String: Any] {
        let briefing = messages.first { $0["role"] as? String == "user" }?["content"] as? String ?? ""
        let turn = messages.filter { $0["role"] as? String == "assistant" }.count
        let name = briefing.components(separatedBy: "The person (\"Me\") is ").dropFirst().first?
            .components(separatedBy: ".").first ?? "[your name]"
        let meetingID = briefing.components(separatedBy: "meeting id ").dropFirst().first?
            .prefix { $0.isLetter || $0.isNumber } ?? "latest"
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'10:00"
        let start = formatter.string(from: tomorrow)
        let call: (name: String, arguments: [String: Any])?
        switch turn {
        case 0:
            call = ("get_meeting", ["id": String(meetingID), "include": "summary"])
        case 1:
            call = ("draft_email", [
                "to": ["Marko"], "cc": [String](), "subject": "Revised pricing deck",
                "body": """
                Hi Marko,

                As promised, here is the revised pricing deck: [link to Pricing v2]. Annual plans now get 20% off.

                Two points are still open, and I'll confirm them after I talk with Ana tomorrow:
                - Launch date: Monday, November 3rd (our planning meeting) or Friday the 7th
                - Free tier: three projects or one

                Thanks,
                \(name)
                """,
                "why": "You promised Marko the deck by Friday; the email flags what is still undecided.",
            ])
        case 2:
            call = ("propose_meeting", [
                "title": "Settle launch date and free tier", "start": start,
                "duration_minutes": 30, "attendees": ["Ana"],
                "agenda": "1. Launch: Monday 3 Nov or Friday 7 Nov\n2. Free tier: three projects or one",
                "why": "The call left both conflicts to settle with Ana tomorrow.",
            ])
        case 3:
            call = ("finish", ["summary": "Drafted the deck email to Marko and proposed a meeting with Ana to settle "
                + "the launch date and free tier. Attach Pricing v2 before you send it."])
        default:
            call = nil
        }
        guard let call, let arguments = try? JSONSerialization.data(withJSONObject: call.arguments) else {
            return ["role": "assistant", "content": "Done."]
        }
        return ["role": "assistant", "content": "",
                "tool_calls": [["id": "call_\(turn)", "type": "function",
                                "function": ["name": call.name,
                                             "arguments": String(decoding: arguments, as: UTF8.self)]]]]
    }
}
#endif
