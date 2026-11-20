import Foundation

protocol CompanionAskOutput: AnyObject, Sendable {
    func delta(_ text: String)
    func done(_ resultJSON: String)
    func failed(_ message: String)
}

enum CompanionAskCitations {
    static func map(_ answer: String, meetings: [Meeting]) -> (answer: String, citations: [CompanionAskResult.Citation]) {
        let extracted = ChatCitationParser.extract(answer)
        let citations = extracted.citations.enumerated().map { offset, citation -> CompanionAskResult.Citation in
            let index = offset + 1
            switch citation.kind {
            case .meeting: break
            case .screen: return .init(index: index, label: "Screen moment")
            case .file: return .init(index: index, label: "File")
            case .note: return .init(index: index, label: "Agent note")
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

    static func resolve(_ id: String, in meetings: [Meeting]) -> Meeting? {
        let needle = id.lowercased()
        if let uuid = UUID(uuidString: needle) { return meetings.first { $0.id == uuid } }
        let matches = meetings.filter { $0.id.uuidString.lowercased().hasPrefix(needle) }
        return matches.count == 1 ? matches[0] : nil
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let hours = total / 3600, minutes = (total % 3600) / 60, rest = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, rest)
            : String(format: "%d:%02d", minutes, rest)
    }
}

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
        let meetingIDs = Set(dependencies.meetings()
            .filter { CompanionLibrary.isShared($0, history: sharing.history, now: now, calendar: .current) }
            .map(\.id))
        let historyIsLimited = sharing.history != .all
        let meetingScope = historyIsLimited
            ? "meetings from the \(sharing.history.displayName.lowercased()), "
                + "the history the user shares with this device"
            : nil
        let activityNotBefore = sharing.history.startOfWindow(now: now)
        var focus: [String] = []
        if let raw = request.scope?.meetingId {
            guard let id = UUID(uuidString: raw), meetingIDs.contains(id),
                  let meeting = dependencies.meetings().first(where: { $0.id == id }) else {
                output.failed("That meeting is not shared with this device.")
                return
            }
            focus.append("the meeting “\(meeting.displayTitle)” [\(SessionLookup.shortID(meeting.id))] "
                + "on \(meeting.startedAt.formatted(date: .abbreviated, time: .omitted))")
        }
        if let day = request.scope?.day {
            guard let dates = AskDateScope(storageKey: day), dates.firstDay == dates.lastDay,
                  let date = AskDayScope.date(for: day), sharing.history.contains(date, now: now) else {
                output.failed("That day is not shared with this device.")
                return
            }
            focus.append("the day \(dates.dateLabel)")
        }
        let startingPoint = focus.isEmpty ? nil : focus.joined(separator: " and ")
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
                                                  meetingIDs: meetingIDs, meetingScope: meetingScope,
                                                  namesMeetingLimit: historyIsLimited,
                                                  activityNotBefore: activityNotBefore,
                                                  focus: startingPoint)
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
