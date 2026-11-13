import XCTest
@testable import LokalBot

final class TranscriptionVocabularyTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vocabulary-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func meeting(_ title: String, day: Double, attendees: [(String?, String?)],
                         aliases: [String: String] = [:]) throws -> Meeting {
        var meeting = Meeting(
            id: UUID(), title: title, appName: "Meet",
            startedAt: Date(timeIntervalSince1970: 1_780_000_000 + day * 86_400),
            endedAt: Date(timeIntervalSince1970: 1_780_000_000 + day * 86_400 + 1_800),
            relativePath: "meetings/\(UUID().uuidString)")
        meeting.calendarTitle = title
        meeting.calendarParticipantIdentities = attendees.compactMap {
            CalendarParticipantIdentity(name: $0.0, emailAddress: $0.1)
        }
        if !aliases.isEmpty {
            let folder = root.appendingPathComponent(meeting.relativePath, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let transcript = Transcript(segments: [], engine: "fixture", speakerAliases: aliases)
            try JSONEncoder().encode(transcript).write(to: folder.appendingPathComponent("transcript.json"))
        }
        return meeting
    }

    func testTermsUseNamesProjectsAndTitleTermsButNeverEmailAddresses() throws {
        let prior = try meeting("Acme weekly sync", day: -7,
                                attendees: [("Jelena Marković", nil)],
                                aliases: ["them": "Jelena Marković", "local 2": "Dragan Ilić"])
        let unrelated = try meeting("Dentist", day: -3, attendees: [("Zed Unrelated", nil)],
                                    aliases: ["them": "Should Not Appear"])
        let current = try meeting("Acme weekly sync", day: 0,
                                  attendees: [("Jelena Marković", "jelena@example.com"),
                                              (nil, "ana.petrovic@example.com")])
        var memory = DreamMemory(updatedAt: Date())
        memory.activeProjects = [
            .init(name: "Orion Launch", status: "blocked", lastActiveDay: "2026-05-27", pinned: true),
            .init(name: "Ave vault accounting and compliance", status: "active", lastActiveDay: "2026-05-27"),
        ]

        let terms = TranscriptionVocabulary.terms(TranscriptionVocabulary.sources(
            for: current, library: [prior, unrelated, current], root: root, memory: memory))

        XCTAssertEqual(terms.first, "Jelena Marković")
        XCTAssertTrue(terms.contains("Dragan Ilić"))
        XCTAssertTrue(terms.contains("Orion Launch"), "a project the person pinned is vocabulary")
        XCTAssertFalse(terms.contains("Ave vault accounting and compliance"),
                       "an unpinned model label must not bias the next transcript")
        XCTAssertTrue(terms.contains("Acme"))
        XCTAssertFalse(terms.contains("Should Not Appear"))
        XCTAssertFalse(terms.contains { $0.contains("@") || $0.localizedCaseInsensitiveContains("petrovic") })
        XCTAssertEqual(terms.filter { $0 == "Jelena Marković" }.count, 1)
        XCTAssertFalse(terms.contains("weekly"))
    }

    func testPromptKeepsManualVocabularyFirstAndBoundsLength() {
        XCTAssertEqual(TranscriptionVocabulary.prompt(manual: "QVAC", terms: []), "QVAC")
        XCTAssertEqual(TranscriptionVocabulary.prompt(manual: "QVAC", terms: ["Ana", "Orion"]),
                       "QVAC\nAna, Orion.")
        XCTAssertEqual(TranscriptionVocabulary.prompt(manual: "", terms: ["Ana"]), "Ana.")

        var sources = TranscriptionVocabulary.Sources()
        sources.attendeeNames = (0..<200).map { "Participant Name \($0)" } + ["Speaker 2", "Me"]
        let terms = TranscriptionVocabulary.terms(sources)
        XCTAssertLessThanOrEqual(terms.count, TranscriptionVocabulary.maximumTerms)
        XCTAssertLessThanOrEqual(terms.joined(separator: ", ").count, TranscriptionVocabulary.maximumCharacters)
        XCTAssertFalse(terms.contains("Speaker 2"))
    }

    func testResumedTranscriptionReusesSavedTerms() throws {
        let current = try meeting("Orion review", day: 0, attendees: [("Mila Novak", nil)])
        let folder = root.appendingPathComponent(current.relativePath, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var config = AppSettings()
        config.transcriptionModel = .whisperLarge
        config.transcriptionPrompt = "LokalBot"

        let first = ProcessingPipeline.transcriptionPrompt(
            for: current, folder: folder, root: root, config: config, reuseSaved: false)
        XCTAssertTrue(first.hasPrefix("LokalBot\n"))
        XCTAssertTrue(first.contains("Mila Novak"))

        try TranscriptionVocabulary.save(.init(terms: ["Saved Term"], createdAt: Date()), to: folder)
        XCTAssertEqual(ProcessingPipeline.transcriptionPrompt(
            for: current, folder: folder, root: root, config: config, reuseSaved: true),
            "LokalBot\nSaved Term.")

        config.transcriptionModel = .parakeetV3
        XCTAssertEqual(ProcessingPipeline.transcriptionPrompt(
            for: current, folder: folder, root: root, config: config, reuseSaved: false), "LokalBot")
        config.transcriptionModel = .whisperLarge
        config.autoTranscriptionVocabulary = false
        XCTAssertEqual(ProcessingPipeline.transcriptionPrompt(
            for: current, folder: folder, root: root, config: config, reuseSaved: false), "LokalBot")
    }

    func testRecentSourcesRankFrequentAttendeesFirst() throws {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let meetings = [
            try meeting("A", day: -1, attendees: [("Rare Person", nil), ("Frequent Person", nil)]),
            try meeting("B", day: -2, attendees: [("Frequent Person", nil)]),
            try meeting("Old", day: -90, attendees: [("Ancient Person", nil)]),
        ]
        let sources = TranscriptionVocabulary.recentSources(library: meetings, memory: nil, now: now)
        XCTAssertEqual(sources.attendeeNames, ["Frequent Person", "Rare Person"])
    }

    /// A merged meeting's applied names carry "· source N", and labels such as
    /// "Them 6" name nobody; fed to the recognizer they came back as rows.
    func testTermsDropMergedAndPlaceholderSpeakerLabelsAndDepartmentTitleWords() throws {
        let merged = try meeting("Product standup", day: -1, attendees: [],
                                 aliases: ["them": "Them 6 · source 2", "local 2": "Mila Novak · source 1",
                                           "them 3": "Speaker unclear", "local": "Local speaker"])
        let current = try meeting("Product standup", day: 0, attendees: [("Ana Horvat", nil)])

        let terms = TranscriptionVocabulary.terms(TranscriptionVocabulary.sources(
            for: current, library: [merged, current], root: root, memory: nil))

        XCTAssertEqual(terms, ["Ana Horvat", "Mila Novak"],
                       "the series still relates the meetings; the suffix is stripped, labels and 'Product' are out")
    }

    func testSavedPromptReusesTheMeetingsOwnTerms() throws {
        let folder = root.appendingPathComponent("saved", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        XCTAssertEqual(TranscriptionVocabulary.savedPrompt(manual: "LokalBot", in: folder), "LokalBot")

        try TranscriptionVocabulary.save(.init(terms: ["Mila Novak", "Acme"], createdAt: Date()), to: folder)

        XCTAssertEqual(TranscriptionVocabulary.savedPrompt(manual: "LokalBot", in: folder),
                       "LokalBot\nMila Novak, Acme.")
    }
}
