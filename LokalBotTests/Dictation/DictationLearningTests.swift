import CryptoKit
import XCTest
@testable import LokalBot

/// Personal Context → Learn from my dictation: the short-lived encrypted log, which
/// pastes may be kept, and how dictated lines reach the learning pass.
@MainActor
final class DictationLearningLogTests: XCTestCase {
    private final class Clock {
        var now = Date(timeIntervalSince1970: 1_790_000_000)
    }

    private var root: URL!
    private let clock = Clock()
    private let key = SymmetricKey(data: Data(repeating: 0x5C, count: 32))
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DictationLearningLogTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeLog() -> DictationLearningLog {
        DictationLearningLog(root: root, now: { [clock] in clock.now }, encryptionKey: { [key] in key })
    }

    func testKeepsRedactedWordsSealedAndReadsThemByDay() throws {
        let log = makeLog()
        try log.append("I'm moving to Lisbon in spring, charge card 4111 1111 1111 1111 for the deposit", appName: "Slack")
        let sealed = try Data(contentsOf: log.url)
        XCTAssertNil(sealed.range(of: Data("Lisbon".utf8)), "the file is encrypted")
        let mode = try FileManager.default.attributesOfItem(atPath: log.url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)

        let entries = log.entries(on: clock.now, calendar: calendar)
        XCTAssertEqual(entries.map(\.appName), ["Slack"])
        XCTAssertTrue(entries[0].text.contains("Lisbon"))
        XCTAssertTrue(entries[0].text.contains("[REDACTED_CARD]"), entries[0].text)
        XCTAssertFalse(entries[0].text.contains("4111"))
        XCTAssertTrue(log.entries(on: clock.now.addingTimeInterval(86_400), calendar: calendar).isEmpty)
    }

    func testTheLearningPassRemovesItsDayAndEverythingBefore() throws {
        let log = makeLog()
        let firstDay = clock.now
        try log.append("I usually start work at nine", appName: "Notes")
        clock.now = clock.now.addingTimeInterval(86_400)
        try log.append("I'm flying to Berlin on Friday", appName: "Mail")

        try log.removeEntries(through: firstDay, calendar: calendar)
        XCTAssertTrue(log.entries(on: firstDay, calendar: calendar).isEmpty)
        XCTAssertEqual(log.entries(on: clock.now, calendar: calendar).map(\.appName), ["Mail"])

        try log.removeEntries(through: clock.now, calendar: calendar)
        XCTAssertFalse(FileManager.default.fileExists(atPath: log.url.path), "an empty log leaves no file")
    }

    func testNothingLastsMoreThanTwoDays() throws {
        let log = makeLog()
        let day = clock.now
        try log.append("I live in Belgrade with my family", appName: "Telegram")
        clock.now = clock.now.addingTimeInterval(DictationLearningLog.maximumAge + 1)
        XCTAssertTrue(log.entries(on: day, calendar: calendar).isEmpty)
        try log.prune()
        XCTAssertFalse(FileManager.default.fileExists(atPath: log.url.path))
    }

    func testKeepsOnlyTheNewestEntriesAndSurvivesAnUnreadableFile() throws {
        let log = makeLog()
        try FileManager.default.createDirectory(at: log.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not sealed".utf8).write(to: log.url)
        for index in 0..<(DictationLearningLog.maximumEntries + 5) {
            clock.now = clock.now.addingTimeInterval(1)
            try log.append("Line number \(index) about my week", appName: "Notes")
        }
        let entries = log.entries(on: clock.now, calendar: calendar)
        XCTAssertEqual(entries.count, DictationLearningLog.maximumEntries)
        XCTAssertEqual(entries.first?.text, "Line number 5 about my week")

        try log.deleteAll()
        XCTAssertFalse(FileManager.default.fileExists(atPath: log.url.path))
    }

    func testTheSettingIsOffByDefaultAndNeedsLearningAndAskMemory() throws {
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        XCTAssertFalse(decoded.personalLearningFromDictation)
        XCTAssertFalse(decoded.learnsFromDictation)
        var settings = AppSettings()
        settings.personalLearningFromDictation = true
        XCTAssertTrue(settings.learnsFromDictation)
        settings.personalLearningEnabled = false
        XCTAssertFalse(settings.learnsFromDictation)
        settings.personalLearningEnabled = true
        settings.askMemoryEnabled = false
        XCTAssertFalse(settings.learnsFromDictation)
    }
}

final class DictationLearningPolicyTests: XCTestCase {
    private func permits(app: String = "Slack", bundleID: String? = "com.tinyspeck.slackmacgap",
                         title: String? = "general – Acme", url: String? = nil,
                         excludedApps: [String] = [], excludedDomains: [String] = []) -> Bool {
        DictationLearningPolicy.permits(
            appName: app, bundleID: bundleID, surface: DictationLearningSurface(windowTitle: title, pageURL: url),
            excludedApps: excludedApps, excludedDomains: excludedDomains, ownBundleID: "me.dotenv.LokalBot")
    }

    func testANativeAppWithAKnownWindowIsKept() {
        XCTAssertTrue(permits())
        XCTAssertFalse(permits(title: nil), "an unreadable window can't be checked")
        XCTAssertFalse(permits(excludedApps: ["Slack"]))
    }

    func testBrowsersNeedAReadableAllowedPageOutsidePrivateWindows() {
        let safari = (app: "Safari", bundleID: "com.apple.Safari")
        XCTAssertTrue(permits(app: safari.app, bundleID: safari.bundleID, title: "Inbox – Gmail",
                              url: "https://mail.google.com/mail/u/0/"))
        XCTAssertFalse(permits(app: safari.app, bundleID: safari.bundleID, title: "Inbox – Gmail", url: nil))
        XCTAssertFalse(permits(app: safari.app, bundleID: safari.bundleID, title: "Inbox – Gmail",
                               url: "https://mail.google.com/mail/u/0/", excludedDomains: ["mail.google.com"]))
        XCTAssertFalse(permits(app: safari.app, bundleID: safari.bundleID, title: "Inbox — Private Browsing",
                               url: "https://mail.google.com/mail/u/0/"))
    }

    func testLokalBotItselfIsNeverKept() {
        XCTAssertFalse(permits(app: "LokalBot", bundleID: "me.dotenv.LokalBot", title: "Ask"))
    }
}

final class DictationLearningLinesTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func entry(_ text: String, app: String = "Slack", at date: Date? = nil) -> DictationLearningLog.Entry {
        DictationLearningLog.Entry(id: UUID(), text: text, appName: app, dictatedAt: date ?? now)
    }

    func testDictatedLinesJoinTypedOnesOnceAndOnlyForTheirDay() {
        let burst = CodingAgentBurst(
            agent: .claudeCode, sessionID: "s", title: "t", project: "LokalBot", branch: nil,
            start: now, end: now.addingTimeInterval(60), activeDuration: 60,
            prompts: ["I prefer small PRs, split this change please."], promptCount: 1, finalReply: nil,
            changedFiles: [], changedFileCount: 0, actions: [], pullRequests: [], toolCallCount: 0)
        let lines = PersonalLearning.typedLines(
            bursts: [burst], conversations: [],
            dictations: [
                entry("I prefer small PRs split this change please", app: "Terminal"),
                entry("Hey Ana, I'm moving to Lisbon in the spring so let's plan the handover"),
                entry("I'm off on Friday", at: now.addingTimeInterval(-86_400)),
            ],
            day: now, calendar: calendar)
        XCTAssertEqual(lines.map(\.label), ["typed to Claude Code", "dictated in Slack"],
                       "a dictated agent request is read once, from the request")
        XCTAssertEqual(lines.last?.source, .dictation(app: "Slack"))

        let utterances = lines.enumerated().map { index, line in
            PersonalLearning.Utterance(handle: "U\(index + 1)", source: .typed(line.source), label: line.label,
                                       dayKey: "2026-09-21", text: line.text)
        }
        let prompt = PersonalLearning.prompt(utterances: utterances, known: [])
        XCTAssertTrue(prompt.contains("U2 (dictated in Slack): Hey Ana, I'm moving to Lisbon"), prompt)
        XCTAssertTrue(prompt.contains("Dictated lines are often messages to someone else."))
    }

    func testTheSeedsDictationOriginDecodes() throws {
        let json = """
            {"version":1,"claims":[{"id":"BBBBBBB1-0000-4000-8000-000000000006","kind":"preference",
            "text":"I prefer to get the agenda the day before.",
            "origin":{"typed":{"source":{"dictation":{"app":"Slack"}},"dayKey":"2026-10-15"}},
            "alwaysUse":false,"sharing":"lokalBotOnly","status":"proposed","authority":"learned",
            "quote":"Hi Marko, could you send the agenda the day before?",
            "createdAt":"2026-10-15T10:00:00Z","updatedAt":"2026-10-15T10:00:00Z"}]}
            """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let model = try decoder.decode(PersonalModel.self, from: Data(json.utf8))
        XCTAssertEqual(model.claims.first?.origin, .typed(source: .dictation(app: "Slack"), dayKey: "2026-10-15"))
    }

    func testDictatedItemsWaitForReviewWithNothingToRetractThem() async throws {
        let line = PersonalLearning.Utterance(
            handle: "U1", source: .typed(.dictation(app: "Slack")), label: "dictated in Slack", dayKey: "2026-09-21",
            text: "Hey Ana, I'm moving to Lisbon in the spring so let's plan the handover")
        let output = #"{"items": [{"line": "U1", "kind": "fact", "text": "I'm moving to Lisbon in the spring."}]}"#
        let candidates = await PersonalLearning.groundedCandidates(from: output, utterances: [line], embed: nil) {
            PersonalLearning.provenance(for: $0, revision: 4)
        }
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates.first?.needsReview, true)
        XCTAssertNil(candidates.first?.evidence)
        XCTAssertEqual(candidates.first?.origin, .typed(source: .dictation(app: "Slack"), dayKey: "2026-09-21"))

        var model = PersonalModel()
        let outcome = model.learn(candidates, now: now)
        XCTAssertTrue(outcome.saved.isEmpty)
        let kept = try model.confirm(id: XCTUnwrap(outcome.proposed.first?.id), now: now).get()
        XCTAssertEqual(PersonalContextProjection.Claim(kept).source, .learnedFromDictation)
        XCTAssertFalse(PersonalContextSettings.hasRemovableSource(kept))
    }
}
