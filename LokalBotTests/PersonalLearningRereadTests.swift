import CryptoKit
import XCTest
@testable import LokalBot

/// Which microphone lines are the person's: diarization's "local 1" and
/// plain "local" are one voice; several voices count only with a clear winner.
final class PersonalLearningMicrophoneTests: XCTestCase {
    private func segment(_ speaker: String, _ text: String,
                         _ identity: SpeakerAttribution.Identity = .user,
                         _ method: SpeakerAttribution.Method = .diarization) -> Transcript.Segment {
        var segment = Transcript.Segment(start: 0, end: 1, speaker: speaker, text: text, confidence: nil)
        segment.attribution = SpeakerAttribution(source: .microphone, identity: identity, method: method)
        return segment
    }

    private func repeated(_ speaker: String, _ count: Int) -> [Transcript.Segment] {
        (0..<count).flatMap { index in
            [segment(speaker, "My line number \(index) about the release plan"), segment("them 1", "Okay.", .other)]
        }
    }

    func testPlainLocalAndLocalOneAreOneVoice() {
        let turns = PersonalLearning.ownTurns(in: [
            segment("local", "I moved to Lisbon with my family in the spring.", .user, .track),
            segment("them 1", "Oh nice.", .other),
            segment("local 1", "My goal is to run a marathon in 2027, honestly."),
        ])
        XCTAssertEqual(turns, [
            "I moved to Lisbon with my family in the spring.",
            "My goal is to run a marathon in 2027, honestly.",
        ])
    }

    func testEchoOverlapAndOtherPeopleAreNotThePerson() {
        let turns = PersonalLearning.ownTurns(in: [
            segment("local 1", "I lead the platform team at the company."),
            segment("local 1", "You lead the design review next week, right?", .unresolved, .suspectedEcho),
            segment("local unclear", "We both live near the old town these days.", .unresolved, .overlappingSpeech),
            segment("local 1", "I was born in Novi Sad and moved later.", .other, .confirmation),
        ])
        XCTAssertEqual(turns, ["I lead the platform team at the company."])
    }

    func testOneDominantVoiceCountsAloneAndAnEvenSplitIsSkipped() {
        let dominant = PersonalLearning.ownTurns(in: repeated("local 1", 8) + repeated("local 2", 2)
            + [segment("local", "I think the plain track line stays out.", .user, .track)])
        XCTAssertEqual(dominant.count, 8)
        XCTAssertTrue(dominant.allSatisfy { $0.hasPrefix("My line number") })

        XCTAssertEqual(PersonalLearning.ownTurns(in: repeated("local 1", 6) + repeated("local 2", 3)), [])
    }

    func testAConfirmedVoiceWinsOverTheDefault() {
        let turns = PersonalLearning.ownTurns(in: repeated("local 1", 5) + [
            segment("local 2", "I confirmed this voice is me in the speaker list.", .user, .confirmation),
        ])
        XCTAssertEqual(turns, ["I confirmed this voice is me in the speaker list."])
    }

    func testUnattributedMicrophoneLinesFollowMyMicrophoneIsMe() {
        let saved = SpeakerAttribution.microphoneIsUser
        defer { SpeakerAttribution.microphoneIsUser = saved }
        let lines = [Transcript.Segment(start: 0, end: 1, speaker: "local", text: "I work from home on Fridays now.",
                                        confidence: nil)]
        SpeakerAttribution.microphoneIsUser = true
        XCTAssertEqual(PersonalLearning.ownTurns(in: lines), ["I work from home on Fridays now."])
        SpeakerAttribution.microphoneIsUser = false
        XCTAssertEqual(PersonalLearning.ownTurns(in: lines), [])
    }
}

/// Learning reads a day again only when the person's lines from it changed,
/// and a learned claim survives a changed source that still has its line.
@MainActor
final class PersonalLearningRereadTests: XCTestCase {
    private var root: URL!
    private let key = SymmetricKey(data: Data(repeating: 0x3C, count: 32))
    private var now = Date(timeIntervalSince1970: 1_790_000_000)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PersonalLearningReread-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func line(_ handle: String, _ source: PersonalLearning.Utterance.Source, _ text: String)
        -> PersonalLearning.Utterance {
        PersonalLearning.Utterance(handle: handle, source: source, label: "Weekly sync", dayKey: "2026-10-20", text: text)
    }

    func testFingerprintIgnoresOrderHandlesAndDictationButNotTheLines() {
        let meeting = UUID()
        let base = [
            line("U1", .meeting(meeting), "I live in Belgrade with my family."),
            line("U2", .typed(.codingAgent(name: "Claude Code")), "I prefer small pull requests, split this."),
        ]
        let reordered = [base[1], base[0]].enumerated().map { index, utterance -> PersonalLearning.Utterance in
            var copy = utterance
            copy.handle = "U\(index + 1)"
            return copy
        }
        let withDictation = base + [line("U3", .typed(.dictation(app: "Slack")), "I'm off on Friday, see you Monday.")]
        let changed = base + [line("U3", .meeting(meeting), "I started learning Portuguese this month.")]

        let fingerprint = PersonalLearning.fingerprint(base)
        XCTAssertEqual(PersonalLearning.fingerprint(reordered), fingerprint)
        XCTAssertEqual(PersonalLearning.fingerprint(withDictation), fingerprint,
                       "dictation is deleted once read, so a later review would always look changed")
        XCTAssertNotEqual(PersonalLearning.fingerprint(changed), fingerprint)
    }

    func testQuoteStillSaidIgnoresCaseAccentsPunctuationAndCutOffs() {
        let quote = "Ja živim u Novom Sadu, i radim od kuće."
        XCTAssertTrue(PersonalLearning.quoteStillSaid(quote, in: ["Ok. JA ZIVIM U NOVOM SADU i radim od kuce! Super."]))
        XCTAssertTrue(PersonalLearning.quoteStillSaid("I lead the platform team and the release train…",
                                                      in: ["I lead the platform team and the release train since May."]))
        XCTAssertFalse(PersonalLearning.quoteStillSaid(quote, in: ["Ja živim u Beogradu."]))
        XCTAssertFalse(PersonalLearning.quoteStillSaid(nil, in: [quote]))
        XCTAssertFalse(PersonalLearning.quoteStillSaid("I agree.", in: ["I agree."]), "too short to tell")
    }

    func testADayIsRecordedAsReadWithItsFingerprint() throws {
        let controller = PersonalModelController(
            store: PersonalModelStore(root: root, encryptionKey: { [key] in key }), now: { [unowned self] in now })
        XCTAssertFalse(controller.hasLearned(dayKey: "2026-10-20", fingerprint: "a"))
        controller.learn([], dayKey: "2026-10-20", fingerprint: "a")
        XCTAssertTrue(controller.hasLearned(dayKey: "2026-10-20", fingerprint: "a"))
        XCTAssertFalse(controller.hasLearned(dayKey: "2026-10-20", fingerprint: "b"))

        controller.learn([], dayKey: "2026-10-20", fingerprint: "b")
        let reopened = PersonalModelController(store: PersonalModelStore(root: root, encryptionKey: { [key] in key }))
        XCTAssertTrue(reopened.hasLearned(dayKey: "2026-10-20", fingerprint: "b"), "saved, and the newer read replaces it")
        XCTAssertFalse(reopened.hasLearned(dayKey: "2026-10-20", fingerprint: "a"))

        now = now.addingTimeInterval(PersonalModel.learnedDayLifetime + 86_400)
        controller.learn([])
        XCTAssertFalse(controller.hasLearned(dayKey: "2026-10-20", fingerprint: "b"), "old records are pruned")
    }

    func testAChangedSourceKeepsClaimsWhoseLineIsStillThereAndRetractsTheRest() throws {
        let dreamStore = DreamStore(root: root)
        let revision = try dreamStore.evidenceRevision()
        let meeting = UUID()
        var stillThere: Set<String> = ["I live in Belgrade with my family."]
        let controller = PersonalModelController(
            store: PersonalModelStore(root: root, encryptionKey: { [key] in key }),
            now: { [unowned self] in now },
            evidenceCheck: { dreamStore.evidenceCheck() },
            sourceStillQuotes: { claim in claim.quote.map { stillThere.contains($0) } ?? false },
            currentRevision: { try? dreamStore.evidenceRevision() })
        func learned(_ text: String) -> PersonalModel.LearningCandidate {
            PersonalModel.LearningCandidate(
                kind: .fact, text: text, quote: text, meetingID: meeting, dayKey: "2026-10-20",
                evidence: DreamEvidenceProvenance(
                    sources: [DreamEvidenceSource(kind: .meeting, id: meeting.uuidString, dayKey: "2026-10-20")],
                    revision: revision))
        }
        controller.learn([learned("I live in Belgrade with my family."), learned("I have two kids at home.")])
        XCTAssertEqual(controller.usableClaims().count, 2)

        // The meeting was edited elsewhere: one quoted line remains, one is gone.
        _ = try dreamStore.invalidateEvidence(affectedDayKeys: [], affectedMeetingIDs: [meeting], reportDayKeys: [])
        XCTAssertEqual(controller.usableClaims().map(\.text), ["I live in Belgrade with my family."])
        let kept = try XCTUnwrap(controller.currentClaims().first)
        XCTAssertEqual(kept.evidence?.revision, try dreamStore.evidenceRevision(), "tied to the current revision")

        // Re-checked only after the next change; then the line is gone too.
        stillThere = []
        XCTAssertEqual(controller.usableClaims().count, 1)
        _ = try dreamStore.invalidateEvidence(affectedDayKeys: [], affectedMeetingIDs: [meeting], reportDayKeys: [])
        XCTAssertTrue(controller.usableClaims().isEmpty)
    }
}

/// Personal Context is its own Settings section, for people, search, and the CLI.
@MainActor
final class PersonalContextSettingsTabTests: XCTestCase {
    func testAboutYouHasItsOwnTabAndSettings() throws {
        XCTAssertTrue(AppState.SettingsTab.allCases.contains(.personalContext))
        XCTAssertEqual(AppState.SettingsTab.personalContext.displayName, "Personal Context")
        XCTAssertEqual(AppState.SettingsTab(captureName: "personal context"), .personalContext)
        XCTAssertEqual(AppState.SettingsTab(rawValue: SettingCategory.personalContext.rawValue), .personalContext)
        for id in ["askMemoryEnabled", "personalLearningEnabled", "personalLearningFromDictation"] {
            let descriptor = try XCTUnwrap(SettingDescriptor.all.first { $0.id == "settings.\(id)" }, id)
            XCTAssertEqual(descriptor.category, .personalContext, id)
            XCTAssertEqual(SettingRegistry.spec(for: id)?.category, .personalContext, id)
        }
    }
}

/// Personal Context rows: one short line of kind, source, and day.
final class PersonalContextSettingsRowTests: XCTestCase {
    private let calendar = Calendar(identifier: .gregorian)
    private let now = Date(timeIntervalSince1970: 1_792_670_400) // 2026-10-22

    private func claim(_ origin: PersonalClaim.Origin, status: PersonalClaim.Status = .confirmed,
                       authority: PersonalClaim.Authority = .confirmed, daysAgo: Double = 1) -> PersonalClaim {
        PersonalClaim(kind: .preference, text: "Answer in bullet points.", origin: origin,
                      status: status, authority: authority, createdAt: now.addingTimeInterval(-daysAgo * 86_400))
    }

    private func line(_ claim: PersonalClaim, showsKind: Bool = false, meetingTitle: String? = nil) -> String {
        PersonalContextSettings.metaLine(for: claim, showsKind: showsKind, meetingTitle: meetingTitle,
                                         now: now, calendar: calendar)
    }

    func testReviewLineNamesKindAndSourceWithoutTheYear() {
        let suggestion = claim(.typed(source: .codingAgent(name: "Codex"), dayKey: "2026-10-21"),
                               status: .proposed, authority: .learned)
        let parts = line(suggestion, showsKind: true).components(separatedBy: " · ")
        XCTAssertEqual(Array(parts.prefix(2)), ["Preference", "From Codex"])
        XCTAssertEqual(parts.count, 3)
        XCTAssertFalse(parts[2].contains("2026"), parts[2])
    }

    func testKeptLinesDropTheKindAndMarkWhatWasSavedWithoutReview() {
        let kept = claim(.typed(source: .codingAgent(name: "Claude Code"), dayKey: "2026-10-21"))
        XCTAssertTrue(line(kept).hasPrefix("From Claude Code · "), line(kept))
        XCTAssertEqual(line(kept).components(separatedBy: " · ").count, 2)

        let meeting = claim(.learned(meetingID: UUID(), dayKey: "2026-10-21"), authority: .learned)
        XCTAssertTrue(line(meeting, meetingTitle: "Weekly sync").hasPrefix("From Weekly sync · Saved automatically · "))
        XCTAssertTrue(line(meeting).hasPrefix("From a meeting · "))
        XCTAssertTrue(line(claim(.added, authority: .stated)).hasPrefix("Added by you · "))
    }

    func testOlderItemsShowTheirYear() {
        let old = claim(.added, authority: .stated, daysAgo: 400)
        XCTAssertTrue(line(old).contains("2025"), line(old))
    }

    func testAgentSummaryFollowsAccessAndSharedCount() {
        XCTAssertEqual(PersonalContextSettings.agentSummary(shared: 0, accessEnabled: true),
                       "Personal context access is on, but nothing is shared yet. Choose Share with Agents on an item.")
        XCTAssertEqual(PersonalContextSettings.agentSummary(shared: 2, accessEnabled: true),
                       "Agents can read 2 shared items, when they're relevant to their task.")
        XCTAssertEqual(PersonalContextSettings.agentSummary(shared: 1, accessEnabled: false),
                       "1 item is marked for agents, but personal context access is off.")
    }
}
