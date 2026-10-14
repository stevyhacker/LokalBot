import XCTest
@testable import LokalBot

final class ChatEvidenceOrderingTests: XCTestCase {
    func testCrossScriptProjectSourcesMoveAheadOfUnrelatedRecordsWithoutLosingHistory() {
        let earlier = source("За Рил смо изабрали плаву полицу.", title: "Банка семена Рил", seconds: 12)
        let current = source("За Рил смо сада одобрили зелени ормар, уместо плаве полице.", title: "Банка семена Рил", seconds: 72)
        let unrelated = (0..<7).map { source("The storage room has a cabinet and a shelf.", title: "Other project \($0)", seconds: 132 + $0 * 60) }
        let input = evidence(unrelated + [current, earlier])
        let result = ChatEvidenceOrdering.prioritize(input, question: "Gde je sada seme za Ril, a gde je prvo trebalo da stoji?")
        XCTAssertEqual(Array(result.excerpts.prefix(2)), [current, earlier])
        XCTAssertEqual(result.excerpts.count, input.excerpts.count)
        XCTAssertTrue(input.excerpts.allSatisfy(result.excerpts.contains))
        XCTAssertEqual(result.meetingIDs, input.meetingIDs)
        XCTAssertEqual(result.meetingSeconds, input.meetingSeconds)
        XCTAssertTrue(ChatGrounding.catalog(result).contains("уместо плаве полице"))
    }

    func testEnglishQueryFindsNamedProjectInSerbianWithoutTranslatingSourceText() {
        let source = source("Lantern proba sada traje trideset pet minuta, umesto dvadeset.", title: "Lokalni radio Lantern", seconds: 12)
        let distracting = self.source("The initial and revised trial durations are documented.", title: "Other", seconds: 72)
        let input = evidence([distracting, source])
        let result = ChatEvidenceOrdering.prioritize(input, question: "What were the initial and revised Lantern trial durations?")
        XCTAssertEqual(result.excerpts.first, source)
        XCTAssertEqual(result.excerpts.first?.text, source.text)
        XCTAssertEqual(result.excerpts.first?.marker, "[meeting:11111111@00:00:12]")
    }

    func testNoMatchesAndTiesRetainRetrievalOrder() {
        let input = evidence([source("A recorded fact.", title: "One", seconds: 72),
                              source("A recorded fact.", title: "Two", seconds: 12)])
        XCTAssertEqual(ChatEvidenceOrdering.prioritize(input, question: "Unmatched?").excerpts, input.excerpts)
        XCTAssertEqual(ChatEvidenceOrdering.prioritize(input, question: "Recorded fact?").excerpts, input.excerpts)
        XCTAssertEqual(ChatEvidenceOrdering.prioritize(input, question: "?").excerpts, input.excerpts)
    }

    func testPresentationOrderCannotAuthorizeForgedSource() {
        let original = source("Harbor has not approved payment.", title: "Harbor", seconds: 12)
        let forged = ChatSourceExcerpt(text: "Harbor approved payment.", citation: .init(meetingID: "deadbeef", seconds: 12),
                                       meetingTitle: "Harbor payment")
        var input = evidence([original])
        input.excerpts.append(forged)
        let ordered = ChatEvidenceOrdering.prioritize(input, question: "Has Harbor approved payment?")
        XCTAssertEqual(ordered.excerpts.count, 2)
        XCTAssertEqual(ChatGrounding.sources(ordered), [original])
        XCTAssertFalse(ChatGrounding.catalog(ordered).contains("Harbor approved payment."))
    }

    func testCatalogKeepsDisplayNamesAndDistinctProvenanceForSameNamedPeople() {
        let first = ChatSourceExcerpt(text: "I own Drift calibration. I am the acoustics researcher.",
            citation: .init(meetingID: "11111111", seconds: 12), label: "Luka · acoustics", meetingTitle: "Drift",
            speakerLabel: "Luka", recordedAt: Date(timeIntervalSince1970: 1_000))
        let second = ChatSourceExcerpt(text: "I coordinate Mosaic signs. I am the conference volunteer.",
            citation: .init(meetingID: "11111111", seconds: 72), label: "Luka · conference volunteer", meetingTitle: "Mosaic",
            speakerLabel: "Luka", recordedAt: Date(timeIntervalSince1970: 2_000))
        let records = ChatGrounding.catalogRecords(evidence([first, second]))
        XCTAssertEqual(records.map { $0["speaker_label"] }, ["Luka", "Luka"])
        XCTAssertNotEqual(records[0]["citation"], records[1]["citation"])
        XCTAssertEqual(records[0]["recorded_at"], "1970-01-01T00:16:40Z")
        XCTAssertEqual(records[1]["label"], "Luka · conference volunteer")
        XCTAssertEqual(records[0]["text"], first.text)
        XCTAssertEqual(records[1]["text"], second.text)
    }

    func testRenderingPreservesTrustedSpeakerDisplayNameWithoutGuessingFromIDs() {
        let source = ChatSourceExcerpt(text: "The stocktake is my responsibility.",
            citation: .init(meetingID: "11111111", seconds: 12), label: "Topaz recorded source",
            speakerLabel: "Soraya [screen:99]")
        let answer = ChatGrounding.render([source])
        XCTAssertTrue(answer.contains("Soraya ［screen:99］"))
        XCTAssertEqual(ChatCitationParser.extract(answer).citations, [source.citation!])
        XCTAssertFalse(answer.contains("speaker-soraya"))
    }

    private func source(_ text: String, title: String, seconds: Int) -> ChatSourceExcerpt {
        .init(text: text, citation: .init(meetingID: "11111111", seconds: Double(seconds)), meetingTitle: title)
    }

    private func evidence(_ sources: [ChatSourceExcerpt]) -> ChatEvidence {
        var result = ChatEvidence(meetingIDs: ["11111111"], meetingSeconds: ["11111111": Set(sources.compactMap { $0.citation?.seconds.map(Int.init) })])
        result.excerpts = sources
        return result
    }
}
