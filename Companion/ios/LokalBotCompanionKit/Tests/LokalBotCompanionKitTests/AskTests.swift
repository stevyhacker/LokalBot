import Foundation
import Testing
@testable import LokalBotCompanionKit

@Suite("Ask citations")
struct AskCitationParserTests {
    @Test func markersInOrderOfFirstUse() {
        #expect(AskCitationParser.markers(in: "Cut to three steps [2] and test it [1][2]. Ship it [3].") == [2, 1, 3])
        #expect(AskCitationParser.markers(in: "Grouped [1, 4] markers") == [1, 4])
        #expect(AskCitationParser.markers(in: "No markers, a [link](https://example.com) and [x].") == [])
    }

    @Test func linksOnlyKnownCitations() {
        let linked = AskCitationParser.linkedMarkdown("Three steps [1]. Legal [7]. Flag [1, 2].", valid: [1, 2])
        #expect(linked == "Three steps [1](lokalbot-citation://source/1). Legal [7]. Flag [1](lokalbot-citation://source/1)[2](lokalbot-citation://source/2).")
    }

    @Test func leavesMarkdownLinksAlone() {
        let text = "See [the doc](https://example.com) and [1]."
        #expect(AskCitationParser.linkedMarkdown(text, valid: [1]) == "See [the doc](https://example.com) and [1](lokalbot-citation://source/1).")
    }

    @Test func holdsBackAMarkerCutOffWhileStreaming() {
        #expect(AskCitationParser.linkedMarkdown("You agreed [", valid: [1], streaming: true) == "You agreed ")
        #expect(AskCitationParser.linkedMarkdown("You agreed [1", valid: [1], streaming: true) == "You agreed ")
        #expect(AskCitationParser.linkedMarkdown("You agreed [1, ", valid: [1], streaming: true) == "You agreed ")
        #expect(AskCitationParser.linkedMarkdown("You agreed [1", valid: [1]) == "You agreed [1")
    }

    @Test func citationLinksRoundTrip() throws {
        let url = try #require(URL(string: "lokalbot-citation://source/12"))
        #expect(AskCitationParser.citationNumber(from: url) == 12)
        #expect(AskCitationParser.citationNumber(from: URL(string: "https://source/12")!) == nil)
    }

    @Test func plainTextDropsMarkers() {
        #expect(AskCitationParser.plainText("Three steps [1]. Ship it [2][3].") == "Three steps. Ship it.")
    }

    @Test func linkedMarkdownParsesIntoLinkRuns() {
        let attributed = MarkdownInline.attributed(AskCitationParser.linkedMarkdown("**Yes** [1]", valid: [1]))
        let links = attributed.runs.compactMap(\.link)
        #expect(links == [URL(string: "lokalbot-citation://source/1")!])
        #expect(String(attributed.characters) == "Yes 1")
    }
}

@Suite("Ask model")
@MainActor
struct AskModelTests {
    func session(reachable: Bool) async throws -> CompanionSession {
        let status = SyncStatus(paired: true, lastSyncAt: SampleLibrary.referenceDate, lastAddress: "192.168.1.20:17890",
                                cursor: 19, macName: "Sample Mac")
        let store = try FixtureStore.sampleLibrary(configuration: .init(
            now: { SampleLibrary.referenceDate }, pairedStatus: status, macReachable: reachable))
        let session = CompanionSession(store: store)
        await session.start()
        return session
    }

    @Test func answersWithCitationsAndKeepsTheConversation() async throws {
        let session = try await session(reachable: true)
        let model = AskModel()
        model.draft = "What did we decide about onboarding?"
        await model.submit(session)
        let turn = try #require(model.current?.turns.first)
        #expect(turn.state == .answered)
        #expect(!(turn.result?.citations.isEmpty ?? true))
        #expect(AskCitationParser.markers(in: turn.answer) == turn.result?.citations.map(\.index))
        #expect(turn.result?.citations.first?.meetingId != nil)

        model.draft = "And pricing?"
        await model.submit(session)
        let second = try #require(model.current?.turns.last)
        #expect(second.request.history.map(\.role) == [.user, .assistant])
        #expect(model.current?.turns.count == 2)

        await model.load(session)
        #expect(model.conversations.count == 1)
        #expect(model.current?.turns.count == 2)
    }

    @Test func offersLocalSearchAndQueueWhenTheMacIsAway() async throws {
        let session = try await session(reachable: false)
        let model = AskModel()
        model.draft = "What did we decide about the pricing tiers?"
        await model.submit(session)
        let id = try #require(model.current?.turns.first?.id)
        #expect(model.turn(id)?.state == .macUnreachable)

        await model.searchDevice(id, session: session)
        let results = try #require(model.turn(id)?.localResults)
        #expect(!results.isEmpty)
        #expect(results.allSatisfy { $0.meetingId != nil || $0.date != nil })

        await model.queue(id, session: session)
        #expect(model.turn(id)?.state == .queued)
        #expect(try await session.store.queuedQuestions().map(\.requestId) == [id])
        await model.load(session)
        #expect(model.turn(id)?.state == .queued)
    }

    @Test func searchTermsDropQuestionWords() {
        #expect(AskModel.searchTerms("What did we decide about the pricing tiers?") == "pricing tiers")
    }
}
