import Foundation

/// Where an answer for a phone goes: `AskSink` from the sync host.
protocol CompanionAskOutput: AnyObject, Sendable {
    func delta(_ text: String)
    func done(_ resultJSON: String)
    func failed(_ message: String)
}

/// Turns the agent's `[meeting:ID@HH:MM:SS]` markers into records.md's
/// `[n]` references and citation list. Screen citations stay text only.
enum CompanionAskCitations {
    static func map(_ answer: String, meetings: [Meeting]) -> (answer: String, citations: [CompanionAskResult.Citation]) {
        let extracted = ChatCitationParser.extract(answer)
        let citations = extracted.citations.enumerated().map { offset, citation -> CompanionAskResult.Citation in
            let index = offset + 1
            guard citation.kind == .meeting else {
                return .init(index: index, label: "Screen moment")
            }
            guard let meeting = resolve(citation.meetingID, in: meetings) else {
                return .init(index: index, at: citation.seconds, label: "Meeting")
            }
            let when = citation.seconds.map(clock)
                ?? meeting.startedAt.formatted(date: .abbreviated, time: .omitted)
            return .init(index: index, meetingId: CompanionJSON.id(meeting.id), at: citation.seconds,
                         label: "\(meeting.displayTitle) · \(when)")
        }
        return (extracted.display, citations)
    }

    /// The agent cites short ids (`SessionLookup.shortID`); a full UUID works
    /// too. Only an unambiguous match names a meeting.
    static func resolve(_ id: String, in meetings: [Meeting]) -> Meeting? {
        let needle = id.lowercased()
        if let uuid = UUID(uuidString: needle) { return meetings.first { $0.id == uuid } }
        let matches = meetings.filter { $0.id.uuidString.lowercased().hasPrefix(needle) }
        return matches.count == 1 ? matches[0] : nil
    }

    /// "12:04" within the first hour, "1:02:03" after it.
    static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let hours = total / 3600, minutes = (total % 3600) / 60, rest = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, rest)
            : String(format: "%d:%02d", minutes, rest)
    }
}

/// Converts the agent's growing answer into the next piece for the phone,
/// with citation markers already numbered. A partial that is not an
/// extension of what was sent (the agent restarted its answer) sends
/// nothing; the final result replaces the streamed text anyway.
final class CompanionAnswerStream {
    private(set) var sent = ""

    func next(_ partial: String) -> String? {
        let display = ChatCitationParser.extract(partial).display
        guard display.count > sent.count, display.hasPrefix(sent) else { return nil }
        let delta = String(display.dropFirst(sent.count))
        sent = display
        return delta
    }
}

/// Answers questions from paired devices with the same Ask agent, Think
/// engine and remote-inference approvals as Ask on the Mac. Tools are limited
/// to the classes the person shares: meetings, and the Timeline's activity
/// summary only when window titles are shared too, because it names windows.
/// Screen search, Dream memory and Personal Context are never used.
@MainActor
final class CompanionAskResponder {
    struct Dependencies {
        var settings: () -> AppSettings
        var makeEngine: () async throws -> TextEngine
        var tools: () -> ChatToolRunner
        var meetings: () -> [Meeting]
        var now: () -> Date = Date.init
    }

    private let dependencies: Dependencies
    private var tasks: [String: Task<Void, Never>] = [:]

    init(dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    static func scopes(for classes: CompanionSharing.DataClasses) -> Set<AskSourceScope> {
        var scopes: Set<AskSourceScope> = []
        if classes.meetings { scopes.insert(.meetings) }
        if classes.sharesWindowTitles { scopes.insert(.today) }
        return scopes
    }

    func answer(_ requestJSON: String, output: CompanionAskOutput) {
        guard let request = try? JSONDecoder().decode(CompanionAskRequest.self, from: Data(requestJSON.utf8)),
              !request.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            output.failed("Your Mac could not read this question.")
            return
        }
        let settings = dependencies.settings()
        let sharing = CompanionSharing(settings: settings)
        guard sharing.enabled, sharing.answersQuestions else {
            output.failed("Answering questions from your devices is turned off on your Mac.")
            return
        }
        let scopes = Self.scopes(for: sharing.dataClasses)
        guard !scopes.isEmpty else {
            output.failed("Your Mac shares no meetings or Timeline with this device, so it has nothing to answer from.")
            return
        }
        let now = dependencies.now()
        var meetingIDs: Set<UUID>?
        if sharing.history != .all {
            meetingIDs = Set(dependencies.meetings()
                .filter { CompanionLibrary.isShared($0, history: sharing.history, now: now, calendar: .current) }
                .map(\.id))
        }
        if let raw = request.scope?.meetingId {
            guard let id = UUID(uuidString: raw), meetingIDs?.contains(id) ?? true else {
                output.failed("That meeting is not shared with this device.")
                return
            }
            meetingIDs = [id]
        }
        var dayKey: String?
        if let day = request.scope?.day {
            guard AskDayScope.isCanonicalKey(day), let date = AskDayScope.date(for: day),
                  sharing.history.contains(date, now: now) else {
                output.failed("That day is not shared with this device.")
                return
            }
            dayKey = day
        }
        let history = (request.history ?? []).compactMap { turn in
            ChatRole(rawValue: turn.role).map { ChatAgent.Turn(role: $0, text: turn.text) }
        }
        let presentation = InferencePresentation(settings: settings)
        let engineLabel = settings.thinkModelDisplayName
        let dependencies = dependencies
        tasks[request.requestId]?.cancel()
        tasks[request.requestId] = Task { [weak self] in
            defer { self?.tasks[request.requestId] = nil }
            do {
                let engine = try await dependencies.makeEngine()
                try Task.checkCancellation()
                let runner = ScopedChatToolRunner(base: dependencies.tools(), scopes: scopes,
                                                  dayScopeKey: dayKey, meetingIDs: meetingIDs)
                var agent = ChatAgent(engine: engine, runner: runner)
                agent.adaptLimits(to: engine)
                let stream = CompanionAnswerStream()
                let answer = try await agent.respond(history: history, latest: request.question) { event in
                    guard case .answerPartial(let text) = event, let delta = stream.next(text) else { return }
                    output.delta(delta)
                }
                try Task.checkCancellation()
                let mapped = CompanionAskCitations.map(answer, meetings: dependencies.meetings())
                let result = CompanionAskResult(
                    requestId: request.requestId,
                    answer: mapped.answer,
                    citations: mapped.citations,
                    engineLabel: engineLabel,
                    location: presentation.isRemote ? "remote" : "mac",
                    answeredAt: CompanionJSON.instant(dependencies.now()))
                output.done(try CompanionJSON.encode(result))
            } catch is CancellationError {
                output.failed("Your Mac stopped answering this question.")
            } catch {
                lokalbotLog("companion ask failed: \(error.localizedDescription)")
                output.failed(ChatViewModel.friendlyFailureMessage(for: error))
            }
        }
    }

    func cancelAll() {
        for task in tasks.values { task.cancel() }
        tasks = [:]
    }
}
