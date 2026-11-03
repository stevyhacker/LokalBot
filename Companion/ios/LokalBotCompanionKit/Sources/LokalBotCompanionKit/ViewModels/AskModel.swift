import Foundation
import Observation

/// Questions answered by the Mac, the conversation they belong to, and what to
/// offer when the Mac can't be reached.
@MainActor @Observable
public final class AskModel {
    public struct Turn: Identifiable, Hashable, Sendable {
        public enum State: Hashable, Sendable {
            case answering
            case answered
            /// Waiting to be sent the next time the Mac is reachable.
            case queued
            /// The Mac didn't answer; the phone offers its own search and the queue.
            case macUnreachable
            /// The connection dropped while the Mac answered. It keeps
            /// answering, and the turn picks the answer up on return.
            case waiting
            case failed(String)
        }

        public var request: AskRequest
        public var answer: String
        public var result: AskResult?
        public var state: State
        public var askedAt: Date
        /// "Search this device" results for this question.
        public var localResults: [SearchHit]?
        /// The connection dropped once while the Mac answered, so the
        /// question is queued.
        public var interrupted = false
        /// Picking up an answer: the next delta is the whole text so far.
        var restartText = false

        public var id: String { request.requestId }
    }

    public struct Conversation: Identifiable, Hashable, Sendable {
        public let id: String
        public var turns: [Turn]

        public var title: String { turns.first?.request.question ?? "New question" }
        public var updatedAt: Date { turns.last?.askedAt ?? .distantPast }
    }

    public private(set) var conversations: [Conversation] = []
    public var currentID: String?
    public var draft = ""
    /// Narrows the next question to a day or a meeting.
    public var scope: AskRequest.Scope?
    public private(set) var loaded = false

    public init() {}

    public var current: Conversation? {
        conversations.first { $0.id == currentID }
    }

    public var isAnswering: Bool {
        current?.turns.contains { $0.state == .answering } == true
    }

    public var canSubmit: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isAnswering
    }

    // MARK: Loading

    /// Ask history and queued questions from the store, keeping turns that
    /// exist only in memory (answering, unreachable, failed).
    public func load(_ session: CompanionSession) async {
        let history = (try? await session.store.askHistory(limit: 500)) ?? []
        let queued = (try? await session.store.queuedQuestions()) ?? []
        var turnsByConversation: [String: [Turn]] = [:]
        for exchange in history {
            turnsByConversation[exchange.request.conversationId, default: []].append(Turn(
                request: exchange.request, answer: exchange.result.answer, result: exchange.result,
                state: .answered, askedAt: exchange.result.answeredAt))
        }
        let saved = Set(history.map(\.request.requestId))
        for request in queued where !saved.contains(request.requestId) {
            // An interrupted turn keeps its partial answer and its state.
            if let memory = memoryTurn(request.requestId), memory.interrupted {
                turnsByConversation[request.conversationId, default: []].append(memory)
                continue
            }
            turnsByConversation[request.conversationId, default: []].append(Turn(
                request: request, answer: "", result: nil, state: .queued,
                askedAt: memoryTurn(request.requestId)?.askedAt ?? Date()))
        }
        let known = saved.union(queued.map(\.requestId))
        for conversation in conversations {
            for turn in conversation.turns where !known.contains(turn.id) && turn.state != .queued && turn.state != .answered {
                turnsByConversation[conversation.id, default: []].append(turn)
            }
        }
        conversations = turnsByConversation.map { id, turns in
            Conversation(id: id, turns: turns.sorted { $0.askedAt < $1.askedAt })
        }.sorted { $0.updatedAt > $1.updatedAt }
        if let currentID, !conversations.contains(where: { $0.id == currentID }) {
            conversations.insert(Conversation(id: currentID, turns: []), at: 0)
        }
        loaded = true
    }

    private func memoryTurn(_ id: String) -> Turn? {
        conversations.lazy.flatMap(\.turns).first { $0.id == id }
    }

    // MARK: Asking

    public func newConversation(scope: AskRequest.Scope? = nil) {
        currentID = nil
        self.scope = scope
        draft = ""
    }

    public func submit(_ session: CompanionSession) async {
        let question = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isAnswering else { return }
        draft = ""
        let conversationID = currentID ?? UUID().uuidString.lowercased()
        let history = (current?.turns ?? []).filter { $0.state == .answered }.suffix(6).flatMap { turn in
            [AskRequest.HistoryTurn(role: .user, text: turn.request.question),
             AskRequest.HistoryTurn(role: .assistant, text: AskCitationParser.plainText(turn.answer))]
        }
        let request = AskRequest(conversationId: conversationID, question: question, history: Array(history), scope: scope)
        if currentID == nil {
            conversations.insert(Conversation(id: conversationID, turns: []), at: 0)
            currentID = conversationID
        }
        append(Turn(request: request, answer: "", result: nil, state: .answering, askedAt: Date()))
        await send(request, session: session)
    }

    /// Asks again a question that couldn't reach the Mac or failed.
    public func retry(_ turnID: String, session: CompanionSession) async {
        guard let turn = turn(turnID) else { return }
        update(turnID) { $0.state = .answering; $0.answer = ""; $0.localResults = nil }
        await send(turn.request, session: session)
    }

    /// Picks up an answer whose connection dropped, e.g. when the phone is
    /// unlocked again.
    public func resumeWaiting(_ session: CompanionSession) async {
        guard !isAnswering,
              let waiting = conversations.lazy.flatMap(\.turns).last(where: { $0.state == .waiting }) else { return }
        // The Mac sends the text so far as the first delta.
        update(waiting.id) { $0.state = .answering; $0.restartText = true }
        await send(waiting.request, session: session)
    }

    private func send(_ request: AskRequest, session: CompanionSession) async {
        let id = request.requestId
        session.askingIDs.insert(id)
        defer { session.askingIDs.remove(id) }
        let addresses = await session.discoverAddresses()
        do {
            let result = try await session.store.ask(request, extraAddresses: addresses) { [weak self] delta in
                Task { @MainActor in
                    self?.update(id) {
                        guard $0.state == .answering else { return }
                        $0.answer = $0.restartText ? delta : $0.answer + delta
                        $0.restartText = false
                    }
                }
            }
            update(id) {
                $0.result = result
                $0.answer = result.answer
                $0.state = .answered
            }
        } catch CompanionStoreError.interrupted {
            update(id) { $0.state = .waiting; $0.interrupted = true }
        } catch CompanionStoreError.unreachable, CompanionStoreError.notPaired {
            // An interrupted question is queued already: out of reach, it keeps waiting.
            update(id) { $0.state = $0.interrupted ? .waiting : .macUnreachable }
        } catch {
            update(id) { $0.state = .failed(error.localizedDescription) }
        }
    }

    /// "Ask when my computer is back".
    public func queue(_ turnID: String, session: CompanionSession) async {
        guard let turn = turn(turnID) else { return }
        do {
            try await session.store.queueQuestion(turn.request)
            update(turnID) { $0.state = .queued }
        } catch {
            update(turnID) { $0.state = .failed(error.localizedDescription) }
        }
    }

    /// "Search this device": the phone's own copy, without the Mac.
    public func searchDevice(_ turnID: String, session: CompanionSession) async {
        guard let turn = turn(turnID) else { return }
        let terms = Self.searchTerms(turn.request.question)
        var hits = (try? await session.store.search(terms, limit: 30)) ?? []
        if hits.isEmpty, terms.contains(" ") {
            for term in terms.split(separator: " ") where hits.count < 30 {
                hits += (try? await session.store.search(String(term), limit: 10)) ?? []
            }
        }
        var seen = Set<String>()
        update(turnID) { $0.localResults = hits.filter { seen.insert($0.id).inserted } }
    }

    /// The question's content words, for a keyword search of the local copy.
    static func searchTerms(_ question: String) -> String {
        let stopWords: Set<String> = [
            "what", "when", "where", "which", "who", "why", "how", "about", "this", "that", "with", "week",
            "have", "does", "did", "from", "were", "will", "the", "and", "for", "are", "was", "you", "your",
            "our", "we", "i", "me", "my", "do", "is", "it", "to", "of", "on", "in", "a", "an", "at", "decide",
            "decided", "say", "said", "today", "yesterday",
        ]
        return question.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count > 2 && !stopWords.contains($0) }
            .joined(separator: " ")
    }

    // MARK: Helpers

    public func turn(_ id: String) -> Turn? {
        for conversation in conversations {
            if let turn = conversation.turns.first(where: { $0.id == id }) { return turn }
        }
        return nil
    }

    private func append(_ turn: Turn) {
        guard let index = conversations.firstIndex(where: { $0.id == turn.request.conversationId }) else { return }
        conversations[index].turns.append(turn)
    }

    private func update(_ id: String, _ change: (inout Turn) -> Void) {
        for c in conversations.indices {
            if let t = conversations[c].turns.firstIndex(where: { $0.id == id }) {
                change(&conversations[c].turns[t])
                return
            }
        }
    }
}
